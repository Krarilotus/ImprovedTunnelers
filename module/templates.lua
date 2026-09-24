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
-- Map Extensions restores the zones and their last observed tick together. The backward
-- tick check remains a defensive guard, not a substitute for restoring saved state.
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

---------------------------------------------------------------------------------------
-- Where a tunnel goes
---------------------------------------------------------------------------------------
-- Everything below sits on the game's own tunnel target search, algTunnelerFindTarget: a
-- spread over the map from a starting tile that stops at the first enemy wall, gate or
-- tower it will take. What it leaves behind is both the answer and the distance map the
-- game's setDestinationForUnit(..., 2) traces the tunnel back along, so choosing a target
-- is only ever a matter of running the search in a way that makes it stop somewhere else.
-- Nothing here lays a path by any other means.
--
-- The rules, per player:
--
--   * A player's tunnels gather on lines. The first tunnel dug in at a castle takes the
--     game's own answer, and that becomes a line; every tunnel dug after it is sent at that
--     line if its own search can reach it within the search range. One that can reach no
--     line starts a line of its own, so a second siege somewhere else gets its own meeting
--     point. A player keeps up to four lines.
--   * A tunnel that arrives on a fortification is left entirely to the game: its own
--     collapse, its own damage.
--   * The first time a line's target comes down, the line lays out its route to the
--     enemy's campfire - once, with one run of the search - and from then on the line's
--     target is simply the first fortification on that route still standing. Every tunnel
--     that arrives on the rubble is sent at it; each one that gets there brings it down and
--     the next goes one further. Only when the whole route is open do tunnels turn to the
--     nearest fortification of all, to widen the way in.
--   * A tunnel with no line, or a line with no route (no campfire known), is sent at the
--     nearest fortification lying towards the enemy's campfire, else the nearest of all.
--   * The keep is never spread into (tunnel_targets below), so every path goes round it.
--
-- Sending a tunnel on never replaces the tunnel it has dug. Its path plan is kept whole
-- from the entrance and the new leg added to the end, so when it finally collapses the
-- game's own collapse, and everything this module adds to it, runs over the entire tunnel
-- exactly as it would for one dug in a straight line.

-- The filter the searches run through. Hooked on the three stores inside the search that
-- say "this tile is the target" - the one place walls, gates and towers all come through.
-- AIM_MODE picks what it does, and every search this module runs sets it and clears it
-- again straight afterwards, so the game's own searches - its first aim, the AI's tunnels -
-- always find the filter off:
--
--   0  take the tile, as the game does - the game's own searches, and the module's when it
--      has to reproduce the game's own answer
--   1  take only AIM_PIN, and spread on past anything else
--   2  take only a tile inside a cone of 45 degrees either side of the line from
--      AIM_FROM towards the enemy's campfire, and spread on past anything else
--   3  take nothing but the enemy's campfire, so the search spreads until it gets there -
--      which is how a line's route to the campfire is measured
--   4  take the tile, as 0, unless it is set aside
--
-- In the module's own modes 1, 2 and 4 a tile the game recently refused to lay a path to
-- is set aside: the search spreads past it for REFUSED_TICKS, so no tunnel is sent at it
-- again in the meantime. The game's own mode 0 never sees that list.
--
-- The cone test is dot(v, w) > 0 and 2 dot(v, w)^2 >= |v|^2 |w|^2, v being the candidate
-- less AIM_FROM and w the direction to the camp scaled down to 64 on its longer side, so
-- everything fits a 32 bit register however far across the map the camp is.
--
-- Whatever the mode, a stockpile is never taken: the game marks its footprint with the wall
-- bit, so the search comes to it as it would to a wall, but that wall cannot be damaged and
-- a tunnel sent at it only collapses uselessly. The search spreads on past it instead, the
-- game's own searches and the AI's included.
--
-- EBP is the tile, EDI its y and EDX its x, which is what the three stores it replaces
-- are about; EAX and ECX are dead here either way and EBX is kept for the search.
local aim_filter = [[
test dword [ebp*4+TILE_FLAGS_ADDRESS], STOCKPILE
jnz SPREAD_ADDRESS
mov eax, [AIM_MODE_ADDRESS]
test eax, eax
je filter_take
cmp eax, 2
je filter_cone
cmp eax, 1
je filter_pin
cmp eax, 3
jne filter_check_refused
movzx eax, word [ebp*2+BUILDING_TILE_ADDRESS]
test eax, eax
je filter_never
cmp eax, [CAMP_BUILDING_ADDRESS]
je filter_take
filter_never:
jmp SPREAD_ADDRESS
filter_pin:
cmp ebp, [AIM_PIN_ADDRESS]
jne filter_never
jmp filter_check_refused
filter_cone:
push ebx
mov eax, edx
sub eax, [AIM_FROM_X_ADDRESS]
mov ecx, edi
sub ecx, [AIM_FROM_Y_ADDRESS]
mov ebx, eax
imul ebx, [AIM_DIR_X_ADDRESS]
imul eax, eax
push eax
mov eax, ecx
imul eax, [AIM_DIR_Y_ADDRESS]
add ebx, eax
imul ecx, ecx
pop eax
add eax, ecx
test ebx, ebx
jle filter_outside
imul eax, [AIM_DIR_LENGTH_ADDRESS]
imul ebx, ebx
add ebx, ebx
cmp ebx, eax
jb filter_outside
pop ebx
filter_check_refused:
mov ecx, REFUSED_ADDRESS
filter_refused_look:
cmp ebp, [ecx]
jne filter_refused_next
mov eax, [TICKS_ADDRESS]
cmp eax, [ecx+4]
jb filter_never
filter_refused_next:
add ecx, 8
cmp ecx, REFUSED_END_ADDRESS
jb filter_refused_look
filter_take:
mov [esi+RESULT_TILE], ebp
mov [esi+RESULT_Y], edi
mov [esi+RESULT_X], edx
jmp RETURN_ADDRESS
filter_outside:
pop ebx
jmp SPREAD_ADDRESS
]]

-- One run of the search: for AIM_OWNER against AIM_SIEGE, from AIM_FROM, no further than
-- AIM_RANGE, through the filter in AIM_MODE - which it puts back to 0 before it returns,
-- whatever happened. EAX comes back as the tile found, 0 for nothing. EAX, ECX and EDX.
local line_search = [[
push dword [AIM_FROM_Y_ADDRESS]
push dword [AIM_FROM_X_ADDRESS]
push dword [AIM_RANGE_ADDRESS]
push dword [AIM_SIEGE_ADDRESS]
push dword [AIM_OWNER_ADDRESS]
mov ecx, PATH_STATE_ADDRESS
call SEARCH_ADDRESS
mov dword [AIM_MODE_ADDRESS], 0
mov eax, [ALG_RESULT_ADDRESS]
ret
]]

-- Whether a fortification still stands on tile EDX: a wall, a crenellation or a stair in
-- the flag layer, or a building. A stockpile is none of these, even though the game marks
-- its footprint with the wall bit: that wall cannot be damaged, so it never stands in a
-- tunnel's way. EAX 1 or 0; nothing else is touched.
local stands = [[
xor eax, eax
test edx, edx
jle stands_done
test dword [edx*4+TILE_FLAGS_ADDRESS], STOCKPILE
jnz stands_done
test dword [edx*4+TILE_FLAGS_ADDRESS], WALL_FAMILY
jnz stands_yes
cmp word [edx*2+BUILDING_TILE_ADDRESS], 0
je stands_done
stands_yes:
mov eax, 1
stands_done:
ret
]]

-- The record of the tunneler at AIM_UNIT (scaled): {uid, times sent on, its line, step},
-- 16 bytes, found by uid in a ring. A tunneler not in it takes the next entry of the ring,
-- starting from nothing, so one that dies simply leaves its entry to be reused. The entry
-- is left in RECORD_ADDRESS. EAX, ECX and EDX.
local record_of = [[
mov eax, [AIM_UNIT_ADDRESS]
mov edx, [eax+UNIT_UID]
mov ecx, RECORDS_ADDRESS
record_look:
cmp [ecx], edx
je record_found
add ecx, 16
cmp ecx, RECORDS_END_ADDRESS
jb record_look
mov ecx, [RING_CURSOR_ADDRESS]
mov [ecx], edx
mov dword [ecx+4], 0
mov dword [ecx+8], 0
mov dword [ecx+12], 0
lea edx, [ecx+16]
cmp edx, RECORDS_END_ADDRESS
jb record_cursor
mov edx, RECORDS_ADDRESS
record_cursor:
mov [RING_CURSOR_ADDRESS], edx
record_found:
mov [RECORD_ADDRESS], ecx
ret
]]

-- A new line for AIM_OWNER at what the last search found, handed to the record in
-- RECORD_ADDRESS. A line is 16 bytes, {tile, x, y, tick last used}, four to a player. The
-- slot taken is an empty one if there is one, else one whose target has come down, else
-- the one used least recently. EAX, ECX and EDX; ESI and EDI are kept.
local new_line = [[
push esi
push edi
mov esi, [AIM_OWNER_ADDRESS]
shl esi, 6
add esi, LINE_ADDRESS
mov ecx, 4
new_empty:
cmp dword [esi], 0
jle new_take
add esi, 16
sub ecx, 1
jnz new_empty
sub esi, 64
mov edi, esi
mov ecx, 4
new_down:
mov edx, [esi]
call STANDS_ADDRESS
test eax, eax
je new_take
mov eax, [esi+12]
cmp eax, [edi+12]
jae new_not_older
mov edi, esi
new_not_older:
add esi, 16
sub ecx, 1
jnz new_down
mov esi, edi
new_take:
mov edx, esi
sub edx, LINE_ADDRESS
shr edx, 4
imul edx, edx, ROUTE_SIZE
add edx, ROUTES_ADDRESS
mov dword [edx], 0
mov dword [edx+4], 0
mov dword [edx+8], 0
mov edx, [ALG_RESULT_ADDRESS]
mov [esi], edx
mov edx, [ALG_TARGET_X_ADDRESS]
mov [esi+4], edx
mov edx, [ALG_TARGET_Y_ADDRESS]
mov [esi+8], edx
mov edx, [TICKS_ADDRESS]
mov [esi+12], edx
mov ecx, [RECORD_ADDRESS]
mov [ecx+8], esi
pop edi
pop esi
ret
]]

