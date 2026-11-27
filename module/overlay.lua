-- The tunnel mark: a red, moat-like tint on the ground over a tunnel, for the player who dug it.
--
-- The game shows a tunnel by raising the ground over it, but only where that ground is low:
-- its dig raises a tile only while the live or the map height there is below 16 (both
-- increaseHeightForTunnelWithBrush and increaseHeightForTunnelSingleTile test exactly that).
-- Under raised terrain a tunnel leaves no sign at all. This marks those tiles instead.
--
-- The mark is drawn the way the game draws a planned moat: renderMap draws a half-transparent
-- diamond from floats.gm1 (gm 16) right after a tile's ground and before anything that stands
-- on it, and a second, taller piece after the tile's objects on the tiles that redraw their
-- ground then. The moat uses picture 0x39 (blue); the tunnel mark uses 0x37, the red one of
-- the same set, with the same blend level - so it sits under walls, buildings and troops and
-- looks like a moat plan in red.
--
-- Which tiles: a map with one dword per tile, {uid low byte << 24 | owner << 16 | unit slot}.
--   * A digging tunneller marks the tile it is on every tick (UpdateTunneler's state 3, the
--     moment before hasUnitReachedDestination). The first time it does so after a load, it
--     also marks every tile of its plan it has already dug (a per-unit generation stamp).
--   * When a tunnel goes into the collapse queue, its tiles turn into "collapsing" marks
--     (slot 0, owner kept); the queue clears each one as it puts that tile's ground back, so
--     the mark falls in with the tunnel, from the far end back to the entrance, at the
--     collapse's own pace.
--   * Every load (Map Extensions writes the baseline into the control block, and the baseline
--     asks for a rebuild) clears the map and re-marks the queued tiles; the stamps then make
--     each digging tunneller re-mark its own plan.
--   * A digging mark whose tunneller is gone (or whose slot was taken by another unit) is
--     dropped the first time it is drawn.
-- Only the local player's own marks are drawn, and only where both the live and the map
-- height are 16 or more - the tiles the game's raised ground cannot show.

local M = {}

