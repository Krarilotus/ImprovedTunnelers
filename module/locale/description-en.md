# Improved Tunnelers

Five changes to the tunneler, each switchable on its own.

**A breach stays open for a while.** When a tunnel brings a wall, a tower or a gate down,
the ground around the hole is denied to builders for 30 seconds (adjustable), exactly as if
an enemy soldier were standing in it - the same circle the game already uses for enemy
units, taken from the game's own values. Neither the player nor the AI can seal the gap
immediately, and the AI's tile-by-tile wall repair is held off in the same way. Two tunnels
through the same breach stack: the second adds its time to the first, so thirty seconds
becomes sixty. A player who tries anyway is told **"The ground is too unstable to build here
right now"** instead of the game's "enemy units are too close" - that one line needs the
Text Resource Modifier module to be on, and without it the game's own message is used.

**Tunnels no longer waste themselves.** A tunnel is aimed once, when the tunneler digs
itself in, and in the unmodified game it keeps digging at that spot whatever happens to it.
Here a tunnel bends towards another target instead, with the game's own search and path
finder, from wherever the tunneler is at that moment - nothing is sent back to the entrance
and no second tunnel is started. The moment one of your tunnels brings a wall down, every
other tunnel of yours that was digging at that same spot turns aside there and then; and a
tunnel that arrives to find its target gone anyway looks for another one before it
collapses. Only when there is nothing in range does it collapse where it stands, the way
the unmodified game does.

**A collapse damages, it does not demolish.** The unmodified game simply removes whatever
the tunnel arrived under. Here the collapse hands it a damage figure you set instead, through
the game's own damage - so at 2500 (the default) anything comes down in one tunnel as before,
and at 1200 a square tower or a large gatehouse survives the first one, keeps the damage, and
falls to the second. The tunnel also shakes the ground beside every tile it ran under, as far
as you set the reach, so a tunnel passing under a workshop yard is felt there too - but that
tremor is for the town only. Walls, stairs, gates, gatehouses, towers, keeps and keep doors
stand through it, and one the tunnel ran directly underneath takes the same five points the
unmodified game took off it and not a point more. What a tunnel brings down is what it was
aimed at, not whatever happened to be nearby.

**A tunnel falls in from the far end.** The unmodified game brings a whole tunnel down in the
single frame the tunneler arrives: every tile of it damaged and lowered at once, which on a
long tunnel is a visible stutter and looks like nothing in particular. Here the tunnel comes
apart a few tiles at a tick - you set how many - starting under the target and running back
towards the entrance, with the damage done tile by tile as the ground drops. The work is
spread over the seconds after the breach instead of landing in one frame.

**A digging tunneler is left to its work.** While it digs its entrance or its tunnel it
cannot be picked by the mouse or a drag box, the orders you give a group pass it over, and
enemy archers and soldiers do not aim at it - the same answer the game already gives for a
man working inside a building. It is back to normal the moment it is above ground.

**A player's tunnels open one breach, not six.** The game's search stops at the first wall it
reaches, which on a long wall is whichever piece happens to lie nearest each tunneler - six
tunnels, six holes, none of them leading anywhere. Here the first tunnel to be aimed asks the
search again, several times over, each round refusing anything not closer to the enemy's
campground than the last answer, and the piece it settles on is written down as *the* breach
that player is working at. Every other tunnel of theirs **that is digging within about twenty
tiles of it** then searches for that one tile and nothing else, so they all arrive at the same
piece of wall and the hole they leave is a road in rather than a scatter. That distance is
deliberately much shorter than the range a tunnel may search: tunnels that start together
should arrive together, but one starting across the map has its own wall in front of it and
digs at that instead of being dragged sideways to somebody else's breach. A tunnel that cannot reach it - too far off, or no way through -
quietly digs at its own best target instead and leaves the breach to the others. Once nothing
stands there any more the breach is given up, the next tunnel to look picks the next piece
closer to the camp, and the rest follow it in turn.

**And the breaches work inwards, not sideways.** Every time a tunnel brings something down,
the player remembers how close to the enemy's camp they have got, and every aim after that has
to beat it. Without that, the nearest target to a fresh tunnel is simply more of the same outer
wall a few tiles along, and the tunnels widen one hole instead of driving a road inwards. With
it, the first breach opens the outer wall, the next has to find something past it, and the
line advances - around the keep rather than under it - until it reaches the camp. The mark only
ever moves inwards, it is set when a tunnel actually collapses on something rather than when
one is merely aimed, and it is forgotten if a player goes a minute and a half without breaching
anything, so a stalled assault starts afresh instead of asking for the impossible. When nothing
can beat the mark, the tunnel falls back to the nearest target as before and still does its
work.

