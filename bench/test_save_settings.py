"""Save -> change one setting -> restart -> load, through Map Extensions' load path.

Each restart is a fresh Lua runtime with the changed setting. The saved archive is
the owner's own required.capture(): the manifest and provider entry that its
beforeWriteSav serializes. Loading runs Map's real readWorld hook boundary,
afterReadSav, preflight validators and deserialize. Native code, ZIP compression
and the framework's process stop are stubbed; this is not in-game evidence.

Set UCP_MAP_EXTENSIONS to the Map Extensions 1.1.6 checkout and
UCP_FRAMEWORK_PROXIES to the framework's extensions/proxies.lua.
"""
import os
from pathlib import Path
import unittest

import yaml
from lupa.lua54 import LuaError

from test_replay_state import StateHost

OWNER = os.environ.get('UCP_MAP_EXTENSIONS')
PROXIES = os.environ.get('UCP_FRAMEWORK_PROXIES')
SECTION = b'improved-tunnelers/tunnelers.bin'

OWNER_LUA = b'''
package.path = ownerRoot..'/?.lua;'..package.path
FATAL, WARNING, DEBUG, VERBOSE = -3, -1, 1, 2
extensions = {proxies = proxies}
log = function(level, message)
  if level == WARNING then details = message end
  if level == FATAL then fatal = message; error('PROCESS_STOPPED', 0) end
end
yaml = {parse = function(text) return parse_yaml(text) end}
package.loaded['luamemzip.dll'] = {MemoryZip = function()
  local current
  return {open_entry = function(_, name)
      if archive[name] == nil then return false end
      current = name; return true end,
    read_entry = function() return archive[current], #archive[current] end,
    close_entry = function() current = nil; return true end,
    close = function() end}
end}
package.loaded['mapextensions.memory'] = {customSectionInfoObject = {size = 1}, customSectionAddress = 0}
package.loaded['mapextensions.readcontext'] = {resolve = function()
  return {resources = 0x40000000, resourceFileName = 0x30000000,
    resourceFileNameBytes = string.rep('x', 20)}, function() return {kind = loadKind} end
end}
local readString, readInteger = core.readString, core.readInteger
core.readString = function(at, size) if at < base then return 'zip' end return readString(at, size) end
core.readInteger = function(at) if at < base then return 200000 end return readInteger(at) end
local address, hooks = 100000, {}
core.AOBScan = function() address = address + 100; return address end
core.hookCode = function(callback) hooks[#hooks + 1] = callback; return function() return 123 end end
core.detourCode = function() end
utils = {unpack = function() return {} end}
CallingConvention = {THISCALL = 1}
io.open = function() return {write = function() end, close = function() end} end
local api, metadata = dofile(ownerRoot..'/init.lua')
local owner = proxies.ExtensionProxy(api, metadata.proxy)
require('mapextensions.game').registerReadWriteSavHooks(300000, 1337, require('mapextensions.callbacks'))
local sections = owner:getNativeSaveInterface().sections
owner:registerSection('improved-tunnelers', callbacks, sectionOptions)
function saveArchive() return require('mapextensions.required').capture() end
-- Stock RPS returns 0 to native code after a Lua error; only FATAL stops the game.
function nativeLoad(entries, kind)
  archive, loadKind, fatal, details = entries, kind, nil, nil
  local ok, value = pcall(hooks[1], 200000, sections)
  return ok and value or 0, fatal
end
'''

# One setting at a time, in the order of the Customizations tab. The save is made
# with StateHost's baseline: everything 0/OFF, radius 2, speed 2.
CHANGES = [
    ('repair delay', {'DENIAL_DURATION': 2400}), ('repair delay off', {'DENIAL_ENABLED': 1}),
    ('collapse damage', {'COLLAPSE_DAMAGE': 100}), ('spread switch', {'SPREAD_ENABLED': 1}),
    ('spread damage', {'SPREAD_DAMAGE': 7}), ('spread radius 0', {'SPREAD_RADIUS': 0}),
    ('spread radius 8', {'SPREAD_RADIUS': 8}), ('collapse speed', {'SPEED': 100}),
    ('retarget', {'RETARGET_ENABLED': 1}), ('retarget range', {'RETARGET_RANGE': 5}),
    ('retarget max', {'RETARGET_MAX': 3}), ('towers and gates', {'TARGETS_ENABLED': 1}),
    ('under buildings', {'UNDER_BUILDINGS': 1}), ('unselectable', {'HIDE_SELECT': 1}),
    ('untargetable', {'HIDE_TARGET': 1}), ('buttons', {'UI_ENABLED': 1}),
    ('stances', {'STANCE_ENABLED': 1}), ('raids', {'RAIDS_ENABLED': 1}),
    ('diagnostics', {'DIAGNOSTICS': 1}),
]


def encoded(value):
    if isinstance(value, str): return value.encode()
    if isinstance(value, dict): return {encoded(k): encoded(v) for k, v in value.items()}
    if isinstance(value, list): return [encoded(v) for v in value]
    return value


