-- Only this module's persistent simulation data belongs here. Map Extensions owns
-- save hooks, map/save discrimination, required-provider admission and Recorder access.
local M = {}
local path, format = 'tunnelers.bin', 'improved-tunnelers-state-1'

-- What a save's tunneler state is checked against. Map Extensions refuses a save whose
-- fingerprint differs from the one registered here by a single character, so this must
-- describe the *layout of the saved state*, not the module's code: a code change that
-- leaves the saved layout alone must not orphan every save made before it. (1.7.1 and
-- 1.7.2 hashed their own source files here, which did exactly that.)
--
-- The value is the one 1.7.2 wrote into its saves - the hash of its init.lua,
-- templates.lua and state.lua - so those saves keep loading. 1.7.1, 1.7.2 and 1.7.3 all
-- save the same ranges in the same layout. Change it, together with `format`, only when
-- the saved layout itself changes.
local STATE_FINGERPRINT = 'c5041749cd5d181bbce5baf2762f27e7b931818fc67d938d4c454a81cda5e9cc'

-- Map Extensions uses the first line for its dialog and logs the detail.
local function reject(key, detail)
  local messages = require('messages')[key]
  local text = modules and modules.textResourceModifier
  local ok, language = pcall(function() return text:GetLanguage() end)
  local message = ok and type(language) == 'string' and messages[language:lower()]
  error('Improved Tunnelers: ' .. (message or messages.english) .. '\n' .. detail, 0)
end

function M.prepare()
  local owner = modules and modules['map-extensions']
  assert(owner and type(owner.requiredStateVersion) == 'function'
    and owner:requiredStateVersion() == 1,
    'Improved Tunnelers requires Map Extensions 1.1.5 required-state support')
  assert(type(owner.requiredStateMapPolicyVersion) == 'function'
    and owner:requiredStateMapPolicyVersion() == 1,
    'Improved Tunnelers requires Map Extensions editable-map initialization support')
  local native = owner:getNativeSaveInterface()
  assert(native and native.failureHandling == 1 and native.readContext == 1,
    'Improved Tunnelers requires Map Extensions save failure handling and read context')
  return {owner = owner, fingerprint = STATE_FINGERPRINT}
end

