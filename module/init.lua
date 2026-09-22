--[[
  Improved Tunnelers

  Four separate changes to the tunneler, each switchable on its own:

  1. A tunnel that brings a wall down denies the ground around the hole to builders for a
     while, the same way an enemy unit standing there would. Nobody - the player, the AI -
     can drop a wall, a tower or anything else back into the gap until the dust settles.

  2. A tunnel whose target is already gone when it arrives does not collapse into bare
     earth any more. It looks for the next wall within reach and keeps digging.

  3. Tunnelers get the attack-here button every other soldier has, in the slot it sits in
     for them, and the dig tunnel button moves one slot along.

  4. Tunnelers obey the defensive and aggressive stances.

  How each of them works is written above the assembly it uses, in templates.lua. What
  follows here is where the module finds the game code it needs and what it does to it.

  Everything is located by pattern scan, so the module runs on both shipped executables
  (Stronghold Crusader.exe and Stronghold_Crusader_Extreme.exe) without a table of
  version-specific addresses: the patterns were checked against both, and every address
  that differs between them - globals, tables, the tunneler's own fields - is read out of
  the instruction that uses it rather than written down here.

  Each feature is independent: if the game code one of them needs cannot be found, that
  feature logs a warning and stays off while the rest carry on.
]]

local templates = require("templates")

---------------------------------------------------------------------------------------
-- What the game's code looks like where this module touches it
---------------------------------------------------------------------------------------

-- UpdateTunneler: the state machine for one tunneler, one tick. The pattern is its
-- prologue up to the two player counters it bumps, which is unique in both executables.
local AOB_UPDATE_TUNNELER =
  "51 8B 0D ? ? ? ? 8B C1 69 C0 90 04 00 00 53 55 0F BF A8 ? ? ? ? 56 57 8B FD 69 FF F4 "
  .. "39 00 00 BA 01 00 00 00 01 97 ? ? ? ? 01 97 ? ? ? ? 33 DB"

-- UnitsState::findTunnelTarget. Only used to read three things out of it: the
-- PathFindingState object, the tunnel target search and where that search leaves its
-- answer.

-- PathFindingState::isEnemyTooCloseUnk(player, x, y, range): "is one of this player's
-- enemies within range tiles of here". Every build denial check in the game, the
-- player's and the AI's, ends up here.
local AOB_ENEMY_TOO_CLOSE = "8B 54 24 08 ? ? ? ? 00 00 56 77 1E"

-- PathFindingState::algTunnelerFindTarget: the search a tunnel is aimed by.
local SEARCH_BUILDING_TEST = 0x23E            -- add edx, -0x4A; cmp edx, 2
local SEARCH_BUILDING_TEST_SIZE = 6
local SEARCH_ALLOW = 0x246                    -- ... and where it goes when the tile is fine
local SEARCH_SKIP = 0x2C4                     -- ... or when the neighbour is not usable
local SEARCH_ACCEPT = 0x1AE                   -- imul eax, eax, 0x32C, on the tile it reached
local SEARCH_ACCEPT_SIZE = 6
local SEARCH_ACCEPT_RETURN = 0x1B4            -- ... the game's own owner and team test
local SEARCH_SPREAD = 0x1CB                   -- ... or spreading past this tile instead
local SEARCH_STRIDE = 0x32C
local SEARCH_TYPE_OPERAND = 0x23A             -- movsx edx, word [edx + buildings + type]
local SEARCH_GUARDS = {
  [SEARCH_BUILDING_TEST] = { 0x83, 0xC2, 0xB6, 0x83, 0xFA, 0x02 },
  [SEARCH_ACCEPT] = { 0x69, 0xC0, 0x2C, 0x03, 0x00, 0x00 },
  [SEARCH_ACCEPT_RETURN] = { 0x0F, 0xBF, 0x80 },
  [SEARCH_SPREAD] = { 0x0F, 0xBF, 0x04, 0x6D },
  [SEARCH_TYPE_OPERAND - 3] = { 0x0F, 0xBF, 0x92 },
}

-- Two reads of the team each player is on, next to each other: the game's own "are these
-- two players enemies" test.
local AOB_PLAYER_TEAMS = "8B 0C 85 ? ? ? ? 8B 44 24 30 3B 0C 85 ? ? ? ?"
local OFFSET_PLAYER_TEAMS = 3

-- The render function shared by the unit command buttons, and the two click handlers
-- behind them.
local AOB_RENDER_UNIT_BUTTONS = "8B 44 24 04 50 B9 ? ? ? ? E8 ? ? ? ? 85 C0 75 0B C7 05 ? ? ? ? ? 00 00 00"
local AOB_UNIT_BUTTON_CLICK = "57 33 FF 39 3D ? ? ? ? ? ? ? ? ? ? 39 3D ? ? ? ? ? ? ? ? ? ? A1 ? ? ? ?"
local AOB_TOOLBAR_CLICK = "53 33 DB 39 1D ? ? ? ? 0F 85 ? ? ? ? 39 1D ? ? ? ? 0F 85 ? ? ? ? A1 ? ? ? ?"

-- updateUnits, where it decides whether a unit is due to look around for enemies this
-- tick. The game tick counter is the third operand there.
local AOB_TICK_COUNTER = "8B 87 50 0A 00 00 8B 8F 98 09 00 00"
local OFFSET_TICK_COUNTER = 14

