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
-- The map is 400 across; tiles on its very edge are never touched.
local MAP_LIMIT = 398

local SEARCH_TAKE_IT = 0x16F                  -- the three stores that say "this is it"
local SEARCH_TAKE_IT_SIZE = 9
local SEARCH_TAKE_IT_DONE = 0x178             -- ... and the return that follows them
local SEARCH_RESULT_TILE = 0x34               -- where those three stores put it
local SEARCH_RESULT_Y = 0x30
local SEARCH_RESULT_X = 0x2C
local SEARCH_ACCEPT = 0x1AE                   -- imul eax, eax, 0x32C, on the tile it reached
local SEARCH_ACCEPT_SIZE = 6
local SEARCH_ACCEPT_RETURN = 0x1B4            -- ... the game's own owner and team test
local SEARCH_SPREAD = 0x1CB                   -- ... or spreading past this tile instead
local SEARCH_DISTANCE_OPERAND = 0x1CF         -- how far the search had to dig to reach a tile
local SEARCH_STRIDE = 0x32C
local SEARCH_TYPE_OPERAND = 0x23A             -- movsx edx, word [edx + buildings + type]
local SEARCH_GUARDS = {
  [SEARCH_BUILDING_TEST] = { 0x83, 0xC2, 0xB6, 0x83, 0xFA, 0x02 },
  [SEARCH_TAKE_IT] = { 0x89, 0x6E, 0x34, 0x89, 0x7E, 0x30, 0x89, 0x56, 0x2C },
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
local TUNNELER_LENGTH = 0x2000                -- as much of UpdateTunneler as this module
                                              -- ever reaches into, for checking an address
                                              -- read out of the game lands inside it
local TUNNELER_PATH_HOOK = 0x6D3              -- did the path to the new target lay?
local TUNNELER_PATH_HOOK_SIZE = 8
local TUNNELER_PATH_LAID = 0x6DB              -- ... it did
local TUNNELER_PATH_GIVE_UP = 0x92B           -- ... it did not, and the entrance is torn down
local TUNNELER_NO_TARGET_JUMP = 0x675         -- the six-byte je itself, two bytes past the
                                              -- test: where the game leaves off when its own
                                              -- search finds nothing, so the tunneler keeps
                                              -- its entrance and is asked again next tick
local TUNNELER_RESET_TILE_CALL = 0x916        -- call resetTileToDefaultState
local TUNNELER_COLLAPSE_HOOK = 0x8DD          -- the collapse takes down what it arrived under
local TUNNELER_COLLAPSE_HOOK_SIZE = 6
local TUNNELER_COLLAPSE_DONE = 0x91B          -- ... and carries on with the tunnel itself
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
  [TUNNELER_PATH_HOOK] = { 0x85, 0xC0, 0x0F, 0x84 },
  [TUNNELER_NO_TARGET_JUMP - 2] = { 0x85, 0xC0, 0x0F, 0x84 },
  [TUNNELER_COLLAPSE_HOOK] = { 0x8B, 0x86 },
  [TUNNELER_RESET_TILE_CALL] = { 0xE8 },
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

-- Offsets inside applyTunnelDamageAlongPathPlan, the walk the game does over a finished
-- tunnel: for each tile it either lowers the ground the dig raised or damages what stands
-- on it, and then tells the path layer the tile has changed.
local DAMAGE_WALK_LIVE_HEIGHT_OPERAND = 0x5B  -- cmp byte [esi + live height map], 0x10
local DAMAGE_WALK_BASE_HEIGHT_OPERAND = 0x64  -- ... and the height the map itself gives it
local DAMAGE_WALK_PATH_STATE_OPERAND = 0xA5   -- mov ecx, PathFindingState
local DAMAGE_WALK_DAMAGE_CALL = 0x9B          -- call processDamageToBuilding
local DAMAGE_WALK_DAMAGE_CALL_SIZE = 5
local DAMAGE_WALK_UPDATE_CALL = 0xA9          -- call updateWalkAndPathLayer
local DAMAGE_WALK_UPDATE_CALL_SIZE = 5
local DAMAGE_WALK_TILE_MAP_OPERAND = 0x97     -- mov ecx, TileMapState
local DAMAGE_WALK_X_DELTAS_OPERAND = 0xD7
local DAMAGE_WALK_Y_DELTAS_OPERAND = 0xE1
local DAMAGE_WALK_DIRECTIONS_OPERAND = 0xE8
local DAMAGE_WALK_GUARDS = {
  [DAMAGE_WALK_LIVE_HEIGHT_OPERAND - 2] = { 0x80, 0xBE },
  [DAMAGE_WALK_BASE_HEIGHT_OPERAND - 2] = { 0x80, 0xBE },
  [DAMAGE_WALK_PATH_STATE_OPERAND - 1] = { 0xB9 },
  [DAMAGE_WALK_DAMAGE_CALL] = { 0xE8 },
  [DAMAGE_WALK_UPDATE_CALL] = { 0xE8 },
  [DAMAGE_WALK_TILE_MAP_OPERAND - 1] = { 0xB9 },
  [DAMAGE_WALK_X_DELTAS_OPERAND - 3] = { 0x03, 0x2C, 0xC5 },
  [DAMAGE_WALK_Y_DELTAS_OPERAND - 3] = { 0x03, 0x3C, 0xC5 },
  [DAMAGE_WALK_DIRECTIONS_OPERAND - 3] = { 0x03, 0x34, 0x95 },
}

-- Offsets inside processDamageToBuilding, the game's own damage, where it sorts the tile
-- it has been handed: a building one way, a tile with the wall bit into the wall loop, and
-- anything else straight back out again having done nothing at all. Both executables have
-- the function byte for byte the same; only the addresses in its operands differ.
local DAMAGE_WALL_TEST = 0x5E                 -- test eax, 0x100 - is a wall standing here?
local DAMAGE_WALL_TEST_SIZE = 5
local DAMAGE_WALL_CARRY_ON = 0x69             -- ... there is: on into the wall loop
local DAMAGE_NOTHING = 0xA6C                  -- ... there is not: out, having done nothing
local DAMAGE_GUARDS = {
  [DAMAGE_WALL_TEST] = { 0xA9, 0x00, 0x01, 0x00, 0x00 },
  [DAMAGE_WALL_TEST + DAMAGE_WALL_TEST_SIZE] = { 0x0F, 0x84 },
  [DAMAGE_WALL_CARRY_ON] = { 0xA8, 0x02 },
}

-- Offsets inside findTunnelTarget. Nothing is written there; it is read for the three
-- addresses the game's own target search works through - the path finding state it is
-- called on, the result it sets, and the search itself.
local ROW_TABLE_OPERAND = 0xFA                -- inside setDestinationForUnit
local ROW_TABLE_GUARD_OFFSET = 0xF7
local FIND_PATH_STATE_OPERAND = 0xB5
local FIND_SEARCH_CALL = 0xB9
local FIND_RESULT_OPERAND = 0xC0
local FIND_GUARDS = {
  [FIND_PATH_STATE_OPERAND - 1] = { 0xB9 },
  [FIND_SEARCH_CALL] = { 0xE8 },
  [FIND_RESULT_OPERAND - 2] = { 0x83, 0x3D },
}

-- The game's pass over its units, which runs once a tick. The module's collapse queue is
-- worked through at the front of it, so a tunnel keeps falling in whether or not the
-- tunneler that dug it is still alive. Three instructions are replayed.
local AOB_UPDATE_UNITS = "53 55 0F BF 2D ? ? ? ? 81 E5 0F 00 00 80 56 57 8B F1"
local TICK_HOOK = 0x00
local TICK_HOOK_SIZE = 9
local TICK_RNG_OPERAND = 0x05
local TICK_GUARDS = {
  [0x00] = { 0x53, 0x55, 0x0F, 0xBF, 0x2D },
  [0x09] = { 0x81, 0xE5, 0x0F, 0x00, 0x00, 0x80 },
}

-- How many tiles of tunnel the queue holds, and where a tunneler keeps the tunnel it dug.
local QUEUE_MAX = 512
local UNIT_PATH_PLAN = 0xFE                   -- two steps to the byte
local UNIT_LADDER_X = 0xCC                    -- where the tunnel started
local UNIT_LADDER_Y = 0xCE
local UNIT_PREVIOUS_TILE = 0xDC

-- The game's own "is this unit worth aiming at" test, asked by every unit's update before
-- it shoots at or charges at somebody. Two instructions are replayed, so the hook is ten
-- bytes wide.

local AOB_WORTH_AIMING_AT =
  "8B 44 24 04 69 C0 90 04 00 00 0F B7 84 08 ? ? ? ? 66 3D 6F 00"
local AIM_HOOK = 0x00
local AIM_HOOK_SIZE = 10
local AIM_GUARDS = {
  [0x0A] = { 0x0F, 0xB7, 0x84, 0x08 },
  [0x12] = { 0x66, 0x3D, 0x6F, 0x00 },
}

-- Where the game looks up a player's keep, which is the module's idea of where that
-- player's castle is. The pattern sits in two functions that do the same thing and both
-- read the same table, so either match gives the right address.
local AOB_KEEP_OF_PLAYER = "66 83 B8 ? ? ? ? 02 74 ? 69 ED F4 39 00 00 8B AD ? ? ? ?"
local AOB_CAMPGROUND_OF_PLAYER = "8B 44 24 04 69 C0 F4 39 00 00 8B 80 ? ? ? ? 85 C0 7F"
local CAMP_IDS_OPERAND = 0x0C
local CAMP_GUARDS = {
  [0x00] = { 0x8B, 0x44, 0x24, 0x04, 0x69, 0xC0, 0xF4, 0x39, 0x00, 0x00 },
  [CAMP_IDS_OPERAND - 2] = { 0x8B, 0x80 },
}
local KEEP_IDS_OPERAND = 0x12
local PLAYER_COUNT = 8                        -- the lords a map can hold, numbered from 1
local PLAYER_STRIDE = 0x39F4
local KEEP_GUARDS = {
  [0x0A] = { 0x69, 0xED, 0xF4, 0x39, 0x00, 0x00 },
  [KEEP_IDS_OPERAND - 2] = { 0x8B, 0xAD },
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
local UNIT_DEST_TILE = 0xD8                   -- ... as a tile, which is what the maps want
local UNIT_PATH_INDEX = 0xFA                  -- how far along its tunnel it has got
local UNIT_PATH_LENGTH = 0xFC                 -- ... and how long the whole tunnel is
local UNIT_MOVE_STATUS = 0xF6                 -- 0 arrived, 1 waiting, 2 on its way
local UNIT_SIEGE_TARGET = 0x432               -- the player this tunneler was sent against
local UNIT_WORKPLACE = 0x338                  -- the tunnel entrance this tunneler built
local UNIT_SELECTABLE = 0x2A4                 -- 0 = the mouse and the tribes pass it by
local BUILDING_X = 0xEE                       -- where a building stands
local BUILDING_Y = 0xF0
local BUILDING_TYPE = 0xD2                    -- what kind of building it is
local BUILDING_SOME_X = 0x260                 -- ... and where its tunnel search starts
local BUILDING_SOME_Y = 0x262

-- What the scan below is looking for: a living tunneler of the same player, digging.
local UNIT_TYPE_TUNNELER = 5
local UNIT_LOGICAL_ALIVE = 2
local UNIT_STATE_DIGGING = 3

-- Building types are well under this; the game's gate-or-tower table is zero everywhere
-- above the highest real type, so the limit is only there to keep the read in range.
local BUILDING_TYPE_LIMIT = 127

-- The three keep types, from the game's own table of per-type update functions: 40 a manor
-- house, 41 a stone keep, 42 a stronghold. A tunnel is never dug underneath one.
local KEEP_FIRST_TYPE = 40
local KEEP_TYPE_SPAN = 2

-- Everything the game counts as castle rather than town, by building type, read off its own
-- per-type update table and checked against the names the rebalancer uses: 40 to 44 the
-- keeps, 45 to 49 the two gatehouses, the wood and postern gates and the drawbridge, 60 and
-- 61 a further gatehouse and tower, 71 to 73 the keep doors, 74 to 78 the five towers.
-- Walls and stairs are not buildings at all - they live in the map's flag layer - so they
-- are recognised by that flag instead.
local FORTIFIED_TYPES = {
  40, 41, 42, 43, 44,
  45, 46, 47, 48, 49,
  60, 61,
  71, 72, 73,
  74, 75, 76, 77, 78,
}

-- What the unmodified game takes off whatever stands on a tile a collapsing tunnel ran
-- under. A fortification is never shaken for more than this.
local TUNNEL_DAMAGE = 5

-- How far a tunnel's search may reach, in tiles, when it looks for its line or for its next
-- target. The game's own first search widens to 80 and stops there, which is also where
-- this starts: "the tunnels that can reach the spot" is the tunnels the game itself would
-- let dig that far.
local DEFAULT_SEARCH_RANGE = 80
local VANILLA_RANGE = 80

-- A unit's path plan holds 400 bytes of four-bit steps. A tunnel that is sent on keeps the
-- whole of what it has dug in front of the new leg, so this is how long a tunnel can get.
local PLAN_STEPS = 800
local PLAN_BYTES = 400

-- The lines a player's tunnels gather on: four to a player, 16 bytes each - the target's
-- tile, x and y, and the tick the line was last used.
local LINE_BLOCK = 64

-- ... and how long a line is kept with nobody using it: long enough for any pause in a siege,
-- short enough that a line from a game played before a load is not waiting in the next one.
local LINE_LIFETIME_SECONDS = 600

-- A line's route to the enemy's campfire: its path, tile by tile, and the fortifications on
-- it, both breach first, behind a 16 byte head. The search that lays it out may reach as
-- far, in steps, as the campfire is plus ROUTE_SLACK for the way round the keep, but never
-- further than ROUTE_REACH; the route ends at the campfire's tile or the nearest tile to it
-- within END_RADIUS that the search reached.
local ROUTE = {
  entries = 24,
  slack = 40,
  reach = 160,
  endRadius = 12,
  found = 64,                                 -- how many the walk may find before it keeps
                                              -- only those nearest the breach
  pathMax = 192,                              -- tiles of path: more than the reach, always
  searchNumberLimit = 0x7D00,                 -- where the game's search counter wraps
}
ROUTE.pathOffset = 16 + ROUTE.entries * 16

-- How long a fortification on a route stays spoken for once a tunnel has been sent at it:
-- long enough for the tunnel to get there and bring it down. A target the game refused to
-- lay a path to is set aside for longer; the spot the refused tunnel stood on is left
-- alone a moment, every tunnel arriving there waiting instead of searching.
ROUTE.claimSeconds = 30
ROUTE.refusedSeconds = 60
ROUTE.waitSeconds = 2
ROUTE.stepSeconds = 2                         -- how long a half-done retarget is kept
ROUTE.refused = 8                             -- targets set aside at a time
ROUTE.size = ROUTE.pathOffset + ROUTE.pathMax * 4
-- Where traceAndCommitPathPlan finds no way back and goes on to rebuild the whole map.
ROUTE.drainBudget = 2500                      -- collapse work a tick may take (x1024 cycles)
ROUTE.stopwatchFloor = 90000                  -- a tick this long (x1024 cycles, ~25 ms) is worth a line
ROUTE.travelHook = 0x7E0                      -- je: not at its destination yet
ROUTE.raids = {
  tribeAob = "56 57 8B 7C 24 10 33 C0 69 FF 90 04 00 00 0F BF 97 ? ? ? ? 8B 0C 85 ? ? ? ? 3B D1",
  tribeHook = 0x0E,               -- movsx edx, word [edi+unitType]
  guildAob = "85 C0 0F 84 ? ? ? ? 83 FB 1E 6A 00 55 50 75",
  guildNext = 0xAD,               -- the recruiting loop's "next unit"
  maceman = 26,
}
ROUTE.raids.guildGuards = { [ROUTE.raids.guildNext] = { 0x8B, 0x44, 0x24, 0x28, 0x83, 0xC0, 0x01 } }
ROUTE.traceFailed = {
  aob = "8B 7C 24 10 83 47 78 01 8B CF C7 87 ? ? ? ? 00 00 00 00 E8",
  hookSize = 8,
  planLengthOperand = 0x0C,     -- mov [edi+planLength], 0
  done = 0x39,                  -- pop ebp / pop ebx / pop esi / pop edi / ret
}
ROUTE.traceFailed.guards = { [ROUTE.traceFailed.done] = { 0x5D, 0x5B, 0x5E, 0x5F } }

-- A tunnel sent at its line's target searches no further than the target's own distance
-- in steps plus this: room to go round a keep, without paying for a spread to the edge of
-- the range when the target turns out to be unreachable.
ROUTE.pinSlack = 24

-- Inside the target search: its read of the flag map (which search last reached a tile),
-- and of the wall owner layer. (Kept in the one table: the module's main chunk is close to
-- Lua's ceiling of two hundred locals.)
ROUTE.flagMapOperand = 0x1F8
ROUTE.wallOwnerOperand = 0x146
ROUTE.guards = {
  [0x1F4] = { 0x0F, 0xBF, 0x14, 0x45 },
  [0x143] = { 0x0F, 0xB6, 0x85 },
  [0x1FC] = { 0x3B, 0x56, 0x04 },                  -- cmp edx, [esi+4]: the search's number
}
ROUTE.buildingOwner = 0xD6                    -- who a building belongs to

-- How close two collapses have to be to count as the same breach, so the second one adds
-- its time to the first zone instead of taking a second one.
local DENIAL_STACK_RADIUS = 2

-- The map's per-tile flag word. A wall is 0x100, a crenellation 0x200 and stairs 0x800 -
-- the three the game's own destroyWall clears together, and the three this module treats
-- alike: a tunnel may be aimed at any of them, a collapse takes any of them away, and the
-- ground under them is never touched, since for a wall that height is its strength.
local WALL_FAMILY_FLAGS = 0x100 | 0x200 | 0x800

-- The same flag word's stockpile bit. The game marks a stockpile's whole footprint with it
-- and with the wall bit (clearStockpileFootprintTiles takes the two away together), which
-- makes a stockpile look like a stretch of wall to anything that only asks for the wall
-- bit - but it cannot be damaged. Tunnels are never aimed at it, never collapse under it,
-- and a route to the campfire running beneath it is not blocked by it. (In ROUTE, not a
-- local of its own: the main chunk is at Lua's ceiling of two hundred locals.)
ROUTE.stockpileFlag = 0x2

-- ... and the two of them the game's own damage routine does not sort into its wall loop
-- by itself, so that a tunnel could never do anything but take them away outright.
local STAIR_FAMILY_FLAGS = 0x200 | 0x800

-- Inside the target search: the test that asks whether a wall stands on the tile it has
-- reached. Widening that one constant is what lets a tunnel be aimed at stairs and
-- crenellations as well.
local SEARCH_WALL_TEST_OPERAND = 0x131
local SEARCH_WALL_TEST_GUARD = { [0x130] = { 0xA9, 0x00, 0x01, 0x00, 0x00 } }
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

-- Tunnel records, a ring of {unit uid, times sent on, its line, spare}. A uid pushed out of
-- the ring only means that tunneler starts its count over and has no line to follow.
local RECORD_COUNT = 64
local RECORD_SIZE = 16

-- Layout of the module's own control block. Whatever did not change keeps the offset it
-- always had.
local C = {}                                  -- the module's own control block
C.DENIAL_ENABLED = 0x00
C.DENIAL_DURATION = 0x04
C.RETARGET_ENABLED = 0x08
C.RETARGET_RANGE = 0x0C
C.RETARGET_MAX = 0x10             -- how often one tunnel may be sent on
C.UI_ENABLED = 0x14
C.STANCE_ENABLED = 0x18
C.RAIDS_ENABLED = 0x1C            -- AI raids may include tunnellers
C.TARGETS_ENABLED = 0x20
C.DIAGNOSTICS = 0x24
C.LAST_TICK = 0x28                -- the tick the zones were last looked at
C.LAST_REPORT_TICK = 0x2C         -- the build check reports at most once a second
C.SCRATCH = 0x30
C.RING_CURSOR = 0x34              -- the next entry of the tunnel records to hand out
C.REPORT = 0x48                   -- ten dwords the hooks fill in before logging
C.MINE = 0x70                     -- the last refusal was this module's own
C.MINE_TICK = 0x74                -- ... on this tick
C.COLLAPSE_DAMAGE = 0x78          -- what a collapse does to what it arrived under
C.SPREAD_ENABLED = 0x7C
C.SPREAD_DAMAGE = 0x80            -- ... and to the eight tiles beside each one
C.SUPPRESS = 0x84                 -- fill the tunnel in, but quietly
C.SPREAD_INDEX = 0x88
C.HIDE_SELECT = 0x8C              -- a digging tunneler cannot be picked
C.HIDE_TARGET = 0x90              -- ... and nothing aims at it
C.CAMP_X = 0xA0                   -- the enemy's campfire, as find_anchor last saw it
C.CAMP_Y = 0xA4
C.UNDER_BUILDINGS = 0xA8          -- a tunnel may pass beneath the town
C.SPREAD_RADIUS = 0xC4
C.SPREAD_DX = 0xC8
C.SPREAD_DY = 0xCC
C.SPREAD_TILE = 0xD0
C.SPREAD_TX = 0xD4
C.SPREAD_TY = 0xD8
C.FLAT_INDEX = 0xDC
C.AIM_MODE = 0xE4                 -- what the search filter does: 0 off, 1 pin, 2 cone
C.AIM_PIN = 0xE8                  -- ... the one tile a pinned search takes
C.AIM_FROM_X = 0xEC               -- where the search runs from
C.AIM_FROM_Y = 0xF0
C.AIM_DIR_X = 0xF4                -- ... and the way to the enemy's campfire, scaled to 64
C.AIM_DIR_Y = 0xF8
C.AIM_DIR_LENGTH = 0xFC           -- ... squared
C.AIM_UNIT = 0x100                -- the tunneler being aimed, scaled
C.AIM_RANGE = 0x104
C.AIM_OWNER = 0x108
C.AIM_SIEGE = 0x10C
C.GAME_TILE = 0x110               -- what the game's own first search answered
C.GAME_X = 0x114
C.GAME_Y = 0x118
C.OURS = 0x11C                    -- the first aim is a line, not the game's own answer
C.REDIRECT_HOW = 0x120            -- how a tunnel was sent on, or why it was not
C.RECORD = 0x128                  -- the record of the tunneler being aimed
C.SAVE_LADDER_X = 0x12C           -- where the tunnel being extended began
C.SAVE_LADDER_Y = 0x130
C.SAVE_PREVIOUS = 0x134
C.LAST_REDIRECT = 0x138            -- the tick a tunnel was last sent on
C.SEARCHED = 0x13C                -- the first aim ran a search of its own
C.ROUTE_CURRENT = 0x140           -- the route line_front last looked at
C.ROUTE_GEN = 0x144               -- the number of the search a route was laid out by
C.ROUTE_BEST = 0x148              -- how near the campfire the route's end is, squared
C.ROUTE_FOUND = 0x14C             -- fortifications the walk has found so far
C.ROUTE_X = 0x150                 -- where the walk is
C.ROUTE_Y = 0x154
C.WALK_X = 0x158
C.WALK_Y = 0x15C
C.PATH_FOUND = 0x160              -- tiles of path the walk has stepped on so far
C.CAMP_BUILDING = 0x164           -- the enemy's campfire, as a building
C.ANCHOR_ID = 0x168               -- ... the one find_anchor is looking at
C.FAIL_SPOT = 0x16C               -- where the game last refused a path, and until when
C.FAIL_UNTIL = 0x170              -- tunnels arriving there wait
C.REFUSED_CURSOR = 0x174          -- the next slot of the targets set aside
C.EXTEND_FULL = 0x178             -- the extension failed for want of room, not the trace
C.FOLLOW_AT = 0x17C               -- where on its route the tunneller stands
C.FOLLOW_FIRST = 0x180            -- the first fortification standing ahead of it
C.FOLLOW_PICK = 0x184             -- ... and the one it is sent at
C.REFUSED = 0x188                 -- {tile, until}, the targets set aside
C.QUIET = 0x1C8                   -- the path being laid is ours: no rebuild if it fails
C.SW_LAST = 0x1CC                 -- stopwatch: when this tick started (cycles / 1024)
C.SW_AVERAGE = 0x1D0              -- ... a tick's usual length
C.SW_TUNNEL = 0x1D4               -- ... spent in UpdateTunneler this tick
C.SW_QUEUE = 0x1D8                -- ... spent collapsing tunnels from the queue
C.SW_MAX = 0x1DC                  -- ... the dearest single tunneller update
C.SW_MAX_STATE = 0x1E0            -- ... the state it started in
C.SW_MAX_UNIT = 0x1E4
C.SW_MAX_HOW = 0x1E8              -- ... and REDIRECT_HOW after it
C.SW_COUNT = 0x1EC                -- ... tunneller updates this tick
C.SW_TILES = 0x1F0                -- ... tunnel tiles the collapse started on this tick
C.SW_DAMAGE_MAX = 0x1F4           -- ... the dearest single call of the game's damage
C.SW_DAMAGE_CALLS = 0x1F8         -- ... how many calls of it
C.SW_DAMAGE_KIND = 0x1FC          -- ... what the dearest hit: a building type, -1 a wall
C.STEP_ACTIVE = 0x200             -- a tunnel tile is part way through falling in
C.DRAIN_START = 0x204             -- when this tick's collapse work began (cycles / 1024)
C.FILL_UNIT = 0x22C               -- the tunnel being written into the queue
C.FILL_FLAGS = 0x230
C.FILL_TILE = 0x234
C.FILL_X = 0x238
C.FILL_Y = 0x23C
C.FILL_STEP = 0x240
C.FILL_LEFT = 0x244
C.STEP_TILE = 0x248               -- the tile being taken apart this tick
C.STEP_X = 0x24C
C.STEP_Y = 0x250
C.STEP_FLAGS = 0x254
C.STEP_DX = 0x258
C.STEP_DY = 0x25C
C.STEP_THIS_TILE = 0x260
C.STEP_THIS_X = 0x264
C.STEP_THIS_Y = 0x268
C.TICK_LEFT = 0x26C
C.QUEUE_COUNT = 0x270
C.SPEED = 0x274
C.ANCHOR_UNIT = 0x278             -- the tunnel looking for a camp to aim at
C.ANCHOR_FROM = 0x27C             -- the players still to be considered
C.ANCHOR_TO = 0x280
C.ANCHOR_BEST = 0x284             -- how far off the nearest camp so far is
C.ANCHOR_X = 0x288
C.ANCHOR_Y = 0x28C
C.STEP_DAMAGE = 0x2A8             -- what this one tile is taking
C.FAMILY_DAMAGE = 0x2C4           -- the damage running now is this module's, so stairs
                                  -- and crenellations take it too
C.FAMILY_READY = 0x2C8            -- ... and the widening that lets them is in
C.QUEUE = 0x2E8
C.ZONES = C.QUEUE + QUEUE_MAX * 16
C.RECORDS = C.ZONES + ZONE_COUNT * ZONE_SIZE
C.LINES = C.RECORDS + RECORD_COUNT * RECORD_SIZE     -- four lines per player
C.PLAN_BUFFER = C.LINES + (PLAYER_COUNT + 1) * LINE_BLOCK  -- a plan being extended
C.ROUTE_TEMP = C.PLAN_BUFFER + PLAN_BYTES                -- a route being read out
C.PATH_TEMP = C.ROUTE_TEMP + ROUTE.found * 12            -- ... and its path
C.ROUTES = C.PATH_TEMP + ROUTE.pathMax * 4               -- one route to every line
C.SIZE = C.ROUTES + (PLAYER_COUNT + 1) * 4 * ROUTE.size

---------------------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------------------
-- The GUI hands enable() only what it has saved, never the defaults in options.yml, so a
-- module nobody has opened in the GUI gets an empty table. These are the real defaults.
local DEFAULTS = {
  denial = { enabled = true, seconds = 120, message = true },
  retarget = { enabled = true, range = DEFAULT_SEARCH_RANGE, max = 10 },
  targets = { towers_and_gates = true, under_buildings = true },
  collapse = { damage = 2500, spread = true, spread_damage = 60, spread_radius = 2,
    speed = 2 },
  digging = { unselectable = true, untargetable = true },
  diagnostics = { enabled = false },
  ui = { enabled = true },
  stances = { enabled = true },
  raids = { enabled = true },
}

-- What each hook writes into the report block, and what the decision code at +0x1C means.
-- Nothing here runs unless diagnostics are switched on, and then only when a tunnel
-- arrives, a tunnel collapses, or somebody tries to build within twenty tiles of a zone.
local REPORT_WORDS = {
  [11] = "tunnel arrived on a fortification, collapsing; every denial slot is in use",
  [12] = "tunnel arrived on a fortification, collapsing; denial laid",
  [13] = "tunnel arrived on a fortification, collapsing; its time added to the denial there",
  [20] = "building attempt near a denial, not refused",
  [21] = "building attempt inside a denial, refused",
  [40] = "tunnel dug in (tile = its target, b = the game's own, c = its line, "
      .. "d = 1 joined the line, 2 started a line, 3 the line was the game's own answer)",
  [41] = "tunnel arrived on a fortification, collapsing",
  [42] = "tunnel arrived on empty ground and is sent on (tile = its new target, "
      .. "b = 7 along its line's route, 1 to its line by a search, 2 towards the campfire, "
      .. "3 widening the way in, c = its line, d = times sent on)",
  [43] = "tunnel arrived on empty ground and collapses there (b = 4 sent on as often as "
      .. "allowed, 5 nothing in reach, 8 the tunnel is as long as a plan can hold)",
  [46] = "the game would not lay the path; the target is set aside and tunnels here wait a "
      .. "moment (tile = the target, flags = its flags, c = the line, d = tries, "
      .. "e = where the tunnel stands, f = that tile's flags, g = its plan so far)",
  [47] = "a slow tick (a = its length, tile = spent in tunneller updates, flags = spent "
      .. "collapsing tunnels, b = the dearest single tunneller update, c = the dearest "
      .. "single call of the game's damage, d = calls of it, e = what that one hit (a "
      .. "building type, -1 a wall), f = tunnel tiles the collapse started on, g = the "
      .. "clock; all times in units of 1024 CPU cycles)",
  [48] = "an AI tunneller joins a raid troop, as a maceman would (a = the unit, "
      .. "tile = its player)",
  [49] = "an AI wanted a raid tunneller but has no Tunneler's Guild; it recruits its next "
      .. "raid unit instead (a = the player)",
  [44] = "a line laid out its route to the campfire (a = player, tile = the first "
      .. "fortification on it, flags = tiles on its path, b = fortifications on it, "
      .. "c = how far the search reached)",
  [45] = "a line's path would not lay; the tunnel keeps the game's own target (b = laid)",
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

---Where a six-byte conditional jump goes.
---@param address number
---@return number
local function jumpTarget(address)
  return (address + 6 + readInteger(address + 2)) & 0xFFFFFFFF
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
    local targetsOn = setting(config, "targets", "towers_and_gates") and true or false
    local collapseDamage = toInteger(setting(config, "collapse", "damage"),
      DEFAULTS.collapse.damage)
    local spreadOn = setting(config, "collapse", "spread") and true or false
    local unselectableOn = setting(config, "digging", "unselectable") and true or false
    local untargetableOn = setting(config, "digging", "untargetable") and true or false
    local underOn = setting(config, "targets", "under_buildings") and true or false
    local spreadDamage = toInteger(setting(config, "collapse", "spread_damage"),
      DEFAULTS.collapse.spread_damage)
    local spreadRadius = toInteger(setting(config, "collapse", "spread_radius"),
      DEFAULTS.collapse.spread_radius)
    local collapseSpeed = toInteger(setting(config, "collapse", "speed"),
      DEFAULTS.collapse.speed)
    local diagnosticsOn = setting(config, "diagnostics", "enabled") and true or false
    local uiOn = setting(config, "ui", "enabled") and true or false
    local stancesOn = setting(config, "stances", "enabled") and true or false
    local raidsOn = setting(config, "raids", "enabled") and true or false

    ---------------------------------------------------------------------------------
    -- Find the game code
    ---------------------------------------------------------------------------------

    local tunneler = scanOptional(AOB_UPDATE_TUNNELER, "the tunneler's update function")
    if tunneler ~= nil and not guardsHold(tunneler, TUNNELER_GUARDS,
        "the tunneler's update function") then
      tunneler = nil
    end

    local currentUnit, unitBase, buildingBase, tileFlags, buildingTiles, unitsState

    -- Where each player's keep is, for aiming tunnels towards it.
    local keepIds, campIds
    local keepSite = scanOptional(AOB_KEEP_OF_PLAYER, "the player's keep")
    if keepSite ~= nil and guardsHold(keepSite, KEEP_GUARDS, "the player's keep") then
      keepIds = readAddress(keepSite + KEEP_IDS_OPERAND)
    end
    local campSite = scanOptional(AOB_CAMPGROUND_OF_PLAYER, "the player's campground")
    if campSite ~= nil and guardsHold(campSite, CAMP_GUARDS, "the player's campground") then
      campIds = readAddress(campSite + CAMP_IDS_OPERAND)
    end
    if tunneler ~= nil then
      currentUnit = readAddress(tunneler + TUNNELER_CURRENT_UNIT_OPERAND)
      unitBase = (readAddress(tunneler + TUNNELER_OWNER_OPERAND) - UNIT_OWNER) & 0xFFFFFFFF
      buildingBase = (readAddress(tunneler + TUNNELER_BUILDING_OPERAND) - 0xF0) & 0xFFFFFFFF
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

    local control = core.allocate(C.SIZE, true)
    local zones = control + C.ZONES
    local records = control + C.RECORDS

    writeInteger(control + C.DENIAL_ENABLED, denialOn and 1 or 0)
    writeInteger(control + C.DENIAL_DURATION, denialSeconds * TICKS_PER_SECOND)
    writeInteger(control + C.RETARGET_ENABLED, retargetOn and 1 or 0)
    writeInteger(control + C.RETARGET_RANGE, retargetRange)
    writeInteger(control + C.RETARGET_MAX, retargetMax)
    writeInteger(control + C.UI_ENABLED, uiOn and 1 or 0)
    writeInteger(control + C.STANCE_ENABLED, stancesOn and 1 or 0)
    writeInteger(control + C.RAIDS_ENABLED, raidsOn and 1 or 0)
    writeInteger(control + C.TARGETS_ENABLED, targetsOn and 1 or 0)
    writeInteger(control + C.COLLAPSE_DAMAGE, collapseDamage)
    writeInteger(control + C.SPREAD_ENABLED, spreadOn and 1 or 0)
    writeInteger(control + C.SPREAD_DAMAGE, spreadDamage)
    writeInteger(control + C.SPREAD_RADIUS, spreadRadius)
    writeInteger(control + C.SPEED, collapseSpeed)
    writeInteger(control + C.HIDE_SELECT, unselectableOn and 1 or 0)
    writeInteger(control + C.HIDE_TARGET, untargetableOn and 1 or 0)
    writeInteger(control + C.UNDER_BUILDINGS, underOn and 1 or 0)
    writeInteger(control + C.DIAGNOSTICS, diagnosticsOn and 1 or 0)
    writeInteger(control + C.RING_CURSOR, records)
    writeInteger(control + C.REFUSED_CURSOR, control + C.REFUSED)

    self.control = control
    self.patched = {}

    -- Where the hooks report to. They fill the report block and call this pad; the pad is
    -- five NOPs and a ret with a lua detour on it, so nothing runs in the game's own code
    -- path except the call itself, and only when diagnostics are on. Tunnels arriving and
    -- collapsing are rare events, but the build check is not: every tile of every wall the
    -- AI lays down goes through it, and an unthrottled version of this wrote seventy
    -- thousand lines in seven minutes of play. So the build check reports at most one line
    -- a second; the tunnel hooks, which speak only when a tunnel arrives, are left alone.
    local report = control + C.REPORT
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
    local collapseReady, familyReady = false, false
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

    if (keepIds == nil) ~= (campIds == nil) then
      log(INFO, "improved-tunnelers: only one of the keep and the campground was found; "
        .. "tunnels aim at whichever is there.")
    end

    -- Where each row of the map starts, for working out a tile from an x and a y.
    local rowTable
    if tunneler ~= nil then
      local setDestination = callTarget(tunneler + TUNNELER_SET_DESTINATION_CALL)
      if guardsHold(setDestination, { [ROW_TABLE_GUARD_OFFSET] = { 0x03, 0x3C, 0x85 } },
          "the map's rows") then
        rowTable = readAddress(setDestination + ROW_TABLE_OPERAND)
      end
    end

    -- Which camp the tunnels should be working towards. Only the nearest enemy is wanted,
    -- so a player on our own team is passed over; with no team table to read, a table of
    -- nothing but zeroes reads as "nobody is allied with anybody".
    local anchor
    local teamTable
    if teamSite ~= nil then
      teamTable = readAddress(teamSite + OFFSET_PLAYER_TEAMS)
    end
    if teamTable == nil then
      teamTable = core.allocate((PLAYER_COUNT + 1) * 4, true)
      for player = 0, PLAYER_COUNT do
        writeInteger(teamTable + 4 * player, 0)
      end
    end
    if unitBase ~= nil and (campIds ~= nil or keepIds ~= nil) then
      anchor = core.allocateAssembly(templates.find_anchor, {
        ANCHOR_ID_ADDRESS = control + C.ANCHOR_ID,
        CAMP_BUILDING_ADDRESS = control + C.CAMP_BUILDING,
        ANCHOR_UNIT_ADDRESS = control + C.ANCHOR_UNIT,
        ANCHOR_FROM_ADDRESS = control + C.ANCHOR_FROM,
        ANCHOR_TO_ADDRESS = control + C.ANCHOR_TO,
        ANCHOR_BEST_ADDRESS = control + C.ANCHOR_BEST,
        ANCHOR_X_ADDRESS = control + C.ANCHOR_X,
        ANCHOR_Y_ADDRESS = control + C.ANCHOR_Y,
        CAMP_X_ADDRESS = control + C.CAMP_X,
        CAMP_Y_ADDRESS = control + C.CAMP_Y,
        TEAMS_ADDRESS = teamTable,
        PLAYER_COUNT = PLAYER_COUNT,
        PLAYER_STRIDE = PLAYER_STRIDE,
        BUILDING_STRIDE = SEARCH_STRIDE,
        KEEP_IDS_ADDRESS = keepIds or campIds,
        CAMP_IDS_ADDRESS = campIds or keepIds,
        BUILDING_X = (buildingBase + BUILDING_X) & 0xFFFFFFFF,
        BUILDING_Y = (buildingBase + BUILDING_Y) & 0xFFFFFFFF,
        UNIT_X = (unitBase + UNIT_X) & 0xFFFFFFFF,
        UNIT_Y = (unitBase + UNIT_Y) & 0xFFFFFFFF,
        UNIT_OWNER = (unitBase + UNIT_OWNER) & 0xFFFFFFFF,
        UNIT_SIEGE_TARGET = (unitBase + UNIT_SIEGE_TARGET) & 0xFFFFFFFF,
      })
    end
    -- One byte a building type, 1 where the shaking leaves the building standing.
    local fortified = core.allocate(BUILDING_TYPE_LIMIT + 1, true)
    for kind = 0, BUILDING_TYPE_LIMIT do
      core.writeByte(fortified + kind, 0)
    end
    for _, kind in ipairs(FORTIFIED_TYPES) do
      core.writeByte(fortified + kind, 1)
    end

    -- ... and what stands in for it when those tables were not found: "no camp".
    local anchorStub = core.allocateAssembly(templates.no_anchor, {
      ANCHOR_BEST_ADDRESS = control + C.ANCHOR_BEST,
    })

    local queueFill
    if tunneler ~= nil and ticks ~= nil and search ~= nil then
      local walk = callTarget(tunneler + TUNNELER_TUNNEL_DAMAGE_CALL)
      local tickSite = scanOptional(AOB_UPDATE_UNITS, "the game's pass over its units")
      if guardsHold(walk, DAMAGE_WALK_GUARDS, "the tunnel collapse")
          and tickSite ~= nil and guardsHold(tickSite, TICK_GUARDS, "the game's pass over its units")
          and rowTable ~= nil then
        local tileMapState = readAddress(walk + DAMAGE_WALK_TILE_MAP_OPERAND)
        local processDamage = callTarget(walk + DAMAGE_WALK_DAMAGE_CALL)

        -- Stairs and crenellations are sorted out of the game's own damage before it does
        -- anything; widening that one test hands them to the wall loop instead, which
        -- already knows how to damage them, how to have them drawn damaged and how to
        -- clear them away. It only holds while this module's own damage is running.
        if guardsHold(processDamage, DAMAGE_GUARDS, "the game's own damage") then
          local family = core.allocateAssembly(templates.damage_family, {
            STAIR_FAMILY = STAIR_FAMILY_FLAGS,
            FAMILY_ACTIVE_ADDRESS = control + C.FAMILY_DAMAGE,
            CARRY_ON_ADDRESS = processDamage + DAMAGE_WALL_CARRY_ON,
            NOTHING_ADDRESS = processDamage + DAMAGE_NOTHING,
          })
          remember(processDamage + DAMAGE_WALL_TEST, DAMAGE_WALL_TEST_SIZE)
          writeJump(processDamage + DAMAGE_WALL_TEST, family, DAMAGE_WALL_TEST_SIZE)
          writeInteger(control + C.FAMILY_READY, 1)
          familyReady = true
        end
        local queue = control + C.QUEUE
        -- Writing a tunnel into the queue, one tile of it at a time.
        local fill = core.allocateAssembly(templates.queue_fill, {
          FILL_UNIT_ADDRESS = control + C.FILL_UNIT,
          FILL_FLAGS_ADDRESS = control + C.FILL_FLAGS,
          FILL_TILE_ADDRESS = control + C.FILL_TILE,
          FILL_X_ADDRESS = control + C.FILL_X,
          FILL_Y_ADDRESS = control + C.FILL_Y,
          FILL_STEP_ADDRESS = control + C.FILL_STEP,
          FILL_LEFT_ADDRESS = control + C.FILL_LEFT,
          QUEUE_ADDRESS = queue,
          QUEUE_COUNT_ADDRESS = control + C.QUEUE_COUNT,
          QUEUE_MAX = QUEUE_MAX,
          DIRECTIONS_ADDRESS = readAddress(walk + DAMAGE_WALK_DIRECTIONS_OPERAND),
          X_DELTAS_ADDRESS = readAddress(walk + DAMAGE_WALK_X_DELTAS_OPERAND),
          Y_DELTAS_ADDRESS = readAddress(walk + DAMAGE_WALK_Y_DELTAS_OPERAND),
          UNIT_PATH_LENGTH = (unitBase + UNIT_PATH_LENGTH) & 0xFFFFFFFF,
          UNIT_PATH_PLAN = (unitBase + UNIT_PATH_PLAN) & 0xFFFFFFFF,
          UNIT_LADDER_X = (unitBase + UNIT_LADDER_X) & 0xFFFFFFFF,
          UNIT_LADDER_Y = (unitBase + UNIT_LADDER_Y) & 0xFFFFFFFF,
          UNIT_PREVIOUS_TILE = (unitBase + UNIT_PREVIOUS_TILE) & 0xFFFFFFFF,
        })

        -- One tile of it: the ground goes back, and what stands about is shaken.
        local step = core.allocateAssembly(templates.queue_step, {
          WALL_FAMILY = WALL_FAMILY_FLAGS,
          STOCKPILE = ROUTE.stockpileFlag,
          FORTIFIED_ADDRESS = fortified,
          TYPE_LIMIT = BUILDING_TYPE_LIMIT,
          TUNNEL_DAMAGE = TUNNEL_DAMAGE,
          STEP_DAMAGE_ADDRESS = control + C.STEP_DAMAGE,
          BUILDING_STRIDE = SEARCH_STRIDE,
          BUILDING_TYPE_ADDRESS = (buildingBase + BUILDING_TYPE) & 0xFFFFFFFF,
          RADIUS_ADDRESS = control + C.SPREAD_RADIUS,
          STEP_X_ADDRESS = control + C.STEP_X,
          STEP_Y_ADDRESS = control + C.STEP_Y,
          STEP_FLAGS_ADDRESS = control + C.STEP_FLAGS,
          STEP_DX_ADDRESS = control + C.STEP_DX,
          STEP_DY_ADDRESS = control + C.STEP_DY,
          STEP_THIS_TILE_ADDRESS = control + C.STEP_THIS_TILE,
          STEP_THIS_X_ADDRESS = control + C.STEP_THIS_X,
          STEP_THIS_Y_ADDRESS = control + C.STEP_THIS_Y,
          SPREAD_DAMAGE_ADDRESS = control + C.SPREAD_DAMAGE,
          ROW_TABLE_ADDRESS = rowTable,
          MAP_LIMIT = MAP_LIMIT,
          LIVE_HEIGHT_ADDRESS = readAddress(walk + DAMAGE_WALK_LIVE_HEIGHT_OPERAND),
          BASE_HEIGHT_ADDRESS = readAddress(walk + DAMAGE_WALK_BASE_HEIGHT_OPERAND),
          TILE_FLAGS_ADDRESS = tileFlags,
          BUILDING_TILE_ADDRESS = buildingTiles,
          TILE_MAP_STATE_ADDRESS = tileMapState,
          PROCESS_DAMAGE_ADDRESS = processDamage,
          FAMILY_ACTIVE_ADDRESS = control + C.FAMILY_DAMAGE,
          STEP_ACTIVE_ADDRESS = control + C.STEP_ACTIVE,
        })

        -- ... and the tick that works through what is queued.
        local tick = core.allocateAssembly(templates.queue_tick, {
          DIAGNOSTICS_ADDRESS = control + C.DIAGNOSTICS,
          REPORT_ADDRESS = report,
          REPORT_PAD_ADDRESS = reportPad,
          SW_FLOOR = ROUTE.stopwatchFloor,
          SW_LAST_ADDRESS = control + C.SW_LAST,
          SW_AVERAGE_ADDRESS = control + C.SW_AVERAGE,
          SW_TUNNEL_ADDRESS = control + C.SW_TUNNEL,
          SW_QUEUE_ADDRESS = control + C.SW_QUEUE,
          SW_MAX_ADDRESS = control + C.SW_MAX,
          SW_COUNT_ADDRESS = control + C.SW_COUNT,
          SW_TILES_ADDRESS = control + C.SW_TILES,
          SW_DAMAGE_MAX_ADDRESS = control + C.SW_DAMAGE_MAX,
          SW_DAMAGE_CALLS_ADDRESS = control + C.SW_DAMAGE_CALLS,
          SW_DAMAGE_KIND_ADDRESS = control + C.SW_DAMAGE_KIND,
          STEP_ACTIVE_ADDRESS = control + C.STEP_ACTIVE,
          DRAIN_START_ADDRESS = control + C.DRAIN_START,
          DRAIN_BUDGET = ROUTE.drainBudget,
          RADIUS_ADDRESS = control + C.SPREAD_RADIUS,
          STEP_DX_ADDRESS = control + C.STEP_DX,
          STEP_DY_ADDRESS = control + C.STEP_DY,
          STEP_THIS_TILE_ADDRESS = control + C.STEP_THIS_TILE,
          TILE_FLAGS_ADDRESS = tileFlags,
          WALL_FAMILY = WALL_FAMILY_FLAGS,
          BUILDING_TILE_ADDRESS = buildingTiles,
          BUILDING_STRIDE = SEARCH_STRIDE,
          BUILDING_TYPE_ADDRESS = (buildingBase + BUILDING_TYPE) & 0xFFFFFFFF,
          QUEUE_ADDRESS = queue,
          QUEUE_COUNT_ADDRESS = control + C.QUEUE_COUNT,
          SPEED_ADDRESS = control + C.SPEED,
          TICK_LEFT_ADDRESS = control + C.TICK_LEFT,
          STEP_TILE_ADDRESS = control + C.STEP_TILE,
          STEP_X_ADDRESS = control + C.STEP_X,
          STEP_Y_ADDRESS = control + C.STEP_Y,
          STEP_FLAGS_ADDRESS = control + C.STEP_FLAGS,
          STEP_ADDRESS = step,
          PATH_STATE_ADDRESS = readAddress(walk + DAMAGE_WALK_PATH_STATE_OPERAND),
          UPDATE_WALK_ADDRESS = callTarget(walk + DAMAGE_WALK_UPDATE_CALL),
          RNG_ADDRESS = readAddress(tickSite + TICK_RNG_OPERAND),
          RETURN_ADDRESS = tickSite + TICK_HOOK + TICK_HOOK_SIZE,
        })
        remember(tickSite + TICK_HOOK, TICK_HOOK_SIZE)
        writeJump(tickSite + TICK_HOOK, tick, TICK_HOOK_SIZE)
        queueFill = fill

        -- ... and what the collapse does to the thing it arrived under, before the tunnel
        -- behind it is queued to fall in.
        local target = core.allocateAssembly(templates.collapse_target, {
          WALL_FAMILY = WALL_FAMILY_FLAGS,
          RESET_TILE_ADDRESS = callTarget(tunneler + TUNNELER_RESET_TILE_CALL),
          TILE_FLAGS_ADDRESS = tileFlags,
          BUILDING_TILE_ADDRESS = buildingTiles,
          CURRENT_UNIT_ADDRESS = currentUnit,
          DAMAGE_ADDRESS = control + C.COLLAPSE_DAMAGE,
          UNIT_TILE = (unitBase + UNIT_TILE) & 0xFFFFFFFF,
          UNIT_X = (unitBase + UNIT_X) & 0xFFFFFFFF,
          UNIT_Y = (unitBase + UNIT_Y) & 0xFFFFFFFF,
          UNIT_OWNER = (unitBase + UNIT_OWNER) & 0xFFFFFFFF,
          TILE_MAP_STATE_ADDRESS = tileMapState,
          PROCESS_DAMAGE_ADDRESS = processDamage,
          FAMILY_ACTIVE_ADDRESS = control + C.FAMILY_DAMAGE,
          FAMILY_READY_ADDRESS = control + C.FAMILY_READY,
          FILL_ADDRESS = fill,
          FILL_UNIT_ADDRESS = control + C.FILL_UNIT,
          FILL_FLAGS_ADDRESS = control + C.FILL_FLAGS,
          UNIT_PATH_LENGTH = (unitBase + UNIT_PATH_LENGTH) & 0xFFFFFFFF,
          RETURN_ADDRESS = tunneler + TUNNELER_COLLAPSE_DONE,
        })
        remember(tunneler + TUNNELER_COLLAPSE_HOOK, TUNNELER_COLLAPSE_HOOK_SIZE)
        writeJump(tunneler + TUNNELER_COLLAPSE_HOOK, target, TUNNELER_COLLAPSE_HOOK_SIZE)
        collapseReady = true
      end

      -------------------------------------------------------------------------------
      -- Where a tunnel goes
      -------------------------------------------------------------------------------
      local algResult = readAddress(finder + FIND_RESULT_OPERAND)
      local algX = readAddress(tunneler + TUNNELER_ALG_TARGET_X_OPERAND)
      local algY = readAddress(tunneler + TUNNELER_ALG_TARGET_Y_OPERAND)
      local setDestination = callTarget(tunneler + TUNNELER_SET_DESTINATION_CALL)
      local lines = control + C.LINES
      local function unitField(offset)
        return (unitBase + offset) & 0xFFFFFFFF
      end

      -- The filter every search runs through. It stays off - the game's own searches, the
      -- AI's included, never see it - except for the single run one of the routines below
      -- asks it for.
      local filter = core.allocateAssembly(templates.aim_filter, {
        STOCKPILE = ROUTE.stockpileFlag,
        TILE_FLAGS_ADDRESS = tileFlags,
        BUILDING_TILE_ADDRESS = buildingTiles,
        CAMP_BUILDING_ADDRESS = control + C.CAMP_BUILDING,
        TICKS_ADDRESS = ticks,
        REFUSED_ADDRESS = control + C.REFUSED,
        REFUSED_END_ADDRESS = control + C.REFUSED + ROUTE.refused * 8,
        AIM_MODE_ADDRESS = control + C.AIM_MODE,
        AIM_PIN_ADDRESS = control + C.AIM_PIN,
        AIM_FROM_X_ADDRESS = control + C.AIM_FROM_X,
        AIM_FROM_Y_ADDRESS = control + C.AIM_FROM_Y,
        AIM_DIR_X_ADDRESS = control + C.AIM_DIR_X,
        AIM_DIR_Y_ADDRESS = control + C.AIM_DIR_Y,
        AIM_DIR_LENGTH_ADDRESS = control + C.AIM_DIR_LENGTH,
        RESULT_TILE = SEARCH_RESULT_TILE,
        RESULT_Y = SEARCH_RESULT_Y,
        RESULT_X = SEARCH_RESULT_X,
        SPREAD_ADDRESS = search + SEARCH_SPREAD,
        RETURN_ADDRESS = search + SEARCH_TAKE_IT_DONE,
      })
      remember(search + SEARCH_TAKE_IT, SEARCH_TAKE_IT_SIZE)
      writeJump(search + SEARCH_TAKE_IT, filter, SEARCH_TAKE_IT_SIZE)

      local lineSearch = core.allocateAssembly(templates.line_search, {
        AIM_FROM_X_ADDRESS = control + C.AIM_FROM_X,
        AIM_FROM_Y_ADDRESS = control + C.AIM_FROM_Y,
        AIM_RANGE_ADDRESS = control + C.AIM_RANGE,
        AIM_SIEGE_ADDRESS = control + C.AIM_SIEGE,
        AIM_OWNER_ADDRESS = control + C.AIM_OWNER,
        AIM_MODE_ADDRESS = control + C.AIM_MODE,
        PATH_STATE_ADDRESS = readAddress(finder + FIND_PATH_STATE_OPERAND),
        SEARCH_ADDRESS = search,
        ALG_RESULT_ADDRESS = algResult,
      })
      local stands = core.allocateAssembly(templates.stands, {
        STOCKPILE = ROUTE.stockpileFlag,
        TILE_FLAGS_ADDRESS = tileFlags,
        BUILDING_TILE_ADDRESS = buildingTiles,
        WALL_FAMILY = WALL_FAMILY_FLAGS,
      })
      local recordOf = core.allocateAssembly(templates.record_of, {
        AIM_UNIT_ADDRESS = control + C.AIM_UNIT,
        UNIT_UID = unitField(UNIT_UID),
        RECORDS_ADDRESS = records,
        RECORDS_END_ADDRESS = records + RECORD_COUNT * RECORD_SIZE,
        RING_CURSOR_ADDRESS = control + C.RING_CURSOR,
        RECORD_ADDRESS = control + C.RECORD,
      })
      local newLine = core.allocateAssembly(templates.new_line, {
        AIM_OWNER_ADDRESS = control + C.AIM_OWNER,
        ROUTES_ADDRESS = control + C.ROUTES,
        ROUTE_SIZE = ROUTE.size,
        LINE_ADDRESS = lines,
        STANDS_ADDRESS = stands,
        ALG_RESULT_ADDRESS = algResult,
        ALG_TARGET_X_ADDRESS = algX,
        ALG_TARGET_Y_ADDRESS = algY,
        TICKS_ADDRESS = ticks,
        RECORD_ADDRESS = control + C.RECORD,
      })

      -- A line's route to the campfire, and its front. Without the map's rows or a search
      -- that looks the way it should, no route is ever laid out and a line whose target is
      -- down falls back on the search towards the campfire.
      local routeBuild, followRoute
      local routesOk = rowTable ~= nil and anchor ~= nil
        and guardsHold(search, ROUTE.guards, "the search's own maps")
      if routesOk then
        local routeWalk = core.allocateAssembly(templates.route_walk, {
          END_RADIUS = ROUTE.endRadius,
          CAMP_X_ADDRESS = control + C.CAMP_X,
          CAMP_Y_ADDRESS = control + C.CAMP_Y,
          MAP_LIMIT = MAP_LIMIT,
          WALK_X_ADDRESS = control + C.WALK_X,
          WALK_Y_ADDRESS = control + C.WALK_Y,
          ROW_TABLE_ADDRESS = rowTable,
          FLAG_MAP_ADDRESS = readAddress(search + ROUTE.flagMapOperand),
          ROUTE_GEN_ADDRESS = control + C.ROUTE_GEN,
          ROUTE_BEST_ADDRESS = control + C.ROUTE_BEST,
          ROUTE_X_ADDRESS = control + C.ROUTE_X,
          ROUTE_Y_ADDRESS = control + C.ROUTE_Y,
          ROUTE_FOUND_ADDRESS = control + C.ROUTE_FOUND,
          DISTANCE_MAP_ADDRESS = readAddress(search + SEARCH_DISTANCE_OPERAND),
          TILE_FLAGS_ADDRESS = tileFlags,
          WALL_FAMILY = WALL_FAMILY_FLAGS,
          STOCKPILE = ROUTE.stockpileFlag,
          WALL_OWNER_ADDRESS = readAddress(search + ROUTE.wallOwnerOperand),
          BUILDING_TILE_ADDRESS = buildingTiles,
          BUILDING_STRIDE = SEARCH_STRIDE,
          BUILDING_TYPE = (buildingBase + BUILDING_TYPE) & 0xFFFFFFFF,
          BUILDING_OWNER = (buildingBase + ROUTE.buildingOwner) & 0xFFFFFFFF,
          TYPE_LIMIT = BUILDING_TYPE_LIMIT,
          GATE_OR_TOWER_ADDRESS = readAddress(tunneler + TUNNELER_GATE_TOWER_OPERAND),
          AIM_OWNER_ADDRESS = control + C.AIM_OWNER,
          TEAMS_ADDRESS = teamTable,
          FOUND_MAX = ROUTE.found,
          ROUTE_TEMP_ADDRESS = control + C.ROUTE_TEMP,
          DIRECTIONS_ADDRESS = readAddress(walk + DAMAGE_WALK_DIRECTIONS_OPERAND),
          X_DELTAS_ADDRESS = readAddress(walk + DAMAGE_WALK_X_DELTAS_OPERAND),
          Y_DELTAS_ADDRESS = readAddress(walk + DAMAGE_WALK_Y_DELTAS_OPERAND),
          ROUTE_ENTRIES = ROUTE.entries,
          PATH_FOUND_ADDRESS = control + C.PATH_FOUND,
          PATH_MAX = ROUTE.pathMax,
          PATH_TEMP_ADDRESS = control + C.PATH_TEMP,
          PATH_OFFSET = ROUTE.pathOffset,
        })
        routeBuild = core.allocateAssembly(templates.route_build, {
          AIM_UNIT_ADDRESS = control + C.AIM_UNIT,
          ANCHOR_UNIT_ADDRESS = control + C.ANCHOR_UNIT,
          ANCHOR_ADDRESS = anchor,
          AIM_FROM_X_ADDRESS = control + C.AIM_FROM_X,
          AIM_FROM_Y_ADDRESS = control + C.AIM_FROM_Y,
          AIM_RANGE_ADDRESS = control + C.AIM_RANGE,
          CAMP_X_ADDRESS = control + C.CAMP_X,
          CAMP_Y_ADDRESS = control + C.CAMP_Y,
          ROUTE_SLACK = ROUTE.slack,
          ROUTE_REACH = ROUTE.reach,
          AIM_MODE_ADDRESS = control + C.AIM_MODE,
          SEARCHED_ADDRESS = control + C.SEARCHED,
          LINE_SEARCH_ADDRESS = lineSearch,
          PATH_STATE_ADDRESS = readAddress(finder + FIND_PATH_STATE_OPERAND),
          ROUTE_GEN_ADDRESS = control + C.ROUTE_GEN,
          ROUTE_WALK_ADDRESS = routeWalk,
          DIAGNOSTICS_ADDRESS = control + C.DIAGNOSTICS,
          REPORT_ADDRESS = report,
          REPORT_PAD_ADDRESS = reportPad,
          AIM_OWNER_ADDRESS = control + C.AIM_OWNER,
        })
        followRoute = core.allocateAssembly(templates.follow_route, {
          STANDS_ADDRESS = stands,
          TICKS_ADDRESS = ticks,
          CLAIM_TICKS = ROUTE.claimSeconds * TICKS_PER_SECOND,
          FOLLOW_AT_ADDRESS = control + C.FOLLOW_AT,
          FOLLOW_FIRST_ADDRESS = control + C.FOLLOW_FIRST,
          FOLLOW_PICK_ADDRESS = control + C.FOLLOW_PICK,
          LINE_ADDRESS = lines,
          ROUTE_SIZE = ROUTE.size,
          ROUTES_ADDRESS = control + C.ROUTES,
          PATH_OFFSET = ROUTE.pathOffset,
          PATH_STATE_ADDRESS = readAddress(finder + FIND_PATH_STATE_OPERAND),
          SEARCH_NUMBER_LIMIT = ROUTE.searchNumberLimit,
          ROUTE_GEN_ADDRESS = control + C.ROUTE_GEN,
          DISTANCE_MAP_ADDRESS = readAddress(search + SEARCH_DISTANCE_OPERAND),
          FLAG_MAP_ADDRESS = readAddress(search + ROUTE.flagMapOperand),
          ALG_RESULT_ADDRESS = algResult,
          ALG_TARGET_X_ADDRESS = algX,
          ALG_TARGET_Y_ADDRESS = algY,
        })

        -- A tunnel collapses under the first enemy fortification it comes to.
        if guardsHold(tunneler, { [ROUTE.travelHook - 2] = { 0x85, 0xC0, 0x0F, 0x84 } },
            "the tunneler's travel test") then
          local crossing = core.allocateAssembly(templates.crossing, {
            ARRIVED_ADDRESS = tunneler + TUNNELER_ARRIVED_HOOK,
            NOT_ARRIVED_ADDRESS = jumpTarget(tunneler + ROUTE.travelHook),
            ENABLED_ADDRESS = control + C.RETARGET_ENABLED,
            CURRENT_UNIT_ADDRESS = currentUnit,
            UNIT_TILE = unitField(UNIT_TILE),
            UNIT_OWNER = unitField(UNIT_OWNER),
            UNIT_X = unitField(UNIT_X),
            UNIT_Y = unitField(UNIT_Y),
            UNIT_DEST_X = unitField(UNIT_DEST_X),
            UNIT_DEST_Y = unitField(UNIT_DEST_Y),
            UNIT_DEST_TILE = unitField(UNIT_DEST_TILE),
            UNIT_UID = unitField(UNIT_UID),
            UNIT_PATH_INDEX = unitField(UNIT_PATH_INDEX),
            UNIT_PATH_LENGTH = unitField(UNIT_PATH_LENGTH),
            UNIT_MOVE_STATUS = unitField(UNIT_MOVE_STATUS),
            TILE_FLAGS_ADDRESS = tileFlags,
            WALL_FAMILY = WALL_FAMILY_FLAGS,
            STOCKPILE = ROUTE.stockpileFlag,
            WALL_OWNER_ADDRESS = readAddress(search + ROUTE.wallOwnerOperand),
            BUILDING_TILE_ADDRESS = buildingTiles,
            BUILDING_STRIDE = SEARCH_STRIDE,
            BUILDING_TYPE = (buildingBase + BUILDING_TYPE) & 0xFFFFFFFF,
            BUILDING_OWNER = (buildingBase + ROUTE.buildingOwner) & 0xFFFFFFFF,
            TYPE_LIMIT = BUILDING_TYPE_LIMIT,
            GATE_OR_TOWER_ADDRESS = readAddress(tunneler + TUNNELER_GATE_TOWER_OPERAND),
            TEAMS_ADDRESS = teamTable,
            RECORDS_ADDRESS = records,
            RECORDS_END_ADDRESS = records + RECORD_COUNT * RECORD_SIZE,
            LINE_ADDRESS = lines,
            ROUTE_SIZE = ROUTE.size,
            ROUTES_ADDRESS = control + C.ROUTES,
            TICKS_ADDRESS = ticks,
            CLAIM_TICKS = ROUTE.claimSeconds * TICKS_PER_SECOND,
          })
          remember(tunneler + ROUTE.travelHook, 6)
          writeJump(tunneler + ROUTE.travelHook, crossing, 6)
        end
      else
        routeBuild = core.allocateCode({ 0xC7, 0x06, 0x02, 0x00, 0x00, 0x00, 0xC3 })  -- state 2
        followRoute = core.allocateCode({ 0x31, 0xC0, 0xC3 })                        -- search
      end
      local lineFront = core.allocateAssembly(templates.line_front, {
        STANDS_ADDRESS = stands,
        LINE_ADDRESS = lines,
        ROUTE_SIZE = ROUTE.size,
        ROUTES_ADDRESS = control + C.ROUTES,
        ROUTE_CURRENT_ADDRESS = control + C.ROUTE_CURRENT,
        ROUTE_BUILD_ADDRESS = routeBuild,
      })
      local aimAtLine = core.allocateAssembly(templates.aim_at_line, {
        AIM_FROM_X_ADDRESS = control + C.AIM_FROM_X,
        AIM_FROM_Y_ADDRESS = control + C.AIM_FROM_Y,
        RANGE_ADDRESS = control + C.RETARGET_RANGE,
        PIN_SLACK = ROUTE.pinSlack,
        AIM_RANGE_ADDRESS = control + C.AIM_RANGE,
        AIM_PIN_ADDRESS = control + C.AIM_PIN,
        AIM_MODE_ADDRESS = control + C.AIM_MODE,
        SEARCHED_ADDRESS = control + C.SEARCHED,
        LINE_SEARCH_ADDRESS = lineSearch,
      })

      -- Laying the next leg while keeping the tunnel one piece.
      local extend = core.allocateAssembly(templates.extend_plan, {
        QUIET_ADDRESS = control + C.QUIET,
        EXTEND_FULL_ADDRESS = control + C.EXTEND_FULL,
        AIM_UNIT_ADDRESS = control + C.AIM_UNIT,
        UNIT_PATH_INDEX = unitField(UNIT_PATH_INDEX),
        UNIT_PATH_LENGTH = unitField(UNIT_PATH_LENGTH),
        UNIT_PATH_PLAN = unitField(UNIT_PATH_PLAN),
        UNIT_LADDER_X = unitField(UNIT_LADDER_X),
        UNIT_LADDER_Y = unitField(UNIT_LADDER_Y),
        UNIT_PREVIOUS_TILE = unitField(UNIT_PREVIOUS_TILE),
        UNIT_MOVE_STATUS = unitField(UNIT_MOVE_STATUS),
        SAVE_LADDER_X_ADDRESS = control + C.SAVE_LADDER_X,
        SAVE_LADDER_Y_ADDRESS = control + C.SAVE_LADDER_Y,
        SAVE_PREVIOUS_ADDRESS = control + C.SAVE_PREVIOUS,
        PLAN_BUFFER_ADDRESS = control + C.PLAN_BUFFER,
        PLAN_STEPS = PLAN_STEPS,
        ALG_TARGET_X_ADDRESS = algX,
        ALG_TARGET_Y_ADDRESS = algY,
        CURRENT_UNIT_ADDRESS = currentUnit,
        UNITS_STATE_ADDRESS = unitsState,
        SET_DESTINATION_ADDRESS = setDestination,
      })

      -- Sending a tunnel on from empty ground.
      -- The search in the cone towards the enemy's campfire.
      local aimCone = core.allocateAssembly(templates.aim_cone, {
        ANCHOR_ADDRESS = anchor or anchorStub,
        ANCHOR_UNIT_ADDRESS = control + C.ANCHOR_UNIT,
        CAMP_X_ADDRESS = control + C.CAMP_X,
        CAMP_Y_ADDRESS = control + C.CAMP_Y,
        AIM_DIR_X_ADDRESS = control + C.AIM_DIR_X,
        AIM_DIR_Y_ADDRESS = control + C.AIM_DIR_Y,
        AIM_DIR_LENGTH_ADDRESS = control + C.AIM_DIR_LENGTH,
        AIM_FROM_X_ADDRESS = control + C.AIM_FROM_X,
        AIM_FROM_Y_ADDRESS = control + C.AIM_FROM_Y,
        SEARCHED_ADDRESS = control + C.SEARCHED,
        AIM_MODE_ADDRESS = control + C.AIM_MODE,
        LINE_SEARCH_ADDRESS = lineSearch,
      })

      local redirect = core.allocateAssembly(templates.redirect, {
        SEARCHED_ADDRESS = control + C.SEARCHED,
        STEP_WINDOW = ROUTE.stepSeconds * TICKS_PER_SECOND * 4,
        EXTEND_FULL_ADDRESS = control + C.EXTEND_FULL,
        REFUSED_CURSOR_ADDRESS = control + C.REFUSED_CURSOR,
        REFUSED_TICKS = ROUTE.refusedSeconds * TICKS_PER_SECOND,
        FAIL_SPOT_ADDRESS = control + C.FAIL_SPOT,
        FAIL_UNTIL_ADDRESS = control + C.FAIL_UNTIL,
        WAIT_TICKS = ROUTE.waitSeconds * TICKS_PER_SECOND,
        LINE_ADDRESS = lines,
        ROUTE_SIZE = ROUTE.size,
        ROUTES_ADDRESS = control + C.ROUTES,
        REFUSED_ADDRESS = control + C.REFUSED,
        REFUSED_END_ADDRESS = control + C.REFUSED + ROUTE.refused * 8,
        CURRENT_UNIT_ADDRESS = currentUnit,
        AIM_UNIT_ADDRESS = control + C.AIM_UNIT,
        RECORD_OF_ADDRESS = recordOf,
        RECORD_ADDRESS = control + C.RECORD,
        REDIRECT_HOW_ADDRESS = control + C.REDIRECT_HOW,
        MAX_ADDRESS = control + C.RETARGET_MAX,
        UNIT_OWNER = unitField(UNIT_OWNER),
        UNIT_SIEGE_TARGET = unitField(UNIT_SIEGE_TARGET),
        UNIT_X = unitField(UNIT_X),
        UNIT_Y = unitField(UNIT_Y),
        UNIT_TILE = unitField(UNIT_TILE),
        AIM_OWNER_ADDRESS = control + C.AIM_OWNER,
        AIM_SIEGE_ADDRESS = control + C.AIM_SIEGE,
        RANGE_ADDRESS = control + C.RETARGET_RANGE,
        AIM_RANGE_ADDRESS = control + C.AIM_RANGE,
        AIM_FROM_X_ADDRESS = control + C.AIM_FROM_X,
        AIM_FROM_Y_ADDRESS = control + C.AIM_FROM_Y,
        TICKS_ADDRESS = ticks,
        STANDS_ADDRESS = stands,
        LINE_FRONT_ADDRESS = lineFront,
        ROUTE_CURRENT_ADDRESS = control + C.ROUTE_CURRENT,
        FOLLOW_ROUTE_ADDRESS = followRoute,
        AIM_AT_LINE_ADDRESS = aimAtLine,
        AIM_MODE_ADDRESS = control + C.AIM_MODE,
        AIM_CONE_ADDRESS = aimCone,
        LINE_SEARCH_ADDRESS = lineSearch,
        NEW_LINE_ADDRESS = newLine,
        LINE_LIFETIME = LINE_LIFETIME_SECONDS * TICKS_PER_SECOND,
        ALG_RESULT_ADDRESS = algResult,
        ALG_TARGET_X_ADDRESS = algX,
        ALG_TARGET_Y_ADDRESS = algY,
        EXTEND_ADDRESS = extend,
      })

      local arrival = core.allocateAssembly(templates.arrival, {
        FAIL_SPOT_ADDRESS = control + C.FAIL_SPOT,
        FAIL_UNTIL_ADDRESS = control + C.FAIL_UNTIL,
        UNIT_PATH_LENGTH = unitField(UNIT_PATH_LENGTH),
        CURRENT_UNIT_ADDRESS = currentUnit,
        UNIT_TILE = unitField(UNIT_TILE),
        UNIT_X = unitField(UNIT_X),
        UNIT_Y = unitField(UNIT_Y),
        UNIT_OWNER = unitField(UNIT_OWNER),
        TILE_FLAGS_ADDRESS = tileFlags,
        BUILDING_TILE_ADDRESS = buildingTiles,
        WALL_FAMILY = WALL_FAMILY_FLAGS,
        STOCKPILE = ROUTE.stockpileFlag,
        RETARGET_ENABLED_ADDRESS = control + C.RETARGET_ENABLED,
        LAST_REDIRECT_ADDRESS = control + C.LAST_REDIRECT,
        REDIRECT_ADDRESS = redirect,
        REDIRECT_HOW_ADDRESS = control + C.REDIRECT_HOW,
        RECORD_ADDRESS = control + C.RECORD,
        ALG_RESULT_ADDRESS = algResult,
        DIAGNOSTICS_ADDRESS = control + C.DIAGNOSTICS,
        REPORT_ADDRESS = report,
        REPORT_PAD_ADDRESS = reportPad,
        DENIAL_ENABLED_ADDRESS = control + C.DENIAL_ENABLED,
        DURATION_ADDRESS = control + C.DENIAL_DURATION,
        TICKS_ADDRESS = ticks,
        LAST_TICK_ADDRESS = control + C.LAST_TICK,
        ZONES_ADDRESS = zones,
        ZONES_END_ADDRESS = zones + ZONE_COUNT * ZONE_SIZE,
        STACK_RADIUS = DENIAL_STACK_RADIUS,
        STACK_SPAN = 2 * DENIAL_STACK_RADIUS,
        TAIL_ADDRESS = tunneler + TUNNELER_TAIL,
        RETURN_ADDRESS = tunneler + TUNNELER_ARRIVED_HOOK + TUNNELER_ARRIVED_HOOK_SIZE,
      })
      remember(tunneler + TUNNELER_ARRIVED_HOOK, TUNNELER_ARRIVED_HOOK_SIZE)
      writeJump(tunneler + TUNNELER_ARRIVED_HOOK, arrival, TUNNELER_ARRIVED_HOOK_SIZE)


      -- A path of ours that will not lay must not set off the game's whole-map rebuild.
      local traceFailed = scanOptional(ROUTE.traceFailed.aob, "the path trace's failure branch")
      if traceFailed ~= nil
          and guardsHold(traceFailed, ROUTE.traceFailed.guards, "the path trace's failure branch") then
        local quiet = core.allocateAssembly(templates.quiet_trace, {
          QUIET_ADDRESS = control + C.QUIET,
          PLAN_LENGTH_FIELD = readInteger(traceFailed + ROUTE.traceFailed.planLengthOperand),
          DONE_ADDRESS = traceFailed + ROUTE.traceFailed.done,
          RETURN_ADDRESS = traceFailed + ROUTE.traceFailed.hookSize,
        })
        remember(traceFailed, ROUTE.traceFailed.hookSize)
        writeJump(traceFailed, quiet, ROUTE.traceFailed.hookSize)
      end

      -- The first target: lines, over the game's own answer.
      local firstAim = core.allocateAssembly(templates.place_aim, {
        OURS_ADDRESS = control + C.OURS,
        QUIET_ADDRESS = control + C.QUIET,
        FIND_TARGET_ADDRESS = finder,
        RETARGET_ENABLED_ADDRESS = control + C.RETARGET_ENABLED,
        ALG_RESULT_ADDRESS = algResult,
        ALG_TARGET_X_ADDRESS = algX,
        ALG_TARGET_Y_ADDRESS = algY,
        GAME_TILE_ADDRESS = control + C.GAME_TILE,
        GAME_X_ADDRESS = control + C.GAME_X,
        GAME_Y_ADDRESS = control + C.GAME_Y,
        CURRENT_UNIT_ADDRESS = currentUnit,
        AIM_UNIT_ADDRESS = control + C.AIM_UNIT,
        UNIT_OWNER = unitField(UNIT_OWNER),
        UNIT_SIEGE_TARGET = unitField(UNIT_SIEGE_TARGET),
        UNIT_WORKPLACE = unitField(UNIT_WORKPLACE),
        AIM_OWNER_ADDRESS = control + C.AIM_OWNER,
        AIM_SIEGE_ADDRESS = control + C.AIM_SIEGE,
        RANGE_ADDRESS = control + C.RETARGET_RANGE,
        AIM_RANGE_ADDRESS = control + C.AIM_RANGE,
        BUILDING_STRIDE = SEARCH_STRIDE,
        BUILDING_SOME_X = (buildingBase + BUILDING_SOME_X) & 0xFFFFFFFF,
        BUILDING_SOME_Y = (buildingBase + BUILDING_SOME_Y) & 0xFFFFFFFF,
        AIM_FROM_X_ADDRESS = control + C.AIM_FROM_X,
        AIM_FROM_Y_ADDRESS = control + C.AIM_FROM_Y,
        RECORD_OF_ADDRESS = recordOf,
        RECORD_ADDRESS = control + C.RECORD,
        LINE_ADDRESS = lines,
        TICKS_ADDRESS = ticks,
        LINE_FRONT_ADDRESS = lineFront,
        AIM_AT_LINE_ADDRESS = aimAtLine,
        SEARCHED_ADDRESS = control + C.SEARCHED,
        LINE_SEARCH_ADDRESS = lineSearch,
        VANILLA_RANGE = VANILLA_RANGE,
        LINE_LIFETIME = LINE_LIFETIME_SECONDS * TICKS_PER_SECOND,
        NEW_LINE_ADDRESS = newLine,
        DIAGNOSTICS_ADDRESS = control + C.DIAGNOSTICS,
        REPORT_ADDRESS = report,
        REPORT_PAD_ADDRESS = reportPad,
        RETURN_ADDRESS = tunneler + TUNNELER_FIND_TARGET_CALL + 5,
      })
      remember(tunneler + TUNNELER_FIND_TARGET_CALL, 5)
      writeJump(tunneler + TUNNELER_FIND_TARGET_CALL, firstAim, 5)

      -- ... and the net under it, should a line's path refuse to lay.
      local net = core.allocateAssembly(templates.place_net, {
        OURS_ADDRESS = control + C.OURS,
        QUIET_ADDRESS = control + C.QUIET,
        AIM_RANGE_ADDRESS = control + C.AIM_RANGE,
        VANILLA_RANGE = VANILLA_RANGE,
        LINE_SEARCH_ADDRESS = lineSearch,
        GAME_TILE_ADDRESS = control + C.GAME_TILE,
        GAME_X_ADDRESS = control + C.GAME_X,
        GAME_Y_ADDRESS = control + C.GAME_Y,
        CURRENT_UNIT_ADDRESS = currentUnit,
        UNITS_STATE_ADDRESS = unitsState,
        SET_DESTINATION_ADDRESS = setDestination,
        DIAGNOSTICS_ADDRESS = control + C.DIAGNOSTICS,
        REPORT_ADDRESS = report,
        REPORT_PAD_ADDRESS = reportPad,
        GIVE_UP_ADDRESS = tunneler + TUNNELER_PATH_GIVE_UP,
        LAID_ADDRESS = tunneler + TUNNELER_PATH_LAID,
      })
      remember(tunneler + TUNNELER_PATH_HOOK, TUNNELER_PATH_HOOK_SIZE)
      writeJump(tunneler + TUNNELER_PATH_HOOK, net, TUNNELER_PATH_HOOK_SIZE)
      retargetReady = true

      -- The denial test itself, in the one function every placement check goes through.
      if teamSite ~= nil and enemySite ~= nil
          and guardsHold(enemySite, ENEMY_GUARDS, "the build denial check") then
        local check = core.allocateAssembly(templates.denial_check, {
          TICKS_ADDRESS = ticks,
          LAST_TICK_ADDRESS = control + C.LAST_TICK,
          ENABLED_ADDRESS = control + C.DENIAL_ENABLED,
          SCRATCH_ADDRESS = control + C.SCRATCH,
          DIAGNOSTICS_ADDRESS = control + C.DIAGNOSTICS,
          REPORT_ADDRESS = report,
          REPORT_PAD_ADDRESS = reportPad,
          LAST_REPORT_TICK_ADDRESS = control + C.LAST_REPORT_TICK,
          MINE_ADDRESS = control + C.MINE,
          MINE_TICK_ADDRESS = control + C.MINE_TICK,
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
            MINE_ADDRESS = control + C.MINE,
            MINE_TICK_ADDRESS = control + C.MINE_TICK,
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
          ENABLED_ADDRESS = control + C.TARGETS_ENABLED,
          GATE_OR_TOWER_ADDRESS = readAddress(tunneler + TUNNELER_GATE_TOWER_OPERAND),
          TYPE_LIMIT = BUILDING_TYPE_LIMIT,
          UNDER_ENABLED_ADDRESS = control + C.UNDER_BUILDINGS,
          KEEP_FIRST_TYPE = KEEP_FIRST_TYPE,
          KEEP_TYPE_SPAN = KEEP_TYPE_SPAN,
          ALLOW_ADDRESS = search + SEARCH_ALLOW,
          SKIP_ADDRESS = search + SEARCH_SKIP,
        })
        -- A tunnel may be aimed at stairs and at crenellations, not only at plain wall.
        if guardsHold(search, SEARCH_WALL_TEST_GUARD, "the search's own wall test") then
          remember(search + SEARCH_WALL_TEST_OPERAND, 4)
          core.writeCodeInteger(search + SEARCH_WALL_TEST_OPERAND, WALL_FAMILY_FLAGS)
        end

        remember(search + SEARCH_BUILDING_TEST, SEARCH_BUILDING_TEST_SIZE)
        writeJump(search + SEARCH_BUILDING_TEST, targets, SEARCH_BUILDING_TEST_SIZE)

        local accept = core.allocateAssembly(templates.tunnel_accept, {
          AIM_MODE_ADDRESS = control + C.AIM_MODE,
          CAMP_BUILDING_ADDRESS = control + C.CAMP_BUILDING,
          ENABLED_ADDRESS = control + C.TARGETS_ENABLED,
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

    -- Nothing aims at a tunneler that is underground.
    local aimReady = false
    local aimSite = scanOptional(AOB_WORTH_AIMING_AT, "the worth-aiming-at test")
    if aimSite ~= nil and unitBase ~= nil
        and guardsHold(aimSite, AIM_GUARDS, "the worth-aiming-at test") then
      local hidden = core.allocateAssembly(templates.not_a_target, {
        ENABLED_ADDRESS = control + C.HIDE_TARGET,
        UNIT_TYPE = (unitBase + UNIT_TYPE) & 0xFFFFFFFF,
        UNIT_STATE = (unitBase + UNIT_STATE) & 0xFFFFFFFF,
        TUNNELER_TYPE = UNIT_TYPE_TUNNELER,
        RETURN_ADDRESS = aimSite + AIM_HOOK + AIM_HOOK_SIZE,
      })
      remember(aimSite + AIM_HOOK, AIM_HOOK_SIZE)
      writeJump(aimSite + AIM_HOOK, hidden, AIM_HOOK_SIZE)
      aimReady = true
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
        ENABLED_ADDRESS = control + C.UI_ENABLED,
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
        ENABLED_ADDRESS = control + C.UI_ENABLED,
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
        ENABLED_ADDRESS = control + C.STANCE_ENABLED,
        CURRENT_UNIT_ADDRESS = currentUnit,
        UNIT_STATE = (unitBase + UNIT_STATE) & 0xFFFFFFFF,
        UNIT_LOOKING_AROUND = (unitBase + UNIT_LOOKING_AROUND) & 0xFFFFFFFF,
        UNIT_SELECTABLE = (unitBase + UNIT_SELECTABLE) & 0xFFFFFFFF,
        HIDE_ENABLED_ADDRESS = control + C.HIDE_SELECT,
        RETURN_ADDRESS = tunneler + 7,
      })
      remember(tunneler, 7)
      writeJump(tunneler, stance, 7)
      stanceReady = true
    end

    ---------------------------------------------------------------------------------
    -- 5. Tunnellers in AI raids
    ---------------------------------------------------------------------------------

    local raidsReady = false
    local tribeSite = scanOptional(ROUTE.raids.tribeAob, "the AI's raid troop lookup")
    local guildSite = scanOptional(ROUTE.raids.guildAob, "the AI's recruiting building test")
    if tribeSite ~= nil and guildSite ~= nil
        and guardsHold(guildSite, ROUTE.raids.guildGuards, "the AI's recruiting loop") then
      local hook = tribeSite + ROUTE.raids.tribeHook
      local tribe = core.allocateAssembly(templates.raid_tribe, {
        UNIT_TYPE_OPERAND = readInteger(hook + 3),
        ENABLED_ADDRESS = control + C.RAIDS_ENABLED,
        TUNNELER_TYPE = UNIT_TYPE_TUNNELER,
        STAND_IN_TYPE = ROUTE.raids.maceman,
        RETURN_ADDRESS = hook + 7,
        DIAGNOSTICS_ADDRESS = control + C.DIAGNOSTICS,
        REPORT_ADDRESS = report,
        REPORT_PAD_ADDRESS = reportPad,
        UNIT_SIZE = UNIT_SIZE,
      })
      local guild = core.allocateAssembly(templates.raid_no_guild, {
        ENABLED_ADDRESS = control + C.RAIDS_ENABLED,
        TUNNELER_TYPE = UNIT_TYPE_TUNNELER,
        RECRUIT_ADDRESS = guildSite + 8,
        EXIT_ADDRESS = jumpTarget(guildSite + 2),
        NEXT_ADDRESS = guildSite + ROUTE.raids.guildNext,
        DIAGNOSTICS_ADDRESS = control + C.DIAGNOSTICS,
        REPORT_ADDRESS = report,
        REPORT_PAD_ADDRESS = reportPad,
      })
      remember(hook, 7)
      writeJump(hook, tribe, 7)
      remember(guildSite, 8)
      writeJump(guildSite, guild, 8)
      raidsReady = true
    end

    if tunneler ~= nil and unitBase ~= nil then
      -- The stopwatch round every tunneller update, for the diagnostics.
      -- It calls whatever sits on the entry already - the stance hook, when that is on -
      -- or else the two instructions it replaces, so it is always the outermost.
      local body
      if (readByte(tunneler) & 0xFF) == 0xE9 then
        body = (tunneler + 5 + readInteger(tunneler + 1)) & 0xFFFFFFFF
      else
        body = core.allocateAssembly(templates.tunneler_entry, {
          FIRST_OPERAND = readAddress(tunneler + 3),
          RETURN_ADDRESS = tunneler + 7,
        })
      end
      local timed = core.allocateAssembly(templates.tunneler_timed, {
        DIAGNOSTICS_ADDRESS = control + C.DIAGNOSTICS,
        CURRENT_UNIT_ADDRESS = currentUnit,
        UNIT_STATE = (unitBase + UNIT_STATE) & 0xFFFFFFFF,
        REDIRECT_HOW_ADDRESS = control + C.REDIRECT_HOW,
        SW_TUNNEL_ADDRESS = control + C.SW_TUNNEL,
        SW_COUNT_ADDRESS = control + C.SW_COUNT,
        SW_MAX_ADDRESS = control + C.SW_MAX,
        SW_MAX_STATE_ADDRESS = control + C.SW_MAX_STATE,
        SW_MAX_UNIT_ADDRESS = control + C.SW_MAX_UNIT,
        SW_MAX_HOW_ADDRESS = control + C.SW_MAX_HOW,
        BODY_ADDRESS = body,
      })
      remember(tunneler, 7)
      writeJump(tunneler, timed, 7)
    end

    ---------------------------------------------------------------------------------

    log(INFO, string.format(
      "improved-tunnelers: build denial %s%s, tunnels %s, targets %s, collapse %s, "
      .. "buttons %s, tunnelers %s, stances %s, AI raid tunnellers %s.",
      denialReady and (denialOn and string.format("on, %d s", denialSeconds) or "off")
        or "unavailable",
      (denialReady and denialOn and messageOn)
        and (messageReady and ", with its own refusal message" or ", with the game's message")
        or "",
      retargetReady and (retargetOn and string.format(
        "gather on lines and are sent on %s up to %d times, reaching %d tiles",
        (anchor ~= nil) and ((campIds ~= nil) and "towards the enemy campfire"
          or "towards the enemy keep") or "to the nearest fortification",
        retargetMax, retargetRange)
        or "as the game digs them") or "unavailable",
      targetsReady and (targetsOn and "walls, towers and gates" or "walls only")
        .. (underOn and ", digging under the town" or "")
        .. (familyReady and ", stairs and crenellations damaged as wall is" or "")
        or "unavailable",
      collapseReady and string.format("%d damage%s", collapseDamage,
        spreadOn and string.format(" and %d within %d tiles", spreadDamage, spreadRadius)
        or "") .. string.format(", %d tiles a tick", collapseSpeed) or "unavailable",
      uiReady and (uiOn and "on" or "off") or "unavailable",
      (aimReady and untargetableOn) and "hidden while digging" or "as the game leaves them",
      stanceReady and (stancesOn and "on" or "off") or "unavailable",
      raidsReady and (raidsOn and "on" or "off") or "unavailable"))
    if diagnosticsOn then
      log(INFO, "improved-tunnelers: diagnostics are on; every tunnel dug in, every arrival "
        .. "and every building attempt near a denial writes a line to this log.")
    end
  end,

  ---Put the game's own bytes back and switch every hook that stays behind inert.
  disable = function(self, config)
    if self.control ~= nil then
      writeInteger(self.control + C.DENIAL_ENABLED, 0)
      writeInteger(self.control + C.RETARGET_ENABLED, 0)
      writeInteger(self.control + C.TARGETS_ENABLED, 0)
      writeInteger(self.control + C.UI_ENABLED, 0)
      writeInteger(self.control + C.STANCE_ENABLED, 0)
    end
    -- Newest first: two hooks on one address (the stopwatch over the stance) come off in
    -- the order they went on, and the game's own bytes are the last thing written back.
    local patched = self.patched or {}
    for index = #patched, 1, -1 do
      core.writeCodeBytes(patched[index].address, patched[index].bytes)
    end
    self.patched = {}
  end,

}
