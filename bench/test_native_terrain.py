"""Execute the actual SHC/Extreme brush and coordinate helper in Unicorn.

The module's real Lua resolves/patches each licensed image; FASM compiles the
terrain hook and queue fill. Only downstream path updates are recorded stubs.
This does not simulate the editor, rendering, complete pathfinding or gameplay.
"""
import copy
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
from unicorn.x86_const import UC_X86_REG_ESP, UC_X86_REG_ECX, UC_X86_REG_EIP


@unittest.skipUnless(os.environ.get('SHC_GAME_DIR') and os.environ.get('FASM_EXE'),
                     'licensed fixtures and FASM_EXE required')
class NativeTerrainTests(unittest.TestCase):
    def host(self, fixture, enabled=True):
        import harness
        from shc import Exe
        self.payloads = {}
        def assemble(host, script, values):
            script = script.decode()
            values = {k.decode(): int(v) for k, v in values.items()}
            if not any(key in values for key in ('UPDATE_ADDRESS','TERRAIN_BRUSH_ADDRESS')):
                return host.allocate(16)
            address = host.allocate(2048)
            with tempfile.TemporaryDirectory() as temp:
                asm, out = Path(temp)/'code.asm', Path(temp)/'code.bin'
                asm.write_text(f'use32\norg {address}\n' + ''.join(
                    f'{k}=0x{v & 0xFFFFFFFF:X}\n' for k, v in values.items()) + script)
                subprocess.run([os.environ['FASM_EXE'], str(asm), str(out)],
                               check=True, capture_output=True)
                code = out.read_bytes()
                self.assertLess(len(code), 2048)
                host.m.write(address, code)
            name = 'fill' if 'fill_loop:' in script else 'restore' if 'restore_original:' in script else 'path'
            self.payloads[name] = (address, values)
            return address
        with patch.object(harness, 'exe', return_value=Exe(str(fixture))), \
                patch.object(harness.Host, 'allocate_assembly', assemble):
            host = harness.Host(config={'terrain': {'enabled': enabled}})
        self.assertIn('fill', self.payloads, host.logs)
        self.assertEqual('restore' in self.payloads, enabled)
        return host

    def world(self, fixture, enabled=True):
        host = self.host(fixture, enabled)
        _, self.v = self.payloads['fill']
        v = self.v
        pe = pefile.PE(str(fixture))
        vm = self.vm = Uc(UC_ARCH_X86, UC_MODE_32)
        vm.mem_map(pe.OPTIONAL_HEADER.ImageBase, (pe.OPTIONAL_HEADER.SizeOfImage+4095)&~4095)
        vm.mem_write(pe.OPTIONAL_HEADER.ImageBase, pe.get_memory_mapped_image())
        vm.mem_map(0x60000000, (host.heap-0x60000000+4095)&~4095)
        vm.mem_map(0x70000000, 0x10000)
        for page, data in host.m.pages.items():
            vm.mem_write(page << 12, bytes(data))
        # A synthetic rectangular coordinate matrix; the native brush's real
        # direction sequence and helper execute unchanged, including all 9 tiles.
        for y in range(400):
            for d in range(8):
                dx = struct.unpack('<i', vm.mem_read(v['X_DELTAS_ADDRESS']+d*8, 4))[0]
                dy = struct.unpack('<i', vm.mem_read(v['Y_DELTAS_ADDRESS']+d*8, 4))[0]
                self.word(v['DIRECTIONS_ADDRESS']+y*32+d*4, dx+dy*100)
        self.brush = v['TERRAIN_BRUSH_ADDRESS']
        def target(at): return at+5+struct.unpack('<i', vm.mem_read(at+1,4))[0]
        self.links, self.walks = target(self.brush+0x84), target(self.brush+0xA6)
        vm.mem_write(self.links, b'\xC2\x08\x00')
        vm.mem_write(self.walks, b'\xC2\x0C\x00')
        self.calls = []
        def record(uc, at, size, _):
            if at in (self.links, self.walks):
                count = 2 if at == self.links else 3
                self.calls.append((at, tuple(self.read(uc.reg_read(UC_X86_REG_ESP)+4+i*4)
                                            for i in range(count))))
        vm.hook_add(UC_HOOK_CODE, record)
        return host

    def word(self, at, value): self.vm.mem_write(at, struct.pack('<I', value & 0xFFFFFFFF))
    def read(self, at): return struct.unpack('<I', self.vm.mem_read(at, 4))[0]

    def call(self, at, args=(), this=0):
        sp, end = 0x7000F000, 0x7000FF00
        self.word(sp, end)
        for i, value in enumerate(args): self.word(sp+4+i*4, value)
        self.vm.reg_write(UC_X86_REG_ESP, sp)
        self.vm.reg_write(UC_X86_REG_ECX, this)
        self.vm.emu_start(at, end, count=500000)
        self.assertEqual(self.vm.reg_read(UC_X86_REG_EIP), end)
        self.assertEqual(self.vm.reg_read(UC_X86_REG_ESP), sp+4+4*len(args))

    def brush_at(self, tile, x, y, increment):
        self.call(self.brush, (tile,x,y,increment), self.v['TILE_MAP_STATE_ADDRESS'])

    def heights(self): return bytes(self.vm.mem_read(self.v['LIVE_HEIGHT_ADDRESS'], 80400))

    def fixtures(self):
        root = Path(os.environ['SHC_GAME_DIR'])
        fixtures = [root/'Stronghold Crusader.exe', root/'Stronghold_Crusader_Extreme.exe']
        if os.environ.get('SHC_FIXTURE_MATRIX'):
            fixtures += [Path(os.environ['SHC_WORKSPACE'])/item['file'] for item in
                         json.loads(Path(os.environ['SHC_FIXTURE_MATRIX']).read_text())]
        return fixtures

    def test_real_brush_restores_footprint_and_preserves_digging_and_exclusions(self):
        for fixture in self.fixtures():
            with self.subTest(fixture=str(fixture)):
                self.world(fixture)
                v = self.v
                baseline = bytes(i % 15 for i in range(80400))
                self.vm.mem_write(v['BASE_HEIGHT_ADDRESS'], baseline)
                self.vm.mem_write(v['LIVE_HEIGHT_ADDRESS'], baseline)
                self.brush_at(5050,50,50,1)
                raised = self.heights()
                footprint = [i for i in range(80400) if baseline[i] != raised[i]]
                self.assertEqual(len(footprint), 9)
                positive_calls = list(self.calls)
                self.assertEqual(len(positive_calls), 10)
                # Regression witness: 1.7.1's center-only assignment leaves 8.
                self.vm.mem_write(v['LIVE_HEIGHT_ADDRESS']+5050, baseline[5050:5051])
                self.assertEqual(sum(a != b for a,b in zip(self.heights(),baseline)), 8)
                self.brush_at(5050,50,50,-2)
                self.assertEqual(self.heights(), baseline)
                # Repeated/overlapping completed footprints are idempotent.
                self.brush_at(5051,51,50,1)
                self.brush_at(5050,50,50,1)
                self.brush_at(5050,50,50,-2)
                self.brush_at(5051,51,50,-2)
                self.assertEqual(self.heights(), baseline)
                # Every native exclusion, plus stairs/crenellations: never lower
                # a wall's height/HP or terrain under a building.
                for flag in (1,0x10,0x20,0x80,0x100,0x200,0x400,0x800,
                             0x100000,0x200000,0x10000000,0x20000000,0x40000000):
                    self.word(v['TILE_FLAGS_ADDRESS']+5050*4, flag)
                    self.vm.mem_write(v['LIVE_HEIGHT_ADDRESS']+5050, b'\x0F')
                    self.brush_at(5050,50,50,-2)
                    self.assertEqual(self.heights()[5050],15, hex(flag))
                self.word(v['TILE_FLAGS_ADDRESS']+5050*4, 0)
                self.vm.mem_write(v['BUILDING_TILE_ADDRESS']+5050*2,b'\x01\x00')
                self.brush_at(5050,50,50,-2)
                self.assertEqual(self.heights()[5050],15)
                # OFF keeps native digging and native subtract-two behavior.
                self.world(fixture, enabled=False)
                self.vm.mem_write(self.v['BASE_HEIGHT_ADDRESS'],baseline)
                self.vm.mem_write(self.v['LIVE_HEIGHT_ADDRESS'],baseline)
                self.brush_at(5050,50,50,1)
                self.assertEqual(self.heights(),raised)
                self.assertEqual(self.calls,positive_calls)
                self.brush_at(5050,50,50,-2)
                self.assertNotEqual(self.heights(),baseline)

    def test_full_damage_queue_still_restores_native_footprint(self):
        for fixture in self.fixtures():
            for full in (False,True):
                with self.subTest(fixture=str(fixture),full=full):
                    self.world(fixture)
                    v = self.v
                    baseline = b'\x05'*80400
                    self.vm.mem_write(v['BASE_HEIGHT_ADDRESS'],baseline)
                    self.vm.mem_write(v['LIVE_HEIGHT_ADDRESS'],baseline)
                    for x in range(50,54): self.brush_at(5000+x,x,50,1)
                    self.word(v['FILL_UNIT_ADDRESS'],1)
                    self.word(v['FILL_FLAGS_ADDRESS'],1)
                    self.word(v['QUEUE_COUNT_ADDRESS'],512 if full else 0)
                    self.vm.mem_write(v['UNIT_PATH_LENGTH']+1168,struct.pack('<H',4))
                    self.vm.mem_write(v['UNIT_LADDER_X']+1168,struct.pack('<h',50))
                    self.vm.mem_write(v['UNIT_LADDER_Y']+1168,struct.pack('<h',50))
                    self.word(v['UNIT_PREVIOUS_TILE']+1168,5050)
                    east = next(d for d in range(8) if self.read(v['X_DELTAS_ADDRESS']+d*8)==1
                                and self.read(v['Y_DELTAS_ADDRESS']+d*8)==0)
                    self.vm.mem_write(v['UNIT_PATH_PLAN']+1168,bytes([east | (east<<4)])*2)
                    self.call(self.payloads['fill'][0])
                    self.assertEqual(self.heights(),baseline)
                    self.assertEqual(self.read(v['QUEUE_COUNT_ADDRESS']),512 if full else 4)

    def test_building_center_and_native_death_cleanup(self):
        for fixture in self.fixtures():
            for native_walk in (False,True):
                with self.subTest(fixture=str(fixture),native_walk=native_walk):
                    host = self.world(fixture)
                    v = self.v
                    baseline = b'\x05'*80400
                    self.vm.mem_write(v['BASE_HEIGHT_ADDRESS'],baseline)
                    self.vm.mem_write(v['LIVE_HEIGHT_ADDRESS'],baseline)
                    self.vm.mem_write(v['BUILDING_TILE_ADDRESS']+5050*2,b'\x01\x00')
                    self.brush_at(5050,50,50,1)
                    self.assertEqual(sum(a!=b for a,b in zip(self.heights(),baseline)),8)
                    self.word(v['FILL_UNIT_ADDRESS'],1)
                    self.word(v['FILL_FLAGS_ADDRESS'],1)
                    self.vm.mem_write(v['UNIT_PATH_LENGTH']+1168,struct.pack('<H',1))
                    self.vm.mem_write(v['UNIT_LADDER_X']+1168,struct.pack('<h',50))
                    self.vm.mem_write(v['UNIT_LADDER_Y']+1168,struct.pack('<h',50))
                    self.word(v['UNIT_PREVIOUS_TILE']+1168,5050)
                    if native_walk:
                        # The real native walk, also used by destruction callers.
                        update = host.E.find('51 8B 0D ? ? ? ? 8B C1 69 C0 90 04 00 00 53 55')[0]
                        walk = update+0x926+5+host.E.i32(update+0x927)
                        damage = walk+0x9B+5+host.E.i32(walk+0x9C)
                        self.vm.mem_write(damage,b'\xC2\x20\x00')
                        self.call(walk,(1,),v['UNIT_PATH_LENGTH']-0x710)
                    else:
                        self.call(self.payloads['fill'][0])
                    self.assertEqual(self.heights(),baseline)

    def test_changed_or_occupied_brush_is_not_patched(self):
        import harness
        from shc import Exe
        for fixture in self.fixtures()[:2]:
            self.world(fixture)
            for offset in (0x51,0x31,0xAF,0xA2):
                changed = Exe(str(fixture))
                raw = bytearray(changed.data)
                raw[changed.va2off(self.brush)+offset] ^= 0x01
                changed.data = bytes(raw)
                with patch.object(harness,'exe',return_value=changed), \
                        patch.object(harness.Host,'allocate_assembly',lambda h,*_: h.allocate(16)):
                    host = harness.Host()
                self.assertFalse(any(at==self.brush+0x51 for at,data in host.patched))
                self.assertTrue(any('terrain brush' in s for s in host.logs))


if __name__ == '__main__': unittest.main()
