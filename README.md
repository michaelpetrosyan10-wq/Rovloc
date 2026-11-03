# Rovloc

A first-person survival horror game for 1–4 players in a pitch-black, post-apocalyptic school. It runs in the browser
(**[rovloc.vercel.app](https://rovloc.vercel.app)**) as one self-contained HTML file, so it works on school
Chromebooks. Co-op uses room codes.

Everything is generated in code: the building, the Creature, the light, the audio and the UI. A Luau world builder
generates the school. It runs offline in Lune, and its export is baked into the web build. Rovloc began as a Roblox
game; that runtime is retired, and git history keeps it.

- **Architecture:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) covers the web runtime, the map pipeline and the
  gates.
- **World data format:** [`web/DATA.md`](web/DATA.md).
- **Checks and tools:** [`tools/README.md`](tools/README.md).

## Quick start

You need Node 22, Python 3 with numpy and Pillow, Playwright's Chromium, and the tools pinned in `rokit.toml` (installed
with `rokit install`).

```sh
cd web
npm ci
npm run data      # export the world (Lune) -> pack the textures -> bake world.json + world.bin
npm run build     # -> dist/Rovloc.html, the whole game in one file
```

Open `web/dist/Rovloc.html` to play. To deploy, copy it to `site/index.html` and push.

## Checks

```sh
tools/verify.sh                                         # map tool: rojo, luau-lsp strict, selene, stylua, Lune checks
cd web && node tools/data-test.mjs && npm run check && node tools/game-smoke.mjs   # web game
```
