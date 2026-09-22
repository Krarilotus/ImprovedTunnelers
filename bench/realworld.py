"""A small castle run with the game's own code.

Tunnellers here are dug in, aimed, moved and collapsed by the real UpdateTunneler and the
real processUnitMove, once a tick each, exactly as updateUnits drives them - so what these
tests see is what the game does, the module included. Only the map is synthetic: a
walkable square with tile = y * 400 + x, and the game's own direction tables filled in.

Vanilla executable only - the addresses of the map layers are the vanilla build's.
"""
import struct
from test_tunnelers import Fixture, UNIT
from test_real_retarget import world, MAPW, SENTINEL, STACK_TOP
from x86emu_t import Halt, MASK

UNITS_STATE = 0x1387F38
MOVER = 0x578C40                 # processUnitMove(unit, stateBasedSpeed)
KEEP_TYPE = 41


class Castle:
    def __init__(self, walls=(), camp=(300, 100), enemy=2, lo=60, hi=161):
        self.f = f = Fixture(False)
        self.h = h = f.h
        f.building_base = 0xF98534
        world(f, wall_at=None, lo=lo, hi=hi)
        self.base = f.building_base
        self.enemy = enemy
        self.tick_now = 5000
        self.next_building = 30
        self.strays = []
        for x, y in walls:
            self.wall(x, y)
        if camp is not None:
            self.camp(camp, enemy)

    # ---------------------------------------------------------------------- the map
    def tile(self, x, y):
        return y * MAPW + x

    def wall(self, x, y, owner_byte=1):
        t = self.tile(x, y)
        self.h.put32(self.f.tile_flags + 4 * t, 0x100)
        self.h.put8(self.f.wall_owner + t, owner_byte)       # (1 & 7) + 1 = player 2

    def take_down(self, x, y):
        """What another tunnel's collapse would leave: no wall."""
        self.h.put32(self.f.tile_flags + 4 * self.tile(x, y), 0)

    def standing(self, x, y):
        return bool(self.h.u32(self.f.tile_flags + 4 * self.tile(x, y)) & 0x100)

    def building(self, kind, owner, tiles, at=None):
        index = self.next_building
        self.next_building += 1
        b = self.base + index * 0x32C
        self.h.put16(b + 0xD0, 1)
        self.h.put16(b + 0xD2, kind)
        self.h.put16(b + 0xD6, owner)
        x, y = at or tiles[0]
        self.h.put16(b + 0xEE, x)
        self.h.put16(b + 0xF0, y)
        for tx, ty in tiles:
            self.h.put16(self.f.building_tiles + 2 * self.tile(tx, ty), index)
        return index

    def keep(self, x0, y0, x1, y1, owner=2):
        tiles = [(x, y) for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)]
        return self.building(KEEP_TYPE, owner, tiles)

    def camp(self, at, player):
        index = self.building(20, player, [], at=at)
        self.h.put32(self.f.camp_ids + 0x39F4 * player, index)

    # ------------------------------------------------------------------ tunnellers
    def tunneller(self, unit, entrance, owner=1, siege=2):
        """A tunneller standing on its entrance, in state 9: about to be aimed."""
        f, h = self.f, self.h
        ex, ey = entrance
        ent = self.building(57, owner, [], at=(ex, ey + 1))     # someY = y - 1 on an even try
        b = self.base + ent * 0x32C
        h.put16(b + 0x110, unit)
        h.put32(b + 0x25C, 0)
        f.set_unit(unit, owner=owner, x=ex, y=ey, tile=self.tile(ex, ey), uid=1000 + unit,
                   siege=siege, state=9, kind=5, alive=2, dying=0)
        h.put16(f.unit(unit) + 0x338, ent)
        return unit

    def u16(self, unit, off):
        return struct.unpack('<H', self.h.m.read(self.f.unit(unit) + off, 2))[0]

    def i16(self, unit, off):
        return struct.unpack('<h', self.h.m.read(self.f.unit(unit) + off, 2))[0]

    def state(self, unit):
        return self.u16(unit, 0x2C0)

    def alive(self, unit):
        return self.u16(unit, 0x8C) == 2

    def at(self, unit):
        return self.i16(unit, 0xC4), self.i16(unit, 0xC6)

    def heading(self, unit):
        return self.i16(unit, 0xC8), self.i16(unit, 0xCA)

    def plan(self, unit):
        """(index, length, ladder exit)"""
        return self.u16(unit, 0xFA), self.u16(unit, 0xFC), (self.i16(unit, 0xCC), self.i16(unit, 0xCE))

    def steps(self, unit):
        """The whole plan, walked from its ladder exit: the tiles the tunnel runs under."""
        index, length, (x, y) = self.plan(unit)
        out = [(x, y)]
        for i in range(length):
            byte = self.h.m.read(self.f.unit(unit) + 0xFE + i // 2, 1)[0]
            d = (byte >> 4) & 15 if i & 1 else byte & 15
            dx = struct.unpack('<h', self.f.e.data[self.f.e.va2off(0xB49048 + 8 * d):][:2])[0]
            dy = struct.unpack('<h', self.f.e.data[self.f.e.va2off(0xB4904C + 8 * d):][:2])[0]
            x, y = x + dx, y + dy
            out.append((x, y))
        return out

    # ------------------------------------------------------------------ running it
    def call(self, fn, args=(), ecx=0):
        cpu = self.h.cpu
        cpu.r['esp'] = STACK_TOP
        for a in reversed(args):
            cpu.push(a & MASK)
        cpu.push(SENTINEL)
        cpu.r['ecx'] = ecx
        cpu.eip = fn
        original = self.h.m.write

        def guarded(address, data):
            if (address & MASK) < 0x400000:
                self.strays.append((address, len(data)))
            return original(address, data)
        self.h.m.write = guarded
        try:
            cpu.run(SENTINEL, 80_000_000)
        finally:
            self.h.m.write = original

    def dig_in(self, unit, ticks=12):
        """State 9 run by the game until the path is laid, then what UpdateTunnel does when
        the entrance's animation ends: state 3, on its way."""
        for _ in range(ticks):
            self.tick_now += 1
            self.h.put32(self.f.ticks, self.tick_now)
            self.h.put32(self.f.current_unit, unit)
            self.call(self.f.tunneler)
            if self.u16(unit, 0xF6) == 1 or not self.alive(unit):
                break
        if self.alive(unit) and self.state(unit) == 9:
            self.h.put16(self.f.unit(unit) + 0x2C0, 3)
            self.h.put16(self.f.unit(unit) + 0xF6, 2)

    def tick(self, units):
        self.tick_now += 1
        self.h.put32(self.f.ticks, self.tick_now)
        for unit in units:
            if not self.alive(unit):
                continue
            self.h.put32(self.f.current_unit, unit)
            self.call(MOVER, (unit, self.i16(unit, 0x2BE)), UNITS_STATE)
            self.h.put32(self.f.current_unit, unit)
            self.call(self.f.tunneler)

    def run(self, units, until, limit=900, watch=None):
        for n in range(limit):
            self.tick(units)
            if watch:
                watch(n)
            if until():
                return n
        return None

    # --------------------------------------------------------------- the module
    def line(self, owner, slot=0):
        a = self.f.lines + 64 * owner + 16 * slot
        return tuple(self.h.u32(a + 4 * k) for k in range(4))
