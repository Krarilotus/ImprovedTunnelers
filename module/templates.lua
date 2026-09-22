--[[
  Improved Tunnelers - injected assembly.

  Every script is FASM source for core.allocateAssembly. Values are passed in as
  assembly-time constants, so nothing here hardcodes an address: init.lua reads them all
  out of the running executable. Comments and indentation are stripped before assembling
  (fasm.dll gets one fixed 64000 byte buffer for source, symbols and output together), so
  keep the comments here rather than in the strings.

  Register discipline: the game is MSVC, so ebx, esi, edi and ebp are preserved across a
  call and eax, ecx and edx are not. Each script below says which registers it may touch.
]]

---------------------------------------------------------------------------------------
-- Build denial: the test
---------------------------------------------------------------------------------------
-- Hooked into PathFindingState::isEnemyTooCloseUnk(player, x, y, range), five bytes past
-- the coordinate validation, where EDX holds x, ESI holds y and the function's own ESI is
-- already on the stack. The zone list is checked first; a hit returns 1 the same way the
-- function returns 1 for an enemy unit, so every caller - the build cursor, the player's
-- placement, the AI's placement, the wall path, the delete tool - refuses the spot
-- without knowing anything new.
--
-- The zone list is 16 bytes per entry: x, y, owner, expiry tick (0 = free). A zone only
-- blocks players on another team than the one who dug the tunnel, which is the same test
-- the game itself uses to decide whether a unit is an enemy, so a zone never gets in the
-- way of its owner or its owner's allies.
--
-- Loading a save or starting a new game moves the tick counter backwards; when that
-- happens the whole list is dropped rather than left to expire against a clock that no
-- longer applies.
local denial_check = [[
push ebx
push ebp
push edi
mov eax, [TICKS_ADDRESS]
cmp eax, [LAST_TICK_ADDRESS]
jae keep_zones
mov ecx, ZONES_ADDRESS
clear_loop:
mov dword [ecx+12], 0
add ecx, 16
cmp ecx, ZONES_END_ADDRESS
jb clear_loop
keep_zones:
mov [LAST_TICK_ADDRESS], eax
mov dword [MINE_ADDRESS], 0
cmp dword [ENABLED_ADDRESS], 0
je no_hit
mov ebp, [esp+20]
mov ebp, [ebp*4+TEAMS_ADDRESS]
mov ecx, [esp+32]
imul ecx, ecx
mov edi, [esp+28]
mov ebx, ZONES_ADDRESS
zone_loop:
cmp ebx, ZONES_END_ADDRESS
jae no_hit
mov edx, [ebx+12]
test edx, edx
je zone_next
cmp eax, edx
jae zone_next
mov edx, [esp+24]
sub edx, [ebx]
imul edx, edx
mov [SCRATCH_ADDRESS], edx
mov edx, edi
sub edx, [ebx+4]
imul edx, edx
add edx, [SCRATCH_ADDRESS]
mov [SCRATCH_ADDRESS], edx
cmp edx, 400
ja zone_next
mov edx, [ebx+8]
cmp edx, [esp+20]
je zone_same_team
mov edx, [edx*4+TEAMS_ADDRESS]
cmp edx, ebp
jne zone_enemy
test ebp, ebp
jnz zone_same_team
zone_enemy:
mov edx, [SCRATCH_ADDRESS]
cmp edx, ecx
jb zone_hit
zone_same_team:
cmp dword [DIAGNOSTICS_ADDRESS], 0
je zone_next
mov edx, eax
sub edx, [LAST_REPORT_TICK_ADDRESS]
cmp edx, REPORT_GAP
jb zone_next
mov [LAST_REPORT_TICK_ADDRESS], eax
mov edx, [esp+20]
mov [REPORT_ADDRESS], edx
mov edx, [esp+24]
mov [REPORT_ADDRESS+4], edx
mov [REPORT_ADDRESS+8], edi
mov edx, [esp+32]
mov [REPORT_ADDRESS+12], edx
mov edx, [ebx]
mov [REPORT_ADDRESS+16], edx
mov edx, [ebx+4]
mov [REPORT_ADDRESS+20], edx
mov edx, [ebx+8]
mov [REPORT_ADDRESS+24], edx
mov [REPORT_ADDRESS+32], ebp
mov edx, [SCRATCH_ADDRESS]
mov [REPORT_ADDRESS+36], edx
mov dword [REPORT_ADDRESS+28], 20
call REPORT_PAD_ADDRESS
zone_next:
add ebx, 16
jmp zone_loop
zone_hit:
mov dword [MINE_ADDRESS], 1
mov [MINE_TICK_ADDRESS], eax
cmp dword [DIAGNOSTICS_ADDRESS], 0
je zone_hit_quiet
mov edx, eax
sub edx, [LAST_REPORT_TICK_ADDRESS]
cmp edx, REPORT_GAP
jb zone_hit_quiet
mov [LAST_REPORT_TICK_ADDRESS], eax
mov edx, [esp+20]
mov [REPORT_ADDRESS], edx
mov edx, [esp+24]
mov [REPORT_ADDRESS+4], edx
mov [REPORT_ADDRESS+8], edi
mov edx, [esp+32]
mov [REPORT_ADDRESS+12], edx
mov edx, [ebx]
mov [REPORT_ADDRESS+16], edx
mov edx, [ebx+4]
mov [REPORT_ADDRESS+20], edx
mov edx, [ebx+8]
mov [REPORT_ADDRESS+24], edx
mov [REPORT_ADDRESS+32], ebp
mov edx, [SCRATCH_ADDRESS]
mov [REPORT_ADDRESS+36], edx
mov dword [REPORT_ADDRESS+28], 21
call REPORT_PAD_ADDRESS
zone_hit_quiet:
pop edi
pop ebp
pop ebx
pop esi
mov eax, 1
ret 16
no_hit:
pop edi
pop ebp
pop ebx
mov eax, [esp+20]
push ebx
jmp RETURN_ADDRESS
]]

