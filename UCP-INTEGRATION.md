# UCP 3.0.7 integration candidate

The native tunneler behaviours already belong to this repository at `a23619c`.
This contribution does not copy the older Unit Behaviour Fixes idle-response
patch or AI Swapper's starting-troop hook. Version1.6.5 adds standard package
inputs, declared dependencies, root description, nine UI catalogs/descriptions
and a localized existing category. UI defaults now match the existing native
fallbacks: denial120 seconds, spread damage60. Explicit saved values still win.

AI Swapper1.5.0 is optional, not a dependency. It alone owns starting counts,
native match initialization, acquisition and initial-defense assignment. An AI
content pack which authors `startTroops.<mode>.Tunneler` needs that dependency; this
behaviour module does not. Fixed Engineers independently owns crew cleanup and
safe dismounting. Do not simultaneously select Unit Behaviour Fixes' duplicate
tunneler-response correction.

## Reuse and lifecycle review

Inspected released UCP3.0.7 core/hooks, AI Swapper's afterInit caller and
textResourceModifier0.3.0 (`5ab58fa`) `init.lua`/`textResourceModifier.cpp`.
Use `hooks.registerHookCallback("afterInit", ...)`, when cr.tex is loaded,
`textResourceModifier:GetLanguage()` (native text6/0) and `SetText` (UTF-8 input,
native game-codepage conversion, boolean success). No private language service,
encoding converter or extra lifecycle hook is added. GUI language remains the
frontend locale mechanism, independently of game text.

The existing placement-message patch now installs only after the localized
string is accepted. Previously pcall success incorrectly accepted a false
SetText result. Unknown language, missing service or refusal leaves the original
game message. A disabled/superseded module cannot install the deferred hook.
Message translations cover the nine GUI languages plus native Italian/Polish;
English/American share text. Actual custom cr.tex language labels and codepages
need in-game verification; no fallback is represented as a completed translation.
Native assembly payloads/signatures are unchanged. The existing message site
is scanned/guarded at installation, preserving original hook ownership.

## Checks and limitations

`python -m unittest discover -s bench -p test_integration.py -v` passes both
tests when SHC_GAME_DIR points to the licensed local SHC/Extreme pair. Catalog
keys, all option/runtime defaults, manifest inputs, root/English description and
Lua compilation are checked. The real-image Lua lifecycle cases verify delayed
registration, one installation, disable-before-init, explicit OFF and false/
missing/unknown-language rejection. Assembly allocation is stubbed in these
cases; this is not native-payload, encoding or gameplay acceptance.

The original broad emulator bench has not been rerun for this packaging change.
Its author-specific FASM/temp paths and missing `t` import remain separate bench
portability work. The narrow tests reuse its host with explicit fixtures and do
not launch or modify the games. No executable files are distributed.

Human translation review, installed GUI/RTL layouts, native text encoding,
combined in-game/save validation, full binding/variant/performance review and
maintainer review remain open. Technical diagnostics remain English. Multiplayer
testing is player-owned. This is an upstream contribution/test candidate, not a
verified release. An upstream license is not present in the inspected tree;
its author must choose the terms before store release readiness is claimed.

## Package

Only `module/` is shipped, using the explicit `module/files.yml` allowlist:
three Lua files, metadata, options and localized descriptions/catalogs.
`bench/` and `tools/` are developer tooling outside the package. Python is not
a game-time dependency. Local disassembly/research scripts are not part of this
repository contribution either.

Use UCP's existing `scripts/build-module-package-files.ps1` against `module/`
with its `files.yml`, or the extension store builder with source location
`module`. The contents belong at ZIP root, including an explicit `locale/`
directory entry. Repository Download ZIP is not an installable module. Use
the store's signing process for secure distribution; do not run the author's
machine-specific `tools/publish.py` in another installation.
