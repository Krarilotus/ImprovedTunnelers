"""Tunnels gathering on a line and working their way in, with the game's own code.

Every tunneller here is dug in by the real UpdateTunneler (state 9, the game's own first
search and all), moved a tick at a time by the real processUnitMove, and collapsed by the
real state 4. What is asserted is where tunnels go, and that the fortification each one is
sent at is the one it brings down - with the collapse the first tunnel got.

Vanilla executable only - the synthetic map uses vanilla addresses.

usage: python test_real_lines.py [name ...]
"""
import sys
from realworld import Castle
from test_tunnelers import check, FAILURES

ONLY = set(sys.argv[1:])


def scenario(fn):
    if not ONLY or fn.__name__ in ONLY:
        print('\n== %s' % fn.__name__)
        try:
            fn()
        except Exception as problem:                         # a crash is a failure too
            check('%s ran to the end' % fn.__name__, repr(problem), 'no exception')
    return fn


def collapsed_where(c, unit):
    """Run until the unit is gone; where its collapse happened."""
    spot = []

    def note(n):
        if c.state(unit) == 4 and not spot:
            spot.append(c.at(unit))
    c.run([unit], lambda: not c.alive(unit), watch=note)
    return spot[0] if spot else None


@scenario
def a_redirected_tunnel_brings_down_its_new_target():
    # A is the nearest wall, B lies further in towards the campfire in the east.
    c = Castle(walls=[(108, 100), (120, 100)], camp=(300, 100))
    t = c.tunneller(11, (100, 100))
    c.dig_in(t)
    check('it is aimed at the nearest wall', c.heading(t), (108, 100))
    check('  and that wall is now the player s line', c.line(1)[:3],
          (c.tile(108, 100), 108, 100))
    c.take_down(108, 100)                                  # another tunnel got there first
    c.run([t], lambda: c.heading(t) != (108, 100) or not c.alive(t))
    check('arriving on empty ground it is sent on towards the campfire', c.heading(t),
          (120, 100))
    index, length, ladder = c.plan(t)
    check('  keeping what it dug: the plan still starts at the entrance', ladder, (100, 100))
    check('  and runs on from where it stands', (index, length), (8, 20))
    check('  and the line moves on with it', c.line(1)[:3], (c.tile(120, 100), 120, 100))
    where = collapsed_where(c, t)
    check('it collapses where it was sent', where, (120, 100))
    check('  and brings that wall down', c.standing(120, 100), False)
    check('  handing the collapse the whole tunnel, entrance to target',
          c.h.u32(c.f.queue_count), 20)
    check('nothing is written below the image base', len(c.strays), 0)
    check('the search filter is left off for the game', c.h.u32(c.f.aim_mode), 0)


@scenario
def tunnels_meet_at_one_wall_and_then_go_on_in_turn():
    # Two tunnels from two entrances; the second one's own nearest wall is a different one,
    # but the first one's is in its reach, so it joins it. The first to arrive takes it,
    # the second arrives on the rubble and goes on to the next wall in.
    c = Castle(walls=[(110, 100), (112, 112), (125, 100)], camp=(300, 100))
    a = c.tunneller(11, (100, 100))
    b = c.tunneller(12, (104, 112))
    c.dig_in(a)
    c.dig_in(b)
    check('the first tunnel starts the line at its wall', c.heading(a), (110, 100))
    check('the second, whose own nearest wall is elsewhere, joins it', c.heading(b),
          (110, 100))
    first = collapsed_where(c, a)
    check('the first one to get there brings it down', (first, c.standing(110, 100)),
          ((110, 100), False))
    c.run([b], lambda: c.heading(b) != (110, 100) or not c.alive(b))
    check('the other goes through the hole to the next wall in', c.heading(b), (125, 100))
    second = collapsed_where(c, b)
    check('  and brings that one down too', (second, c.standing(125, 100)),
          ((125, 100), False))
    check('  the one it passed on the way is untouched', c.standing(112, 112), True)