---------------------------------------------------------------------------------------
-- Sending a tunnel at another target
---------------------------------------------------------------------------------------
-- The one place that changes a tunnel's aim, called from both hooks below. It runs the
-- game's own tunnel target search from wherever the tunneler is standing and, when the
-- search finds something, gives it a new destination with the game's own path finder. The
-- tunneler stays in its digging state and simply carries on from where it is: nothing is
-- teleported back to the entrance and no state is invented, so the tunnel is one
-- continuous tunnel that bends towards the new target.
--
-- Each tunneler may only do this so many times, counted in a small ring of {uid, count}.
-- A search that finds nothing does not count against it.
--
-- Returns 1 when the tunnel was sent somewhere new, 2 when the tunneler has used up its
-- re-aims, and 0 when there was nothing to go to. Only EAX, ECX and EDX are touched, and
-- the game's own functions preserve the rest.
local reaim = [[
mov eax, [UNIT_ADDRESS]
imul eax, eax, 1168
mov [SCALED_ADDRESS], eax
call FIND_RECORD_ADDRESS
test eax, eax
jne reaim_budget_left
mov eax, 2
ret
reaim_budget_left:
mov eax, [SCALED_ADDRESS]
mov dword [BEST_TILE_ADDRESS], 0
mov dword [ROUNDS_ADDRESS], 0
mov dword [BIAS_ACTIVE_ADDRESS], 0
mov dword [DEPTH_LIMIT_ADDRESS], 0
mov dword [PINNED_TILE_ADDRESS], 0
mov dword [SHARED_SLOT_ADDRESS], 0
cmp dword [TOWARDS_ENABLED_ADDRESS], 0
je reaim_search
mov [ANCHOR_UNIT_ADDRESS], eax
call ANCHOR_ADDRESS
mov eax, [SCALED_ADDRESS]
cmp dword [ANCHOR_BEST_ADDRESS], -1
je reaim_search
movsx edx, word [eax+UNIT_X]
sub edx, [CAMP_X_ADDRESS]
imul edx, edx
mov [ORIGIN_DISTANCE_ADDRESS], edx
movsx edx, word [eax+UNIT_Y]
sub edx, [CAMP_Y_ADDRESS]
imul edx, edx
add [ORIGIN_DISTANCE_ADDRESS], edx
mov dword [BIAS_ACTIVE_ADDRESS], 1
movsx ecx, word [eax+UNIT_OWNER]
mov [BREACH_OWNER_ADDRESS], ecx
movsx ecx, word [eax+UNIT_X]
mov [BREACH_X_ADDRESS], ecx
movsx ecx, word [eax+UNIT_Y]
mov [BREACH_Y_ADDRESS], ecx
call BREACH_ADDRESS
mov ecx, [SHARED_SLOT_ADDRESS]
test ecx, ecx
je reaim_no_mark
mov ecx, [ecx+16]
test ecx, ecx
je reaim_no_mark
cmp ecx, [ORIGIN_DISTANCE_ADDRESS]
jae reaim_no_mark
mov [ORIGIN_DISTANCE_ADDRESS], ecx
reaim_no_mark:
mov eax, [SCALED_ADDRESS]
reaim_search:
movsx ecx, word [eax+UNIT_Y]
push ecx
movsx ecx, word [eax+UNIT_X]
push ecx
push dword [RANGE_ADDRESS]
movsx ecx, word [eax+UNIT_SIEGE_TARGET]
push ecx
movsx ecx, word [eax+UNIT_OWNER]
push ecx
mov ecx, PATH_STATE_ADDRESS
call SEARCH_ADDRESS
cmp dword [ALG_RESULT_ADDRESS], 0
jne reaim_round_found
cmp dword [PINNED_TILE_ADDRESS], 0
je reaim_free_miss
mov dword [PINNED_TILE_ADDRESS], 0
mov eax, [SCALED_ADDRESS]
jmp reaim_search
reaim_free_miss:
cmp dword [BEST_TILE_ADDRESS], 0
jne reaim_has_target
cmp dword [BIAS_ACTIVE_ADDRESS], 0
je reaim_nothing
mov dword [BIAS_ACTIVE_ADDRESS], 0
mov eax, [SCALED_ADDRESS]
jmp reaim_search
reaim_round_found:
mov ecx, [ALG_RESULT_ADDRESS]
mov [BEST_TILE_ADDRESS], ecx
mov ecx, [ALG_TARGET_X_ADDRESS]
mov [BEST_X_ADDRESS], ecx
mov ecx, [ALG_TARGET_Y_ADDRESS]
mov [BEST_Y_ADDRESS], ecx
cmp dword [PINNED_TILE_ADDRESS], 0
je reaim_round_free
mov dword [PINNED_TILE_ADDRESS], 0
jmp reaim_has_target
reaim_round_free:
cmp dword [BIAS_ACTIVE_ADDRESS], 0
je reaim_has_target
cmp dword [DEPTH_LIMIT_ADDRESS], 0
jne reaim_depth_set
mov edx, [BEST_TILE_ADDRESS]
movsx edx, word [edx*2+DISTANCE_MAP_ADDRESS]
add edx, DEPTH_SLACK
mov [DEPTH_LIMIT_ADDRESS], edx
reaim_depth_set:
mov ecx, [BEST_X_ADDRESS]
sub ecx, [CAMP_X_ADDRESS]
imul ecx, ecx
mov edx, [BEST_Y_ADDRESS]
sub edx, [CAMP_Y_ADDRESS]
imul edx, edx
add ecx, edx
mov [ORIGIN_DISTANCE_ADDRESS], ecx
add dword [ROUNDS_ADDRESS], 1
mov ecx, [ROUNDS_ADDRESS]
cmp ecx, SEARCH_ROUNDS
jae reaim_has_target
mov eax, [SCALED_ADDRESS]
jmp reaim_search
reaim_has_target:
mov dword [BIAS_ACTIVE_ADDRESS], 0
mov dword [DEPTH_LIMIT_ADDRESS], 0
mov dword [PINNED_TILE_ADDRESS], 0
mov ecx, [SHARED_SLOT_ADDRESS]
test ecx, ecx
je reaim_told_nobody
cmp dword [ecx], 0
jne reaim_told_nobody
mov edx, [BEST_TILE_ADDRESS]
mov [ecx], edx
mov edx, [BEST_X_ADDRESS]
mov [ecx+4], edx
mov edx, [BEST_Y_ADDRESS]
mov [ecx+8], edx
mov edx, [TICKS_ADDRESS]
mov [ecx+12], edx
reaim_told_nobody:
mov eax, [SCALED_ADDRESS]
movzx ecx, word [eax+UNIT_PATH_INDEX]
mov word [eax+UNIT_PATH_LENGTH], cx
mov ecx, 1
cmp dword [ARRIVED_ADDRESS], 0
je reaim_fill
cmp dword [COLLAPSE_BEHIND_ADDRESS], 0
je reaim_fill
movsx ecx, word [eax+UNIT_OWNER]
shl ecx, 8
reaim_fill:
mov [FILL_FLAGS_ADDRESS], ecx
mov ecx, [UNIT_ADDRESS]
mov [FILL_UNIT_ADDRESS], ecx
call FILL_ADDRESS
push 2
push dword [BEST_Y_ADDRESS]
push dword [BEST_X_ADDRESS]
push dword [UNIT_ADDRESS]
mov ecx, UNITS_STATE_ADDRESS
call SET_DESTINATION_ADDRESS
test eax, eax
je reaim_nothing
mov ecx, [RECORD_ADDRESS]
add dword [ecx+4], 1
mov eax, 1
ret
reaim_nothing:
mov dword [BIAS_ACTIVE_ADDRESS], 0
mov dword [DEPTH_LIMIT_ADDRESS], 0
mov dword [PINNED_TILE_ADDRESS], 0
xor eax, eax
ret
]]

---------------------------------------------------------------------------------------
-- A tunnel reaching the end of its tunnel
---------------------------------------------------------------------------------------
-- Hooked in UpdateTunneler where the dig has reached its destination and the game is about
-- to switch the tunneler into its collapse. Two things happen here.
--
-- If something is standing on the tile - a wall, a gate, a tower, any building - the
-- collapse goes ahead as usual, and this is the moment a build denial is recorded, because
-- it is the last moment the target is certainly still there: the collapse's own damage
-- ticks can take a weak wall down before the destroying tick. A second collapse at the same
-- breach does not take a second zone, it adds its time to the one already standing there.
--
-- If the tile is empty - the wall was taken while this tunnel was still digging - the tunnel
-- is sent at another target from where it stands and the function returns without
-- collapsing anything, so the tunneler digs straight on.
local arrival = [[
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
mov ecx, [eax+UNIT_TILE]
mov edx, [CURRENT_UNIT_ADDRESS]
mov [REPORT_ADDRESS], edx
mov [REPORT_ADDRESS+4], ecx
mov edx, [ecx*4+TILE_FLAGS_ADDRESS]
mov [REPORT_ADDRESS+8], edx
test edx, 256
jnz arrived_on_something
movzx edx, word [ecx*2+BUILDING_TILE_ADDRESS]
mov [REPORT_ADDRESS+12], edx
test dx, dx
jnz arrived_on_something
cmp dword [RETARGET_ENABLED_ADDRESS], 0
je arrive_quiet
mov edx, [CURRENT_UNIT_ADDRESS]
mov [REAIM_UNIT_ADDRESS], edx
mov dword [REAIM_ARRIVED_ADDRESS], 1
call REAIM_ADDRESS
cmp eax, 2
je arrive_used_up
test eax, eax
je arrive_found_nothing
mov dword [REPORT_ADDRESS+28], 7
cmp dword [DIAGNOSTICS_ADDRESS], 0
je dig_on
call REPORT_PAD_ADDRESS
dig_on:
jmp TAIL_ADDRESS
arrive_used_up:
mov dword [REPORT_ADDRESS+28], 6
jmp arrive_report
arrive_found_nothing:
mov dword [REPORT_ADDRESS+28], 9
jmp arrive_report
arrived_on_something:
cmp dword [DENIAL_ENABLED_ADDRESS], 0
je arrive_quiet
cmp dword [DURATION_ADDRESS], 0
jle arrive_quiet
push ebx
mov ebx, [CURRENT_UNIT_ADDRESS]
imul ebx, ebx, 1168
mov eax, [TICKS_ADDRESS]
mov [REPORT_ADDRESS+16], eax
cmp eax, [LAST_TICK_ADDRESS]
jae deny_keep
mov ecx, ZONES_ADDRESS
deny_clear:
mov dword [ecx+12], 0
add ecx, 16
cmp ecx, ZONES_END_ADDRESS
jb deny_clear
deny_keep:
mov [LAST_TICK_ADDRESS], eax
mov ecx, ZONES_ADDRESS
deny_stack:
mov edx, [ecx+12]
test edx, edx
je deny_stack_next
cmp eax, edx
jae deny_stack_next
movsx edx, word [ebx+UNIT_OWNER]
cmp edx, [ecx+8]
jne deny_stack_next
movsx edx, word [ebx+UNIT_X]
sub edx, [ecx]
add edx, STACK_RADIUS
cmp edx, STACK_SPAN
ja deny_stack_next
movsx edx, word [ebx+UNIT_Y]
sub edx, [ecx+4]
add edx, STACK_RADIUS
cmp edx, STACK_SPAN
ja deny_stack_next
mov edx, [DURATION_ADDRESS]
add [ecx+12], edx
mov edx, [ecx]
mov [REPORT_ADDRESS+20], edx
mov edx, [ecx+4]
mov [REPORT_ADDRESS+24], edx
movsx edx, word [ebx+UNIT_OWNER]
mov [REPORT_ADDRESS], edx
mov edx, [ecx+12]
mov [REPORT_ADDRESS+32], edx
mov dword [REPORT_ADDRESS+28], 13
pop ebx
jmp arrive_report
deny_stack_next:
add ecx, 16
cmp ecx, ZONES_END_ADDRESS
jb deny_stack
mov ecx, ZONES_ADDRESS
deny_find:
mov edx, [ecx+12]
test edx, edx
je deny_found
cmp eax, edx
jae deny_found
add ecx, 16
cmp ecx, ZONES_END_ADDRESS
jb deny_find
mov dword [REPORT_ADDRESS+28], 11
pop ebx
jmp arrive_report
deny_found:
movsx edx, word [ebx+UNIT_X]
mov [ecx], edx
mov [REPORT_ADDRESS+20], edx
movsx edx, word [ebx+UNIT_Y]
mov [ecx+4], edx
mov [REPORT_ADDRESS+24], edx
movsx edx, word [ebx+UNIT_OWNER]
mov [ecx+8], edx
mov [REPORT_ADDRESS], edx
mov edx, [DURATION_ADDRESS]
add edx, eax
mov [ecx+12], edx
mov [REPORT_ADDRESS+32], edx
mov dword [REPORT_ADDRESS+28], 12
pop ebx
arrive_report:
cmp dword [DIAGNOSTICS_ADDRESS], 0
je arrive_quiet
call REPORT_PAD_ADDRESS
arrive_quiet:
mov eax, [CURRENT_UNIT_ADDRESS]
jmp RETURN_ADDRESS
]]