-- Offsets inside UpdateTunneler. The function is byte for byte the same in both
-- executables - only the addresses in its operands differ - so these hold for both.
local TUNNELER_CURRENT_UNIT_OPERAND = 0x03    -- mov ecx, [current unit]
local TUNNELER_OWNER_OPERAND = 0x14           -- movsx ebp, word [eax + units + owner]
local TUNNELER_TILE_FLAGS_OPERAND = 0xC0E     -- mov edi, [edx*4 + tile flags]
local TUNNELER_ARRIVED_HOOK = 0x7E6           -- tunnel has reached its target
local TUNNELER_ARRIVED_HOOK_SIZE = 5
local TUNNELER_COLLAPSE_DONE_HOOK = 0x954     -- the collapse has taken the building down
local TUNNELER_COLLAPSE_DONE_HOOK_SIZE = 5
local TUNNELER_FIND_TARGET_CALL = 0x66E       -- call findTunnelTarget
local TUNNELER_BUILDING_OPERAND = 0x4D3       -- movsx ecx, word [eax + buildings + y]
local TUNNELER_BUILDING_STRIDE = 0x4CA        -- imul eax, eax, 0x32C
local TUNNELER_COLLAPSE_HOOK = 0x8DD          -- the collapse branch (checked, not patched)
local TUNNELER_BUILDING_TILE_OPERAND = 0x8E7  -- movzx ecx, word [eax*2 + building ids]
local TUNNELER_UNITS_STATE_OPERAND = 0x922    -- mov ecx, UnitsState
local TUNNELER_TUNNEL_DAMAGE_CALL = 0x926     -- call applyTunnelDamageAlongPathPlan
local TUNNELER_SET_DESTINATION_CALL = 0x6CE   -- call setDestinationForUnit
local TUNNELER_ALG_TARGET_Y_OPERAND = 0x6B5
local TUNNELER_ALG_TARGET_X_OPERAND = 0x6BB
local TUNNELER_TAIL = 0x1197                  -- pop edi/esi/ebp/ebx/ecx; ret
local TUNNELER_GATE_TOWER_OPERAND = 0xC50     -- mov ecx, [ecx*4 + is-gate-or-tower]

-- ... and the bytes expected at each of them, so a site another module has already
-- rewritten is noticed instead of patched blindly. A few of these are not patched or read
-- at all any more (the state 9 block) and are only here to confirm this really is the
-- tunneler's update function before anything is written to it.
local TUNNELER_GUARDS = {
  [0x00] = { 0x51, 0x8B, 0x0D },
  [TUNNELER_ARRIVED_HOOK] = { 0xA1 },
  [TUNNELER_COLLAPSE_HOOK] = { 0x8B, 0x86 },
  [TUNNELER_BUILDING_TILE_OPERAND - 4] = { 0x0F, 0xB7, 0x0C, 0x45 },
  [TUNNELER_OWNER_OPERAND - 3] = { 0x0F, 0xBF, 0xA8 },
  [TUNNELER_TILE_FLAGS_OPERAND - 3] = { 0x8B, 0x3C, 0x95 },
  [TUNNELER_UNITS_STATE_OPERAND - 1] = { 0xB9 },
  [TUNNELER_TUNNEL_DAMAGE_CALL] = { 0xE8 },
  [TUNNELER_SET_DESTINATION_CALL] = { 0xE8 },
  [TUNNELER_ALG_TARGET_Y_OPERAND - 2] = { 0x8B, 0x0D },
  [TUNNELER_ALG_TARGET_X_OPERAND - 2] = { 0x8B, 0x15 },
  [TUNNELER_COLLAPSE_DONE_HOOK] = { 0xA1 },
  [TUNNELER_FIND_TARGET_CALL] = { 0xE8 },
  [TUNNELER_GATE_TOWER_OPERAND - 3] = { 0x8B, 0x0C, 0x8D },
  [TUNNELER_BUILDING_OPERAND - 3] = { 0x0F, 0xBF, 0x88 },
  [TUNNELER_BUILDING_STRIDE] = { 0x69, 0xC0, 0x2C, 0x03, 0x00, 0x00 },
  [TUNNELER_TAIL] = { 0x5F, 0x5E, 0x5D, 0x5B, 0x59, 0xC3 },
}

-- Offsets inside findTunnelTarget. Nothing is written there; it is read for the three
-- addresses the game's own target search works through - the path finding state it is
-- called on, the result it sets, and the search itself.
local FIND_PATH_STATE_OPERAND = 0xB5
local FIND_SEARCH_CALL = 0xB9
local FIND_RESULT_OPERAND = 0xC0
local FIND_GUARDS = {
  [FIND_PATH_STATE_OPERAND - 1] = { 0xB9 },
  [FIND_SEARCH_CALL] = { 0xE8 },
  [FIND_RESULT_OPERAND - 2] = { 0x83, 0x3D },
}

-- Where the placement handler puts its refusal on screen: push 0x1770 (how long to show
-- it), the entry number in EAX, and text group 0x4D. Identical in both executables.
local AOB_PLACEMENT_MESSAGE =
  "3B C5 74 2C 68 70 17 00 00 6A 64 55 50 6A 4D 53 B9 ? ? ? ? E8 ? ? ? ? A1 ? ? ? ?"
local MESSAGE_HOOK = 0x04
local MESSAGE_HOOK_SIZE = 5
local MESSAGE_GUARDS = {
  [MESSAGE_HOOK] = { 0x68, 0x70, 0x17, 0x00, 0x00 },
  [MESSAGE_HOOK + 8] = { 0x50, 0x6A, 0x4D },
}

-- The text group the placement messages live in, and the entry this module writes its own
-- line into - well past anything the game itself asks for in that group. Writing it needs
-- the textResourceModifier module, which is what lets anything change the game's strings;
-- without it the denial simply keeps the game's own "enemy units are too close" refusal.
local MESSAGE_GROUP = 0x4D
local MESSAGE_ENTRY = 250
local MESSAGE_TEXT = "The ground is too unstable to build here right now"

-- Offsets inside isEnemyTooCloseUnk. The hook sits after the coordinates have been
-- checked, so the zone test never runs on coordinates the game would have thrown out.
local ENEMY_HOOK = 0x31
local ENEMY_HOOK_SIZE = 5
local ENEMY_GUARDS = {
  [ENEMY_HOOK] = { 0x8B, 0x44, 0x24, 0x14, 0x53 },
}

