"""Exercise native collapse code and Map Extensions callbacks on both 1.41 PEs."""
import struct
import unittest

from lupa.lua54 import LuaError

from harness import SENTINEL
from test_tunnelers import Fixture

STEP_ACTIVE = 0x200
STEP_RADIUS = 0x214
STEP_DX = 0x258
STEP_DY = 0x25C


def fixture(extreme, radius):
    game = Fixture(extreme, config={'collapse': {'spread_radius': radius}})
    game.h.lua.execute(b'''
        local callbacks = testState.callbacks
        function saveTunnelers()
          local bytes
          callbacks:capture({put=function(_, _, value) bytes=value end})
          return bytes
        end
        function loadTunnelers(bytes)
          local handle = {exists=function() return true end, get=function() return bytes end}
          callbacks:validate(handle)
          callbacks:deserialize(handle)
        end
    ''')
    return game


def active_tile(game, radius):
    game.h.put32(game.step_tile, 100 * 400 + 200)
    game.h.put32(game.step_x, 200)
    game.h.put32(game.step_y, 100)
    game.h.put32(game.step_flags, 0)
    game.h.put32(game.control + STEP_RADIUS, radius)
    game.h.put32(game.control + STEP_DX, -1 & 0xFFFFFFFF)
    game.h.put32(game.control + STEP_DY, -2 & 0xFFFFFFFF)
    game.h.put32(game.control + STEP_ACTIVE, 1)


class SaveRadiusTests(unittest.TestCase):
    def test_active_tile_survives_changed_radius_and_resaving(self):
        for extreme in (False, True):
            with self.subTest(extreme=extreme):
                source = fixture(extreme, 2)
                active_tile(source, 2)
                saved = source.h.lua.globals()[b'saveTunnelers']()
                target = fixture(extreme, 0)
                target.h.lua.globals()[b'loadTunnelers'](saved)
                self.assertEqual(target.h.u32(target.spread_radius), 0)
                self.assertEqual(target.h.u32(target.control + STEP_ACTIVE), 1)
                self.assertEqual(target.h.u32(target.control + STEP_RADIUS), 2)

                # Save again while the configured radius is zero, then load
                # under a third configuration. The in-flight tile keeps two.
                saved_again = target.h.lua.globals()[b'saveTunnelers']()
                reloaded = fixture(extreme, 1)
                reloaded.h.lua.globals()[b'loadTunnelers'](saved_again)
                self.assertEqual(reloaded.h.u32(reloaded.spread_radius), 1)
                self.assertEqual(reloaded.h.u32(reloaded.control + STEP_RADIUS), 2)
                step = reloaded.h.assembly[reloaded.h.lua.eval(b'require("templates").queue_step')]
                for _ in range(23):
                    reloaded.h.run(step, until=SENTINEL)
                    self.assertEqual(reloaded.h.u32(reloaded.control + STEP_ACTIVE), 1)
                reloaded.h.run(step, until=SENTINEL)
                self.assertEqual(reloaded.h.u32(reloaded.control + STEP_ACTIVE), 0)

    def test_invalid_radius_is_refused_before_writes(self):
        game = fixture(False, 2)
        active_tile(game, 2)
        saved = game.h.lua.globals()[b'saveTunnelers']()
        header = game.h.lua.globals()[b'testState'][b'options'][b'format']
        # The configured radius, speed and family mode are consecutive words
        # after the runtime header. Find the radius using a capture with radius 3.
        game.h.put32(game.control + STEP_RADIUS, 3)
        comparison = game.h.lua.globals()[b'saveTunnelers']()
        touched, = [i for i, (x, y) in enumerate(zip(saved, comparison)) if x != y]
        self.assertGreater(touched, len(header))
        corrupt = saved[:touched] + struct.pack('<I', 9) + saved[touched + 4:]
        with self.assertRaisesRegex(LuaError, 'invalid saved collapse radius'):
            game.h.lua.globals()[b'loadTunnelers'](corrupt)
        self.assertEqual(game.h.lua.globals()[b'saveTunnelers'](), comparison)


if __name__ == '__main__':
    unittest.main()
