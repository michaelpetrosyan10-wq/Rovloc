# Rovloc — Architecture

Rovloc is a first-person survival horror game for 1–4 players in a pitch-black school, played in the browser at
[rovloc.vercel.app](https://rovloc.vercel.app). The whole game ships as **one self-contained HTML file** (code, world,
textures; no network until co-op) so it runs on school Chromebooks, even from `file://`.

The game started on Roblox. The Roblox runtime is retired (git history keeps it, up to `71db8fd`). Its Luau **world
builder** remains: it is the map tool that generates the school the browser game plays in.

## 1. Repository

| Path | What it is |
| --- | --- |
| `web/src/` | The game: engine, creature, game, co-op and net (§2). |
| `web/tools/` | The export, the bake, the single-file build and the headless tests (§3, §4). `web/DATA.md` documents the world data. |
| `src/ReplicatedStorage/Shared/` | The map tool: the Luau world builder and the configs and utilities it needs (§3). |
| `src/MaterialService/RovlocTextures.model.json` | Frozen texture variants. With `Config/TextureAssets.luau` they decide which surfaces are textured. |
| `tests/` | The world specs (`Specs/*.spec.luau`) and their runner (`SpecRunner.luau`). |
| `tools/` | `verify.sh` (the gates), the Lune harness and checks, and the texture generator. See `tools/README.md`. |
| `default.project.json` | The Rojo tree of the map tool and its specs: built for Lune, mapped for luau-lsp. |
| `site/` | The deployed page (`index.html`) and `vercel.json`. |
| `docs/store/` | Promo art and store copy. |

## 2. The web runtime (`web/src/`)

`main.js` shows the loading screen, inflates the world data embedded in the page, creates the engine, then calls
`start(engine)` from `game/index.js`. Without a game module (or with `?sandbox`), the build links the engine
sandbox: a free walk through the school.

### Engine (`engine/`)

`Engine.create()` returns one object; `engine/index.js` documents the API that the creature and the game use.

- **World:** `data.js` decodes the baked world. `world.js` turns it into the scene: chunks per level, material and
  cell, with level culling. It also gives per-level collision BVHs (three-mesh-bvh) and the queries (`raycast`,
  `lineClear`, `probeAt`, `zoneAt`, `levelAt`).
- **Rendering:**
  - `renderer.js`: WebGL2 with dynamic resolution, the torch shadow pass, the viewmodel pass, bloom and the post grade;
  - `materials.js`: the baked vertex light, the dynamic lights, flicker and fog;
  - `lighting.js`: flicker, blackouts, lightning and the light budget;
  - `volumetrics.js`, `sky.js`;
  - `quality.js`: the Low / Medium / High tiers, auto-detected.
- **Player:** `player.js` (MoveState machine, meters, first-person camera), `physics.js` (a floating capsule),
  `camera.js`, `viewmodel.js`, `flashlight.js`, `panic.js`.
- **Systems:**
  - `loop.js`: a fixed 30 Hz tick plus a per-frame callback;
  - `input.js`: keyboard, pointer lock, gamepad and touch;
  - `audio/`: WebAudio synthesis; there are no sound files;
  - `ui/`, `prompts.js`;
  - `entities.js`: doors, grates, lockers and pickups, which move;
  - `noise.js`: the noise bus the Creature hears;
  - `save.js`, `settings.js`.

### Creature (`creature/`)

`createCreature(engine)` returns the monster.

- **Brain:** `service.js` runs it at 10 Hz. The state machine is in `brain.js` and `states/`. Its inputs are
  `perception.js`, `hearing.js` and `pacing.js`.
- **Movement:** `locomotion.js`, with `nav.js` for zone-graph pathfinding, `ventgraph.js` and `water.js`.
- **Look:** `view.js` draws the skinned rig from the bake (`rig.js`, `body.js`) and animates it procedurally
  (`animator.js`, `profile.js`).
- **The catch:** `jumpscare.js` and `jumpscareView.js`.
- **Collision:** `monsterCollision.js` reads `passthroughData.js`, which `web/tools/creature-collision.mjs` generates.

### Game (`game/`)

- **Root:** `start.js` builds the systems. `game.js` drives them: the match phases, the active level, the run stats and
  the scripted scenes. Each system implements any of `beginRun`, `endRun`, `tick`, `frame`, `levelActivated` and
  `phaseChanged`.
- **Adapters:** `env.js` is the one adapter to the engine, and `creatureApi.js` the one adapter to the Creature.
- **Run flow:** `menu.js`, `lobby.js`, `match.js` (deploy, run seed, outcomes, Results) and `life.js` (downed, revive,
  death).
- **Floors:**
  - `levels/level0–5.js`: each floor's beats;
  - `objectives/`: one objective per floor, read from `meta.objectives`;
  - `mechanics/`: doors, lockers, traps, vents, the pool, flasks, the parachute, the airlock, debris;
  - `scenes.js` and `timeline.js`: the scripted moments.
- **Planning:** `worldData.js` indexes the world metadata. It ports RunDirector's rules, so every run picks its exits,
  objective spots and props from the export's candidates by the run seed.
- **The rest:** `ui/` (HUD and screens), `profile.js` (saved progress) and `dev.js` (dev shortcuts, `?dev`).

### Co-op (`game/coop/`) and net (`net/`)

Co-op is for 2–4 players, joined with a room code.

- **Authority:** the host's page is the server. It runs the lobby, the run seed and routes, the Creature, the shared
  objectives, doors, traps, pickups, lockers, life states and results.