---------------------------------------------------------------------------------------
-- ... and every other tunnel of that player, the moment one collapses
---------------------------------------------------------------------------------------
-- Hooked at the end of the collapse, once the building that stood over the tunnel has been
-- destroyed. Every other tunneler of the same player digging towards that same spot has
-- just lost its target, and this is where they hear about it: each is sent at another
-- target from where it is, instead of digging on to a wall that is no longer there and
-- collapsing under nothing.
--
-- The scan is the game's own: unit slots 1 up to the live unit count, skipping everything
-- that is not a living tunneler of that player in its digging state. It runs once per
-- collapse, so walking the slots costs nothing.
local collapse_scan = [[
pushad
cmp dword [RETARGET_ENABLED_ADDRESS], 0
je scan_done
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
movsx ebp, word [eax+UNIT_OWNER]
movsx esi, word [eax+UNIT_X]
movsx edi, word [eax+UNIT_Y]
mov dword [REAIM_COUNT_ADDRESS], 0
mov ebx, 1
scan_loop:
mov eax, [UNIT_COUNT_ADDRESS]
cmp ebx, eax
jge scan_report
mov eax, ebx
imul eax, eax, 1168
cmp word [eax+UNIT_LOGICAL_STATE], LOGICAL_ALIVE
jne scan_next
cmp word [eax+UNIT_DYING], 0
jne scan_next
cmp word [eax+UNIT_TYPE], TUNNELER_TYPE
jne scan_next
cmp word [eax+UNIT_STATE], DIGGING_STATE
jne scan_next
movsx edx, word [eax+UNIT_OWNER]
cmp edx, ebp
jne scan_next
mov edx, [eax+UNIT_DEST_TILE]
test dword [edx*4+TILE_FLAGS_ADDRESS], 256
jnz scan_next
cmp word [edx*2+BUILDING_TILE_ADDRESS], 0
jne scan_next
mov ecx, ebx
mov eax, ebx
shr eax, 3
and ecx, 7
mov edx, 1
shl edx, cl
or byte [eax+PENDING_ADDRESS], dl
add dword [REAIM_COUNT_ADDRESS], 1
scan_next:
add ebx, 1
jmp scan_loop
scan_report:
cmp dword [DIAGNOSTICS_ADDRESS], 0
je scan_done
cmp dword [REAIM_COUNT_ADDRESS], 0
je scan_done
mov [REPORT_ADDRESS], ebp
mov [REPORT_ADDRESS+20], esi
mov [REPORT_ADDRESS+24], edi
mov eax, [REAIM_COUNT_ADDRESS]
mov [REPORT_ADDRESS+32], eax
mov dword [REPORT_ADDRESS+28], 8
call REPORT_PAD_ADDRESS
scan_done:
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
mov [ANCHOR_UNIT_ADDRESS], eax
call ANCHOR_ADDRESS
cmp dword [ANCHOR_BEST_ADDRESS], -1
je scan_no_mark
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
movsx ecx, word [eax+UNIT_OWNER]
shl ecx, 5
add ecx, SHARED_ADDRESS
movsx edx, word [eax+UNIT_X]
sub edx, [CAMP_X_ADDRESS]
imul edx, edx
mov [SCRATCH_ADDRESS], edx
movsx edx, word [eax+UNIT_Y]
sub edx, [CAMP_Y_ADDRESS]
imul edx, edx
add edx, [SCRATCH_ADDRESS]
cmp dword [ecx+16], 0
je scan_set_mark
cmp edx, [ecx+16]
jae scan_no_mark
scan_set_mark:
mov [ecx+16], edx
scan_no_mark:
popad
mov eax, [CURRENT_UNIT_ADDRESS]
jmp RETURN_ADDRESS
]]
---------------------------------------------------------------------------------------
-- What a tunnel is allowed to aim at
---------------------------------------------------------------------------------------
-- Hooked into the game's tunnel target search, at the test that decides which tiles the
-- search may spread into. In the unmodified game a tile with a building on it is only
-- entered when that building is one of the three small towers, so a tunnel can only ever
-- be aimed at a wall or at those - a gatehouse, a square tower or a round tower is never
-- a target, because the search stops at the tile in front of it.
--
-- With this on, the test asks the game's own "is this a gate or a tower" table instead,
-- which covers both gatehouses, the wooden gate and all five towers. Nothing else about
-- the search changes: the first enemy wall, gate or tower it reaches is the target, and
-- the collapse takes whatever building stands on the tile it arrives under.
--
-- EDX holds the building type here and is the search's scratch register; everything else
-- the loop is using is left alone.
-- Hooked where the placement handler has decided it cannot build and is about to put the
-- reason up in the bottom left corner. The game looks its message up as text group 0x4D
-- entry <reason code>, so when the refusal was this module's own denial zone - and from
-- this very tick, never a stale one - the entry number is swapped for the one the module
-- wrote its own line into. Everything else about the refusal is untouched, including the
-- reason code itself, so the lord still says what he always says.
--
-- EAX carries the entry number and is meant to be changed here; ECX is loaded with the
-- display's address two instructions later, so it is free.
local placement_message = [[
cmp dword [MINE_ADDRESS], 0
je message_vanilla
mov ecx, [TICKS_ADDRESS]
cmp ecx, [MINE_TICK_ADDRESS]
jne message_vanilla
mov eax, MESSAGE_ENTRY
message_vanilla:
push 6000
jmp RETURN_ADDRESS
]]

