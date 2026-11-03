# tools/

The map tool's checks and helpers. The web game's own tools live in `web/tools/`.

| Path | What it does |
| --- | --- |
| `verify.sh` | The gates. Run it before every commit that touches `src/`, `tests/` or `tools/lune/`. |
| `verify-files.sh` | The same luau-lsp, selene and stylua checks on just the paths you give it. |
| `lune/harness.luau` | Loads a Rojo-built place in Lune and runs the Luau modules outside Roblox (engine shims). |
| `lune/check.luau` | `layouts`, `world`, `specs` or `all`: the blueprints, the world build and the world specs. |
| `textures/` | The PBR texture generator (`generate.py`, `materials.py`, `texlib.py`, `manifest.json`). `web/tools/textures.py` packs its output. |

## `verify.sh`

```sh
tools/verify.sh             # every gate
tools/verify.sh --no-lune   # skip the Lune checks (about 10 s instead of a few minutes)
```

It runs, from the repo root:

1. `rojo build` and `rojo sourcemap` of `default.project.json`;
2. `luau-lsp analyze` in strict mode over `src` and `tests`, against that sourcemap;
3. `selene src tests`;
4. `stylua --check src tests`;
5. `lune run tools/lune/check.luau all`.

It prints `ALL GATES GREEN` and exits 0, or prints the problems, then `GATES FAILED`, and exits 1.

### Tools it needs

- **rojo, selene, stylua, lune:** on `PATH`. `rokit install` installs the versions pinned in `rokit.toml`.
- **luau-lsp:** `$LUAU_LSP`, or else `luau-lsp` on `PATH` (also pinned in `rokit.toml`).
- **Roblox type definitions:** `$LUAU_DEFS`, or else `./globalTypes.d.luau` (git-ignored). Download the file that
  matches the pinned luau-lsp:

  ```sh
  curl -sSfL -o globalTypes.d.luau \
    https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/1.70.1/scripts/globalTypes.None.d.luau
  ```

CI (`.github/workflows/ci.yml`) installs the same tools and runs `tools/verify.sh` on every push.
