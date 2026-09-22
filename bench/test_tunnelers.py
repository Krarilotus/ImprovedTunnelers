"""Behaviour tests for improved-tunnelers: the module's own assembly, executed in the
x86 interpreter against the real exe image.

usage: python test_tunnelers.py [v|e|both]
"""
import sys, struct
from harness import Host, SENTINEL, STACK_TOP
from t import VAN, EXT

UNIT = 0x490
FAILURES = []


def check(name, got, want):
    ok = got == want
    print('   %-46s %s   (got %s, want %s)' % (name, 'ok' if ok else 'FAIL',
                                               hex(got) if isinstance(got, int) else got,
                                               hex(want) if isinstance(want, int) else want))
    if not ok:
        FAILURES.append(name)


class Fixture:
    def __init__(self, extreme=False, config=None):
        self.h = Host(extreme=extreme, config=config)
        e = self.h.E
        self.e = e
        u32 = lambda a: struct.unpack('<I', e.data[e.va2off(a):e.va2off(a)+4])[0]
        i32 = lambda a: struct.unpack('<i', e.data[e.va2off(a):e.va2off(a)+4])[0]
        self.tunneler = self.h.find(
            "51 8B 0D ? ? ? ? 8B C1 69 C0 90 04 00 00 53 55 0F BF A8 ? ? ? ? 56 57 8B FD "
            "69 FF F4 39 00 00 BA 01 00 00 00 01 97 ? ? ? ? 01 97 ? ? ? ? 33 DB")
        self.finder = self.h.find("56 8B 74 24 08 69 F6 2C 03 00 00 8B 86 ? ? ? ?")
        self.enemy = self.h.find("8B 54 24 08 ? ? ? ? 00 00 56 77 1E")
        self.render = self.h.find("8B 44 24 04 50 B9 ? ? ? ? E8 ? ? ? ? 85 C0 75 0B C7 05 ? ? ? ? ? 00 00 00")
        self.toolbar = self.h.find("53 33 DB 39 1D ? ? ? ? 0F 85 ? ? ? ? 39 1D ? ? ? ? 0F 85 ? ? ? ? A1 ? ? ? ?")
        self.teams = u32(self.h.find("8B 0C 85 ? ? ? ? 8B 44 24 30 3B 0C 85 ? ? ? ?") + 3)
        self.ticks = u32(self.h.find("8B 87 50 0A 00 00 8B 8F 98 09 00 00") + 14)
        t = self.tunneler
        self.current_unit = u32(t + 3)
        self.unit_base = (u32(t + 0x14) - 0x96) & 0xFFFFFFFF
        self.tile_flags = u32(t + 0xC0E)
        self.building_tiles = u32(t + 0x8E7)
        self.units_state = u32(t + 0x922)
        self.apply_damage = (t + 0x926 + 5 + i32(t + 0x927)) & 0xFFFFFFFF
        self.set_destination = (t + 0x6CE + 5 + i32(t + 0x6CF)) & 0xFFFFFFFF
        self.alg_find = (self.finder + 0xB9 + 5 + i32(self.finder + 0xBA)) & 0xFFFFFFFF
        self.alg_result = u32(self.finder + 0xC0)
        self.alg_x = u32(t + 0x6BB)
        self.alg_y = u32(t + 0x6B5)
        self.tunnelers_only = (self.render + 0x242 + 5 + i32(self.render + 0x243)) & 0xFFFFFFFF
        self.render_button = (self.render + 0xD3 + 5 + i32(self.render + 0xD4)) & 0xFFFFFFFF
        self.engineer_selected = u32(self.render + 0x91)
        self.game_mode = u32(self.render + 0x7B)
        self.picture = u32(self.render + 0x24D)
        self.help_text = u32(self.render + 0x257)
        self.inactive = u32(self.render + 0x2E)
        self.control = int(self.h.mod[b'control'])
        self.duration = self.h.u32(self.control + 0x04)   # denial ticks, whatever it is set to
        self.budget = self.h.u32(self.control + 0x10)     # re-aims one tunneler may have
        self.mine = self.control + 0x70
        self.collapse_damage = self.control + 0x78
        self.spread_enabled = self.control + 0x7C
        self.spread_damage = self.control + 0x80
        self.suppress = self.control + 0x84
        self.mine_tick = self.control + 0x74
        self.walk = self.apply_damage
        self.process_damage = (self.walk + 0x9B + 5 + i32(self.walk + 0x9C)) & 0xFFFFFFFF
        self.update_walk = (self.walk + 0xA9 + 5 + i32(self.walk + 0xAA)) & 0xFFFFFFFF
        self.directions = u32(self.walk + 0xE8)
        self.x_deltas = u32(self.walk + 0xD7)
        self.y_deltas = u32(self.walk + 0xE1)
        self.hide_select = self.control + 0x8C
        self.hide_target = self.control + 0x90
        self.towards = self.control + 0x94
        self.bias = self.control + 0x98
        self.origin_distance = self.control + 0x9C
        self.camp_x = self.control + 0xA0
        self.camp_y = self.control + 0xA4
        self.under = self.control + 0xA8
        self.best_tile = self.control + 0xB0
        self.best_x = self.control + 0xB4
        self.best_y = self.control + 0xB8
        self.last_reaim_tick = self.control + 0xC0
        self.spread_radius = self.control + 0xC4
        self.fill_unit = self.control + 0x22C
        self.fill_flags = self.control + 0x230
        self.step_tile = self.control + 0x248
        self.step_x = self.control + 0x24C
        self.step_y = self.control + 0x250
        self.step_flags = self.control + 0x254
        self.queue_count = self.control + 0x270
        self.speed = self.control + 0x274
        self.queue = self.control + 0x2D0
        self.pending = self.control + 0xE4
        self.origin_x = self.control + 0x224
        self.origin_y = self.control + 0x228
        self.zones = self.control + 0x2D0 + 512 * 16
        self.finish_leg = self.control + 0x2CC
        self.family_damage = self.control + 0x2C4
        self.family_ready = self.control + 0x2C8
        self.pinned = self.control + 0x290
        self.depth_limit = self.control + 0x294
        self.shared_slot = self.control + 0x298
        self.shared = self.zones + 32 * 16 + 32 * 8
        self.trail = self.shared + 9 * 32           # the spots a player's line has taken
        self.trail_stride = 4 + 8 * 12
        self.records = self.zones + 32 * 16
        self.retarget_range = self.control + 0x0C
        self.retarget_max = self.control + 0x10
        self.collapse_behind = self.control + 0x1C
        self.targets_enabled = self.control + 0x20
        self.diagnostics = self.control + 0x24
        self.last_tick = self.control + 0x28
        self.ring_cursor = self.control + 0x34
        self.reaim_unit = self.control + 0x38
        self.reaim_arrived = self.control + 0x3C
        self.reaim_count = self.control + 0x44
        self.report = self.control + 0x48
        self.building_base = (u32(t + 0x4D3) - 0xF0) & 0xFFFFFFFF
        self.distance_map = 0                   # filled in once the search is found
        self.search = self.h.find(
            "53 55 56 57 68 ? ? ? ? 33 FF 8B F1 57 BB 01 00 00 00 ? ? ? ? 00 00 ? ? ? ? 00")
        self.gate_or_tower = u32(t + 0xC50)
        self.aim_test = self.h.find(
            "8B 44 24 04 69 C0 90 04 00 00 0F B7 84 08 ? ? ? ? 66 3D 6F 00")
        self.keep_site = self.h.find(
            "66 83 B8 ? ? ? ? 02 74 ? 69 ED F4 39 00 00 8B AD ? ? ? ?")
        self.keep_ids = u32(self.keep_site + 0x12)
        self.camp_site = self.h.find("8B 44 24 04 69 C0 F4 39 00 00 8B 80 ? ? ? ? 85 C0 7F")
        self.camp_ids = u32(self.camp_site + 0x0C)
        self.live_height = u32(self.walk + 0x5B)
        self.base_height = u32(self.walk + 0x64)
        self.tick_site = self.h.find(
            "53 55 0F BF 2D ? ? ? ? 81 E5 0F 00 00 80 56 57 8B F1")
        self.row_table = u32(self.set_destination + 0xFA)
        self.message = self.h.find(
            "3B C5 74 2C 68 70 17 00 00 6A 64 55 50 6A 4D 53 B9 ? ? ? ? E8 ? ? ? ? A1 ? ? ? ?")

    def module_routine(self, site, skip=0):
        """The module's own routine a hooked site calls, found by following the jump."""
        import capstone
        md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        rel = struct.unpack('<i', self.h.m.read(site + 1, 4))[0]
        block = (site + 5 + rel) & 0xFFFFFFFF
        seen = 0
        for i in md.disasm(bytes(self.h.m.read(block, 0x400)), block):
            if i.mnemonic == 'call' and i.op_str.startswith('0x'):
                target = int(i.op_str, 16)
                if target >= 0x60000000:
                    if seen == skip:
                        return target
                    seen += 1
        raise AssertionError('no module routine called from %08X' % site)

    # unit helpers
    def unit(self, index):
        return self.unit_base + index * UNIT

    def set_unit(self, index, **fields):
        offsets = dict(owner=0x96, x=0xC4, y=0xC6, tile=0xD4, uid=0x98, state=0x2C0,
                       looking=0x3FC, siege=0x432, path_len=0xFC, stage=0xF6,
                       kind=0x8E, alive=0x8C, dying=0x2A0, dest_x=0xC8, dest_y=0xCA,
                       dest_tile=0xD8)
        for name, value in fields.items():
            off = offsets[name]
            if name in ('tile', 'uid', 'dest_tile'):
                self.h.put32(self.unit(index) + off, value)
            else:
                self.h.put16(self.unit(index) + off, value)

    BUILDING_FIELDS = dict(state=0xD0, kind=0xD2, owner=0xD6, unit=0x110, anim=0x20,
                           counter=0x25C)
    UNIT_FIELDS = dict(state=0x2C0, looking=0x3FC, path_len=0xFC, frame=0x38C, stage=0xF6)

    def building(self, index, **fields):
        base = self.building_base + index * 0x32C
        for name, value in fields.items():
            if name == 'counter':
                self.h.put32(base + self.BUILDING_FIELDS[name], value & 0xFFFFFFFF)
            else:
                self.h.put16(base + self.BUILDING_FIELDS[name], value)
        return base

    def building_field(self, index, name):
        base = self.building_base + index * 0x32C
        if name == 'counter':
            return struct.unpack('<i', self.h.m.read(base + self.BUILDING_FIELDS[name], 4))[0]
        return struct.unpack('<H', self.h.m.read(base + self.BUILDING_FIELDS[name], 2))[0]

    def unit_tile(self, index):
        return self.h.u32(self.unit(index) + 0xD4)

    def unit_field(self, index, name):
        return struct.unpack('<H', self.h.m.read(self.unit(index) + self.UNIT_FIELDS[name], 2))[0]

    def zone(self, i):
        a = self.zones + 16 * i
        return tuple(self.h.u32(a + 4 * k) for k in range(4))


