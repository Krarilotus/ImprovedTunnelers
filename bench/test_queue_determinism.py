"""Execute the real queue_tick + queue_step payloads with varied CPU clocks.

Requires FASM_EXE, lupa and unicorn. Native damage/path calls are recorded stubs;
this proves scheduling/order/resumption, not whole-game damage or native ABI.
"""
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import unittest
from lupa.lua54 import LuaRuntime
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
from unicorn.x86_const import UC_X86_REG_EAX, UC_X86_REG_EDX, UC_X86_REG_EIP, UC_X86_REG_ESP, UC_X86_REG_ECX

MODULE = Path(__file__).resolve().parents[1] / 'module'


@unittest.skipUnless(os.environ.get('FASM_EXE'), 'FASM_EXE not supplied')
class QueueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        templates = LuaRuntime().execute((MODULE/'templates.lua').read_text(encoding='utf-8'))
        payloads = (templates['queue_tick'], templates['queue_step'])
        names = sorted(set(re.findall(r'\b[A-Z][A-Z0-9_]+\b', '\n'.join(payloads))))
        cls.v = v = {name: 0x200000+i*4 for i, name in enumerate(names)}
        v.update(STEP_ADDRESS=0x110000, UPDATE_WALK_ADDRESS=0x111000,
                 PROCESS_DAMAGE_ADDRESS=0x111100, RETURN_ADDRESS=0x111200,
                 REPORT_PAD_ADDRESS=0x111300, QUEUE_ADDRESS=0x202000,
                 ROW_TABLE_ADDRESS=0x240000, TILE_FLAGS_ADDRESS=0x300000,
                 BUILDING_TILE_ADDRESS=0x3A0000, BUILDING_TYPE_ADDRESS=0x3F0000,
                 FORTIFIED_ADDRESS=0x3F8000, BASE_HEIGHT_ADDRESS=0x440000,
                 LIVE_HEIGHT_ADDRESS=0x470000, WALL_FAMILY=0xB00, STOCKPILE=2,
                 BUILDING_STRIDE=0x32C, TYPE_LIMIT=120, MAP_LIMIT=398,
                 TUNNEL_DAMAGE=5, SW_FLOOR=90000)
        cls.code = []
        with tempfile.TemporaryDirectory() as temp:
            for origin, script in zip((0x100000, v['STEP_ADDRESS']), payloads):
                source = f'use32\norg 0x{origin:X}\n'+''.join(f'{k}=0x{value:X}\n' for k,value in v.items())+script
                asm, binary = Path(temp)/'payload.asm', Path(temp)/'payload.bin'
                asm.write_text(source, encoding='ascii')
                subprocess.run([os.environ['FASM_EXE'], str(asm), str(binary)], check=True, capture_output=True)
                cls.code.append((origin, binary.read_bytes()))

    def run_queue(self, clock_step, diagnostics, populated=True, resume=False, radius_after=None):
        v = self.v
        vm = Uc(UC_ARCH_X86, UC_MODE_32)
        vm.mem_map(0x100000, 0x20000)
        vm.mem_map(0x200000, 0x400000)
        vm.mem_map(0x700000, 0x10000)
        for origin, code in self.code: vm.mem_write(origin, code)
        vm.mem_write(v['PROCESS_DAMAGE_ADDRESS'], b'\xC2\x20\x00')
        vm.mem_write(v['UPDATE_WALK_ADDRESS'], b'\xC2\x0C\x00')
        vm.mem_write(v['REPORT_PAD_ADDRESS'], b'\xC3')
        def word(at, value): vm.mem_write(at, struct.pack('<I', value & 0xFFFFFFFF))
        def read(at): return struct.unpack('<I', vm.mem_read(at, 4))[0]
        for y in range(400): word(v['ROW_TABLE_ADDRESS']+y*12, y*400)
        for y in range(2, 11):
            for x in range(2, 11):
                tile = y*400+x
                vm.mem_write(v['LIVE_HEIGHT_ADDRESS']+tile, b'\x02')
                if populated: vm.mem_write(v['BUILDING_TILE_ADDRESS']+tile*2, b'\x01\x00')
        word(v['SPEED_ADDRESS'], 2)
        word(v['RADIUS_ADDRESS'], 2)
        word(v['SPREAD_DAMAGE_ADDRESS'], 60)
        word(v['DIAGNOSTICS_ADDRESS'], diagnostics)
        word(v['QUEUE_COUNT_ADDRESS'], 2)
        for i, xy in enumerate((4, 8)):
            for field, value in enumerate((xy*400+xy, xy, xy, 8 << 8)):
                word(v['QUEUE_ADDRESS']+i*16+field*4, value)
        damage, walks, frames, clock = [], [], [], 0
        def instruction(uc, address, size, _):
            nonlocal clock
            stack = uc.reg_read(UC_X86_REG_ESP)
            if address == v['RETURN_ADDRESS']: uc.emu_stop()
            elif address == v['PROCESS_DAMAGE_ADDRESS']: damage.append(tuple(read(stack+4+i*4) for i in range(8)))
            elif address == v['UPDATE_WALK_ADDRESS']: walks.append(tuple(read(stack+4+i*4) for i in range(3)))
            elif bytes(uc.mem_read(address, 2)) == b'\x0F\x31':
                clock += clock_step
                uc.reg_write(UC_X86_REG_EAX, clock & 0xFFFFFFFF)
                uc.reg_write(UC_X86_REG_EDX, (clock >> 32) & 0xFFFFFFFF)
                uc.reg_write(UC_X86_REG_EIP, address+2)
        vm.hook_add(UC_HOOK_CODE, instruction)
        state_names = ('QUEUE_COUNT','STEP_ACTIVE','STEP_TILE','STEP_X','STEP_Y','STEP_FLAGS','STEP_DX','STEP_DY',
                       'STEP_RADIUS')
        for tick in range(40):
            before = len(damage)
            vm.reg_write(UC_X86_REG_ESP, 0x70FFF0)
            vm.reg_write(UC_X86_REG_ECX, 0x12345678)
            vm.emu_start(0x100000, v['RETURN_ADDRESS']+1, count=100000)
            self.assertEqual(vm.reg_read(UC_X86_REG_EIP), v['RETURN_ADDRESS'])
            self.assertEqual(vm.reg_read(UC_X86_REG_ECX), 0x12345678)
            self.assertLessEqual(len(damage)-before, 2)
            current = tuple(read(v[name+'_ADDRESS']) for name in state_names)
            frames.append((current, tuple(damage), tuple(walks)))
            if resume and tick == 2:
                # Model exact persisted state restoration after unrelated progress:
                # only queue + STEP_* survive, diagnostic/scratch values do not.
                for name in names_for_scratch(v): word(v[name], 0)
                for name, value in zip(state_names, current): word(v[name+'_ADDRESS'], value)
                # The loading setup may use another spread radius.
                if radius_after is not None: word(v['RADIUS_ADDRESS'], radius_after)
            if current[:2] == (0, 0): break
        else: self.fail('queue failed to drain')
        if radius_after is None:
            self.assertEqual(len(damage), 50 if populated else 0)
        self.assertEqual(len(walks), 2)
        # Deferred damage no longer owns terrain repair or lowers neighbouring
        # active tunnels. Discarding this queue cannot strand a terrain change.
        self.assertEqual(bytes(vm.mem_read(v['LIVE_HEIGHT_ADDRESS']+4*400+4, 1)), b'\x02')
        return frames

    def test_changed_radius_applies_from_next_tile(self):
        expected = self.run_queue(100, 0)[-1][1]
        damage = self.run_queue(100, 0, resume=True, radius_after=0)[-1][1]
        # The partial tile at (8, 8) still completes its 5x5 spread; the next
        # queued tile at (4, 4) uses the loaded radius 0: only its own tile.
        self.assertEqual(damage[:25], expected[:25])
        self.assertEqual([call[1:3] for call in damage[25:]], [(4, 4)])

    def test_clock_diagnostics_and_partial_work(self):
        expected = self.run_queue(100, 0)
        self.assertGreater(len(expected), 2)  # Mid-tile suspension really occurs.
        for step in (1, 10_000_000, 2**42):
            for diagnostics in (0, 1):
                with self.subTest(step=step, diagnostics=diagnostics):
                    self.assertEqual(self.run_queue(step, diagnostics, resume=True), expected)

    def test_empty_tiles_keep_tile_limit(self):
        self.assertEqual(len(self.run_queue(10_000_000, 1, populated=False)), 1)