-- ... and the same list again, where the search decides a tile it has reached IS the
-- target. The two are separate tests in the game: the one below picks which tiles the
-- search may spread into, this one picks which of the tiles it reaches count as something
-- to dig at, and in the unmodified game that is any enemy building at all. It never showed,
-- because the only building tiles the search could reach were the three small towers - but
-- a search that starts under the enemy's town, which is exactly where a tunnel being turned
-- aside starts, reaches an ordinary house on its first step and digs at that. So the type
-- has to be checked here too: a wall is accepted further up and never reaches this code, a
-- gate or a tower is handed back to the game's own owner and team test, and anything else
-- is left behind and the search spreads on past it.
--
-- EAX holds the building id on entry and the game wants it multiplied out by the building
-- size, which is the instruction this replaces; EDX is free here.
-- What a collapse does to the thing it arrived under. A wall, a gate or a tower takes the
-- damage figure from the settings through the game's own damage, which for a wall means its
-- height comes down by that much and it is gone once that reaches the ground.
--
-- Stairs and crenellations are a different matter. They live in the same flag layer as a
-- wall (0x100 a wall, 0x200 a crenellation, 0x800 stairs - the set the game's own
-- destroyWall clears), but the damage routine only knows what to do with the wall bit and
-- quietly does nothing for the other two. So a tile that is stairs or crenellation and
-- nothing else is taken away with the game's own resetTileToDefaultState, which is what the
-- unmodified game itself calls when a tunnel comes up under something that is not a
-- building. The game demolishes it outright,
-- whatever it is; this hands it the module's damage figure through the game's own damage
-- function instead, which is what a catapult stone or a fire arrow goes through. Walls and
-- weak gates still come down in one tunnel, a square tower or a large gatehouse only if the
-- figure is set high enough - and whatever survives keeps the damage, so the next tunnel
-- finishes it.
--
-- Replaces the read of the unit's tile that the demolition branch starts with. EBX must
-- stay zero for the instructions after this, which the game's own functions see to.
local collapse_target = [[
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
mov ecx, [eax+UNIT_TILE]
test dword [ecx*4+TILE_FLAGS_ADDRESS], 256
jnz collapse_damage
test dword [ecx*4+TILE_FLAGS_ADDRESS], WALL_FAMILY
jz collapse_damage
cmp word [ecx*2+BUILDING_TILE_ADDRESS], 0
jne collapse_damage
movsx edx, word [eax+UNIT_Y]
push edx
movsx edx, word [eax+UNIT_X]
push edx
push ecx
mov ecx, TILE_MAP_STATE_ADDRESS
call RESET_TILE_ADDRESS
jmp collapse_taken
collapse_damage:
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
push 0
push 0
movsx ecx, word [eax+UNIT_OWNER]
push ecx
push 0
push dword [DAMAGE_ADDRESS]
movsx ecx, word [eax+UNIT_Y]
push ecx
movsx ecx, word [eax+UNIT_X]
push ecx
push dword [eax+UNIT_TILE]
mov ecx, TILE_MAP_STATE_ADDRESS
call PROCESS_DAMAGE_ADDRESS
collapse_taken:
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
movsx ecx, word [eax+UNIT_OWNER]
shl ecx, 8
mov [FILL_FLAGS_ADDRESS], ecx
mov ecx, [CURRENT_UNIT_ADDRESS]
mov [FILL_UNIT_ADDRESS], ecx
call FILL_ADDRESS
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
mov word [eax+UNIT_PATH_LENGTH], 0
jmp RETURN_ADDRESS
]]

---------------------------------------------------------------------------------------
-- A tunnel falling in
---------------------------------------------------------------------------------------
-- The game brings a whole tunnel down in the one frame the tunneler reaches its target:
-- every tile damaged and every tile's ground lowered at once. That is a visible stutter on
-- a long tunnel, and it looks like nothing in particular. These three scripts take the
-- tunnel apart a few tiles at a time instead, starting at the target and running back to
-- the entrance.
--
-- The first walks a tunneler's path plan and writes each tile into a queue: where it is,
-- and who is bringing it down. Nothing else happens here, so a collapse costs no more than
-- a few dozen writes.
-- Which camp a tunnel is working towards. A tunneler sent out with an attack wave carries
-- the player it was sent against, and that player's campground - where their peasants
-- gather - is the answer. A tunneler the player dug in by hand carries nobody: the game
-- reads that as "any enemy will do" and aims at whatever wall is nearest, and the old
-- lookup here gave up on it entirely, which is why those tunnels converged on nothing.
-- So when there is no player named, every player who is neither us nor an ally is
-- considered and the nearest of their camps taken. A player with no campground - razed,
-- or a map that never gave them one - is measured by their keep instead.
--
-- In: the scaled unit, at ANCHOR_UNIT. Out: EAX 1 with the camp written into CAMP_X and
-- CAMP_Y, or EAX 0 if there is nothing to aim at.
-- The game paths the tunneler to its target the moment the aim is taken, and if that path
-- cannot be laid it does not try anything else: it destroys the tunnel entrance on the spot
-- (the "give up" call three instructions along). The search and the path finder do not always
-- agree - the search spreads through tiles the path finder will not tunnel through - so a
-- target this module picked could cost the player the entrance where the game's own nearest
-- one would have worked.
--
-- So when the path will not lay and the target was one of ours, the frame is abandoned through
-- the game's own "nothing to do this tick" exit - the same one it takes when its search finds
-- nothing at all, which leaves the tunneler and its entrance exactly as they were. The tunnel
-- is noted, and the next time the game aims that tunneler this module keeps out of it, so the
-- game's own choice is used and the tunnel gets under way. Nothing is redirected mid-frame and
-- no entrance is lost that the unmodified game would have kept. A path the game itself could
-- not lay is still the game's own business, and it gives up exactly as it always did.
local path_check = [[
test eax, eax
jne path_laid
cmp dword [OURS_ADDRESS], 0
je path_give_up
mov dword [OURS_ADDRESS], 0
mov eax, [CURRENT_UNIT_ADDRESS]
add eax, 1
mov [SKIP_UNIT_ADDRESS], eax
cmp dword [DIAGNOSTICS_ADDRESS], 0
je path_wait
mov eax, [CURRENT_UNIT_ADDRESS]
mov [REPORT_ADDRESS], eax
mov eax, [ALG_RESULT_ADDRESS]
mov [REPORT_ADDRESS+4], eax
mov dword [REPORT_ADDRESS+28], 31
call REPORT_PAD_ADDRESS
path_wait:
jmp NOTHING_TODAY_ADDRESS
path_laid:
jmp RETURN_ADDRESS
path_give_up:
jmp GIVE_UP_ADDRESS
]]

-- The breach a player's tunnels are working at, looked up for whichever tunnel is being
-- aimed. Hand it the player and the spot the digging starts from; it answers by writing
-- down the slot (so the caller can record a new breach in it) and, when the breach is worth
-- joining, the tile to search for and nothing else.
--
-- Beside the breach itself each player keeps a mark: how close to their enemy's camp their
-- tunnels have already got. Every aim has to beat that mark, so once the outer wall is open
-- the next tunnel looks past it rather than taking the next piece of the same wall sideways,
-- and the breaches work their way in towards the camp. The mark only ever moves inwards, it
-- is set when a tunnel actually collapses on something rather than when one is merely aimed,
-- and it is dropped along with the breach when that is given up. When nothing beats the mark
-- the aim falls back to the nearest target as always, so a tunnel is never left with nothing
-- to do.
--
-- A breach is worth joining while something still stands on it, while it is not older than
-- its life, and while it is close by. "Close" is its own short figure, not the range the
-- search may reach: a tunnel will happily dig eighty tiles to find a target, but it should
-- never be dragged eighty tiles sideways to join somebody else's breach when there is a
-- castle wall in front of it. A breach further off than this belongs to the tunnels over
-- there; this one digs at whatever it finds for itself.
-- The age test also throws away a breach left over from an earlier match, since the tick
-- counter starts again and the subtraction runs wide.
-- How many times this tunnel has already been turned aside. The count lives in a small
-- ring of records kept by unit id - a tunneler that dies frees its slot to whoever takes it
-- next - and this finds or starts the one for the tunnel being re-aimed. EAX comes back 0
-- when the tunnel has used up its allowance and may not be turned aside again.
local find_record = [[
mov eax, [SCALED_ADDRESS]
mov edx, [eax+UNIT_UID]
mov ecx, RECORDS_ADDRESS
record_look:
cmp dword [ecx], edx
je record_have
add ecx, 8
cmp ecx, RECORDS_END_ADDRESS
jb record_look
mov ecx, [RING_CURSOR_ADDRESS]
mov [ecx], edx
mov dword [ecx+4], 0
add dword [RING_CURSOR_ADDRESS], 8
mov edx, [RING_CURSOR_ADDRESS]
cmp edx, RECORDS_END_ADDRESS
jb record_have
mov dword [RING_CURSOR_ADDRESS], RECORDS_ADDRESS
record_have:
mov [RECORD_ADDRESS], ecx
mov edx, [ecx+4]
cmp edx, [MAX_RETARGETS_ADDRESS]
jb record_room_left
xor eax, eax
ret
record_room_left:
mov eax, 1
ret
]]