@scenario
def with_the_way_to_the_campfire_open_the_breach_is_widened():
    # Nothing lies between the breach and the campfire; the one wall left is off to the
    # side, and that is where the tunnel goes.
    c = Castle(walls=[(108, 100), (108, 110)], camp=(300, 100))
    t = c.tunneller(11, (100, 100))
    c.dig_in(t)
    c.take_down(108, 100)
    c.run([t], lambda: c.heading(t) != (108, 100) or not c.alive(t))
    check('it is sent at the nearest wall there is', c.heading(t), (108, 110))
    where = collapsed_where(c, t)
    check('  and brings it down', (where, c.standing(108, 110)), ((108, 110), False))


@scenario
def a_tunnel_with_nowhere_to_go_collapses_where_it_stands():
    c = Castle(walls=[(108, 100)], camp=(300, 100))
    t = c.tunneller(11, (100, 100))
    c.dig_in(t)
    c.take_down(108, 100)
    where = collapsed_where(c, t)
    check('it collapses on the empty spot, as the game would', where, (108, 100))


@scenario
def the_keep_is_gone_round_not_under():
    # The keep stands squarely between the breach and the next wall towards the campfire.
    c = Castle(walls=[(104, 100), (124, 100)], camp=(300, 100))
    c.keep(110, 96, 118, 104)
    t = c.tunneller(11, (100, 100))
    c.dig_in(t)
    c.take_down(104, 100)
    c.run([t], lambda: c.heading(t) != (104, 100) or not c.alive(t))
    check('the tunnel is sent at the wall behind the keep', c.heading(t), (124, 100))
    under = [p for p in c.steps(t) if 110 <= p[0] <= 118 and 96 <= p[1] <= 104]
    check('  and not one tile of its path runs under the keep', under, [])
    where = collapsed_where(c, t)
    check('  and it brings that wall down', (where, c.standing(124, 100)),
          ((124, 100), False))


@scenario
def a_second_siege_gets_its_own_meeting_point():
    # Two groups far enough apart that neither can reach the other's wall: each starts a
    # line of its own, and a second tunnel of the far group joins the far line.
    c = Castle(walls=[(100, 70), (100, 150), (108, 150)], camp=(100, 300), lo=60, hi=161)
    c.f.h.put32(c.f.retarget_range, 30)
    a = c.tunneller(11, (100, 64))
    b = c.tunneller(12, (100, 144))
    d = c.tunneller(13, (112, 144))
    c.dig_in(a)
    c.dig_in(b)
    c.dig_in(d)
    check('the near group starts a line', c.heading(a), (100, 70))
    check('the far group, out of its reach, starts its own', c.heading(b), (100, 150))
    check('  and the next tunnel there joins that one, not the near one', c.heading(d),
          (100, 150))
    slots = sorted(c.line(1, s)[0] for s in range(4) if c.line(1, s)[0])
    check('the player has two lines', slots, sorted([c.tile(100, 70), c.tile(100, 150)]))