-- Offsets inside the unit command button render function.
local RENDER_INACTIVE_OPERAND = 0x2E          -- mov [button inactive], 1
local RENDER_GAME_MODE_OPERAND = 0x7B         -- cmp [GameMode2], esi
local RENDER_BUILD_SLOT_HOOK = 0x8F           -- cmp [engineer selected], edi
local RENDER_BUILD_SLOT_HOOK_SIZE = 6
local RENDER_ENGINEER_OPERAND = 0x91
local RENDER_UNITS_STATE_OPERAND = 0x9C
local RENDER_BUTTON_CALL = 0xD3
local RENDER_RETURN = 0xDE                    -- pop edi; pop esi; ret
local RENDER_TUNNELER_BRANCH = 0x249          -- je past the tunneler branch
local RENDER_TUNNELERS_ONLY_CALL = 0x242
local RENDER_PICTURE_OPERAND = 0x24D
local RENDER_HELP_TEXT_OPERAND = 0x257
local RENDER_GUARDS = {
  [RENDER_INACTIVE_OPERAND - 2] = { 0x89, 0x3D },
  [RENDER_GAME_MODE_OPERAND - 2] = { 0x39, 0x35 },
  [RENDER_BUILD_SLOT_HOOK] = { 0x39, 0x3D },
  [RENDER_UNITS_STATE_OPERAND - 1] = { 0xB9 },
  [RENDER_BUTTON_CALL] = { 0xE8 },
  [RENDER_RETURN] = { 0x5F, 0x5E, 0xC3 },
  [RENDER_TUNNELER_BRANCH] = { 0x74, 0x22 },
  [RENDER_TUNNELERS_ONLY_CALL] = { 0xE8 },
  [RENDER_PICTURE_OPERAND - 2] = { 0xC7, 0x05 },
  [RENDER_HELP_TEXT_OPERAND - 2] = { 0xC7, 0x05 },
}

-- Offsets inside the two click handlers.
local CLICK_TUNNELER_BRANCH = 0x127           -- je past the tunneler branch
local CLICK_GUARD = { 0x74, 0x0F }
local TOOLBAR_HOOK_SIZE = 9                   -- push ebx; xor ebx, ebx; cmp [sync], ebx
local TOOLBAR_SYNC_OPERAND = 0x05
local TOOLBAR_GUARD = { 0x53, 0x33, 0xDB, 0x39, 0x1D }

---------------------------------------------------------------------------------------
-- Game constants
---------------------------------------------------------------------------------------

local UNIT_SIZE = 0x490

-- Unit fields, as offsets from the start of a unit.
local UNIT_OWNER = 0x96
local UNIT_X = 0xC4
local UNIT_Y = 0xC6
local UNIT_TILE = 0xD4
local UNIT_UID = 0x98
local UNIT_STATE = 0x2C0
local UNIT_LOOKING_AROUND = 0x3FC             -- the flag soldiers set when free to react
local UNIT_TYPE = 0x8E
local UNIT_LOGICAL_STATE = 0x8C               -- 2 = alive and in the world
local UNIT_DYING = 0x2A0
local UNIT_DEST_X = 0xC8                      -- where a tunnel is being dug to
local UNIT_DEST_Y = 0xCA
local UNIT_SIEGE_TARGET = 0x432               -- the player this tunneler was sent against

-- What the scan below is looking for: a living tunneler of the same player, digging.
local UNIT_TYPE_TUNNELER = 5
local UNIT_LOGICAL_ALIVE = 2
local UNIT_STATE_DIGGING = 3

-- Building types are well under this; the game's gate-or-tower table is zero everywhere
-- above the highest real type, so the limit is only there to keep the read in range.
local BUILDING_TYPE_LIMIT = 127

-- How far a re-aimed tunnel may look for its next target, in tiles. The game's own first
-- search uses 20, then 40, then 80; this is only what a re-aim uses.
local DEFAULT_SEARCH_RANGE = 80

-- How close two collapses have to be to count as the same breach, so the second one adds
-- its time to the first zone instead of taking a second one; and how close a tunnel's
-- destination has to be to a collapse for that tunnel to count as aimed at the same spot.
local DENIAL_STACK_RADIUS = 2
local RETARGET_SCAN_RADIUS = 1

-- The map's per-tile flag word: bit 0x100 is "a wall stands here".
local TILE_WALL_FLAG = 0x100

-- Picture and help text the vanilla dig tunnel button uses, taken from the branch this
-- module moves out of the attack-here slot.
local TUNNEL_PICTURE = 0xDA
local TUNNEL_HELP_TEXT = 0xC9

-- Menu command ids: what the engineer's build button sends, and what the dig tunnel
-- button sends.
local ENGINEER_BUILD_COMMAND = 291
local TUNNEL_COMMAND = 0x42

-- The game's logic runs at the game speed setting in ticks per second, and that setting
-- is 40 by default. Durations are given in seconds and turned into ticks with that, so a
-- denial lasts the same number of game ticks whatever speed the game is running at, which
-- is what keeps it identical on every machine in a multiplayer game.
local TICKS_PER_SECOND = 40

-- Denial zones: plenty for any siege, and small enough that walking the list costs
-- nothing. Each is 16 bytes: x, y, owner, expiry tick.
local ZONE_COUNT = 32
local ZONE_SIZE = 16

-- Re-aim records, a small ring of {unit uid, re-aims used}. Only a handful of tunnels are
-- ever digging at once; a uid pushed out of the ring only means that tunneler starts its
-- budget over.
local RECORD_COUNT = 32
local RECORD_SIZE = 8

-- Layout of the module's own control block.
local CONTROL_DENIAL_ENABLED = 0x00
local CONTROL_DENIAL_DURATION = 0x04
local CONTROL_RETARGET_ENABLED = 0x08
local CONTROL_RETARGET_RANGE = 0x0C
local CONTROL_RETARGET_MAX = 0x10
local CONTROL_UI_ENABLED = 0x14
local CONTROL_STANCE_ENABLED = 0x18
local CONTROL_COLLAPSE_BEHIND = 0x1C
local CONTROL_TARGETS_ENABLED = 0x20
local CONTROL_DIAGNOSTICS = 0x24
local CONTROL_LAST_TICK = 0x28                -- the tick the zones were last looked at
local CONTROL_LAST_REPORT_TICK = 0x2C         -- the build check reports at most once a second
local CONTROL_SCRATCH = 0x30
local CONTROL_RING_CURSOR = 0x34
local CONTROL_REAIM_UNIT = 0x38               -- which tunneler the re-aim is working on
local CONTROL_REAIM_ARRIVED = 0x3C            -- ... and whether it is standing at its target
local CONTROL_REAIM_RECORD = 0x40
local CONTROL_REAIM_COUNT = 0x44              -- how many a collapse sent somewhere new
local CONTROL_REPORT = 0x48                   -- ten dwords the hooks fill in before logging
local CONTROL_MINE = 0x70                     -- the last refusal was this module's own
local CONTROL_MINE_TICK = 0x74                -- ... on this tick
local CONTROL_ZONES = 0x78
local CONTROL_RECORDS = CONTROL_ZONES + ZONE_COUNT * ZONE_SIZE
local CONTROL_SIZE = CONTROL_RECORDS + RECORD_COUNT * RECORD_SIZE