local find_breach = [[
mov ecx, [BREACH_OWNER_ADDRESS]
shl ecx, 5
add ecx, SHARED_ADDRESS
mov [SHARED_SLOT_ADDRESS], ecx
mov dword [PINNED_TILE_ADDRESS], 0
mov edx, [ecx]
test edx, edx
jle breach_done
mov eax, [TICKS_ADDRESS]
sub eax, [ecx+12]
cmp eax, BREACH_LIFETIME
ja breach_gone
test dword [edx*4+TILE_FLAGS_ADDRESS], 256
jnz breach_stands
cmp word [edx*2+BUILDING_TILE_ADDRESS], 0
jne breach_stands
breach_gone:
mov dword [ecx], 0
mov dword [ecx+16], 0
jmp breach_done
breach_stands:
mov [PIN_SCRATCH_ADDRESS], edx
mov eax, [BREACH_X_ADDRESS]
sub eax, [ecx+4]
imul eax, eax
mov edx, eax
mov eax, [BREACH_Y_ADDRESS]
sub eax, [ecx+8]
imul eax, eax
add eax, edx
cmp eax, [BREACH_REACH_ADDRESS]
ja breach_done
mov edx, [PIN_SCRATCH_ADDRESS]
mov [PINNED_TILE_ADDRESS], edx
breach_done:
ret
]]

local find_anchor = [[
mov dword [ANCHOR_BEST_ADDRESS], -1
mov eax, [ANCHOR_UNIT_ADDRESS]
movsx ecx, word [eax+UNIT_SIEGE_TARGET]
test ecx, ecx
jle anchor_every_player
mov [ANCHOR_FROM_ADDRESS], ecx
mov [ANCHOR_TO_ADDRESS], ecx
jmp anchor_loop
anchor_every_player:
mov dword [ANCHOR_FROM_ADDRESS], 1
mov dword [ANCHOR_TO_ADDRESS], PLAYER_COUNT
anchor_loop:
mov ecx, [ANCHOR_FROM_ADDRESS]
mov eax, [ANCHOR_UNIT_ADDRESS]
movsx edx, word [eax+UNIT_OWNER]
cmp edx, ecx
je anchor_next
mov edx, [edx*4+TEAMS_ADDRESS]
test edx, edx
je anchor_enemy
cmp edx, [ecx*4+TEAMS_ADDRESS]
je anchor_next
anchor_enemy:
imul ecx, ecx, PLAYER_STRIDE
mov edx, [ecx+CAMP_IDS_ADDRESS]
test edx, edx
jg anchor_found
mov edx, [ecx+KEEP_IDS_ADDRESS]
test edx, edx
jle anchor_next
anchor_found:
imul edx, edx, BUILDING_STRIDE
movsx ecx, word [edx+BUILDING_X]
mov [ANCHOR_X_ADDRESS], ecx
movsx ecx, word [edx+BUILDING_Y]
mov [ANCHOR_Y_ADDRESS], ecx
mov eax, [ANCHOR_UNIT_ADDRESS]
movsx edx, word [eax+UNIT_X]
sub edx, [ANCHOR_X_ADDRESS]
imul edx, edx
mov ecx, edx
movsx edx, word [eax+UNIT_Y]
sub edx, [ANCHOR_Y_ADDRESS]
imul edx, edx
add ecx, edx
cmp dword [ANCHOR_BEST_ADDRESS], -1
je anchor_take
cmp ecx, [ANCHOR_BEST_ADDRESS]
jae anchor_next
anchor_take:
mov [ANCHOR_BEST_ADDRESS], ecx
mov ecx, [ANCHOR_X_ADDRESS]
mov [CAMP_X_ADDRESS], ecx
mov ecx, [ANCHOR_Y_ADDRESS]
mov [CAMP_Y_ADDRESS], ecx
anchor_next:
mov ecx, [ANCHOR_FROM_ADDRESS]
add ecx, 1
mov [ANCHOR_FROM_ADDRESS], ecx
cmp ecx, [ANCHOR_TO_ADDRESS]
jle anchor_loop
cmp dword [ANCHOR_BEST_ADDRESS], -1
je anchor_nothing
mov eax, 1
ret
anchor_nothing:
xor eax, eax
ret
]]

-- ... and what stands in for it on a game whose keep and campground tables were not found.
local no_anchor = [[
mov dword [ANCHOR_BEST_ADDRESS], -1
xor eax, eax
ret
]]

local queue_fill = [[
mov eax, [FILL_UNIT_ADDRESS]
imul eax, eax, 1168
movsx ecx, word [eax+UNIT_PATH_LENGTH]
test ecx, ecx
jle fill_done
mov [FILL_LEFT_ADDRESS], ecx
mov ecx, [eax+UNIT_PREVIOUS_TILE]
mov [FILL_TILE_ADDRESS], ecx
movsx ecx, word [eax+UNIT_LADDER_X]
mov [FILL_X_ADDRESS], ecx
movsx ecx, word [eax+UNIT_LADDER_Y]
mov [FILL_Y_ADDRESS], ecx
mov dword [FILL_STEP_ADDRESS], 0
fill_loop:
mov ecx, [QUEUE_COUNT_ADDRESS]
cmp ecx, QUEUE_MAX
jae fill_done
shl ecx, 4
add ecx, QUEUE_ADDRESS
mov edx, [FILL_TILE_ADDRESS]
mov [ecx], edx
mov edx, [FILL_X_ADDRESS]
mov [ecx+4], edx
mov edx, [FILL_Y_ADDRESS]
mov [ecx+8], edx
mov edx, [FILL_FLAGS_ADDRESS]
mov [ecx+12], edx
add dword [QUEUE_COUNT_ADDRESS], 1
mov eax, [FILL_UNIT_ADDRESS]
imul eax, eax, 1168
mov ecx, [FILL_STEP_ADDRESS]
mov edx, ecx
shr edx, 1
add edx, eax
movsx edx, byte [edx+UNIT_PATH_PLAN]
test ecx, 1
je fill_even
sar edx, 4
jmp fill_direction
fill_even:
and edx, 15
fill_direction:
mov eax, [FILL_Y_ADDRESS]
shl eax, 5
mov eax, [eax+edx*4+DIRECTIONS_ADDRESS]
add [FILL_TILE_ADDRESS], eax
mov eax, [edx*8+X_DELTAS_ADDRESS]
add [FILL_X_ADDRESS], eax
mov eax, [edx*8+Y_DELTAS_ADDRESS]
add [FILL_Y_ADDRESS], eax
add dword [FILL_STEP_ADDRESS], 1
mov ecx, [FILL_STEP_ADDRESS]
cmp ecx, [FILL_LEFT_ADDRESS]
jl fill_loop
fill_done:
ret
]]

