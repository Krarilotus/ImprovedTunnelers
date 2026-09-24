"""Bounded save codec and real Map Extensions/stock framework proxy integration.

Set UCP_MAP_EXTENSIONS and UCP_FRAMEWORK_PROXIES for the owner integration case.
No game process, save hook or multiplayer test is run by these checks.
"""
import hashlib
import os
from pathlib import Path
import struct
import time
import unittest
from lupa.lua54 import LuaRuntime, LuaError

MODULE = Path(__file__).resolve().parents[1] / 'module'


class StateHost:
    def __init__(self, base=0x60000000, diagnostics=0, speed=2):
        self.base, self.writes = base, 0
        self.lua = lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
        g = lua.globals()
        lua.execute(b'core={}; package.preload.templates=function() return {} end')
        g[b'messages'] = lua.execute((MODULE/'messages.lua').read_bytes())
        lua.execute(b"package.preload.messages=function() return messages end")
        source = (MODULE / 'init.lua').read_bytes().replace(b'\r\n', b'\n')
        self.C, self.layout = lua.execute(source[:source.index(b'\nreturn {\n\n  enable')] + b'''
          return C, {queue=QUEUE_MAX,zones=ZONE_COUNT,records=RECORD_COUNT,
            lines=(PLAYER_COUNT+1)*4,refused=ROUTE.refused,routeSize=ROUTE.size,
            entries=ROUTE.entries,pathMax=ROUTE.pathMax,pathOffset=ROUTE.pathOffset}
        ''')
        self.mem = bytearray(self.C[b'SIZE'])
        g[b'core'][b'readInteger'] = lambda at: struct.unpack_from('<i', self.mem, at-base)[0]
        g[b'core'][b'readString'] = lambda at, size: bytes(self.mem[at-base:at-base+size])
        def write(at, values):
            data = bytes(values.values())
            self.mem[at-base:at-base+len(data)] = data
            self.writes += 1
        g[b'core'][b'writeBytes'] = write
        g[b'sha'] = lua.table_from({b'sha256': lambda value: hashlib.sha256(value).hexdigest().encode()})
        self.put('RING_CURSOR', base+self.C[b'RECORDS'])
        self.put('REFUSED_CURSOR', base+self.C[b'REFUSED'])
        self.put('SPREAD_RADIUS', 2)
        self.put('SPEED', speed)
        self.put('DIAGNOSTICS', diagnostics)
        g[b'state'] = lua.execute((MODULE/'state.lua').read_bytes())
        g[b'C'], g[b'layout'], g[b'base'] = self.C, self.layout, base
        lua.execute(b'''
          module = {control=base, stateSupport={fingerprint=string.rep('a',64),
            owner={registerSection=function(_, name, value, options) callbacks=value end}}}
          state.attach(module, C, layout, 'all-tested-capabilities')
          function capture()
            local bytes
            callbacks:capture({put=function(_, path, value) bytes=value end})
            return bytes
          end
          function handle(bytes, kind)
            return {loadKind=kind, exists=function() return bytes~=nil end,
              get=function() return bytes end}
          end
          function restore(bytes, kind) callbacks:deserialize(handle(bytes, kind)) end
          function validate(bytes, kind) callbacks:validate(handle(bytes, kind)) end
        ''')

    def put(self, name, value, offset=0):
        struct.pack_into('<I', self.mem, self.C[name.encode()]+offset, value & 0xFFFFFFFF)

    def capture(self): return self.lua.globals()[b'capture']()
    def restore(self, data, kind=b'save'): self.lua.globals()[b'restore'](data, kind)

    def populated(self):
        self.put('LAST_TICK', 500)
        self.put('LAST_REDIRECT', 498)
        self.put('FAIL_SPOT', 1500)
        self.put('FAIL_UNTIL', 540)
        self.put('REFUSED_CURSOR', self.base+self.C[b'REFUSED']+56)
        self.put('REFUSED', 1500)
        self.put('REFUSED', 600, 4)
        self.put('RING_CURSOR', self.base+self.C[b'RECORDS']+16*63)
        for index, value in enumerate((9001, 3, self.base+self.C[b'LINES']+16*35, 500*4+2)):
            self.put('RECORDS', value, 4*index)
        for index, value in enumerate((1500, 50, 60, 490)):
            self.put('LINES', value, 16*35+4*index)
        for index, value in enumerate((50, 60, 8, 900)):
            self.put('ZONES', value, 16*31+4*index)
        self.put('QUEUE_COUNT', 2)
        for slot in range(2):
            for index, value in enumerate((1500+slot, 50+slot, 60, 8 << 8)):
                self.put('QUEUE', value, slot*16+4*index)
        self.put('STEP_ACTIVE', 1)
        for index, value in enumerate((1502, 52, 60, 8 << 8, -1, 1)):
            self.put('STEP_TILE', value, 4*index)
        route = 35*self.layout[b'routeSize']
        for index, value in enumerate((1, 1, 0, 2, 1500, (60 << 16)|50, 1, 499)):
            self.put('ROUTES', value, route+4*index)
        self.put('ROUTES', 1499, route+self.layout[b'pathOffset'])
        self.put('ROUTES', 1500, route+self.layout[b'pathOffset']+4)
        return self


