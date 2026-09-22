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
mov edx, [eax+UNIT_UID]
mov ecx, RECORDS_ADDRESS
reaim_look:
cmp dword [ecx], edx
je reaim_have
add ecx, 8
cmp ecx, RECORDS_END_ADDRESS
jb reaim_look
mov ecx, [RING_CURSOR_ADDRESS]
mov [ecx], edx
mov dword [ecx+4], 0
add dword [RING_CURSOR_ADDRESS], 8
mov edx, [RING_CURSOR_ADDRESS]
cmp edx, RECORDS_END_ADDRESS
jb reaim_have
mov dword [RING_CURSOR_ADDRESS], RECORDS_ADDRESS
reaim_have:
mov [RECORD_ADDRESS], ecx
mov edx, [ecx+4]
cmp edx, [MAX_RETARGETS_ADDRESS]
jb reaim_budget_left
mov eax, 2
ret
reaim_budget_left:
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
je reaim_nothing
cmp dword [ARRIVED_ADDRESS], 0
je reaim_keep_the_tunnel
cmp dword [COLLAPSE_BEHIND_ADDRESS], 0
je reaim_keep_the_tunnel
push dword [UNIT_ADDRESS]
mov ecx, UNITS_STATE_ADDRESS
call APPLY_TUNNEL_DAMAGE_ADDRESS
reaim_keep_the_tunnel:
push 2
push dword [ALG_TARGET_Y_ADDRESS]
push dword [ALG_TARGET_X_ADDRESS]
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
movsx edx, word [eax+UNIT_DEST_X]
sub edx, esi
add edx, SCAN_RADIUS
cmp edx, SCAN_SPAN
ja scan_next
movsx edx, word [eax+UNIT_DEST_Y]
sub edx, edi
add edx, SCAN_RADIUS
cmp edx, SCAN_SPAN
ja scan_next
mov [REAIM_UNIT_ADDRESS], ebx
mov dword [REAIM_ARRIVED_ADDRESS], 0
call REAIM_ADDRESS
cmp eax, 1
jne scan_next
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

local tunnel_targets = [[
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
push ecx
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
  stance = stance,
  render_tunnel_button = render_tunnel_button,
  tunnel_button_click = tunnel_button_click,
}