-- What the shaking may touch: the town, and only the town. A tile carrying a wall or a
-- stair - both of which live in the map's own flag layer rather than as buildings - is left
-- standing, and so is any building the module counts as a fortification: the keeps, the
-- gatehouses and gates, the drawbridge, the keep doors and the towers. Bringing a wall down
-- is the business of the tunnel's own target, not of the tremor beside it.
--
-- They are not made sturdier than they were, though. The unmodified game takes five points
-- off whatever stands on each tile a collapsing tunnel ran under, and a fortification still
-- takes exactly that on the tile the tunnel was actually beneath - no more, and nothing at
-- all on the tiles to either side, which is what the base game did there too.
--
-- One warning about the ground, learnt the hard way. **A wall's hit points are its height.**
-- The game's own damage routine takes one off `live height` per point of damage and only
-- removes the wall - flags, rubble counter and all - when that height comes down to the
-- height the map gives the tile. So writing `live = base` on a tile that carries a wall
-- flattens it to nothing while leaving every flag in place: it looks lowered, it cannot be
-- repaired, and nothing will ever finish it off. The ground is therefore put back only where
-- nothing stands; a wall or a building on the tile is left entirely to the game, which
-- resets the height itself the moment the thing is destroyed.
--
-- One tile of that queue: the ground it and its neighbours stand on goes back to the height
-- the map itself says they should be - the game keeps that in a second map, which is what
-- its own "put this tile back" does, and it is why a tunnel over raised ground must never
-- simply be flattened to nothing. Then, unless this is a tunnel being quietly filled in
-- behind a tunneler that is still digging, whatever stands within reach is shaken.
local queue_step = [[
mov eax, [RADIUS_ADDRESS]
test eax, eax
jl step_done
neg eax
mov [STEP_DY_ADDRESS], eax
step_row:
mov eax, [RADIUS_ADDRESS]
neg eax
mov [STEP_DX_ADDRESS], eax
step_tile:
mov edx, [STEP_Y_ADDRESS]
add edx, [STEP_DY_ADDRESS]
cmp edx, 1
jl step_next
cmp edx, MAP_LIMIT
jg step_next
mov eax, [STEP_X_ADDRESS]
add eax, [STEP_DX_ADDRESS]
cmp eax, 1
jl step_next
cmp eax, MAP_LIMIT
jg step_next
mov ecx, edx
lea ecx, [ecx+ecx*2]
mov ecx, [ecx*4+ROW_TABLE_ADDRESS]
add ecx, eax
mov [STEP_THIS_X_ADDRESS], eax
mov [STEP_THIS_Y_ADDRESS], edx
mov [STEP_THIS_TILE_ADDRESS], ecx
test dword [ecx*4+TILE_FLAGS_ADDRESS], WALL_FAMILY
jnz step_ground_done
cmp word [ecx*2+BUILDING_TILE_ADDRESS], 0
jne step_ground_done
mov al, byte [ecx+BASE_HEIGHT_ADDRESS]
cmp al, byte [ecx+LIVE_HEIGHT_ADDRESS]
jae step_ground_done
mov byte [ecx+LIVE_HEIGHT_ADDRESS], al
step_ground_done:
test dword [STEP_FLAGS_ADDRESS], 1
jnz step_next
mov eax, [SPREAD_DAMAGE_ADDRESS]
mov [STEP_DAMAGE_ADDRESS], eax
test dword [ecx*4+TILE_FLAGS_ADDRESS], WALL_FAMILY
jnz step_fortified
movzx eax, word [ecx*2+BUILDING_TILE_ADDRESS]
test eax, eax
je step_next
imul eax, eax, BUILDING_STRIDE
movsx eax, word [eax+BUILDING_TYPE_ADDRESS]
cmp eax, TYPE_LIMIT
ja step_shake
cmp byte [eax+FORTIFIED_ADDRESS], 0
je step_shake
step_fortified:
cmp dword [STEP_DX_ADDRESS], 0
jne step_next
cmp dword [STEP_DY_ADDRESS], 0
jne step_next
mov dword [STEP_DAMAGE_ADDRESS], TUNNEL_DAMAGE
step_shake:
push 0
push 0
mov eax, [STEP_FLAGS_ADDRESS]
sar eax, 8
push eax
push 0
push dword [STEP_DAMAGE_ADDRESS]
push dword [STEP_THIS_Y_ADDRESS]
push dword [STEP_THIS_X_ADDRESS]
push dword [STEP_THIS_TILE_ADDRESS]
mov ecx, TILE_MAP_STATE_ADDRESS
call PROCESS_DAMAGE_ADDRESS
step_next:
add dword [STEP_DX_ADDRESS], 1
mov eax, [STEP_DX_ADDRESS]
cmp eax, [RADIUS_ADDRESS]
jle step_tile
add dword [STEP_DY_ADDRESS], 1
mov eax, [STEP_DY_ADDRESS]
cmp eax, [RADIUS_ADDRESS]
jle step_row
step_done:
ret
]]

-- ... and the tick that works through the queue, hooked into the front of the game's own
-- pass over its units so it runs once a tick whether or not a tunneler is still alive. It
-- takes the queue from the back, which is the target end, so the tunnel falls in towards
-- its entrance.
--
-- It runs before the function's own prologue, so the three instructions it replaces are
-- replayed at the end. Everything else the function expects has to be left exactly as it
-- was found, and that includes **ECX**: this is a thiscall, the prologue's `mov esi, ecx`
-- five instructions later is where `this` comes from, and the whole function writes through
-- it. Hence the pushad - the drain calls the game's own damage, which clobbers freely.
local queue_tick = [[
pushad
cmp dword [QUEUE_COUNT_ADDRESS], 0
je tick_done
mov eax, [SPEED_ADDRESS]
test eax, eax
jle tick_done
mov [TICK_LEFT_ADDRESS], eax
tick_next:
cmp dword [QUEUE_COUNT_ADDRESS], 0
je tick_done
sub dword [QUEUE_COUNT_ADDRESS], 1
mov ecx, [QUEUE_COUNT_ADDRESS]
shl ecx, 4
add ecx, QUEUE_ADDRESS
mov eax, [ecx]
mov [STEP_TILE_ADDRESS], eax
mov eax, [ecx+4]
mov [STEP_X_ADDRESS], eax
mov eax, [ecx+8]
mov [STEP_Y_ADDRESS], eax
mov eax, [ecx+12]
mov [STEP_FLAGS_ADDRESS], eax
call STEP_ADDRESS
push dword [STEP_Y_ADDRESS]
push dword [STEP_X_ADDRESS]
push 1
mov ecx, PATH_STATE_ADDRESS
call UPDATE_WALK_ADDRESS
sub dword [TICK_LEFT_ADDRESS], 1
mov eax, [TICK_LEFT_ADDRESS]
test eax, eax
jg tick_next
tick_done:
popad
push ebx
push ebp
movsx ebp, word [RNG_ADDRESS]
jmp RETURN_ADDRESS
]]


-- The game's own "is this unit worth aiming at" test, which every unit's update asks
-- before it shoots at, charges at or runs from somebody. It says no for the states a
-- citizen is in when it is inside a building; this says no as well for a tunneler that is
-- digging its entrance or its tunnel, which is underground and should be no more shootable
-- than a man in a mill.
--
-- Replaces the two instructions the function opens with, and leaves EAX the way they did.
local not_a_target = [[
mov eax, [esp+4]
imul eax, eax, 1168
cmp dword [ENABLED_ADDRESS], 0
je target_vanilla
cmp word [eax+UNIT_TYPE], TUNNELER_TYPE
jne target_vanilla
movzx edx, word [eax+UNIT_STATE]
cmp dx, 3
je target_hidden
cmp dx, 4
je target_hidden
cmp dx, 8
je target_hidden
cmp dx, 9
jne target_vanilla
target_hidden:
mov eax, 1
ret 4
target_vanilla:
jmp RETURN_ADDRESS
]]

-- Where the search decides the tile it has reached is the target - the one place walls,
-- gates and towers all come through. With the module looking for something towards the
-- enemy's keep, a target is only taken when it is closer to that keep than the tunneler is
-- standing now; anything else is left behind and the search spreads on past it, so a tunnel
-- works its way inwards instead of wandering along the wall it is already at. The flag is
-- only up while the module's own search runs.
--
-- EBP is the tile, EDI its y and EDX its x, which is what the three stores this replaces
-- are about; EAX and ECX are dead here either way.
local accept_towards = [[
cmp dword [PINNED_TILE_ADDRESS], 0
je accept_free
cmp ebp, [PINNED_TILE_ADDRESS]
je accept_take_it
jmp accept_spread_past
accept_free:
cmp dword [BIAS_ACTIVE_ADDRESS], 0
je accept_take_it
mov eax, [DEPTH_LIMIT_ADDRESS]
test eax, eax
je accept_near_enough
movsx ecx, word [ebp*2+DISTANCE_MAP_ADDRESS]
cmp ecx, eax
jg accept_spread_past
accept_near_enough:
mov eax, edx
sub eax, [CAMP_X_ADDRESS]
imul eax, eax
mov ecx, edi
sub ecx, [CAMP_Y_ADDRESS]
imul ecx, ecx
add eax, ecx
cmp eax, [ORIGIN_DISTANCE_ADDRESS]
jge accept_spread_past
accept_take_it:
mov [esi+RESULT_TILE], ebp
mov [esi+RESULT_Y], edi
mov [esi+RESULT_X], edx
jmp RETURN_ADDRESS
accept_spread_past:
jmp SPREAD_ADDRESS
]]