@unittest.skipUnless(os.environ.get('FASM_EXE'), 'FASM_EXE not supplied')
class StanceSelectionTests(unittest.TestCase):
    def test_switching_off_returns_hidden_tunnelers_after_digging(self):
        script = LuaRuntime().execute((MODULE/'templates.lua').read_text(encoding='utf-8'))['stance']
        names = sorted(set(re.findall(r'\b[A-Z][A-Z0-9_]+\b', script)))
        v = {name: 0x200000+i*4 for i, name in enumerate(names)}
        v.update(UNIT_STATE=0x300000, UNIT_SELECTABLE=0x300010, UNIT_LOOKING_AROUND=0x300020,
                 RETURN_ADDRESS=0x111000)
        with tempfile.TemporaryDirectory() as temp:
            asm, binary = Path(temp)/'stance.asm', Path(temp)/'stance.bin'
            asm.write_text('use32\norg 0x100000\n'+''.join(f'{k}=0x{value:X}\n' for k, value in v.items())
                           + script, encoding='ascii')
            subprocess.run([os.environ['FASM_EXE'], str(asm), str(binary)], check=True, capture_output=True)
            code = binary.read_bytes()
        unit = 2*1168  # The current unit's fields, as UNIT_* + index * 1168.
        for hide in (1, 0):
            for state in (3, 4, 8, 9, 0, 1, 5, 0x65):
                for before in (0, 1, 7):
                    vm = Uc(UC_ARCH_X86, UC_MODE_32)
                    vm.mem_map(0x100000, 0x20000)
                    vm.mem_map(0x200000, 0x200000)
                    vm.mem_map(0x700000, 0x10000)
                    vm.mem_write(0x100000, code)
                    vm.mem_write(v['CURRENT_UNIT_ADDRESS'], struct.pack('<I', 2))
                    vm.mem_write(v['HIDE_ENABLED_ADDRESS'], struct.pack('<I', hide))
                    vm.mem_write(v['UNIT_STATE']+unit, struct.pack('<H', state))
                    vm.mem_write(v['UNIT_SELECTABLE']+unit, struct.pack('<H', before))
                    vm.reg_write(UC_X86_REG_ESP, 0x70FFF0)
                    vm.reg_write(UC_X86_REG_ECX, 0x12345678)
                    vm.emu_start(0x100000, v['RETURN_ADDRESS'], count=200)
                    after = struct.unpack('<H', vm.mem_read(v['UNIT_SELECTABLE']+unit, 2))[0]
                    digging = state in (3, 4, 8, 9)
                    # ON is unchanged. OFF leaves digging tunnelers and the game's own
                    # non-zero values alone, and only shows one that ON had hidden.
                    want = (0 if digging else 1) if hide else (before if digging or before else 1)
                    with self.subTest(hide=hide, state=state, before=before):
                        self.assertEqual(after, want)
                        self.assertEqual(vm.reg_read(UC_X86_REG_EIP), v['RETURN_ADDRESS'])
                        self.assertEqual(struct.unpack('<I', vm.mem_read(0x70FFF0-4, 4))[0], 0x12345678)