-- One search for a line's own target, from AIM_FROM. A target further away in steps than
-- the search range can never be reached - the search moves a tile at a time, never
-- diagonally - so it is not searched for at all. Otherwise the search is let spread only
-- as far as the target's own distance in steps plus PIN_SLACK, room to go round a keep,
-- rather than to the full range: when the target cannot be reached after all, that is
-- the difference between a few hundred thousand instructions and well over a million.
--
-- In: EBX the line. Out: EAX the tile found, 0 for none; SEARCHED set when a search ran.
-- EAX, ECX and EDX.
local aim_at_line = [[
mov eax, [ebx+4]
sub eax, [AIM_FROM_X_ADDRESS]
cdq
xor eax, edx
sub eax, edx
mov ecx, eax
mov eax, [ebx+8]
sub eax, [AIM_FROM_Y_ADDRESS]
cdq
xor eax, edx
sub eax, edx
add eax, ecx
cmp eax, [RANGE_ADDRESS]
jg aim_out_of_reach
add eax, PIN_SLACK
cmp eax, [RANGE_ADDRESS]
jbe aim_range_set
mov eax, [RANGE_ADDRESS]
aim_range_set:
mov [AIM_RANGE_ADDRESS], eax
mov eax, [ebx]
mov [AIM_PIN_ADDRESS], eax
mov dword [AIM_MODE_ADDRESS], 1
mov dword [SEARCHED_ADDRESS], 1
call LINE_SEARCH_ADDRESS
mov ecx, [RANGE_ADDRESS]
mov [AIM_RANGE_ADDRESS], ecx
ret
aim_out_of_reach:
xor eax, eax
ret
]]

-- Where a line's tunnels are to go now. While the line's target stands, that is it. Once
-- it has come down the line follows its route to the campfire, laying that out first if
-- it has none yet: the first fortification on the route still standing becomes the line's
-- target. EDX comes back as that tile, or 0 when there is none - and then ROUTE_CURRENT
-- says why: its route's state is 1 when the whole route is open, 2 when no route could be
-- laid out at all.
--
-- A route is a 16 byte head {state, fortifications on it, how many are behind us, tiles on
-- its path}, then ROUTE_ENTRIES fortifications of 16 bytes {tile, x, y, where on the path,
-- the tick a tunnel was sent at it}, then the path itself, a tile to a dword, breach first. One route to every line, found by
-- the line's own index. In: EBX the line, AIM_UNIT and AIM_OWNER set. EAX, ECX and EDX.
local line_front = [[
push esi
mov edx, [ebx]
call STANDS_ADDRESS
test eax, eax
jne front_stands
mov esi, ebx
sub esi, LINE_ADDRESS
shr esi, 4
imul esi, esi, ROUTE_SIZE
add esi, ROUTES_ADDRESS
mov [ROUTE_CURRENT_ADDRESS], esi
cmp dword [esi], 0
jne front_look
call ROUTE_BUILD_ADDRESS
front_look:
cmp dword [esi], 1
jne front_none
mov ecx, [esi+8]
cmp ecx, [esi+4]
jae front_none
shl ecx, 4
mov edx, [esi+ecx+16]
call STANDS_ADDRESS
test eax, eax
jne front_moved
add dword [esi+8], 1
jmp front_look
front_moved:
mov [ebx], edx
movzx eax, word [esi+ecx+20]
mov [ebx+4], eax
movzx eax, word [esi+ecx+22]
mov [ebx+8], eax
front_stands:
mov dword [ROUTE_CURRENT_ADDRESS], 0
mov edx, [ebx]
pop esi
ret
front_none:
xor edx, edx
pop esi
ret
]]

-- Laying a tunnel's next leg along its line's route without searching for it at all.
--
-- Which fortification: the first one on the route, ahead of where the tunneller stands,
-- that still stands and that no other tunnel has been sent at in the last CLAIM_TICKS. A
-- thick wall is several fortifications on the route one tile apart, and a group of tunnels
-- arriving on the rubble together used to be sent at the same one: the first took it and
-- the rest came up under it a moment later, before it had fallen, and were spent on one
-- tile. Claiming spreads them along the route, each to its own piece. When every one
-- ahead is claimed the tunnel doubles up on the first of them rather than do nothing.
--
-- How: the game's trace, setDestinationForUnit(..., 2), walks back from the target to the
-- tunneller over tiles that carry the number of the search that reached the target and a
-- distance one or two lower each step - that is all it reads. The route already is such a
-- walk. So the stretch between the tunneller and its fortification is written into the
-- search's own maps under a fresh search number - distance 1 where the tunneller stands,
-- rising by one a tile - exactly as a search would have left it, and the game's trace lays
-- the path over it as it always does. What that costs is the length of the stretch, where
-- a search costs the area of everything within the same distance.
--
-- The search number is the game's own counter at PathFindingState + 4, moved on by one as
-- every search moves it; near the top of its range the game clears its flag map when the
-- counter wraps, so there this simply declines and the search does the job instead. It also
-- declines when the tunneller is not on the route or nothing stands on it ahead.
--
-- In: EBX the line, EDI the tile the tunneller stands on. Out: EAX 1 with the game's result
-- words set to the target, 0 when the search is needed. EAX, ECX and EDX.
local follow_route = [[
push esi
push ebp
mov esi, ebx
sub esi, LINE_ADDRESS
shr esi, 4
imul esi, esi, ROUTE_SIZE
add esi, ROUTES_ADDRESS
xor eax, eax
cmp dword [esi], 1
jne follow_out
xor ecx, ecx
follow_find:
cmp ecx, [esi+12]
jae follow_out
cmp [esi+ecx*4+PATH_OFFSET], edi
je follow_found
add ecx, 1
jmp follow_find
follow_found:
mov [FOLLOW_AT_ADDRESS], ecx
mov dword [FOLLOW_FIRST_ADDRESS], -1
mov ebp, [esi+8]
follow_scan:
cmp ebp, [esi+4]
jae follow_scanned
mov ecx, ebp
shl ecx, 4
mov eax, [esi+ecx+24]
cmp eax, [FOLLOW_AT_ADDRESS]
jbe follow_skip
mov edx, [esi+ecx+16]
call STANDS_ADDRESS
test eax, eax
je follow_skip
cmp dword [FOLLOW_FIRST_ADDRESS], -1
jne follow_first_known
mov [FOLLOW_FIRST_ADDRESS], ebp
follow_first_known:
mov eax, [esi+ecx+28]
test eax, eax
je follow_pick
mov edx, [TICKS_ADDRESS]
sub edx, eax
cmp edx, CLAIM_TICKS
ja follow_pick
follow_skip:
add ebp, 1
jmp follow_scan
follow_scanned:
mov ebp, [FOLLOW_FIRST_ADDRESS]
xor eax, eax
cmp ebp, -1
je follow_out
follow_pick:
mov edx, [PATH_STATE_ADDRESS+4]
add edx, 1
cmp edx, SEARCH_NUMBER_LIMIT
jg follow_decline
mov [PATH_STATE_ADDRESS+4], edx
mov [ROUTE_GEN_ADDRESS], edx
mov [FOLLOW_PICK_ADDRESS], ebp
shl ebp, 4
mov eax, [TICKS_ADDRESS]
mov [esi+ebp+28], eax
mov ebp, [esi+ebp+24]
mov ecx, [FOLLOW_AT_ADDRESS]
mov eax, 1
follow_stamp:
mov edx, [esi+ecx*4+PATH_OFFSET]
mov [edx*2+DISTANCE_MAP_ADDRESS], ax
push eax
mov eax, [ROUTE_GEN_ADDRESS]
mov [edx*2+FLAG_MAP_ADDRESS], ax
pop eax
add eax, 1
add ecx, 1
cmp ecx, ebp
jbe follow_stamp
mov ecx, [FOLLOW_PICK_ADDRESS]
shl ecx, 4
mov edx, [esi+ecx+16]
mov [ALG_RESULT_ADDRESS], edx
movzx edx, word [esi+ecx+20]
mov [ALG_TARGET_X_ADDRESS], edx
movzx edx, word [esi+ecx+22]
mov [ALG_TARGET_Y_ADDRESS], edx
mov eax, 1
jmp follow_out
follow_decline:
xor eax, eax
follow_out:
pop ebp
pop esi
ret
]]

-- Laying out a line's route, once. The search runs from the line's own spot - where its
-- first target stood, rubble now - taking nothing, so it spreads through walls, gates,
-- towers and (when tunnels may pass under the town) houses alike until it is a little
-- further from its start, in steps, than the campfire is: every tile it reaches holds its
-- distance from the breach in the search's own map. route_walk then reads the route out of
-- that map. It is the only full spread a line ever costs, and it is paid once.
--
-- The state is left at 1 when a route was read out - even an empty one, which means the
-- way to the campfire is already open - and at 2 when it could not be: no campfire known,
-- or the search never came near it. In: EBX the line, ESI its route. EAX, ECX and EDX.
local route_build = [[
push edi
mov dword [esi], 2
mov dword [esi+4], 0
mov dword [esi+8], 0
mov dword [esi+12], 0
mov eax, [AIM_UNIT_ADDRESS]
mov [ANCHOR_UNIT_ADDRESS], eax
call ANCHOR_ADDRESS
test eax, eax
je build_out
push dword [AIM_FROM_X_ADDRESS]
push dword [AIM_FROM_Y_ADDRESS]
push dword [AIM_RANGE_ADDRESS]
mov eax, [ebx+4]
mov [AIM_FROM_X_ADDRESS], eax
mov eax, [ebx+8]
mov [AIM_FROM_Y_ADDRESS], eax
mov eax, [CAMP_X_ADDRESS]
sub eax, [ebx+4]
cdq
xor eax, edx
sub eax, edx
mov ecx, eax
mov eax, [CAMP_Y_ADDRESS]
sub eax, [ebx+8]
cdq
xor eax, edx
sub eax, edx
add eax, ecx
add eax, ROUTE_SLACK
cmp eax, ROUTE_REACH
jbe build_range_set
mov eax, ROUTE_REACH
build_range_set:
mov [AIM_RANGE_ADDRESS], eax
mov [REPORT_ADDRESS+16], eax
mov dword [AIM_MODE_ADDRESS], 3
mov dword [SEARCHED_ADDRESS], 1
call LINE_SEARCH_ADDRESS
mov eax, [PATH_STATE_ADDRESS+4]
mov [ROUTE_GEN_ADDRESS], eax
pop dword [AIM_RANGE_ADDRESS]
pop dword [AIM_FROM_Y_ADDRESS]
pop dword [AIM_FROM_X_ADDRESS]
call ROUTE_WALK_ADDRESS
test eax, eax
jl build_out
mov dword [esi], 1
cmp dword [DIAGNOSTICS_ADDRESS], 0
je build_out
mov [REPORT_ADDRESS+12], eax
mov eax, [AIM_OWNER_ADDRESS]
mov [REPORT_ADDRESS], eax
mov eax, [esi+16]
mov [REPORT_ADDRESS+4], eax
mov eax, [esi+12]
mov [REPORT_ADDRESS+8], eax
mov dword [REPORT_ADDRESS+28], 44
call REPORT_PAD_ADDRESS
build_out:
pop edi
ret
]]

