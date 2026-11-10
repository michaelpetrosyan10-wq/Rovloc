# tools/

The Luau side's checks and helpers: the Roblox game and the shared world builder. The web game's own tools live in
`web/tools/`.

| Path | What it does |
| --- | --- |
| `verify.sh` | The gates. Run it before every commit that touches `src/`, `tests/`, `tools/lune/` or a project file. |
| `verify-files.sh` | The same luau-lsp, selene and stylua checks on just the paths you give it. |
| `capscan.py` | Flags writes to engine properties game scripts may not write (plugin-only, read-only, not scriptable), from the Roblox API dump. |
| `lune/harness.luau` | Loads a Rojo-built place in Lune and runs the Luau modules outside Roblox (engine shims, a deterministic `Random`, fake remotes and players). |
| `lune/check.luau` | `layouts`, `world`, `specs`, `lifecycle` or `all`: the blueprints, the world build, every spec, and the real `ServerMain` driven through the match loop. |
| `textures/` | The PBR texture generator (`generate.py`, `materials.py`, `texlib.py`, `manifest.json`) and the Roblox uploader (`upload.py`, run by the Textures workflow). `web/tools/textures.py` packs the generator's output for the web, one set per graphics tier (2048, 1024, 512, 256; the 2048 maps come from `generate.py --size 2048 --out tools/textures/out/2048`: the same textures with the detail 1024 cannot hold). |

## `verify.sh`

```sh
tools/verify.sh             # every gate
tools/verify.sh --no-lune   # skip the Lune checks (about 10 s instead of a few minutes)
```

It runs, from the repo root:

1. the project files: every `$path` in `default.project.json`, `test.project.json` and `syncback.project.json`
   exists; the engine pins are intact; `test.project.json` is `default.project.json` plus `tests/` under
   `ServerScriptService.Tests`, and the game never ships `tests/`;
2. `rojo build` of `default.project.json` (the game) and `test.project.json`, and `rojo sourcemap` of
   `test.project.json`;
3. `luau-lsp analyze` in strict mode over `src` and `tests`, against that sourcemap;
4. `selene src tests`;
5. `stylua --check src tests`;
6. `capscan.py` over `src`;
7. `lune run tools/lune/check.luau all`: the layouts, the world build, every spec (the shared world, the Roblox
   services and controllers, the Graphics tiers) and the server lifecycle.

It prints `ALL GATES GREEN` and exits 0, or prints the problems, then `GATES FAILED`, and exits 1. A gate it had to skip
(no API dump, or `--no-lune`) is named after the verdict. `RBXL_OUT=Rovloc.rbxl tools/verify.sh` keeps the built place.

### Tools it needs

- **rojo, selene, stylua, lune:** on `PATH`. `rokit install` installs the versions pinned in `rokit.toml`.
- **luau-lsp:** `$LUAU_LSP`, or else `luau-lsp` on `PATH` (also pinned in `rokit.toml`).
- **Roblox type definitions:** `$LUAU_DEFS`, or else `./globalTypes.d.luau` (git-ignored). Download the file that
  matches the pinned luau-lsp:

  ```sh
  curl -sSfL -o globalTypes.d.luau \
    https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.70.1/scripts/globalTypes.None.d.luau
  ```

- **Roblox API dump** (for capscan): `$API_DUMP`, or else `./API-Dump.json` (git-ignored):

  ```sh
  curl -sSfL -o API-Dump.json \
    https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/API-Dump.json
  ```

CI (`.github/workflows/ci.yml`) installs the same tools, fetches both files, runs `tools/verify.sh` on every push and
uploads the built `Rovloc.rbxl`.
