# Improved Tunnelers

Tunnels in the unmodified game are a lottery: one tunneller, one hole, somewhere along the
nearest wall, and whatever it comes up under simply vanishes. This module turns them into a
siege tool. Tunnels dug at the same castle meet at **one** piece of wall, open it, and then
work their way inwards towards the enemy's camp - while the ground and the rubble behave
themselves afterwards.

Everything below can be switched on or off on its own.

## What it does

**They all dig at the same spot.** The first tunnel you dig in at a castle aims where the game
would have aimed it, and that piece of fortification becomes the meeting point. Every tunnel you
dig in after it goes for that same spot if it can reach it - instead of six holes in six places,
one road in. A tunnel too far off to reach it starts a meeting point of its own, so a second
siege somewhere else gets one too.

**Then they go on through the hole, one after another.** The first tunnel to get there brings the
spot down. The first one to arrive on the rubble after it lays out the route from the hole to the
enemy's campfire - once - round the keep, which no tunnel can pass under. From then on the
meeting point is simply the first fortification on that route still standing: every tunnel that
arrives on the rubble is sent along the route to it, the one that gets there brings it down, and
the next goes one further. Only when the whole route to the campfire is open do tunnels turn to
the nearest fortification instead, to widen the way in. Tunnels dug in later join the line where
its front is now.

**Tunnels arriving together are spread out.** Where the next wall on the route is several tiles
thick, the first tunnel is sent at its first tile, the next at the one behind it, and so on -
each spot is held for the tunnel sent at it, so they don't all come up under the same tile and
spend themselves on rubble. If the game refuses to lay a tunnel's way to its new target, the
tunnel waits a moment where it is and is then sent somewhere else; that spot is left alone for
a minute. It is no longer lost.

**No tunnel passes under a standing fortification.** Whatever the route says - a way that
looked open through a gate, past ladders or a siege tower - a tunnel that comes under an enemy
wall, gate or tower on its way collapses right there, on that piece. The one exception is a
thick wall being taken a tile per tunnel: passing under the tiles the others are bringing
down is the point.

**A tunnel that is sent on is still one tunnel.** It carries on from where it stands, and when
it comes up under its new target it collapses exactly the way it would have at the first one -
the same damage, and the whole tunnel behind it, back to its entrance, comes down with it.
Laying out the route costs one search, once per siege. Following it costs no search at all:
the stretch of route ahead is handed straight to the game's own path tracer. Tunnels arriving
together are still sent on one a tick, and a tunnel that needs more than one search to find
its next target waits where it stands and runs them on successive ticks - never two in one.
A path the game refuses to lay for a tunnel sent on no longer makes the game rebuild its path
maps for the whole map, which was the worst of the lag.

**A collapse damages, it does not delete.** What the tunnel comes up under takes a damage
figure you set, through the game's own damage. At the default nothing survives, as before; turn
it down and a large gatehouse shrugs off the first tunnel, keeps the damage, and falls to the
second. Stairs and crenellations are damaged the same way: they lose height, they are drawn in
the game's own damaged state while they are still standing, and the game clears them away
itself once there is nothing left of them. Only tunnels do this - a catapult or a fire arrow
treats them exactly as it always did.

**The tunnel falls in from the far end.** Rather than the whole tunnel vanishing in one frame,
it comes apart a few tiles at a time, starting under the target and running back to the
entrance, damaging as it goes. That tremor is for the town only: workshops and houses beside
the tunnel feel it, while walls, gates, towers, keeps and stairs are left to the tunnel's
actual target.

**The ground is put back properly.** Everything the digging raised is returned to the height
the map gives it - never flattened, never left lower than it started - so hills and cliffs
survive a tunnel crossing them and nothing is left raised to block building later.

**A breach stays open for a while.** Nobody may build on the rubble for a couple of minutes,
player and AI alike, and a second tunnel through the same hole adds its time on top. Anyone who
tries is told the ground is too unstable.

**Better targets.** Gatehouses, towers, gates, stairs and crenellations can all be tunnelled,
not only plain wall - and workshops, houses and farms never can. Tunnels may pass beneath the
town to reach what lies behind it, but never beneath a keep.

**Diggers are left alone.** A tunneller digging its entrance or its tunnel cannot be picked by
the mouse or a drag box, is passed over by the orders you give a group, and enemy archers do
not shoot at it. It is back to normal the moment it is above ground.

**Tunnellers behave like soldiers.** They obey stances, and they get the ordinary attack-here
button; the dig button moves one slot along to make room for it.

## Settings

| Setting | What it means | Default |
|---|---|---|
| **Build denial** | Nobody may build on a fresh breach | on |
| Denial time | How long the rubble stays unbuildable | 120 s |
| Own refusal message | Say "the ground is too unstable" rather than the game's message | on |
| **Tunnels meet** | Tunnels share a meeting point and go on through the hole towards the enemy's campfire | on |
| How far a tunnel reaches | How far a tunnel looks for the meeting point, or for its next target | 80 tiles |
| Times one tunnel is sent on | How often one tunnel may arrive at an empty spot and be sent further in | 10 |
| **Towers and gates** | Gatehouses and towers count as targets, not only wall | on |
| Dig under the town | Tunnels may pass beneath buildings to reach what is behind them | on |
| **Collapse damage** | What the tunnel does to what it arrives under. For scale: wooden gate 200, lookout tower 250, small gatehouse 1000, square tower 1600, large gatehouse 2000 | 2500 |
| Shake the surroundings | Damage the town beside the tunnel as it falls in | on |
| Reach of the shaking | How far either side of the tunnel that reaches | 2 tiles |
| Damage beside the tunnel | What each ordinary building within reach takes | 60 |
| Falling-in speed | Tiles a tick. Lower is slower and prettier | 2 |
| **Diggers unpickable** | Mouse, drag box and group orders pass a digging tunneller by | on |
| Nothing shoots diggers | Archers ignore a tunneller while it is digging | on |
| **Attack-here button** | Tunnellers get the ordinary attack-here button | on |
| **Stances** | Tunnellers obey defensive and aggressive stance | on |
| Diagnostics | Write a line to `ucp3.log` for every tunnel dug in, every arrival and every refused building | off |

Everything is found by pattern scan and works on both Stronghold Crusader and Stronghold
Crusader Extreme. Times are counted in game ticks, so they are identical on every machine in a
multiplayer game.
