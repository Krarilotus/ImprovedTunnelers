# Loading saves after changing settings (1.7.3)

**TL;DR:** 1.7.2 refused every save once a gameplay setting had changed. The
refusal went through Map Extensions' fatal path, so the game showed an error and
closed. Saved state now holds only simulation data and what is needed to read it,
so the current settings apply. Malformed or unsupported data is still refused before
anything is written, with a short message in the game's language.

## Reported failure, traced

Reproduced with the real Map Extensions 1.1.5 load path and the unchanged 1.7.2
`state.lua` (`bench/test_save_settings.py`; output in the task record). A save made
with one setup, loaded after a restart with one changed setting:

1. Map's wrapped `readWorld` runs; the game reads its native sections.
2. `afterReadSav` runs `required.validate`. The manifest check passes: format and
   source fingerprint are unchanged.
3. The tunneler validator compares the payload identity. 1.7.2 included the bytes
   of 17 settings (repair delay and its switch, collapse and spread damage, radius,
   speed, retargeting, targets, digging protection, buttons, stances and raids) and
   put the ground-restoration switch in its capability string. Diagnostics loaded
   only because its byte was just outside that range.
4. The mismatch is raised before any tunneler write. Map's `nativeBoundary` logs
   it and calls `log(FATAL)`: the framework shows a dialog and loguru stops the
   process. Native sections are already loaded, so the game cannot continue.

This was an intentional rejection reported through the supported failure path. It
was not an uncaught callback error, incompatible data, a stale reference or a
partial restore. The rejection itself was unnecessary.

## What the identity protects

| Part | Protects | 1.7.3 |
|---|---|---|
| Format id | Payload layout | Kept; now `improved-tunnelers-state-2` |
| Source fingerprint (`init.lua`, `templates.lua`, `state.lua`) | Control-block offsets, record/route layout and their meaning | Kept; Map's manifest checks it too |
| Native capabilities | That the bindings which finish saved work exist (collapse, retarget, family damage, aim, anchors) | Kept, minus the terrain setting that 1.7.2 mixed in |
| Setting bytes | Nothing in the payload layout | Removed |

Recorder already freezes every module's resolved options for replays
(`ucp_recorder/code/recorded-settings.lua`). Exact replay continuation therefore
still needs matching settings without this module duplicating that check.

## How saved work continues after a change

Every saved field means the same thing under any setting:

- **Queued collapse tiles** keep their tile, coordinates and owner. Their remaining
  damage uses the current damage values, and the current speed sets how many are
  done per tick.
- **The tile being taken apart** keeps the radius it began with (new `STEP_RADIUS`,
  set by `queue_tick` and read by `queue_step`). 1.7.2 read its saved cursor using
  the current radius setting. A smaller radius rejected the save, and without the
  check the cursor would have been read against a different area. The changed
  radius applies from the next tile. This is the only layout change, hence format 2.
- **Denied ground** keeps its saved expiry tick; new breaches use the new delay.
  With the delay switched off, existing zones are inert and expire as saved.
- **Tunnel records, lines and routes** are kept. Changed retarget limits apply to
  later decisions; when retargeting is off they are simply not used.
- **Ground restoration** happens at fill time and in native cleanup, not from the
  queue, so it was removed from the capability string.
- **Skip digging tunnelers in selections** writes the native unit field +0x2A4, which
  the save keeps. Native `UpdateTunneler` only copies a global into it when it is zero
  (SHC 0x54E6FB, Extreme 0x54EB1B). Match setup resets that global to zero, and the
  feature depends on it staying zero. So a tunneler hidden underground when the game
  was saved could otherwise remain unselectable after loading with the switch off.
  With the switch off, the stance hook now does what it does when on, once a
  tunneler is no longer digging: it sets a zero field to 1. Digging tunnelers and
  non-zero native values are left alone. Behavior with the switch on is unchanged.
- **Protect underground tunnelers** is a targeting filter and stores nothing.

Pre-existing, unchanged: the "spread to nearby tiles" switch is written to the
control block, but no payload reads it, in upstream `main` as well. Radius and
spread damage still decide the spread. This needs the author's decision; it is not
part of this save fix.

## Rejections

All checks run before the first write, and Map runs every validator before any
restore. They raise one of three localized messages from `messages.lua`, in the game
language reported by textResourceModifier:

- missing state on a `.sav`;
- different format, module code or game edition;
- damaged or out-of-range data, including a partial tile outside its own radius.

Each refusal goes through Map's existing fatal path. Map Extensions 1.1.6 removes
the `file.lua:line:` prefixes that the framework's `@path` chunk names add, so the
dialog shows the message itself. Details stay in `ucp3-error-log.log`. The game
still closes after the dialog, by Map's design. The framework shows this dialog
with `MessageBoxA`, so non-ASCII text in it depends on the system code page; that
is unchanged and belongs to the framework.

`.map` loads, including a `.sav` renamed to `.map`, still initialize fresh tunneler
state through Map's `initializeOnMap` policy. Malformed battle data in them is
ignored, not restored.

## Migration

No migration existed before 1.7.3, and none is added. Map's manifest rejects 1.7.2
saves in 1.7.3 because the package fingerprint differs; that is unchanged
package-identity policy. Renaming such a save to `.map` still opens it as a scenario.

## Reuse decision

| Need | Owner inspected | Decision |
|---|---|---|
| Save/load, preflight, fatal stop | Map Extensions `6837657` `callbacks.lua`, `required.lua`, `game.lua`, tests | Reused unchanged |
| Short dialog reason | Map Extensions `game.lua:nativeBoundary` strips only `[string]` positions; framework `extensions/environment.lua:74` loads `@<path>` chunks | Owner fix in 1.1.6 with a Lua 5.4/LuaJIT test |
| Replay setting identity | Recorder `recorded-settings.lua` | Reused; settings removed from this payload |
| Game language | textResourceModifier `GetLanguage`, as in `missingSaveState` | Reused |
| Native radius | Existing `queue_tick`/`queue_step` payloads | One control-block field; no new hook |
| Selectable after switching off | Existing stance hook on `UpdateTunneler` | Two instructions in that hook; no new hook |

## Checks

- `test_save_settings.py`: save, then load after each of 19 single-setting changes, through Map's real
  hook boundary, preflight and restore; a partial tile keeps its radius; a new
  match/`.map` after loading starts fresh; unsupported, malformed and missing state
  stop with a localized first dialog line and no tunneler writes.
- `test_queue_determinism.py`: the real FASM-built `queue_tick`/`queue_step`
  finish a partial 5x5 tile after the radius is reloaded as 0, then spread only
  the next tile's own tile. `init.lua` assembles both payloads with the expected
  radius fields on Crusader and Extreme 1.41. The stance hook runs with the switch ON
  and OFF for eight unit states and three starting values.
- Existing state, terrain, portability and integration tests updated where they
  asserted the old setting rejection or terrain identity.

These are component checks with stubbed native calls. In-game save/load, editor
and replay acceptance is listed in the PR checklist and has not been performed.