-- Both aims work the same way past this point. The narrowing on its own walks the target
-- towards the camp round after round, and with tunnels allowed under the town that walk goes
-- straight through the wall and ends at the keep - which is the one thing a breach must not
-- be. So the first answer sets a depth: the tunnelling distance the search itself measured to
-- it, plus a few tiles of room to look along the wall face. Later rounds may move the target
-- sideways within that band but never deeper in.
--
-- The other half is that the player's tunnels have to agree. Each keeps its own slot - the
-- tile the player is breaching - and a tunnel that finds one already set searches for that
-- exact tile and nothing else. Reach it and they all dig at one piece of wall and open one
-- road in; fail to reach it (too far, no way through) and the tunnel quietly falls back to
-- its own narrowing without disturbing the others. The slot is cleared when nothing stands
-- on that tile any more, so the next tunnel to look picks the next piece and the rest follow
-- it in turn.

-- The game's own first aim, taken the moment a tunneler has dug itself in. It calls its
-- target search once and digs at whatever it reaches first, which on a long wall is
-- whichever piece happens to be nearest. This lets that call happen - it is what works out
-- where the tunnel starts and winds the entrance's own counter on - and then, if it found
-- something, runs the search again from the same spot with the module's filter up, each
-- round demanding something closer to the enemy's campground than the round before. What
-- the game reads afterwards is the last answer, so the tunnel starts out aimed at the piece
-- of wall nearest their camp instead of the nearest one to itself.
local initial_aim = [[
call FIND_TARGET_ADDRESS
test eax, eax
je initial_done
mov dword [SHARED_SLOT_ADDRESS], 0
mov dword [PINNED_TILE_ADDRESS], 0
mov dword [DEPTH_LIMIT_ADDRESS], 0
mov dword [OURS_ADDRESS], 0
mov ecx, [ALG_RESULT_ADDRESS]
mov [GAME_TILE_ADDRESS], ecx
mov ecx, [CURRENT_UNIT_ADDRESS]
add ecx, 1
cmp ecx, [SKIP_UNIT_ADDRESS]
jne initial_our_turn
mov dword [SKIP_UNIT_ADDRESS], 0
jmp initial_found
initial_our_turn:
mov ecx, [ALG_RESULT_ADDRESS]
mov [BEST_TILE_ADDRESS], ecx
mov ecx, [ALG_TARGET_X_ADDRESS]
mov [BEST_X_ADDRESS], ecx
mov ecx, [ALG_TARGET_Y_ADDRESS]
mov [BEST_Y_ADDRESS], ecx
cmp dword [TOWARDS_ENABLED_ADDRESS], 0
je initial_done
mov ecx, [CURRENT_UNIT_ADDRESS]
imul ecx, ecx, 1168
movsx edx, word [ecx+UNIT_WORKPLACE]
test edx, edx
jle initial_found
imul edx, edx, BUILDING_STRIDE
movsx eax, word [edx+BUILDING_SOME_X]
mov [ORIGIN_X_ADDRESS], eax
movsx eax, word [edx+BUILDING_SOME_Y]
mov [ORIGIN_Y_ADDRESS], eax
mov [INITIAL_UNIT_ADDRESS], ecx
mov [ANCHOR_UNIT_ADDRESS], ecx
call ANCHOR_ADDRESS
test eax, eax
je initial_found
mov ecx, [BEST_X_ADDRESS]
sub ecx, [CAMP_X_ADDRESS]
imul ecx, ecx
mov edx, [BEST_Y_ADDRESS]
sub edx, [CAMP_Y_ADDRESS]
imul edx, edx
add ecx, edx
mov [ORIGIN_DISTANCE_ADDRESS], ecx
mov dword [ROUNDS_ADDRESS], 0
mov dword [BIAS_ACTIVE_ADDRESS], 1
mov ecx, [SHARED_SLOT_ADDRESS]
test ecx, ecx
je initial_no_mark
mov ecx, [ecx+16]
test ecx, ecx
je initial_no_mark
cmp ecx, [ORIGIN_DISTANCE_ADDRESS]
jae initial_no_mark
mov [ORIGIN_DISTANCE_ADDRESS], ecx
initial_no_mark:
mov ecx, [BEST_TILE_ADDRESS]
movsx ecx, word [ecx*2+DISTANCE_MAP_ADDRESS]
add ecx, DEPTH_SLACK
mov [DEPTH_LIMIT_ADDRESS], ecx
mov ecx, [INITIAL_UNIT_ADDRESS]
movsx ecx, word [ecx+UNIT_OWNER]
mov [BREACH_OWNER_ADDRESS], ecx
mov ecx, [ORIGIN_X_ADDRESS]
mov [BREACH_X_ADDRESS], ecx
mov ecx, [ORIGIN_Y_ADDRESS]
mov [BREACH_Y_ADDRESS], ecx
call BREACH_ADDRESS
initial_round:
mov ecx, [INITIAL_UNIT_ADDRESS]
push dword [ORIGIN_Y_ADDRESS]
push dword [ORIGIN_X_ADDRESS]
push dword [RANGE_ADDRESS]
movsx edx, word [ecx+UNIT_SIEGE_TARGET]
push edx
movsx edx, word [ecx+UNIT_OWNER]
push edx
mov ecx, PATH_STATE_ADDRESS
call SEARCH_ADDRESS
cmp dword [ALG_RESULT_ADDRESS], 0
je initial_miss
mov ecx, [ALG_RESULT_ADDRESS]
mov [BEST_TILE_ADDRESS], ecx
mov ecx, [ALG_TARGET_X_ADDRESS]
mov [BEST_X_ADDRESS], ecx
mov ecx, [ALG_TARGET_Y_ADDRESS]
mov [BEST_Y_ADDRESS], ecx
cmp dword [PINNED_TILE_ADDRESS], 0
je initial_free
mov dword [PINNED_TILE_ADDRESS], 0
jmp initial_stop
initial_miss:
cmp dword [PINNED_TILE_ADDRESS], 0
je initial_stop
mov dword [PINNED_TILE_ADDRESS], 0
jmp initial_round
initial_free:
mov ecx, [BEST_X_ADDRESS]
sub ecx, [CAMP_X_ADDRESS]
imul ecx, ecx
mov edx, [BEST_Y_ADDRESS]
sub edx, [CAMP_Y_ADDRESS]
imul edx, edx
add ecx, edx
mov [ORIGIN_DISTANCE_ADDRESS], ecx
add dword [ROUNDS_ADDRESS], 1
mov ecx, [ROUNDS_ADDRESS]
cmp ecx, SEARCH_ROUNDS
jb initial_round
initial_stop:
mov dword [BIAS_ACTIVE_ADDRESS], 0
mov dword [DEPTH_LIMIT_ADDRESS], 0
mov dword [PINNED_TILE_ADDRESS], 0
mov ecx, [SHARED_SLOT_ADDRESS]
test ecx, ecx
je initial_told_nobody
cmp dword [ecx], 0
jne initial_told_nobody
mov edx, [BEST_TILE_ADDRESS]
mov [ecx], edx
mov edx, [BEST_X_ADDRESS]
mov [ecx+4], edx
mov edx, [BEST_Y_ADDRESS]
mov [ecx+8], edx
mov edx, [TICKS_ADDRESS]
mov [ecx+12], edx
initial_told_nobody:
mov ecx, [BEST_TILE_ADDRESS]
cmp ecx, [GAME_TILE_ADDRESS]
je initial_write
mov dword [OURS_ADDRESS], 1
initial_write:
cmp dword [DIAGNOSTICS_ADDRESS], 0
je initial_quiet
mov ecx, [CURRENT_UNIT_ADDRESS]
mov [REPORT_ADDRESS], ecx
mov ecx, [BEST_TILE_ADDRESS]
mov [REPORT_ADDRESS+4], ecx
mov ecx, [GAME_TILE_ADDRESS]
mov [REPORT_ADDRESS+12], ecx
mov ecx, [SHARED_SLOT_ADDRESS]
test ecx, ecx
je initial_no_slot_said
mov ecx, [ecx]
initial_no_slot_said:
mov [REPORT_ADDRESS+16], ecx
mov ecx, [ROUNDS_ADDRESS]
mov [REPORT_ADDRESS+20], ecx
mov ecx, [DEPTH_LIMIT_ADDRESS]
mov [REPORT_ADDRESS+24], ecx
mov dword [REPORT_ADDRESS+28], 30
call REPORT_PAD_ADDRESS
initial_quiet:
mov ecx, [BEST_TILE_ADDRESS]
mov [ALG_RESULT_ADDRESS], ecx
mov ecx, [BEST_X_ADDRESS]
mov [ALG_TARGET_X_ADDRESS], ecx
mov ecx, [BEST_Y_ADDRESS]
mov [ALG_TARGET_Y_ADDRESS], ecx
mov eax, 1
jmp initial_done
initial_found:
mov eax, 1
initial_done:
jmp RETURN_ADDRESS
]]

