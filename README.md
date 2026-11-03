# Rovloc

A first-person survival horror game for 1–4 players in a pitch-black, post-apocalyptic school. It ships natively on
two platforms, the same game with every feature on both:

- **the website**, **[rovloc.vercel.app](https://rovloc.vercel.app)**: one HTML file, with co-op over room codes;
- **a Roblox game**, built from this repository with Rojo.

Everything is generated in code: the building, the Creature, the light, the audio and the UI. One Luau world builder
makes the school for both: Roblox builds it live, and the web bakes its export. Each platform runs its own native
gameplay code: Luau services and controllers on Roblox, a JavaScript engine on the web. Both follow the same shared
configs and specs. A Graphics setting goes from Max (the default) down to Potato, for school Chromebooks.

- **Architecture:** [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) covers what is shared, both runtimes, the
  Graphics tiers, the map pipeline and the gates.
- **Roblox place setup and publishing:** [`docs/PLACE_SETUP.md`](docs/PLACE_SETUP.md).
- **Roblox lighting matched to the web:** [`docs/LIGHTING-PARITY.md`](docs/LIGHTING-PARITY.md).
- **World data format:** [`web/DATA.md`](web/DATA.md).
- **Checks and tools:** [`tools/README.md`](tools/README.md).

## Quick start: Roblox

You need the tools pinned in `rokit.toml` (`rokit install`).

```sh
rojo build -o Rovloc.rbxl         # build the place once (applies every engine setting)
# open Rovloc.rbxl in Studio and publish it, then:
rojo serve                        # live-sync code into that place
```

CI uploads a ready-to-open `Rovloc.rbxl` on every push, for Studio-only users.

## Quick start: web

You need Node 22, Python 3 with numpy and Pillow, Playwright's Chromium, and the same rokit tools (the export runs the
world builder in Lune).

```sh
cd web
npm ci
npm run data      # export the world (Lune) -> pack the textures -> bake world.json + world.bin
npm run build     # -> dist/Rovloc.html, the whole game in one file
```

Open `web/dist/Rovloc.html` to play. To deploy, copy it to `site/index.html` and push.

## Checks

```sh
tools/verify.sh       # Luau: project files, rojo, luau-lsp strict, selene, stylua, capscan, layouts, world, every spec, server lifecycle
cd web && node tools/data-test.mjs && npm run check && node tools/game-smoke.mjs   # web game
```