---------------------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------------------
-- The GUI hands enable() only what it has saved, never the defaults in options.yml, so a
-- module nobody has opened in the GUI gets an empty table. These are the real defaults.
local DEFAULTS = {
  denial = { enabled = true, seconds = 120, message = true },
  retarget = { enabled = true, range = DEFAULT_SEARCH_RANGE, max = 10, collapse_behind = true },
  targets = { towers_and_gates = true },
  diagnostics = { enabled = false },
  ui = { enabled = true },
  stances = { enabled = true },
}

-- What each hook writes into the report block, and what the decision code at +0x1C means.
-- Nothing here runs unless diagnostics are switched on, and then only when a tunnel
-- arrives, a tunnel collapses, or somebody tries to build within twenty tiles of a zone.
local REPORT_WORDS = {
  [1] = "tunnel arrived on a wall, collapsing as usual",
  [2] = "tunnel arrived on a building, collapsing as usual",
  [6] = "tunnel arrived on empty ground but has used up its re-aims, collapsing",
  [7] = "tunnel arrived on empty ground and is digging on towards a new target",
  [8] = "a collapse sent the player's other tunnels at new targets",
  [9] = "tunnel arrived on empty ground with nothing in range, collapsing",
  [10] = "tunnel collapsed on empty ground, no denial laid",
  [11] = "tunnel collapsed but every denial slot is in use",
  [12] = "tunnel collapsed on something, denial laid",
  [13] = "tunnel collapsed where a denial already stood, its time added on",
  [20] = "building attempt near a denial, not refused",
  [21] = "building attempt inside a denial, refused",
}

---------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------

local readByte = core.readByte
local readInteger = core.readInteger
local writeInteger = core.writeInteger

---Scan for a pattern this module can live without. Modules load in the order the config
---lists them and rewrite game code as they go, so a pattern that has been overwritten has
---to switch its feature off, not take the game down at launch.
---@param pattern string
---@param purpose string
---@return number|nil
local function scanOptional(pattern, purpose)
  local found, address = pcall(core.AOBScan, pattern)
  if not found or address == nil then
    log(WARNING, "improved-tunnelers: could not find " .. purpose
      .. "; the part of the module that needs it is off. Another module has probably "
      .. "patched the same code.")
    return nil
  end
  return address
end

---True when the bytes at base + offset are the ones this module expects.
---@param base number
---@param offsets table<number, table> offset -> expected bytes
---@param purpose string
---@return boolean
local function guardsHold(base, offsets, purpose)
  for offset, expected in pairs(offsets) do
    for index, byte in ipairs(expected) do
      local found = readByte(base + offset + index - 1) & 0xFF
      if found ~= byte then
        log(WARNING, string.format(
          "improved-tunnelers: %s does not look the way it should at +0x%X (found 0x%02X, "
          .. "expected 0x%02X); that part of the module is off.",
          purpose, offset + index - 1, found, byte))
        return false
      end
    end
  end
  return true
end

---Read a pointer-sized value as the unsigned address it is.
---@param address number
---@return number
local function readAddress(address)
  return readInteger(address) & 0xFFFFFFFF
end

---The target of the five byte call at this address.
---@param address number
---@return number
local function callTarget(address)
  local relative = readInteger(address + 1)
  return (address + 5 + relative) & 0xFFFFFFFF
end

