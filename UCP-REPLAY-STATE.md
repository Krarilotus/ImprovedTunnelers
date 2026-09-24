# Replay and save-state correction (1.7.0; terrain follow-up 1.7.1)

Requires UCP 3.0.7 and Map Extensions 1.1.5 to run this module. Saved matches need
matching module content/settings. A scenario must remain usable without it:
[the 1.7.1 portability audit](UCP-MAP-PORTABILITY.md) verifies stock unknown-section
dispatch and moves terrain repair out of private queued state. Native editor
acceptance remains pending; stock file-size limits and other providers still apply.

TL;DR: collapse work uses a deterministic allowance instead of CPU time. Map
Extensions saves pending collapses, partial tiles, denied ground, tunnel records,
lines, routes, claims and cursors. Existing tunneler mechanics and native damage/
path calls remain in their original owners. No additional native hook is added.

## Ownership and dependency

| Responsibility | Existing implementation inspected and reused |
|---|---|
| Save/load, new map detection, required-provider preflight and fatal load failure | Map Extensions 1.1.4, `795d32b4ab60ff43dd9bd2f23d821d7ce7cfa5db`: `init.lua:registerSection/getNativeSaveInterface`, `mapextensions/required.lua`, `callbacks.lua`, their tests and AIC Tactics' state caller. The focused 1.1.5 prerequisite adds opt-in fresh state for converted `.map` scenarios; see below. |
| Recorder snapshots and state verification | The same owner's `captureRequiredSections`, `observeRequiredStateBoundary` and integrity methods. Recorder's existing session boundary caller consumes these; no Recorder hook or private state registry. |
| Binary memory IO, source fingerprint, selected package path | UCP 3.0.7 `77c6acc`: `core.readString/writeBytes`, `sha.sha256`, `allActiveExtensions` and loader ZIP-backed `io.open`. No alternate hashing or package resolver. |
| Module-specific layout and reference relocation | New `state.lua` encodes this module's private data. Neither Map Extensions nor ucp2-legacy exports knowledge of these tunneler fields; the legacy module's private allocator is not copied. |
| Native binding/jump installation | The existing verified AoBs and `core.allocateAssembly`/`core.getRelativeAddress` remain unchanged. No fixed-address bindings. |

Map Extensions' required-state/failure-handling changes are still under review:
[upstream PR3](https://github.com/gynt/ucp-extension-map-extensions/pull/3) and
[failure-handling PR2](https://github.com/Krarilotus/ucp-extension-map-extensions/pull/2).
[Editable-map PR3](https://github.com/Krarilotus/ucp-extension-map-extensions/pull/3)
pins 1.1.5 at `683765703c5d79776b8154813e86912627f5bbf6` without changing the active
AIC/Recorder branches. Its full owner suite passes 32 tests on Lua 5.4/LuaJIT.
Released 1.0.0 cannot provide required-state rejection. Version 1.7.0 declares
`map-extensions: ^1.1.5` and checks the actual owner API before patching. The dependency
must accompany testing; release readiness depends on its review as well.

## Behavior and compatibility

The existing collapse speed is now both the maximum new tunnel tiles and maximum
damage calls per simulation tick (default 2). The previous CPU-clock budget made
the same game execute different damage on different machines. Dense collapses
can therefore take longer now. Queue order, radius, damage values, partial-tile
resumption and the native path update on tile completion are preserved. Diagnostic
clocks are only observations; they are neither saved nor used to schedule work.

Only simulation state is serialized. Record/line pointers become checked indices
and are relocated on restore. All identities, sizes, counts, coordinates and
dereferenced indices are checked before any state is written. Loading a new map
clears previous-world data; loading a save restores it even if the tick moves
forward. Recorder boundary capture copies at most about 53 KB; hashing is deferred
until verification requests it, not performed each simulation tick.

**Older-save migration is out of scope.** Keep exactly the same module packages/settings for a saved match
or recording; this version does not promise playback of recordings made with
the former CPU-timed scheduler. Default-on settings and existing categories stay
the same. All nine locales are retained; module descriptions are brief player
overviews, with technical details kept in the review and test instructions.

Renaming a save to `.map` remains supported as an editable scenario. Map Extensions
1.1.5 adds `initializeOnMap=true` to its existing required-state registration:
this module's saved battle data no longer imposes module identity requirements on
map loads, and the owner calls initialization rather than restoration. Native map
content is not rewritten or converted by this module. Loading/editing/re-saving
maps and then starting a match begins fresh tunneler state. Ordinary `.sav` loads
and Recorder's `.sav` snapshots still restore pending work exactly. Other providers
keep their existing contracts. No extra editor or file-load hook is introduced.

## Focused checks performed

- Four existing packaging/lifecycle tests pass, including SHC/Extreme real-image
  Lua admission, OFF paths and failed bindings. Assembly is stubbed in those cases.
- Two Unicorn tests assemble the actual `queue_tick` and `queue_step` with FASM:
  50 damage calls across partial tiles, queue order, completed-tile path updates,
  empty tiles, caller ECX preservation, varying CPU clocks and diagnostics ON/OFF.
  Native damage/path callees are recorded stubs, not gameplay validation.
- Four state tests cover relocation, earlier/later loads, new-world reset,
  pending work/routes/claims, no writes on malformed/missing/incompatible state,
  scratch/diagnostic exclusion and immutable observed boundaries. The owner case
  executes the real Map Extensions registration/capture/preflight and stock UCP proxy.
- Bounded capture measured about 0.09 ms per callback in the local mocked host
  over 1,000 calls. This is a codec check, not in-game performance acceptance.

Run `test_integration.py`, `test_replay_state.py` and `test_queue_determinism.py`
with unittest from `bench/`. Supply `SHC_GAME_DIR`, `FASM_EXE`, `UCP_MAP_EXTENSIONS`
and `UCP_FRAMEWORK_PROXIES` as described in those files. Tests stay outside `module/`.

## Short single-player check still required

1. Install the signed packages including Map Extensions 1.1.5, select Improved
   Tunnelers, keep defaults, and start a new single-player match.
2. Dig through several buildings, save during the collapse, continue briefly,
   then reload. Compare the remaining collapse and temporary building denial
   with uninterrupted play; repeat after restarting the game process.
3. With the same package files and configuration, record and replay that match.
   Compare damage order and the final state with diagnostics OFF/ON.
4. Copy the save to Maps, rename its extension to `.map`, open and edit it in
   the game editor, save it and start a new match. Check that stale pending
   collapses and denial zones from the original battle do not carry over.

No new whole-game save/replay, native variant or frame-time acceptance is claimed.
Multiplayer testing remains player-owned. The pre-existing disable/patch ownership
limitations in UCP-NATIVE-REVIEW.md also remain explicit; this change does not add
a competing patch manager or claim to solve unrelated lifecycle work.
