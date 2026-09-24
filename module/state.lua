-- Only this module's persistent simulation data belongs here. Map Extensions owns
-- save hooks, map/save discrimination, required-provider admission and Recorder access.
local M = {}
local path, format = 'tunnelers.bin', 'improved-tunnelers-state-1'

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
  -- Use the framework's actual selected package path, including its ZIP-backed IO.
  -- Hash source content, not archive timestamps or a hand-maintained build constant.
  local source = {}
  for _, extension in ipairs(allActiveExtensions) do
    if extension.name == 'improved-tunnelers' then
      for _, file in ipairs({'init.lua', 'templates.lua', 'state.lua'}) do
        local handle = assert(io.open(extension.path .. '/' .. file, 'rb'))
        local bytes = handle:read('*a')
        handle:close()
        source[#source + 1] = string.pack('<I4', #bytes) .. bytes
      end
      return {owner = owner, fingerprint = sha.sha256(table.concat(source))}
    end
  end
  error('Improved Tunnelers is missing from the framework extension inventory')
end

function M.attach(module, C, layout, capabilities)
  local control, support = module.control, module.stateSupport
  local baseline = core.readString(control, C.SIZE)
  local function read(offset) return core.readInteger(control + offset) & 0xFFFFFFFF end
  local ranges = {
    {C.LAST_TICK, 4}, {C.LAST_REDIRECT, 4}, {C.FAIL_SPOT, 8},
    {C.RING_CURSOR, 4}, {C.REFUSED_CURSOR, 4}, {C.REFUSED, layout.refused * 8},
    {C.STEP_ACTIVE, 4}, {C.STEP_TILE, 24}, {C.QUEUE_COUNT, 4},
    {C.QUEUE, C.ZONES - C.QUEUE}, {C.ZONES, C.RECORDS - C.ZONES},
    {C.RECORDS, C.LINES - C.RECORDS}, {C.LINES, C.PLAN_BUFFER - C.LINES},
    {C.ROUTES, layout.lines * layout.routeSize},
  }
  local identity = format .. '\0' .. support.fingerprint .. capabilities
    .. core.readString(control, C.DIAGNOSTICS)
    .. core.readString(control + C.COLLAPSE_DAMAGE, 12)
    .. core.readString(control + C.HIDE_SELECT, 8)
    .. core.readString(control + C.UNDER_BUILDINGS, 4)
    .. core.readString(control + C.SPREAD_RADIUS, 4)
    .. core.readString(control + C.SPEED, 4)
    .. core.readString(control + C.FAMILY_READY, 4)
  local offsets, length = {}, #identity
  for _, range in ipairs(ranges) do
    for offset = 0, range[2] - 4, 4 do offsets[range[1] + offset] = length + offset + 1 end
    length = length + range[2]
  end
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
    local parts = {identity}
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
    assert(type(bytes) == 'string' and #bytes == length and bytes:sub(1, #identity) == identity,
      'Improved Tunnelers: this save requires its original module, configuration and native capabilities')
    local function bounded(offset, maximum)
      local value = word(bytes, offset)
      assert(value <= maximum, 'Improved Tunnelers: invalid saved state at offset ' .. offset)
      return value
    end
    local function tile(offset) return bounded(offset, 400 * 400 - 1) end
    local function coordinate(offset) return bounded(offset, 399) end
    local function queued(offset)
      tile(offset); coordinate(offset + 4); coordinate(offset + 8)
      local flags = word(bytes, offset + 12)
      assert(flags & 0xFFFFF0FE == 0 and flags >> 8 <= 8,
        'Improved Tunnelers: invalid saved collapse owner/flags')
    end
    bounded(C.RING_CURSOR, layout.records - 1)
    bounded(C.REFUSED_CURSOR, layout.refused - 1)
    tile(C.FAIL_SPOT)
    for i = 0, layout.refused - 1 do tile(C.REFUSED + i * 8) end
    if bounded(C.STEP_ACTIVE, 1) == 1 then
      queued(C.STEP_TILE)
      local radius = read(C.SPREAD_RADIUS)
      for _, offset in ipairs({C.STEP_DX, C.STEP_DY}) do
        local value = string.unpack('<i4', bytes, offsets[offset])
        assert(value >= -radius and value <= radius, 'Improved Tunnelers: invalid saved collapse cursor')
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
        assert(xy & 0xFFFF <= 399 and xy >> 16 <= 399, 'Improved Tunnelers: invalid saved route coordinates')
        assert(tiles > 0, 'Improved Tunnelers: saved route has no path')
        bounded(offset + 8, tiles - 1)
      end
      for entry = 0, tiles - 1 do tile(route + layout.pathOffset + entry * 4) end
    end
    return bytes
  end
  -- core.writeBytes is the framework's binary writer. Small chunks avoid Lua's
  -- multiple-return stack limit; no custom native memory or save bridge is needed.
  local function write(address, bytes)
    for first = 1, #bytes, 4096 do
      core.writeBytes(address + first - 1, {bytes:byte(first, math.min(first + 4095, #bytes))})
    end
  end
  local function restore(bytes)
    validate(bytes) -- All bounds and identities checked before the first write.
    bytes = replace(bytes, C.RING_CURSOR, control + C.RECORDS + word(bytes, C.RING_CURSOR) * 16)
    bytes = replace(bytes, C.REFUSED_CURSOR, control + C.REFUSED + word(bytes, C.REFUSED_CURSOR) * 8)
    for i = 0, layout.records - 1 do
      local offset = C.RECORDS + i * 16 + 8
      local line = word(bytes, offset)
      bytes = replace(bytes, offset, line == 0 and 0 or control + C.LINES + (line - 1) * 16)
    end
    write(control, baseline) -- Scratch and diagnostic clocks never cross worlds.
    for _, range in ipairs(ranges) do
      local at = offsets[range[1]]
      write(control + range[1], bytes:sub(at, at + range[2] - 1))
    end
  end
  local function absent(kind)
    if kind == 'map' then return end
    local messages = require('messages').missingSaveState
    local text = modules and modules.textResourceModifier
    local ok, language = pcall(function() return text:GetLanguage() end)
    local message = ok and type(language) == 'string' and messages[language:lower()]
    error('Improved Tunnelers: ' .. (message or messages.english))
  end
  local observed
  local callbacks = {
    isRequired = function() return module.control == control end,
    initialize = function(_, context)
      if module.control ~= control then return end
      absent(context and context.kind)
      write(control, baseline)
      observed = nil
    end,
    serialize = function(_, handle)
      if module.control == control then handle:put(path, capture()) end
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
        assert(module.control == control, 'This save requires Improved Tunnelers to be enabled')
        validate(handle:get(path))
      elseif module.control == control then absent(handle.loadKind) end
    end,
    deserialize = function(_, handle)
      if handle:exists(path) then restore(handle:get(path))
      elseif module.control == control then absent(handle.loadKind); write(control, baseline) end
      observed = nil
    end,
  }
  support.owner:registerSection('improved-tunnelers', callbacks,
    {required = true, format = format, fingerprint = support.fingerprint, initializeOnMap = true})
end

return M