-- Reading the route out of the search's map. It ends at the campfire's own tile, or - the
-- campfire being a building the search may not have been let into - at the tile it did
-- reach nearest the campfire, looked for within END_RADIUS. From there it walks downhill:
-- every tile the search reached carries its distance from the start, and each has a
-- neighbour one nearer, so stepping to that neighbour again and again retraces the
-- search's own way back to the breach - round the keep, since the search never went under
-- it. Every tile stepped on is the route's path, and every enemy wall, stair,
-- crenellation, gate or tower among them a fortification on it - but not a stockpile,
-- whose wall bit marks a footprint that cannot be damaged, not a wall in the way. The
-- walk finds them campfire first; both are written into the route the other way round, breach first, and
-- only the ROUTE_ENTRIES fortifications nearest the breach are kept, each with its place
-- on the path.
--
-- A tile counts as reached only if the search stamped it this time: the flag map holds
-- the number of the search that last reached each tile, and PathFindingState + 4 the
-- number of the latest. In: ESI the route. Out: EAX how many fortifications, or -1 when
-- the search came nowhere near the campfire. EBX, ESI, EDI and EBP are kept.
local route_walk = [[
push ebx
push ebp
push edi
xor edi, edi
mov dword [ROUTE_BEST_ADDRESS], -1
mov ebp, -END_RADIUS
walk_end_row:
mov ebx, -END_RADIUS
walk_end_col:
mov eax, [CAMP_X_ADDRESS]
add eax, ebx
cmp eax, 1
jl walk_end_next
cmp eax, MAP_LIMIT
jg walk_end_next
mov ecx, [CAMP_Y_ADDRESS]
add ecx, ebp
cmp ecx, 1
jl walk_end_next
cmp ecx, MAP_LIMIT
jg walk_end_next
mov [WALK_X_ADDRESS], eax
mov [WALK_Y_ADDRESS], ecx
lea edx, [ecx+ecx*2]
mov edx, [edx*4+ROW_TABLE_ADDRESS]
add edx, eax
movsx eax, word [edx*2+FLAG_MAP_ADDRESS]
cmp eax, [ROUTE_GEN_ADDRESS]
jne walk_end_next
mov eax, ebx
imul eax, eax
mov ecx, ebp
imul ecx, ecx
add eax, ecx
cmp eax, [ROUTE_BEST_ADDRESS]
jae walk_end_next
mov [ROUTE_BEST_ADDRESS], eax
mov edi, edx
mov eax, [WALK_X_ADDRESS]
mov [ROUTE_X_ADDRESS], eax
mov eax, [WALK_Y_ADDRESS]
mov [ROUTE_Y_ADDRESS], eax
walk_end_next:
add ebx, 1
cmp ebx, END_RADIUS
jle walk_end_col
add ebp, 1
cmp ebp, END_RADIUS
jle walk_end_row
mov eax, -1
test edi, edi
je walk_out
mov dword [ROUTE_FOUND_ADDRESS], 0
mov dword [PATH_FOUND_ADDRESS], 0
walk_step:
movsx ebp, word [edi*2+DISTANCE_MAP_ADDRESS]
mov ecx, [PATH_FOUND_ADDRESS]
cmp ecx, PATH_MAX
jae walk_path_full
mov [ecx*4+PATH_TEMP_ADDRESS], edi
add dword [PATH_FOUND_ADDRESS], 1
walk_path_full:
test dword [edi*4+TILE_FLAGS_ADDRESS], STOCKPILE
jnz walk_passed
test dword [edi*4+TILE_FLAGS_ADDRESS], WALL_FAMILY
jz walk_building
movzx eax, byte [edi+WALL_OWNER_ADDRESS]
and eax, 7
add eax, 1
jmp walk_whose
walk_building:
movzx eax, word [edi*2+BUILDING_TILE_ADDRESS]
test eax, eax
je walk_passed
imul eax, eax, BUILDING_STRIDE
movsx ecx, word [eax+BUILDING_TYPE]
cmp ecx, TYPE_LIMIT
ja walk_passed
cmp dword [ecx*4+GATE_OR_TOWER_ADDRESS], 0
je walk_passed
movsx eax, word [eax+BUILDING_OWNER]
walk_whose:
cmp eax, [AIM_OWNER_ADDRESS]
je walk_passed
mov ecx, [eax*4+TEAMS_ADDRESS]
test ecx, ecx
je walk_enemy
mov edx, [AIM_OWNER_ADDRESS]
cmp ecx, [edx*4+TEAMS_ADDRESS]
je walk_passed
walk_enemy:
mov ecx, [ROUTE_FOUND_ADDRESS]
cmp ecx, FOUND_MAX
jae walk_passed
lea ecx, [ecx+ecx*2]
mov [ecx*4+ROUTE_TEMP_ADDRESS], edi
mov eax, [ROUTE_X_ADDRESS]
mov [ecx*4+ROUTE_TEMP_ADDRESS+4], ax
mov eax, [ROUTE_Y_ADDRESS]
mov [ecx*4+ROUTE_TEMP_ADDRESS+6], ax
mov eax, [PATH_FOUND_ADDRESS]
sub eax, 1
mov [ecx*4+ROUTE_TEMP_ADDRESS+8], eax
add dword [ROUTE_FOUND_ADDRESS], 1
walk_passed:
cmp ebp, 1
jle walk_home
lea ebx, [ebp-1]
mov ecx, [ROUTE_Y_ADDRESS]
shl ecx, 5
add ecx, DIRECTIONS_ADDRESS
xor edx, edx
walk_dir:
mov eax, [ecx+edx*8]
add eax, edi
cmp word [eax*2+DISTANCE_MAP_ADDRESS], bx
jne walk_other
push edx
movsx edx, word [eax*2+FLAG_MAP_ADDRESS]
cmp edx, [ROUTE_GEN_ADDRESS]
pop edx
jne walk_other
mov edi, eax
mov eax, edx
shl eax, 4
mov ecx, [eax+X_DELTAS_ADDRESS]
add [ROUTE_X_ADDRESS], ecx
mov ecx, [eax+Y_DELTAS_ADDRESS]
add [ROUTE_Y_ADDRESS], ecx
jmp walk_step
walk_other:
add edx, 1
cmp edx, 4
jb walk_dir
walk_home:
mov ebx, [PATH_FOUND_ADDRESS]
mov [esi+12], ebx
xor edx, edx
walk_path_copy:
cmp edx, ebx
jae walk_path_copied
mov ecx, ebx
sub ecx, edx
mov eax, [ecx*4+PATH_TEMP_ADDRESS-4]
mov [esi+edx*4+PATH_OFFSET], eax
add edx, 1
jmp walk_path_copy
walk_path_copied:
mov ecx, [ROUTE_FOUND_ADDRESS]
xor edx, edx
walk_copy:
cmp edx, ROUTE_ENTRIES
jae walk_copied
test ecx, ecx
je walk_copied
sub ecx, 1
lea ebp, [ecx+ecx*2]
mov edi, edx
shl edi, 4
mov eax, [ebp*4+ROUTE_TEMP_ADDRESS]
mov [esi+edi+16], eax
mov eax, [ebp*4+ROUTE_TEMP_ADDRESS+4]
mov [esi+edi+20], eax
mov eax, ebx
sub eax, 1
sub eax, [ebp*4+ROUTE_TEMP_ADDRESS+8]
mov [esi+edi+24], eax
mov dword [esi+edi+28], 0
add edx, 1
jmp walk_copy
walk_copied:
mov [esi+4], edx
mov eax, edx
walk_out:
pop edi
pop ebp
pop ebx
ret
]]

