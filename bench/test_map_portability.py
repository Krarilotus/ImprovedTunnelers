"""Run stock SHC/Extreme section dispatch with an unknown Map Extensions section.

No patched game, file IO, editor UI or compression is simulated. The actual native
dispatch and copy routines run in Unicorn against synthetic directory/payload data.
SHC_GAME_DIR supplies the two licensed reference executables. Optionally supply
SHC_FIXTURE_MATRIX (JSON list with file paths) and SHC_WORKSPACE for more fixtures.
This development test is excluded from the module's files.yml.
"""
import json
import os
from pathlib import Path
import re
import struct
import unittest

import capstone
import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32
from unicorn.x86_const import UC_X86_REG_EBX, UC_X86_REG_EDI, UC_X86_REG_ESI, UC_X86_REG_ESP, UC_X86_REG_EIP


def unique(image, pattern):
    regex = b''.join(b'.' if part == '?' else re.escape(bytes([int(part, 16)]))
                     for part in pattern.split())
    matches = list(re.finditer(regex, image, re.S))
    assert len(matches) == 1, (pattern, len(matches))
    return matches[0].start()


@unittest.skipUnless(os.environ.get('SHC_GAME_DIR'), 'SHC_GAME_DIR not supplied')
class MapPortabilityTests(unittest.TestCase):
    def test_stock_dispatch_ignores_unknown_section_without_losing_native_data(self):
        root = Path(os.environ['SHC_GAME_DIR'])
        fixtures = [root/'Stronghold Crusader.exe', root/'Stronghold_Crusader_Extreme.exe']
        if os.environ.get('SHC_FIXTURE_MATRIX'):
            workspace = Path(os.environ['SHC_WORKSPACE'])
            fixtures += [workspace/item['file'] for item in
                         json.loads(Path(os.environ['SHC_FIXTURE_MATRIX']).read_text())]
        for fixture in fixtures:
            with self.subTest(executable=str(fixture)):
                self.check_reader(fixture)

    def check_reader(self, fixture):
        pe = pefile.PE(str(fixture))
        image, base = pe.get_memory_mapped_image(), pe.OPTIONAL_HEADER.ImageBase
        table = unique(image, '? ? ? ? 00 00 00 00 20 74 02 00 01 00 e9 03 '
                       '? ? ? ? 00 00 00 00 20 74 02 00 01 00 09 04 '
                       '? ? ? ? 00 00 00 00 20 74 02 00 01 00 ea 03 '
                       '? ? ? ? 00 00 00 00 40 e8 04 00 01 00 eb 03')
        descriptors = [struct.unpack_from('<IIIHh', image, table+i*16) for i in range(123)]
        self.assertTrue(all(entry[0] for entry in descriptors[:122]))
        self.assertEqual(descriptors[122], (0, 0, 0, 0, 0))
        self.assertNotIn(1337, [entry[-1] for entry in descriptors])

        # Both real layouts use this entry into the section loop. The target of
        # its empty-directory branch is the exit before OS free and audio work.
        entry = unique(image, '39 5E 28 8B 54 24 20 89 5E 0C 89 5E 24 '
                       '89 54 24 20 0F 8E')
        dis = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        branch = next(ins for ins in dis.disasm(image[entry:entry+32], base+entry)
                      if ins.mnemonic == 'jle')
        end = int(branch.op_str, 16)
        obj, payload, stack = 0x60000000, 0x60002000, 0x6000F000
        for unknown_position in (0, 1, 2):
            vm = Uc(UC_ARCH_X86, UC_MODE_32)
            vm.mem_map(base, (pe.OPTIONAL_HEADER.SizeOfImage+4095) & ~4095)
            vm.mem_write(base, image)
            vm.mem_map(obj, 0x10000)
            def word(at, value): vm.mem_write(at, struct.pack('<I', value))
            known = [(descriptors[0][-1], b'FIRST123', descriptors[0][0]),
                     (descriptors[1][-1], b'SECOND45', descriptors[1][0])]
            sections = list(known)
            # Deliberately not a valid compressed stream. A stock reader must
            # never try to decode it, regardless of its position in the file.
            sections.insert(unknown_position, (1337, b'not-a-game-compressed-section', None))
            word(obj+0x10, payload)
            word(obj+0x28, len(sections))
            cursor = 0
            for index, (section_id, data, destination) in enumerate(sections):
                word(obj+0x40+index*4, len(data))
                word(obj+0x4F0+index*4, section_id)
                word(obj+0x748+index*4, int(destination is None))
                word(obj+0x9A0+index*4, cursor)
                vm.mem_write(payload+cursor, data)
                cursor += len(data)
                if destination is not None:
                    vm.mem_write(destination, b'\xCC'*16)
            word(stack+0x20, base+table)
            for reg, value in ((UC_X86_REG_ESI, obj), (UC_X86_REG_ESP, stack),
                               (UC_X86_REG_EBX, 0), (UC_X86_REG_EDI, 0)):
                vm.reg_write(reg, value)
            vm.emu_start(base+entry, end, count=10000)
            self.assertEqual(vm.reg_read(UC_X86_REG_EIP), end)
            self.assertEqual(struct.unpack('<I', vm.mem_read(obj+0xC, 4))[0], 3)
            for _, data, destination in known:
                self.assertEqual(bytes(vm.mem_read(destination, 16)), data+b'\xCC'*8)


if __name__ == '__main__': unittest.main()