@unittest.skipUnless(os.environ.get('FASM_EXE') and os.environ.get('SHC_GAME_DIR'),
                     'FASM_EXE and licensed fixtures required')
class InitPayloadTests(unittest.TestCase):
    def test_init_assembles_collapse_payloads_with_their_own_radius(self):
        import json
        from unittest.mock import patch
        import harness
        from shc import Exe
        root = Path(os.environ['SHC_GAME_DIR'])
        fixtures = [root/'Stronghold Crusader.exe', root/'Stronghold_Crusader_Extreme.exe']
        if os.environ.get('SHC_FIXTURE_MATRIX'):
            fixtures += [Path(os.environ['SHC_WORKSPACE'])/item['file'] for item in
                         json.loads(Path(os.environ['SHC_FIXTURE_MATRIX']).read_text())]
        for fixture in fixtures:
            seen = {}
            def assemble(host, script, values):
                script = script.decode()
                values = {k.decode(): int(v) & 0xFFFFFFFF for k, v in values.items()}
                name = 'tick' if 'tick_next:' in script else 'step' if 'step_next:' in script else None
                if name is None: return host.allocate(16)
                with tempfile.TemporaryDirectory() as temp:
                    asm, binary = Path(temp)/'payload.asm', Path(temp)/'payload.bin'
                    asm.write_text('use32\norg 0x10000000\n' + ''.join(
                        f'{k}=0x{value:X}\n' for k, value in values.items()) + script, encoding='ascii')
                    # FASM refuses any symbol init.lua does not supply.
                    subprocess.run([os.environ['FASM_EXE'], str(asm), str(binary)], check=True, capture_output=True)
                seen[name] = values
                return host.allocate(16)
            with self.subTest(fixture=fixture.name), patch.object(harness, 'exe', return_value=Exe(str(fixture))), \
                    patch.object(harness.Host, 'allocate_assembly', assemble):
                control = harness.Host().mod[b'control']
                self.assertEqual(seen['tick']['STEP_RADIUS_ADDRESS'], control + 0x2CC)
                self.assertEqual(seen['tick']['RADIUS_ADDRESS'], control + 0xC4)
                self.assertEqual(seen['step']['STEP_RADIUS_ADDRESS'], control + 0x2CC)
                self.assertNotIn('RADIUS_ADDRESS', seen['step'])


def names_for_scratch(values):
    return [name for name in values if name.startswith('SW_') and name.endswith('_ADDRESS')]


if __name__ == '__main__': unittest.main()
