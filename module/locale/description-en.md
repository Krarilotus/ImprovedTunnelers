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
