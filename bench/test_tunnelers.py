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
        self.queue = self.control + 0x2E8
        self.claims_slot = self.control + 0x2D8
        self.claims_active = self.control + 0x2DC
        self.search_range = self.control + 0x2E0
        self.advance = self.control + 0xAC
        self.min_advance = self.control + 0x2E4
        self.pending = self.control + 0xE4
        self.origin_x = self.control + 0x224
        self.origin_y = self.control + 0x228
        self.zones = self.control + 0x2E8 + 512 * 16
        self.finish_leg = self.control + 0x2CC
        self.family_damage = self.control + 0x2C4
        self.family_ready = self.control + 0x2C8
        self.pinned = self.control + 0x290
        self.depth_limit = self.control + 0x294
        self.shared_slot = self.control + 0x298
        self.shared = self.zones + 32 * 16 + 32 * 8
        # 1.5.0: where a tunnel goes
        self.records = self.zones + 32 * 16          # {uid, times sent on, line, spare}
        self.lines = self.records + 64 * 16          # four lines a player, {tile, x, y, tick}
        self.plan_buffer = self.lines + 9 * 64
        self.aim_mode = self.control + 0xE4
        self.aim_pin = self.control + 0xE8
        self.aim_from_x = self.control + 0xEC
        self.aim_from_y = self.control + 0xF0
        self.aim_dir_x = self.control + 0xF4
        self.aim_dir_y = self.control + 0xF8
        self.aim_dir_length = self.control + 0xFC
        self.aim_unit = self.control + 0x100
        self.aim_range = self.control + 0x104
        self.game_tile = self.control + 0x110
        self.ours = self.control + 0x11C
        self.redirect_how = self.control + 0x120
        self.record = self.control + 0x128
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

    # ------------------------------------------------------------ where a tunnel goes
    # The game's own search, trace and first aim are stubbed here: what is tested is what
    # the module asks them for and what it does with the answers. test_real_lines.py runs
    # the same thing with the game's real code.
    unit = 11
    arrived = f.tunneler + 0x7E6
    first = f.tunneler + 0x66E
    first_on = first + 5
    stop = h.allocate_code([0xC3])
    reach = set()                        # the tiles a pinned search can get to
    answers = {0: 0, 2: 0}               # what an open and a cone search find, by mode
    asked = []                           # (mode, pin, range, x, y) for every search run
    traces = []                          # (unit, x, y, mode) for every trace laid

    def xy(tile):
        return tile % 400, tile // 400

    def search(cpu):
        mode, pin = h.u32(f.aim_mode), h.u32(f.aim_pin)
        args = [cpu.m.u32(cpu.r['esp'] + 4 + 4 * i) for i in range(5)]
        asked.append((mode, pin if mode == 1 else 0, args[2], args[3], args[4]))
        # mode 4 is the module's own open search: the same answer as the game's mode 0
        found = (pin if pin in reach else 0) if mode == 1 else answers.get(mode % 4, 0)
        h.put32(f.alg_result, found)
        x, y = xy(found) if found else (0, 0)
        h.put32(f.alg_x, x)
        h.put32(f.alg_y, y)
        cpu.r['eax'] = 0
        cpu.eip = cpu.pop()
        cpu.r['esp'] += 20
    h.cpu.hooks[f.alg_find] = search

    trace_ok = [True]
    new_leg = [4, 3]                     # how many steps the game's trace lays, and which way

    def trace(cpu):
        args = [cpu.m.u32(cpu.r['esp'] + 4 + 4 * i) for i in range(4)]
        traces.append(tuple(args))
        u = f.unit(args[0])
        if trace_ok[0]:                  # what the game's own trace leaves behind
            steps, way = new_leg
            for i in range(0, steps, 2):
                h.put8(u + 0xFE + i // 2, way | (way << 4))
            h.put16(u + 0xFC, steps)
            h.put16(u + 0xFA, 0)
            h.put16(u + 0xCC, struct.unpack('<H', h.m.read(u + 0xC4, 2))[0])
            h.put16(u + 0xCE, struct.unpack('<H', h.m.read(u + 0xC6, 2))[0])
            h.put32(u + 0xDC, h.u32(u + 0xD4))
            h.put16(u + 0xF6, 2)
        cpu.r['eax'] = 1 if trace_ok[0] else 0
        cpu.eip = cpu.pop()
        cpu.r['esp'] += 16
    h.cpu.hooks[f.set_destination] = trace

    def stand(tile, up=True):
        h.put32(f.tile_flags + 4 * tile, 0x100 if up else 0)

    def line(owner, slot):
        a = f.lines + 64 * owner + 16 * slot
        return tuple(h.u32(a + 4 * k) for k in range(4))

    def set_line(owner, slot, tile, tick=None):
        a = f.lines + 64 * owner + 16 * slot
        x, y = xy(tile) if tile else (0, 0)
        for k, v in enumerate((tile, x, y, h.u32(f.ticks) if tick is None else tick)):
            h.put32(a + 4 * k, v)

    def clear_lines():
        for k in range(0, 9 * 64, 4):
            h.put32(f.lines + k, 0)
        for k in range(0, 64 * 16, 4):
            h.put32(f.records + k, 0)
        h.put32(f.ring_cursor, f.records)

    def record_of(u):
        uid = h.u32(f.unit(u) + 0x98)
        for i in range(64):
            if h.u32(f.records + 16 * i) == uid:
                return f.records + 16 * i
        return None

    # ---------------------------------------------------------------- the filter
    print(' where a tunnel goes: the filter in the search')
    take = f.search + 0x16F
    took_it = f.search + 0x178
    spread_on = f.search + 0x1CB

    def reaches(tile, x, y):
        cpu = h.cpu
        cpu.r['esp'] = STACK_TOP
        cpu.r['esi'] = f.alg_result - 0x34                  # the search's own state
        cpu.r['ebp'], cpu.r['edi'], cpu.r['edx'] = tile, y, x
        cpu.r['ebx'] = 0x5EB5
        cpu.eip = take
        for _ in range(300):
            if cpu.eip in (took_it, spread_on):
                break
            cpu.step()
        where = 'taken' if cpu.eip == took_it else 'passed' if cpu.eip == spread_on else '?'
        return where if cpu.r['ebx'] == 0x5EB5 and cpu.r['esp'] == STACK_TOP else 'LOST EBX'

    h.put32(f.aim_mode, 0)
    check('off, the first thing reached is taken as the game takes it',
          reaches(40000, 150, 150), 'taken')
    check('  and recorded the way the game records it',
          (h.u32(f.alg_result), h.u32(f.alg_y), h.u32(f.alg_x)), (40000, 150, 150))
    check('the search looks for stairs and crenellations as well as wall',
          h.u32(f.search + 0x131), 0x100 | 0x200 | 0x800)
    h.put32(f.aim_mode, 1)
    h.put32(f.aim_pin, 40000)
    check('pinned, the one tile is taken', reaches(40000, 80, 80), 'taken')
    check('  and nothing else, however near', reaches(40001, 81, 80), 'passed')

    h.put32(f.aim_mode, 2)                                  # from (100,100), the camp east
    h.put32(f.aim_from_x, 100)
    h.put32(f.aim_from_y, 100)
    h.put32(f.aim_dir_x, 64)
    h.put32(f.aim_dir_y, 0)
    h.put32(f.aim_dir_length, 64 * 64)
    for (x, y), want, what in (((120, 100), 'taken', 'straight towards the camp'),
                               ((120, 119), 'taken', 'just inside 45 degrees'),
                               ((120, 120), 'taken', 'on 45 degrees exactly'),
                               ((120, 121), 'passed', 'just outside it'),
                               ((100, 130), 'passed', 'square across'),
                               ((80, 100), 'passed', 'behind'),
                               ((101, 100), 'taken', 'one tile on, straight in')):
        check('the cone: %s is %s' % (what, want), reaches(y * 400 + x, x, y), want)
    h.put32(f.aim_dir_x, 64)                                # the camp off to the south east
    h.put32(f.aim_dir_y, 64)
    h.put32(f.aim_dir_length, 2 * 64 * 64)
    check('  a camp on the diagonal: straight east is on its edge', reaches(40120, 120, 100),
          'taken')
    check('  and a little north of east is outside', reaches(39720, 120, 99), 'passed')
    h.put32(f.aim_mode, 0)

    # ------------------------------------------------------------- the first aim
    print(' where a tunnel goes: the first target')
    ENTRANCE = 40
    f.building(ENTRANCE, state=1)
    h.put16(f.building_base + ENTRANCE * 0x32C + 0x260, 100)   # where the game searched from
    h.put16(f.building_base + ENTRANCE * 0x32C + 0x262, 100)
    game_says = [0]

    def game_first(cpu):
        tile = game_says[0]
        h.put32(f.alg_result, tile)
        h.put32(f.alg_x, xy(tile)[0])
        h.put32(f.alg_y, xy(tile)[1])
        cpu.r['eax'] = 1 if tile else 0
        cpu.eip = cpu.pop()
        cpu.r['esp'] += 8
    h.cpu.hooks[f.finder] = game_first

    def aim(u, uid, game_tile):
        game_says[0] = game_tile
        f.set_unit(u, owner=1, siege=2, x=100, y=100, uid=uid, kind=5, alive=2, state=9)
        h.put16(f.unit(u) + 0x338, ENTRANCE)
        h.put32(f.current_unit, u)
        asked.clear()
        cpu = h.run(first, until=first_on, regs={'ebx': 0, 'esi': 0x51, 'edi': 0x52})
        kept = (cpu.r['ebx'], cpu.r['esi'], cpu.r['edi']) == (0, 0x51, 0x52)
        return cpu.r['eax'], h.u32(f.alg_result), kept

    A, B, FAR = 100 * 400 + 110, 108 * 400 + 104, 300 * 400 + 300
    for t in (A, B, FAR):
        stand(t)
    clear_lines()
    h.put32(f.ticks, 9000)
    got = aim(unit, 3001, A)
    check('the first tunnel takes the game s own answer', got, (1, A, True))
    check('  and that starts a line', line(1, 0)[:3], (A, 110, 100))
    check('  which is its line', h.u32(record_of(unit) + 8), f.lines + 64 + 0)
    check('  and no search of ours was run for it', asked, [])

    reach.add(A)
    got = aim(12, 3002, B)
    check('the next one, whose own answer is another wall, is sent at the line',
          got, (1, A, True))
    check('  by one search, pinned on the line, from where the game searched',
          asked, [(1, A, 10 + 24, 100, 100)])
    check('    spreading no further than the line is in steps, plus room to go round a keep',
          asked[0][2] < h.u32(f.retarget_range), True)
    check('  and the line is its line too', h.u32(record_of(12) + 8), f.lines + 64 + 0)
    check('  and the net knows the answer is ours', h.u32(f.ours), 1)

    got = aim(13, 3003, A)
    check('one whose own answer is the line joins it without a search',
          (got, asked), ((1, A, True), []))
    check('  and the net has nothing to fall back to', h.u32(f.ours), 0)

    reach.discard(A)
    answers[0] = B                                          # the game's own search, run again
    got = aim(14, 3004, B)
    check('one that cannot reach the line keeps the game s answer', got, (1, B, True))
    check('  after the game s own search is run again at its own full reach',
          asked, [(1, A, 10 + 24, 100, 100), (0, 0, 80, 100, 100)])
    check('  and starts a line of its own', line(1, 1)[:3], (B, 104, 108))

    clear_lines()
    set_line(1, 0, FAR)                                     # a line two hundred tiles off
    reach.add(FAR)
    got = aim(15, 3005, B)
    check('a line further off than the range is not searched for at all',
          (got, asked), ((1, B, True), []))
    check('  and the tunnel starts its own beside it', line(1, 1)[0], B)

    clear_lines()
    set_line(1, 0, A, tick=h.u32(f.ticks) + 5000)           # from a game played before this one
    reach.add(A)
    got = aim(16, 3006, B)
    check('a line from before the clock went back is dropped', (got[1], asked), (B, []))
    check('  and its slot taken', line(1, 0)[0], B)

    clear_lines()
    set_line(1, 0, A, tick=h.u32(f.ticks) - 600 * 40 - 1)   # nobody has used it for ten minutes
    got = aim(21, 3011, B)
    check('a line nobody has used for ten minutes is dropped', (got[1], asked), (B, []))
    set_line(1, 0, A, tick=h.u32(f.ticks) - 600 * 40 + 1)
    got = aim(22, 3012, B)
    check('  one used a moment before that is still joined', got[1], A)

    clear_lines()
    set_line(1, 0, A)
    stand(A, False)                                         # the line's wall has come down
    got = aim(17, 3007, B)
    check('a line whose wall is down is not joined', (got[1], asked), (B, []))
    check('  and is left for the tunnels still heading there', line(1, 0)[0], A)
    check('  the new line going into an empty slot', line(1, 1)[0], B)
    stand(A)

    clear_lines()
    for slot, tick in enumerate((400, 100, 300, 200)):
        set_line(1, slot, FAR + slot, tick)
        stand(FAR + slot)
    got = aim(18, 3008, B)
    check('with every slot in use, the line used least recently gives way',
          [line(1, k)[0] for k in range(4)], [FAR, B, FAR + 2, FAR + 3])

    clear_lines()
    h.put32(f.control + 0x08, 0)
    got = aim(19, 3009, B)
    check('switched off, the game s answer and nothing else',
          (got, asked, line(1, 0)[0]), ((1, B, True), [], 0))
    h.put32(f.control + 0x08, 1)
    game_says[0] = 0
    got = aim(20, 3010, 0)
    check('while the game is still looking, it is left to look', got[0], 0)
    check('the filter is never left on for the game', h.u32(f.aim_mode), 0)

    # --------------------------------------------------------------- the net
    print(' where a tunnel goes: the net under the first aim')
    net = f.tunneler + 0x6D3
    laid = f.tunneler + 0x6DB
    give_up = f.tunneler + 0x92B
    ended = []

    def ends(where):
        def hook(cpu):
            ended.append(where)
            cpu.eip = stop
        return hook
    h.cpu.hooks[laid] = ends('laid')
    h.cpu.hooks[give_up] = ends('given up')

    def net_with(result, ours, trace_works=True):
        h.put32(f.ours, ours)
        h.put32(f.game_tile, B)
        h.put32(f.control + 0x114, 104)
        h.put32(f.control + 0x118, 108)
        trace_ok[0] = trace_works
        ended.clear()
        asked.clear()
        traces.clear()
        h.put32(f.current_unit, unit)
        h.run(net, regs={'eax': result})
        trace_ok[0] = True
        return ended[-1] if ended else '?'

    check('a path that laid is left alone', (net_with(1, 1), asked, traces), ('laid', [], []))
    check('one of the game s own that did not lay is given up, as always',
          (net_with(0, 0), asked), ('given up', []))
    answers[0] = B
    got = net_with(0, 1)
    check('one of ours that did not lay falls back on the game s own answer', got, 'laid')
    check('  searching for it again at the game s own reach', asked, [(0, 0, 80, 100, 100)])
    check('  and tracing the path to it', traces, [(unit, 104, 108, 2)])
    check('  once only', h.u32(f.ours), 0)
    check('and if that will not lay either, the game gives up',
          net_with(0, 1, trace_works=False), 'given up')

    # ---------------------------------------------------------- sending one on
    print(' where a tunnel goes: sending a tunnel on from empty ground')
    redirect = f.module_routine(arrived)
    HERE = 100 * 400 + 130                                  # where the tunneller stands
    NEXT, SIDE = 100 * 400 + 145, 118 * 400 + 130

    def dug(u, uid, steps=8, way=2):
        f.set_unit(u, owner=1, siege=2, x=130, y=100, tile=HERE, uid=uid, kind=5, alive=2,
                   state=3, stage=0)
        base = f.unit(u)
        for i in range(0, 400):
            h.put8(base + 0xFE + i, 0)
        for i in range(steps):
            b = h.m.read(base + 0xFE + i // 2, 1)[0]
            h.put8(base + 0xFE + i // 2, (b & 0x0F) | (way << 4) if i & 1 else (b & 0xF0) | way)
        h.put16(base + 0xFC, steps)
        h.put16(base + 0xFA, steps)
        h.put16(base + 0xCC, 102)
        h.put16(base + 0xCE, 100)
        h.put32(base + 0xDC, 100 * 400 + 102)

    def send_on(u):
        asked.clear()
        traces.clear()
        h.put32(f.current_unit, u)
        cpu = h.run(redirect, regs={'ebx': 0x61, 'esi': 0x62, 'edi': 0x63})
        kept = (cpu.r['ebx'], cpu.r['esi'], cpu.r['edi']) == (0x61, 0x62, 0x63)
        return cpu.r['eax'], h.u32(f.redirect_how), kept

    f.building(9, kind=20)                                  # the enemy's campfire, due east
    h.put16(f.building_base + 9 * 0x32C + 0xEE, 300)
    h.put16(f.building_base + 9 * 0x32C + 0xF0, 100)
    h.put32(f.camp_ids + 0x39F4 * 2, 9)
    h.put32(f.keep_ids + 0x39F4 * 2, 0)

    def give(u, slot):
        """The tunneler's record, following line `slot` of player 1, sent on no times yet."""
        rec = f.records
        h.put32(rec, h.u32(f.unit(u) + 0x98))
        h.put32(rec + 4, 0)
        h.put32(rec + 8, f.lines + 64 + 16 * slot)
        h.put32(f.ring_cursor, f.records + 16)
        return rec

    clear_lines()
    for t in (A, NEXT, SIDE):
        stand(t)
    stand(HERE, False)
    reach.clear()
    reach.update((A, NEXT, SIDE))
    set_line(1, 0, A)                                       # its line stands, off to the side
    dug(unit, 4001)
    rec = give(unit, 0)
    got = send_on(unit)
    check('with its line still standing, it is sent at the line', got, (1, 1, True))
    check('  by one pinned search from where it stands',
          asked, [(1, A, 20 + 24, 130, 100)])
    check('  and the path is traced there', traces, [(unit, 110, 100, 2)])
    check('  and it is counted', h.u32(rec + 4), 1)
    check('  and the line, still standing, stays put', line(1, 0)[0], A)

    clear_lines()
    set_line(1, 0, HERE)                                    # its line was where it now stands
    dug(unit, 4002)
    rec = give(unit, 0)
    answers[2] = NEXT
    got = send_on(unit)
    check('with its line gone, it looks towards the campfire', got, (1, 2, True))
    check('  from where it stands, the direction scaled down to 64',
          (asked[0][0], asked[0][3:], h.u32(f.aim_dir_x), h.u32(f.aim_dir_y)),
          (2, (130, 100), 64, 0))
    check('  and the line moves on to what it found', line(1, 0)[:3], (NEXT, 145, 100))

    set_line(1, 0, HERE)
    dug(unit, 4002)
    answers[2] = 0
    answers[0] = SIDE
    got = send_on(unit)
    check('with nothing towards the campfire, it waits after the one search', got, (2, 9, True))
    check('  the cone', [a[0] for a in asked], [2])
    check('  and nothing is traced', traces, [])
    h.put32(f.ticks, h.u32(f.ticks) + 1)
    got = send_on(unit)
    check('  and on the next tick the way in is widened', got, (1, 3, True))
    check('    by the nearest of all, without searching the cone again',
          [a[0] for a in asked], [4])
    check('    and the line moves there', line(1, 0)[0], SIDE)

    set_line(1, 0, HERE)
    dug(unit, 4002)
    h.put32(f.ticks, h.u32(f.ticks) + 1)
    send_on(unit)
    h.put32(f.ticks, h.u32(f.ticks) + 200)
    send_on(unit)
    check('a step left too long is forgotten: it starts from the top again',
          [a[0] for a in asked], [2])
    h.put32(rec + 12, 0)

    set_line(1, 0, HERE)
    dug(unit, 4002)
    answers[0] = 0
    h.put32(f.ticks, h.u32(f.ticks) + 1)
    send_on(unit)
    h.put32(f.ticks, h.u32(f.ticks) + 1)
    got = send_on(unit)
    check('with nothing in reach at all, it collapses where it is', got, (0, 5, True))
    check('  and no path is traced', traces, [])

    h.put32(rec + 4, h.u32(f.control + 0x10))               # sent on as often as allowed
    answers[2] = NEXT
    got = send_on(unit)
    check('one sent on as often as allowed is not sent again', got, (0, 4, True))
    check('  and nothing is searched for', asked, [])
    h.put32(rec + 4, 0)

    set_line(1, 0, FAR)                                     # its line, far across the map
    dug(unit, 4002)
    answers[2] = NEXT
    got = send_on(unit)
    check('a line out of reach is not searched for', [a[0] for a in asked], [2])
    check('  and stays where it is', line(1, 0)[0], FAR)

    h.put32(rec + 8, 0)                                     # a tunnel with no line at all
    clear_lines()
    dug(unit, 4003)
    answers[2] = NEXT
    got = send_on(unit)
    check('a tunnel with no line starts one where it is sent', line(1, 0)[0], NEXT)
    check('  and follows it', h.u32(record_of(unit) + 8), f.lines + 64)

    h.put32(f.camp_ids + 0x39F4 * 2, 0)                     # no campfire known anywhere
    dug(unit, 4004)
    answers[0] = SIDE
    got = send_on(unit)
    check('knowing no campfire, it goes straight to the nearest', (got[1], [a[0] for a in asked]),
          (3, [4]))
    h.put32(f.camp_ids + 0x39F4 * 2, 9)
    check('the filter is never left on for the game', h.u32(f.aim_mode), 0)

    # ----------------------------------------------------- keeping the tunnel whole
    print(' where a tunnel goes: the tunnel stays one piece')

    def nibbles(u, n):
        out = []
        for i in range(n):
            b = h.m.read(f.unit(u) + 0xFE + i // 2, 1)[0]
            out.append((b >> 4) & 15 if i & 1 else b & 15)
        return out

    for dug_steps in (8, 7):
        clear_lines()
        dug(unit, 5000 + dug_steps, steps=dug_steps, way=2)
        new_leg[:] = [5, 3]
        answers[2] = NEXT
        send_on(unit)
        base = f.unit(unit)
        check('%s: what was dug is kept, the new leg added behind it' % (
              'an even tunnel' if dug_steps % 2 == 0 else 'an odd one'),
              nibbles(unit, dug_steps + 5), [2] * dug_steps + [3] * 5)
        check('  the plan is as long as both', struct.unpack('<H', h.m.read(base + 0xFC, 2))[0],
              dug_steps + 5)
        check('  and the tunneler is at the join', struct.unpack('<H', h.m.read(base + 0xFA, 2))[0],
              dug_steps)
        check('  the tunnel still starts at its entrance',
              (struct.unpack('<H', h.m.read(base + 0xCC, 2))[0],
               struct.unpack('<H', h.m.read(base + 0xCE, 2))[0], h.u32(base + 0xDC)),
              (102, 100, 100 * 400 + 102))
        check('  and it is on its way', struct.unpack('<H', h.m.read(base + 0xF6, 2))[0], 2)

    clear_lines()
    dug(unit, 5100, steps=797, way=1)
    new_leg[:] = [5, 3]
    got = send_on(unit)
    base = f.unit(unit)
    check('a tunnel that would not fit its plan is not sent on', got, (0, 8, True))
    check('  and is put back exactly as it was',
          (nibbles(unit, 797) == [1] * 797, struct.unpack('<H', h.m.read(base + 0xFC, 2))[0],
           struct.unpack('<H', h.m.read(base + 0xFA, 2))[0],
           struct.unpack('<H', h.m.read(base + 0xCC, 2))[0], h.u32(base + 0xDC),
           struct.unpack('<H', h.m.read(base + 0xF6, 2))[0]),
          (True, 797, 797, 102, 100 * 400 + 102, 0))

    clear_lines()
    dug(unit, 5200, steps=9, way=4)
    trace_ok[0] = False
    got = send_on(unit)
    trace_ok[0] = True
    check('one whose path will not lay is not sent on: it waits where it is', got,
          (2, 6, True))
    refused_ring = f.control + 0x188
    check('  and its target is set aside', h.u32(refused_ring) in (NEXT, SIDE), True)
    check('  and the spot it stands on is left alone a moment',
          (h.u32(f.control + 0x16C), h.u32(f.control + 0x170) > h.u32(f.ticks)), (HERE, True))
    check('  and is put back exactly as it was',
          (nibbles(unit, 9), struct.unpack('<H', h.m.read(base + 0xFC, 2))[0],
           struct.unpack('<H', h.m.read(base + 0xFA, 2))[0]), ([4] * 9, 9, 9))

    # the filter sets a refused target aside for the module's own searches, never the game's
    for k in range(0, 64, 4):
        h.put32(refused_ring + k, 0)
    h.put32(refused_ring, 40000)
    h.put32(refused_ring + 4, h.u32(f.ticks) + 100)
    h.put32(f.aim_mode, 4)
    check('a target set aside is passed by the module s own search', reaches(40000, 150, 150),
          'passed')
    h.put32(f.aim_mode, 0)
    check('  but the game s own search takes it as always', reaches(40000, 150, 150), 'taken')
    h.put32(refused_ring + 4, h.u32(f.ticks) - 1)
    h.put32(f.aim_mode, 4)
    check('  and once its time is up it is taken again', reaches(40000, 150, 150), 'taken')
    h.put32(f.aim_mode, 0)
    h.put32(refused_ring, 0)
    h.put32(f.control + 0x170, 0)                           # nothing cooling

    # --------------------------------------------------------------- the arrival
    print(' where a tunnel goes: arriving')
    resume = arrived + 5
    tail = f.tunneler + 0x1197
    h.cpu.hooks[resume] = ends('collapses')
    h.cpu.hooks[tail] = ends('digs on')

    def arrive(u, next_tick=True):
        ended.clear()
        if next_tick:                                       # each arrival on a tick of its own
            h.put32(f.ticks, h.u32(f.ticks) + 1)
        h.put32(f.current_unit, u)
        h.run(arrived, regs={'ebx': 0})
        return ended[-1] if ended else '?'

    clear_lines()
    dug(unit, 6000)
    stand(HERE)
    check('on a fortification, the game collapses it as it always does', arrive(unit),
          'collapses')
    stand(HERE, False)
    answers[2] = NEXT
    dug(unit, 6001)
    check('on empty ground, sent on, it digs on', arrive(unit), 'digs on')
    answers[2] = 0
    answers[0] = 0
    dug(unit, 6002)
    check('with nowhere to go, it first waits a tick for its second search', arrive(unit),
          'digs on')
    check('  and then the game collapses it there', arrive(unit), 'collapses')
    h.put32(f.control + 0x08, 0)
    answers[2] = NEXT
    dug(unit, 6003)
    check('switched off, it collapses there as in the unmodified game', arrive(unit),
          'collapses')
    h.put32(f.control + 0x08, 1)

    # a group arriving on the same breach together is sent on one a tick, not all at once
    answers[2] = NEXT
    h.put32(f.ticks, h.u32(f.ticks) + 1)
    dug(unit, 6004)
    dug(12, 6005)
    asked.clear()
    first_one = arrive(unit)
    searched = len(asked)
    second_one = arrive(12, next_tick=False)
    check('two arriving in the same tick: the first is sent on',
          (first_one, searched > 0), ('digs on', True))
    check('  the second waits where it is, no search run for it',
          (second_one, len(asked) == searched), ('digs on', True))
    check('    still at the end of its tunnel, still in state 3, nothing laid',
          (f.unit_field(12, 'state'), struct.unpack('<H', h.m.read(f.unit(12) + 0xFA, 2))[0],
           struct.unpack('<H', h.m.read(f.unit(12) + 0xFC, 2))[0]), (3, 8, 8))
    asked.clear()
    arrive(12)
    check('  and on the next tick it is its turn', len(asked) > 0, True)
    # where the game just refused a path, tunnels wait a moment instead of searching again
    answers[2] = NEXT
    dug(unit, 6006)
    h.put32(f.control + 0x16C, HERE)
    h.put32(f.control + 0x170, h.u32(f.ticks) + 10)
    asked.clear()
    check('arriving where a path was just refused, it waits', arrive(unit), 'digs on')
    check('  without a search', asked, [])
    check('  still at the end of its tunnel', f.unit_field(unit, 'state'), 3)
    h.put32(f.ticks, h.u32(f.ticks) + 20)
    asked.clear()
    arrive(unit)
    check('  and after the moment it looks again', len(asked) > 0, True)
    h.put32(f.control + 0x170, 0)
    h.cpu.hooks.pop(resume, None)
    h.cpu.hooks.pop(tail, None)
    h.cpu.hooks.pop(laid, None)
    h.cpu.hooks.pop(give_up, None)
    h.cpu.hooks.pop(f.finder, None)
    h.cpu.hooks.pop(f.alg_find, None)
    h.cpu.hooks.pop(f.set_destination, None)
    clear_lines()

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
    dh.put32(d.alg_result, 5555)
    d.set_unit(12, state=3, uid=4321)
    dh.put32(d.ticks, 7001)
    before = len(dh.logs)
    dh.run(d.tunneler + 0x7E6, until=d.tunneler + 0x1197)
    check('a tunnel sent on says so',
          'is sent on' in (dh.logs[before] if len(dh.logs) > before else ''), True)
    dh.put32(d.alg_result, 0)
    d.set_unit(12, state=3, uid=4322)
    dh.put32(d.ticks, 7002)
    before = len(dh.logs)
    dh.run(d.tunneler + 0x7E6, until=d.tunneler + 0x7E6 + 5)
    check('and one with nowhere to go says that',
          'collapses there' in (dh.logs[before] if len(dh.logs) > before else ''), True)

    # the stopwatch: every tunneller update is timed, and a tick far longer than usual
    # writes one line saying where its time went
    sw = d.control + 0x1CC
    d.set_unit(12, state=3, uid=4323)
    dh.put32(d.current_unit, 12)
    dh.put16(d.unit(12) + 0xF6, 2)                          # still on its way
    marks = dict(ebx=0x44440000, esi=0x55550000, edi=0x66660000, ebp=0x77770000)
    cpu = dh.run(d.tunneler, regs=dict(marks))
    check('a timed tunneller update keeps the registers the game expects kept',
          {k: cpu.r[k] for k in marks}, marks)
    check('  and is counted, with its time', (dh.u32(sw + 0x20), dh.u32(sw + 0x08) > 0),
          (1, True))
    tick_on = d.tick_site + 9
    dh.run(d.tick_site, until=tick_on)
    dh.run(d.tick_site, until=tick_on)
    before = len(dh.logs)
    dh.run(d.tick_site, until=tick_on)
    check('an ordinary tick writes nothing', len(dh.logs) - before, 0)
    dh.cpu.clock_offset = getattr(dh.cpu, "clock_offset", 0) + 1024 * 200000
    dh.run(d.tick_site, until=tick_on)
    slow = dh.logs[before:]
    check('a tick far longer than usual writes one line', len(slow), 1)
    check('  saying it was slow', 'slow tick' in (slow[0] if slow else ''), True)
    check('  and it starts the next one from nothing', dh.u32(sw + 0x08), 0)

    # every tile of every wall the AI puts down goes through the build check, so its line
    # is rationed: one a second, however many attempts there are
    dh.put32(d.teams + 4 * 4, 1)
    dh.put32(d.teams + 4 * 2, 2)
    bm2 = struct.unpack('<I', d.e.data[d.e.va2off(d.enemy + 0x24):
                                       d.e.va2off(d.enemy + 0x24) + 4])[0]
    for y in range(145, 156):
        for x in range(145, 156):
            dh.put8(bm2 + y * 400 + x, 1)
    dh.put32(d.ticks, 7000)
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

    # ------------------------------------------------------------ the damage routine
    print(' the game\'s own damage, where it sorts the tile it is handed')
    landed = []
                                                        # the sentinel run() pushed is

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
    f.step_routine = f.module_routine(f.tick_site, skip=1)   # after the stopwatch report
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
        whole_tile()

    def whole_tile():
        """The step does one neighbour a call; run it until the tile is done."""
        r = h.u32(f.spread_radius)
        h.put32(f.control + 0x258, -r & 0xFFFFFFFF)          # STEP_DX
        h.put32(f.control + 0x25C, -r & 0xFFFFFFFF)          # STEP_DY
        h.put32(f.control + 0x200, 1)                        # STEP_ACTIVE
        for _ in range(200):
            h.run(f.step_routine, until=SENTINEL)
            if not h.u32(f.control + 0x200):
                return
        raise AssertionError('the step never finished its tile')

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
    whole_tile()
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

    # A tick stops between two calls of the game's damage once its time is spent, and the
    # next one carries on with the same tile where it left off.
    h.put32(f.spread_radius, 2)
    h.put32(f.spread_damage, 60)
    shaken = []
    h.stub(f.process_damage, 0, 32, record=shaken)
    burn = []
    def slow(cpu):                                          # each call "costs" 3000 units
        cpu.clock_offset = getattr(cpu, 'clock_offset', 0) + 3000 * 1024
    h.cpu.hooks[f.process_damage] = lambda cpu, old=h.cpu.hooks.get(f.process_damage): (slow(cpu), old and old(cpu))
    for y in range(98, 103):
        for x in range(198, 203):
            h.put16(f.building_tiles + 2 * (y * 400 + x), 31)   # a workshop all round
    h.put32(f.queue, stile)
    h.put32(f.queue + 4, 200)
    h.put32(f.queue + 8, 100)
    h.put32(f.queue + 12, 5 << 8)
    h.put32(f.queue_count, 1)
    h.put32(f.control + 0x200, 0)
    h.run(tick, until=tick_on)
    check('a tick whose time is spent stops after one call of the damage', len(shaken), 1)
    check('  with the tile still part way through', h.u32(f.control + 0x200), 1)
    h.run(tick, until=tick_on)
    check('  and the next tick carries on with it', len(shaken), 2)
    h.stub(f.process_damage, 0, 32, record=shaken)
    h.cpu.clock_offset = 0
    for _ in range(40):
        h.run(tick, until=tick_on)
    check('  until the tile is done', (h.u32(f.control + 0x200), len(shaken)), (0, 25))
    for y in range(98, 103):
        for x in range(198, 203):
            h.put16(f.building_tiles + 2 * (y * 400 + x), 0)

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


def raids(extreme):
    """Tunnellers in AI raids: the raid troop lookup and the recruiting loop."""
    print(' AI raids (%s)' % ('Extreme' if extreme else 'vanilla'))
    f = Fixture(extreme)
    h = f.h
    lookup = h.E.find('56 57 8B 7C 24 10 33 C0 69 FF 90 04 00 00 0F BF 97 ? ? ? ? '
                      '8B 0C 85 ? ? ? ? 3B D1')[0]
    enabled = f.control + 0x1C

    def troop(kind, unit):
        f.set_unit(unit, owner=3, kind=kind, alive=2)
        return h.run(lookup, stack=[3, unit]).r['eax']

    mace = troop(26, 21)
    check('a maceman recruited for a raid gets a raid troop', mace != 0, True)
    check('a tunneller recruited for a raid gets the same one', troop(5, 22), mace)
    check('  and a spearman is still in it too', troop(24, 23), mace)
    check('  and an archer is not', troop(22, 24) != mace, True)
    h.put32(enabled, 0)
    check('switched off, a tunneller gets no troop, as in the unmodified game',
          troop(5, 25), 0)
    h.put32(enabled, 1)

    site = h.E.find('85 C0 0F 84 ? ? ? ? 83 FB 1E 6A 00 55 50 75')[0]
    stop = h.allocate_code([0xC3])
    ended = []
    rel = struct.unpack('<i', f.e.data[f.e.va2off(site + 4):f.e.va2off(site + 4) + 4])[0]
    exit_to = (site + 8 + rel) & 0xFFFFFFFF                 # from the file: the hook is on it
    for where, name in ((site + 8, 'recruits'), (exit_to, 'gives up'),
                        (site + 0xAD, 'next unit')):
        h.cpu.hooks[where] = (lambda n: lambda cpu: (ended.append(n), setattr(cpu, 'eip', stop)))(name)

    def recruiting(building, kind):
        ended.clear()
        h.run(site, regs=dict(eax=building, ebx=kind))
        return ended[-1] if ended else '?'

    check('a unit whose building stands is recruited', recruiting(1234, 5), 'recruits')
    check('a tunneller with no guild: the pass goes on to the next unit',
          recruiting(0, 5), 'next unit')
    check('any other unit with no building: the pass ends as it always did',
          recruiting(0, 24), 'gives up')
    h.put32(enabled, 0)
    check('switched off, a tunneller with no guild ends the pass too', recruiting(0, 5),
          'gives up')

    d = Fixture(extreme, config={'diagnostics': {'enabled': True}})
    dh = d.h
    d.set_unit(22, owner=3, kind=5, alive=2)
    before = len(dh.logs)
    dh.run(lookup, stack=[3, 22])
    said = dh.logs[before:]
    check('with diagnostics on, a tunneller joining a raid troop says so',
          [('joins a raid troop' in x and 'a=22 tile=3' in x) for x in said], [True])
    stop2 = dh.allocate_code([0xC3])
    dh.cpu.hooks[site + 0xAD] = lambda cpu: setattr(cpu, 'eip', stop2)
    before = len(dh.logs)
    dh.run(site, regs=dict(eax=0, ebx=5, ebp=3))
    said = dh.logs[before:]
    check('  and an AI with no guild says it recruits its next unit',
          [('no Tunneler' in x and 'a=3 ' in x) for x in said], [True])


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else 'both'
    if which in ('v', 'both'):
        scenario(False)
        raids(False)
    if which in ('e', 'both'):
        scenario(True)
        raids(True)
    print('\n%s' % ('ALL OK' if not FAILURES else 'FAILURES: ' + ', '.join(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == '__main__':
    sys.exit(main())