local tunnel_accept = [[
imul eax, eax, BUILDING_STRIDE
movsx edx, word [eax+BUILDING_TYPE_ADDRESS]
cmp dword [ENABLED_ADDRESS], 0
je accept_vanilla
cmp edx, TYPE_LIMIT
ja accept_spread_on
cmp dword [edx*4+GATE_OR_TOWER_ADDRESS], 0
je accept_spread_on
jmp RETURN_ADDRESS
accept_vanilla:
add edx, -74
cmp edx, 2
ja accept_spread_on
jmp RETURN_ADDRESS
accept_spread_on:
jmp SPREAD_ADDRESS
]]

-- Whether the search may spread past a tile with a building on it. With tunnels allowed
-- under the town the answer is yes for everything except a keep: a tunnel works its way
-- round one rather than under it, so the three keep types are refused even then. EDX is the
-- building's type and is dead after this test; ECX, EAX and EBX belong to the search's own
-- neighbour loop and are left alone.
local tunnel_targets = [[
cmp dword [UNDER_ENABLED_ADDRESS], 0
je targets_by_type
sub edx, KEEP_FIRST_TYPE
cmp edx, KEEP_TYPE_SPAN
jbe targets_skip
jmp targets_allow
targets_by_type:
cmp dword [ENABLED_ADDRESS], 0
je targets_vanilla
cmp edx, TYPE_LIMIT
ja targets_skip
mov edx, [edx*4+GATE_OR_TOWER_ADDRESS]
test edx, edx
jne targets_allow
jmp targets_skip
targets_vanilla:
add edx, -74
cmp edx, 2
ja targets_skip
targets_allow:
jmp ALLOW_ADDRESS
targets_skip:
jmp SKIP_ADDRESS
]]

---------------------------------------------------------------------------------------
-- Stances
---------------------------------------------------------------------------------------
-- Hooked into the first instruction of UpdateTunneler. The stance search
-- (findNearestEnemyAndHeadTowardsIt) only looks at a unit's tribe stance when the unit
-- has its "standing about, free to react" flag set, and every soldier's update function
-- sets that flag in its idle and walking states. The tunneler's never does, which is the
-- whole reason stances do nothing for tunnelers. So set it for the states where a
-- tunneler is standing about with nothing of its own to do: idle, waiting, and the walk
-- back to its guild.
--
-- It is deliberately not set while the tunneler walks to a destination it has been given
-- (state 101), so an order to go somewhere is never thrown away halfway for an enemy that
-- happens to stand near the route. The moment the unit arrives the game puts it back into
-- state 0 and the stance takes over from there, which is also what makes a patrol react at
-- each of its points. It is not set while the tunneler walks to a tunnel it has been told
-- to dig, or while it is underground, so a stance never cancels a dig order either.
--
-- Runs before the function's own prologue, so ECX must survive; only EAX and EDX are used.
local stance = [[
push ecx
mov eax, [CURRENT_UNIT_ADDRESS]
mov ecx, eax
and ecx, 7
shr eax, 3
mov dl, 1
shl dl, cl
test byte [eax+PENDING_ADDRESS], dl
je pending_none
mov ecx, [TICKS_ADDRESS]
cmp ecx, [LAST_REAIM_TICK_ADDRESS]
je pending_none
mov [LAST_REAIM_TICK_ADDRESS], ecx
not dl
and byte [eax+PENDING_ADDRESS], dl
mov ecx, [CURRENT_UNIT_ADDRESS]
mov [REAIM_UNIT_ADDRESS], ecx
mov dword [REAIM_ARRIVED_ADDRESS], 0
call REAIM_ADDRESS
pending_none:
cmp dword [HIDE_ENABLED_ADDRESS], 0
je hide_done
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
movzx edx, word [eax+UNIT_STATE]
cmp dx, 3
je hide_it
cmp dx, 4
je hide_it
cmp dx, 8
je hide_it
cmp dx, 9
je hide_it
mov word [eax+UNIT_SELECTABLE], 1
jmp hide_done
hide_it:
mov word [eax+UNIT_SELECTABLE], 0
hide_done:
cmp dword [ENABLED_ADDRESS], 0
je stance_vanilla
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
movzx edx, word [eax+UNIT_STATE]
test dx, dx
je stance_set
cmp dx, 1
je stance_set
cmp dx, 5
je stance_set
cmp dx, 6
je stance_set
cmp dx, 105
jne stance_vanilla
stance_set:
mov word [eax+UNIT_LOOKING_AROUND], 1
stance_vanilla:
mov ecx, [CURRENT_UNIT_ADDRESS]
jmp RETURN_ADDRESS
]]

---------------------------------------------------------------------------------------
-- The dig tunnel button, one slot along
---------------------------------------------------------------------------------------
-- Hooked into MenuItemRenderFunction_BuildMenu_UnitActionButtons, in the case that draws
-- the engineer's "build siege engine" button - the slot to the right of the attack-here
-- slot, empty for every other unit. With tunnelers selected it draws the dig tunnel
-- picture there instead and names the dig tunnel help text, then leaves the render
-- function the way the case's own render path does.
--
-- The vanilla tunneler branch in the attack-here case is jumped over by a two byte patch
-- in init.lua, so the two buttons never both claim the same slot.
local render_tunnel_button = [[
cmp dword [ENABLED_ADDRESS], 0
je render_vanilla
cmp dword [ENGINEER_SELECTED_ADDRESS], 0
jne render_vanilla
mov ecx, UNITS_STATE_ADDRESS
call TUNNELERS_ONLY_ADDRESS
test eax, eax
je render_vanilla
mov eax, [GAME_MODE_ADDRESS]
cmp eax, 6
je render_vanilla
mov dword [BUTTON_PICTURE_ADDRESS], TUNNEL_PICTURE
mov dword [HELP_TEXT_ADDRESS], TUNNEL_HELP_TEXT
call RENDER_BUTTON_ADDRESS
mov dword [BUTTON_INACTIVE_ADDRESS], 0
jmp RENDER_RETURN_ADDRESS
render_vanilla:
cmp dword [ENGINEER_SELECTED_ADDRESS], edi
jmp RETURN_ADDRESS
]]

---------------------------------------------------------------------------------------
-- and its click
---------------------------------------------------------------------------------------
-- Hooked into the first instruction of MenuItemActionHandler_General_ToolbarButtonPressed,
-- which is what the slot above runs when it is clicked. With tunnelers selected the
-- engineer's build command is swapped for the tunnel command the vanilla dig tunnel
-- button sends. The parameter is the caller's own copy on the stack, so writing it
-- changes nothing else.
local tunnel_button_click = [[
cmp dword [ENABLED_ADDRESS], 0
je click_vanilla
cmp dword [esp+4], ENGINEER_BUILD_COMMAND
jne click_vanilla
mov ecx, UNITS_STATE_ADDRESS
call TUNNELERS_ONLY_ADDRESS
test eax, eax
je click_vanilla
mov dword [esp+4], TUNNEL_COMMAND
click_vanilla:
push ebx
xor ebx, ebx
cmp dword [SYNC_STATUS_ADDRESS], ebx
jmp RETURN_ADDRESS
]]

return {
  denial_check = denial_check,
  placement_message = placement_message,
  arrival = arrival,
  reaim = reaim,
  collapse_scan = collapse_scan,
  tunnel_targets = tunnel_targets,
  tunnel_accept = tunnel_accept,
  collapse_target = collapse_target,
  not_a_target = not_a_target,
  accept_towards = accept_towards,
  initial_aim = initial_aim,
  find_anchor = find_anchor,
  find_breach = find_breach,
  find_record = find_record,
  path_check = path_check,
  no_anchor = no_anchor,
  queue_fill = queue_fill,
  queue_step = queue_step,
  queue_tick = queue_tick,
  stance = stance,
  render_tunnel_button = render_tunnel_button,
  tunnel_button_click = tunnel_button_click,
}