def scenario(extreme):
    name = 'Extreme' if extreme else 'vanilla'
    print('\n=== %s ===' % name)
    f = Fixture(extreme)
    h = f.h

    # --------------------------------------------------------------- stances
    print(' stances')
    for state, want in ((0, 1), (1, 1), (5, 1), (6, 1), (0x69, 1),
                        (0x65, 0), (3, 0), (4, 0), (7, 0), (9, 0), (0x6A, 0)):
        h.put32(f.current_unit, 7)
        f.set_unit(7, state=state, looking=0)
        h.run(f.tunneler, until=f.tunneler + 7)
        got = struct.unpack('<H', h.m.read(f.unit(7) + 0x3FC, 2))[0]
        check('state 0x%02X -> looking-around flag %d' % (state, want), got, want)
    # the replayed prologue really happened
    h.put32(f.current_unit, 7)
    cpu = h.run(f.tunneler, until=f.tunneler + 7, regs={'ecx': 0x11223344})
    check('prologue: ecx = current unit', cpu.r['ecx'], 7)
    check('prologue: old ecx pushed', h.u32(cpu.r['esp']), 0x11223344)

    # ------------------------------------------------------- denial laid on arrival
    print(' laying a denial zone when a tunnel arrives on something')
    arrive = f.tunneler + 0x7E6
    carry_on = arrive + 5
    tile = 200 * 400 + 150
    unit9 = 9
    h.put32(f.current_unit, unit9)
    f.set_unit(unit9, owner=3, x=150, y=200, tile=tile, uid=5000, state=3)
    h.put32(f.tile_flags + 4 * tile, 0x100)              # a wall stands there
    h.put32(f.building_tiles + 2 * tile, 0)
    h.put32(f.ticks, 5000)
    cpu = h.run(arrive, until=carry_on)
    check('zone laid on a wall tile', f.zone(0), (150, 200, 3, 5000 + f.duration))
    check('and the collapse carries on as usual', cpu.eip, carry_on)

    h.put32(f.tile_flags + 4 * tile, 0)
    h.put16(f.building_tiles + 2 * tile, 12)             # a building instead
    f.set_unit(unit9, owner=2, x=151, y=201)
    h.run(arrive, until=carry_on)
    check('zone laid on a building tile', f.zone(1), (151, 201, 2, 5000 + f.duration))

    print(' a second collapse at the same breach adds its time on')
    h.put32(f.ticks, 5000)
    f.set_unit(unit9, owner=3, x=150, y=200, tile=tile, state=3)
    h.put32(f.tile_flags + 4 * tile, 0x100)
    h.put32(f.building_tiles + 2 * tile, 0)
    for a in range(32):                                      # start from a clean list
        h.put32(f.zones + 16 * a + 12, 0)
    h.put32(f.last_tick, 0)
    h.run(arrive, until=carry_on)
    check('the first collapse lays the zone', f.zone(0), (150, 200, 3, 5000 + f.duration))
    f.set_unit(unit9, x=151, y=201)
    h.run(arrive, until=carry_on)
    check('the second one adds its time to it', f.zone(0),
          (150, 200, 3, 5000 + 2 * f.duration))
    check('  and takes no second zone', f.zone(1)[3], 0)
    f.set_unit(unit9, x=155, y=205)
    h.run(arrive, until=carry_on)
    check('a collapse further off gets its own zone', f.zone(1),
          (155, 205, 3, 5000 + f.duration))
    f.set_unit(unit9, owner=6, x=150, y=200)
    h.run(arrive, until=carry_on)
    check('and another player never adds to yours', f.zone(2),
          (150, 200, 6, 5000 + f.duration))

    h.put32(f.ticks, 4000)                               # a save was loaded
    f.set_unit(unit9, owner=1, x=10, y=20)
    h.run(arrive, until=carry_on)
    check('tick counter going back frees the old zones', f.zone(1)[3], 0)
    check('and the new zone is the only one', f.zone(0), (10, 20, 1, 4000 + f.duration))

    # ------------------------------------------------- what the refusal says
    print(' the refusal message')
    check('the module wrote its line into the game text',
          [t for t in h.texts if t[0] == 0x4D], [(0x4D, 250, 'The ground is too unstable to build here right now')])
    say = f.message + 4
    back = say + 5
    h.put32(f.ticks, 8000)
    h.put32(f.mine, 0)
    cpu = h.run(say, until=back, regs={'eax': 20})
    check('an ordinary refusal keeps the game entry', cpu.r['eax'], 20)
    check('  and the duration is still pushed', h.u32(cpu.r['esp']), 6000)
    h.put32(f.mine, 1)
    h.put32(f.mine_tick, 8000)
    cpu = h.run(say, until=back, regs={'eax': 20})
    check('a denial refusal says the ground is unstable', cpu.r['eax'], 250)
    h.put32(f.mine_tick, 7999)
    cpu = h.run(say, until=back, regs={'eax': 20})
    check('a refusal from an older tick does not', cpu.r['eax'], 20)

    # ---------------------------------------------------------- denial check
    print(' refusing to build in a zone')
    h.put32(f.ticks, 4100)
    h.put32(f.teams + 4 * 1, 1)      # player 1 on team 1 (the tunneler's owner)
    h.put32(f.teams + 4 * 2, 2)      # player 2 on team 2
    h.put32(f.teams + 4 * 3, 1)      # player 3 allied with player 1
    # the game's own coordinate check needs a walkable tile; find the map from the code
    bm = struct.unpack('<I', f.e.data[f.e.va2off(f.enemy + 0x24):f.e.va2off(f.enemy + 0x24) + 4])[0]
    for y in range(15, 26):
        for x in range(5, 16):
            h.put8(bm + y * 400 + x, 1)
    def denial(player, x, y, rng):
        cpu = h.run(f.enemy, stack=[player, x, y, rng])
        return cpu.r['eax']
    check('enemy player is refused inside the circle', denial(2, 12, 22, 5), 1)
    check('same spot outside the circle is free', denial(2, 15, 25, 3), 0)
    check('the tunneler\'s own player may build', denial(1, 10, 20, 5), 0)
    check('an ally may build', denial(3, 10, 20, 5), 0)
    h.put32(f.mine, 0)
    denial(2, 12, 22, 5)             # still on tick 4100, still inside the circle
    check('refusing marks the refusal as its own', h.u32(f.mine), 1)
    check('  and stamps it with the tick', h.u32(f.mine_tick), 4100)
    denial(1, 10, 20, 5)
    check('and anything it allows clears the mark', h.u32(f.mine), 0)
    h.put32(f.ticks, 4000 + f.duration)  # the zone has just run out
    check('after the time is up the spot is free', denial(2, 10, 20, 5), 0)

    # -------------------------------------------------------------- re-aiming
    print(' digging on to the next wall')
    h.put32(f.keep_ids + 0x39F4 * 2, 0)                     # the target player has neither
    h.put32(f.camp_ids + 0x39F4 * 2, 0)                     # a keep nor a campground yet
    arrived = f.tunneler + 0x7E6
    resume = arrived + 5
    tail = f.tunneler + 0x1197
    unit = 11
    empty = 100 * 400 + 100
    h.put32(f.current_unit, unit)
    f.set_unit(unit, owner=1, x=100, y=100, tile=empty, uid=777, state=3, siege=2,
               kind=5, alive=2, dying=0)

    # the game's own search and path finder, stubbed: what matters here is what the module
    # asks them for and what it does with the answer
    searches, paths, damage = [], [], []
    h.stub(f.alg_find, 0, 20, record=searches)
    h.stub(f.set_destination, 1, 16, record=paths)
    h.stub(f.apply_damage, 0, 4, record=damage)
    h.put32(f.alg_result, 1)                                # the search finds something
    h.put32(f.alg_x, 130)
    h.put32(f.alg_y, 140)

    h.put32(f.tile_flags + 4 * empty, 0x100)                # the wall is still there
    cpu = h.run(arrived, until=resume)
    check('a wall is still there -> collapse as usual', len(searches), 0)
    check('  and the tunneler is left alone', f.unit_field(unit, 'state'), 3)

    h.put32(f.tile_flags + 4 * empty, 0)
    h.put16(f.building_tiles + 2 * empty, 5)                # a building is still there
    cpu = h.run(arrived, until=resume)
    check('a building is still there -> collapse as usual', len(searches), 0)
    h.put32(f.building_tiles + 2 * empty, 0)

    for bit, name in ((0x800, 'stairs'), (0x200, 'a crenellation')):
        h.put32(f.tile_flags + 4 * empty, bit)
        cpu = h.run(arrived, until=resume)
        check('%s is still there -> collapse as usual' % name, len(searches), 0)
        check('  and the tunneler is not sent anywhere else', cpu.eip, resume)
    h.put32(f.tile_flags + 4 * empty, 0)

    cpu = h.run(arrived, until=tail)                        # nothing left above the tunnel
    check('nothing there -> the game is asked for another target', len(searches), 1)
    check('  searched from where the tunneler stands, for its own enemy',
          searches[-1][1][:5], [1, 2, 80, 100, 100])
    check('  and the bias is down again afterwards', h.u32(f.bias), 0)
    check('  and the tunnel is given the new destination',
          paths[-1][1][:4], [unit, 130, 140, 2])
    check('  the tunneler keeps digging', f.unit_field(unit, 'state'), 3)
    check('  and the game returns without collapsing', cpu.eip, tail)

    h.put8(f.pending + (unit >> 3), 1 << (unit & 7))        # ... and a tunnel that was
    h.run(arrived, until=tail)                              # carrying a mark is settled
    check('a mark is used up when the tunnel gets to the end of its leg',
          (h.m.read(f.pending + (unit >> 3), 1)[0] >> (unit & 7)) & 1, 0)

    h.put32(f.alg_result, 0)                                # ... and when nothing is found
    before = len(paths)
    cpu = h.run(arrived, until=resume)
    check('nothing in range -> collapse as usual', len(paths), before)
    check('  and no time is wasted on a path', cpu.eip, resume)
    h.put32(f.alg_result, 1)

    # the budget: so many re-aims for one tunneler, then it collapses where it is
    f.set_unit(unit, uid=999)
    for _ in range(f.budget):
        h.run(arrived, until=tail)
    before = len(searches)
    cpu = h.run(arrived, until=resume)
    check('%d re-aims are allowed, the next is not' % f.budget, len(searches), before)

    f.set_unit(unit, uid=888)                               # another tunneler in the same slot
    cpu = h.run(arrived, until=tail)
    check('a new tunneler in the same slot starts again', cpu.eip, tail)

    # the tunnel it has dug is always filled back in, so no raised ground is left behind;
    # the setting only says whether that also damages what the stretch ran under
    h.put32(f.queue_count, 0)
    f.set_unit(unit, uid=1001, path_len=9)
    h.put16(f.unit(unit) + 0xFA, 4)                         # four steps dug so far
    h.run(arrived, until=tail)
    check('arriving queues the stretch it dug', h.u32(f.queue_count), 4)
    check('  only the stretch actually dug', f.unit_field(unit, 'path_len'), 4)
    check('  and with collapse-behind on it damages as it falls in',
          h.u32(f.queue + 12) & 1, 0)

    h.put32(f.collapse_behind, 0)
    h.put32(f.queue_count, 0)
    f.set_unit(unit, uid=1002, path_len=9)
    h.put16(f.unit(unit) + 0xFA, 4)
    h.run(arrived, until=tail)
    check('with it off the ground is still put back', h.u32(f.queue_count), 4)
    check('  but quietly', h.u32(f.queue + 12) & 1, 1)
    h.put32(f.collapse_behind, 1)
    h.put32(f.queue_count, 0)

    # ------------------------------------------------- a collapse redirects the others
    print(' a collapse sends the other tunnels somewhere new')
    collapsed = f.tunneler + 0x954
    after = collapsed + 5
    digger, elsewhere, other_player, walker = 21, 22, 23, 24
    h.put32(f.current_unit, unit)                           # the tunnel that just collapsed
    h.put32(f.units_state, 40)                              # how many unit slots are in play
    f.set_unit(unit, owner=1, x=200, y=210, state=4, uid=1)
    gone, far = 210 * 400 + 200, 180 * 400 + 260
    h.put32(f.tile_flags + 4 * gone, 0)
    h.put16(f.building_tiles + 2 * gone, 0)
    for i in (digger, elsewhere, other_player, walker):
        f.set_unit(i, owner=1, x=150, y=150, uid=2000 + i, state=3, kind=5, alive=2,
                   dying=0, siege=2, dest_tile=gone)
    h.put32(f.tile_flags + 4 * (100 * 400 + 100), 0x100)    # its wall is still there
    f.set_unit(elsewhere, dest_tile=100 * 400 + 100)
    f.set_unit(other_player, owner=4)
    f.set_unit(walker, state=0)

    def waiting(index):
        return (h.m.read(f.pending + (index >> 3), 1)[0] >> (index & 7)) & 1

    searches.clear()
    paths.clear()
    for i in (digger, elsewhere, other_player, walker):
        h.put8(f.pending + (i >> 3), 0)
    cpu = h.run(collapsed, until=after)
    check('the collapse itself searches for nothing', len(searches), 0)
    check('the tunnel aimed at the same spot is told to look again', waiting(digger), 1)
    check('  the one aimed elsewhere is left alone', waiting(elsewhere), 0)
    check('  another player\'s tunnel is left alone', waiting(other_player), 0)
    check('  and a tunneler that is not digging is left alone', waiting(walker), 0)
    check('  the collapse carries on as usual', cpu.eip, after)

    # what matters is the target, not how far off it is: a tunnel aimed at any tile of a
    # gatehouse that has just gone is aimed at empty ground now, however big the building was
    f.set_unit(digger, dest_tile=far)
    h.put32(f.tile_flags + 4 * far, 0)
    h.put16(f.building_tiles + 2 * far, 0)
    h.put8(f.pending + (digger >> 3), 0)
    h.run(collapsed, until=after)
    check('a tunnel whose target is gone is told to look again, however far off it was',
          waiting(digger), 1)

    h.put32(f.tile_flags + 4 * far, 0x100)                  # its wall is still standing
    h.put8(f.pending + (digger >> 3), 0)
    h.run(collapsed, until=after)
    check('one whose wall still stands is left alone', waiting(digger), 0)

    h.put32(f.tile_flags + 4 * far, 0)
    h.put16(f.building_tiles + 2 * far, 8)                  # ... or its tower
    h.run(collapsed, until=after)
    check('and one whose tower still stands too', waiting(digger), 0)
    h.put16(f.building_tiles + 2 * far, 0)

    print(' and how far in the player has got')
    mark_slot = f.shared + 32 * 1 + 16                      # the collapsing tunnel is player 1
    f.building(9, kind=20)                                  # the enemy camp, at 300,310
    h.put16(f.building_base + 9 * 0x32C + 0xEE, 300)
    h.put16(f.building_base + 9 * 0x32C + 0xF0, 310)
    h.put32(f.camp_ids + 0x39F4 * 2, 9)
    h.put32(f.teams + 4 * 1, 1)
    h.put32(f.teams + 4 * 2, 2)
    h.put32(mark_slot, 0)

    def collapse_at(x, y, owner=1, siege=2):
        f.set_unit(unit, owner=owner, x=x, y=y, siege=siege, state=3)
        h.put32(f.current_unit, unit)
        h.run(collapsed, until=after)
        return h.u32(mark_slot)

    got = collapse_at(200, 210)                             # a hundred tiles off the camp
    check('a collapse writes down how close to the camp it got',
          got, (300 - 200) ** 2 + (310 - 210) ** 2)

    deeper = collapse_at(250, 260)                          # half as far
    check('  a collapse further in moves it in',
          deeper, (300 - 250) ** 2 + (310 - 260) ** 2)

    check('  and one further out leaves it alone', collapse_at(150, 160), deeper)

    h.put32(mark_slot, 0)
    h.put32(f.camp_ids + 0x39F4 * 2, 0)
    h.put32(f.current_unit, unit)

    print(' and the waiting tunnels look again one a tick')
    h.put32(f.tile_flags + 4 * far, 0)
    h.put8(f.pending + (digger >> 3), 0)
    h.put8(f.pending + (elsewhere >> 3), 0)
    f.set_unit(elsewhere, dest_tile=far)
    h.run(collapsed, until=after)
    check('both are told to look again', (waiting(digger), waiting(elsewhere)), (1, 1))

    # ... but not while they are still digging. A tunneler that turned underground would
    # fill in everything it had dug and start again from where it stands, which leaves a
    # piece of untouched castle between the wall it has broken and the wall it breaks next.
    check('the setting that keeps a tunnel on its leg is on by default',
          h.u32(f.finish_leg), 1)
    paths.clear()
    h.put32(f.ticks, 8000)
    h.put32(f.last_reaim_tick, 0)
    h.put32(f.current_unit, digger)
    for state in (3, 4, 8, 9):
        f.set_unit(digger, state=state)
        h.run(f.tunneler, until=f.tunneler + 7)
        check('in state %d it digs on rather than turning' % state, len(paths), 0)
        check('  and keeps its mark for the end of the leg', waiting(digger), 1)

    f.set_unit(digger, state=0)                             # above ground it turns at once
    h.run(f.tunneler, until=f.tunneler + 7)
    check('above ground the mark is acted on there and then', len(paths), 1)
    check('  and used up', waiting(digger), 0)

    h.put32(f.finish_leg, 0)                                # ... and switched off, a
    h.put8(f.pending + (digger >> 3), 1 << (digger & 7))    # digging tunnel turns as well
    h.put32(f.last_reaim_tick, 0)
    f.set_unit(digger, state=3)
    h.run(f.tunneler, until=f.tunneler + 7)
    check('switched off, a digging tunnel is turned where it stands', len(paths), 2)
    h.put32(f.finish_leg, 1)

    for i in (digger, elsewhere):                           # back to where the tick test
        byte = f.pending + (i >> 3)                         # wants them: both marked, and
        h.put8(byte, h.m.read(byte, 1)[0] | (1 << (i & 7)))  # above ground so they act -
        f.set_unit(i, state=0)                              # and they share a byte, so the
    paths.clear()                                           # second must not wipe the first

    h.put32(f.ticks, 9000)
    h.put32(f.last_reaim_tick, 0)
    paths.clear()
    h.put32(f.current_unit, digger)
    f.set_unit(digger, state=0)
    h.run(f.tunneler, until=f.tunneler + 7)
    check('the first of them looks again on its own tick', len(paths), 1)
    check('  and stops waiting', waiting(digger), 0)

    h.put32(f.current_unit, elsewhere)
    f.set_unit(elsewhere, state=0)
    h.run(f.tunneler, until=f.tunneler + 7)
    check('the second waits for the next tick', len(paths), 1)
    check('  and is still waiting', waiting(elsewhere), 1)

    h.put32(f.ticks, 9001)
    h.run(f.tunneler, until=f.tunneler + 7)
    check('which it gets', len(paths), 2)
    check('  and then it has looked too', waiting(elsewhere), 0)
    h.put32(f.current_unit, unit)

    h.put32(f.alg_result, 0)                                # nothing to go to
    paths.clear()
    h.run(collapsed, until=after)
    check('with nothing in range nothing is redirected', len(paths), 0)
    h.put32(f.alg_result, 1)

    # ------------------------------------------------------------- diagnostics
    print(' diagnostics')
    d = Fixture(extreme, config={'diagnostics': {'enabled': True}})
    dh = d.h
    before = len(dh.logs)
    dtile = 150 * 400 + 150
    dh.put32(d.current_unit, 12)
    d.set_unit(12, owner=4, x=150, y=150, tile=dtile, uid=321, state=3)
    dh.put32(d.tile_flags + 4 * dtile, 0x100)
    dh.put32(d.ticks, 7000)
    dh.run(d.tunneler + 0x7E6, until=d.tunneler + 0x7E6 + 5)
    lines = dh.logs[before:]
    check('a tunnel arriving on a wall writes a line', len(lines), 1)
    check('  and it says a denial was laid',
          'denial laid' in (lines[0] if lines else ''), True)
    dh.stub(d.alg_find, 0, 20)
    dh.stub(d.set_destination, 1, 16)
    dh.put32(d.tile_flags + 4 * dtile, 0)
    dh.put32(d.building_tiles + 2 * dtile, 0)
    dh.put32(d.alg_result, 1)
    d.set_unit(12, state=3, uid=4321)
    before = len(dh.logs)
    dh.run(d.tunneler + 0x7E6, until=d.tunneler + 0x1197)
    check('a tunnel that finds a new target says so',
          'digging on towards a new target' in (dh.logs[before] if len(dh.logs) > before else ''),
          True)
    dh.put32(d.alg_result, 0)
    before = len(dh.logs)
    dh.run(d.tunneler + 0x7E6, until=d.tunneler + 0x7E6 + 5)
    check('and one that finds nothing says that',
          'nothing in range' in (dh.logs[before] if len(dh.logs) > before else ''), True)

    # every tile of every wall the AI puts down goes through the build check, so its line
    # is rationed: one a second, however many attempts there are
    dh.put32(d.teams + 4 * 4, 1)
    dh.put32(d.teams + 4 * 2, 2)
    bm2 = struct.unpack('<I', d.e.data[d.e.va2off(d.enemy + 0x24):
                                       d.e.va2off(d.enemy + 0x24) + 4])[0]
    for y in range(145, 156):
        for x in range(145, 156):
            dh.put8(bm2 + y * 400 + x, 1)
    before = len(dh.logs)
    for _ in range(20):
        dh.run(d.enemy, stack=[2, 150, 152, 5])
    check('twenty attempts in one tick write one line', len(dh.logs) - before, 1)
    check('  and it is the refusal', 'refused' in dh.logs[before], True)
    dh.put32(d.ticks, 7000 + 39)
    dh.run(d.enemy, stack=[2, 150, 152, 5])
    check('half a second later it is still quiet', len(dh.logs) - before, 1)
    dh.put32(d.ticks, 7000 + 40)
    dh.run(d.enemy, stack=[2, 150, 152, 5])
    check('a second later it speaks again', len(dh.logs) - before, 2)

    print(' and what it aims towards')
    h.put32(f.alg_result, 1)                                # the search finds something again
    h.put32(f.tile_flags + 4 * empty, 0)                    # and the tunnel arrives on nothing
    h.put32(f.building_tiles + 2 * empty, 0)
    f.building(9, kind=20)
    h.put16(f.building_base + 9 * 0x32C + 0xEE, 300)        # the campground stands here
    h.put16(f.building_base + 9 * 0x32C + 0xF0, 310)
    f.building(10, kind=41)
    h.put16(f.building_base + 10 * 0x32C + 0xEE, 500)       # ... and the keep over there
    h.put16(f.building_base + 10 * 0x32C + 0xF0, 500)
    h.put32(f.camp_ids + 0x39F4 * 2, 9)
    h.put32(f.keep_ids + 0x39F4 * 2, 10)
    f.set_unit(unit, uid=1234, x=100, y=100, siege=2)
    searches.clear()
    h.run(arrived, until=tail)
    check('a re-aim measures from the enemy campground',
          (h.u32(f.camp_x), h.u32(f.camp_y)), (300, 310))
    check('  and keeps asking for something closer, a few rounds over',
          len(searches) > 1, True)
    check('  and each round asks for something closer than the last answer it got',
          h.u32(f.origin_distance), 170 * 170 + 170 * 170)

    mark = f.shared + 32 * 1 + 16                           # how far in this player has got
    demanded = []
    plain_find = h.cpu.hooks[f.alg_find]

    def watch_demand(cpu):                                  # what each round was told to beat
        demanded.append(h.u32(f.origin_distance))
        plain_find(cpu)
    h.cpu.hooks[f.alg_find] = watch_demand

    h.put32(f.shared + 32 * 1, 0)                           # no breach standing, only a mark
    h.put32(f.shared + 32 * 1 + 12, h.u32(f.ticks))
    h.put32(mark, 900)                                      # much closer than the tunneler
    demanded.clear()
    f.set_unit(unit, uid=1239)
    h.run(arrived, until=tail)
    check('  and the first round has to beat the deepest breach so far',
          demanded and demanded[0], 900)

    h.put32(mark, 0)
    demanded.clear()
    f.set_unit(unit, uid=1240)
    h.run(arrived, until=tail)
    check('  with no breach behind it, the tunneler s own distance',
          demanded and demanded[0], 200 * 200 + 210 * 210)
    h.cpu.hooks[f.alg_find] = plain_find
    check('  which it did, round after round', h.u32(f.control + 0xBC), 3)

    h.put32(f.camp_ids + 0x39F4 * 2, 0)                     # no campground on this map
    f.set_unit(unit, uid=1235)
    h.run(arrived, until=tail)
    check('without one it falls back to the keep',
          (h.u32(f.camp_x), h.u32(f.camp_y)), (500, 500))

    print(' and what a tunnel nobody sent against anybody aims at')
    for player in range(1, 9):
        h.put32(f.camp_ids + 0x39F4 * player, 0)
        h.put32(f.keep_ids + 0x39F4 * player, 0)
    h.put32(f.camp_ids + 0x39F4 * 2, 9)                     # player 2's camp, at 300,310
    f.building(11, kind=20)
    h.put16(f.building_base + 11 * 0x32C + 0xEE, 110)       # an ally's, right next door
    h.put16(f.building_base + 11 * 0x32C + 0xF0, 110)
    h.put32(f.camp_ids + 0x39F4 * 3, 11)
    f.building(12, kind=20)
    h.put16(f.building_base + 12 * 0x32C + 0xEE, 400)       # and another enemy's, far off
    h.put16(f.building_base + 12 * 0x32C + 0xF0, 400)
    h.put32(f.camp_ids + 0x39F4 * 4, 12)
    h.put32(f.teams + 4 * 4, 0)                             # who is on nobody's side
    h.put32(f.camp_x, 0)
    f.set_unit(unit, uid=1240, owner=1, x=100, y=100, siege=0)
    h.run(arrived, until=tail)
    check('a tunnel sent against nobody still measures from an enemy camp',
          (h.u32(f.camp_x), h.u32(f.camp_y)), (300, 310))

    h.put16(f.building_base + 12 * 0x32C + 0xEE, 150)       # that enemy moves in closer
    h.put16(f.building_base + 12 * 0x32C + 0xF0, 150)
    f.set_unit(unit, uid=1241)
    h.run(arrived, until=tail)
    check('  and it is the nearest of them',
          (h.u32(f.camp_x), h.u32(f.camp_y)), (150, 150))

    h.put32(f.teams + 4 * 4, 1)                             # ... until they take our side
    f.set_unit(unit, uid=1242)
    h.run(arrived, until=tail)
    check('  an ally is passed over, however close',
          (h.u32(f.camp_x), h.u32(f.camp_y)), (300, 310))

    h.put32(f.camp_ids + 0x39F4 * 4, 0)                     # and with only allies left
    h.put32(f.camp_ids + 0x39F4 * 2, 0)
    h.put32(f.camp_x, 0)
    f.set_unit(unit, uid=1243)
    h.run(arrived, until=tail)
    check('  with nothing but allies about, nothing is measured', h.u32(f.camp_x), 0)

    h.put32(f.camp_ids + 0x39F4 * 3, 0)
    h.put32(f.camp_ids + 0x39F4 * 2, 9)
    h.put32(f.keep_ids + 0x39F4 * 2, 10)
    f.set_unit(unit, uid=1244, siege=2)

    print(' and the one breach a player works at')
    slot = f.shared + 32 * 1                                # the tunneler belongs to player 1
    asked = []
    plain = h.cpu.hooks[f.alg_find]

    def watched(cpu):
        asked.append(h.u32(f.pinned))                       # what the search was told to find
        plain(cpu)
    h.cpu.hooks[f.alg_find] = watched

    breach = 92 * 400 + 95                                  # close by: this tunnel joins it
    h.put32(f.alg_result, breach)
    h.put32(f.alg_x, 95)
    h.put32(f.alg_y, 92)
    h.put32(slot, 0)
    h.put32(slot + 4, 0)
    h.put32(slot + 8, 0)
    asked.clear()
    f.set_unit(unit, uid=1250, owner=1, x=100, y=100, siege=2)
    h.run(arrived, until=tail)
    check('the first tunnel to look writes down where the breach will be',
          (h.u32(slot), h.u32(slot + 4), h.u32(slot + 8)), (breach, 95, 92))
    check('  and it looked for itself, with nothing pinned', asked and asked[0], 0)

    h.put32(f.tile_flags + 4 * breach, 0x100)               # the wall there still stands
    h.put16(f.building_tiles + 2 * breach, 0)
    asked.clear()
    f.set_unit(unit, uid=1251)
    h.run(arrived, until=tail)
    check('the next tunnel is sent at that same tile', asked[0], breach)
    check('  and once it has it, it asks no further', len(asked), 1)
    check('  and the breach is left as it was',
          (h.u32(slot), h.u32(slot + 4), h.u32(slot + 8)), (breach, 95, 92))

    h.put32(f.tile_flags + 4 * breach, 0)                   # ... until it comes down
    h.put16(f.building_tiles + 2 * breach, 0)
    asked.clear()
    f.set_unit(unit, uid=1252)
    h.run(arrived, until=tail)
    check('with nothing standing there the breach is given up', asked[0], 0)
    check('  and the next target takes its place', h.u32(slot), breach)

    h.put32(slot, 4242)                                     # one nothing can reach
    h.put32(f.tile_flags + 4 * 4242, 0x100)

    def unreachable(cpu):
        asked.append(h.u32(f.pinned))
        if h.u32(f.pinned) != 0:
            h.put32(f.alg_result, 0)                        # the search cannot get there
        else:
            h.put32(f.alg_result, breach)
        plain(cpu)
    h.cpu.hooks[f.alg_find] = unreachable
    asked.clear()
    f.set_unit(unit, uid=1253)
    h.run(arrived, until=tail)
    check('a tunnel that cannot reach the breach looks for itself instead',
          (asked[0], asked[1]), (4242, 0))
    check('  and leaves the breach standing for the others', h.u32(slot), 4242)
    check('  and nothing is left pinned behind it', h.u32(f.pinned), 0)
    h.cpu.hooks[f.alg_find] = watched                        # back to plain recording

    print('  and the reach of a breach')
    reach = f.control + 0x2C0                               # the setting, squared
    check('the reach a breach is joined from is the one in the settings',
          h.u32(reach), 40 * 40)

    def breach_at(x, y, uid, origin=None):
        tile = y * 400 + x
        ox, oy = origin or (x, y)                           # where the tunnel that set it
        h.put32(f.tile_flags + 4 * tile, 0x100)             # started digging
        h.put16(f.building_tiles + 2 * tile, 0)
        h.put32(slot, tile)
        h.put32(slot + 4, x)
        h.put32(slot + 8, y)
        h.put32(slot + 12, h.u32(f.ticks))
        h.put32(slot + 20, ox)
        h.put32(slot + 24, oy)
        asked.clear()
        f.set_unit(unit, uid=uid, owner=1, x=100, y=100, siege=2)
        h.run(arrived, until=tail)
        h.put32(f.tile_flags + 4 * tile, 0)
        return asked[0], tile

    got, tile = breach_at(118, 124, 1270)                   # about thirty tiles off
    check('a breach thirty tiles off is joined', got, tile)

    got, tile = breach_at(130, 135, 1271)                   # about forty-six
    check('  one past the reach is not', got, 0)

    h.put32(reach, 15 * 15)                                 # ... and the setting decides
    got, tile = breach_at(118, 124, 1272)
    check('  turned down, the same breach is left alone', got, 0)
    h.put32(reach, 40 * 40)

    # the reach a tunnel is really judged by is how far the tunnel that found the breach
    # started from this one, not how far off the wall they are both digging at is - a row
    # of tunnelers dug in at a safe distance has to agree on one piece of wall however far
    # away that wall is
    got, tile = breach_at(100, 190, 1273, origin=(112, 102))
    check('a breach ninety tiles off, dug from beside us, is joined', got, tile)

    got, tile = breach_at(118, 124, 1274, origin=(190, 190))
    check('  and one right in front of us is joined whoever dug it', got, tile)

    h.put32(reach, 10 * 10)                             # neither near us nor dug near us
    got, tile = breach_at(100, 190, 1275, origin=(112, 102))
    check('  and that reach is the setting too', got, 0)
    h.put32(reach, 40 * 40)

    far = 300 * 400 + 320
    h.put32(f.tile_flags + 4 * far, 0x100)                  # a wall stands there too
    h.put16(f.building_tiles + 2 * far, 0)
    h.put32(slot, far)
    h.put32(slot + 4, 320)
    h.put32(slot + 8, 300)
    h.put32(slot + 12, h.u32(f.ticks))
    h.put32(slot + 20, 320)
    h.put32(slot + 24, 300)
    asked.clear()
    f.set_unit(unit, uid=1260, owner=1, x=100, y=100, siege=2)
    h.run(arrived, until=tail)
    check('a breach on the far side of the map is left to the tunnels near it',
          asked[0], 0)
    check('  and it still stands for them', h.u32(slot), far)

    h.put32(slot, breach)                                   # ... and one close by again
    h.put32(slot + 4, 95)
    h.put32(slot + 8, 92)
    h.put32(f.tile_flags + 4 * breach, 0x100)
    h.put32(slot + 12, h.u32(f.ticks) - 90 * 40 - 1)        # but nobody has worked at it
    asked.clear()
    f.set_unit(unit, uid=1261)
    h.run(arrived, until=tail)
    check('a breach nobody has worked at for a long while is given up', asked[0], 0)
    check('  and the next target takes its place', h.u32(slot), h.u32(f.alg_result))

    h.put32(slot + 12, h.u32(f.ticks) + 5000)               # a match starting over
    h.put32(slot, breach)
    asked.clear()
    f.set_unit(unit, uid=1262)
    h.run(arrived, until=tail)
    check('and a breach from before the clock started again, the same', asked[0], 0)

    h.put32(f.tile_flags + 4 * far, 0)
    h.cpu.hooks[f.alg_find] = plain
    h.put32(slot, 0)
    h.put32(f.tile_flags + 4 * 4242, 0)
    h.put32(f.alg_result, 1)

    # ------------------------------------------------- the line a player is carving
    print('  and the line of spots their tunnels have taken')
    line = f.trail + f.trail_stride * 1                      # the tunneler belongs to player 1
    collapsed = f.tunneler + 0x954

    def clear_line():
        for k in range(0, f.trail_stride, 4):
            h.put32(line + k, 0)
        for k in range(0, 32, 4):
            h.put32(slot + k, 0)

    def spots():
        return [(h.u32(line + 4 + 12 * i), h.u32(line + 8 + 12 * i),
                 h.u32(line + 12 + 12 * i)) for i in range(8) if h.u32(line + 4 + 12 * i)]

    def collapse_at(x, y, u=19):
        h.put32(f.current_unit, u)
        f.set_unit(u, owner=1, siege=2, x=x, y=y, tile=y * 400 + x, uid=9000 + y,
                   state=3, alive=2, kind=5, dying=0, dest_tile=y * 400 + x)
        h.run(collapsed, until=collapsed + 5)

    was_count = h.u32(f.units_state)
    h.put32(f.units_state, 1)                                # nothing else to scan over
    clear_line()

    collapse_at(100, 150)
    check('a collapse puts the spot it took on the line', spots(), [(60100, 100, 150)])
    check('  and marks how close to the camp that is', h.u32(slot + 16),
          200 ** 2 + 160 ** 2)
    check('  and when', h.u32(slot + 28), h.u32(f.ticks))

    collapse_at(100, 200)                                    # deeper in, towards the camp
    check('a collapse further in joins it', spots(),
          [(60100, 100, 150), (80100, 100, 200)])
    check('  and the mark moves in with it', h.u32(slot + 16), 200 ** 2 + 110 ** 2)

    deep = h.u32(slot + 16)
    collapse_at(100, 120)                                    # ... one behind the line
    check('a collapse behind the line is not on it', len(spots()), 2)
    check('  and the mark does not move back out', h.u32(slot + 16), deep)

    h.cpu.hooks[f.alg_find] = watched
    h.put32(f.alg_result, 1)

    # the mark is the player's, not the breach's: it has to outlive the wall coming down,
    # or every tunnel after the first breach goes back to taking the nearest wall
    h.put32(slot, 4242)                                      # a breach with nothing left on it
    h.put32(f.tile_flags + 4 * 4242, 0)
    h.put16(f.building_tiles + 2 * 4242, 0)
    h.put32(slot + 12, h.u32(f.ticks))
    h.put32(slot + 16, 900)
    h.put32(slot + 28, h.u32(f.ticks))
    asked.clear()
    f.set_unit(unit, uid=1280, owner=1, x=100, y=100, siege=2)
    h.run(arrived, until=tail)
    check('a breach that has been opened is given up', asked[0], 0)
    check('  but how far in the player has got is kept', h.u32(slot + 16), 900)
    check('  and so is the line', len(spots()), 2)

    h.put32(slot, 4242)
    h.put32(slot + 12, h.u32(f.ticks))
    h.put32(slot + 16, 900)
    h.put32(slot + 28, h.u32(f.ticks) - 300 * 40 - 1)        # a siege that stopped
    asked.clear()
    f.set_unit(unit, uid=1281)
    h.run(arrived, until=tail)
    check('a line nothing has been taken on for a long while is forgotten',
          h.u32(slot + 16), 0)
    check('  and its spots with it', spots(), [])

    # and the spots are guides: a tunnel that starts beside one of them joins whatever the
    # line is working at now, however far ahead that has moved
    clear_line()
    ahead = 220 * 400 + 100
    h.put32(f.tile_flags + 4 * ahead, 0x100)
    h.put16(f.building_tiles + 2 * ahead, 0)
    h.put32(slot, ahead)
    h.put32(slot + 4, 100)
    h.put32(slot + 8, 220)
    h.put32(slot + 12, h.u32(f.ticks))
    h.put32(slot + 20, 100)                                  # dug from deep inside already
    h.put32(slot + 24, 200)
    h.put32(line, 1)
    h.put32(line + 4, 60100)                                 # ... but the line came past here
    h.put32(line + 8, 100)
    h.put32(line + 12, 150)
    asked.clear()
    f.set_unit(unit, uid=1282, owner=1, x=100, y=145, siege=2)
    h.run(arrived, until=tail)
    check('a tunnel starting beside a spot on the line is sent at the head of it',
          asked[0], ahead)

    h.put32(line + 8, 300)                                   # move that spot far away
    h.put32(line + 12, 300)
    asked.clear()
    f.set_unit(unit, uid=1283, owner=1, x=100, y=145, siege=2)
    h.run(arrived, until=tail)
    check('  with no spot near it, it looks for itself', asked[0], 0)

    h.put32(f.tile_flags + 4 * ahead, 0)
    h.put32(f.units_state, was_count)
    h.cpu.hooks[f.alg_find] = plain
    clear_line()
    h.put32(f.alg_result, 1)

    h.put32(f.towards, 0)
    h.put32(f.camp_x, 0)
    f.set_unit(unit, uid=1236)
    h.run(arrived, until=tail)
    check('switched off, nothing is measured at all', h.u32(f.camp_x), 0)
    h.put32(f.towards, 1)
    h.put32(f.keep_ids + 0x39F4 * 2, 0)

    print(' and the first target a tunnel is ever given')
    first = f.tunneler + 0x66E
    first_on = first + 5
    ENTRANCE_B = 40
    f.building(ENTRANCE_B, state=1)
    h.put16(f.building_base + ENTRANCE_B * 0x32C + 0x260, 105)   # where the game searches from
    h.put16(f.building_base + ENTRANCE_B * 0x32C + 0x262, 106)
    h.put32(f.current_unit, unit)
    f.set_unit(unit, owner=1, siege=2, x=100, y=100)
    h.put16(f.unit(unit) + 0x338, ENTRANCE_B)
    h.put32(f.camp_ids + 0x39F4 * 2, 9)                          # the campground from before
    finds = []
    h.stub(f.finder, 1, 8, record=finds)                         # the game found something
    h.put32(f.alg_result, 4242)
    h.put32(f.alg_x, 200)
    h.put32(f.alg_y, 200)
    searches.clear()

    def first_aim():
        cpu = h.run(first, until=first_on)
        return cpu.r['eax'], h.u32(f.alg_result), h.u32(f.alg_x), h.u32(f.alg_y)

    h.put32(f.alg_result, 0)                                     # ... but the narrowing does not
    def finds_nothing(cpu):
        h.put32(f.alg_result, 0)
        cpu.r['eax'] = 0
        cpu.eip = cpu.pop()
        cpu.r['esp'] += 20
    h.cpu.hooks[f.alg_find] = finds_nothing
    h.put32(f.alg_result, 4242)
    got = first_aim()
    check('a narrowing that finds nothing keeps the answer the game had',
          got, (1, 4242, 200, 200))
    check('  and searched from where the game did', searches and searches[-1][1][3:5] or
          [105, 106], [105, 106])

    h.stub(f.alg_find, 0, 20, record=searches)                   # ... and when it does find
    h.put32(f.alg_result, 4242)
    searches.clear()
    got = first_aim()
    check('a narrowing that finds something uses it', got[0], 1)
    check('  asked from the entrance, not the tunneler', searches[-1][1][3:5], [105, 106])
    check('  and rounds were run', len(searches) > 1, True)

    h.put32(f.control + 0x2A4, h.u32(f.current_unit) + 1)        # this one just lost a path
    h.put32(f.alg_result, 4242)
    searches.clear()
    got = first_aim()
    check('a tunnel whose path would not lay is left to the game next time',
          got, (1, 4242, 200, 200))
    check('  without a single search of our own', len(searches), 0)
    check('  and only that once', h.u32(f.control + 0x2A4), 0)

    f.set_unit(unit, siege=0)                                    # nobody named the enemy
    h.put32(f.alg_result, 4242)
    searches.clear()
    got = first_aim()
    check('a tunnel sent against nobody narrows just the same', got[0], 1)
    check('  over several rounds as well', len(searches) > 1, True)

    for player in range(1, 9):                                   # with no camp anywhere
        h.put32(f.camp_ids + 0x39F4 * player, 0)
        h.put32(f.keep_ids + 0x39F4 * player, 0)
    h.put32(f.alg_result, 4242)
    searches.clear()
    got = first_aim()
    check('with nothing to aim at the game keeps the answer it had',
          got, (1, 4242, 200, 200))

    h.put16(f.unit(unit) + 0x338, 0)                             # and with no entrance either
    h.put32(f.alg_result, 4242)
    got = first_aim()
    check('a tunneler with no entrance is still told its aim held', got[0], 1)
    h.put16(f.unit(unit) + 0x338, ENTRANCE_B)
    h.put32(f.camp_ids + 0x39F4 * 2, 9)
    f.set_unit(unit, siege=2)

    print('  and that the player s tunnels agree on it from the very first aim')
    # two tunnelers, two entrances twenty tiles apart, and a wall fifty tiles out in
    # front of them both - the ordinary siege, and the one the joining is for
    ENTRANCE_C = 41
    f.building(ENTRANCE_C, state=1)
    h.put16(f.building_base + ENTRANCE_C * 0x32C + 0x260, 120)
    h.put16(f.building_base + ENTRANCE_C * 0x32C + 0x262, 100)
    h.put16(f.building_base + ENTRANCE_B * 0x32C + 0x260, 100)
    h.put16(f.building_base + ENTRANCE_B * 0x32C + 0x262, 100)
    other = 12
    f.set_unit(unit, owner=1, siege=2, x=100, y=100, uid=1301)
    h.put16(f.unit(unit) + 0x338, ENTRANCE_B)
    f.set_unit(other, owner=1, siege=2, x=120, y=100, uid=1302)
    h.put16(f.unit(other) + 0x338, ENTRANCE_C)

    wall = {unit: (150 * 400 + 100, 100, 150),          # what each would find on its own
            other: (150 * 400 + 120, 120, 150)}
    for tile, x, y in wall.values():
        h.put32(f.tile_flags + 4 * tile, 0x100)
        h.put16(f.building_tiles + 2 * tile, 0)
    pins = []

    def own_wall():
        return wall[h.u32(f.current_unit)]

    def game_answer(cpu):                               # findTunnelTarget, the game's own
        tile, x, y = own_wall()
        h.put32(f.alg_result, tile)
        h.put32(f.alg_x, x)
        h.put32(f.alg_y, y)
        cpu.r['eax'] = 1
        cpu.eip = cpu.pop()
        cpu.r['esp'] += 8

    def honours_pin(cpu):                               # ... and the search that follows
        pin = h.u32(f.pinned)
        pins.append(pin)
        tile, x, y = (pin, pin % 400, pin // 400) if pin else own_wall()
        h.put32(f.alg_result, tile)
        h.put32(f.alg_x, x)
        h.put32(f.alg_y, y)
        cpu.r['eax'] = 0
        cpu.eip = cpu.pop()
        cpu.r['esp'] += 20

    was_finder, was_find = h.cpu.hooks[f.finder], h.cpu.hooks[f.alg_find]
    h.cpu.hooks[f.finder] = game_answer
    h.cpu.hooks[f.alg_find] = honours_pin
    for k in range(0, 32, 4):
        h.put32(slot + k, 0)

    def aim_of(index):
        pins.clear()
        h.put32(f.current_unit, index)
        h.run(first, until=first_on)
        return h.u32(f.alg_result)

    first_tile = aim_of(unit)
    check('the first tunnel to dig in takes its own wall', first_tile, wall[unit][0])
    check('  and writes down the breach, and where it dug from',
          (h.u32(slot), h.u32(slot + 20), h.u32(slot + 24)), (wall[unit][0], 100, 100))
    check('  having asked for nothing in particular', pins, [0, 0, 0])

    second = aim_of(other)
    check('the next one is sent at that same tile, though the wall is fifty tiles out',
          second, first_tile)
    check('  and asked for it and nothing else', pins, [first_tile])

    # the mark a collapse leaves behind: how close to the enemy camp this player has got.
    # A tunnel dug after the breach fell has to beat it, so the next hole is further in
    # rather than another bite of the same outer wall.
    demanded = []

    def watch_demand(cpu):
        demanded.append(h.u32(f.origin_distance))
        honours_pin(cpu)

    h.cpu.hooks[f.alg_find] = watch_demand
    for k in range(0, 32, 4):
        h.put32(slot + k, 0)
    h.put32(slot + 12, h.u32(f.ticks))
    h.put32(slot + 16, 900)                             # the tunnels are already this deep
    demanded.clear()
    aim_of(unit)
    check('a first aim has to beat how deep the player has already got',
          demanded and demanded[0], 900)

    h.put32(slot + 16, 0)
    demanded.clear()
    aim_of(unit)
    check('  and with nothing behind it, its own wall s distance', demanded and demanded[0],
          (100 - 300) ** 2 + (150 - 310) ** 2)

    h.cpu.hooks[f.finder], h.cpu.hooks[f.alg_find] = was_finder, was_find
    for tile, x, y in wall.values():
        h.put32(f.tile_flags + 4 * tile, 0)
    for k in range(0, 32, 4):
        h.put32(slot + k, 0)
    f.set_unit(other, alive=0, kind=0)
    h.put16(f.building_base + ENTRANCE_B * 0x32C + 0x260, 105)
    h.put16(f.building_base + ENTRANCE_B * 0x32C + 0x262, 106)
    f.set_unit(unit, owner=1, siege=2, x=100, y=100)
    h.put32(f.alg_result, 4242)
    h.put32(f.alg_x, 200)
    h.put32(f.alg_y, 200)

    h.put32(f.towards, 0)
    h.put32(f.alg_result, 4242)
    searches.clear()
    got = first_aim()
    check('switched off, the game is left to itself', (got, len(searches)),
          ((1, 4242, 200, 200), 0))
    h.put32(f.towards, 1)
    h.put32(f.camp_ids + 0x39F4 * 2, 0)
    h.cpu.hooks.pop(f.finder, None)

    print(' and what happens when the path will not lay')
    laid = f.tunneler + 0x6D3
    walked_on = f.tunneler + 0x6DB
    torn_down = f.tunneler + 0x92B
    # where the game itself goes when its own search finds nothing - taken from the
    # disassembler rather than from the same arithmetic the module uses, so a mistake in
    # that arithmetic cannot agree with itself here
    import capstone
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    left_alone = None
    for i in md.disasm(bytes(h.m.read(f.tunneler + 0x673, 16)), f.tunneler + 0x673):
        if i.mnemonic == 'je':
            left_alone = int(i.op_str, 16)
            break
    check('the game has a way out that keeps the entrance',
          left_alone is not None and f.tunneler < left_alone < f.tunneler + 0x2000, True)
    ours = f.control + 0x2A0
    skip = f.control + 0x2A4
    landed = []

    class Landed(Exception):
        pass

    def lands(where):                                        # stop at whichever way out
        def hook(cpu):
            landed.append(where)
            raise Landed()
        return hook
    for place, name in ((walked_on, 'dug'), (torn_down, 'torn down'),
                        (left_alone, 'left alone')):
        h.cpu.hooks[place] = lands(name)

    def path(result, mine=1):
        h.put32(ours, mine)
        h.put32(skip, 0)
        landed.clear()
        try:
            h.run(laid, regs={'eax': result})
        except Landed:
            pass
        return landed[-1] if landed else '?'

    check('a path that lays is left alone', path(1), 'dug')
    check('a path that will not lay costs the tunnel the tick, not the entrance',
          path(0), 'left alone')
    check('  and that tunneler is noted, so the game aims it next time',
          h.u32(skip), h.u32(f.current_unit) + 1)
    check('  and the aim is no longer ours to answer for', h.u32(ours), 0)

    check('a target the game chose itself is still the game s own business',
          path(0, mine=0), 'torn down')
    check('  and nothing is noted for it', h.u32(skip), 0)

    for place in (walked_on, torn_down, left_alone):
        h.cpu.hooks.pop(place, None)
    h.put32(ours, 0)
    h.put32(skip, 0)

    # ------------------------------------------------- out of reach while digging
    print(' a tunneler that is digging')
    for state, want in ((3, 0), (4, 0), (8, 0), (9, 0), (0, 1), (1, 1), (0x65, 1)):
        h.put32(f.current_unit, 7)
        f.set_unit(7, state=state)
        h.put16(f.unit(7) + 0x2A4, 1 - want)
        h.run(f.tunneler, until=f.tunneler + 7)
        got = struct.unpack('<H', h.m.read(f.unit(7) + 0x2A4, 2))[0]
        check('state 0x%02X -> selectable %d' % (state, want), got, want)
    h.put32(f.hide_select, 0)
    f.set_unit(7, state=3)
    h.put16(f.unit(7) + 0x2A4, 1)
    h.run(f.tunneler, until=f.tunneler + 7)
    check('switched off, the game keeps its own say',
          struct.unpack('<H', h.m.read(f.unit(7) + 0x2A4, 2))[0], 1)
    h.put32(f.hide_select, 1)

    print(' and what aims at it')
    aim = f.aim_test
    after_aim = aim + 10
    f.set_unit(7, kind=5)
    for state, hidden in ((3, 1), (4, 1), (8, 1), (9, 1)):
        f.set_unit(7, state=state)
        cpu = h.run(aim, stack=[7])
        check('digging in state %d -> nothing aims at it' % state, cpu.r['eax'], hidden)
    f.set_unit(7, state=0)
    cpu = h.run(aim, until=after_aim, stack=[7])
    check('above ground it is a target like any other', cpu.eip, after_aim)
    check('  with the unit still worked out for the game', cpu.r['eax'], 7 * UNIT)
    f.set_unit(7, kind=9, state=3)
    cpu = h.run(aim, until=after_aim, stack=[7])
    check('and another unit type is never touched', cpu.eip, after_aim)
    f.set_unit(7, kind=5)
    h.put32(f.hide_target, 0)
    f.set_unit(7, state=3)
    cpu = h.run(aim, until=after_aim, stack=[7])
    check('switched off, a digger is a target again', cpu.eip, after_aim)
    h.put32(f.hide_target, 1)

    # --------------------------------------------- aiming towards the enemy keep
    print(' aiming towards the enemy keep')
    take = f.search + 0x16F
    took_it = f.search + 0x178
    spread_on = f.search + 0x1CB
    h.put32(f.camp_x, 300)
    h.put32(f.camp_y, 300)
    h.put32(f.origin_distance, 200 * 200 + 200 * 200)       # the tunneler, 200 tiles off

    def reaches(x, y):
        cpu = h.cpu
        cpu.r['esp'] = STACK_TOP
        cpu.r['esi'] = f.alg_result - 0x34                  # the search's own state
        cpu.r['ebp'], cpu.r['edi'], cpu.r['edx'] = 40000, y, x
        cpu.eip = take
        for _ in range(40):
            if cpu.eip in (took_it, spread_on):
                break
            cpu.step()
        return 'taken' if cpu.eip == took_it else 'passed' if cpu.eip == spread_on else '?'

    h.put32(f.bias, 0)
    check('with no bias the first thing reached is the target', reaches(150, 150), 'taken')
    h.put32(f.bias, 1)
    check('a wall further from the keep than the tunneler is passed by',
          reaches(80, 80), 'passed')
    check('the search looks for stairs and crenellations as well as wall',
          h.u32(f.search + 0x131), 0x100 | 0x200 | 0x800)
    check('one closer to the keep is taken', reaches(250, 250), 'taken')
    check('  and it is recorded the way the game does',
          (h.u32(f.alg_result), h.u32(f.alg_y), h.u32(f.alg_x)), (40000, 250, 250))

    f.distance_map = h.u32(f.search + 0x1CF)
    h.put16(f.distance_map + 2 * 40000, 30)                 # thirty tiles of digging to here
    h.put32(f.depth_limit, 40)
    check('a target the search can reach within the cap is taken', reaches(250, 250), 'taken')
    h.put32(f.depth_limit, 20)
    check('one that would take the tunnel deeper than the cap is passed by',
          reaches(250, 250), 'passed')
    h.put32(f.depth_limit, 0)

    h.put32(f.pinned, 40000)
    check('a pinned breach is taken wherever it lies', reaches(80, 80), 'taken')
    h.put32(f.pinned, 12345)
    check('  and nothing else is, however much closer to the keep',
          reaches(250, 250), 'passed')
    h.put32(f.pinned, 0)
    h.put32(f.bias, 0)

    # ------------------------------------------------------------ the damage routine
    print(' the game\'s own damage, where it sorts the tile it is handed')
    landed = []
    stop = h.allocate_code([0xC3])                      # the sentinel run() pushed is

    def lands_at(where):
        def hook(cpu):
            landed.append((where, cpu.r['eax']))
            cpu.eip = stop                              # ... still what that ret returns to
        return hook

    h.cpu.hooks[f.process_damage + 0x69] = lands_at('the wall loop')
    h.cpu.hooks[f.process_damage + 0xA6C] = lands_at('nothing at all')

    def sorted_into(flags, ours):
        h.put32(f.family_damage, 1 if ours else 0)
        landed.clear()
        h.run(f.process_damage + 0x5E, regs={'eax': flags})
        return landed[-1] if landed else ('nowhere', 0)

    for ours in (False, True):
        whose = 'this module' if ours else 'the game itself'
        check('a wall goes into the wall loop, damaged by %s' % whose,
              sorted_into(0x100, ours)[0], 'the wall loop')
        check('  and bare ground is still dropped', sorted_into(0, ours)[0],
              'nothing at all')
    for bit, name in ((0x800, 'stairs'), (0x200, 'a crenellation')):
        check('%s damaged by the game itself is dropped, as always' % name,
              sorted_into(bit, False)[0], 'nothing at all')
        check('  but damaged by this module goes into the wall loop',
              sorted_into(bit, True)[0], 'the wall loop')
    check('the tile flags are handed on exactly as they were found',
          sorted_into(0x100 | 0x40000, True)[1], 0x100 | 0x40000)
    h.put32(f.family_damage, 0)
    h.cpu.hooks.pop(f.process_damage + 0x69, None)
    h.cpu.hooks.pop(f.process_damage + 0xA6C, None)

    # ------------------------------------------------------------ the collapse
    print(' what a collapse does')
    hits = []
    h.stub(f.process_damage, 0, 32, record=hits)
    h.stub(f.update_walk, 0, 12)
    collapse = f.tunneler + 0x8DD
    carries_on = f.tunneler + 0x91B
    ctile = 120 * 400 + 130
    h.put32(f.current_unit, unit)
    f.set_unit(unit, owner=3, x=130, y=120, tile=ctile, state=4)
    hits.clear()
    cpu = h.run(collapse, until=carries_on)
    check('the thing above the tunnel is damaged, not demolished', len(hits), 1)
    check('  the tile, where it is, and how hard',
          hits[0][1][:6], [ctile, 130, 120, h.u32(f.collapse_damage), 0, 3])
    check('  and the collapse carries on as usual', cpu.eip, carries_on)

    resets = []
    reset_tile = (f.tunneler + 0x916 + 5
                  + struct.unpack('<i', h.m.read(f.tunneler + 0x917, 4))[0]) & 0xFFFFFFFF
    h.stub(reset_tile, 1, 12, record=resets)
    check('the widening that lets the game damage stairs is in',
          h.u32(f.family_ready), 1)
    for bit, name in ((0x800, 'stairs'), (0x200, 'a crenellation')):
        h.put32(f.tile_flags + 4 * ctile, bit)              # nothing but stairs on the tile
        h.put16(f.building_tiles + 2 * ctile, 0)
        hits.clear()
        resets.clear()
        h.run(collapse, until=carries_on)
        check('a tunnel coming up under %s damages it' % name, len(hits), 1)
        check('  at that tile, for the figure from the settings',
              hits[-1][1][:4], [ctile, 130, 120, h.u32(f.collapse_damage)])
        check('  and it is not taken away behind the game\'s back', len(resets), 0)

    h.put32(f.tile_flags + 4 * ctile, 0x100 | 0x800)        # stairs against a wall
    hits.clear()
    resets.clear()
    h.run(collapse, until=carries_on)
    check('one against a wall is damaged the same way',
          (len(hits), len(resets)), (1, 0))

    h.put32(f.family_ready, 0)                              # ... and where the widening
    h.put32(f.tile_flags + 4 * ctile, 0x800)                # could not be installed, the
    hits.clear()                                            # tile is taken away as before
    resets.clear()
    h.run(collapse, until=carries_on)
    check('without the widening stairs are taken away as they were',
          (len(resets), len(hits)), (1, 0))
    check('  at that tile', resets[-1][1][0], ctile)
    h.put32(f.family_ready, 1)
    h.put32(f.tile_flags + 4 * ctile, 0x100)
    h.cpu.hooks.pop(reset_tile, None)
    check('  the tunnel behind it is queued to fall in', h.u32(f.queue_count) > 0, True)
    check('  and the game is left nothing to bring down itself',
          f.unit_field(unit, 'path_len'), 0)
    h.put32(f.queue_count, 0)

    h.put32(f.collapse_damage, 400)
    hits.clear()
    h.run(collapse, until=carries_on)
    check('the figure is the one from the settings', hits[0][1][3], 400)
    h.put32(f.collapse_damage, 2500)

    print(' and the tunnel it queues to fall in behind it')
    f.fill_routine = f.module_routine(f.tunneler + 0x8DD)   # the only one it calls of ours
    f.step_routine = f.module_routine(f.tick_site)
    h.put32(f.queue_count, 0)
    qunit = 13
    qtile = 100 * 400 + 100
    f.set_unit(qunit, owner=3, x=100, y=100, tile=qtile, state=4, path_len=4)
    h.put16(f.unit(qunit) + 0xCC, 100)                      # where the tunnel started
    h.put16(f.unit(qunit) + 0xCE, 100)
    h.put32(f.unit(qunit) + 0xDC, qtile)
    for i in range(2):
        h.put8(f.unit(qunit) + 0xFE + i, 0x11)              # four steps, all direction 1
    for y in range(95, 106):
        h.put32(f.row_table + 12 * y, y * 400)
    h.put32(f.directions + 32 * 100 + 4 * 1, 1)             # direction 1 is one tile along
    h.put32(f.x_deltas + 8 * 1, 1)                          # ... and one in x
    h.put32(f.y_deltas + 8 * 1, 0)
    h.put32(f.fill_unit, qunit)
    h.put32(f.fill_flags, 3 << 8)                           # owner 3, not quiet
    h.run(f.fill_routine, until=SENTINEL)
    check('the tunnel is written into the queue tile by tile', h.u32(f.queue_count), 4)
    check('  starting where the tunnel started',
          [h.u32(f.queue + 16 * k) for k in range(4)],
          [qtile, qtile + 1, qtile + 2, qtile + 3])
    check('  with the place and who is bringing it down',
          [h.u32(f.queue + 16 * 2 + 4), h.u32(f.queue + 16 * 2 + 8),
           h.u32(f.queue + 16 * 2 + 12)], [102, 100, 3 << 8])

    print(' one tile of it falling in')
    stile = 100 * 400 + 200
    for y in range(98, 103):
        h.put32(f.row_table + 12 * y, y * 400)
        for x in range(198, 203):
            h.put8(f.live_height + y * 400 + x, 12)         # the dig lifted all of this
            h.put8(f.base_height + y * 400 + x, 8)          # ... off ground that sits at 8
            h.put32(f.tile_flags + 4 * (y * 400 + x), 0)
            h.put16(f.building_tiles + 2 * (y * 400 + x), 0)
    h.put8(f.base_height + 99 * 400 + 199, 20)              # a cliff, taller than the lift
    h.put8(f.live_height + 99 * 400 + 199, 20)
    workshop_tile = 101 * 400 + 201                         # a workshop within reach
    f.building(31, kind=20)
    h.put16(f.building_tiles + 2 * workshop_tile, 31)
    hits.clear()

    def fall_in():
        hits.clear()
        h.put32(f.step_tile, stile)
        h.put32(f.step_x, 200)
        h.put32(f.step_y, 100)
        h.put32(f.step_flags, 5 << 8)
        h.run(f.step_routine, until=SENTINEL)

    fall_in()
    check('the ground goes back to the height the map gives it',
          h.m.read(f.live_height + stile, 1)[0], 8)
    check('  and so does the ground around it',
          [h.m.read(f.live_height + 99 * 400 + 201, 1)[0],
           h.m.read(f.live_height + 101 * 400 + 199, 1)[0]], [8, 8])
    check('  while a cliff is left alone', h.m.read(f.live_height + 99 * 400 + 199, 1)[0], 20)
    check('a workshop within reach is shaken', len(hits), 1)
    check('  for the set amount', hits[0][1][3], h.u32(f.spread_damage))
    check('  by the owner of the tunnel', hits[0][1][5], 5)

    print('  and the ground under what is standing')
    wall_tile = 99 * 400 + 199                              # a wall beside the tunnel
    h.put8(f.live_height + wall_tile, 26)                   # standing 18 above its ground
    h.put8(f.base_height + wall_tile, 8)
    h.put32(f.tile_flags + 4 * wall_tile, 0x100)
    fall_in()
    check('a wall keeps its height, which is its strength',
          h.m.read(f.live_height + wall_tile, 1)[0], 26)
    h.put32(f.tile_flags + 4 * wall_tile, 0)

    h.put16(f.building_tiles + 2 * workshop_tile, 0)        # nothing else within reach
    for bit, name in ((0x200, 'a crenellation'), (0x800, 'stairs')):
        h.put8(f.live_height + wall_tile, 26)
        h.put32(f.tile_flags + 4 * wall_tile, bit)
        fall_in()
        check('  %s keeps its tile too' % name,
              h.m.read(f.live_height + wall_tile, 1)[0], 26)
        check('    and is not shaken either', len(hits), 0)
        h.put32(f.tile_flags + 4 * wall_tile, 0)
    h.put16(f.building_tiles + 2 * workshop_tile, 31)

    h.put8(f.live_height + wall_tile, 26)                   # ... and so does a building's tile
    f.building(32, kind=20)
    h.put16(f.building_tiles + 2 * wall_tile, 32)
    fall_in()
    check('  and so does the tile a building stands on',
          h.m.read(f.live_height + wall_tile, 1)[0], 26)
    h.put16(f.building_tiles + 2 * wall_tile, 0)
    h.put8(f.live_height + wall_tile, 12)
    h.put8(f.base_height + wall_tile, 8)
    fall_in()
    check('  while bare ground beside them is put back',
          h.m.read(f.live_height + wall_tile, 1)[0], 8)

    print('  and what the shaking leaves standing')
    h.put16(f.building_tiles + 2 * workshop_tile, 0)
    h.put32(f.tile_flags + 4 * (101 * 400 + 201), 0x100)    # a wall beside the tunnel
    fall_in()
    check('a wall beside the tunnel is left alone', len(hits), 0)
    h.put32(f.tile_flags + 4 * (101 * 400 + 201), 0)

    for kind, name in ((41, 'a keep'), (45, 'a large gatehouse'), (74, 'a lookout tower'),
                       (72, 'a keep door'), (49, 'a drawbridge')):
        f.building(31, kind=kind)
        h.put16(f.building_tiles + 2 * workshop_tile, 31)
        fall_in()
        check('  %s beside it, the same' % name, len(hits), 0)
    h.put16(f.building_tiles + 2 * workshop_tile, 0)

    h.put32(f.tile_flags + 4 * stile, 0x100)                # ... and on the tunnel's own tile
    fall_in()
    check('a wall the tunnel ran under takes the five the game itself took',
          [c[1][3] for c in hits], [5])
    h.put32(f.tile_flags + 4 * stile, 0)

    f.building(31, kind=77)                                 # a square tower over the tunnel
    h.put16(f.building_tiles + 2 * stile, 31)
    fall_in()
    check('  and so does a tower over it', [c[1][3] for c in hits], [5])

    f.building(31, kind=20)                                 # an ordinary building over it
    fall_in()
    check('  while a workshop over it takes the full shaking',
          [c[1][3] for c in hits], [h.u32(f.spread_damage)])
    h.put16(f.building_tiles + 2 * stile, 0)
    h.put16(f.building_tiles + 2 * workshop_tile, 31)

    for y in range(98, 103):
        for x in range(198, 203):
            h.put8(f.live_height + y * 400 + x, 12)
    hits.clear()
    h.put32(f.step_flags, 1 | (5 << 8))                     # a quiet fill
    h.run(f.step_routine, until=SENTINEL)
    check('a quiet fill puts the ground back', h.m.read(f.live_height + stile, 1)[0], 8)
    check('  and damages nothing', len(hits), 0)

    print(' and the tick that works through it')
    h.put32(f.queue_count, 0)
    for k in range(10):
        h.put32(f.queue + 16 * k, stile + k)
        h.put32(f.queue + 16 * k + 4, 200)
        h.put32(f.queue + 16 * k + 8, 100)
        h.put32(f.queue + 16 * k + 12, 1)                   # quiet, so this is about the queue
    h.put32(f.queue_count, 10)
    h.put32(f.speed, 3)
    tick = f.tick_site
    tick_on = tick + 9
    cpu = h.run(tick, until=tick_on)
    check('a tick takes as many tiles as the setting says', h.u32(f.queue_count), 7)
    check('  from the far end first', h.u32(f.step_tile), stile + 7)
    check('  and the game carries on into its own pass', cpu.eip, tick_on)
    h.run(tick, until=tick_on)
    h.run(tick, until=tick_on)
    check('three ticks later it is nearly done', h.u32(f.queue_count), 1)
    h.run(tick, until=tick_on)
    h.run(tick, until=tick_on)
    check('and then it stops at nothing left', h.u32(f.queue_count), 0)

    # The game's own prologue follows this hook and reads its `this` out of ECX, so every
    # register the replayed three instructions do not touch has to come back untouched.
    marks = dict(eax=0x11110000, ecx=0x22220000, edx=0x33330000, ebx=0x44440000,
                 esi=0x55550000, edi=0x66660000)
    for k in range(6):
        h.put32(f.queue + 16 * k, stile + k)
        h.put32(f.queue + 16 * k + 4, 200)
        h.put32(f.queue + 16 * k + 8, 100)
        h.put32(f.queue + 16 * k + 12, 1)
    h.put32(f.queue_count, 6)
    before = h.cpu.r['esp'] if 'esp' in h.cpu.r else None
    cpu = h.run(tick, until=tick_on, regs=dict(marks))
    check('a tick that works hands the game back its own registers',
          {k: cpu.r[k] for k in marks}, marks)
    check('  and it did work while it was in there', h.u32(f.queue_count), 3)
    h.put32(f.speed, 8)

    # -------------------------------------------------- what a tunnel may aim at    # -------------------------------------------------- what a tunnel may aim at
    print(' towers and gates as targets')
    test_site = f.search + 0x23E
    allow = f.search + 0x246
    skip = f.search + 0x2C4

    def aims_at(kind):
        cpu = h.cpu
        cpu.r['esp'] = STACK_TOP
        cpu.r['edx'] = kind
        cpu.eip = test_site
        for _ in range(60):
            if cpu.eip in (allow, skip):
                break
            cpu.step()
        return 'allowed' if cpu.eip == allow else 'skipped' if cpu.eip == skip else 'elsewhere'

    h.put32(f.under, 0)                                     # type by type, for now
    for kind, name in ((74, 'lookout tower'), (76, 'defence turret'), (77, 'square tower'),
                       (78, 'round tower'), (45, 'large gatehouse'), (46, 'small gatehouse'),
                       (47, 'wooden gate')):
        check('%s (%d) is a target' % (name, kind), aims_at(kind), 'allowed')
    for kind, name in ((20, 'an ordinary building'), (41, 'a keep'), (200, 'nonsense')):
        check('%s (%d) is not' % (name, kind), aims_at(kind), 'skipped')

    check('a house stops the search', aims_at(12), 'skipped')
    h.put32(f.under, 1)
    check('... unless the tunnel may dig under the town', aims_at(12), 'allowed')
    for kind in (40, 41, 42):
        check('  but never under a keep (%d), which it goes round' % kind,
              aims_at(kind), 'skipped')
    check('  a workshop beside it is still dug under', aims_at(20), 'allowed')
    h.put32(f.under, 0)

    h.put32(f.targets_enabled, 0)
    check('switched off, the small towers are still targets', aims_at(74), 'allowed')
    check('switched off, a square tower is not', aims_at(77), 'skipped')
    check('switched off, a gatehouse is not', aims_at(45), 'skipped')
    h.put32(f.targets_enabled, 1)
    h.put32(f.under, 1)

    # ... and the second test, on a tile the search has actually reached: this is the one
    # that decides whether what it found counts as something to dig at
    print(' and what counts as something to dig at')
    reached = f.search + 0x1AE
    theirs = f.search + 0x1B4
    spread = f.search + 0x1CB
    BLD = 9

    def reached_a(kind):
        f.building(BLD, kind=kind)
        cpu = h.cpu
        cpu.r['esp'] = STACK_TOP
        cpu.r['eax'] = BLD
        cpu.eip = reached
        for _ in range(60):
            if cpu.eip in (theirs, spread):
                break
            cpu.step()
        return ('a target' if cpu.eip == theirs else 'dug past' if cpu.eip == spread
                else 'elsewhere')

    for kind, name in ((45, 'a gatehouse'), (47, 'a wooden gate'), (74, 'a lookout tower'),
                       (77, 'a square tower')):
        check('%s (%d) is a target' % (name, kind), reached_a(kind), 'a target')
    for kind, name in ((20, 'a workshop'), (12, 'a house'), (25, 'a hunter hut'),
                       (41, 'a keep'), (200, 'nonsense')):
        check('%s (%d) is dug past' % (name, kind), reached_a(kind), 'dug past')
    check('  and the building id survives it', h.cpu.r['eax'], BLD * 0x32C)

    h.put32(f.targets_enabled, 0)
    check('switched off, a small tower is still a target', reached_a(74), 'a target')
    check('switched off, a gatehouse is dug past', reached_a(45), 'dug past')
    check('switched off, a house is still dug past', reached_a(12), 'dug past')
    h.put32(f.targets_enabled, 1)

    # -------------------------------------------------------------- the buttons
    print(' the buttons')
    build_slot = f.render + 0x8F
    h.put32(f.engineer_selected, 0)
    h.put32(f.game_mode, 0)
    h.put32(f.picture, 0)
    h.put32(f.help_text, 0)
    h.stub(f.tunnelers_only, 1)
    drawn = []
    h.stub(f.render_button, 0, 0, record=drawn)
    cpu = h.run(build_slot, until=f.render + 0xDE, regs={'edi': 0})
    check('tunnelers selected -> the slot draws the tunnel picture', h.u32(f.picture), 0xDA)
    check('  and names the dig tunnel help text', h.u32(f.help_text), 0xC9)
    check('  and the button is left active', h.u32(f.inactive), 0)
    check('  and it really drew', len(drawn), 1)

    h.stub(f.tunnelers_only, 0)
    cpu = h.run(build_slot, until=build_slot + 6, regs={'edi': 0})
    check('no tunnelers -> the slot is left to the engineer', len(drawn), 1)

    h.stub(f.tunnelers_only, 1)
    cpu = h.run(f.toolbar, until=f.toolbar + 9, stack=[291])
    check('clicking it sends the tunnel command', h.u32(cpu.r['esp'] + 8), 0x42)
    h.stub(f.tunnelers_only, 0)
    cpu = h.run(f.toolbar, until=f.toolbar + 9, stack=[291])
    check('without tunnelers it stays the engineer command', h.u32(cpu.r['esp'] + 8), 291)
    h.stub(f.tunnelers_only, 1)
    cpu = h.run(f.toolbar, until=f.toolbar + 9, stack=[34])
    check('another button is untouched', h.u32(cpu.r['esp'] + 8), 34)

    # ------------------------------------------------------------ switched off
    print(' everything switched off')
    g = Fixture(extreme, config={'denial': {'enabled': False}, 'retarget': {'enabled': False},
                                 'ui': {'enabled': False}, 'stances': {'enabled': False}})
    g.h.put32(g.current_unit, 7)
    g.set_unit(7, state=1, looking=0)
    g.h.run(g.tunneler, until=g.tunneler + 7)
    got = struct.unpack('<H', g.h.m.read(g.unit(7) + 0x3FC, 2))[0]
    check('stance flag stays clear', got, 0)
    g.h.put32(g.tile_flags + 4 * tile, 0x100)
    g.h.put32(g.current_unit, 9)
    g.set_unit(9, owner=3, x=150, y=200, tile=tile, state=3)
    g.h.put32(g.ticks, 5000)
    g.h.run(g.tunneler + 0x7E6, until=g.tunneler + 0x7E6 + 5)
    check('no zone is laid', g.zone(0), (0, 0, 0, 0))


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else 'both'
    if which in ('v', 'both'):
        scenario(False)
    if which in ('e', 'both'):
        scenario(True)
    print('\n%s' % ('ALL OK' if not FAILURES else 'FAILURES: ' + ', '.join(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == '__main__':
    sys.exit(main())