function M.attach(module, C, layout, capabilities)
  local control = capabilities and module.control
  local support = module.stateSupport
  local baseline = control and core.readString(control, C.SIZE)
  local function headerField(offset, size)
    return control and core.readString(control + offset, size) or string.rep('\0', size)
  end
  local function read(offset) return core.readInteger(control + offset) & 0xFFFFFFFF end
  local ranges = {
    {C.LAST_TICK, 4}, {C.LAST_REDIRECT, 4}, {C.FAIL_SPOT, 8},
    {C.RING_CURSOR, 4}, {C.REFUSED_CURSOR, 4}, {C.REFUSED, layout.refused * 8},
    {C.STEP_ACTIVE, 4}, {C.STEP_TILE, 24}, {C.QUEUE_COUNT, 4},
    {C.QUEUE, C.ZONES - C.QUEUE}, {C.ZONES, C.RECORDS - C.ZONES},
    {C.RECORDS, C.LINES - C.RECORDS}, {C.LINES, C.PLAN_BUFFER - C.LINES},
    {C.ROUTES, layout.lines * layout.routeSize},
  }
  local key = format .. '\0' .. support.fingerprint
  local identityPrefix = key .. (capabilities or '')
    .. headerField(0, C.DIAGNOSTICS)
    .. headerField(C.COLLAPSE_DAMAGE, 12)
    .. headerField(C.HIDE_SELECT, 8)
    .. headerField(C.UNDER_BUILDINGS, 4)
  local identitySuffix = headerField(C.SPEED, 4)
    .. headerField(C.FAMILY_READY, 4)
  local headerSize = #identityPrefix + 4 + #identitySuffix
  local offsets, length = {}, headerSize
  for _, range in ipairs(ranges) do
    for offset = 0, range[2] - 4, 4 do offsets[range[1] + offset] = length + offset + 1 end
    length = length + range[2]
  end
  -- A save names the format and fingerprint it was written in, then the settings and
  -- native capabilities of the game that wrote it. Only the first two decide whether its
  -- state can be read: the ranges after them are the same whatever the settings were, and
  -- data for a feature that is now switched off is simply never looked at. So a save made
  -- with other settings - including a capability string of another length - is read, and
  -- its header swapped for this game's own.
  local body = length - headerSize
  -- The format-1 radius word holds the active tile's radius while a tile is active and
  -- the configured radius otherwise, at the same byte offset in every format-1 save.
  local function word(bytes, offset) return string.unpack('<I4', bytes, offsets[offset]) end
  local function replace(bytes, offset, value)
    local at = offsets[offset]
    return bytes:sub(1, at - 1) .. string.pack('<I4', value) .. bytes:sub(at + 4)
  end
  local function index(pointer, start, count, stride)
    local offset = pointer - control - start
    assert(offset >= 0 and offset < count * stride and offset % stride == 0,
      'Improved Tunnelers: invalid live state pointer')
    return offset // stride
  end
  local function capture()
    local radius = read(read(C.STEP_ACTIVE) == 1 and C.STEP_RADIUS or C.SPREAD_RADIUS)
    local parts = {identityPrefix, string.pack('<I4', radius), identitySuffix}
    for _, range in ipairs(ranges) do
      local offset = range[1]
      local bytes = core.readString(control + offset, range[2])
      if offset == C.RING_CURSOR then
        bytes = string.pack('<I4', index(read(offset), C.RECORDS, layout.records, 16))
      elseif offset == C.REFUSED_CURSOR then
        bytes = string.pack('<I4', index(read(offset), C.REFUSED, layout.refused, 8))
      elseif offset == C.RECORDS then
        local records = {}
        for i = 0, layout.records - 1 do
          local at = i * 16 + 1
          local pointer = string.unpack('<I4', bytes, at + 8)
          records[#records + 1] = bytes:sub(at, at + 7)
            .. string.pack('<I4', pointer == 0 and 0 or index(pointer, C.LINES, layout.lines, 16) + 1)
            .. bytes:sub(at + 12, at + 15)
        end
        bytes = table.concat(records)
      end
      parts[#parts + 1] = bytes
    end
    return table.concat(parts)
  end
  local function validate(bytes)
    local radiusDistance = 4 + #identitySuffix
    if type(bytes) ~= 'string' or #bytes < body + #key + radiusDistance
        or bytes:sub(1, #key) ~= key then
      reject('incompatibleSaveState', 'saved format or layout does not match')
    end
    local function check(valid, detail)
      if not valid then reject('damagedSaveState', detail) end
    end
    local savedRadius = string.unpack('<I4', bytes, #bytes - body - radiusDistance + 1)
    bytes = identityPrefix .. string.pack('<I4', savedRadius) .. identitySuffix .. bytes:sub(#bytes - body + 1)
    local function bounded(offset, maximum)
      local value = word(bytes, offset)
      check(value <= maximum, 'invalid saved state at offset ' .. offset)
      return value
    end
    local function tile(offset) return bounded(offset, 400 * 400 - 1) end
    local function coordinate(offset) return bounded(offset, 399) end
    local function queued(offset)
      tile(offset); coordinate(offset + 4); coordinate(offset + 8)
      local flags = word(bytes, offset + 12)
      -- bits: 1 a quiet fill, 4 its ground is back (1.7.6), 8-11 who brings it down
      check(flags & 0xFFFFF0FA == 0 and flags >> 8 <= 8,
        'invalid saved collapse owner/flags')
    end
    bounded(C.RING_CURSOR, layout.records - 1)
    bounded(C.REFUSED_CURSOR, layout.refused - 1)
    tile(C.FAIL_SPOT)
    for i = 0, layout.refused - 1 do tile(C.REFUSED + i * 8) end
    if bounded(C.STEP_ACTIVE, 1) == 1 then
      queued(C.STEP_TILE)
      check(savedRadius <= 8, 'invalid saved collapse radius')
      for _, offset in ipairs({C.STEP_DX, C.STEP_DY}) do
        local value = string.unpack('<i4', bytes, offsets[offset])
        check(value >= -savedRadius and value <= savedRadius,
          'invalid saved collapse cursor')
      end
    end
    for i = 0, bounded(C.QUEUE_COUNT, layout.queue) - 1 do queued(C.QUEUE + i * 16) end
    for i = 0, layout.zones - 1 do
      local offset = C.ZONES + i * 16
      coordinate(offset); coordinate(offset + 4); bounded(offset + 8, 8)
    end
    for i = 0, layout.records - 1 do bounded(C.RECORDS + i * 16 + 8, layout.lines) end
    for i = 0, layout.lines - 1 do
      local line, route = C.LINES + i * 16, C.ROUTES + i * layout.routeSize
      tile(line); coordinate(line + 4); coordinate(line + 8)
      bounded(route, 2)
      local count = bounded(route + 4, layout.entries)
      bounded(route + 8, count)
      local tiles = bounded(route + 12, layout.pathMax)
      for entry = 0, count - 1 do
        local offset = route + 16 + entry * 16
        tile(offset)
        local xy = word(bytes, offset + 4)
        check(xy & 0xFFFF <= 399 and xy >> 16 <= 399, 'invalid saved route coordinates')
        check(tiles > 0, 'Improved Tunnelers: saved route has no path')
        bounded(offset + 8, tiles - 1)
      end
      for entry = 0, tiles - 1 do tile(route + layout.pathOffset + entry * 4) end
    end
    return bytes, savedRadius
  end
  -- core.writeBytes is the framework's binary writer. Small chunks avoid Lua's
  -- multiple-return stack limit; no custom native memory or save bridge is needed.
  local function write(address, bytes)
    for first = 1, #bytes, 4096 do
      core.writeBytes(address + first - 1, {bytes:byte(first, math.min(first + 4095, #bytes))})
    end
  end
  local function restore(bytes)
    local savedRadius
    bytes, savedRadius = validate(bytes) -- Check the entire body before any writes.
    bytes = replace(bytes, C.RING_CURSOR, control + C.RECORDS + word(bytes, C.RING_CURSOR) * 16)
    bytes = replace(bytes, C.REFUSED_CURSOR, control + C.REFUSED + word(bytes, C.REFUSED_CURSOR) * 8)
    for i = 0, layout.records - 1 do
      local offset = C.RECORDS + i * 16 + 8
      local line = word(bytes, offset)
      bytes = replace(bytes, offset, line == 0 and 0 or control + C.LINES + (line - 1) * 16)
    end
    write(control, baseline) -- Scratch and diagnostic clocks never cross worlds.
    if word(bytes, C.STEP_ACTIVE) == 1 then core.writeInteger(control + C.STEP_RADIUS, savedRadius) end
    for _, range in ipairs(ranges) do
      local at = offsets[range[1]]
      write(control + range[1], bytes:sub(at, at + range[2] - 1))
    end
  end
  -- A save from before tunneler state was saved at all (1.6 and older, or the game
  -- without this module) starts with fresh tunneler state - exactly what every load did
  -- before 1.7 - instead of being refused.
  local function active() return control ~= nil and module.control == control end
  local function absent(kind)
    if kind == 'map' then return end
    log(INFO, 'improved-tunnelers: this save holds no tunneler state; tunnels in it carry '
      .. 'on with fresh state.')
  end
  local observed
  local callbacks = {
    isRequired = active,
    initialize = function(_, context)
      if not active() then return end
      absent(context and context.kind)
      write(control, baseline)
      observed = nil
    end,
    serialize = function(_, handle)
      if active() then handle:put(path, capture()) end
    end,
    capture = function(_, handle) handle:put(path, capture()) end,
    integrity = function() return sha.sha256(capture()) end,
    -- Recorder requests a boundary each tick. Copy bounded state there, but hash
    -- only when asked for verification, not in every simulation tick.
    observeBoundary = function() observed = nil; observed = capture() end,
    boundaryIntegrity = function()
      assert(observed, 'No tunneler boundary observed')
      return sha.sha256(observed)
    end,
    validate = function(_, handle)
      if handle:exists(path) then
        validate(handle:get(path))
      elseif active() then absent(handle.loadKind) end
    end,
    deserialize = function(_, handle)
      if not active() then return end
      if handle:exists(path) then restore(handle:get(path))
      else absent(handle.loadKind); write(control, baseline) end
      observed = nil
    end,
  }
  support.owner:registerSection('improved-tunnelers', callbacks,
    {required = true, format = format, fingerprint = support.fingerprint, initializeOnMap = true})
end

return M
