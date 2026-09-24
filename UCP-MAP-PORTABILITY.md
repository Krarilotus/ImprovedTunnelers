# Map portability audit and correction — 1.7.1

A converted scenario must not need Improved Tunnelers merely to keep its terrain
usable. A matching module/configuration remains necessary to resume its exact
saved battle or replay, including pending damage, claims and denial timers.

## Defect and focused correction

Previously `collapse_target` queued a tunnel and cleared its native path length.
`queue_step` later lowered the raised ground. Discarding private state for a `.map`,
or opening without the module, could therefore abandon terrain repair. A full
512-entry queue also stopped walking the remaining native path, leaving its ground
behind. The unknown file section itself was not the problem.

`queue_fill` now restores **bare tunnel tiles** to their native base height and
calls the already resolved native `updateWalkAndPathLayer` before the path is
released. It visits the remaining path even when no more damage entries fit.
Walls/buildings retain their native height/hit points; ground is never raised.
`queue_step` handles delayed damage and no longer lowers neighbouring active
tunnels. Damage allowance/order and ordinary save/replay restoration are unchanged.

Visible difference: empty tunnel ground returns immediately, while building damage
still progresses over ticks. Terrain/path work moves to completion; expensive
building damage stays bounded per tick. No claim of zero performance impact is
made without a game measurement. The pre-existing damage queue capacity is not
expanded; saturation can still omit excess damage, but can no longer omit terrain
repair. This is not a redesign of collapse scheduling or siege tactics.

## Framework reuse and native world data

- Reuse the existing `applyTunnelDamageAlongPathPlan` instruction-derived height
  arrays, path owner and relative call target already validated in `init.lua`.
  No additional AoB, hook, fixed runtime address, save projection or file converter.
- The original game owns in-progress tunnel paths. Extended plans retain the
  original packed nibble format and 800-step capacity; no new unit type/state or
  module pointer is written into native unit records.
- The selection field is native data too: original `UpdateTunneler` repairs a zero
  value on its next update. Removing this module does not require its stance hook
  to keep units permanently selectable. This is assembly inspection, not UI testing.
- Map Extensions 1.1.5 `initializeOnMap` discards this provider's old battle state
  and removes its identity requirement for `.map`, including if it is absent.
  `.sav` and Recorder snapshot restoration stay strict. Other providers retain
  their contracts. The owner branch and AIC/Recorder code are unchanged here.

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

## Checks and remaining acceptance

- Existing four integration and four state tests pass.
- Three FASM/Unicorn queue tests pass: deterministic damage, no deferred terrain
  writes, and immediate repair with full/non-full queues and normal/quiet fills.
  The 800-step bound, base-height preservation, wall/building protection and
  volatile-register clobbering are exercised; native path/damage callees are stubs.
- The six-fixture stock dispatch test above passes. Python stays in `bench/`,
  outside the module allowlist; all nine shipped descriptions explain the change.

Still perform a short **single-player** acceptance check with a newly created
1.7.1 save during delayed damage: copy/rename to `.map`; open, edit, save and start
it with (a) module enabled, (b) Improved Tunnelers absent but Map Extensions 1.1.5
present, and (c) both absent. Test completed bare tunnels and still-active tunnels;
compare ordinary save/replay continuation separately with matching packages.
Check walking/building on the completed tunnel footprint. No native editor,
whole-game replay, new variant or frame-time acceptance is claimed here.
Old-save migration remains out of scope; this does not repair ground abandoned
in an already exported 1.7.0 scenario. Multiplayer testing remains player-owned.