- **Clients:** each page simulates its own player and sends its pose at `StateHz`. It sends intents for anything
  shared. The host applies them and broadcasts events and world state.

`net/` has the parts underneath:

- `session.js`: one host plus up to three clients in a star;
- `transport.js`: the `Transport` and `SignalingChannel` contracts and the relay transport;
- `webrtc.js`: direct data channels, falling back to the relay;
- `supabase.js`: Supabase Realtime for signalling in production;
- `localRelay.js`: the stand-in used by the tests;
- `codec.js`: binary poses and delta-coded relay packets.

Played alone, none of it runs, and the page makes no request.

## 3. The map pipeline

```text
src/ (Luau world builder) ──rojo build──▶ place ──Lune export──▶ world-raw.json ──bake──▶ world.json + world.bin
                                                                     textures ──┘                      │
                                     site/index.html ◀── copy ── dist/Rovloc.html ◀── single-file build ┘ ──▶ Vercel
```

| Step | Command (in `web/`) | What happens |
| --- | --- | --- |
| Export | `npm run export` | `tools/export-world.luau` builds `default.project.json` with Rojo and loads it in Lune through `tools/lune/harness.luau`. It then does what a run's server did at the fixed seed 20251029 on Standard: builds the school, the run's plan with props and fixtures, every objective's candidate spots, the cosmetic dressing, the Creature rig and the moonlight windows. It writes `build/cache/world-raw.json`. |
| Textures | `npm run textures` | `tools/textures.py` packs the generator's maps (`tools/textures/`) into WebP. |
| Bake | `npm run bake` | `tools/bake.mjs` tessellates every part and bakes vertex light (BVH shadows, AO, sky, probes). It packs the result into `build/world.json` (metadata) and `build/world.bin` (quantised streams). See `web/DATA.md`. |
| Build | `npm run build` | `tools/build.mjs` bundles `src/` with esbuild and inlines the gzipped world and textures into `dist/Rovloc.html`. |
| Deploy | — | Copy `dist/Rovloc.html` to `site/index.html` and push; Vercel serves `site/` at rovloc.vercel.app. |

`npm run data` runs the export, textures and bake in order. Every step is deterministic. Two runs differ only in the
bake's timing (`stats.bakeSeconds`) and in eight `worldConfig` function entries that the export writes as their
addresses.

### The world builder (`src/ReplicatedStorage/Shared/`)

- **`World/ProceduralWorldBuilder/`:**
  - the builder (`init.luau`);
  - the shell, stairwells, lobby and skyline builders;
  - the props under `Props/`;
  - the level blueprints (`Layouts/*.luau`, validated by `LayoutSchema`); a tunnel floor's map comes from
    `TunnelPlanner` and passes `TunnelRules` (the authoring guide is `docs/MAPS.md`);
  - the creature rig (`CreatureRigBuilder`);
  - `ZoneGraph` (rooms and door edges);
  - lighting: `LightingMood`, `LightingRig` and `FixtureGlow`;
  - surfaces: `Palette`, `MaterialLibrary` and `Finishes`;
  - `ObjectivePlaces`.
- **`World/RunDirector.luau`:** the pure, seeded run plan (objective picks, traps, flasks, batteries, grate locks and
  routes). The export runs it at the fixed seed and writes its rules into the metadata. The web ports them.
- **`World/Volumetrics.luau`:** the moonlight window specs, `meta.windows`.
- **`Vents/VentGraph.luau`:** the duct network.
- **`Config/`:** `WorldConfig`, `CreatureConfig`, `DifficultyConfig`, `GameConfig`, `ObjectiveConfig`,
  `CameraConfig` and `TextureAssets`.
- **The shared contract:** `Enums`, `Types`, `Attributes`, `Tags`, `CollisionGroups`, `Instances` and `Strings`.
- **Utilities:** `Util/Log` and `Util/MathUtil`.

Everything here is `--!strict` Luau. Requires go by instance path through the Rojo tree, for example
`require(ReplicatedStorage.Shared.World.RunDirector)`. The builders still create Roblox instances, but only inside
the Lune harness. The harness provides the engine services the builders touch, and a deterministic `Random`.

## 4. Gates

**The map tool:** `tools/verify.sh` runs from the repo root (see `tools/README.md`). CI runs it on every push. It
checks, in order:

1. `rojo build` and `rojo sourcemap`;
2. `luau-lsp analyze` in strict mode;
3. `selene`;
4. `stylua --check`;
5. `lune run tools/lune/check.luau all`: the layouts, the world build and the world specs (`tests/Specs`).

**The web game:** run these in `web/` after a change, with a baked world in `web/build/`.

| Command | Checks |
| --- | --- |
| `node tools/data-test.mjs` | The world data codec round trip and structural checks of the baked world. |
| `npm run check` | Builds `dist/Rovloc.html`, then loads it headless: it boots from `file://`, makes no stray requests or console errors, and renders. |
| `node tools/game-smoke.mjs` | The game played headless from the title through each floor's signature moment. |
| `node tools/creature-sim.mjs` | The Creature's scenarios on the real world, on a fake clock. |
| `node tools/objective-run.mjs` | Every floor's objective played through, for each seed. |
| `node tools/coop-test.mjs`, `node tools/net-test.mjs` | Co-op across real browser pages, and the network layer's unit tests. |
| `node tools/playtest.mjs` | A scripted and randomised player, for finding bugs. |
