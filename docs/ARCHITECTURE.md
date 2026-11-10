# Rovloc — Architecture

Rovloc is a first-person survival horror game for 1–4 players in a pitch-black school. It ships natively on two
platforms:

- **the website**, [rovloc.vercel.app](https://rovloc.vercel.app): one HTML file, with co-op over room codes;
- **a Roblox game**, built from this repository with Rojo.

It is the same game on both, with every feature on both. Neither platform embeds the other.

```text
            src/ReplicatedStorage/Shared  (Luau, shared by both platforms)
            world builder · layouts · props · Creature rig · LightingMood · RunDirector
            ObjectiveConfig · CreatureConfig · GraphicsConfig · contracts (Enums, Types, Attributes, ...)
                     │                                               │
      built live in the place:                          exported in Lune, then baked:
      the server builds the school, each client         web/tools → world.json + world.bin
      its cosmetic dressing                                          │
                     │                                               │
      Roblox runtime (Luau)                             web runtime (JavaScript)
      ServerScriptService: services                     web/src: engine · creature · game · coop · net
      StarterPlayerScripts: controllers
      ReplicatedFirst: the loading curtain
```

- **One world builder.** The Luau world builder is the single source of the maps, the props and the Creature rig. Roblox
  builds it live. The web exports and bakes it. A layout change shows up on both platforms.
- **Two native runtimes.** The gameplay logic is written natively per platform: Luau services and controllers on
  Roblox, the JS engine, Creature, game and co-op on the web. Both follow the same written rules: the shared configs
  (`ObjectiveConfig`, `CreatureConfig`, `DifficultyConfig`, `GameConfig`, `GraphicsConfig`), RunDirector's run plan
  (which the web ports rule for rule), `LightingMood`'s look and `docs/LIGHTING-PARITY.md`.
- **Shared specs.** `tests/Specs` checks the shared modules and the Roblox runtime in Lune. The web's headless tests
  play the same rules in the browser (§7).

## 1. Repository

| Path | What it is |
| --- | --- |
| `src/ReplicatedStorage/Shared/` | Shared by both platforms: the world builder, configs, contracts and pure rules (§2). The Roblox-only shared modules live here too: `Net`, `Audio`, `Animation`, `Sequence` and most of `Util`. |
| `src/ServerScriptService/` | The Roblox server: `ServerMain` and the services (§3.3). |
| `src/StarterPlayer/StarterPlayerScripts/` | The Roblox client: `ClientMain`, `RbxCharacterSounds` and the controllers (§3.4). |
| `src/ReplicatedFirst/` | `LoadingCurtain`: the black curtain until the client holds the world. |
| `src/MaterialService/RovlocTextures.model.json` | The MaterialVariants of the generated PBR textures. With `Config/TextureAssets.luau` they decide which surfaces are textured on both platforms. |
| `tests/` | The specs (`Specs/*.spec.luau`), their runner (`SpecRunner.luau`) and the Studio entry (`Runner.server.luau`). |
| `web/src/` | The web game: engine, creature, game, co-op and net (§4). |
| `web/tools/` | The export, the bake, the single-file build and the headless tests (§6, §7). `web/DATA.md` documents the world data. |
| `tools/` | `verify.sh` (the Luau gates), `capscan.py`, the Lune harness and checks, and the texture generator and uploader. See `tools/README.md`. |
| `default.project.json` | The Roblox game: the Rojo tree and the engine pins. It is what ships and what the web export builds. |
| `test.project.json` | The same tree plus `tests/` under `ServerScriptService.Tests`, for Lune, luau-lsp and Studio spec runs. |
| `syncback.project.json` | The script folders only, for `rojo syncback` (keeps the pins out of syncback). |
| `.github/workflows/` | `ci.yml` (the gates and a `Rovloc.rbxl` artifact), `publish.yml` (Open Cloud place publishing) and `textures.yml` (texture generation and upload). |
| `site/` | The deployed web page (`index.html`) and `vercel.json`. |
| `docs/` | This file, `LIGHTING-PARITY.md` (the Roblox look fitted to the web's), `PLACE_SETUP.md` (what Rojo can't set, and publishing) and `store/` (promo art and store copy). |

## 2. What both platforms share (`src/ReplicatedStorage/Shared/`)

Everything here is `--!strict` Luau. Requires go by instance path through the Rojo tree, for example
`require(ReplicatedStorage.Shared.World.RunDirector)`.

- **`World/ProceduralWorldBuilder/`:**
  - the builder (`init.luau`): `BuildAuthoritative` (the server's school, lobby and stair towers), `BuildCosmetic`
    (each client's skyline and dressing) and `BuildFixtures` (each run's doors, grates, lockers, traps);
  - the shell, stairwells, lobby and skyline builders;
  - the props under `Props/`;
  - the level blueprints (`Layouts/*.luau`, validated by `LayoutSchema`);
  - the Creature rig (`CreatureRigBuilder`);
  - `ZoneGraph` (rooms and door edges);
  - lighting: `LightingMood` (which fixtures burn, each level's film and its Roblox render), `LightingRig` and
    `FixtureGlow`;
  - surfaces: `Palette`, `MaterialLibrary`, `Finishes` and `SurfaceArt`;
  - `ObjectivePlaces`.
- **`World/RunDirector.luau`:** the pure, seeded run plan: objective picks, traps, flasks, batteries, grate locks and
  routes. Roblox's `NoiseAndDirectorService` runs it for every run. The web export runs it at the fixed seed and
  writes its rules into the metadata, and `web/src/game/worldData.js` ports them.
- **`World/Volumetrics.luau`:** the moonlight window specs. Roblox's `LightingController/Volumetrics` lights them; the
  web bakes them (`meta.windows`).
- **`Vents/`:** `VentGraph` (the duct network) and `VentPathfinder` (A* and retreat paths on it).
- **`Config/`:**
  - the game's rules: `GameConfig`, `DifficultyConfig`, `CreatureConfig`, `ObjectiveConfig`, `NoiseConfig`,
    `PerkConfig` and `TutorialConfig`;
  - the world: `WorldConfig` and `TextureAssets`;
  - the client: `CameraConfig`, `InputConfig`, `SettingsSchema` and `GraphicsConfig` (§5).
- **The contracts:** `Enums`, `Types`, `Attributes`, `Tags`, `CollisionGroups`, `Instances` and `Strings`.
- **Roblox-only shared modules** (used by both the server and the clients):
  - `Net`: the remotes and their validation;
  - `Audio`: the synthesizer, voice pool and buses;
  - `Animation/ProceduralAnimator`;
  - `Sequence`: `Timeline`, the scenes and the door, locker and parachute motions;
  - `Util`: `Signal`, `Trove`, `Spring`, `SpatialQuery`, `Ballistics`, `WaterRules`, `ObjectiveState`, `BinaryHeap`,
    plus `Log`, `MathUtil` and `Rng` (the world's random streams, §6), which the world builder also uses.

## 3. The Roblox runtime

### 3.1 Ground rules

| Rule | How it's enforced |
| --- | --- |
| `--!strict` everywhere | Every game and test `.luau` file. `tools/verify.sh` runs `luau-lsp analyze` in strict mode against the Rojo sourcemap, and `tools/capscan.py` rejects writes to plugin-only or read-only engine properties. |
| Works in Rojo **and** Studio | `src/` mirrors the Explorer one to one. Requires go by instance path, never string aliases. Runtime-created instances are only reached through `Shared/Instances.luau`. |
| One ordered bootstrap per side | `ServerMain` and `ClientMain` require an explicit module list and wrap every lifecycle call in `xpcall`. Later modules plug into registries owned by earlier ones (`ProceduralWorldBuilder.Register*`, `LevelDirector.RegisterLevel`, `MovementAuthority.RegisterValidator`, the `MonsterAIService` hooks). |
| Downward-only dependencies | `Shared → Core → Player → Vents, Monster → Levels, Mechanics → Match`. Upward traffic goes through typed `Signal`s or registered hooks, so there are no require cycles. |
| Server authority | Clients send *intents* through validated, rate-limited remotes. The server owns noise, damage, life state, meters, interactions, items, progression and data. Noise tiers come from the server's **observed** speed as well as the claimed move state. |
| No gameplay on `Touched` | `ZoneService` tests points against volumes with plain math at 10 Hz, so triggers, traps, checkpoints, water and scare volumes work in every collision group. |
| Events are remotes, state is attributes | Durable state replicates as attributes. Moments travel on one reliable `OneShot` remote with a server-time `startAt`, so every client starts the same `Timeline` on the same frame, and late joiners fast-forward. |
| Resettable runs | Each module has a `ServiceTrove` and a `RunTrove`. `RunLifecycleService` calls `BeginRun` in forward order and `EndRun` in reverse, then clears `Workspace.Runtime`. |
| Procedural only | Geometry is Parts, WedgeParts and built-in materials. Audio layers verified `rbxasset://sounds/` engine files through `SoundEffect` chains, built on the clients. Animation writes `Motor6D.Transform` in `PreSimulation`. There are no model files and no animation or sound asset ids. |

The API surface is checked against the Roblox API dump. Scripts never touch deprecated members (`task.*` and
`os.clock()`, never `wait`/`spawn`/`delay`/`tick`; selene enforces it). The only deprecated property pinned anywhere is
`Lighting.Technology = Future`, in the project file.

### 3.2 The place

`default.project.json` pins what scripts can't set: `StreamingEnabled = false`, `SignalBehavior = Deferred`,
`CharacterAutoLoads = false`, the R15 avatar settings, the legacy character controller, the sound service and the
Future lighting. `docs/PLACE_SETUP.md` lists the settings Rojo can't write. At boot `ServerMain` checks the ones scripts
can read and sets `BootError` if any is wrong.

```text
game
├── Workspace
│   ├── Lobby · School (Level0_Basement … Level5_Roof, Stairwells)   built by WorldService at boot
│   ├── Runtime            each run's fixtures, traps, flasks and batteries (wiped on reset)
│   ├── Cosmetic           client-local: skyline, dressing, effects (CosmeticWorldController and the effect owners)
│   └── Creature           [tag Creature] rig, CreatureHitbox
├── Lighting               the rig (Atmosphere, BaseColorCorrection, Bloom, SunRays) + client-local grades
├── ReplicatedFirst        LoadingCurtain
├── ReplicatedStorage      Shared (Rojo) · Remotes (created by Net)
├── ServerScriptService    ServerMain · Services/Core, Player, Vents, Monster, Mechanics, Levels, Match
├── MaterialService        RovlocTextures (MaterialVariants)
└── StarterPlayer          StarterPlayerScripts: ClientMain · RbxCharacterSounds · Controllers/Core, FirstPerson,
                           Characters, HUD, Gameplay, Match
```

Every character is built by `CharacterService` (R15 from the player's normalized HumanoidDescription, no `Animate`
script, no passive regen).

### 3.3 The server (`ServerScriptService`)

`ServerMain` checks the place, then requires the services in order and calls `Init`, then `Start`. The services:

- **Core:**
  - `WorldService` builds the world;
  - `RunLifecycleService` owns the match phases and the `BeginRun` / `EndRun` fan-out;
  - `LevelDirector` owns the current level;
  - `ZoneService` tests volumes;
  - `CollisionService` is the only writer of collision groups;
  - `CharacterService` builds characters and locks them;
  - `NoiseAndDirectorService` runs the noise bus, its sampler, the pacing director and RunDirector's plan;
  - `AudioService` sends audio cues;
  - `RunStatsService` counts each run's stats;
  - `DevToolsService` runs the dev commands.
- **Player:** `PlayerStateService` (move state, meters), `MovementAuthority` (speed, displacement and noclip checks),
  `LifeStateService` (the only writer of health and life state), `InteractionService` (prompts and channels),
  `FlashlightService` and `LoadoutService`.
- **Vents:** `VentNetworkService`: grates, crawling and occupancy.
- **Monster:** `MonsterAIService`. A 10 Hz brain drives the states (Dormant, Patrol, InvestigateNoise, WallChase,
  VentChase, Stunned, AquaticStalk and Scripted). Its inputs are `Perception` and `Hearing`. It moves with
  `Locomotion` and catches with `JumpscareHandler`.
- **Mechanics:** `DoorService`, `BearTrapService`, `ChemicalProjectileService`, `LockerHidingService`,
  `FloodedPoolService` and `ParachuteService`.
- **Levels:** `ObjectiveService` (the floor objectives, from `ObjectiveConfig`) and the per-floor controllers,
  `Level0_BasementController` … `Level5_RoofController`.
- **Match:**
  - `MatchAndDataService`: saved data, Deploy, the outcome evaluator and rewards;
  - `LobbyService`, `PerkShopService` and `CheckpointAirlockService`;
  - `DownedReviveService` and `SpectatorService`;
  - `MatchResetService` and `TelemetryService`.

**Match phases:** `Lobby → Countdown → Deploying → InRun → RunEnded → Results → Resetting → Lobby`. Floors change at
the stairwell airlocks. A wipe or an escape resolves the run, and Results returns everyone to the lobby.

### 3.4 The client (`StarterPlayerScripts`)

`ClientMain` waits for the game, sets up `Net`, then requires the controllers in order and calls `Init`, then `Start`.
It announces each run with `OnRunStarted` / `OnRunEnded`. The controllers:

- **Core:**
  - `AudioController` plays the buses and cues;
  - `LightingController` is the only writer of the level lights and `Lighting`. With it are `Film` (each level's
    grade and its Roblox render) and `Volumetrics` (moonlight, light shafts and dust);
  - `CosmeticWorldController` builds the client-only dressing;
  - `SettingsController`, `InputController` and `CursorController`;
  - `RenderBudgetController` (the light budget and its frame-rate guard) and `GraphicsController` (the Graphics tier,
    §5);
  - `SequenceController` plays the `OneShot` timelines;
  - `DevToolsController` draws the dev overlays.
- **FirstPerson:** `FirstPersonController`: the camera stack, body and hands, view bob, panic effects and the dual-cone
  flashlight.
- **Characters:** `CharacterAnimationController`, `CreatureController` and `RemoteFlashlightRenderer`.
- **HUD:** the HUD on `UIKit` (procedural UI, no images): status bars, prompts, captions, the objective tracker, the
  squad panel, first-time hints, touch controls and the `SettingsMenu`.
- **Gameplay:** vents, jumpscares, bear traps, doors, flasks, level scenes, lockers, swimming and the struggle.
- **Match:** the lobby, onboarding, airlocks, downed, spectating, the parachute and the escape summary.

### 3.5 Networking, physics and contracts

- **Remotes.** `Shared/Net/RemoteRegistry` lists every remote: name, kind, direction, validator, rate limit, allowed
  phases and life states. The server creates `ReplicatedStorage.Remotes`. Every client message is validated, then
  rate-limited, then phase-gated. There is no `InvokeClient`.
- **Collision groups.** `CollisionGroups` holds the matrix as data, and `CollisionService` applies it:
  - players never collide with players, the Creature or ragdolls;
  - in a vent, a player collides only through one `VentCollider` ball;
  - the Creature walks through `MonsterPassthrough` dressing;
  - zones, water and cosmetics are `NoCollide`.

  The web's player and Creature collision follow the same groups, which the export writes on every part.
- **Queries.** Line of sight runs from the Creature's eye to the target's eye point, in the `Default` group with every
  character excluded. Flasks are stepped server raycasts along the shared `Ballistics` parabola.
- **Ownership.** Players own their characters, checked by `MovementAuthority`. The server owns locked players, the
  Creature, doors, grates, traps and ragdolls. Flasks have no physical part.
- **Data.** `MatchAndDataService` saves through DataStore, with a session lock and a save queue. Studio without API
  access and Lune use the in-memory backend. Settings are saved in the same blob, sanitized by `SettingsSchema`.

The 71db8fd version of this file has the original phase-by-phase design of every service, in more detail.

## 4. The web runtime (`web/src/`)

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
  - `quality.js`: the quality tiers, auto-detected (§5).
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

## 5. Graphics tiers

The Graphics setting goes from **Max** (the default: everything on, for a strong PC) down to **Potato** (for school
Chromebooks): Max, High, Medium, Low and Potato. A tier only strips visual overhead from the player's own view. It
never changes collision, queries, sizes, positions, collision groups, materials, physics, navigation, the Creature or
anything the server owns. `Shared/Config/GraphicsConfig.luau` holds the table.

| | Max | High | Medium | Low | Potato |
| --- | --- | --- | --- | --- | --- |
| Fixtures lit (nearest) | 64 | 48 | 30 | 16 | 10 |
| Fixture shadows (nearest) | 56 | 40 | 20 | none | none |
| Unshadowed fixtures go dark past | no limit | 220 studs | 150 | 100 | 70 |
| Torch shadows | yes | yes | yes | yes | no |
| Torch haze cone | yes | yes | yes | no | no |
| Teammates' torch cones | 3 | 3 | 2 | 1 | 1 |
| Moonlight spills (shadowed) | 14 (6) | 10 (4) | 6 (0) | 4 (0) | 2 (0) |
| Light shafts / dust emitters | 20 / 12 | 14 / 8 | 6 / 3 | 0 / 0 | 0 / 0 |
| Particle rate | ×1 | ×1 | ×0.7 | ×0.4 | off |
| Depth of field | yes | yes | no | no | no |
| Bloom / sun rays | yes / yes | yes / yes | yes / no | no / no | no / no |
| Grade | full | full | full | full | flat: exposure and the contrast fit only, no area tint |
| Haze closes at | the level's own | 300 studs | 220 | 160 | 120 |
| MaterialVariants | yes | yes | yes | plain | plain |
| Wear paint | yes | yes | yes | hidden | hidden |
| `Detail` parts shown | 1–3 | 1–3 | 1–2 | 1 | none |
| Animation LOD (full / frozen past) | 120 / 300 studs | 80 / 220 | 55 / 140 | 35 / 90 | 35 / 90 |

On Roblox:

- **Settings.** `SettingsSchema` saves the tier as an index (a `Choice` setting). `SettingsMenu` shows it as a row of
  segments, with a one-line description of the picked tier under it.
- **`GraphicsController`** applies the tier on join, on change and to everything that arrives later
  (`DescendantAdded`):
  - The tier's budget is `RenderBudgetController`'s ceiling. Its frame-rate guard may step the budget down under it,
    never above it.
  - The post goes to `LightingController.SetGraphics`. `Film` drops bloom and sun rays, flattens Potato's grade (the
    exposure, the contrast fit and the fills stay, so the frame keeps the web's brightness) and thickens the level's
    haze until it closes at the tier's distance, darkened so far geometry sinks into the dark.
  - It writes the surfaces itself. Textured parts show their plain material in their palette colour. `Wear` and
    `Damage` SurfaceGuis and `Overlay_` textures are hidden, and every sign, label and wayfinding mark is kept. Parts
    whose `Detail` attribute is above the tier's limit get `LocalTransparencyModifier` 1. World particle emitters are
    rate-scaled.
- **Light LOD.** The fill-radius LOD only switches off client lights. The server's rules read `BaseBrightness` and the
  torches' state, never these lights.
- **The spec.** `tests/Specs/GraphicsTiers.spec.luau` checks that every planned write is on `GraphicsConfig.Writes`.
  It puts a real level through every tier and back to Max, and asserts that every part's `CanCollide`, `CanQuery`,
  `Size`, `CFrame` and `CollisionGroup` never change and that Max restores the exact build.

On the web, `engine/quality.js` still has its own Low / Medium / High tiers, auto-detected, with dynamic resolution.
It will move to the same five tiers.

## 6. The map pipeline

```text
src/ (Luau world builder) ──rojo build──▶ place ──Lune export──▶ world-raw.json ──bake──▶ world.json + world.bin
                                                                     textures ──┘                      │
                                     site/index.html ◀── copy ── dist/Rovloc.html ◀── single-file build ┘ ──▶ Vercel
```

| Step | Command (in `web/`) | What happens |
| --- | --- | --- |
| Export | `npm run export` | `tools/export-world.luau` builds `default.project.json` with Rojo and loads it in Lune through `tools/lune/harness.luau`. It then does what a run's server does at the fixed seed 20251029 on Standard: builds the school, the run's plan with props and fixtures, a prop on every other candidate anchor a run may pick, the cosmetic dressing, the Creature rig and the moonlight windows. It writes `build/cache/world-raw.json`, and RunDirector's plans for a spread of seeds to `build/cache/run-plans.json` (the data test replays them on the web's port). |
| Textures | `npm run textures` | `tools/textures.py` packs the generator's maps (`tools/textures/`) into WebP. |
| Bake | `npm run bake` | `tools/bake.mjs` tessellates every part and bakes vertex light (BVH shadows, AO, sky, probes). It packs the result into `build/world.json` (metadata) and `build/world.bin` (quantised streams). See `web/DATA.md`. |
| Build | `npm run build` | `tools/build.mjs` bundles `src/` with esbuild and inlines the gzipped world and textures into `dist/Rovloc.html`. |
| Deploy | — | Copy `dist/Rovloc.html` to `site/index.html` and push; Vercel serves `site/` at rovloc.vercel.app. |

`npm run data` runs the export, textures and bake in order. Every step is deterministic. Two runs differ only in the
bake's timing (`stats.bakeSeconds`).

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
- **Utilities:** `Util/Log`, `Util/MathUtil` and `Util/Rng`.

Everything here is `--!strict` Luau. Requires go by instance path through the Rojo tree, for example
`require(ReplicatedStorage.Shared.World.RunDirector)`. The builders create Roblox instances: live in the Roblox game, and inside the
Lune harness for the web export. The harness provides the engine services the builders touch (and a stand-in for the
engine's `Random`, which only the runtime's specs use: the world never draws from it).

### One world on both platforms

The web's export and a live Roblox build are the same world, part for part, for every floor and the lobby:

- **One generator.** Every random number the world builder, the layouts (TunnelPlanner) and RunDirector draw comes from
  `Shared/Util/Rng`: a pure-Luau xoshiro128** seeded by SplitMix32, exact 32-bit integer maths on `bit32`, so Lune and
  every Roblox server and client draw the same numbers. `Rng.seeded(seed, key)` is a stream per decision (the seed xor
  `MathUtil.hash(key)`); `NextInteger` is unbiased (it redraws past the last whole range) and `Rng.shuffle` is
  Fisher-Yates. Never the engine's `Random`, `math.random` or `math.noise` there: `tests/Specs/WorldDeterminism.spec`
  lints the sources of `Shared/World`, `Shared/Vents`, `Shared/Config` and `Util/Rng` for them (and for clocks, GUIDs
  and spatial queries, which the harness answers with nothing). `tests/Specs/Rng.spec` and `web/tools/data-test.mjs`
  pin the same golden values, from an independent C reference.
- **One world seed.** Everything built is seeded from the builder's `WORLD_SEED` and its own key, never from a run's
  seed: the school and its statics, each run's fixtures (`BuildFixtures`), each planned prop (`BuildProp`: its stream
  and its variant are its anchor's) and every client's cosmetic dressing and skyline (`BuildCosmetic`). A run varies
  only its plan (which anchors hold props, which grates lock, the route), and a plan never changes what is built, only
  what shows: a stairwell door is built with its collapse and a grate in both its looks (galvanized and rusted shut,
  the same boxes), and the run shows the ones its plan picks (`DoorBuilder.setJammed`, `VentGrateBuilder.setLocked`;
  the web does the same per run). So the export, built once, is what every run builds.
- **One maths.** Colours and points the builders derive are computed in Luau's doubles and stored once:
  `MathUtil.lerpColor`, `lerpVector2`, `lerpVector3`, `lerpCFrame`, `toHSV` and `fromHSV`, never the engine's `Lerp`
  or HSV methods. Each engine rounds those in float32 its own way (Lune's `Color3:Lerp` is `a * (1 - t) + b * t`, so a
  channel lerped to its own value comes back off it and a .5 tie can round to the other byte), and one ulp flips a part
  colour on the 8-bit grid or a point across a seam. The same lint refuses them in world code.
- **One plan.** The web's `worldData.js` ports RunDirector rule for rule on the same generator (`Rng` in
  `web/src/game/util.js`, `Math.imul` and `>>> 0` for `bit32`), so a run seed picks the same objective spots, guard
  traps, bear traps, flasks, batteries, locked grates and exits on both platforms; the data test replays the export's
  RunDirector plans for a spread of seeds pick for pick. The export builds a prop on every candidate anchor, exactly
  as a run plans it there (`RunDirector.plannedProp` / `objectiveProp`: the anchor's variant, a reagent's kind), and a
  run shows the ones on its picks.
- **No hash order.** Every loop whose order reaches a draw, a name or a tie walks sorted keys (the walk graphs, the
  exterior's tower holes, TunnelPlanner's crawl weights), sorts break every tie, and float comparisons in sorts use
  quantised keys, so no Luau build's table layout or sort algorithm can change the map.

What still differs is the runtime's own randomness (pacing, beats, spawns: the engine's `Random` on Roblox, mulberry32
on the web), the text fitting of signs (each renderer's) and Lune's engine model where it is not Roblox's: property
writes rounded to 1/65536 and `CFrame:Inverse` over the whole matrix, where Roblox stores float32 and transposes a
rotation (positions agree to 2e-4 studs, and no build decision turns on that), and a stored `Model.WorldPivot` where
Roblox pivots a model with a `PrimaryPart` on that part. Part colours do not differ: Roblox stores `BasePart.Color` in
8 bits a channel, so the builders write every part colour on that grid, once (`MathUtil.color8`; never read back and
reworked), from colour maths in Luau's doubles (One maths, above), and the export refuses a colour off it.

On Roblox, the same builder runs live: `WorldService` builds the school and the lobby at boot, `BuildFixtures` builds
each run's fixtures into `Workspace.Runtime`, and each client builds its cosmetic dressing. The textures reach Roblox
through the `textures.yml` workflow (`tools/textures/upload.py`), which uploads the maps and writes
`Config/TextureAssets.luau` and `src/MaterialService/RovlocTextures.model.json`.

## 7. Gates

**The Luau side:** `tools/verify.sh` runs from the repo root (see `tools/README.md`). CI runs it on every push. It
checks, in order:

1. the project files: every `$path` exists, the engine pins are intact, and `test.project.json` is
   `default.project.json` plus `tests/`;
2. `rojo build` of the game and the test place, and `rojo sourcemap`;
3. `luau-lsp analyze` in strict mode over `src` and `tests`;
4. `selene` and `stylua --check`;
5. `capscan.py`: no writes to restricted engine properties;
6. `lune run tools/lune/check.luau all`:
   - the layouts;
   - the world build;
   - every spec in `tests/Specs` (the shared world, the Roblox services and controllers, the Graphics tiers);
   - the server lifecycle: the real `ServerMain` booted with every service, the match loop, runs on both
     difficulties, every level, the dev commands and shutdown.

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

**Publishing:** CI uploads `Rovloc.rbxl` with every run. `publish.yml` publishes the place through Open Cloud, with
no Studio needed (`docs/PLACE_SETUP.md`). The website deploys from `site/`.