@scenario
def tunnels_follow_the_route_to_the_campfire_and_only_then_widen():
    # Three walls in a row between the breach and the campfire, and one off to the side.
    # The first tunnel to arrive on the rubble lays out the route - once - and each tunnel
    # after it goes one wall further along it; only when the route is open all the way does
    # a tunnel turn to the wall off to the side.
    c = Castle(walls=[(108, 100), (118, 100), (128, 100), (108, 112)], camp=(150, 100))
    a = c.tunneller(11, (100, 100))
    b = c.tunneller(12, (100, 104))
    d = c.tunneller(13, (100, 96))
    for t in (a, b, d):
        c.dig_in(t)
    check('all three start out at the same wall', [c.heading(t) for t in (a, b, d)],
          [(108, 100)] * 3)
    c.take_down(108, 100)                                  # another tunnel got there first
    searches = c.watch_searches()
    c.run([a], lambda: c.heading(a) != (108, 100) or not c.alive(a))
    check('the first to arrive is sent at the next wall on the way to the campfire',
          c.heading(a), (118, 100))
    route = [m for m in searches if m[0] == 3]
    check('  the route was laid out by one search, from the breach',
          [(m[2], m[3]) for m in route], [(108, 100)])
    check('    reaching as far as the campfire is, plus room for the way round the keep',
          route[0][1], 42 + 40)
    check('  and the tunnel was laid along it with no search of its own', len(searches), 1)
    check('    the way the diagnostics would say: along its line s route',
          c.h.u32(c.f.redirect_how), 7)
    check('it brings that wall down', (collapsed_where(c, a), c.standing(118, 100)),
          ((118, 100), False))

    searches.clear()
    c.run([b], lambda: c.heading(b) != (108, 100) or not c.alive(b))
    check('the next one goes past it to the wall after', c.heading(b), (128, 100))
    check('  without a single search - nor the route laid out again', searches, [])
    index, length, ladder = c.plan(b)
    check('  its tunnel still one piece from its entrance', ladder, (100, 104))
    check('  and brings that one down too', (collapsed_where(c, b), c.standing(128, 100)),
          ((128, 100), False))

    searches.clear()
    c.run([d], lambda: c.heading(d) != (108, 100) or not c.alive(d))
    check('with the route open all the way, the last widens the breach instead',
          c.heading(d), (108, 112))
    check('  with one search, straight for the nearest fortification', [m[0] for m in searches], [4])
    check('  and brings it down', (collapsed_where(c, d), c.standing(108, 112)),
          ((108, 112), False))
    check('nothing is written below the image base', len(c.strays), 0)


@scenario
def a_tunnel_dug_in_later_joins_the_front_of_the_route():
    # The route is laid out and its first wall already down: a tunnel dug in afterwards is
    # sent straight at the front of the route, not at the rubble or its own nearest wall.
    c = Castle(walls=[(108, 100), (118, 100), (128, 100)], camp=(150, 100))
    a = c.tunneller(11, (100, 100))
    c.dig_in(a)
    c.take_down(108, 100)
    c.run([a], lambda: c.heading(a) != (108, 100) or not c.alive(a))
    collapsed_where(c, a)                                  # (118, 100) comes down
    late = c.tunneller(12, (100, 108))
    c.dig_in(late)
    check('a tunnel dug in later goes for the front of the route', c.heading(late), (128, 100))
    check('  which is now the line s target', c.line(1)[:3], (c.tile(128, 100), 128, 100))


@scenario
def the_route_goes_round_the_keep():
    # The keep stands squarely between the breach and the campfire, and beyond it a wall
    # runs right across the way. The route is laid out round the keep and through the wall,
    # and the tunnel following it never passes under the keep.
    inner = [(132, y) for y in range(84, 117)]
    c = Castle(walls=[(108, 100)] + inner, camp=(150, 100))
    c.keep(116, 94, 124, 106)
    t = c.tunneller(11, (100, 100))
    c.dig_in(t)
    c.take_down(108, 100)
    searches = c.watch_searches()
    c.run([t], lambda: c.heading(t) != (108, 100) or not c.alive(t))
    target = c.heading(t)
    check('the route leads on to the wall beyond the keep', target[0], 132)
    check('  laid out once, and followed with no search of its own',
          [m[0] for m in searches], [3])
    under = [p for p in c.steps(t) if 116 <= p[0] <= 124 and 94 <= p[1] <= 106]
    check('  and not one tile of the tunnel runs under the keep', under, [])
    check('  and it brings that piece of wall down', (collapsed_where(c, t), c.standing(*target)),
          (target, False))