---Write a five byte jump over the instruction(s) at address, padding the rest with the
---one byte NOP so a disassembler - and anything that reads the code later - sees whole
---instructions.
---@param address number
---@param destination number
---@param size number how many bytes the jump replaces, at least 5
local function writeJump(address, destination, size)
  local relative = (destination - (address + 5)) & 0xFFFFFFFF
  local bytes = { 0xE9, relative & 0xFF, (relative >> 8) & 0xFF, (relative >> 16) & 0xFF,
    (relative >> 24) & 0xFF }
  for _ = 6, size do
    bytes[#bytes + 1] = 0x90
  end
  core.writeCodeBytes(address, bytes)
end

---A whole number from a config value, which YAML may hand over as a float.
---@param value any
---@param fallback number
---@return number
local function toInteger(value, fallback)
  if type(value) ~= "number" then
    return fallback
  end
  return math.tointeger(math.floor(value)) or fallback
end

---A setting out of the config, falling back to this module's own default.
---@param config table
---@param group string
---@param name string
---@return any
local function setting(config, group, name)
  local section = config and config[group]
  local value = section and section[name]
  if value == nil then
    return DEFAULTS[group][name]
  end
  return value
end

return {

  enable = function(self, config)
    config = config or {}

    local denialOn = setting(config, "denial", "enabled") and true or false
    local denialSeconds = toInteger(setting(config, "denial", "seconds"),
      DEFAULTS.denial.seconds)
    local messageOn = setting(config, "denial", "message") and true or false
    local retargetOn = setting(config, "retarget", "enabled") and true or false
    local retargetRange = toInteger(setting(config, "retarget", "range"),
      DEFAULTS.retarget.range)
    local retargetMax = toInteger(setting(config, "retarget", "max"), DEFAULTS.retarget.max)
    local collapseBehind = setting(config, "retarget", "collapse_behind") and true or false
    local targetsOn = setting(config, "targets", "towers_and_gates") and true or false
    local diagnosticsOn = setting(config, "diagnostics", "enabled") and true or false
    local uiOn = setting(config, "ui", "enabled") and true or false
    local stancesOn = setting(config, "stances", "enabled") and true or false

    ---------------------------------------------------------------------------------
    -- Find the game code
    ---------------------------------------------------------------------------------

    local tunneler = scanOptional(AOB_UPDATE_TUNNELER, "the tunneler's update function")
    if tunneler ~= nil and not guardsHold(tunneler, TUNNELER_GUARDS,
        "the tunneler's update function") then
      tunneler = nil
    end

    local currentUnit, unitBase, tileFlags, buildingTiles, unitsState
    if tunneler ~= nil then
      currentUnit = readAddress(tunneler + TUNNELER_CURRENT_UNIT_OPERAND)
      unitBase = (readAddress(tunneler + TUNNELER_OWNER_OPERAND) - UNIT_OWNER) & 0xFFFFFFFF
      tileFlags = readAddress(tunneler + TUNNELER_TILE_FLAGS_OPERAND)
      buildingTiles = readAddress(tunneler + TUNNELER_BUILDING_TILE_OPERAND)
      unitsState = readAddress(tunneler + TUNNELER_UNITS_STATE_OPERAND)
    end

    local ticks
    local tickSite = scanOptional(AOB_TICK_COUNTER, "the game tick counter")
    if tickSite ~= nil then
      ticks = readAddress(tickSite + OFFSET_TICK_COUNTER)
    end

    ---------------------------------------------------------------------------------
    -- The module's own memory
    ---------------------------------------------------------------------------------

    local control = core.allocate(CONTROL_SIZE, true)
    local zones = control + CONTROL_ZONES
    local records = control + CONTROL_RECORDS

    writeInteger(control + CONTROL_DENIAL_ENABLED, denialOn and 1 or 0)
    writeInteger(control + CONTROL_DENIAL_DURATION, denialSeconds * TICKS_PER_SECOND)
    writeInteger(control + CONTROL_RETARGET_ENABLED, retargetOn and 1 or 0)
    writeInteger(control + CONTROL_RETARGET_RANGE, retargetRange)
    writeInteger(control + CONTROL_RETARGET_MAX, retargetMax)
    writeInteger(control + CONTROL_UI_ENABLED, uiOn and 1 or 0)
    writeInteger(control + CONTROL_STANCE_ENABLED, stancesOn and 1 or 0)
    writeInteger(control + CONTROL_COLLAPSE_BEHIND, collapseBehind and 1 or 0)
    writeInteger(control + CONTROL_TARGETS_ENABLED, targetsOn and 1 or 0)
    writeInteger(control + CONTROL_DIAGNOSTICS, diagnosticsOn and 1 or 0)
    writeInteger(control + CONTROL_RING_CURSOR, records)

    self.control = control
    self.patched = {}

    -- Where the hooks report to. They fill the report block and call this pad; the pad is
    -- five NOPs and a ret with a lua detour on it, so nothing runs in the game's own code
    -- path except the call itself, and only when diagnostics are on. Tunnels arriving and
    -- collapsing are rare events, but the build check is not: every tile of every wall the
    -- AI lays down goes through it, and an unthrottled version of this wrote seventy
    -- thousand lines in seven minutes of play. So the build check reports at most one line
    -- a second; the tunnel hooks, which speak only when a tunnel arrives, are left alone.
    local report = control + CONTROL_REPORT
    local reportPad = core.allocateCode({ 0x90, 0x90, 0x90, 0x90, 0x90, 0xC3 })
    core.detourCode(function(registers)
      local code = readInteger(report + 0x1C)
      log(INFO, string.format(
        "improved-tunnelers: %s | a=%d tile=%d flags=0x%X b=%d c=%d d=%d e=%d f=%d g=%d",
        REPORT_WORDS[code] or ("report " .. tostring(code)),
        readInteger(report), readInteger(report + 4), readInteger(report + 8) & 0xFFFFFFFF,
        readInteger(report + 12), readInteger(report + 16), readInteger(report + 20),
        readInteger(report + 24), readInteger(report + 32), readInteger(report + 36)))
      return registers
    end, reportPad, 5)

    ---Remember a stretch of code before overwriting it, so disable() can put it back.
    ---@param address number
    ---@param size number
    local function remember(address, size)
      self.patched[#self.patched + 1] = { address = address, bytes = core.readBytes(address, size) }
    end

    ---------------------------------------------------------------------------------
    -- 1 and 2. What happens when a tunnel arrives under its target
    ---------------------------------------------------------------------------------
    -- Both features hang off the same moment - the tile is still exactly as the tunnel
    -- found it there - so they share one hook: something standing on it means the collapse
    -- will take it and a denial is laid, nothing standing on it means the target has gone
    -- and the tunneler is sent back to the game's own search.

    local denialReady, retargetReady, messageReady = false, false, false
    local teamSite = scanOptional(AOB_PLAYER_TEAMS, "the player team table")
    local enemySite = scanOptional(AOB_ENEMY_TOO_CLOSE, "the build denial check")

    -- The game's own target search, and the three addresses it works through, all read
    -- out of the function that drives it.
    local finder, search = nil, nil
    if tunneler ~= nil then
      finder = callTarget(tunneler + TUNNELER_FIND_TARGET_CALL)
      if guardsHold(finder, FIND_GUARDS, "the tunnel target search") then
        search = callTarget(finder + FIND_SEARCH_CALL)
        if not guardsHold(search, SEARCH_GUARDS, "the tunnel target search") then
          search = nil
        end
      end
    end

    if tunneler ~= nil and ticks ~= nil and search ~= nil then
      -- The one routine that changes a tunnel's aim. Both hooks below call it.
      local reaim = core.allocateAssembly(templates.reaim, {
        UNIT_ADDRESS = control + CONTROL_REAIM_UNIT,
        ARRIVED_ADDRESS = control + CONTROL_REAIM_ARRIVED,
        RECORD_ADDRESS = control + CONTROL_REAIM_RECORD,
        RECORDS_ADDRESS = records,
        RECORDS_END_ADDRESS = records + RECORD_COUNT * RECORD_SIZE,
        RING_CURSOR_ADDRESS = control + CONTROL_RING_CURSOR,
        MAX_RETARGETS_ADDRESS = control + CONTROL_RETARGET_MAX,
        RANGE_ADDRESS = control + CONTROL_RETARGET_RANGE,
        COLLAPSE_BEHIND_ADDRESS = control + CONTROL_COLLAPSE_BEHIND,
        UNIT_UID = (unitBase + UNIT_UID) & 0xFFFFFFFF,
        UNIT_X = (unitBase + UNIT_X) & 0xFFFFFFFF,
        UNIT_Y = (unitBase + UNIT_Y) & 0xFFFFFFFF,
        UNIT_OWNER = (unitBase + UNIT_OWNER) & 0xFFFFFFFF,
        UNIT_SIEGE_TARGET = (unitBase + UNIT_SIEGE_TARGET) & 0xFFFFFFFF,
        PATH_STATE_ADDRESS = readAddress(finder + FIND_PATH_STATE_OPERAND),
        ALG_RESULT_ADDRESS = readAddress(finder + FIND_RESULT_OPERAND),
        ALG_TARGET_X_ADDRESS = readAddress(tunneler + TUNNELER_ALG_TARGET_X_OPERAND),
        ALG_TARGET_Y_ADDRESS = readAddress(tunneler + TUNNELER_ALG_TARGET_Y_OPERAND),
        SEARCH_ADDRESS = search,
        SET_DESTINATION_ADDRESS = callTarget(tunneler + TUNNELER_SET_DESTINATION_CALL),
        APPLY_TUNNEL_DAMAGE_ADDRESS = callTarget(tunneler + TUNNELER_TUNNEL_DAMAGE_CALL),
        UNITS_STATE_ADDRESS = unitsState,
      })

      local arrival = core.allocateAssembly(templates.arrival, {
        DENIAL_ENABLED_ADDRESS = control + CONTROL_DENIAL_ENABLED,
        DURATION_ADDRESS = control + CONTROL_DENIAL_DURATION,
        RETARGET_ENABLED_ADDRESS = control + CONTROL_RETARGET_ENABLED,
        DIAGNOSTICS_ADDRESS = control + CONTROL_DIAGNOSTICS,
        REPORT_ADDRESS = report,
        REPORT_PAD_ADDRESS = reportPad,
        REAIM_ADDRESS = reaim,
        REAIM_UNIT_ADDRESS = control + CONTROL_REAIM_UNIT,
        REAIM_ARRIVED_ADDRESS = control + CONTROL_REAIM_ARRIVED,
        TICKS_ADDRESS = ticks,
        LAST_TICK_ADDRESS = control + CONTROL_LAST_TICK,
        ZONES_ADDRESS = zones,
        ZONES_END_ADDRESS = zones + ZONE_COUNT * ZONE_SIZE,
        STACK_RADIUS = DENIAL_STACK_RADIUS,
        STACK_SPAN = 2 * DENIAL_STACK_RADIUS,
        CURRENT_UNIT_ADDRESS = currentUnit,
        TILE_FLAGS_ADDRESS = tileFlags,
        BUILDING_TILE_ADDRESS = buildingTiles,
        UNIT_TILE = (unitBase + UNIT_TILE) & 0xFFFFFFFF,
        UNIT_X = (unitBase + UNIT_X) & 0xFFFFFFFF,
        UNIT_Y = (unitBase + UNIT_Y) & 0xFFFFFFFF,
        UNIT_OWNER = (unitBase + UNIT_OWNER) & 0xFFFFFFFF,
        TAIL_ADDRESS = tunneler + TUNNELER_TAIL,
        RETURN_ADDRESS = tunneler + TUNNELER_ARRIVED_HOOK + TUNNELER_ARRIVED_HOOK_SIZE,
      })
      remember(tunneler + TUNNELER_ARRIVED_HOOK, TUNNELER_ARRIVED_HOOK_SIZE)
      writeJump(tunneler + TUNNELER_ARRIVED_HOOK, arrival, TUNNELER_ARRIVED_HOOK_SIZE)
      retargetReady = true

      -- ... and the other trigger: the moment a collapse takes a building down, every
      -- other tunnel of that player aimed at the same spot is sent somewhere new.
      local scan = core.allocateAssembly(templates.collapse_scan, {
        RETARGET_ENABLED_ADDRESS = control + CONTROL_RETARGET_ENABLED,
        DIAGNOSTICS_ADDRESS = control + CONTROL_DIAGNOSTICS,
        REPORT_ADDRESS = report,
        REPORT_PAD_ADDRESS = reportPad,
        REAIM_ADDRESS = reaim,
        REAIM_UNIT_ADDRESS = control + CONTROL_REAIM_UNIT,
        REAIM_ARRIVED_ADDRESS = control + CONTROL_REAIM_ARRIVED,
        REAIM_COUNT_ADDRESS = control + CONTROL_REAIM_COUNT,
        CURRENT_UNIT_ADDRESS = currentUnit,
        UNIT_COUNT_ADDRESS = unitsState,
        UNIT_X = (unitBase + UNIT_X) & 0xFFFFFFFF,
        UNIT_Y = (unitBase + UNIT_Y) & 0xFFFFFFFF,
        UNIT_OWNER = (unitBase + UNIT_OWNER) & 0xFFFFFFFF,
        UNIT_STATE = (unitBase + UNIT_STATE) & 0xFFFFFFFF,
        UNIT_TYPE = (unitBase + UNIT_TYPE) & 0xFFFFFFFF,
        UNIT_LOGICAL_STATE = (unitBase + UNIT_LOGICAL_STATE) & 0xFFFFFFFF,
        UNIT_DYING = (unitBase + UNIT_DYING) & 0xFFFFFFFF,
        UNIT_DEST_X = (unitBase + UNIT_DEST_X) & 0xFFFFFFFF,
        UNIT_DEST_Y = (unitBase + UNIT_DEST_Y) & 0xFFFFFFFF,
        TUNNELER_TYPE = UNIT_TYPE_TUNNELER,
        LOGICAL_ALIVE = UNIT_LOGICAL_ALIVE,
        DIGGING_STATE = UNIT_STATE_DIGGING,
        SCAN_RADIUS = RETARGET_SCAN_RADIUS,
        SCAN_SPAN = 2 * RETARGET_SCAN_RADIUS,
        RETURN_ADDRESS = tunneler + TUNNELER_COLLAPSE_DONE_HOOK
          + TUNNELER_COLLAPSE_DONE_HOOK_SIZE,
      })
      remember(tunneler + TUNNELER_COLLAPSE_DONE_HOOK, TUNNELER_COLLAPSE_DONE_HOOK_SIZE)
      writeJump(tunneler + TUNNELER_COLLAPSE_DONE_HOOK, scan, TUNNELER_COLLAPSE_DONE_HOOK_SIZE)

      -- The denial test itself, in the one function every placement check goes through.
      if teamSite ~= nil and enemySite ~= nil
          and guardsHold(enemySite, ENEMY_GUARDS, "the build denial check") then
        local check = core.allocateAssembly(templates.denial_check, {
          TICKS_ADDRESS = ticks,
          LAST_TICK_ADDRESS = control + CONTROL_LAST_TICK,
          ENABLED_ADDRESS = control + CONTROL_DENIAL_ENABLED,
          SCRATCH_ADDRESS = control + CONTROL_SCRATCH,
          DIAGNOSTICS_ADDRESS = control + CONTROL_DIAGNOSTICS,
          REPORT_ADDRESS = report,
          REPORT_PAD_ADDRESS = reportPad,
          LAST_REPORT_TICK_ADDRESS = control + CONTROL_LAST_REPORT_TICK,
          MINE_ADDRESS = control + CONTROL_MINE,
          MINE_TICK_ADDRESS = control + CONTROL_MINE_TICK,
          REPORT_GAP = TICKS_PER_SECOND,
          ZONES_ADDRESS = zones,
          ZONES_END_ADDRESS = zones + ZONE_COUNT * ZONE_SIZE,
          TEAMS_ADDRESS = readAddress(teamSite + OFFSET_PLAYER_TEAMS),
          RETURN_ADDRESS = enemySite + ENEMY_HOOK + ENEMY_HOOK_SIZE,
        })
        remember(enemySite + ENEMY_HOOK, ENEMY_HOOK_SIZE)
        writeJump(enemySite + ENEMY_HOOK, check, ENEMY_HOOK_SIZE)
        denialReady = true
      end

      -- The refusal the player reads. The module's own line has to go into the game's text
      -- through textResourceModifier; if that module is not there, or says no, the message
      -- is left exactly as the game writes it.
      if denialReady and messageOn then
        local texts = modules ~= nil and modules.textResourceModifier or nil
        local wrote = false
        if texts ~= nil and texts.SetText ~= nil then
          wrote = pcall(function() texts:SetText(MESSAGE_GROUP, MESSAGE_ENTRY, MESSAGE_TEXT) end)
          if not wrote then
            log(WARNING, "improved-tunnelers: the game's text could not be changed, so a "
              .. "denial keeps the game's own refusal message.")
          end
        else
          log(INFO, "improved-tunnelers: no textResourceModifier, so a denial keeps the "
            .. "game's own refusal message.")
        end
        local messageSite = wrote and scanOptional(AOB_PLACEMENT_MESSAGE,
          "the placement refusal message") or nil
        if messageSite ~= nil and guardsHold(messageSite, MESSAGE_GUARDS,
            "the placement refusal message") then
          local message = core.allocateAssembly(templates.placement_message, {
            MINE_ADDRESS = control + CONTROL_MINE,
            MINE_TICK_ADDRESS = control + CONTROL_MINE_TICK,
            TICKS_ADDRESS = ticks,
            MESSAGE_ENTRY = MESSAGE_ENTRY,
            RETURN_ADDRESS = messageSite + MESSAGE_HOOK + MESSAGE_HOOK_SIZE,
          })
          remember(messageSite + MESSAGE_HOOK, MESSAGE_HOOK_SIZE)
          writeJump(messageSite + MESSAGE_HOOK, message, MESSAGE_HOOK_SIZE)
          messageReady = true
        end
      end
    end

    ---------------------------------------------------------------------------------
    -- 2b. Towers and gates as tunnel targets
    ---------------------------------------------------------------------------------

    local targetsReady = false
    if tunneler ~= nil then
      if search ~= nil then
        local targets = core.allocateAssembly(templates.tunnel_targets, {
          ENABLED_ADDRESS = control + CONTROL_TARGETS_ENABLED,
          GATE_OR_TOWER_ADDRESS = readAddress(tunneler + TUNNELER_GATE_TOWER_OPERAND),
          TYPE_LIMIT = BUILDING_TYPE_LIMIT,
          ALLOW_ADDRESS = search + SEARCH_ALLOW,
          SKIP_ADDRESS = search + SEARCH_SKIP,
        })
        remember(search + SEARCH_BUILDING_TEST, SEARCH_BUILDING_TEST_SIZE)
        writeJump(search + SEARCH_BUILDING_TEST, targets, SEARCH_BUILDING_TEST_SIZE)

        local accept = core.allocateAssembly(templates.tunnel_accept, {
          ENABLED_ADDRESS = control + CONTROL_TARGETS_ENABLED,
          GATE_OR_TOWER_ADDRESS = readAddress(tunneler + TUNNELER_GATE_TOWER_OPERAND),
          TYPE_LIMIT = BUILDING_TYPE_LIMIT,
          BUILDING_STRIDE = SEARCH_STRIDE,
          BUILDING_TYPE_ADDRESS = readAddress(search + SEARCH_TYPE_OPERAND),
          RETURN_ADDRESS = search + SEARCH_ACCEPT_RETURN,
          SPREAD_ADDRESS = search + SEARCH_SPREAD,
        })
        remember(search + SEARCH_ACCEPT, SEARCH_ACCEPT_SIZE)
        writeJump(search + SEARCH_ACCEPT, accept, SEARCH_ACCEPT_SIZE)
        targetsReady = true
      end
    end

    ---------------------------------------------------------------------------------
    -- 3. The attack-here button, and the dig tunnel button one slot along
    ---------------------------------------------------------------------------------

    local uiReady = false
    local render = scanOptional(AOB_RENDER_UNIT_BUTTONS, "the unit command buttons")
    local click = scanOptional(AOB_UNIT_BUTTON_CLICK, "the unit command button clicks")
    local toolbar = scanOptional(AOB_TOOLBAR_CLICK, "the toolbar button handler")
    if render ~= nil and click ~= nil and toolbar ~= nil
        and guardsHold(render, RENDER_GUARDS, "the unit command buttons")
        and guardsHold(click, { [CLICK_TUNNELER_BRANCH] = CLICK_GUARD },
          "the unit command button clicks")
        and guardsHold(toolbar, { [0] = TOOLBAR_GUARD }, "the toolbar button handler") then

      -- The attack-here slot: step over the branch that turns it into the dig tunnel
      -- button, so tunnelers fall through to the sword every other soldier gets. Two
      -- bytes, je -> jmp.
      remember(render + RENDER_TUNNELER_BRANCH, 2)
      core.writeCodeByte(render + RENDER_TUNNELER_BRANCH, 0xEB)

      -- ... and the same branch in the click handler, so the button does what it shows.
      remember(click + CLICK_TUNNELER_BRANCH, 2)
      core.writeCodeByte(click + CLICK_TUNNELER_BRANCH, 0xEB)

      -- The slot to the right of it draws the dig tunnel button now.
      local slot = core.allocateAssembly(templates.render_tunnel_button, {
        ENABLED_ADDRESS = control + CONTROL_UI_ENABLED,
        ENGINEER_SELECTED_ADDRESS = readAddress(render + RENDER_ENGINEER_OPERAND),
        UNITS_STATE_ADDRESS = readAddress(render + RENDER_UNITS_STATE_OPERAND),
        TUNNELERS_ONLY_ADDRESS = callTarget(render + RENDER_TUNNELERS_ONLY_CALL),
        GAME_MODE_ADDRESS = readAddress(render + RENDER_GAME_MODE_OPERAND),
        BUTTON_PICTURE_ADDRESS = readAddress(render + RENDER_PICTURE_OPERAND),
        HELP_TEXT_ADDRESS = readAddress(render + RENDER_HELP_TEXT_OPERAND),
        BUTTON_INACTIVE_ADDRESS = readAddress(render + RENDER_INACTIVE_OPERAND),
        RENDER_BUTTON_ADDRESS = callTarget(render + RENDER_BUTTON_CALL),
        TUNNEL_PICTURE = TUNNEL_PICTURE,
        TUNNEL_HELP_TEXT = TUNNEL_HELP_TEXT,
        RENDER_RETURN_ADDRESS = render + RENDER_RETURN,
        RETURN_ADDRESS = render + RENDER_BUILD_SLOT_HOOK + RENDER_BUILD_SLOT_HOOK_SIZE,
      })
      remember(render + RENDER_BUILD_SLOT_HOOK, RENDER_BUILD_SLOT_HOOK_SIZE)
      writeJump(render + RENDER_BUILD_SLOT_HOOK, slot, RENDER_BUILD_SLOT_HOOK_SIZE)

      -- ... and sends the tunnel command when it is clicked.
      local press = core.allocateAssembly(templates.tunnel_button_click, {
        ENABLED_ADDRESS = control + CONTROL_UI_ENABLED,
        UNITS_STATE_ADDRESS = readAddress(render + RENDER_UNITS_STATE_OPERAND),
        TUNNELERS_ONLY_ADDRESS = callTarget(render + RENDER_TUNNELERS_ONLY_CALL),
        ENGINEER_BUILD_COMMAND = ENGINEER_BUILD_COMMAND,
        TUNNEL_COMMAND = TUNNEL_COMMAND,
        SYNC_STATUS_ADDRESS = readAddress(toolbar + TOOLBAR_SYNC_OPERAND),
        RETURN_ADDRESS = toolbar + TOOLBAR_HOOK_SIZE,
      })
      remember(toolbar, TOOLBAR_HOOK_SIZE)
      writeJump(toolbar, press, TOOLBAR_HOOK_SIZE)
      uiReady = true
    end

    ---------------------------------------------------------------------------------
    -- 4. Stances
    ---------------------------------------------------------------------------------

    local stanceReady = false
    if tunneler ~= nil then
      local stance = core.allocateAssembly(templates.stance, {
        ENABLED_ADDRESS = control + CONTROL_STANCE_ENABLED,
        CURRENT_UNIT_ADDRESS = currentUnit,
        UNIT_STATE = (unitBase + UNIT_STATE) & 0xFFFFFFFF,
        UNIT_LOOKING_AROUND = (unitBase + UNIT_LOOKING_AROUND) & 0xFFFFFFFF,
        RETURN_ADDRESS = tunneler + 7,
      })
      remember(tunneler, 7)
      writeJump(tunneler, stance, 7)
      stanceReady = true
    end

    ---------------------------------------------------------------------------------

    log(INFO, string.format(
      "improved-tunnelers: build denial %s%s, digging on %s, targets %s, buttons %s, stances %s.",
      denialReady and (denialOn and string.format("on, %d s", denialSeconds) or "off")
        or "unavailable",
      (denialReady and denialOn and messageOn)
        and (messageReady and ", with its own refusal message" or ", with the game's message")
        or "",
      retargetReady and (retargetOn and string.format("on, %d times, search %d tiles",
        retargetMax, retargetRange) or "off") or "unavailable",
      targetsReady and (targetsOn and "walls, towers and gates" or "walls only") or "unavailable",
      uiReady and (uiOn and "on" or "off") or "unavailable",
      stanceReady and (stancesOn and "on" or "off") or "unavailable"))
    if diagnosticsOn then
      log(INFO, "improved-tunnelers: diagnostics are on; every tunnel arrival, every tunnel "
        .. "collapse and every building attempt near a denial writes a line to this log.")
    end
  end,

  ---Put the game's own bytes back and switch every hook that stays behind inert.
  disable = function(self, config)
    if self.control ~= nil then
      writeInteger(self.control + CONTROL_DENIAL_ENABLED, 0)
      writeInteger(self.control + CONTROL_RETARGET_ENABLED, 0)
      writeInteger(self.control + CONTROL_TARGETS_ENABLED, 0)
      writeInteger(self.control + CONTROL_UI_ENABLED, 0)
      writeInteger(self.control + CONTROL_STANCE_ENABLED, 0)
    end
    for _, patch in ipairs(self.patched or {}) do
      core.writeCodeBytes(patch.address, patch.bytes)
    end
    self.patched = {}
  end,

}
