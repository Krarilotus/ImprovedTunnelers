"""Disassemble the game code behind AI raids and troop orders, for working out how raid
tunnellers can march with their troop.

usage: python tools/dump_raid_code.py "<path to Stronghold Crusader.exe>" [out.txt]

Needs pefile and capstone (the bench has both). Uses the vanilla executable: the addresses
come from bench/syms.pkl, which names OpenSHC's reverse-engineered functions for it. Every
function listed below is written out whole, and so is every function it calls directly
(one level deep), with calls and known globals labelled by name.
"""
import os, pickle, re, struct, sys

import capstone
import pefile

HERE = os.path.dirname(os.path.abspath(__file__))
SYMS = os.path.join(HERE, '..', 'bench', 'syms.pkl')

# What the raid is made of: the AI's orders, the troop code they go through, and the
# tunneller's own update, which is what has to act on them.
ROOTS = [
    'aiGiveRaidInstructions', 'checkTribeActivityPercentages', 'getDefensiveTribeForUnit',
    'aiAssignUnitToDefensiveTribe', 'aiRecruitUnits', 'giveSomeRaidCommand',
    'canNavigateUnitsFromTileToTargetTile', 'sendUnitsToCampfire',
    'moveAttackTribesToLocations', 'giveMoveCommandToAttackTribes', 'sendTribeToAttack',
    'percentageNonMovingTribesGTEAICSpecified', 'useAITribe_0xe_toPlaceTunnels',
    'aiReassignTunnelersToTribe', 'addUnitToItsTribe', 'addUnitToSmallestBehaviourTypeTribe',
    'isTribeFreeOfTunnelingUnits', 'commandUnitsToLocation', 'giveTribeMoveInstruction',
    'giveTribeAnInstruction', 'moveUnitToBehaviorTarget', 'applyTribeBehaviorType',
    'addUnitToTribe', 'addUnitToTribeAndUpdateTribeMovementSpeed',
    'relayTribeInstruction', 'giveTribeMoveInstructionHumans', 'UpdateTunneler',
]
UPDATE_TUNNELER_AOB = bytes.fromhex('518B0D')        # push ecx; mov ecx, [current unit]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else 'raid-code.txt'

    syms = pickle.load(open(SYMS, 'rb'))
    functions = sorted((va, v[0]) for va, v in syms.items()
                       if isinstance(va, int) and va >= 0x401000 and v[2] == 'function')
    data_names = {va: v[0] for va, v in syms.items()
                  if isinstance(va, int) and va >= 0x401000 and v[2] != 'function'}
    by_name = {}
    for va, name in functions:
        by_name.setdefault(name, va)
    starts = [va for va, _ in functions]
    names = dict(functions)

    pe = pefile.PE(path, fast_load=True)
    blob = open(path, 'rb').read()
    base = pe.OPTIONAL_HEADER.ImageBase
    sections = [(s.VirtualAddress + base, s.SizeOfRawData, s.PointerToRawData)
                for s in pe.sections]

    def offset(va):
        for start, size, raw in sections:
            if start <= va < start + size:
                return raw + va - start
        return None

    tunneler = by_name['UpdateTunneler']
    if blob[offset(tunneler):offset(tunneler) + 3] != UPDATE_TUNNELER_AOB:
        print('This does not look like the executable the symbols are for (UpdateTunneler '
              'is not at 0x%X). Pass the vanilla Stronghold Crusader.exe.' % tunneler)
        return 1

    def end_of(va):
        later = [s for s in starts if s > va]
        return min(later) if later else va + 0x400

    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    md.skipdata = True

    def label(value):
        if value in names:
            return names[value]
        if value in data_names:
            return data_names[value]
        return None

    def disassemble(va):
        end = min(end_of(va), va + 0x3000)
        o = offset(va)
        lines, callees = [], []
        for ins in md.disasm(blob[o:o + (end - va)], va):
            text = '%08X  %-24s %s %s' % (ins.address, ins.bytes.hex(' '), ins.mnemonic,
                                         ins.op_str)
            notes = []
            if ins.mnemonic == 'call' and ins.op_str.startswith('0x'):
                target = int(ins.op_str, 16)
                callees.append(target)
                notes.append(label(target) or 'sub_%X' % target)
            for word in re.findall(r'0x[0-9a-f]{6,8}', ins.op_str):
                name = label(int(word, 16))
                if name and name not in notes:
                    notes.append(name)
            if notes:
                text += '    ; ' + ', '.join(notes)
            lines.append(text)
        return lines, callees

    done, order = set(), []
    queue = [by_name[n] for n in ROOTS if n in by_name]
    missing = [n for n in ROOTS if n not in by_name]
    roots = set(queue)
    for va in queue:
        if va in done:
            continue
        done.add(va)
        lines, callees = disassemble(va)
        order.append((va, lines))
        if va in roots:
            queue.extend(c for c in callees if c in names and c not in done)

    # Every call of the tunnelling-unit test, wherever it is.
    free_test = by_name.get('isTribeFreeOfTunnelingUnits')
    callers = []
    if free_test:
        for start, size, raw in sections:
            chunk = blob[raw:raw + size]
            for m in re.finditer(b'\xE8', chunk):
                i = m.start()
                rel = struct.unpack('<i', chunk[i + 1:i + 5])[0] if i + 5 <= len(chunk) else 0
                if start + i + 5 + rel == free_test:
                    callers.append(start + i)

    with open(out_path, 'w') as out:
        out.write('# %s\n' % os.path.basename(path))
        if missing:
            out.write('# not in the symbols: %s\n' % ', '.join(missing))
        out.write('# calls of isTribeFreeOfTunnelingUnits: %s\n\n' % ', '.join(
            '0x%X (in %s)' % (c, names.get(max(s for s in starts if s <= c), '?'))
            for c in callers))
        for va, lines in order:
            out.write('==== %s 0x%X\n' % (names.get(va, 'sub_%X' % va), va))
            out.write('\n'.join(lines))
            out.write('\n\n')
    print('wrote %d functions to %s' % (len(order), out_path))
    return 0


if __name__ == '__main__':
    sys.exit(main())
