# Improved Tunnelers

A UCP3 module for Stronghold Crusader and Stronghold Crusader Extreme. Tunnels dug at the
same castle meet at one piece of wall, open it, and then work their way inwards towards the
enemy's camp.

What the module does, in plain English, is in `FEATURES.md`. The short overview the UCP
launcher shows is in `module/description.md` and `module/locale/description-*.md`.

## What is in here

| Folder | |
|---|---|
| `module/` | the module itself - this is the source of truth, edited in place |
| `bench/` | the emulator bench: the module's own Lua runs against the real exe image, its assembly is assembled with UCP's own fasm.dll and then executed |
| `tools/publish.py` | copies `module/` into the game's module folder under a new version |

## Working on it

1. Edit under `module/`.
2. Run the bench until it is green: `bench/test_tunnelers.py` (both executables, stubbed game
   functions, quick) and `bench/test_real_lines.py` (vanilla, the game's own mover, search,
   trace and collapse running whole tunnels tick by tick - a few minutes).
3. `python tools/publish.py --bump` - raises the last version slot and copies the module to
   `ucp/modules/improved-tunnelers-<version>`, leaving the build before it installed and
   clearing anything older.
4. In the UCP GUI press F5, then apply. `ucp-config.yml` is never edited by hand: the apply
   button moves the pin.
5. Commit and tag: `git commit -am "<version> - <what changed>" && git tag v<version>`.

Every version that was published has a tag, so any build can be brought back with
`git checkout v1.4.8 -- module`.

## The bench

`bench/` is a snapshot of the working copies under `%TEMP%\shcw`; it needs `lupa`,
`keystone`, the two game exes and UCP's `fasm.dll`, and it still runs from that temp
directory. The copy here is so the harness and its 500-odd assertions survive a temp wipe.

The newer bench files are ordinary `unittest` tests, run from `bench/` with
`python -m unittest test_integration test_queue_determinism test_replay_state test_native_terrain test_map_portability test_save_settings`.
They need `lupa`, `unicorn`, `pefile`, `capstone` and `pyyaml`, and these variables:
`SHC_GAME_DIR` (folder with both exes) and `FASM_EXE` (the FASM assembler). The save
tests also need `UCP_MAP_EXTENSIONS` (a Map Extensions 1.1.6 checkout) and
`UCP_FRAMEWORK_PROXIES` (the UCP framework's `extensions/proxies.lua`). A test skips
itself when its files are not supplied.

## UCP integration

The module needs UCP 3.0.7, textResourceModifier 0.3.0 and Map Extensions 1.1.6.
Map Extensions saves pending collapse work with the game; loading a `.map`, including
a save renamed to `.map`, starts with fresh tunneler state. Options are in the
launcher's usual categories, in the nine languages of `module/locale`.
