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

    def run_queue(self, clock_step, diagnostics, populated=True, resume=False):
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
        state_names = ('QUEUE_COUNT','STEP_ACTIVE','STEP_TILE','STEP_X','STEP_Y','STEP_FLAGS','STEP_DX','STEP_DY')
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
            if current[:2] == (0, 0): break
        else: self.fail('queue failed to drain')
        self.assertEqual(len(damage), 50 if populated else 0)
        self.assertEqual(len(walks), 2)
        # Deferred damage no longer owns terrain repair or lowers neighbouring
        # active tunnels. Discarding this queue cannot strand a terrain change.
        self.assertEqual(bytes(vm.mem_read(v['LIVE_HEIGHT_ADDRESS']+4*400+4, 1)), b'\x02')
        return frames

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
class TerrainOwnershipTests(unittest.TestCase):
    def test_native_terrain_is_repaired_before_path_release_even_with_full_queue(self):
        script = LuaRuntime().execute((MODULE/'templates.lua').read_text(encoding='utf-8'))['queue_fill']
        names = sorted(set(re.findall(r'\b[A-Z][A-Z0-9_]+\b', script)))
        v = {name: 0x200000+i*4 for i, name in enumerate(names)}
        v.update(QUEUE_ADDRESS=0x202000, QUEUE_MAX=512, UPDATE_WALK_ADDRESS=0x110000,
                 DIRECTIONS_ADDRESS=0x220000, X_DELTAS_ADDRESS=0x230000, Y_DELTAS_ADDRESS=0x230004,
                 TILE_FLAGS_ADDRESS=0x300000, BUILDING_TILE_ADDRESS=0x3A0000,
                 BASE_HEIGHT_ADDRESS=0x440000, LIVE_HEIGHT_ADDRESS=0x470000,
                 UNIT_PATH_LENGTH=0x5000FC, UNIT_PATH_PLAN=0x5000FE,
                 UNIT_LADDER_X=0x500290, UNIT_LADDER_Y=0x500292,
                 UNIT_PREVIOUS_TILE=0x500298, WALL_FAMILY=0xB00)
        with tempfile.TemporaryDirectory() as temp:
            asm, binary = Path(temp)/'fill.asm', Path(temp)/'fill.bin'
            asm.write_text('use32\norg 0x100000\n'+''.join(f'{k}=0x{value:X}\n' for k,value in v.items())+script)
            subprocess.run([os.environ['FASM_EXE'], str(asm), str(binary)], check=True, capture_output=True)
            code = binary.read_bytes()
        for full in (False, True):
            for quiet in (0, 1):
                vm = Uc(UC_ARCH_X86, UC_MODE_32)
                vm.mem_map(0x100000, 0x20000)
                vm.mem_map(0x200000, 0x400000)
                vm.mem_map(0x700000, 0x10000)
                vm.mem_write(0x100000, code)
                # Native THISCALL ABI; clobber every volatile register to ensure
                # fill does not depend on a stub accidentally preserving them.
                vm.mem_write(v['UPDATE_WALK_ADDRESS'], bytes.fromhex('B8 EF BE AD DE B9 EF BE AD DE BA EF BE AD DE C2 0C 00'))
                def word(at, value): vm.mem_write(at, struct.pack('<I', value))
                def read(at): return struct.unpack('<I', vm.mem_read(at, 4))[0]
                unit, start, count = 1168, 1604, 800
                word(v['FILL_UNIT_ADDRESS'], 1)
                word(v['FILL_FLAGS_ADDRESS'], (8 << 8)|quiet)
                word(v['QUEUE_COUNT_ADDRESS'], 512 if full else 0)
                vm.mem_write(unit+v['UNIT_PATH_LENGTH'], struct.pack('<H', count))
                vm.mem_write(unit+v['UNIT_LADDER_X'], struct.pack('<HH', 4, 4))
                word(unit+v['UNIT_PREVIOUS_TILE'], start)
                # A repeated rightwards nibble is enough to exercise the entire
                # native 800-step capacity. Native path update is a recorded stub.
                word(v['DIRECTIONS_ADDRESS']+4*32, 1)
                word(v['X_DELTAS_ADDRESS'], 1)
                word(v['Y_DELTAS_ADDRESS'], 0)
                vm.mem_write(v['BASE_HEIGHT_ADDRESS']+start, b'\x05'*count)
                vm.mem_write(v['LIVE_HEIGHT_ADDRESS']+start, b'\x10'*count)
                word(v['TILE_FLAGS_ADDRESS']+(start+1)*4, 0x100)
                vm.mem_write(v['BUILDING_TILE_ADDRESS']+(start+2)*2, b'\x01\x00')
                vm.mem_write(v['LIVE_HEIGHT_ADDRESS']+start+3, b'\x03')
                vm.mem_write(v['BASE_HEIGHT_ADDRESS']+start+4, b'\x10')
                walks = []
                def instruction(uc, address, size, _):
                    if address == v['UPDATE_WALK_ADDRESS']:
                        self.assertEqual(uc.reg_read(UC_X86_REG_ECX), v['PATH_STATE_ADDRESS'])
                        sp = uc.reg_read(UC_X86_REG_ESP)
                        walks.append(tuple(read(sp+4+i*4) for i in range(3)))
                vm.hook_add(UC_HOOK_CODE, instruction)
                word(0x70FFF0, 0x111000)
                vm.reg_write(UC_X86_REG_ESP, 0x70FFF0)
                vm.emu_start(0x100000, 0x111000, count=100000)
                self.assertEqual(vm.reg_read(UC_X86_REG_EIP), 0x111000)
                self.assertEqual(bytes(vm.mem_read(v['LIVE_HEIGHT_ADDRESS']+start, count)),
                                 b'\x05\x10\x10\x03\x10'+b'\x05'*(count-5))
                self.assertEqual(len(walks), count-4)
                self.assertEqual(walks[0], (1, 4, 4))
                self.assertEqual(walks[-1], (1, 4+count-1, 4))
                self.assertEqual(read(v['QUEUE_COUNT_ADDRESS']), 512)
                if not full:
                    self.assertEqual(read(v['QUEUE_ADDRESS']+12), (8 << 8)|quiet)


def names_for_scratch(values):
    return [name for name in values if name.startswith('SW_') and name.endswith('_ADDRESS')]


if __name__ == '__main__': unittest.main()