class ReplayStateTests(unittest.TestCase):
    def test_relocation_pending_work_and_world_reset(self):
        first = StateHost().populated()
        data = first.capture()
        second = StateHost(0x61000000, diagnostics=1)
        second.restore(data)
        self.assertEqual(second.capture(), data)
        # Loading an older or later snapshot is independent of the current tick.
        for tick in (1, 999999):
            second.put('LAST_TICK', tick)
            second.put('QUEUE_COUNT', 0)
            second.restore(data)
            self.assertEqual(second.capture(), data)
        first.restore(None, b'map')
        self.assertEqual(first.capture(), StateHost().capture())

    def test_rejections_do_not_write(self):
        h = StateHost().populated()
        data = h.capture()
        corruptions = [data[:-1], data+b'\0', b'broken'+data[6:], None]
        # Generate structurally malformed snapshots through native state; capture
        # must preserve them so restore/owner preflight can reject them atomically.
        for name, value, offset in [('QUEUE_COUNT', 513, 0), ('STEP_ACTIVE', 2, 0),
                                    ('STEP_DX', 3, 0), ('QUEUE', 9 << 8, 12),
                                    ('ROUTES', 193, 35*h.layout[b'routeSize']+12),
                                    ('ZONES', 9, 16*31+8)]:
            h.restore(data)
            h.put(name, value, offset)
            corruptions.append(h.capture())
        h.restore(data)
        for invalid in corruptions:
            before, writes = bytes(h.mem), h.writes
            with self.assertRaises(LuaError): h.restore(invalid)
            self.assertEqual(bytes(h.mem), before)
            self.assertEqual(h.writes, writes)
        with self.assertRaises(LuaError): StateHost(speed=3).restore(data)
        other = StateHost()
        other.lua.execute(b"module.stateSupport.fingerprint=string.rep('b',64); state.attach(module,C,layout,'changed')")
        with self.assertRaises(LuaError): other.restore(data)

    def test_diagnostics_scratch_and_observed_boundary(self):
        h = StateHost().populated()
        g = h.lua.globals()
        original = h.capture()
        g[b'callbacks'][b'observeBoundary']()
        for name in ('SW_LAST','SW_DAMAGE_MAX','REPORT','CAMP_X','ROUTE_CURRENT','TICK_LEFT','DAMAGE_LEFT'):
            h.put(name, 0x12345678)
        self.assertEqual(h.capture(), original)
        h.put('LAST_REDIRECT', 600)
        self.assertEqual(g[b'callbacks'][b'boundaryIntegrity'](), hashlib.sha256(original).hexdigest().encode())
        self.assertNotEqual(g[b'callbacks'][b'integrity'](), g[b'callbacks'][b'boundaryIntegrity']())
        started = time.perf_counter()
        for _ in range(1000): g[b'callbacks'][b'observeBoundary']()
        print(f'bounded {len(original)}-byte boundary capture: {(time.perf_counter()-started):.3f} ms/call (1000 calls)')

    @unittest.skipUnless(os.environ.get('UCP_MAP_EXTENSIONS') and os.environ.get('UCP_FRAMEWORK_PROXIES'),
                         'owner/framework checkout not supplied')
    def test_real_required_owner_and_framework_proxy(self):
        h = StateHost().populated()
        g = h.lua.globals()
        g[b'ownerRoot'] = os.environ['UCP_MAP_EXTENSIONS'].replace('\\','/').encode()
        g[b'proxies'] = h.lua.execute(Path(os.environ['UCP_FRAMEWORK_PROXIES']).read_bytes())
        h.lua.execute(b'''
          package.path=ownerRoot..'/?.lua;'..package.path
          extensions={proxies=proxies}; log=function() end
          for _,name in ipairs({'memory','game','callbacks'}) do package.loaded['mapextensions.'..name]={} end
          local api,metadata=dofile(ownerRoot..'/init.lua')
          owner=proxies.ExtensionProxy(api,metadata.proxy)
          owner:registerSection('improved-tunnelers',callbacks,
            {required=true,format='test',fingerprint=string.rep('a',64),initializeOnMap=true})
          assert(owner:captureRequiredSections()['improved-tunnelers/tunnelers.bin']==capture())
          owner:observeRequiredStateBoundary()
          assert(owner:requiredStateBoundaryIntegrity()['improved-tunnelers'].digest==callbacks:integrity())
          local required=require('mapextensions.required')
          assert(not pcall(required.validateEmpty,{kind='save'}))
          required.validateEmpty({kind='map'})
          assert(required.initializesOnMap('improved-tunnelers',{kind='map'}))
          callbacks:initialize({kind='map'})
          assert(core.readInteger(base+C.QUEUE_COUNT)==0 and core.readInteger(base+C.STEP_ACTIVE)==0)
          module.control=nil
          assert(next(owner:requiredStateContracts())==nil)
          assert(not pcall(callbacks.validate,callbacks,handle(capture(),'save')))
        ''')


if __name__ == '__main__': unittest.main()