@scenario
def a_group_spreads_along_a_thick_wall_instead_of_piling_onto_one_tile():
    # The next wall on the route is three tiles deep. Three tunnels arrive on the rubble of
    # the first together: each is sent at a tile of its own, and each brings its tile down,
    # instead of all three coming up under the first tile and two of them spent for nothing.
    thick = [(x, y) for x in (116, 117, 118) for y in range(90, 111)]
    c = Castle(walls=[(108, 100)] + thick, camp=(150, 100))
    units = [c.tunneller(11 + i, (100, 98 + 2 * i)) for i in range(3)]
    for t in units:
        c.dig_in(t)
    c.take_down(108, 100)
    c.run(units, lambda: all(c.heading(t) != (108, 100) or not c.alive(t) for t in units))
    targets = sorted(c.heading(t) for t in units)
    check('three tunnels arriving together are sent at three different tiles',
          len(set(targets)), 3)
    check('  the three tiles of the wall, in a row along the route', targets,
          [(116, 100), (117, 100), (118, 100)])
    heading = {t: c.heading(t) for t in units}
    spots = {}

    def note(n):
        for t in units:
            if c.alive(t) and c.state(t) == 4 and t not in spots:
                spots[t] = c.at(t)
    c.run(units, lambda: not any(c.alive(t) for t in units), watch=note)
    check('each collapses under the tile it was sent at',
          [spots.get(t) for t in units], [heading[t] for t in units])
    check('  and all three are down', [c.standing(*p) for p in targets], [False] * 3)


@scenario
def a_path_of_ours_that_will_not_lay_costs_no_whole_map_rebuild():
    # A trace that finds no way back makes the game rebuild the path linkage of every
    # building and the area map of the whole map - the lag spike. For a path the module
    # asked for that is skipped; the game's own paths still get it.
    from realworld import UNITS_STATE
    c = Castle(walls=[(108, 100)], camp=(150, 100))
    t = c.tunneller(11, (100, 100))
    c.dig_in(t)
    rebuilds = []
    c.h.cpu.hooks[0x4A5F60] = lambda cpu: rebuilds.append(1)
    quiet = c.f.control + 0x1C8
    x, y = 104, 120                         # a tile the last search never stamped a way back to
    tile = c.tile(x, y)

    def lay():
        c.h.put8(0x21AEC98 + y * 400 + x, 1)
        c.h.put16(0x1E6CD38 + 2 * tile, 0x7ABC)     # a search number no neighbour carries
        c.h.put16(0x1E45918 + 2 * tile, 9)
        c.call(c.f.set_destination, (t, x, y, 2), UNITS_STATE)
        return c.h.cpu.r['eax']

    c.h.put32(quiet, 1)
    got = lay()
    check('a path of ours that will not lay is refused', got, 0)
    check('  without the whole-map rebuild', len(rebuilds), 0)
    check('  and the flag is left for the module to clear', c.h.u32(quiet), 1)
    c.h.put32(quiet, 0)
    lay()
    check("a refused path of the game's own still gets its rebuild", len(rebuilds), 1)


@scenario
def a_tunnel_collapses_under_the_first_enemy_fortification_it_crosses():
    # The tunnel is on its way to the wall at x=116. A wall at x=112, right on its way, was
    # not there when it was aimed - the way a route can miss a piece behind a gate, a
    # ladder or a siege tower. It comes up under that one, and 116 is left standing.
    c = Castle(walls=[(116, 100)], camp=(150, 100))
    t = c.tunneller(11, (100, 100))
    c.dig_in(t)
    check('it is aimed at the far wall', c.heading(t), (116, 100))
    check('  along a tunnel under x=112', (112, 100) in c.steps(t), True)
    c.wall(112, 100)
    where = collapsed_where(c, t)
    check('it collapses under the wall it crosses', where, (112, 100))
    check('  which comes down', c.standing(112, 100), False)
    check('  and the wall it was aimed at still stands', c.standing(116, 100), True)
    index, length, ladder = c.plan(t)
    check('  its tunnel ends where it got to', length <= 13, True)


if __name__ == '__main__':
    print('\n%s' % ('ALL OK' if not FAILURES else 'FAILURES: ' + ', '.join(FAILURES)))
    sys.exit(1 if FAILURES else 0)
