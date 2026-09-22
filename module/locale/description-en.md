# Improved Tunnelers

Tunnels in the unmodified game are a lottery: one tunneller, one hole, somewhere along the
nearest wall, and whatever it comes up under simply vanishes. This module turns them into a
siege tool. Tunnels dug at the same castle meet at **one** piece of wall, open it, and then
work their way inwards towards the enemy's camp - while the ground and the rubble behave
themselves afterwards.

Everything below can be switched on or off on its own.

## What it does

**They all dig at the same spot.** When one of your tunnels picks a piece of wall, that becomes
*the* breach your tunnels are working at, and every other tunnel of yours digging nearby goes
for that same piece. Instead of six holes in six places you get one road in. A tunnel too far
off to join sensibly digs at whatever is in front of it rather than being dragged across the
map.

**And then they work inwards.** Every time a tunnel brings something down, the game remembers
how close to the enemy's camp you have got, and the next tunnel has to beat it. The first
breach opens the outer wall, the next has to find something past it, and the line advances -
around the keep, never under it - towards the campfire.

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

**Tunnels no longer waste themselves.** A tunnel whose target is destroyed before it arrives
bends towards a new one from where it stands, instead of digging on to nothing. And if a target
turns out to be unreachable, the tunnel loses a moment rather than the entrance.

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
| **Digging on** | A tunnel whose target is gone looks for another | on |
| Search range | How far a tunnel looks for a target | 80 tiles |
| **Breach reach** | How near a tunnel must be to join the breach the others are at. Higher: they converge from further apart. Lower: each digs at what is in front of it | 40 tiles |
| Times per tunnel | How often one tunnel may be turned aside | 10 |
| Fill in behind | Collapse the stretch already dug when a tunnel turns aside | on |
| Aim towards the camp | Drive the breaches inwards towards the enemy's campfire | on |
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
| Diagnostics | Write a line to `ucp3.log` for every tunnel arrival, collapse and refused building | off |

Everything is found by pattern scan and works on both Stronghold Crusader and Stronghold
Crusader Extreme. Times are counted in game ticks, so they are identical on every machine in a
multiplayer game.
