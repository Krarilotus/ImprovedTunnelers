"""End to end, with the game's real code: a tunnel arrives under a wall that has gone and
the module sends it at the next wall from where it stands, with the game's own target
search and path finder - and a tunnel that collapses does the same for every other tunnel
of that player aimed at the same spot.

Vanilla executable only - the synthetic map uses vanilla addresses.

usage: python test_real_handoff.py
"""
import struct
from test_tunnelers import Fixture, UNIT, check, FAILURES
from test_real_retarget import world, MAPW, SENTINEL, STACK_TOP
from x86emu_t import Halt, MASK
from syms import near


def run_at(f, eip, unit, limit=40_000_000, esi=None):
    """Enter somewhere inside UpdateTunneler the way the function itself would be entered."""
    h = f.h
    cpu = h.cpu
    cpu.r['esp'] = STACK_TOP
    cpu.push(SENTINEL)
    for _ in range(5):
        cpu.push(0)
    cpu.r['ebx'] = 0
    cpu.r['esi'] = esi if esi is not None else unit * UNIT
    cpu.eip = eip
    strays = []
    original = h.m.write

    def guarded(address, data):
        if (address & MASK) < 0x400000:
            strays.append((address, len(data)))
        return original(address, data)
    h.m.write = guarded
    try:
        cpu.run(SENTINEL, limit)
        result = 'returned'
    except Halt as ex:
        n = near(cpu.eip)
        result = 'HALT %s at %08X (%s)' % (ex, cpu.eip, n[1][0] if n else '?')
    finally:
        h.m.write = original
    return result, strays


def run_whole_function(f, unit, limit=40_000_000):
    """UpdateTunneler from its first instruction, as updateUnits calls it."""
    h = f.h
    cpu = h.cpu
    cpu.r['esp'] = STACK_TOP
    cpu.push(SENTINEL)
    cpu.eip = f.tunneler
    strays = []
    original = h.m.write

    def guarded(address, data):
        if (address & MASK) < 0x400000:
            strays.append((address, len(data)))
        return original(address, data)
    h.m.write = guarded
    try:
        cpu.run(SENTINEL, limit)
        result = 'returned'
    except Halt as ex:
        n = near(cpu.eip)
        result = 'HALT %s at %08X (%s)' % (ex, cpu.eip, n[1][0] if n else '?')
    finally:
        h.m.write = original
    return result, strays


def word(f, unit, off):
    return struct.unpack('<h', f.h.m.read(f.unit(unit) + off, 2))[0]


