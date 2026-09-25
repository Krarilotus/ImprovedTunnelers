# Map portability and tunnel terrain ? 1.7.2

**1.7.1 has a reported terrain regression and is superseded by 1.7.2.**
Its center-only assignment did not clear the full native digging footprint. The
old synthetic terrain test was insufficient and has been replaced by execution of
the actual native brush and coordinate helper. See [the terrain review](UCP-TERRAIN-RESET.md).

Completed tunnels now use the game's nine-tile brush before the native path is
released. With the terrain fix enabled (the default), its cleanup restores original
terrain height instead of subtracting two and forcing the center to zero. Existing
native exclusions/path updates remain, with stairs and crenellations protected too.
Positive digging is unchanged. The extra damage queue does not write terrain.

The native path remains available for cleanup even when the damage queue is full.
Queue saturation can still drop extra building damage; it cannot stop this ground
cleanup. Overlapping active tunnels share native terrain data: this is not a new
per-tunnel terrain ownership system. No additional saved field or map section was added.

Exact saved-battle/replay continuation still requires matching packages/settings.
Map Extensions 1.1.5 initializes fresh module state for renamed `.map` scenarios,
including when this provider is absent. Other providers retain their own contracts.
The native packed tunnel path remains game-owned, including in-progress tunnels.

## Reader compatibility evidence

The stock `FilePackager::readMapOrSavFile` matches file section IDs against its
native descriptor table, stopping at the zero descriptor. Unknown IDs are skipped,
not decompressed into native data. The stock table has 122 entries and no ID 1337.
Map Extensions uses that extra section; native entries and directory layout are
unchanged. The original writer enumerates its own descriptors, so it cannot carry
that module section into a stock re-save.

`bench/test_map_portability.py` executes the actual stock dispatch and native copy
routines on all six available fixture files: local SHC/Extreme 1.41 plus official
EFIGS/PL copies (two distinct code layouts). An invalid compressed unknown section
is inserted before/between/after two ordinary sections. In all 18 cases it is
ignored and both ordinary payloads load without overrunning their destination.
This does not run file IO, compression, the editor or a whole game.

Released Map Extensions 1.0.0 (`d939912`) dispatches only registered consumers and
ignores the new required-state manifest. With Improved Tunnelers absent, it does
not require that consumer. Development versions 1.1.0–1.1.4 predate the map policy
and can reject renamed required-state saves; use released 1.0.0, the new 1.1.5
owner, or no owner for this comparison. They are not compatibility prerequisites
silently added to the current store release.

The unmodified reader allocates 6,000,000 bytes for the entire compressed payload;
Map Extensions enlarges that buffer. Unknown-section skipping does **not** remove
this stock size limit. This module's snapshot is bounded to about 53 KB, but this
audit does not promise stock loading for oversized files or other mods' formats.
Do not turn the section-dispatch result into an unlimited-format claim.

## Verification and remaining acceptance

Sixteen focused module tests pass: five Lua/default/localization tests, four saved
state tests, two deterministic damage-queue tests, four native terrain tests and
one stock section-dispatch test. The native terrain and stock-dispatch tests cover
six fixture files (two distinct SHC/Extreme code layouts). The terrain tests execute
the game's brush and coordinate helper; downstream path calls are recorded stubs,
not a full pathfinding or rendering simulation. Python remains outside the package.

Still check a new single-player match in normal Crusader and Extreme: completed,
overlapping and active tunnels; raised ground; walls and buildings; save/reload;
matching-setup replay; and a copied save renamed to `.map`, edited and played both
with and without the modules. Check walking/building and pauses at completion.
Actual game/editor/replay, installed GUI and measured performance acceptance have
not been performed for 1.7.2. No old-save migration is promised. Multiplayer testing
remains player-owned. Stock size limits and other modules' requirements still apply.