-- The first target a tunnel is given. Replaces the call to findTunnelTarget in the
-- tunneler's state 9, which the game makes once a tick - widening its search 20, 20, 40,
-- 40, 80, 80 tiles - until it finds something. That call still happens, unchanged, and
-- decides when the tunnel is ready; nothing is done until it has an answer.
--
-- Then each of the player's lines is tried in turn for its front (line_front): the line's
-- target, or - once that is down - the first fortification standing on its route. The
-- first front the tunnel can reach (aim_at_line) is joined, and the game goes on to trace
-- the path there. A front that is the game's own answer is joined without a search at
-- all. If none answers, the tunnel starts a line of its own with the game's answer.
--
-- Whenever any search of ours ran and the answer is the game's own after all, the game's
-- search is run once more at its own full reach, so that its answer and the map the path
-- is traced along are what they were. A line nobody has used for LINE_LIFETIME ticks is
-- dropped: the siege it belonged to has stopped, or the game was restarted or loaded - one
-- unsigned comparison catches both, since a clock that went backwards makes the difference
-- wrap to something enormous. OURS records that the answer is a line rather than the
-- game's own, for the net below. EAX goes back as findTunnelTarget's own answer; EBX, ESI
-- and EDI are kept.
local place_aim = [[
mov dword [OURS_ADDRESS], 0
mov dword [QUIET_ADDRESS], 0
call FIND_TARGET_ADDRESS
test eax, eax
je place_done
cmp dword [RETARGET_ENABLED_ADDRESS], 0
je place_found
push ebx
push esi
push edi
mov ecx, [ALG_RESULT_ADDRESS]
mov [GAME_TILE_ADDRESS], ecx
mov ecx, [ALG_TARGET_X_ADDRESS]
mov [GAME_X_ADDRESS], ecx
mov ecx, [ALG_TARGET_Y_ADDRESS]
mov [GAME_Y_ADDRESS], ecx
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
mov [AIM_UNIT_ADDRESS], eax
movsx ecx, word [eax+UNIT_OWNER]
mov [AIM_OWNER_ADDRESS], ecx
movsx ecx, word [eax+UNIT_SIEGE_TARGET]
mov [AIM_SIEGE_ADDRESS], ecx
mov ecx, [RANGE_ADDRESS]
mov [AIM_RANGE_ADDRESS], ecx
movsx ecx, word [eax+UNIT_WORKPLACE]
imul ecx, ecx, BUILDING_STRIDE
movsx edx, word [ecx+BUILDING_SOME_X]
mov [AIM_FROM_X_ADDRESS], edx
movsx edx, word [ecx+BUILDING_SOME_Y]
mov [AIM_FROM_Y_ADDRESS], edx
call RECORD_OF_ADDRESS
mov ecx, [RECORD_ADDRESS]
mov dword [ecx+4], 0
mov dword [ecx+8], 0
mov dword [SEARCHED_ADDRESS], 0
mov ebx, [AIM_OWNER_ADDRESS]
shl ebx, 6
add ebx, LINE_ADDRESS
mov edi, 4
place_try:
mov edx, [ebx]
test edx, edx
jle place_next
mov eax, [TICKS_ADDRESS]
sub eax, [ebx+12]
cmp eax, LINE_LIFETIME
jbe place_current
mov dword [ebx], 0
jmp place_next
place_current:
call LINE_FRONT_ADDRESS
test edx, edx
je place_next
cmp edx, [GAME_TILE_ADDRESS]
je place_is_line
call AIM_AT_LINE_ADDRESS
test eax, eax
jne place_joined
place_next:
add ebx, 16
sub edi, 1
jnz place_try
call place_restore
call NEW_LINE_ADDRESS
mov dword [REPORT_ADDRESS+20], 2
jmp place_report
place_joined:
mov dword [OURS_ADDRESS], 1
mov dword [QUIET_ADDRESS], 1
mov dword [REPORT_ADDRESS+20], 1
jmp place_mine
place_is_line:
call place_restore
mov dword [REPORT_ADDRESS+20], 3
place_mine:
mov ecx, [RECORD_ADDRESS]
mov [ecx+8], ebx
mov eax, [TICKS_ADDRESS]
mov [ebx+12], eax
place_report:
cmp dword [DIAGNOSTICS_ADDRESS], 0
je place_quiet
mov eax, [CURRENT_UNIT_ADDRESS]
mov [REPORT_ADDRESS], eax
mov eax, [ALG_RESULT_ADDRESS]
mov [REPORT_ADDRESS+4], eax
mov dword [REPORT_ADDRESS+8], 0
mov eax, [GAME_TILE_ADDRESS]
mov [REPORT_ADDRESS+12], eax
mov eax, [RECORD_ADDRESS]
mov eax, [eax+8]
sub eax, LINE_ADDRESS
shr eax, 4
mov [REPORT_ADDRESS+16], eax
mov dword [REPORT_ADDRESS+28], 40
call REPORT_PAD_ADDRESS
place_quiet:
pop edi
pop esi
pop ebx
place_found:
mov eax, 1
place_done:
jmp RETURN_ADDRESS
place_restore:
cmp dword [SEARCHED_ADDRESS], 0
je place_restored
mov dword [AIM_RANGE_ADDRESS], VANILLA_RANGE
call LINE_SEARCH_ADDRESS
place_restored:
ret
]]

-- The net under that. The game traces the tunnel's path the moment it has its target, and
-- if the trace fails it tears the entrance down on the spot. The search and the tracer do
-- not always agree, so when the target was the line - a choice the unmodified game would
-- not have made - and the trace fails, the game's own answer is searched for again from
-- the same spot and traced instead. Only when that fails too does the game give up, which
-- is exactly when the unmodified game would have.
--
-- Hooked on the test straight after the trace, with EAX its result. The unit is already
-- standing at the entrance, which is where the search starts.
local place_net = [[
mov dword [QUIET_ADDRESS], 0
test eax, eax
jne net_laid
cmp dword [OURS_ADDRESS], 0
je net_give_up
mov dword [OURS_ADDRESS], 0
mov dword [AIM_RANGE_ADDRESS], VANILLA_RANGE
call LINE_SEARCH_ADDRESS
push 2
push dword [GAME_Y_ADDRESS]
push dword [GAME_X_ADDRESS]
push dword [CURRENT_UNIT_ADDRESS]
mov ecx, UNITS_STATE_ADDRESS
call SET_DESTINATION_ADDRESS
cmp dword [DIAGNOSTICS_ADDRESS], 0
je net_quiet
push eax
mov [REPORT_ADDRESS+12], eax
mov eax, [CURRENT_UNIT_ADDRESS]
mov [REPORT_ADDRESS], eax
mov eax, [GAME_TILE_ADDRESS]
mov [REPORT_ADDRESS+4], eax
mov dword [REPORT_ADDRESS+28], 45
call REPORT_PAD_ADDRESS
pop eax
net_quiet:
test eax, eax
jne net_laid
net_give_up:
jmp GIVE_UP_ADDRESS
net_laid:
jmp LAID_ADDRESS
]]

-- The search inside the cone towards the enemy's campfire, for the tunnel at AIM_UNIT (the
-- scaled unit in ESI) from AIM_FROM. Nothing is searched when there is no camp to aim at,
-- or the tunnel stands on it. Out: EAX the tile found, 0 for none; SEARCHED set when a
-- search ran. EAX, ECX and EDX.
local aim_cone = [[
push ebx
mov [ANCHOR_UNIT_ADDRESS], esi
call ANCHOR_ADDRESS
test eax, eax
je cone_none
mov eax, [CAMP_X_ADDRESS]
sub eax, [AIM_FROM_X_ADDRESS]
mov ecx, [CAMP_Y_ADDRESS]
sub ecx, [AIM_FROM_Y_ADDRESS]
mov edx, eax
test edx, edx
jge cone_abs_x
neg edx
cone_abs_x:
mov ebx, ecx
test ebx, ebx
jge cone_abs_y
neg ebx
cone_abs_y:
cmp edx, ebx
jge cone_longest
mov edx, ebx
cone_longest:
test edx, edx
je cone_none
mov ebx, edx
imul eax, eax, 64
cdq
idiv ebx
mov [AIM_DIR_X_ADDRESS], eax
mov eax, ecx
imul eax, eax, 64
cdq
idiv ebx
mov [AIM_DIR_Y_ADDRESS], eax
imul eax, eax
mov ecx, [AIM_DIR_X_ADDRESS]
imul ecx, ecx
add eax, ecx
mov [AIM_DIR_LENGTH_ADDRESS], eax
mov dword [SEARCHED_ADDRESS], 1
mov dword [AIM_MODE_ADDRESS], 2
call LINE_SEARCH_ADDRESS
pop ebx
ret
cone_none:
xor eax, eax
pop ebx
ret
]]

-- A tunnel on its way that comes under a standing enemy fortification collapses there.
-- Whatever the route says - it can call the way to the campfire open when the search that
-- measured it slipped through a gate, past a ladder or a siege tower - the ground the tunnel
-- actually crosses has the last word. Hooked on UpdateTunneler's "not there yet" branch, so
-- it looks once a tick at the tile the tunneller is under; when that is an enemy wall,
-- stair, crenellation, gate or tower, the tunnel is cut short right there - its plan ends
-- where it has got to, its destination is here - and handed to the arrival as if it had
-- arrived, which lets the game collapse it the way it collapses any tunnel.
--
-- A stockpile is passed under: the game marks it with the wall bit, but it cannot be
-- damaged, and a tunnel collapsing beneath it would be wasted.
--
-- Two exceptions: its own destination, which the ordinary arrival takes care of, and a
-- fortification on its line's route that another tunnel was sent at within CLAIM_TICKS -
-- that is the thick wall being taken a tile per tunnel, and passing under the tiles the
-- others are bringing down is the point. EAX is the game's "arrived"; everything else kept.
local crossing = [[
test eax, eax
jne ARRIVED_ADDRESS
cmp dword [ENABLED_ADDRESS], 0
je cross_off
push ebx
push esi
mov esi, [CURRENT_UNIT_ADDRESS]
imul esi, esi, 1168
mov ecx, [esi+UNIT_TILE]
test dword [ecx*4+TILE_FLAGS_ADDRESS], STOCKPILE
jnz cross_none
test dword [ecx*4+TILE_FLAGS_ADDRESS], WALL_FAMILY
jz cross_building
movzx eax, byte [ecx+WALL_OWNER_ADDRESS]
and eax, 7
add eax, 1
jmp cross_whose
cross_building:
movzx eax, word [ecx*2+BUILDING_TILE_ADDRESS]
test eax, eax
je cross_none
imul eax, eax, BUILDING_STRIDE
movsx edx, word [eax+BUILDING_TYPE]
cmp edx, TYPE_LIMIT
ja cross_none
cmp dword [edx*4+GATE_OR_TOWER_ADDRESS], 0
je cross_none
movsx eax, word [eax+BUILDING_OWNER]
cross_whose:
movsx edx, word [esi+UNIT_OWNER]
cmp eax, edx
je cross_none
mov ebx, [eax*4+TEAMS_ADDRESS]
test ebx, ebx
je cross_enemy
cmp ebx, [edx*4+TEAMS_ADDRESS]
je cross_none
cross_enemy:
mov ax, [esi+UNIT_X]
cmp ax, [esi+UNIT_DEST_X]
jne cross_elsewhere
mov ax, [esi+UNIT_Y]
cmp ax, [esi+UNIT_DEST_Y]
je cross_none
cross_elsewhere:
mov edx, [esi+UNIT_UID]
mov eax, RECORDS_ADDRESS
cross_record:
cmp [eax], edx
je cross_record_found
add eax, 16
cmp eax, RECORDS_END_ADDRESS
jb cross_record
jmp cross_cut
cross_record_found:
mov eax, [eax+8]
test eax, eax
je cross_cut
sub eax, LINE_ADDRESS
shr eax, 4
imul eax, eax, ROUTE_SIZE
add eax, ROUTES_ADDRESS
cmp dword [eax], 1
jne cross_cut
mov ebx, [eax+4]
lea edx, [eax+16]
cross_entry:
test ebx, ebx
je cross_cut
cmp [edx], ecx
jne cross_entry_next
mov eax, [TICKS_ADDRESS]
sub eax, [edx+12]
cmp dword [edx+12], 0
je cross_cut
cmp eax, CLAIM_TICKS
jb cross_none
jmp cross_cut
cross_entry_next:
add edx, 16
sub ebx, 1
jmp cross_entry
cross_cut:
mov ax, [esi+UNIT_PATH_INDEX]
mov [esi+UNIT_PATH_LENGTH], ax
mov ax, [esi+UNIT_X]
mov [esi+UNIT_DEST_X], ax
mov ax, [esi+UNIT_Y]
mov [esi+UNIT_DEST_Y], ax
mov [esi+UNIT_DEST_TILE], ecx
mov word [esi+UNIT_MOVE_STATUS], 0
pop esi
pop ebx
jmp ARRIVED_ADDRESS
cross_none:
pop esi
pop ebx
cross_off:
jmp NOT_ARRIVED_ADDRESS
]]