def dig(f, unit, x, y, steps=8, east=2):
    """A tunneler standing at x,y that has dug its way there from (100,100)."""
    h = f.h
    h.put16(f.unit(unit) + 0xCC, 100)                     # where the tunnel started
    h.put16(f.unit(unit) + 0xCE, 100)
    h.put32(f.unit(unit) + 0xDC, 100 * MAPW + 100)
    h.put16(f.unit(unit) + 0xFC, steps)
    h.put16(f.unit(unit) + 0xFA, steps)
    for i in range(0, steps, 2):
        h.put8(f.unit(unit) + 0xFE + i // 2, east | (east << 4))
    f.set_unit(unit, owner=1, x=x, y=y, tile=y * MAPW + x, siege=2, state=3,
               kind=5, alive=2, dying=0, dest_x=x, dest_y=y)


def main():
    # collapse-behind off: filling a tunnel in makes the game rebuild the whole path layer,
    # which is a second of emulator time and nothing to do with what is being tested here
    f = Fixture(False, config={'retarget': {'collapse_behind': False}})
    h = f.h
    world(f, wall_at=(116, 100))
    # filling the tunnel back in makes the game rebuild the walk and path layer for the whole
    # map - a second of emulator time per tile and nothing to do with what is tested here,
    # which is the search and the path finder. test_tunnelers covers the fill itself.
    h.stub(f.apply_damage, 0, 4)

    unit, second = 11, 12
    h.put32(f.current_unit, unit)
    h.put32(f.units_state, 40)
    dig(f, unit, 108, 100, steps=8)
    h.put32(f.unit(unit) + 0x98, 777)                     # uid
    h.put32(f.ticks, 5000)

    print('1. the tunnel arrives where its wall used to be')
    result, strays = run_at(f, f.tunneler + 0x7E6, unit)
    check('the hook returns cleanly', result, 'returned')
    check('the tunneler is still digging', f.unit_field(unit, 'state'), 3)
    check('the game found the next wall', h.u32(f.alg_result) != 0, True)
    check('  which is the wall on the map', (h.u32(f.alg_x), h.u32(f.alg_y)), (116, 100))
    check('a new path was laid', f.unit_field(unit, 'path_len') > 0, True)
    check('  from where the tunneler stands',
          (word(f, unit, 0xC4), word(f, unit, 0xC6)), (108, 100))
    check('  towards the wall', (word(f, unit, 0xC8), word(f, unit, 0xCA)), (116, 100))
    check('nothing written below the image base', len(strays), 0)

    print('2. and the ticks that follow just dig on')
    for tick in range(3):
        result, strays = run_whole_function(f, unit)
        check('  tick %d returns cleanly' % (tick + 1), result, 'returned')
        check('  still digging', f.unit_field(unit, 'state'), 3)
        check('  nothing written below the image base', len(strays), 0)

    print('3. a collapse sends the player\'s other tunnels at the next wall')
    dig(f, second, 104, 100, steps=4)                     # aimed where the first one stands
    h.put32(f.unit(second) + 0x98, 778)
    f.set_unit(second, dest_x=108, dest_y=100)
    h.put32(f.current_unit, unit)
    f.set_unit(unit, state=4)                             # the first one is collapsing
    result, strays = run_at(f, f.tunneler + 0x954, unit)
    check('the collapse hook returns cleanly', result, 'returned')
    check('  and it costs the collapse nothing but a mark',
          (h.m.read(f.pending + (second >> 3), 1)[0] >> (second & 7)) & 1, 1)

    # the tunnel that was marked looks again on its own tick, not in the collapse
    h.put32(f.current_unit, second)
    h.put32(f.ticks, 5001)
    h.put32(f.last_reaim_tick, 0)
    result, strays = run_whole_function(f, second)
    check('the second tunnel looks again on its own tick', result, 'returned')
    check('  and is sent at the wall',
          (word(f, second, 0xC8), word(f, second, 0xCA)), (116, 100))
    check('  it kept digging', f.unit_field(second, 'state'), 3)
    check('  and it has a path to follow', f.unit_field(second, 'path_len') > 0, True)
    check('nothing written below the image base', len(strays), 0)

    print('4. and a tunnel digs under the town to reach what is behind it')
    g = Fixture(False, config={'retarget': {'collapse_behind': False}})
    gh = g.h
    world(g, wall_at=(116, 100), building_at=(112, 100), building_type=20)
    gh.stub(g.apply_damage, 0, 4)
    gh.put32(g.current_unit, unit)
    gh.put32(g.units_state, 40)
    dig(g, unit, 108, 100, steps=8)
    gh.put32(g.unit(unit) + 0x98, 777)
    gh.put32(g.ticks, 5000)
    gh.put32(g.camp_ids + 0x39F4 * 2, 0)                  # nothing to aim towards here
    gh.put32(g.keep_ids + 0x39F4 * 2, 0)
    result, strays = run_at(g, g.tunneler + 0x7E6, unit)
    check('the hook returns cleanly', result, 'returned')
    check('the search reached past the workshop to the wall',
          (gh.u32(g.alg_x), gh.u32(g.alg_y)), (116, 100))
    check('and the game laid a path under it',
          (word(g, unit, 0xC8), word(g, unit, 0xCA)), (116, 100))
    check('  which the tunneler can follow', g.unit_field(unit, 'path_len') > 0, True)
    check('nothing written below the image base', len(strays), 0)

    print('\n%s' % ('ALL OK' if not FAILURES else 'FAILURES: ' + ', '.join(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == '__main__':
    raise SystemExit(main())