def owner_host(language=None, **kwargs):
    h = StateHost(**kwargs)
    g = h.lua.globals()
    g[b'ownerRoot'] = OWNER.replace('\\', '/').encode()
    g[b'proxies'] = h.lua.execute(Path(PROXIES).read_bytes())
    g[b'parse_yaml'] = lambda text: h.lua.table_from(encoded(yaml.safe_load(text.decode())), recursive=True)
    if language:
        h.lua.execute(b'modules={textResourceModifier={GetLanguage=function() return language end}}')
        g[b'language'] = language
    h.lua.execute(OWNER_LUA)
    return h


def saved(host):
    return {key: value for key, value in host.lua.globals()[b'saveArchive']().items()}


def load(host, entries, kind=b'save'):
    result, fatal = host.lua.globals()[b'nativeLoad'](host.lua.table_from(entries), kind)
    return result, fatal


@unittest.skipUnless(OWNER and PROXIES, 'owner/framework checkout not supplied')
class SaveSettingsTests(unittest.TestCase):
    def setUp(self):
        self.source = owner_host().populated()
        self.archive = saved(self.source)

    def test_unchanged_and_each_changed_setting_load(self):
        for label, change in [('unchanged', {})] + CHANGES:
            with self.subTest(label):
                target = owner_host(base=0x61000000, settings=change)
                result, fatal = load(target, self.archive)
                self.assertIsNone(fatal)
                self.assertEqual(result, 123)
                self.assertEqual(target.capture(), self.archive[SECTION])
                for name, value in change.items():  # The loading setup's settings apply.
                    self.assertEqual(target.lua.globals()[b'core'][b'readInteger'](
                        target.base + target.C[name.encode()]), value)

    def test_active_partial_tile_keeps_its_radius(self):
        target = owner_host(settings={'SPREAD_RADIUS': 0})
        self.assertIsNone(load(target, self.archive)[1])
        read = lambda name: target.lua.globals()[b'core'][b'readInteger'](target.base + target.C[name])
        self.assertEqual((read(b'STEP_ACTIVE'), read(b'STEP_RADIUS'), read(b'STEP_DX'), read(b'STEP_DY')),
                         (1, 2, -1, 1))
        self.assertEqual(read(b'SPREAD_RADIUS'), 0)  # Only later tiles use the new radius.

    def test_full_queue_from_several_players_round_trips(self):
        source = owner_host().populated()
        count = source.layout[b'queue']
        source.put('QUEUE_COUNT', count)
        for slot in range(count):  # Simultaneous collapses of players 1-8, some quiet.
            for index, value in enumerate((1000+slot, slot % 400, slot // 400 + 1,
                                           (slot % 8 + 1) << 8 | slot % 2)):
                source.put('QUEUE', value, slot*16+4*index)
        archive = saved(source)
        target = owner_host(settings={'SPEED': 100, 'SPREAD_RADIUS': 8, 'COLLAPSE_DAMAGE': 1})
        self.assertIsNone(load(target, archive)[1])
        self.assertEqual(target.capture(), archive[SECTION])

    def test_new_match_after_loading_starts_fresh(self):
        target = owner_host(settings={'SPEED': 9})
        self.assertIsNone(load(target, self.archive)[1])
        # A new match, editor scenario or .sav renamed to .map initializes instead.
        fresh = saved(owner_host(settings={'SPEED': 9}))
        self.assertIsNone(load(target, fresh, b'map')[1])
        self.assertEqual(target.capture(), StateHost(settings={'SPEED': 9}).capture())
        broken = dict(self.archive)
        broken[SECTION] = b'not tunneler state'
        self.assertIsNone(load(target, broken, b'map')[1])
        self.assertEqual(target.capture(), StateHost(settings={'SPEED': 9}).capture())

    def test_unsupported_and_malformed_state_stop_before_writes(self):
        incompatible = owner_host(language=b'German', capabilities=b'other-game-edition')
        corrupt = owner_host().populated()
        corrupt.put('QUEUE', 9 << 8, 12)  # A queued collapse owned by a ninth player.
        malformed = saved(corrupt)
        cases = [
            (incompatible, self.archive, 'Dieser Spielstand benötigt'),
            (owner_host(language=b'German'), malformed, 'Die Tunnelerdaten in diesem Spielstand sind beschädigt'),
            (owner_host(language=b'Polish'), {key: value for key, value in self.archive.items()
                                              if key != SECTION}, 'Ten stary zapis'),
        ]
        for host, entries, message in cases:
            with self.subTest(message):
                before, writes = bytes(host.mem), host.writes
                result, fatal = load(host, entries)
                self.assertEqual(result, 0)
                first = fatal.decode('utf-8').split('\n')
                self.assertEqual(first[0], 'Map Extensions: failed while loading state.')
                self.assertTrue(first[1].startswith('Improved Tunnelers: ' + message), first[1])
                self.assertNotIn('[string', first[1])
                self.assertEqual((bytes(host.mem), host.writes), (before, writes))


if __name__ == '__main__':
    unittest.main()