The narrowing is also kept shallow on purpose. Left to itself, "closer to the camp each round"
walks the target straight through the wall and ends at the keep, which is where the tunnels
used to converge. So the first answer fixes a depth - the digging distance the search itself
measured to it, plus about a dozen tiles of room to look along the wall face - and later rounds
may move the target sideways along the wall but never deeper into the castle.

A tunnel you dig by hand is sent against nobody in particular - the game reads that as "any
enemy will do" - and it works towards the nearest camp that is neither ours nor an ally's.

**A tunnel never costs you the entrance.** When a tunnel is aimed, the game immediately
lays the tunneler's path to that target, and if the path will not lay it does not look for
anything else - it destroys the tunnel entrance where it stands. The search and the path
finder do not always agree, so a target this module picked could lose you a tunnel the game's
own choice would have kept. Now, when that happens, the tick is simply abandoned through the
game's own "nothing to do" exit, which leaves the tunneler and its entrance exactly as they
were, and the next time the game aims that tunneler this module stands aside and lets the
game's own choice through. The tunnel loses a moment instead of the entrance, nothing is
redirected under the player's feet, and a path the game itself cannot lay is still the game's
own business, ending the way it always did.

**Tunnels go round a keep, never under it.** With digging under the town switched on, a
tunnel may pass beneath workshops, houses and yards to reach the walls behind them - but a
keep is treated as solid rock and worked around. This keeps tunnels out of the one place the
game's path finder is least willing to follow them, and stops a breach being aimed at the
lord's own doorstep instead of at the wall.

**Tunnels work inwards.** A tunnel being turned aside takes a target that is closer to the
enemy's campground - where their peasants gather - than the tunneler is now, instead of the
nearest piece of wall in any direction, so a second tunnel does not just wander along the
same wall. Tunnels may also pass beneath the town and beneath the keep itself, which the
game's own search refuses to do, so they can reach the walls and towers on the far side
instead of stopping at the first workshop. If nothing closer is in range a tunnel takes the
nearest target after all.

**The ground is left where the tunnel found it.** The game keeps two height maps: the one the
map was drawn with, and the one being played on. As a tunnel falls in, every tile it ran under
and the ground around it is set back to the height the map itself gives that tile - never to
flat, and never lower than it was found. Raised ground and cliffs a tunnel crossed come back
exactly as they were, a tunnel dug across a hill leaves no ditch in it, and however many
tunnels cross the same ground it can only ever go back to where it started. The stretch a
tunnel dug before it turned towards a new target is put back the same way, quietly, so nothing
is left raised behind it either.

**Stairs and crenellations count as wall.** The game's own search only ever looks for plain
wall on the tile it reaches, so a stairway or a crenellated section was invisible to a tunnel
even though it is part of the same castle. All three live in the same layer - wall, crenellation
and stairs - and a tunnel is now aimed at any of them. Taking one away is a different matter
from a wall: the game's damage only understands the wall bit and silently does nothing for the
other two, so a tile that is stairs or crenellation and nothing else is removed with the game's
own tile reset, exactly as the unmodified game does when a tunnel surfaces under something that
is not a building. A stair against a wall is damaged as the wall it belongs to.

**Towers and gates can be tunnelled, and nothing else.** The unmodified game will only aim a
tunnel at a wall or at one of the three small towers; a gatehouse, a square tower or a round
tower is never picked. This lets the search treat every gate and tower the game itself counts
as one, and they collapse the same way a wall does. Walls, gates and towers are also the only
things a tunnel is ever aimed at: workshops, houses, farms and the rest are never targets,
and a tunnel turned aside while it is under the enemy's town digs on past them to the next
piece of wall.

**Tunnelers get the attack-here button.** The dig tunnel button moves one slot to the
right, into the empty slot next to it, and the ordinary attack-here button takes its place,
so a tunneler can be sent at a particular building like any other soldier.

**Tunnelers obey stances.** Defensive and aggressive stance work for tunnelers now, at the
same ranges as for every other unit. A stance only takes over once the tunneler is standing
about: an order to walk somewhere is never thrown away halfway for an enemy near the route,
and a tunneler on its way to dig, or already underground, is never interrupted at all.

Everything is found by pattern scan and works on both Stronghold Crusader and Stronghold
Crusader Extreme. Denial times are counted in game ticks, so they are identical on every
machine in a multiplayer game.