-- A stopwatch round UpdateTunneler, for the diagnostics. Sits on the function's entry: with
-- diagnostics off it replays the two instructions it replaced and goes on, as if it were not
-- there; with them on it calls the whole function as a subroutine and reads the time stamp
-- counter either side (in units of 1024 cycles), adding what each tunneller's update cost -
-- its searches, its path, its collapse and the game's damage - to this tick's total, and
-- keeping the dearest one with the state it started in and REDIRECT_HOW. queue_tick reads
-- and clears those at the start of every tick, and reports a tick that took far longer
-- than usual. EAX comes back as the function's own; the rest as the function leaves them.
local tunneler_timed = [[
cmp dword [DIAGNOSTICS_ADDRESS], 0
je timed_plain
push ebx
rdtsc
shrd eax, edx, 10
push eax
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
movzx eax, word [eax+UNIT_STATE]
push eax
mov dword [REDIRECT_HOW_ADDRESS], 0
call timed_plain
pop ecx
pop ebx
push eax
rdtsc
shrd eax, edx, 10
sub eax, ebx
add [SW_TUNNEL_ADDRESS], eax
add dword [SW_COUNT_ADDRESS], 1
cmp eax, [SW_MAX_ADDRESS]
jbe timed_small
mov [SW_MAX_ADDRESS], eax
mov [SW_MAX_STATE_ADDRESS], ecx
mov eax, [CURRENT_UNIT_ADDRESS]
mov [SW_MAX_UNIT_ADDRESS], eax
mov eax, [REDIRECT_HOW_ADDRESS]
mov [SW_MAX_HOW_ADDRESS], eax
timed_small:
pop eax
pop ebx
ret
timed_plain:
jmp BODY_ADDRESS
]]

-- The two instructions at UpdateTunneler's entry, for the stopwatch to call when nothing
-- else is hooked there.
local tunneler_entry = [[
push ecx
mov ecx, [FIRST_OPERAND]
jmp RETURN_ADDRESS
]]

-- AI raids. getDefensiveTribeForUnit sorts the units an AI recruits for raiding into its six
-- raid troops by looking the unit type up in a table of twenty - knights, horse archers,
-- the ranged units, two kinds of melee and the siege engines - and a type that is not in
-- it gets no troop at all: the tunneller is recruited and never ordered anywhere. Here a
-- tunneller is looked up as a maceman, so it joins the light melee troop, and the game's
-- own raid orders (move, attack this building) already treat it as the melee unit it is.
--
-- The unit the lookup is handed is not a tunneller yet. Recruiting takes a peasant from the
-- campfire and sends it to the Tunneler's Guild with the type it is to become written into
-- unitTypeToChangeInto, and it is sorted into its troop there and then, on the way. The
-- lookup compares both types against the table, so either one being the tunneller's is
-- enough to take it for a maceman - the peasant keeps its troop when the guild turns it
-- into a tunneller, just as a maceman's keeps it at the barracks.
-- Replaces `movsx edx, word [edi+unitType]`; EDX is the type the lookup compares.
local raid_tribe = [[
movsx edx, word [edi+UNIT_TYPE_OPERAND]
cmp dword [ENABLED_ADDRESS], 0
je raid_tribe_back
cmp edx, TUNNELER_TYPE
je raid_tribe_tunneller
cmp word [edi+CHANGE_INTO_OPERAND], TUNNELER_TYPE
jne raid_tribe_back
raid_tribe_tunneller:
cmp dword [DIAGNOSTICS_ADDRESS], 0
je raid_tribe_quiet
pushad
mov eax, edi
xor edx, edx
mov ecx, UNIT_SIZE
div ecx
mov [REPORT_ADDRESS], eax
mov eax, [esp+32+12]
mov [REPORT_ADDRESS+4], eax
mov dword [REPORT_ADDRESS+28], 48
call REPORT_PAD_ADDRESS
popad
raid_tribe_quiet:
mov edx, STAND_IN_TYPE
raid_tribe_back:
jmp RETURN_ADDRESS
]]

-- ... and in aiRecruitUnits, where the building a unit is recruited at turns out not to
-- exist: the game gives up on the whole recruiting pass. For a tunneller with no
-- Tunneler's Guild that pass goes on to the next unit instead. EAX is the building.
local raid_no_guild = [[
test eax, eax
jne RECRUIT_ADDRESS
cmp dword [ENABLED_ADDRESS], 0
je EXIT_ADDRESS
cmp ebx, TUNNELER_TYPE
jne EXIT_ADDRESS
cmp dword [DIAGNOSTICS_ADDRESS], 0
je NEXT_ADDRESS
pushad
mov [REPORT_ADDRESS], ebp
mov dword [REPORT_ADDRESS+28], 49
call REPORT_PAD_ADDRESS
popad
jmp NEXT_ADDRESS
]]

-- Inside traceAndCommitPathPlan, where the trace has found no way back to the unit. The
-- game takes that to mean its own maps are stale and rebuilds the path linkage of every
-- building and the separate-area map of the whole map before it gives up: millions of
-- instructions, all in one tick - the lag spike that came with a tunnel's refused path.
-- For a path this module asked for (QUIET set) the maps are not stale, the corridor simply
-- does not lead back, so the plan is emptied and the trace returns at once. Everything
-- else, the game's own units included, still gets the rebuild.
local quiet_trace = [[
mov edi, [esp+0x10]
add dword [edi+0x78], 1
cmp dword [QUIET_ADDRESS], 0
je quiet_rebuild
mov dword [edi+PLAN_LENGTH_FIELD], 0
jmp DONE_ADDRESS
quiet_rebuild:
jmp RETURN_ADDRESS
]]

