# Rovloc

A 1–4 player co-op first-person survival horror game for Roblox, set in a pitch-black, post-apocalyptic school.
Everything is generated in code: the building, the Creature, animation, audio and UI. There are no model files and
no asset ids.

- **Architecture:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) covers the file tree, the Explorer hierarchy,
  collision groups, contracts and the 8-phase roadmap.
- **Setup and publishing:** [`docs/PLACE_SETUP.md`](docs/PLACE_SETUP.md) covers the settings Rojo can't set, and how
  to publish from a phone without Studio.

## Quick start (Rojo + VS Code)

```sh
rokit install                     # rojo, selene, stylua, luau-lsp, lune at pinned versions
rojo build -o Rovloc.rbxl         # build the place once (applies every engine setting)
# open Rovloc.rbxl in Studio and publish it, then:
rojo serve                        # live-sync code into that place
```

## Checks

```sh
selene src tests && stylua --check src tests       # lint + format
lune run tools/lune/check.luau all                  # layouts, world build and specs, outside Roblox
```

CI runs all of the above, plus strict `luau-lsp` type-checking, on every push. It also uploads a ready-to-open
`Rovloc.rbxl` for Studio-only users.
