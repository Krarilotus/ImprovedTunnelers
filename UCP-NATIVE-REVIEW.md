# Native integration review

Reviewed against UCP framework **v3.0.7** (`77c6acc`), not an unreleased API.
`core.lua` supplies cached `core.AOBScan`, code allocation/writes, `core.itob`
and `core.getRelativeAddress`; `hooks.lua` supplies `afterInit`.
Legacy reference: `extension-ucp2-legacy` at `caa50ab`, especially
`port/u_fireballistafix.lua`, `o_engineertent.lua` and
`o_change_siege_engine_spawn_position_catapult.lua`. Its signatures and decoded
operands illustrate UCP integration; its unimplemented disable paths are not
a cleanup model to copy.

## Reuse decisions

| Capability | Existing implementation and decision |
| --- | --- |
| Discovery | Keep stock cached `core.AOBScan`; strengthen identifying patterns. No private scanner, cache, full-process duplicate pass or dependency on proposed framework PR149. |
| Jumps | Use `core.getRelativeAddress` and `core.itob` instead of manual displacement/byte encoding. The small wrapper only adds the JMP opcode and NOP padding. |
| Assembly | Keep `core.allocateAssembly` with named resolved operands. `core.insertCode` would allocate a second trampoline around these already allocated payloads. |
| Decoding | Read operands and signed displacements from validated instruction sites. UCP3.0.7 `utils.AOBExtract` has an offset error for `@()` captures after the first byte; do not introduce that bug or add another scan to decode an already resolved call. |
| Restore | Retain the existing original-byte list: stock core has no patch-ownership/rollback handle. Do not add a second manager. Cross-extension unload ownership remains a limitation. |
| Language | Reuse textResourceModifier0.3.0 GetLanguage/SetText after the framework's afterInit; no private language or encoding service. |
| Gameplay | Keep original targeting/path/damage calls and the existing tunneler payloads. Starting troops stay in AI Swapper; crew lifecycle stays in Fixed Engineers; new siege policy stays in AIC Tactics. |

## Corrections in 1.6.6

- The keep pattern previously matched two native functions. Include the following
  troop-role case to select one, retaining wildcarded absolute operands.
- The tick pattern now includes the actual absolute load consumed at offset14
  and its following comparisons, rather than identifying only preceding loads.
- Reject zero/non-numeric scan results before reading memory.
- `ui.enabled=false` leaves all original button code intact. Previously two
  branches were changed unconditionally while the replacement button was OFF.
- A failed damage-walk guard also prevents route construction from reading that
  rejected function's operands.
- Missing team discovery disables camp targeting, using the existing no-anchor
  path; it no longer fabricates an all-zero alliance table.
- Delegate jump encoding to the stock framework. Assembly templates are unchanged.

## Evidence and limits

The replay findings below describe **1.6.6**. They are addressed in the 1.7.0
implementation and focused checks in [UCP-REPLAY-STATE.md](UCP-REPLAY-STATE.md).
Whole-game save/editor/replay acceptance is still pending; the remaining patch
ownership limitations below are unchanged.

**Replay blockers:** `queue_tick` uses RDTSC/DRAIN_BUDGET to choose when to stop
applying gameplay damage, even with diagnostics OFF. An isolated execution of
the actual FASM payload from identical state processed two damage steps with a
100-cycle simulated clock increment, but only one with a 10,000,000-cycle increment.
The damage/path callbacks were controlled stubs: this establishes scheduling
nondeterminism, not a full recorded-game desync. Use deterministic bounded work
quotas in the existing queue; keep wall-clock timing observational only.

Map Extensions1.0.0 (`d939912`) already exports `registerSection` with initialize,
serialize and deserialize callbacks. Its newer required-state/native-interface
work is used by AIC Tactics; coordinate there for stronger load admission.
Recorder0.51.0 (`651817d`) saves through the extension-aware native world owner
and fingerprints packages/settings, but does not automatically capture this
module's private heap. Reuse Map Extensions for queue/route/denial state; do not
add private save hooks or patch Recorder to reconstruct missing state. Encode
module-relative pointers as offsets and validate before restoring. Both the
wall-clock scheduler and missing saved state remain unresolved in 1.6.6.

Offline scans on six licensed SHC/Extreme1.41 fixtures (local, official EFIGS
patch and official Polish patch pairs) find exactly one match for each of the
15 signatures. Their code sections represent **two distinct layouts**, not six.
The decoded jump-hook spans end on original instruction boundaries; separate
branch-opcode and immediate edits are intentional. This does not establish
every payload's ABI or gameplay.

Four focused bench tests cover localization/defaults, delayed text integration,
UI OFF, missing/invalid discovery and rejected native context. Payload assembly
is stubbed in these Lua tests; no native instructions are executed. Research
scripts and fixture hashes remain outside the installable module.

The framework scanner retains its documented first-match behavior. Offline
uniqueness is not a runtime ambiguity guarantee on unknown/modified binaries.
No fixed executable address or per-hash fallback was introduced. Numeric unit
fields, function-relative offsets and enum values are not executable bindings.

**Remaining acceptance:** the module's heap-held collapse queue, route/denial
state and pending work are not integrated with a save/load owner. Tick rollback
clears denial zones only; it does not establish safe loading of an equal/later
tick or a fresh-process save. Disable restores remembered bytes without checking
whether a later extension owns the site. Full installation failure rollback,
cross-module composition, gameplay/save behavior, encoding and performance still
need owner review/validation. This candidate is not a completed release audit.
Multiplayer testing remains player-owned.