-- Sending a tunnel on from where it stands, once it has arrived on empty ground.
--
--   1  its line's front (line_front): the line's target while that stands, else the next
--      fortification standing on the line's route to the campfire - laid along the route
--      with no search at all when the tunneller stands on it (follow_route), else one short
--      search, and none at all for a front out of reach
--   2  with the route open all the way, the nearest fortification of all, to widen it
--   3  with no line, or a line with no route, the nearest fortification inside the cone
--      towards the enemy's campfire, then the nearest of all
--
-- Then the line moves on to whatever was chosen if what it pointed at is gone - or, for a
-- tunnel that has no line, a line is started - and the tunnel is extended to it
-- (extend_plan). Each tunnel may be sent on only so many times.
--
-- EAX comes back 1 when the tunnel is on its way somewhere new, 0 when it should
-- collapse where it is, and 2 when it should wait where it is: the game refused to lay the
-- path to the target chosen. That target is set aside for REFUSED_TICKS so no search takes
-- it again, and the spot it stands on is left alone for WAIT_TICKS - every tunnel arriving
-- there waits too, rather than each running the same searches only to be refused the same
-- way. The try counts against the tunnel's allowance, so none waits for ever.
--
-- One search per call, never more. Laying out the route, the search for the line, the cone
-- and the widening are each a search, and one arrival used to run up to four of them and a
-- path in a single tick. Now, when a second search would be needed, the tunnel waits where
-- it stands (EAX 2, REDIRECT_HOW 9) and the step it has reached is kept in its record as
-- ticks * 4 + step - 0 from the top, 1 the cone, 2 widening - so the next tick carries on
-- there instead of repeating what already failed. A step older than STEP_WINDOW ticks is
-- forgotten and the tunnel starts from the top.
--
-- REDIRECT_HOW says which way it went (7 along its line's route, 1 its line by a search, 2
-- the cone, 3 widening), or why not (4 used up, 5 nothing in reach, 6 the path would not
-- lay, 8 the tunnel is as long as a plan can hold, 9 waiting its turn for a search). The
-- line only moves on once the path to its new target is actually laid. EBX, ESI and EDI
-- are kept.
local redirect = [[
push ebx
push esi
push edi
mov esi, [CURRENT_UNIT_ADDRESS]
imul esi, esi, 1168
mov [AIM_UNIT_ADDRESS], esi
call RECORD_OF_ADDRESS
mov dword [REDIRECT_HOW_ADDRESS], 4
mov ecx, [RECORD_ADDRESS]
mov edx, [ecx+4]
cmp edx, [MAX_ADDRESS]
jae redirect_none
movsx ecx, word [esi+UNIT_OWNER]
mov [AIM_OWNER_ADDRESS], ecx
movsx ecx, word [esi+UNIT_SIEGE_TARGET]
mov [AIM_SIEGE_ADDRESS], ecx
mov ecx, [RANGE_ADDRESS]
mov [AIM_RANGE_ADDRESS], ecx
movsx ecx, word [esi+UNIT_X]
mov [AIM_FROM_X_ADDRESS], ecx
movsx ecx, word [esi+UNIT_Y]
mov [AIM_FROM_Y_ADDRESS], ecx
mov edi, [esi+UNIT_TILE]
mov dword [SEARCHED_ADDRESS], 0
mov ecx, [RECORD_ADDRESS]
mov eax, [TICKS_ADDRESS]
shl eax, 2
sub eax, [ecx+12]
mov edx, [ecx+12]
mov dword [ecx+12], 0
cmp eax, STEP_WINDOW
jae redirect_top
and edx, 3
cmp edx, 1
je redirect_cone
cmp edx, 2
je redirect_widen
redirect_top:
mov ebx, [ecx+8]
test ebx, ebx
je redirect_cone
mov eax, [TICKS_ADDRESS]
sub eax, [ebx+12]
cmp eax, LINE_LIFETIME
jbe redirect_line_current
mov dword [ecx+8], 0
jmp redirect_cone
redirect_line_current:
call LINE_FRONT_ADDRESS
test edx, edx
jne redirect_front
mov eax, [ROUTE_CURRENT_ADDRESS]
test eax, eax
je redirect_cone
cmp dword [eax], 1
je redirect_widen
jmp redirect_cone
redirect_front:
cmp edx, edi
je redirect_cone
mov dword [REDIRECT_HOW_ADDRESS], 7
call FOLLOW_ROUTE_ADDRESS
test eax, eax
jne redirect_go
xor edx, edx
cmp dword [SEARCHED_ADDRESS], 0
jne redirect_later
call AIM_AT_LINE_ADDRESS
mov dword [REDIRECT_HOW_ADDRESS], 1
test eax, eax
jne redirect_go
mov eax, ebx
sub eax, LINE_ADDRESS
shr eax, 4
imul eax, eax, ROUTE_SIZE
add eax, ROUTES_ADDRESS
cmp dword [eax], 1
je redirect_widen
redirect_cone:
mov edx, 1
cmp dword [SEARCHED_ADDRESS], 0
jne redirect_later
call AIM_CONE_ADDRESS
mov dword [REDIRECT_HOW_ADDRESS], 2
test eax, eax
jne redirect_go
redirect_widen:
mov edx, 2
cmp dword [SEARCHED_ADDRESS], 0
jne redirect_later
mov dword [AIM_MODE_ADDRESS], 4
mov dword [SEARCHED_ADDRESS], 1
call LINE_SEARCH_ADDRESS
mov dword [REDIRECT_HOW_ADDRESS], 3
test eax, eax
jne redirect_go
mov dword [REDIRECT_HOW_ADDRESS], 5
jmp redirect_none
redirect_go:
call EXTEND_ADDRESS
test eax, eax
jne redirect_laid
cmp dword [EXTEND_FULL_ADDRESS], 0
jne redirect_full
mov ecx, [REFUSED_CURSOR_ADDRESS]
mov edx, [ALG_RESULT_ADDRESS]
mov [ecx], edx
mov edx, [TICKS_ADDRESS]
add edx, REFUSED_TICKS
mov [ecx+4], edx
add ecx, 8
cmp ecx, REFUSED_END_ADDRESS
jb redirect_refused_cursor
mov ecx, REFUSED_ADDRESS
redirect_refused_cursor:
mov [REFUSED_CURSOR_ADDRESS], ecx
mov [FAIL_SPOT_ADDRESS], edi
mov edx, [TICKS_ADDRESS]
add edx, WAIT_TICKS
mov [FAIL_UNTIL_ADDRESS], edx
mov ecx, [RECORD_ADDRESS]
add dword [ecx+4], 1
mov dword [REDIRECT_HOW_ADDRESS], 6
mov dword [AIM_MODE_ADDRESS], 0
mov eax, 2
jmp redirect_out
redirect_full:
mov dword [REDIRECT_HOW_ADDRESS], 8
jmp redirect_none
redirect_later:
mov ecx, [RECORD_ADDRESS]
mov eax, [TICKS_ADDRESS]
lea eax, [eax*4+edx]
mov [ecx+12], eax
mov dword [REDIRECT_HOW_ADDRESS], 9
mov dword [AIM_MODE_ADDRESS], 0
mov eax, 2
jmp redirect_out
redirect_laid:
mov ecx, [RECORD_ADDRESS]
mov ebx, [ecx+8]
test ebx, ebx
jne redirect_have_line
call NEW_LINE_ADDRESS
jmp redirect_extended
redirect_have_line:
mov edx, [ebx]
call STANDS_ADDRESS
test eax, eax
jne redirect_line_used
mov edx, [ALG_RESULT_ADDRESS]
mov [ebx], edx
mov edx, [ALG_TARGET_X_ADDRESS]
mov [ebx+4], edx
mov edx, [ALG_TARGET_Y_ADDRESS]
mov [ebx+8], edx
redirect_line_used:
mov edx, [TICKS_ADDRESS]
mov [ebx+12], edx
redirect_extended:
mov ecx, [RECORD_ADDRESS]
add dword [ecx+4], 1
mov eax, 1
jmp redirect_out
redirect_none:
mov dword [AIM_MODE_ADDRESS], 0
xor eax, eax
redirect_out:
pop edi
pop esi
pop ebx
ret
]]

-- Laying the new leg while keeping the tunnel one piece. The game's own trace,
-- setDestinationForUnit(unit, x, y, 2), always writes a fresh plan starting where the unit
-- stands: plan index 0, the ladder exit and the previous tile moved up to here. The game's
-- collapse walks a tunnel from that ladder exit along the plan, lowering the ground the dig
-- raised and doing its damage as it goes, so a plan started afresh here would leave every
-- tile dug before it raised for ever and undamaged.
--
-- So what has been dug is saved first - its steps, the ladder exit, the previous tile -
-- the trace is laid, its steps are moved up behind the saved ones (last first, so nothing
-- is overwritten before it has been read), the saved ones go back in front, and the plan
-- index is left at the join, where the unit is standing. A plan holds 800 steps; if the
-- tunnel would not fit, or the trace fails, everything is put back exactly as it was,
-- including the "arrived" status, and EAX comes back 0; EXTEND_FULL says which it was.
--
-- Steps are four bits each, two to a byte, the even step in the low half - the way the
-- game's own mover reads them. EAX 1 on success. EBX, ESI and EDI are kept.
local extend_plan = [[
push ebx
push esi
push edi
mov dword [EXTEND_FULL_ADDRESS], 0
mov esi, [AIM_UNIT_ADDRESS]
movzx edi, word [esi+UNIT_PATH_INDEX]
movzx eax, word [esi+UNIT_LADDER_X]
mov [SAVE_LADDER_X_ADDRESS], eax
movzx eax, word [esi+UNIT_LADDER_Y]
mov [SAVE_LADDER_Y_ADDRESS], eax
mov eax, [esi+UNIT_PREVIOUS_TILE]
mov [SAVE_PREVIOUS_ADDRESS], eax
lea ecx, [edi+1]
shr ecx, 1
xor edx, edx
extend_save:
cmp edx, ecx
jae extend_saved
mov al, [esi+edx+UNIT_PATH_PLAN]
mov [edx+PLAN_BUFFER_ADDRESS], al
add edx, 1
jmp extend_save
extend_saved:
push 2
push dword [ALG_TARGET_Y_ADDRESS]
push dword [ALG_TARGET_X_ADDRESS]
push dword [CURRENT_UNIT_ADDRESS]
mov ecx, UNITS_STATE_ADDRESS
mov dword [QUIET_ADDRESS], 1
call SET_DESTINATION_ADDRESS
mov dword [QUIET_ADDRESS], 0
test eax, eax
je extend_put_back
movzx ebx, word [esi+UNIT_PATH_LENGTH]
lea eax, [ebx+edi]
mov dword [EXTEND_FULL_ADDRESS], 1
cmp eax, PLAN_STEPS
ja extend_put_back
mov dword [EXTEND_FULL_ADDRESS], 0
mov ecx, ebx
extend_move:
test ecx, ecx
je extend_moved
sub ecx, 1
mov eax, ecx
shr eax, 1
movzx edx, byte [esi+eax+UNIT_PATH_PLAN]
test ecx, 1
je extend_move_low
shr edx, 4
extend_move_low:
and edx, 15
lea eax, [ecx+edi]
call extend_put
jmp extend_move
extend_moved:
xor ecx, ecx
extend_restore:
cmp ecx, edi
jae extend_restored
mov eax, ecx
shr eax, 1
movzx edx, byte [eax+PLAN_BUFFER_ADDRESS]
test ecx, 1
je extend_restore_low
shr edx, 4
extend_restore_low:
and edx, 15
mov eax, ecx
call extend_put
add ecx, 1
jmp extend_restore
extend_restored:
lea eax, [ebx+edi]
mov [esi+UNIT_PATH_LENGTH], ax
mov [esi+UNIT_PATH_INDEX], di
call extend_ladder
mov eax, 1
jmp extend_out
extend_put_back:
lea ecx, [edi+1]
shr ecx, 1
xor edx, edx
extend_unsave:
cmp edx, ecx
jae extend_unsaved
mov al, [edx+PLAN_BUFFER_ADDRESS]
mov [esi+edx+UNIT_PATH_PLAN], al
add edx, 1
jmp extend_unsave
extend_unsaved:
mov [esi+UNIT_PATH_LENGTH], di
mov [esi+UNIT_PATH_INDEX], di
mov word [esi+UNIT_MOVE_STATUS], 0
call extend_ladder
xor eax, eax
extend_out:
pop edi
pop esi
pop ebx
ret
extend_ladder:
mov eax, [SAVE_LADDER_X_ADDRESS]
mov [esi+UNIT_LADDER_X], ax
mov eax, [SAVE_LADDER_Y_ADDRESS]
mov [esi+UNIT_LADDER_Y], ax
mov eax, [SAVE_PREVIOUS_ADDRESS]
mov [esi+UNIT_PREVIOUS_TILE], eax
ret
extend_put:
push ecx
mov ecx, eax
shr ecx, 1
test eax, 1
movzx eax, byte [esi+ecx+UNIT_PATH_PLAN]
je extend_put_low
and eax, 15
shl edx, 4
or eax, edx
jmp extend_put_done
extend_put_low:
and eax, 240
or eax, edx
extend_put_done:
mov [esi+ecx+UNIT_PATH_PLAN], al
pop ecx
ret
]]