M.TILES = 80400                -- tiles on a map, both executables
M.UNITS = 10000                -- unit slots (the larger exe has 10000)
M.FLOATS_GM = 0x10             -- floats.gm1
M.MARK_FRAME = 0x37            -- 1-based: the red diamond (0x39 is the moat's blue one)
M.TALL_STEP = 8                -- the game draws the taller piece at frame + 8, 9 px lower
M.BLEND = 0x18                 -- the moat's own blend level
M.RAISED = 16                  -- the dig raises a tile only below this height

-- renderMap: the ground of a tile is drawn, then the moat mark if the tile has one.
--   cmp [tileImage], 0xFF / je / cmp [esp+0x38], 0 / je / call RenderTerrainTilesCenterPiece /
--   test esi, esi / je / mov eax, [shade] / sub eax, [yOffset] / mov ecx, [drawX] /
--   add eax, [drawY] / mov edx, [imageId] / push 0x18 ... push 0x10 / mov ecx, core / call blend
M.AOB_GROUND = "81 3D ? ? ? ? FF 00 00 00 74 ? 83 7C 24 38 00 74 ? E8 ? ? ? ? 85 F6 74 ? "
  .. "A1 ? ? ? ? 2B 05 ? ? ? ? 8B 0D ? ? ? ? 03 05 ? ? ? ? 8B 15 ? ? ? ? 6A 18 50 51 52 6A 10 B9 ? ? ? ? E8"
M.GROUND = {
  hook = 0x13,                 -- call RenderTerrainTilesCenterPiece (5 bytes)
  resume = 0x18,               -- test esi, esi: has the game a mark of its own here?
  shade = 0x1D, yOffset = 0x23, drawX = 0x29, drawY = 0x2F, core = 0x41, blendCall = 0x45,
}
M.GROUND.guards = {
  [0x13] = { 0xE8 }, [0x18] = { 0x85, 0xF6, 0x74 }, [0x1C] = { 0xA1 }, [0x21] = { 0x2B, 0x05 },
  [0x27] = { 0x8B, 0x0D }, [0x2D] = { 0x03, 0x05 }, [0x40] = { 0xB9 }, [0x45] = { 0xE8 },
}

-- ... and after the tile's objects, the taller piece on tiles that redraw their ground:
--   cmp dword [esp+0x54], 0 / je skip / ... push 0x18 / push y+9 / push x / push frame+8 ...
-- Interface and Visual Fixes rewrites the call just before this (its FoundationDrawCall); it
-- loads earlier and only scans while it starts, so the two do not meet.
M.AOB_TALL = "F7 C6 00 08 00 00 A3 ? ? ? ? 74 07 E8 ? ? ? ? EB 05 E8 ? ? ? ? 83 7C 24 54 00 74 ? "
  .. "A1 ? ? ? ? 2B 05 ? ? ? ? 8B 0D ? ? ? ? 8D 54 08 09 A1 ? ? ? ? 8B 0D ? ? ? ? 6A 18 52 50 83 C1 08 51 6A 10 B9 ? ? ? ? E8"
M.TALL = { hook = 0x19, hookSize = 7, draw = 0x20, skipOperand = 0x1F }
M.TALL.guards = { [0x19] = { 0x83, 0x7C, 0x24, 0x54, 0x00, 0x74 }, [0x20] = { 0xA1 } }

-- The moat test in renderMap compares the moat's owner's team with the local player's.
M.AOB_PLAYER = "C1 E0 04 0F BE 88 ? ? ? ? 8B 14 8D ? ? ? ? A1 ? ? ? ? 3B 14 85"
M.PLAYER_OPERAND = 0x12

-- UpdateTunneler, state 3 (digging): mov edx, [current unit] / push edx / mov ecx, UnitsState /
-- call hasUnitReachedDestination. Reached every tick a tunneller digs.
M.DIG_HOOK = 0x7CD
M.DIG_HOOK_SIZE = 6
M.DIG_GUARDS = { [0x7CD] = { 0x8B, 0x15 }, [0x7D3] = { 0x52, 0xB9 }, [0x7D9] = { 0xE8 } }

-- Shared by the routines below: is this tile's mark drawn? EAX = tile in, EAX = 1 / 0 out.
-- Clobbers ECX and EDX.
M.test = [[
cmp dword [ON_ADDRESS], 0
je mt_no
cmp eax, TILES
jae mt_no
mov ecx, eax
mov eax, [MARKS_ADDRESS+ecx*4]
test eax, eax
jz mt_no
mov edx, eax
shr edx, 16
and edx, 0xFF
cmp edx, [PLAYER_ADDRESS]
jne mt_no
cmp byte [ecx+BASE_HEIGHT_ADDRESS], RAISED
jb mt_no
cmp byte [ecx+LIVE_HEIGHT_ADDRESS], RAISED
jb mt_no
movzx edx, ax
test edx, edx
jz mt_yes
imul edx, edx, 1168
cmp word [edx+UNIT_TYPE], TUNNELER_TYPE
jne mt_stale
cmp word [edx+UNIT_LOGICAL], ALIVE
jne mt_stale
shr eax, 24
cmp al, byte [edx+UNIT_UID]
jne mt_stale
mt_yes:
mov eax, 1
ret
mt_stale:
mov dword [MARKS_ADDRESS+ecx*4], 0
mt_no:
xor eax, eax
ret
]]

-- After the ground of a tile: the red diamond where the game drew no mark of its own.
M.ground = [[
call CENTER_ADDRESS
test esi, esi
jnz g_out
mov eax, [esp+0x10]
call TEST_ADDRESS
test eax, eax
jz g_out
mov eax, [SHADE_ADDRESS]
sub eax, [Y_OFFSET_ADDRESS]
add eax, [DRAW_Y_ADDRESS]
push BLEND
push eax
push dword [DRAW_X_ADDRESS]
push MARK_FRAME
push FLOATS_GM
mov ecx, CORE_ADDRESS
call BLEND_ADDRESS
g_out:
jmp RESUME_ADDRESS
]]

-- After a tile's objects: the taller piece, as the game does for its own marks.
M.tall = [[
cmp dword [esp+0x54], 0
jne DRAW_ADDRESS
mov eax, [esp+0x10]
call TEST_ADDRESS
test eax, eax
jz t_out
mov eax, [SHADE_ADDRESS]
sub eax, [Y_OFFSET_ADDRESS]
add eax, [DRAW_Y_ADDRESS]
add eax, 9
push BLEND
push eax
push dword [DRAW_X_ADDRESS]
push MARK_FRAME + TALL_STEP
push FLOATS_GM
mov ecx, CORE_ADDRESS
call BLEND_ADDRESS
t_out:
jmp SKIP_ADDRESS
]]

-- The tunneller being updated digs: mark where it is, and once a load, everything it has dug.
-- EAX, ECX and EDX are free here (the game reloads them for its own call that follows).
M.dig = [[
cmp dword [ON_ADDRESS], 0
je d_out
mov eax, [CURRENT_UNIT_ADDRESS]
cmp eax, UNITS
jae d_out
mov ecx, eax
imul ecx, ecx, 1168
movzx edx, byte [ecx+UNIT_UID]
shl edx, 8
mov dl, byte [ecx+UNIT_OWNER]
shl edx, 16
or edx, eax
push ebx
mov bl, [GENERATION_ADDRESS]
cmp [STAMPS_ADDRESS+eax], bl
je d_here
mov [STAMPS_ADDRESS+eax], bl
push esi
push edi
push ebp
mov ebp, ecx
mov esi, [ebp+UNIT_PREVIOUS_TILE]
movsx edi, word [ebp+UNIT_LADDER_Y]
movsx ebx, word [ebp+UNIT_PATH_INDEX]
movsx ecx, word [ebp+UNIT_PATH_LENGTH]
cmp ebx, ecx
jle d_count
mov ebx, ecx
d_count:
xor ecx, ecx
d_walk:
cmp esi, TILES
jae d_walked
cmp edi, MAP_ROWS
jae d_walked
mov [MARKS_ADDRESS+esi*4], edx
cmp ecx, ebx
jge d_walked
mov eax, ecx
shr eax, 1
movsx eax, byte [ebp+eax+UNIT_PATH_PLAN]
test ecx, 1
jz d_even
sar eax, 4
jmp d_direction
d_even:
and eax, 15
d_direction:
cmp eax, 7
ja d_walked
push edx
mov edx, edi
shl edx, 5
add esi, [edx+eax*4+DIRECTIONS_ADDRESS]
add edi, [eax*8+Y_DELTAS_ADDRESS]
pop edx
add ecx, 1
jmp d_walk
d_walked:
mov ecx, ebp
pop ebp
pop edi
pop esi
d_here:
pop ebx
mov eax, [ecx+UNIT_TILE]
cmp eax, TILES
jae d_out
mov [MARKS_ADDRESS+eax*4], edx
d_out:
mov edx, [CURRENT_UNIT_ADDRESS]
jmp RETURN_ADDRESS
]]

-- After a load (or at start): forget every mark, start a new stamp generation, and mark the
-- tiles still waiting in the collapse queue. Called from queue_tick inside its pushad.
M.rebuild = [[
mov dword [REBUILD_ADDRESS], 0
cld
mov edi, MARKS_ADDRESS
mov ecx, TILES
xor eax, eax
rep stosd
mov al, [GENERATION_ADDRESS]
add al, 1
jnz r_generation
mov al, 1
r_generation:
mov [GENERATION_ADDRESS], al
mov ecx, [QUEUE_COUNT_ADDRESS]
cmp ecx, QUEUE_MAX
jbe r_next
mov ecx, QUEUE_MAX
r_next:
sub ecx, 1
jl r_done
mov edx, ecx
shl edx, 4
add edx, QUEUE_ADDRESS
mov eax, [edx+12]
test eax, GROUND_DONE
jnz r_next
and eax, 0xFF00
shl eax, 8
mov edx, [edx]
cmp edx, TILES
jae r_next
mov [MARKS_ADDRESS+edx*4], eax
jmp r_next
r_done:
ret
]]

---The overlay's memory, before the collapse queue's scripts are assembled (they clear marks).
---Returns the values those scripts need, or nil when the overlay is off.
---@param on boolean the setting
---@param control number the module's control block
---@param C table its offsets
function M.prepare(on, control, C)
  if not on then
    return { OVERLAY = 0, MARKS_ADDRESS = 0, OVERLAY_TILES = M.TILES, REBUILD_ADDRESS = 0,
      OVERLAY_REBUILD_ADDRESS = 0 }
  end
  local marks = core.allocate(M.TILES * 4, true)
  local stamps = core.allocate(M.UNITS, true)
  local generation = core.allocate(4, true)
  M.memory = { marks = marks, stamps = stamps, generation = generation }
  core.writeInteger(control + C.OVERLAY_ON, 1)
  core.writeInteger(control + C.OVERLAY_REBUILD, 1)   -- in the baseline: every load rebuilds
  return { OVERLAY = 1, MARKS_ADDRESS = marks, OVERLAY_TILES = M.TILES,
    REBUILD_ADDRESS = control + C.OVERLAY_REBUILD, GENERATION_ADDRESS = generation }
end

---Assemble the rebuild routine (needs the queue's addresses).
function M.rebuildRoutine(values)
  if M.memory == nil then return 0 end
  return core.allocateAssembly(M.rebuild, {
    REBUILD_ADDRESS = values.REBUILD_ADDRESS,
    MARKS_ADDRESS = M.memory.marks,
    GENERATION_ADDRESS = M.memory.generation,
    TILES = M.TILES,
    QUEUE_ADDRESS = values.QUEUE_ADDRESS,
    QUEUE_COUNT_ADDRESS = values.QUEUE_COUNT_ADDRESS,
    QUEUE_MAX = values.QUEUE_MAX,
    GROUND_DONE = values.GROUND_DONE,
  })
end

---Install the marking and the drawing. `h` carries the module's helpers and addresses.
---@return boolean ready
function M.install(h)
  if M.memory == nil then return false end
  local mem = h.memory or M.memory
  local function scan(pattern, purpose)
    local ok, address = pcall(core.AOBScan, pattern)
    if not ok or type(address) ~= "number" or address <= 0 then
      log(WARNING, "improved-tunnelers: could not find " .. purpose
        .. "; the tunnel mark is off. Another module has probably patched the same code.")
      return nil
    end
    return address
  end
  local ground = scan(M.AOB_GROUND, "where the map draws a tile's ground")
  local tall = scan(M.AOB_TALL, "where the map redraws a tile's ground")
  local player = scan(M.AOB_PLAYER, "the local player")
  if ground == nil or tall == nil or player == nil then
    log(ERROR, "The tunnel mark is off. The map drawing code could not be bound.")
    return false
  end
  if not h.guardsHold(ground, M.GROUND.guards, "the map's ground drawing")
      or not h.guardsHold(tall, M.TALL.guards, "the map's ground redrawing")
      or not h.guardsHold(h.tunneler, M.DIG_GUARDS, "the tunneller's digging")
      or h.readAddress(h.tunneler + M.DIG_HOOK + 2) ~= h.currentUnit then
    log(ERROR, "The tunnel mark is off. The map drawing layout could not be verified.")
    log(WARNING, "improved-tunnelers: the map drawing is not laid out as expected; the tunnel mark is off.")
    return false
  end
  local readAddress = h.readAddress
  local blend = h.callTarget(ground + M.GROUND.blendCall)
  if h.callTarget(tall + 0x4F) ~= blend then
    log(ERROR, "The tunnel mark is off. The two moat drawing routines do not match.")
    return false
  end
  local draw = {
    SHADE_ADDRESS = readAddress(ground + M.GROUND.shade),
    Y_OFFSET_ADDRESS = readAddress(ground + M.GROUND.yOffset),
    DRAW_X_ADDRESS = readAddress(ground + M.GROUND.drawX),
    DRAW_Y_ADDRESS = readAddress(ground + M.GROUND.drawY),
    CORE_ADDRESS = readAddress(ground + M.GROUND.core),
    BLEND_ADDRESS = blend,
    BLEND = M.BLEND,
    MARK_FRAME = M.MARK_FRAME,
    TALL_STEP = M.TALL_STEP,
    FLOATS_GM = M.FLOATS_GM,
  }

  local test = core.allocateAssembly(M.test, {
    ON_ADDRESS = h.onAddress,
    TILES = M.TILES,
    MARKS_ADDRESS = mem.marks,
    PLAYER_ADDRESS = readAddress(player + M.PLAYER_OPERAND),
    BASE_HEIGHT_ADDRESS = h.baseHeight,
    LIVE_HEIGHT_ADDRESS = h.liveHeight,
    RAISED = M.RAISED,
    UNIT_TYPE = h.unitField(h.UNIT_TYPE),
    UNIT_LOGICAL = h.unitField(h.UNIT_LOGICAL_STATE),
    UNIT_UID = h.unitField(h.UNIT_UID),
    TUNNELER_TYPE = h.UNIT_TYPE_TUNNELER,
    ALIVE = h.UNIT_LOGICAL_ALIVE,
  })
  draw.TEST_ADDRESS = test

  local values = {}
  for k, v in pairs(draw) do values[k] = v end
  values.CENTER_ADDRESS = h.callTarget(ground + M.GROUND.hook)
  values.RESUME_ADDRESS = ground + M.GROUND.resume
  local groundCode = core.allocateAssembly(M.ground, values)

  values = {}
  for k, v in pairs(draw) do values[k] = v end
  values.DRAW_ADDRESS = tall + M.TALL.draw
  values.SKIP_ADDRESS = tall + M.TALL.draw + core.readByte(tall + M.TALL.skipOperand)
  local tallCode = core.allocateAssembly(M.tall, values)

  local digCode = core.allocateAssembly(M.dig, {
    ON_ADDRESS = h.onAddress,
    CURRENT_UNIT_ADDRESS = h.currentUnit,
    UNITS = M.UNITS,
    TILES = M.TILES,
    MAP_ROWS = 400,
    MARKS_ADDRESS = mem.marks,
    STAMPS_ADDRESS = mem.stamps,
    GENERATION_ADDRESS = mem.generation,
    UNIT_UID = h.unitField(h.UNIT_UID),
    UNIT_OWNER = h.unitField(h.UNIT_OWNER),
    UNIT_TILE = h.unitField(h.UNIT_TILE),
    UNIT_PREVIOUS_TILE = h.unitField(h.UNIT_PREVIOUS_TILE),
    UNIT_LADDER_Y = h.unitField(h.UNIT_LADDER_Y),
    UNIT_PATH_INDEX = h.unitField(h.UNIT_PATH_INDEX),
    UNIT_PATH_LENGTH = h.unitField(h.UNIT_PATH_LENGTH),
    UNIT_PATH_PLAN = h.unitField(h.UNIT_PATH_PLAN),
    DIRECTIONS_ADDRESS = h.directions,
    Y_DELTAS_ADDRESS = h.yDeltas,
    RETURN_ADDRESS = h.tunneler + M.DIG_HOOK + M.DIG_HOOK_SIZE,
  })

  h.remember(ground + M.GROUND.hook, 5)
  h.writeJump(ground + M.GROUND.hook, groundCode, 5)
  h.remember(tall + M.TALL.hook, M.TALL.hookSize)
  h.writeJump(tall + M.TALL.hook, tallCode, M.TALL.hookSize)
  h.remember(h.tunneler + M.DIG_HOOK, M.DIG_HOOK_SIZE)
  h.writeJump(h.tunneler + M.DIG_HOOK, digCode, M.DIG_HOOK_SIZE)
  return true
end

return M
