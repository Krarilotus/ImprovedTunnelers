"""Run the retarget hook with the game's REAL functions (no stubs) on a synthetic map.

The map is laid out so tile = y*400 + x, and the direction tables the search and the path
retrace walk are filled from the game's own static delta tables, so the real BFS, the real
path retrace and the real tunnel-damage pass all run.

usage: python test_real_retarget.py [v|e] [trace]
"""
import sys, struct
from test_tunnelers import Fixture, UNIT
from x86emu_t import Halt, MASK
from syms import near

MAPW = 400
SENTINEL = 0x7FFFFFF0
STACK_TOP = 0x70100000


def addr_from(e, va, off):
    return struct.unpack('<I', e.data[e.va2off(va + off):e.va2off(va + off) + 4])[0]


def world(f, wall_at=(116, 100), building_at=None, building_type=0, lo=80, hi=141):
    """A walkable square with tile = y*400 + x, plus one enemy wall or building."""
    h, e = f.h, f.e
    # vanilla addresses; this bench only runs against Stronghold Crusader.exe
    f.row_table = 0x2337300
    f.binary_map = 0x21AEC98
    f.area_map = 0x1DF70D8
    f.wall_owner = 0x1D5A058
    f.y_of_tile = 0x21D5D98
    f.dir_deltas = 0x1A93208
    f.dx_table = 0xB49048
    f.dy_table = 0xB4904C

    for y in range(lo, hi):
        h.put32(f.row_table + 12 * y, y * MAPW)
        for x in range(lo, hi):
            tile = y * MAPW + x
            h.put8(f.binary_map + y * MAPW + x, 1)
            h.put16(f.area_map + 2 * tile, 1)
            h.put16(f.y_of_tile + 2 * tile, y)
    # the four neighbour deltas, per row, in tile units - from the game's own x/y deltas
    for d in range(8):
        dx = struct.unpack('<h', e.data[e.va2off(f.dx_table + 8 * d):e.va2off(f.dx_table + 8 * d) + 2])[0]
        dy = struct.unpack('<h', e.data[e.va2off(f.dy_table + 8 * d):e.va2off(f.dy_table + 8 * d) + 2])[0]
        for y in range(0, 400):
            h.put32(f.dir_deltas + 32 * y + 4 * d, (dx + dy * MAPW) & MASK)
    if wall_at:
        tile = wall_at[1] * MAPW + wall_at[0]
        h.put32(f.tile_flags + 4 * tile, 0x100)
        h.put8(f.wall_owner + tile, 1)                     # (1 & 7) + 1 = player 2
    if building_at:
        tile = building_at[1] * MAPW + building_at[0]
        h.put16(f.building_tiles + 2 * tile, 40)           # building slot 40
        bld = f.building_base + 40 * 0x32C
        h.put16(bld + 0xD2, building_type)                 # buildingType
        h.put16(bld + 0xD6, 2)                             # owner: player 2
    h.put32(f.teams + 4 * 1, 1)
    h.put32(f.teams + 4 * 2, 2)


def run_hook(f, unit=11, limit=40_000_000, watch=True):
    """Enter the arrival hook the way UpdateTunneler would: five saved registers and a
    return address on the stack."""
    h = f.h
    cpu = h.cpu
    cpu.r['esp'] = STACK_TOP
    cpu.push(SENTINEL)                 # the caller's return address
    for _ in range(5):                 # ecx, ebx, ebp, esi, edi as the prologue pushed them
        cpu.push(0)
    cpu.r['ebx'] = 0                   # the function keeps zero here
    cpu.r['esi'] = unit * UNIT
    cpu.eip = f.tunneler + 0x7E6
    strays = []
    original = h.m.write

    def guarded(address, data):
        if watch and (address & MASK) < 0x400000:
            strays.append((address, len(data)))
        return original(address, data)
    h.m.write = guarded
    try:
        cpu.run(SENTINEL, limit)
        result = 'returned'
    except Halt as ex:
        result = 'HALT: %s at %08X (%s)' % (ex, cpu.eip, describe(cpu.eip))
    finally:
        h.m.write = original
    return result, strays


def describe(va):
    n = near(va)
    return '%s+0x%X' % (n[1][0], va - n[0]) if n else '?'


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else 'v'
    f = Fixture(which == 'e')
    h, e = f.h, f.e
    f.building_base = 0xF98534

    world(f)
    unit = 11
    h.put32(f.current_unit, unit)
    f.set_unit(unit, owner=1, x=100, y=100, tile=100 * MAPW + 100, uid=777, siege=0, state=3)
    h.put16(f.unit(unit) + 0x8E, 5)      # unitType = tunneler

    # the stretch it has just dug: eight steps east from (100,100) to (108,100)
    STEPS = 8
    EAST = 2
    f.set_unit(unit, x=108, y=100, tile=100 * MAPW + 108)
    h.put16(f.unit(unit) + 0xCC, 100)                    # ladderExitX: where the path began
    h.put16(f.unit(unit) + 0xCE, 100)                    # ladderExitY
    h.put32(f.unit(unit) + 0xDC, 100 * MAPW + 100)       # previousTilePosition
    h.put16(f.unit(unit) + 0xFC, STEPS)                  # totalSizeOfPathPlan
    h.put16(f.unit(unit) + 0xFA, STEPS)                  # currentIndexInPathPlan
    for i in range(0, STEPS, 2):
        h.put8(f.unit(unit) + 0xFE + i // 2, EAST | (EAST << 4))
    # something standing over the tunnel, to make the damage pass do real work
    over = 100 * MAPW + 104
    h.put16(f.building_tiles + 2 * over, 41)
    h.put16(f.building_base + 41 * 0x32C + 0xD0, 1)      # logicalState: alive
    h.put16(f.building_base + 41 * 0x32C + 0xD2, 20)     # some ordinary building type
    h.put16(f.building_base + 41 * 0x32C + 0xD6, 2)      # owner
    h.put16(f.building_base + 41 * 0x32C + 0xEE, 104)    # x
    h.put16(f.building_base + 41 * 0x32C + 0xF0, 100)    # y
    h.put32(f.ticks, 5000)

    print('running the retarget with the real game functions ...')
    result, strays = run_hook(f)
    print('result: %s' % result)
    print('state now %d, movement %d, path length %d, dest (%d,%d)' % (
        struct.unpack('<H', h.m.read(f.unit(unit) + 0x2C0, 2))[0],
        struct.unpack('<H', h.m.read(f.unit(unit) + 0xF6, 2))[0],
        struct.unpack('<h', h.m.read(f.unit(unit) + 0xFC, 2))[0],
        struct.unpack('<h', h.m.read(f.unit(unit) + 0xC8, 2))[0],
        struct.unpack('<h', h.m.read(f.unit(unit) + 0xCA, 2))[0]))
    print('search result tile %d, target (%d, %d)' % (
        h.u32(f.alg_result), h.u32(f.alg_x), h.u32(f.alg_y)))
    if strays:
        print('WRITES BELOW THE IMAGE BASE: %d, first at %08X' % (len(strays), strays[0][0]))
    else:
        print('no writes below the image base')


if __name__ == '__main__':
    main()