---------------------------------------------------------------------------------------
-- A tunnel reaching the end of its tunnel
---------------------------------------------------------------------------------------
-- Hooked in UpdateTunneler where hasUnitReachedDestination has just said yes and the game
-- is about to switch the tunneler into its collapse. Two things happen here.
--
-- If a fortification is standing on the tile - a wall, a gate, a tower, any building -
-- the collapse goes ahead exactly as the game runs it, and this is the moment a build
-- denial is recorded, because it is the last moment the target is certainly still there:
-- the collapse's own damage ticks can take a weak wall down before the destroying tick. A
-- second collapse at the same breach does not take a second zone, it adds its time to the
-- one already standing there.
--
-- A stockpile counts as empty ground: its wall bit cannot be damaged.
--
-- If the tile is empty - another tunnel took the target first - the tunnel is sent on
-- (redirect) and the function returns through its own tail without switching state, so
-- the tunneler digs straight on. If there is nowhere to send it, the game collapses it
-- where it stands, as it always would have.
--
-- Only one tunnel is sent on in any one tick. Sending one on runs the game's target search
-- up to three times, and each run is anything from fifty thousand instructions to well
-- over a million when the search has to spread to the edge of its range - so a group of
-- tunnels that arrive on the same breach together, handled in one tick, is a hitch the
-- player sees. The others wait: returning through the tail without switching state leaves
-- a tunneler exactly where it is, in state 3 with nowhere left to go, and the game brings
-- it straight back here on the next tick. Nothing about it changes in the meantime but the
-- digging animation's counter.
local arrival = [[
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
mov ecx, [eax+UNIT_TILE]
mov edx, [CURRENT_UNIT_ADDRESS]
mov [REPORT_ADDRESS], edx
mov [REPORT_ADDRESS+4], ecx
mov edx, [ecx*4+TILE_FLAGS_ADDRESS]
mov [REPORT_ADDRESS+8], edx
test edx, STOCKPILE
jnz arrived_on_nothing
test edx, WALL_FAMILY
jnz arrived_on_something
movzx edx, word [ecx*2+BUILDING_TILE_ADDRESS]
mov [REPORT_ADDRESS+12], edx
test dx, dx
jnz arrived_on_something
arrived_on_nothing:
cmp dword [RETARGET_ENABLED_ADDRESS], 0
je arrive_quiet
cmp ecx, [FAIL_SPOT_ADDRESS]
jne arrive_spot_fine
mov edx, [TICKS_ADDRESS]
cmp edx, [FAIL_UNTIL_ADDRESS]
jb arrive_wait
arrive_spot_fine:
mov ecx, [TICKS_ADDRESS]
cmp ecx, [LAST_REDIRECT_ADDRESS]
je arrive_wait
mov [LAST_REDIRECT_ADDRESS], ecx
call REDIRECT_ADDRESS
cmp dword [REDIRECT_HOW_ADDRESS], 9
je arrive_wait
cmp dword [DIAGNOSTICS_ADDRESS], 0
je arrive_redirect_said
push eax
mov ecx, 43
test eax, eax
je arrive_redirect_code
mov ecx, 42
cmp eax, 1
je arrive_redirect_code
mov ecx, 46
arrive_redirect_code:
mov [REPORT_ADDRESS+28], ecx
mov ecx, [CURRENT_UNIT_ADDRESS]
mov [REPORT_ADDRESS], ecx
mov ecx, [ALG_RESULT_ADDRESS]
mov [REPORT_ADDRESS+4], ecx
mov dword [REPORT_ADDRESS+8], 0
mov ecx, [REDIRECT_HOW_ADDRESS]
mov [REPORT_ADDRESS+12], ecx
mov ecx, [RECORD_ADDRESS]
mov edx, [ecx+4]
mov [REPORT_ADDRESS+20], edx
mov ecx, [ecx+8]
test ecx, ecx
je arrive_no_line
mov ecx, [ecx]
arrive_no_line:
mov [REPORT_ADDRESS+16], ecx
cmp dword [REPORT_ADDRESS+28], 46
jne arrive_redirect_say
mov ecx, [ALG_RESULT_ADDRESS]
mov ecx, [ecx*4+TILE_FLAGS_ADDRESS]
mov [REPORT_ADDRESS+8], ecx
mov ecx, [CURRENT_UNIT_ADDRESS]
imul ecx, ecx, 1168
mov ecx, [ecx+UNIT_TILE]
mov [REPORT_ADDRESS+24], ecx
mov ecx, [ecx*4+TILE_FLAGS_ADDRESS]
mov [REPORT_ADDRESS+32], ecx
mov ecx, [CURRENT_UNIT_ADDRESS]
imul ecx, ecx, 1168
movzx ecx, word [ecx+UNIT_PATH_LENGTH]
mov [REPORT_ADDRESS+36], ecx
arrive_redirect_say:
call REPORT_PAD_ADDRESS
pop eax
arrive_redirect_said:
test eax, eax
je arrive_quiet
arrive_wait:
jmp TAIL_ADDRESS
arrived_on_something:
cmp dword [DENIAL_ENABLED_ADDRESS], 0
je arrive_on_it
cmp dword [DURATION_ADDRESS], 0
jle arrive_on_it
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
jmp arrive_report
arrive_on_it:
mov dword [REPORT_ADDRESS+28], 41
arrive_report:
cmp dword [DIAGNOSTICS_ADDRESS], 0
je arrive_quiet
call REPORT_PAD_ADDRESS
arrive_quiet:
mov eax, [CURRENT_UNIT_ADDRESS]
jmp RETURN_ADDRESS
]]

