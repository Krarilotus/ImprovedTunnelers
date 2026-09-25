# Terrain restoration review for 1.7.2

Version 1.7.1 has a reported terrain regression. Its center-only height assignment
omitted the surrounding tiles changed by vanilla digging. The earlier synthetic
test did not execute the native brush and was insufficient evidence.

## Native responsibility and reuse decision

Inspected OpenSHC revision `126f25c9`: `TileMapState::HeightLayer` and
`DefaultHeightLayer`, `increaseHeightForTunnelWithBrush`, `getTileForBrush`, and
`UnitsState::applyTunnelDamageAlongPathPlan` already name the relevant data and
functions. These declarations are reconstruction evidence, not shipped UCP APIs.

The original brush visits nine tiles through `getTileForBrush`, applies native
terrain/building exclusions, updates path linkages for eligible tiles, then calls
`updateWalkAndPathLayer`. Its two direct callers are digging (+1) and cleanup (-2).
Cleanup subsequently forces its center tile to zero. Neither subtracting two nor
forcing zero restores arbitrary original terrain height.

| Capability | Existing implementation inspected | Decision |
| --- | --- | --- |
| Discovery and assembly | UCP 3.0.7 `content/ucp/code/core.lua`: `AOBScan`, `allocateAssembly`, `writeCodeBytes`; Legacy `port/o_healer.lua` reads operands and relative calls | Reuse the module's existing framework-resolved tunneler/collapse owner and derive its brush call. No independent scanner, address table or private patch framework. |
| Native terrain brush | Existing named OpenSHC declarations and original SHC/Extreme callers; no exported brush API in the framework or Legacy | Correct the negative cleanup branch in the native brush; keep its existing footprint, exclusions and path updates. Positive digging remains unchanged. |
| Delayed damage | Existing `queue_fill` / `queue_step` | Call the native brush before releasing the path. Remove the center-only replacement. Deferred extra building damage does not own terrain restoration. |
| Controls | Legacy `options.yml`, locale catalogs and UCP2Slider | Use established categories, the existing slider/switch schema and all nine maintained UI locales. |

The brush hook must verify its instruction context, member offsets, return ABI,
native singleton and path-update consumer before any write. The normal collapse
walk's forced-zero assignment must not overwrite the corrected height. All binding
addresses come from the existing resolved caller, never from the research VAs.

This correction needs no additional saved field or map section. Overlapping active
tunnels share vanilla height data; this is not a per-tunnel ownership system.
In-game appearance, save/editor/replay and performance checks remain distinct from
native instruction tests and must be reported separately.

## Implemented and verified

The seven-byte brush load at `+0x51` now branches only for the native -2 cleanup
argument; other increments execute the displaced load and continue unchanged.
Cleanup restores `DefaultHeightLayer` for eligible tiles and resumes the native
path update. The additional `0xB00` exclusion protects wall/stair/crenellation HP.
The native collapse walk also has two destruction callers besides UpdateTunneler.
It now invokes that brush at the start of each path position, preserving ECX for
its native path advance. This matters under buildings: digging can raise the
neighbours of an occupied center. The 11-byte native logic test is replayed after
the brush call. The old 22-byte cleanup branch (brush call and forced center zero)
then jumps to its existing path update instead of performing cleanup twice.
All three writes use the existing module patch lifecycle and UCP code writers.
Disabling the setting retains original cleanup.

`queue_fill` calls that brush through the already resolved collapse owner rather
than writing heights itself. The brush owns per-tile admission; the old center
conditions are used only when the terrain fix is disabled.
The settings identity includes the terrain toggle so saved-state validation can
reject a mismatched setup. No per-frame discovery or new persistent state is added.

`bench/test_native_terrain.py` executes the actual brush and coordinate helper on
six SHC/Extreme fixtures (two code layouts), with downstream path functions recorded
as stubs. It demonstrates the old center-only failure, full-footprint restoration,
unchanged positive digging, native exclusions, wall/building protection, overlapping
completed footprints, full-queue cleanup and rejection of modified/occupied bindings.
It also executes the native path walker used by destruction callers and verifies
that raised neighbours of a building center are restored without changing the building.
Actual game/editor/replay, installed GUI and frame-time checks remain pending.

The existing building-denial controls are now one UCP2Slider at
`improved-tunnelers.denial`: enabled by default, `sliderValue: 100`, range 1–2400
ticks. Its sibling `message` setting remains independent. GUI code
`CreateUCP2Slider.tsx` preserves sibling fields through its object spread; runtime
and option defaults agree. Explicit disabled profiles remain disabled; old seconds
are converted at 40 ticks/second and bounded to the new range. New profiles use ticks.

All nine catalogs follow `UCP3-GUI/resources/lang/languages.yaml`. Option text is
shortened throughout. Categories match Legacy's *resolved* names: Balance Changes,
Bugfixes, AI / Improvements and Miscellaneous. Legacy currently falls back to English
for these category names; the GUI uses the resolved strings as grouping keys in
`extension-util.ts`. Independently translating them here would create duplicate
categories. This owner limitation is preserved; option labels/help are translated.
Terrain and stance fixes are in Bugfixes; raid participation in AI / Improvements;
optional targeting, collapse and denial choices in Balance Changes; logging in
Miscellaneous. The generic building-delay switch/number pair is removed.

Final production review: no Python, additional runtime Lua file, custom save format,
independent resolver, private brush loop or redundant delay control was introduced.
Known existing damage-queue saturation and non-composable live patch unload remain
release limitations; this focused terrain correction does not claim to solve them.