---------------------------------------------------------------------------------------
-- What a tunnel is allowed to aim at, and what it may pass beneath
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
--
-- One exception: while a line's route is being measured (filter mode 3) the enemy's
-- campfire is let through to the game's own owner test, so that the search can stop the
-- moment it gets there instead of spreading on past it to the edge of its range.
local tunnel_accept = [[
cmp dword [AIM_MODE_ADDRESS], 3
jne accept_not_camp
cmp eax, [CAMP_BUILDING_ADDRESS]
jne accept_not_camp
imul eax, eax, BUILDING_STRIDE
jmp RETURN_ADDRESS
accept_not_camp:
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

---------------------------------------------------------------------------------------
-- The collapse
---------------------------------------------------------------------------------------
-- Stairs and crenellations, damaged the way the game damages a wall.
--
-- The game's own damage routine sorts the tile it is handed before it does anything. A
-- building, or a tile carrying a building id, goes down the building path. A tile with the
-- wall bit (0x100) goes into the wall loop. Everything else is dropped on the floor: the
-- routine returns having done nothing at all. Stairs (0x800) and crenellations (0x200) are
-- in that last group, which is why the only thing a tunnel could ever do with them was
-- take them away outright.
--
-- The wall loop itself is already written for the whole family. It takes a point of height
-- for every point of damage - height above the ground is what a wall has instead of hit
-- points - and raises the tile's own damage figure, which is the thing the game's drawing
-- code reads to decide whether to draw the intact piece or the damaged one. When the
-- height reaches the ground it clears all three flags in one go (0xFFBEF4FF keeps neither
-- the wall bit nor the crenellation bit nor the stairs bit), puts the height back, wipes
-- the damage figure and has the tile redrawn. So there is nothing here to imitate: the
-- damaged look, the stages and the tidying up are the game's own, and the only thing
-- standing in the way was the sorting test.
--
-- It is widened for this module's damage alone. The module sets FAMILY_ACTIVE for the
-- length of its own call and clears it again afterwards, so a catapult stone, a fire arrow
-- or anything else that damages a tile still finds the routine exactly as it was.
--
-- Replaces the five byte test itself. EAX carries the tile's flags and the instructions
-- further along read its low byte, so it is handed on untouched.
local damage_family = [[
test eax, 0x100
jnz family_carry_on
test eax, STAIR_FAMILY
jz family_nothing
cmp dword [FAMILY_ACTIVE_ADDRESS], 0
je family_nothing
family_carry_on:
jmp CARRY_ON_ADDRESS
family_nothing:
jmp NOTHING_ADDRESS
]]

-- What a collapse does to the thing it arrived under. A wall, a gate or a tower takes the
-- damage figure from the settings through the game's own damage, which for a wall means its
-- height comes down by that much and it is gone once that reaches the ground.
--
-- Stairs and crenellations now go the same way, because the sorting test in the damage
-- routine has been widened and it takes them: they lose height, they are drawn damaged
-- while they are still standing, and the game itself clears them away once the height is
-- gone. Where that widening could not be installed - another module in the same place, or
-- code that did not look the way it should - FAMILY_READY stays zero and the older
-- behaviour is kept, which is to take the tile away with the game's own
-- resetTileToDefaultState, so a tunnel arriving under stairs still does something.
--
-- The game demolishes what it arrives under outright, whatever it is; this hands it the
-- module's damage figure through the game's own damage function instead, which is what a
-- catapult stone or a fire arrow goes through. Walls and weak gates still come down in one
-- tunnel, a square tower or a large gatehouse only if the figure is set high enough - and
-- whatever survives keeps the damage, so the next tunnel finishes it.
--
-- Replaces the read of the unit's tile that the demolition branch starts with. EBX must
-- stay zero for the instructions after this, which the game's own functions see to.
local collapse_target = [[
mov eax, [CURRENT_UNIT_ADDRESS]
imul eax, eax, 1168
mov ecx, [eax+UNIT_TILE]
cmp dword [FAMILY_READY_ADDRESS], 0
jne collapse_damage
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
mov dword [FAMILY_ACTIVE_ADDRESS], 1
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
mov dword [FAMILY_ACTIVE_ADDRESS], 0
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

-- The game brings a whole tunnel down in the one frame the tunneler reaches its target:
-- every tile damaged and every tile's ground lowered at once. That is a visible stutter on
-- a long tunnel, and it looks like nothing in particular. These three scripts take the
-- tunnel apart a few tiles at a time instead, starting at the target and running back to
-- the entrance.
--
-- The first walks the native path before its owner releases it. Restore bare ground and
-- its native walk layer immediately: an optional damage queue must never be the only
-- owner of terrain repair when a save is used as a map without this module. Walls and
-- buildings keep their native height/hit points. Expensive damage remains queued.
-- The plan it walks is the whole tunnel from its entrance, however many times the tunnel was
-- sent on along the way - extend_plan keeps it so.
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
mov ecx, [FILL_TILE_ADDRESS]
test dword [ecx*4+TILE_FLAGS_ADDRESS], WALL_FAMILY
jnz fill_ground_done
cmp word [ecx*2+BUILDING_TILE_ADDRESS], 0
jne fill_ground_done
mov al, byte [ecx+BASE_HEIGHT_ADDRESS]
cmp al, byte [ecx+LIVE_HEIGHT_ADDRESS]
jae fill_ground_done
mov byte [ecx+LIVE_HEIGHT_ADDRESS], al
push dword [FILL_Y_ADDRESS]
push dword [FILL_X_ADDRESS]
push 1
mov ecx, PATH_STATE_ADDRESS
call UPDATE_WALK_ADDRESS
fill_ground_done:
mov ecx, [QUEUE_COUNT_ADDRESS]
cmp ecx, QUEUE_MAX
jae fill_advance
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
fill_advance:
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
-- Terrain repair now belongs to queue_fill, before the native path is released. This
-- queue only shakes buildings; it must not lower neighbouring active tunnels whose
-- native path is still responsible for their ground. Quiet fills do no damage.
--
-- One neighbour per call, at STEP_DX / STEP_DY, which it then moves on; when the last one
-- is done STEP_ACTIVE goes to 0. The game's damage is the dear part of a collapse on a real
-- map - a building it brings down sets the game rebuilding its maps - so queue_tick has to
-- be able to stop between any two of them. EAX comes back 1 when the game's damage was
-- called, else 0. EBX is kept.
local queue_step = [[
push ebx
xor ebx, ebx
cmp dword [RADIUS_ADDRESS], 0
jl step_finished
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
test dword [STEP_FLAGS_ADDRESS], 1
jnz step_next
mov eax, [SPREAD_DAMAGE_ADDRESS]
mov [STEP_DAMAGE_ADDRESS], eax
test dword [ecx*4+TILE_FLAGS_ADDRESS], STOCKPILE
jnz step_next
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
mov dword [FAMILY_ACTIVE_ADDRESS], 1
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
mov dword [FAMILY_ACTIVE_ADDRESS], 0
mov ebx, 1
step_next:
add dword [STEP_DX_ADDRESS], 1
mov eax, [STEP_DX_ADDRESS]
cmp eax, [RADIUS_ADDRESS]
jle step_out
mov eax, [RADIUS_ADDRESS]
neg eax
mov [STEP_DX_ADDRESS], eax
add dword [STEP_DY_ADDRESS], 1
mov eax, [STEP_DY_ADDRESS]
cmp eax, [RADIUS_ADDRESS]
jle step_out
step_finished:
mov dword [STEP_ACTIVE_ADDRESS], 0
step_out:
mov eax, ebx
pop ebx
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
-- SPEED bounds both new tunnel tiles and expensive damage calls per tick. Unlike a CPU
-- time budget this produces the same work on every machine, including when replaying.
-- A partial tile stays in STEP_* for the next tick; empty cells retain the tile bound.
local queue_tick = [[
pushad
cmp dword [DIAGNOSTICS_ADDRESS], 0
je tick_unwatched
rdtsc
shrd eax, edx, 10
mov ebx, eax
mov ecx, eax
sub ecx, [SW_LAST_ADDRESS]
cmp dword [SW_LAST_ADDRESS], 0
mov [SW_LAST_ADDRESS], ebx
je tick_watch_reset
mov eax, [SW_AVERAGE_ADDRESS]
shl eax, 2
cmp ecx, eax
jbe tick_watch_average
cmp ecx, SW_FLOOR
jbe tick_watch_average
mov [REPORT_ADDRESS], ecx
mov eax, [SW_TUNNEL_ADDRESS]
mov [REPORT_ADDRESS+4], eax
mov eax, [SW_QUEUE_ADDRESS]
mov [REPORT_ADDRESS+8], eax
mov eax, [SW_MAX_ADDRESS]
mov [REPORT_ADDRESS+12], eax
mov eax, [SW_DAMAGE_MAX_ADDRESS]
mov [REPORT_ADDRESS+16], eax
mov eax, [SW_DAMAGE_CALLS_ADDRESS]
mov [REPORT_ADDRESS+20], eax
mov eax, [SW_DAMAGE_KIND_ADDRESS]
mov [REPORT_ADDRESS+24], eax
mov dword [REPORT_ADDRESS+28], 47
mov eax, [SW_TILES_ADDRESS]
mov [REPORT_ADDRESS+32], eax
mov [REPORT_ADDRESS+36], ebx
push ecx
call REPORT_PAD_ADDRESS
pop ecx
jmp tick_watch_reset
tick_watch_average:
mov eax, ecx
sub eax, [SW_AVERAGE_ADDRESS]
sar eax, 4
add [SW_AVERAGE_ADDRESS], eax
tick_watch_reset:
xor eax, eax
mov [SW_TUNNEL_ADDRESS], eax
mov [SW_QUEUE_ADDRESS], eax
mov [SW_MAX_ADDRESS], eax
mov [SW_COUNT_ADDRESS], eax
mov [SW_DAMAGE_MAX_ADDRESS], eax
mov [SW_DAMAGE_CALLS_ADDRESS], eax
mov [SW_TILES_ADDRESS], eax
tick_unwatched:
mov eax, [SPEED_ADDRESS]
test eax, eax
jle tick_done
mov [TICK_LEFT_ADDRESS], eax
mov [DAMAGE_LEFT_ADDRESS], eax
tick_next:
cmp dword [STEP_ACTIVE_ADDRESS], 0
jne tick_step
cmp dword [TICK_LEFT_ADDRESS], 0
jle tick_done
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
mov eax, [RADIUS_ADDRESS]
neg eax
mov [STEP_DX_ADDRESS], eax
mov [STEP_DY_ADDRESS], eax
mov dword [STEP_ACTIVE_ADDRESS], 1
sub dword [TICK_LEFT_ADDRESS], 1
add dword [SW_TILES_ADDRESS], 1
tick_step:
rdtsc
shrd eax, edx, 10
mov esi, eax
call STEP_ADDRESS
mov edi, eax
test edi, edi
je tick_stepped
add dword [SW_DAMAGE_CALLS_ADDRESS], 1
rdtsc
shrd eax, edx, 10
sub eax, esi
cmp eax, [SW_DAMAGE_MAX_ADDRESS]
jbe tick_stepped
mov [SW_DAMAGE_MAX_ADDRESS], eax
mov ecx, [STEP_THIS_TILE_ADDRESS]
mov eax, -1
test dword [ecx*4+TILE_FLAGS_ADDRESS], WALL_FAMILY
jnz tick_kind
movzx eax, word [ecx*2+BUILDING_TILE_ADDRESS]
imul eax, eax, BUILDING_STRIDE
movsx eax, word [eax+BUILDING_TYPE_ADDRESS]
tick_kind:
mov [SW_DAMAGE_KIND_ADDRESS], eax
tick_stepped:
cmp dword [STEP_ACTIVE_ADDRESS], 0
jne tick_budget
push dword [STEP_Y_ADDRESS]
push dword [STEP_X_ADDRESS]
push 1
mov ecx, PATH_STATE_ADDRESS
call UPDATE_WALK_ADDRESS
tick_budget:
test edi, edi
je tick_next
sub dword [DAMAGE_LEFT_ADDRESS], 1
jnz tick_next
tick_done:
cmp dword [DIAGNOSTICS_ADDRESS], 0
je tick_out
rdtsc
shrd eax, edx, 10
sub eax, [SW_LAST_ADDRESS]
mov [SW_QUEUE_ADDRESS], eax
tick_out:
popad
push ebx
push ebp
movsx ebp, word [RNG_ADDRESS]
jmp RETURN_ADDRESS
]]

---------------------------------------------------------------------------------------
-- The enemy's campfire
---------------------------------------------------------------------------------------
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
mov [ANCHOR_ID_ADDRESS], edx
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
mov ecx, [ANCHOR_ID_ADDRESS]
mov [CAMP_BUILDING_ADDRESS], ecx
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

---------------------------------------------------------------------------------------
-- A tunneler at work
---------------------------------------------------------------------------------------
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
  aim_filter = aim_filter,
  line_search = line_search,
  stands = stands,
  record_of = record_of,
  aim_at_line = aim_at_line,
  follow_route = follow_route,
  line_front = line_front,
  route_build = route_build,
  route_walk = route_walk,
  new_line = new_line,
  place_aim = place_aim,
  place_net = place_net,
  redirect = redirect,
  quiet_trace = quiet_trace,
  aim_cone = aim_cone,
  crossing = crossing,
  raid_tribe = raid_tribe,
  raid_no_guild = raid_no_guild,
  tunneler_timed = tunneler_timed,
  tunneler_entry = tunneler_entry,
  extend_plan = extend_plan,
  arrival = arrival,
  tunnel_targets = tunnel_targets,
  tunnel_accept = tunnel_accept,
  damage_family = damage_family,
  collapse_target = collapse_target,
  queue_fill = queue_fill,
  queue_step = queue_step,
  queue_tick = queue_tick,
  find_anchor = find_anchor,
  no_anchor = no_anchor,
  not_a_target = not_a_target,
  stance = stance,
  render_tunnel_button = render_tunnel_button,
  tunnel_button_click = tunnel_button_click,
}
