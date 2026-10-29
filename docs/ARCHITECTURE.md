# Rovloc — Architecture

A 1–4 player co-op first-person survival horror game set in a pitch-black, post-apocalyptic five-level school.
Everything (geometry, the Creature rig, animation, audio and UI) is generated in code. The game ships with
no `.rbxm` models, no `rbxassetid://` animations and no `rbxassetid://` sounds.

API surface is checked against the Roblox API dump **v0.744** (reflection DB 741 inside Rojo 7.7.1).
Scripts never touch deprecated members: for example `LoadCharacter` → `LoadCharacterAsync`, `GetHumanoidDescriptionFromUserId`
→ `…Async`, `Sound.MaxDistance` → `RollOffMaxDistance`, and `wait`/`spawn`/`delay`/`tick` → `task.*` / `os.clock()`
(selene enforces the last four, see `rovloc.yml`, and `luau-lsp analyze` rejects the rest). The only deprecated property
pinned anywhere is `Lighting.Technology = Future`, and only in the project file. No scriptable property forces Future
lighting, so its modern partner `LightingStyle = Realistic` is pinned next to it.

---

## 1. Ground rules

| Rule | How it's enforced |
| --- | --- |
| `--!strict` everywhere | Every game and test `.luau` file starts with `--!strict` (Lune tooling under `tools/lune/` is exempt, since it runs outside Roblox). `.luaurc` sets strict mode. CI runs `luau-lsp analyze` against the Rojo sourcemap, plus `tools/capscan.py`, which rejects writes to plugin-only or read-only engine properties. |
| Works in Rojo **and** Studio | `src/` mirrors the Explorer one-to-one. Requires go by instance path (`require(ReplicatedStorage.Shared.Config.GameConfig)`), never string aliases. Runtime-created instances are only reached through `Shared/Instances.luau`, so strict typing never guesses. |
| One ordered bootstrap per side | `ServerMain` and `ClientMain` require an explicit module list and wrap every lifecycle call in `xpcall`. They're the **only** files that grow in later phases. Every shared contract (enums, types, attributes, tags, remotes, config) is complete in Phase 1. Later phases plug in through registries owned by earlier ones: `ProceduralWorldBuilder.RegisterProp/RegisterFixture/RegisterStatic/RegisterRig/RegisterCosmeticAnchor` (filled at load by the P2 `Props` catalog and `CreatureRigBuilder`), `LevelDirector.RegisterLevel`, `MovementAuthority.RegisterValidator`, and the `MonsterAIService` hooks (`RegisterLockerInspector`, `RegisterPoolGrabber`). |
| Downward-only dependencies | Layers: `Shared → Core → Player → World systems (Vents, Monster) → Levels & Mechanics → Match`. A module only requires layers below it. Upward traffic goes through typed `Signal`s or registered hooks (e.g. `MonsterAIService.RegisterLockerInspector`), so there are no require cycles and no `any` leaks. |
| Server authority | Clients send *intents* through validated, rate-limited remotes. The server owns noise, damage, life state, meters, interactions, items, progression and data. Noise tiers come from **observed** server-side speed as well as the claimed move state. |
| No gameplay on `Touched` | The server polls triggers, traps, checkpoints, water and scare volumes at 10 Hz (`ZoneService`). It tests points against volumes with plain math (`volume.CFrame:PointToObjectSpace(root.Position)` against `Size/2`), so the test works in every collision group, `NoCollide` included. Spatial queries would skip those parts. `Touched` may drive client-only cosmetics. |
| Events are remotes, state is attributes | Durable state replicates as Attributes. Moments (neck snap, gate slam, door motions, lightning, jumpscare) travel on one reliable `OneShot` remote: `{seq, kind, subject, startAt, args}`. `startAt = GetServerTimeNow() + lead`, so every client starts the same `Timeline` on the same frame, and late joiners fast-forward. |
| Resettable runs | Each module has a `ServiceTrove` (process lifetime) and a `RunTrove` (one run). `RunLifecycleService` is the only writer of `MatchPhase` and the run attributes. **Deploying** calls `BeginRun(ctx)` on every service, in forward order, once the difficulty and participants are known. **Resetting** calls `EndRun` on every service in reverse order, then clears `Workspace.Runtime`. Before Phase 8, a Studio dev-run harness in `DevToolsService` drives the lifecycle, so every phase is playable on its own. |
| Procedural only | Geometry uses Parts, WedgeParts, built-in `Enum.Material`s, Attachments and Constraints, with no runtime CSG. Audio layers verified `rbxasset://sounds/` engine files through `SoundEffect` DSP chains, all built on clients. Animation writes `Motor6D.Transform` (or `AnimationConstraint.Transform`) in `PreSimulation` on clients. |

---

## 2. Repository file tree

Phase tags show which phase writes each file: `[P1]` … `[P8]`.

```text
Rovloc/
├── default.project.json                    Rojo project + engine pins (validated with Rojo 7.7.1)
├── syncback.project.json                   Scripts-only project for `rojo syncback` (keeps pins out of syncback)
├── test.project.json                       [P1] default tree + tests/ mapped to ServerScriptService.Tests
├── rokit.toml                              rojo 7.7.1 · selene 0.31.0 · stylua 2.6.0 · luau-lsp 1.70.1 · lune 0.11.1
├── selene.toml · rovloc.yml · roblox.yml   Lint config, project rules (Rule 5), pinned Roblox std (offline-safe)
├── stylua.toml · .luaurc · .gitignore
├── .vscode/                                extensions.json · settings.json (luau-lsp sourcemap)
├── .github/workflows/
│   ├── ci.yml                              [P1] paths, pins, selene, stylua, luau-lsp analyze, Lune checks, .rbxl artifact
│   └── publish.yml                         [P1] Open Cloud place publishing (no Studio needed)
├── tools/
│   ├── verify-files.sh                     [P1] Gate a subset of files (luau-lsp + selene + stylua)
│   └── lune/                               [P1] harness.luau (engine shims) · check.luau (layouts / world / specs / lifecycle)
├── docs/
│   ├── ARCHITECTURE.md                     This file
│   └── PLACE_SETUP.md                      Settings Rojo cannot set + bootstrap procedure
├── tests/
│   ├── Runner.server.luau                  [P1] Studio entry for the specs (test.project.json places only)
│   ├── SpecRunner.luau                     [P1] Dependency-free runner shared by Studio and Lune
│   └── Specs/                              [P1→P8] One spec per pure module: CollisionMatrix, RunDirector (determinism +
│                                           solvability over 500 seeds), ZoneGraph, BinaryHeap, VentPathfinder,
│                                           Hearing, PacingDirector, Doors, Airlock, Levels (scenes + the Level 0-2
│                                           controllers on a fake clock), Lockers (hiding, the breath check, the rip
│                                           hand-over), Level3 (gym stalk, sweeps, beats), Pool (water rules,
│                                           swimming, oxygen, the grab, struggle and every release, the swim
│                                           client's maths), Level4 (pool alert, floodlights, beats), DataMigration
└── src/
    ├── ReplicatedFirst/
    │   └── LoadingCurtain.client.luau      [P1] Engine-only black curtain until WorldReady + local ack; 30s BootError fallback
    │
    ├── ReplicatedStorage/
    │   └── Shared/
    │       ├── Config/
    │       │   ├── GameConfig.luau         [P1] Squad 1–4, bleedout 35, revive 4, straggler 20, pry 5/1.5, unscrew 3.5,
    │       │   │                                trap dmg 35, respawn 50%, stun 6, packs 4, OneShot lead/maxLate
    │       │   ├── DifficultyConfig.luau   [P1] Standard / Nightmare: speeds, trap count, battery count, pacing knobs
    │       │   ├── NoiseConfig.luau        [P1] 8 crouch/slow-vent · 10 unscrew · 30 walk · 65 sprint · 75 freestyle ·
    │       │   │                                90 vent scurry · 130 kick/debris/trap + treading, gasp, falling object (24,
    │       │   │                                Low), splash meter
    │       │   ├── CameraConfig.luau       [P1] State offsets, eye points per MoveState, FOV, bob/sway/shake, panic curve
    │       │   ├── CreatureConfig.luau     [P1] Per-state speeds, senses, EMF 45, PathAgent, hitbox per PoseMode, eye offsets
    │       │   ├── PerkConfig.luau         [P1] Rusty Screwdriver 1.2s · Lithium Cell +50% · Adrenaline Syringe (2 modes)
    │       │   ├── WorldConfig.luau        [P1] Floor heights, 3.5×3.5 bore, doors ≥6×10, walls ≥1 stud, avatar normalization
    │       │   ├── InputConfig.luau        [P1] Action → keyboard / gamepad / touch binding + tap/hold/mash kind
    │       │   └── SettingsSchema.luau     [P1] Sensitivity, base FOV, bus volumes, motion & flash scale, captions
    │       ├── Types.luau                  [P1] Service/Controller lifecycle, RunContext, NoiseEvent, DataSchema, hook interfaces
    │       ├── Enums.luau                  [P1] MoveState, CameraState, LifeState, ControlLock, MonsterState (+Scripted), PoseMode,
    │       │                                    MatchPhase, LevelId, LevelPhase, NoiseKind, OneShotKind, JumpscareKind,
    │       │                                    ItemId, GrateState, DoorState, PromptKind, StatKey, PerkId, Difficulty, RunOutcome
    │       ├── Tags.luau                   [P1] CollectionService tag registry (§6)
    │       ├── Attributes.luau             [P1] Attribute keys + typed get/set helpers (§6)
    │       ├── CollisionGroups.luau        [P1] Group names + matrix as data (§4)
    │       ├── Instances.luau              [P1] Typed resolvers for runtime instances (Remotes, Creature, Runtime, levels)
    │       ├── Strings.luau                [P1] Keyed UI strings (localization-ready)
    │       ├── Net/
    │       │   ├── init.luau               [P1] Server creates ReplicatedStorage.Remotes; validation → token bucket → phase gate
    │       │   ├── RemoteRegistry.luau     [P1] Every remote: name, kind, direction, validator, rate, allowed phases (§6)
    │       │   └── Validators.luau         [P1] typeof, finite numbers, unit vectors, enum membership, string bounds
    │       ├── Audio/
    │       │   ├── SoundSynthesizer.luau   [P1] Client-side voice builder: layered Sounds + DSP chains + envelopes
    │       │   ├── SoundLibrary.luau       [P1] Verified rbxasset://sounds/ engine-file catalog
    │       │   ├── SynthPresets.luau       [P1] Screech, heartbeat, vent scrape, trap snap, bone crunch, drip, glass crunch,
    │       │   │                                drone, EMF static, chem hiss, gate slam, light burst, thunder, rain, splash,
    │       │   │                                gasp, breathing, footsteps per material, fire door swing / latch and door
    │       │   │                                creak [P6], the Creature sniffing at locker slits, a locker torn open, a
    │       │   │                                held breath let out, locker slams, ball bounces, shower drips, a gasp at
    │       │   │                                the surface, climbing out, bubbles, the underwater thrash, pool drips,
    │       │   │                                sloshes and falling tiles, the floodlight breaker and strike-up [P7]
    │       │   │                                (+ caption text)
    │       │   ├── VoicePool.luau          [P1] Pooled voices, per-bus caps, priority stealing, distance pre-cull
    │       │   └── AudioBuses.luau         [P1] SoundGroup tree + environment DSP (Vent, Underwater, Outdoor, Lobby)
    │       ├── Animation/
    │       │   └── ProceduralAnimator/
    │       │       ├── init.luau           [P3] One PreSimulation driver for every rig, layered blending, springs, LOD
    │       │       ├── JointMap.luau       [P3] Motor6D / AnimationConstraint discovery for R15 + Creature rigs
    │       │       ├── IK.luau             [P3] Two-bone IK (hands on items, foot planting)
    │       │       └── Profiles/
    │       │           ├── PlayerR15.luau  [P3] Walk, sprint, crouch, vent crawl, downed crawl, tread, freestyle, trapped, parachute
    │       │           └── Creature.luau   [P4] Stalk, sprint, stun flail, 180° neck snap, spider crawl, vent retreat,
    │       │                                    vent stun flail, lunge, swim, locker rip, door smash
    │       ├── Sequence/
    │       │   ├── Timeline.luau           [P3] Server-time track runner (camera, light, sound, creature, door); fast-forward
    │       │   ├── DoorMotion.luau         [P6] A fixture door's motion on server time (swing / slide / smash, eases),
    │       │   │                                shared by DoorService and DoorController; the door OneShot's args
    │       │   ├── LockerMotion.luau       [P7] A locker's moments on server time, shared by LockerHidingService and
    │       │   │                                LockerController: enter / exit schedules, door poses (DoorMotion
    │       │   │                                messages), the lungs meter, the check's warning / peek / grace numbers
    │       │   └── Scenes.luau             [P6] The level scenes as data: the Floor 1 classroom scare's beat times (the
    │       │                                    server schedules from them) and every scene Timeline (the clients play
    │       │                                    them), the basement beats, the subject camera maths (stumble, face drag),
    │       │                                    the Floor 3 locker-room beats, the Floor 4 floodlight strike-up [P7]
    │       ├── World/
    │       │   └── ProceduralWorldBuilder/
    │       │       ├── init.luau           [P1] BuildAuthoritative / BuildCosmetic / ClearRuntime + RegisterProp / RegisterRig
    │       │       ├── Palette.luau        [P1] Materials + colour grading (concrete, tile, galvanized steel, rust, ...)
    │       │       ├── Geometry.luau       [P1] Split-slab walls with door / vent openings, trims, pillars, stairs (no CSG)
    │       │       ├── LayoutSchema.luau   [P1] Blueprint types, shared geometry helpers, validator (tiling, doors, ducts, solvability)
    │       │       ├── ZoneGraph.luau      [P1] Rooms + portals (doors, grates, duct segments): solvability, hearing, EMF adjacency
    │       │       ├── LightingRig.luau    [P1] Baseline Atmosphere, ColorCorrection, Bloom, Terrain clouds
    │       │       ├── LightingMood.luau   Which fixtures burn, how bright, flicker groups; each wing's colour cast + grade
    │       │       ├── FixtureGlow.luau    Glow surfaces of a fixture (Neon tubes, lenses, self-lit exit letters) and the
    │       │       │                       curve the client dims them along with their light
    │       │       ├── SurfaceArt.luau     SurfaceGui paint kit: checkers, seams, hazard stripes, stains, grime, print
    │       │       ├── Finishes.luau       Interior finishes: glossy / checker / vinyl floors, drop ceilings with missing
    │       │       │                       tiles, two-tone wainscots (band, chair rail, baseboard), floor hazard plates
    │       │       ├── LobbyBuilder.luau   [P1] Boiler-room safe zone + wrecked bus staging area
    │       │       ├── SchoolShellBuilder.luau [P1] Levels 0–5: slabs, walls, rooms, corridors, boarded windows, Zone volumes
    │       │       ├── StairwellBuilder.luau [P1] Stair towers between levels (respawn points are the entry-airlock PlayerSpawn anchors)
    │       │       ├── VentShaftBuilder.luau [P1] 3.5×3.5 ducts per level, VentNodes with explicit Links, AdjacentZones, Submerged
    │       │       ├── SkylineBuilder.luau [P1] Ruined city backdrop (cosmetic, client-built)
    │       │       ├── Layouts/
    │       │       │   ├── Lobby.luau              [P1] Blueprints: rooms, doors, vent routes (Lockable / CriticalPath),
    │       │       │   ├── Level0_Basement.luau    [P1]   spawn anchors, zones, trigger volumes, patrol waypoints,
    │       │       │   ├── Level1_Hallways.luau    [P1]   light fixtures, dressing seeds
    │       │       │   ├── Level2_ScienceHall.luau [P1]
    │       │       │   ├── Level3_Gymnasium.luau   [P1]
    │       │       │   ├── Level4_FloodedPool.luau [P1]
    │       │       │   └── Level5_Roof.luau        [P1]
    │       │       ├── Props/
    │       │       │   ├── init.luau                   [P2] Catalog: requires every prop builder and registers its kinds
    │       │       │   ├── PropKit.luau                [P2] Builder kinds + contexts, leaf poses (hinge/slide), disabled prompts
    │       │       │   ├── BearTrapBuilder.luau        [P2] Rusted jaws, spring, chain, stake (anchored, server-tweened)
    │       │       │   ├── VentGrateBuilder.luau       [P2] Grate, 4 screws, hinge, prompts, ExitAnchor (room side)
    │       │       │   ├── ChemicalFlaskBuilder.luau   [P2] World pickup + held/projectile visual (same builder)
    │       │       │   ├── LockerBuilder.luau          [P2] Hideable locker, door, horizontal slits, peek anchor
    │       │       │   ├── PoolWaterBuilder.luau       [P2] Part-based murky water volumes + collapsed walkways
    │       │       │   ├── ParachuteBuilder.luau       [P2] 4 packs, crate, canopy
    │       │       │   ├── DoorBuilder.luau            [P2] Airlock fire doors, hallway gate, roof stairwell door
    │       │       │   ├── PickupBuilder.luau          [P2] Flashlight batteries
    │       │       │   ├── FloodlightSwitchBuilder.luau [P2] Emergency pool floodlight switch + lights
    │       │       │   ├── SetDressingBuilder.luau     [P2] Server: lab counters, smashed lockers, debris triggers, drip pipes ·
    │       │       │   │                                    Client: posed corpses, loose clutter, trims
    │       │       │   ├── SignageBuilder.luau         Room plates, wayfinding, posters, notes, scrawls, WET FLOOR A-frames
    │       │       │   └── ServicePipeBuilder.luau     Pipework and conduit along the plant rooms' ceilings
    │       │       └── CreatureRigBuilder.luau [P2] 8.5-stud rig, Motor6Ds, hair, claws, grin, pupils, CreatureHitbox
    │       └── Util/
    │           ├── Signal.luau             [P1] Typed, immediate-fire signal
    │           ├── Trove.luau              [P1] Connection / instance / thread cleanup
    │           ├── Spring.luau             [P1]
    │           ├── MathUtil.luau           [P1]
    │           ├── SpatialQuery.luau       [P1] RaycastParams / OverlapParams factories, EyePoint helpers
    │           ├── Log.luau                [P1] Levels, tags, rate limiting
    │           ├── BinaryHeap.luau         [P4]
    │           ├── Ballistics.luau         [P6] Flask flight shared by server + clients: parabola, release point +
    │           │                                pull-back, stepped casts, aim-arc trace, pool surface crossings
    │           └── WaterRules.luau         [P7] The pool's rules shared by FloodedPoolService and the swimming client:
    │                                            water volumes + in / out hysteresis, float height, heads under, the
    │                                            oxygen rate, struggle presses (sequence, 12/s cap, decay, break-free)
    │
    ├── ServerScriptService/
    │   ├── ServerMain.server.luau          [P1] Ordered bootstrap, xpcall isolation, place-settings audit → BootError
    │   └── Services/
    │       ├── Core/
    │       │   ├── CollisionService.luau   [P1] Groups + matrix; only writer of CollisionGroup (per-character mode stack)
    │       │   ├── CharacterService.luau   [P1] Normalized R15 builds, spawning, Lock/Unlock (Anchor / ServerOwned), Died signal
    │       │   ├── RunLifecycleService.luau [P1] Only writer of MatchPhase + run attributes; BeginRun / EndRun fan-out
    │       │   ├── WorldService.luau       [P1] Clears edit-time Workspace, builds, WorldReady + per-client ack, per-run spawns
    │       │   ├── LevelDirector.luau      [P1] CurrentLevel / LevelPhase, Enter/Advance, activation signals, level registry
    │       │   ├── ZoneService.luau        [P1] 10 Hz point-in-volume enter/exit for every character (replaces Touched)
    │       │   ├── AudioService.luau       [P1] Cue routing to clients (server never creates synth voices)
    │       │   ├── RunStatsService.luau    [P1] Per-player run counters (StatKey) + run timing
    │       │   ├── DevToolsService.luau    [P1] Studio / allowlist / owner: dev-run harness, level skip, noise + plan overlays
    │       │   └── NoiseAndDirectorService/
    │       │       ├── init.luau           [P1] Noise bus (Emit / NoiseEmitted), splash meter, director API
    │       │       ├── LocomotionNoiseSampler.luau [P1] 10 Hz: max(tier(MoveState), tier(observed speed))
    │       │       ├── RunDirector.luau    [P1] Seeded traps / grate locks / flask & battery spawns + ZoneGraph solvability
    │       │       └── PacingDirector.luau [P5] BuildUp / Peak / Relax, catch cooldown, leash, out-of-sight reposition, grace
    │       ├── Player/
    │       │   ├── PlayerStateService.luau [P3] MoveState authority + override stack, meters, LookRelay broadcast
    │       │   ├── MovementAuthority.luau  [P3] Speed / displacement / noclip checks + RegisterValidator → rubber-band + strikes
    │       │   ├── LifeStateService.luau   [P3] Only writer of Health + LifeState: damage, Downed, 35s bleedout, Execute, Eliminate
    │       │   ├── InteractionService.luau [P3] Server-timed prompt holds, per-player durations + audience, channel progress
    │       │   ├── FlashlightService.luau  [P3] Battery authority, pickups, FlashlightOn
    │       │   └── LoadoutService.luau     [P3] Perk effects: screwdriver timing, lithium capacity, syringe (stamina + self-revive)
    │       ├── Vents/
    │       │   └── VentNetworkService/
    │       │       ├── init.luau           [P4] Grates (unscrew / kick / locked), enter / exit, occupancy, rail validator
    │       │       ├── GrateRules.luau     [P4] Pure grate state / prompt acceptance rules
    │       │       └── CrawlRules.luau     [P4] Pure entry / exit geometry predicates (+ the swimmers' entry from
    │       │                                        the water at the pool's grates [P7])
    │       │           (VentGraph + VentPathfinder are shared: ReplicatedStorage/Shared/Vents, used by the
    │       │            server, the crawling client and the Creature)
    │       ├── Monster/
    │       │   └── MonsterAIService/
    │       │       ├── init.luau           [P5] State machine host, 10 Hz brain, AcquireScripted(), hook registry,
    │       │       │                            SetSpeedScale [P7] (level tuning: the Level 3 gym), CatchGrabbed [P7]
    │       │       │                            (a held swimmer out of air: the Underwater jumpscare)
    │       │       ├── Brain.luau          [P5] Shared state types, pure transition table, catch rules, level knowledge
    │       │       ├── CreatureBody.luau   [P5] Ownership reassert, hitbox sizing per PoseMode, Hidden, collision modes
    │       │       ├── Perception.luau     [P5] Eye-to-EyePoint LOS (never limbs), view cones
    │       │       ├── Hearing.luau        [P5] Same-level filter, wall occlusion, vent path distance over VentGraph
    │       │       ├── Locomotion.luau     [P5] PathfindingService on floors, A* rail in vents, swim movement
    │       │       ├── JumpscareHandler.luau [P5] Kinds: Hallway, Vent, Locker, Underwater → LifeStateService
    │       │       └── States/
    │       │           ├── Dormant.luau            [P5]
    │       │           ├── Patrol.luau             [P5]
    │       │           ├── InvestigateNoise.luau   [P5]
    │       │           ├── WallChase.luau          [P5]
    │       │           ├── VentChase.luau          [P5]
    │       │           ├── Stunned.luau            [P5]
    │       │           ├── AquaticStalk.luau       [P5]
    │       │           └── Scripted.luau           [P5] Exclusive control for cutscenes (Floor 1, roof)
    │       ├── Mechanics/
    │       │   ├── BearTrapService.luau    [P6] Snap, 35 damage, Anchor lock, solo pry 5s (look-down), co-op rescue 1.5s
    │       │   ├── DoorService.luau        [P6] Only writer of DoorState + fixture leaf poses: fire doors, hallway gate,
    │       │   │                                classroom + roof doors; Heartbeat-stepped leaves, never crushing, cues
    │       │   ├── ChemicalProjectileService.luau [P6] Flask pickup / hold / throw, stepped server raycasts, stun cloud
    │       │   │                                (radius + clear line, or VentGraph hops in ducts), Shattered signal
    │       │   ├── LockerHidingService.luau [P7] Only writer of OccupantUserId / DoorOpen + locker door poses: Hide
    │       │   │                                prompt, Anchor lock + Hiding override, stepped doors, exit to a clear
    │       │   │                                spot; the locker inspector: server-judged hold-breath check, gasp (cue +
    │       │   │                                noise), the LockerRip hand-over to JumpscareHandler
    │       │   └── FloodedPoolService.luau [P7] Who swims (10 Hz, Swim mode), oxygen rates, the Swim validator, the
    │       │                                    climb exemption, splashes; the PoolGrabber: ServerOwned drag, Grabbed,
    │       │                                    the struggle (StrugglePress), flask / floodlight / let-go releases, the
    │       │                                    drowning catch
    │       ├── Levels/
    │       │   ├── init.luau                [P6] The Levels service: registers the controllers with LevelDirector, runs
    │       │   │                                their run resets and one Heartbeat driver
    │       │   ├── LevelKit.luau            [P6] Shared: server eyes / feet, LOS, "can anyone see it", OneShots, a
    │       │   │                                server-time beat schedule
    │       │   ├── Level0_BasementController.luau [P6] Seeded ambience beats 25-50 s apart, 25-45 studs out of sight:
    │       │   │                                pipe bang, boiler surge (bulbs stutter), ceiling drag, child, falling object
    │       │   ├── Level1_HallwaysController.luau [P6] The classroom scare: staged Creature, glass / room / near / bypass
    │       │   │                                triggers, NeckSnap, light burst (bulbs dead for the run), vanish, gate slam,
    │       │   │                                hidden relocation, release + alert; once per run
    │       │   ├── Level2_ScienceHallController.luau [P6] Flask restock (two in play, out of sight, one per 45 s), hint
    │       │   ├── Level3_GymnasiumController.luau [P7] The fast stalk on the court (SetSpeedScale), locker-room
    │       │   │                                sweeps and court prowls (Alert), seeded locker-room beats out of sight
    │       │   ├── Level4_FloodedPoolController.luau [P7] Pool sessions call the Creature to the water (Alert), the
    │       │   │                                emergency floodlight switch (prompt, On, lever, lamps lit for the run,
    │       │   │                                release / blind), seeded water beats out of sight
    │       │   └── Level5_RoofController.luau [P8] Door smash, final sprint, parachute leap, lightning reveal + vanish
    │       └── Match/
    │           ├── CheckpointAirlockService.luau [P6] Stairwell airlocks: 10 Hz checkpoint volume, 20s straggler timer,
    │           │                                 seal via DoorService, left-behind spectators, Advance, 50% HP respawn
    │           ├── DownedReviveService.luau [P8] Revive anchor + prompt on Downed participants (4 s InteractionService
    │           │                                 channel, Alive teammates only), cancels, Revive at 50%, notices
    │           ├── SpectatorService.luau   [P8] Only writer of SpectateReason / SpectateTargetUserId: eliminated,
    │           │                                 late joiners and over-capacity players, target ring, SpectateCycle
    │           └── MatchAndDataService/
    │               ├── init.luau           [P8] Match policy over RunLifecycleService + single RunOutcomeEvaluator
    │               ├── StoreBackend.luau   [P8] DataStore backend + Ephemeral Studio fallback + guest mode
    │               ├── PlayerDataStore.luau [P8] Session lock, serialized save queue, idempotent rewards, migrations
    │               ├── LobbyService.luau   [P8] Ready-up, difficulty vote, countdown, squad cap
    │               ├── PerkShopService.luau [P8] Credit spend → PerkStock, loadout equip
    │               ├── MatchResetService.luau [P8] Results → Resetting → Lobby; Play Again votes
    │               └── TelemetryService.luau [P8] AnalyticsService funnels, economy, death causes
    │
    └── StarterPlayer/
        └── StarterPlayerScripts/
            ├── ClientMain.client.luau      [P1] Waits for game.Loaded; ordered bootstrap; disables Reset Character
            ├── RbxCharacterSounds.client.luau [P1] Replaces the engine default and strips legacy character sounds (P3 footsteps own audio)
            └── Controllers/
                ├── Core/
                │   ├── AudioController.luau        [P1] Buses, cue playback with server-time offset, zone reverb, nearby emitters
                │   ├── LightingController.luau     [P1] Only writer of level lights: active level ∧ budget, Timeline overrides,
                │   │                                    fixture glow (tubes dim, flicker and die with their light), area grade;
                │   │                                    BaseBrightness re-read live (the server kills burst bulbs for the run)
                │   ├── CosmeticWorldController.luau [P1] Skyline + non-interactive dressing from RunSeed
                │   ├── DevToolsController.luau     [P1] Noise rings, ZoneGraph / VentGraph overlays, Creature billboard
                │   ├── InputController.luau        [P3] ContextActionService context stack (Menu > Cutscene > … > OnFoot)
                │   ├── CursorController.luau       [P3] Ref-counted cursor-free requests (Modal button + MouseBehavior)
                │   ├── SettingsController.luau     [P3]
                │   ├── RenderBudgetController.luau [P3] Light / shadow / emitter / DOF / animation LOD budgets
                │   └── SequenceController.luau     [P3] Receives OneShot, runs Timelines in sync
                ├── FirstPerson/
                │   └── FirstPersonController/
                │       ├── init.luau               [P3] Owns the Scriptable camera; LockFirstPerson in match; one RenderStep
                │       ├── CameraRig.luau          [P3] Look input (mouse / touch / gamepad), yaw / pitch, root yaw
                │       ├── CameraStack.luau        [P3] Priority overrides: Cutscene > Jumpscare > Spectating > Struggle > Trapped > base
                │       ├── CameraStates.luau       [P3] Standing, Crouching, VentCrawling, DownedCrawling, LockerPeeking,
                │       │                                UnderwaterSwimming, ParachuteLookback
                │       ├── BodyRenderer.luau       [P3] Per-frame LocalTransparencyModifier for any subject model
                │       ├── HandRig.luau            [P3] Real-body IK hands: flashlight, flask, pry, ripcord, slit grip
                │       ├── MovementController.luau [P3] Predicted LocalMoveState, crouch / sprint / stamina intents
                │       ├── ViewBob.luau            [P3] Sine bob, breathing sway, shake (applied to output only)
                │       ├── PanicVFX.luau           [P3] ColorCorrection, DepthOfField, FOV warp, vignette
                │       └── Flashlight.luau         [P3] Dual-cone SpotLights, battery HUD, EMF flicker + static
                ├── Characters/
                │   ├── CharacterAnimationController.luau [P3] Animates every player rig (local + teammates)
                │   ├── RemoteFlashlightRenderer.luau     [P3] Teammates' cones from LookRelay + FlashlightOn
                │   └── CreatureController.luau           [P4] Creature animation, pupils in vents, vent scrape + breathing audio
                ├── HUD/
                │   ├── init.luau                   [P3]
                │   ├── UIKit.luau                  [P3] Procedural UI primitives (no images; ResetOnSpawn=false)
                │   ├── StatusBars.luau             [P3] Battery, stamina, oxygen, bleedout (extrapolated meters)
                │   ├── PromptRenderer.luau         [P3] Custom prompt style, local per-perk durations, audience hiding, rings
                │   ├── MobileControls.luau         [P3] Touch buttons rendered from InputConfig per context
                │   ├── Captions.luau               [P3]
                │   └── SettingsMenu.luau           [P3]
                ├── Gameplay/
                │   ├── VentController.luau         [P4] Entry / exit transitions, rail crawl input, duct audio bus
                │   ├── JumpscareController.luau    [P5] Face lock, lunge, screech, flash
                │   ├── BearTrapController.luau     [P6] Leg-lock camera tilt, shaking-hands pry
                │   ├── DoorController.luau         [P6] Renders every door motion each PreRender from its OneShot, impacts
                │   ├── ChemicalThrowController.luau [P6] Held flasks (own + teammates'), HandRig "Flask" pose, wind-up,
                │   │                                   aim arc, predicted throw reconciled to Launch, shatter VFX + cloud
                │   ├── LevelScenesController.luau  [P6] Registers the Scenes timelines + their tracks: the subject's stumble
                │   │                                   and face drag (Cutscene override), panic, the hush, moving sounds,
                │   │                                   bulb surges
                │   ├── LockerController.luau       [P7] Locker doors for everyone; the hider's camera in / out and behind
                │   │                                   the slits ("Trapped" override), Locker context, lungs meter, the
                │   │                                   hold-breath prompt (device-aware), heartbeat via the panic floor
                │   ├── SwimController.luau         [P7] Part-water swimming: buoyancy + drag + stroke (VectorForce +
                │   │                                   LinearVelocity), dive / surface, climbing out, the underwater view
                │   │                                   (tint, blur, murk, waterline), bubbles, strokes, muffled audio
                │   └── StruggleController.luau     [P7] The grab on the victim's client: Struggle context, presses under
                │                                       the server's rule, mash UI, the pulled-down shaking camera, darkness
                └── Match/
                    ├── AirlockController.luau      [P6] Straggler countdown banner (inside / outside / sealing)
                    ├── LobbyController.luau        [P8] Ready-up, difficulty vote, perk shop UI
                    ├── DownedController.luau       [P8] Downed HUD (bleedout ring, revive status, syringe button,
                    │                                   vignette, heartbeat, desaturation), teammates' downed markers
                    ├── SpectatorController.luau    [P8] Through the target's eyes ("Spectating" override, LookBroadcast
                    │                                   look, their torch from inside), cuts, Q / E cycling, HUD
                    ├── ParachuteController.luau    [P8] Leap, ripcord, lookback camera
                    └── EscapeSummaryController.luau [P8] ESCAPED / WIPED summary + Play Again
```

---

## 3. Roblox Studio Explorer hierarchy

### 3a. Edit time (what Rojo writes, or what you create by hand in Studio)

```text
game
├── Workspace                StreamingEnabled=false · SignalBehavior=Deferred · RejectCharacterDeletions
│                            · ValidateEnabledProximityPrompt · PlayerCharacterDestroyBehavior · ReplicateInstanceDestroySetting
├── Lighting                 Technology=Future · LightingStyle=Realistic · ClockTime 0.5 · Brightness 0 · Ambient black
├── Players                  CharacterAutoLoads=false (CharacterService spawns every character)
├── ReplicatedFirst
│   └── LoadingCurtain       LocalScript
├── ReplicatedStorage
│   └── Shared               Folder
│       ├── Config           Folder of ModuleScripts
│       ├── Types · Enums · Tags · Attributes · CollisionGroups · Instances · Strings     ModuleScripts
│       ├── Net              ModuleScript (+ RemoteRegistry, Validators)
│       ├── Audio            Folder: SoundSynthesizer · SoundLibrary · SynthPresets · VoicePool · AudioBuses
│       ├── Animation        Folder: ProceduralAnimator (ModuleScript + JointMap · IK · Profiles)
│       ├── Sequence         Folder: Timeline
│       ├── World            Folder: ProceduralWorldBuilder (ModuleScript + builders · Layouts · Props)
│       └── Util             Folder of ModuleScripts
├── ServerScriptService
│   ├── ServerMain           Script
│   └── Services             Folder: Core · Player · Vents · Monster · Mechanics · Levels · Match
├── SoundService             AmbientReverb=NoReverb · AcousticSimulationEnabled=false · DopplerScale=0
├── StarterGui               (empty: every ScreenGui is built in code with ResetOnSpawn=false)
└── StarterPlayer            GameSettingsAvatar=R15 · AvatarJointUpgrade=Disabled · LuaCharacterController=Legacy
    │                        · CameraMode=Classic, zoom 0.5 (fallback only; FirstPersonController drives a Scriptable
    │                          camera everywhere and sets Player.CameraMode=LockFirstPerson for the match)
    └── StarterPlayerScripts
        ├── ClientMain           LocalScript
        ├── RbxCharacterSounds   LocalScript (replaces the default)
        └── Controllers          Folder: Core · FirstPerson · Characters · HUD · Gameplay · Match
```

Rojo file mapping, for Studio-only users: `X.server.luau` → **Script**, `X.client.luau` → **LocalScript**,
`X.luau` → **ModuleScript**, and a folder holding `init.luau` → **ModuleScript** whose children are the other files.
The simplest Studio-only route is to open the `Rovloc.rbxl` built by CI (or by `rojo build`). See `docs/PLACE_SETUP.md`.

There is deliberately no `StarterCharacterScripts`. `CharacterService` builds every character in this fixed order:

1. Fetch the HumanoidDescription with `GetHumanoidDescriptionFromUserIdAsync` inside `pcall`. Studio test players
   have negative UserIds, so they fall back to `HumanoidDescription.new()`.
2. Normalize it: scales 1, body type and proportion 0, no layered clothing, no head accessories.
3. Build it with `CreateHumanoidModelFromDescriptionAsync(desc, Enum.HumanoidRigType.R15)`.
4. Strip any `Animate` / `Health` script, then set `BreakJointsOnDeath=false` and `RequiresNeck=false`.
5. Pivot it to a `SpawnAnchor`.
6. Set `player.Character = model`, then parent it to Workspace.

The rig is therefore R15 whatever the universe avatar setting is, there is no passive regen, and `CharacterService`
destroys the old model on every swap (deploy, airlock respawn, return to lobby).

### 3b. Run time (built by code; never saved in the place file)

```text
Workspace
├── Lobby                    Model  ReadyPads · DifficultyTerminal · PerkLocker · SpawnAnchors
├── School                   Model
│   ├── Level0_Basement      Model  Shell · Lights · Zones · Vents · Anchors · Triggers · Waypoints · Props (P2 statics:
│   │                               open doors, lab counters, smashed lockers, drip pipes, debris, pool wreckage,
│   │                               signs and posters, plant-room pipework)
│   ├── Level1_Hallways      Model  (same layout per level; Vents holds that level's ducts + VentNodes)
│   ├── Level2_ScienceHall   Model
│   ├── Level3_Gymnasium     Model
│   ├── Level4_FloodedPool   Model
│   ├── Level5_Roof          Model
│   └── Stairwells           Model  Stairwell_0_1 … Stairwell_4_5 (stairs + emergency lights; checkpoint volumes are the
│                                   layouts' Checkpoint triggers in each exit airlock; fire doors come from P2 DoorBuilder)
├── Cosmetic                 Folder (client-local) Skyline, trims, loose clutter, posed corpses
├── Creature                 Model  [tag Creature] Humanoid · HumanoidRootPart · CreatureHitbox · Motor6D rig
└── Runtime                  Folder  Level0 … Level5: per-run traps, flasks, batteries, and the P2 fixtures rebuilt every
                                     run (vent grates with the plan's locks, fire doors, hallway gate, roof door, lockers,
                                     parachute crate, floodlight switch), clouds, executed ragdolls (wiped on reset)

Lighting                     Atmosphere · ColorCorrection · Bloom (+ client-local Panic CC / DOF / lightning pulses)
Workspace.Terrain            Clouds (storm deck)
ReplicatedStorage
├── Shared                   (Rojo)
└── Remotes                  Folder  RemoteEvent / UnreliableRemoteEvent / RemoteFunction, created by Net
SoundService (client-local)  Master SoundGroup ▸ Ambience · World · Monster · Player · Body · UI (Vent, Underwater and the
                             other room acoustics are environment DSP presets swapped onto World / Player / Monster)
```

---

## 4. Physics: collision groups, queries, ownership

### 4a. Collision matrix

`CollisionService` registers the groups with `PhysicsService:RegisterCollisionGroup` (8 of 32) and applies this
matrix (✓ = collide). The user's required groups (Players, Monster, CorpseProps, Projectiles) are joined by three
helpers that make the vent and doorway guarantees hold.

| | Default | Players | Monster | CorpseProps | Projectiles | MonsterPassthrough | VentCollider | NoCollide |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| **Default** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| **Players** | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |
| **Monster** | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ |
| **CorpseProps** | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |
| **Projectiles** | ✓ | ✗ | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ |
| **MonsterPassthrough** | ✓ | ✓ | ✗ | ✓ | ✓ | ✓ | ✗ | ✗ |
| **VentCollider** | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| **NoCollide** | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |

- **Players ✗ Players, ✗ Monster, ✗ CorpseProps.** Teammates, the Creature and ragdolls can never wedge or fling a player.
- **One writer.** Only `CollisionService` sets `CollisionGroup`. Each character has a mode stack
  (`Normal < Vent < Locked`), and the highest mode wins. So a jumpscare that ends inside a duct falls back to `Vent`,
  never to `Players`.
- **Vent crawl.** In `Vent` mode every character part is `NoCollide`, and a 2.6-stud `VentCollider` ball welded to
  the root is the only collider. The owning client drives the root along the VentNode rail (`AlignPosition` +
  `AlignOrientation`, Humanoid in `Physics` state). The ball can't snag inside the 3.5×3.5 bore, and the duct walls
  still contain it if the constraint ever fails. Exit teleports to the grate's `ExitAnchor` after an overlap check.
- **Creature.** Limbs are permanently `NoCollide`, because the Humanoid rewrites `CanCollide` on head and torso parts but
  can't override collision groups. On floors only the root (`Monster`) collides. `CreatureHitbox`
  (`CanCollide=false`, `CanQuery=true`, `Monster`) is resized per PoseMode. It is about 3×8×2 for the biped and fits
  the duct when quadruped. Door trims, lockers, desks and debris are `MonsterPassthrough` with
  `PathfindingModifier { PassThrough = true }`. Airlock doors and the hallway gate stay `Default`, so they really block.
  Doorways are at least 6×10 studs clear, and the Creature ducks procedurally.
- **NoCollide** also covers characters in `Locked` mode (locker, drag, jumpscare, cutscene), water and zone volumes,
  and every cosmetic part. Nothing ever queries those parts physically: zones and water are tested with math (§4b).
- **Creature Humanoid.** `RequiresNeck=false`, `BreakJointsOnDeath=false`, `AutomaticScalingEnabled=false`, an
  explicit `HipHeight`, and no `Animator`.

### 4b. Query rules

1. Gameplay never relies on `Touched`. `ZoneService` tests each character root against every tagged volume with
   point-in-box math at 10 Hz. Clients run the same math to find their own `ZoneId`, which drives reverb and EMF
   adjacency.
2. Line of sight runs from the Creature's eye (root + CreatureConfig offset per PoseMode) to the target's **EyePoint**
   (root + CameraConfig offset per MoveState). It uses `RaycastParams.CollisionGroup = "Default"` with every
   character and the Creature excluded, so lockers, desks and debris block sight. The server never sees client-side
   poses (`Motor6D.Transform` is NotReplicated), so it never tests against limbs.
3. Flasks are stepped server raycasts with `CollisionGroup="Projectiles"` (every character excluded), in segments of
   at most 1/60 s of flight along the shared `Ballistics` parabola. They hit walls, props and `CreatureHitbox`.
   Each step also tests the `PoolWater` surface planes with math, so a flask landing in the pool shatters at the surface.
   A shatter near a grabbed player releases the grab (P7, through `ChemicalProjectileService.Shattered`). Short tosses
   (×0.45 speed) are allowed while vent crawling. A shatter is in a duct when its point lies inside the square bore of
   the level's VentGraph (a grate's opening counts up to its wall's room face).
   The stun is decided by the cloud (`FlaskCloudRadius`, `FlaskCloudSeconds`, at most once per cloud, checked at the
   shatter and at 10 Hz so a Creature walking in is stunned too): its hitbox within the radius **with a clear
   Default-group line** from the cloud centre (no stunning through walls), or, for an in-duct shatter with the Creature in
   a vent, a VentGraph hop distance of `FlaskVentHopRadius` (2) or fewer. `MonsterAIService.Stun(StunSeconds, point)`
   makes it retreat away from the point (in ducts along `VentPathfinder.retreatPath`).

### 4c. Ownership and control locks

| Assembly | Owner | Mechanism |
| --- | --- | --- |
| Player character | Client | Validated by `MovementAuthority`: speed, displacement and noclip raycasts. `VentNetworkService` registers a rail-distance validator for the vent. |
| Player under a lock | Server | `CharacterService.Lock(player, reason, mode)`, ref-counted, which pushes collision mode `Locked`. **Anchor**: trap, locker, jumpscare, cutscene. **ServerOwned**: underwater drag. The last `Unlock` unanchors first, then calls `SetNetworkOwner(player)`. |
| Creature | Server | `CreatureBody.Reassert()` after every anchor or rig change, with a Studio audit that the owner is `nil` |
| Doors, gates, grates, locker doors, trap jaws | Server | Anchored and stepped by the server on Heartbeat (collision follows them). No free hinges. Fixture doors announce each motion on `OneShot` and `DoorController` renders the same server-time motion every frame; a swinging or sliding leaf stops short of any player in its path and finishes once the way is clear (`DoorService`). |
| Executed-player ragdolls | Server | `CorpseProps` + `SetNetworkOwner(nil)`. Level corpses are posed, anchored and client-cosmetic. |
| Flasks | Nobody | No physical server part. `ProjectileEvent` → clients simulate the same parabola visually. |

---

## 5. Service architecture

```lua
-- Types.luau (shape)
export type Service = {
	Name: string,
	Init: (self: Service) -> (),                         -- wire up, no yielding (ServiceTrove)
	Start: (self: Service) -> (),                        -- begin loops
	BeginRun: (self: Service, ctx: RunContext) -> (),    -- forward order, fresh RunTrove
	EndRun: (self: Service) -> (),                       -- reverse order, RunTrove:Clean(), release locks
	OnPlayerRemoving: (self: Service, player: Player) -> (), -- before data release, reverse order
}
```

**Match phases.** `Lobby → Countdown → Deploying → InRun → RunEnded → Results → Resetting → Lobby`.
`RunLifecycleService` [P1] owns the transitions and the `BeginRun` / `EndRun` fan-out. `MatchAndDataService` [P8]
owns the policy (votes, countdown, rewards). Until P8 exists, the Studio dev-run harness deploys straight into
`InRun`.

- Countdown aborts if the ready count drops.
- Deploying snapshots the participants, calls `BeginRun(ctx)` and moves the squad to the basement.
- Outcomes are per player (`Escaped / Dead / Disconnected`). One `RunOutcomeEvaluator` (coalesced with `task.defer`)
  decides wipe or escape.
- Wipe = no Alive participant and no Downed participant with a syringe charge left.

**Death rules.** `LifeStateService` is the only writer of `Health` and `LifeState`. `CharacterService` just fires
`Died`. Lethal damage goes to `Down`, which becomes `Execute` if the player has already been downed once. Oxygen
reaching 0 goes through the same `Down` path. Execute and `Died` are idempotent.

**Leaving mid-run.** `OnPlayerRemoving` releases locks, traps and channels, clears vent and locker occupancy, drops
the Creature's target to its last known position, re-evaluates the airlock and the run outcome, and retargets spectators.
On rejoin, the data load waits for any `Release` still in flight for that UserId.

**Stairwell airlocks (P6).** `CheckpointAirlockService` watches the current level's exit vestibule (the stairwell's
`fromRoom`, holding the level's `Checkpoint` volume) at 10 Hz. The first playing participant inside starts the 20 s
straggler timer (`StragglerDeadline` on the exit fire door, which `AirlockController` counts down). It seals when every
Alive participant is inside (a Downed one counts only while inside) or at the deadline (an empty vestibule resets to
Idle instead). The fire door locks shut through `DoorService`, and once it is shut the floor changes: participants still
outside are left behind as spectators, `LevelDirector.MarkCleared` + `Advance`, `FloorsCleared` for the survivors,
`FloorCleared(level, survivors)`, then every Dead / Spectating participant respawns at 50% health at the next floor's
entry, and `Sealed(from, to)`. Sealed doors stay locked for the run. The roof has no exit airlock. P8 awards the floor
credits from these signals.

**Floor debris.** `NoiseAndDirectorService` owns debris noise: entering a `FloorDebris` volume during a run emits the
130-stud `FloorDebris` noise and a `GlassCrunch` cue (with a per-player cooldown). The Floor 1 `ScareStep` stays with the
P6 Level 1 controller.

**Level scenes (P6).** The `Levels` service registers the Level 0 / 1 / 2 controllers with `LevelDirector`. Scenes are
data (`Shared/Sequence/Scenes`): the server times its authoritative beats from the same constants the clients' timelines
use, and announces each scene with one `OneShot` `Timeline` (`LevelScenesController` registers them and their tracks).
- *Floor 1 classroom scare, once per run.* On activation the Creature is taken with
  `MonsterAIService.AcquireScripted("L1_ClassroomScare")` and, on the next step and only while nobody can see the spot
  it leaves or the corner, staged at `L1_ScarePose_Classroom108` in `PoseMode Hunched` (a scripted hold in Hunched poses
  the Dormant corner crouch). The first playing participant on the glass (`L1_Trigger_GlassStep`), in Classroom 108,
  within 14 studs with a clear line, in the corridor past the glass, past the gate or in its bypass vent sets it off:
  the `FloorDebris` noise at their feet, the scene timeline (crunch, the subject's stumble and their view dragged onto
  the Creature, NeckSnap with the body turned so the stare lands on them, a hush, the burst sounds), `LightBurst` on
  both glow fixtures (their `BaseBrightness` set to 0 for the rest of the run, restored at `EndRun`, so late joiners see
  them dead), `CreatureVanish` + `SetHidden(true)` as the bulbs die, the `HallwayGate` locked shut through `DoorService`
  (`GateSlam`; `Locked` refuses every gameplay open, so the bypass vent is the only way on), the hidden Creature moved
  east of the gate out of everyone's sight, then `Release("Patrol")` + `Alert(glass, "High")` 6-9 s after the slam.
  A Creature that could not be taken still leaves the crunch, the stumble and the gate.
- *Level 0 beats.* A seeded director plays a positional scare every 25-50 s (never the same twice in a row, never within
  8 s of a `TrapSnap`) 25-45 studs from a random player, at a point nobody can see.
- *Level 2 flasks.* At least two untaken flasks stay in play: a new one appears at a free `FlaskCandidate` more than
  30 studs from everyone and out of sight, at most one every 45 s; the first approach to a flask shows a one-time hint.
- *Level 3 gym (P7).* While the Creature hunts on the court (Patrol, InvestigateNoise, WallChase inside `L3_Gymnasium`)
  its pace is scaled by 1.3 through `MonsterAIService.SetSpeedScale` (1 elsewhere and once the level is left). Low
  `Alert`s steer it, never at a player: a *sweep* to a seeded locker in a room a participant has spent 12 s in (it
  peeks into the nearest lockers), a *prowl* back to the court after 30 s patrolling elsewhere with nobody on it.
  Locker-room beats (a dripping shower, a locker banging with a quiet `FallingObject` noise, a ball bouncing to rest
  far off) play every 22-44 s out of sight. Neither steering nor beats happen during a breath check or 6 s after one.

**Lockers and the hold-breath check (P7).** `LockerHidingService` owns every `HideableLocker`. Hiding (the 0.25 s Hide
prompt; Alive, on foot, no lock, the locker free, not being chased) takes `CharacterService.Lock(player, "Locker",
"Anchor")`, the `Hiding` override (the Creature never sees a Hiding player) and switches the torch off; the door swings
open, the body is moved to the `HideAnchor`, the door shuts (`LockerMotion` schedules; doors are server-stepped and
announced as DoorMotion OneShots so clients render them smoothly). Leaving (`ExitHide` or the prompt key) goes to the
first clear spot in front. The Creature's `InvestigateNoise` calls the registered inspector in its own thread at each
door: an empty locker is `Empty` after a short look; an occupied one runs the check on the server's clock. The occupant
is warned (`PrivateCue BreathCheck`) 0.9 s before a seeded 3.5-6 s peek; `BreathInput` holds drain the 7 s lungs and
releases recover them at 0.6/s. Running out while it is at the door, letting go with under 30% left, or not holding
inside the window for more than 0.5 s is a loud gasp (`Gasp` cue + noise) and `Caught`; holding through is
`HiddenSafe` (warning + longest peek < the longest hold, so a player who holds when warned always makes it). On
`Caught`, `InvestigateNoise` tries the Locker catch; once `JumpscareHandler` holds the victim, the door is torn off
(`LockerRip` OneShot), the locker's own lock and override are released and the locker stays smashed for the run; the
victim is put down outside when the catch ends. A catch that does not take leaves them hidden (the gasp brings it back).

**The flooded pool (P7).** Water is part volumes, never Terrain. `FloodedPoolService` decides at 10 Hz who is in the
water with `WaterRules` (a root inside a `PoolWater` volume's footprint, up to 0.5 studs over the surface to get in and
1.8 to stay in; the half-flooded duct's water belongs to the crawl) and sets the `Swim` mode (`Treading` / `Freestyle`
/ `Underwater` from the intent). Leaving upward needs something to stand on under the root (a climb out, exempted from
the fly check); rising out over nothing is put back by the `Swim` validator. Oxygen drains at 7/s while the head is
under (the dive held, or the eye below the surface), 9/s while grabbed, holds during a jumpscare, and recovers at 30/s
otherwise; 0 is a Down ("Drowned"). The client (`SwimController`) swims its own body (gravity cancelled, a
force-limited LinearVelocity toward the stroke) at the server's WalkSpeeds and climbs out at the coping, ladders and
bridge fragments. The Creature's `AquaticStalk` calls the PoolGrabber (`FloodedPoolService.TryGrab`) once a swimmer's
splashing crossed the threshold: `Lock(victim, "Drag", "ServerOwned")`, the `Grabbed` override, a server drag rig
pulling them down and back in front of it over 1.2 s, oxygen topped up to 4.5 s of air, `PrivateCue Struggle`, the
squad warned. 22 `StrugglePress`es (sequence-numbered, 12/s at most, slipping back after 0.6 s idle) break free and the
Creature recoils; a flask shattering within the cloud radius of the victim, the Level 4 emergency floodlights or the
Creature letting go free them too, always with 2.5 s of air to reach the surface. At the drowning floor the drain stops
and `MonsterAIService.CatchGrabbed` runs the Underwater jumpscare (Down / Execute by its outcome rule); if it cannot,
the air runs out (Down). Swimmers enter the pool's grates from the water (`CrawlRules`). The Level 4 controller calls
the Creature to the water a few seconds into each pool session (`Alert`, once, 40 s cooldown), owns the emergency
floodlight switch (one use per run: the nine lamps lit for the run, a held swimmer released, otherwise a Creature in the
natatorium stunned) and plays water beats out of sight.

**Downed, revive and spectating (P8).** A Downed participant's root carries a `ReviveAnchor` attachment (tagged
`Interactable`, `OwnerUserId` = the victim, lowered to where the crawling body lies) with one `Revive` prompt that
`DownedReviveService` serves through `InteractionService`: audience `Others`, a 4 s server-timed hold
(`GameConfig.ReviveHoldSeconds`), one reviver at a time, only an Alive participant with no control lock, never on a
victim being caught (`Jumpscare` / `Drag` / `Cutscene`; a victim still in a bear trap can be revived). A 10 Hz pass
re-checks every running hold and cancels it the moment it fails (InteractionService already covers range and the
reviver's own life state). Completion is `LifeStateService.Revive(victim, 0.5)` + `RunStats Revives`; leaving Downed
(revived, executed, bled out, the run ending, leaving) removes the anchor with that reason. Downs and deaths of Downed
teammates are announced to the squad, and coming back up (teammate or syringe) gasps. On the client,
`DownedController` claims the HUD's downed block and draws the bleedout ring, the revive status, the syringe button
(the `Syringe` action sends `UseSyringe` SelfRevive while Downed, Stamina while Alive), the blood vignette and
heartbeat (panic floor) and the draining colour, plus subtle through-wall markers on downed teammates; Revive prompts
are hidden on clients that are not Alive. `SpectatorService` is the only writer of `SpectateReason` /
`SpectateTargetUserId`: participants out of play (`Dead`, or `Spectating` after an airlock left them behind) are
`Eliminated` until a checkpoint brings them back; players present at `BeginRun` but not deployed are `OverCapacity`
(squad full) or `LateJoin`, and so are players joining during `Deploying` / `InRun`. Non-participants are made
`Spectating`, hold no body for the rest of the run (despawned now or the moment one appears; a spawn in flight is never
cancelled) and join the next run from the lobby: the airlocks only bring participants back. Targets are playing
participants around the run's ring (next after me; a lost target hands over to the next one; `SpectateCycle` ±1
wraps; nobody playing → none). `SpectatorController` puts the camera in the target's eyes through the `Spectating`
override (their head + their `LookBroadcast` look, smoothed), hides their head (`SetBodySubject`), lights their torch
from inside (`RemoteFlashlightRenderer.SetFocus`), cuts through black on switches and holds on the body for 2.5 s after
a death.

**Dev runs.** Any state-changing dev command during a run sets `ReplicatedStorage.DevRun = true`. `MatchAndDataService`
(P8) must not award credits, escapes or BestTime for a run with `DevRun`.

**Self-reset.** `ClientMain` disables the Reset Character button. A Humanoid death that bypasses `LifeStateService`
is treated as an elimination, never a respawn.

---

## 6. Contracts

### 6a. CollectionService tags

`VentShaft` · `VentGrate` · `VentNode` · `BearTrap` · `ChemicalItem` · `HideableLocker` · `ParachutePack` ·
`BatteryPickup` · `FloorDebris` · `DripPipe` · `Corpse` · `PoolWater` · `FloodlightSwitch` · `AirlockDoor` ·
`ScriptedDoor` · `CheckpointVolume` · `ScareTrigger` · `PatrolWaypoint` · `SpawnAnchor` · `MonsterPassthrough` ·
`Zone` · `LevelLight` · `AmbientEmitter` · `Creature` · `Interactable`

### 6b. Attributes (durable state)

| Owner | Attributes |
| --- | --- |
| `Player` | `LifeState` · `MoveState` (server-confirmed; the client predicts) · `ControlLock` · `Battery`/`Stamina`/`Oxygen` + `…Rate` + `…At` (extrapolated meters) · `FlashlightOn` · `HeldItem` + `HeldItemVariant` · `SyringeCharges` · `Loadout` · `DownedCount` · `BleedoutEndsAt` · `Ready` · `DataLoaded` · `Credits` · `RunOutcome` · `SpectateReason` + `SpectateTargetUserId` |
| `Creature` | `MonsterState` · `StateSince` · `PoseMode` · `TargetUserId` · `InVent` · `VentSegmentId` · `Hidden` · `GrabbedUserId` |
| `ReplicatedStorage` | `MatchPhase` · `RunId` · `RunSeed` · `Difficulty` · `CurrentLevel` · `LevelPhase` · `RunStartedAt` · `RunEndedAt` · `WorldReady` · `DataMode` · `BootError` |
| `VentGrate` | `GrateId` · `GrateState` (Closed / Unscrewing / Open / Kicked / Locked) · `Lockable` · `CriticalPath` · `NodeId` |
| `VentNode` / `VentShaft` | `NodeId` · `Links` · `LevelId` · `GrateId` / `SegmentId` · `AdjacentZones` · `Submerged` |
| Props | `BearTrap{Armed, TrappedUserId}` · `HideableLocker{OccupantUserId, DoorOpen}` · `AirlockDoor{DoorState, FromLevel, ToLevel, StragglerDeadline}` · `ScriptedDoor{DoorId, DoorState}` · `ParachutePack{TakenByUserId}` · `FloodlightSwitch{On}` · `ChemicalItem{HeldByUserId}` · `BatteryPickup{Charge}` · `Zone{ZoneId, LevelId, ReverbPreset}` · `Interactable{ChannelActor, ChannelStartedAt, ChannelDuration}` |

`RunDirector` only ever locks `Lockable` grates, never `CriticalPath` ones (the Floor 1 bypass vent, the gym
connectors, the pool ducts). After randomizing, it runs a breadth-first search over `ZoneGraph` from each level's
entry airlock to its exit. It re-rolls deterministically from the seed, up to 64 times. If a level is still
unsolvable after that, every `Lockable` grate on that level is unlocked. A locked grate blocks players and the
Creature alike.

### 6c. Remotes (`RemoteRegistry`, all validated and rate-limited; no `InvokeClient`)

| Direction | Reliable | Unreliable |
| --- | --- | --- |
| Client → Server | `MoveIntent` (level-encoded {crouch, sprint, dive, seq}) · `FlashlightToggle` · `ItemThrow` · `BreathInput` · `StrugglePress` (≤12/s) · `UseSyringe` · `ExitHide` · `ParachutePull` · `LobbyAction` · `PlayAgain` · `ClientWorldReady` · `SettingsSave` · `DevCommand` · `PerkPurchase` (RemoteFunction) | `LookRelay` (20 Hz, quantized yaw/pitch). Vent crawling needs no input remote: the owning client drives the rail and the server validates positions. |
| Server → Client | `OneShot` (all) · `PrivateCue` (one player: minigame windows, victim cues) · `AudioCue` (with a cue id) · `AudioStop` · `ProjectileEvent` · `RunSummary` · `Notify` | `LookBroadcast` (batched teammate views: flashlights, head pitch, spectator camera) |

### 6d. Data schema (v1)

```lua
{ v = 1, Escapes = 0, SurvivalCredits = 0,
  BestTime = { Standard = nil :: number?, Nightmare = nil :: number? },
  PerkStock = {} :: { [PerkId]: number },   -- bought with credits, one consumed per run when equipped
  Settings = {} :: SettingsBlob, LastRunId = "" }
```

Session lock `{jobId, lockedAt}` with stale-lock steal, a serialized save queue, an idempotent `Release` shared by
`PlayerRemoving` and `BindToClose` (25 s deadline), and run rewards guarded by `LastRunId`. In Studio without API
access, the Ephemeral backend takes over and `DataMode="Ephemeral"` shows a HUD banner. After repeated failures
in production, the player plays as a guest with saving off. Nobody is kicked and nobody blocks ready-up.

---

## 7. Eight-phase build order

| Phase | Scope |
| --- | --- |
| **1** | Shared config + **every** contract (enums, types, attributes, tags, remotes, strings, input, settings) · Net layer · collision groups · CharacterService · `SoundSynthesizer` + voice pool + buses · `NoiseAndDirectorService` (bus, sampler, seeded RunDirector + solvability) · `ProceduralWorldBuilder` part 1 (lobby, 5-level shell, stairwells, per-level vents + VentNode graph, ZoneGraph, lighting) · LevelDirector · ZoneService · RunStats · DevTools · LoadingCurtain · client Audio / Lighting / Cosmetic controllers · test runner + CI |
| **2** | `ProceduralWorldBuilder` part 2: bear traps, grates, flasks, lockers, pool water, parachutes, doors, pickups, floodlight, set dressing + the Creature rig and hitbox |
| **3** | `FirstPersonController` (Scriptable camera, CameraStack, body + IK hands, states, view-bob, panic VFX, dual-cone flashlight + EMF) · HUD · input / cursor / settings · `ProceduralAnimator` core + player profile · Timeline + SequenceController · PlayerState / MovementAuthority / LifeState / Interaction / Flashlight / Loadout services |
| **4** | `VentNetworkService` (unscrew vs kick, locked grates, crawl transitions, A* + retreat) · `ProceduralAnimator` Creature profile · CreatureController |
| **5** | `MonsterAIService`: all 7 states + Scripted, Perception, Hearing, Locomotion, PacingDirector, jumpscare handler |
| **6** | Bear traps (solo pry + co-op rescue) · fixture doors (`DoorService`) + stairwell airlock checkpoints · Floor 1 classroom encounter · Floor 2 chemical stun physics · Level 0–2 controllers |
| **7** | Floor 3 lockers + hold breath · Floor 4 swimming, oxygen, drag struggle, floodlight · Level 3–4 controllers |
| **8** | `MatchAndDataService`: lobby, difficulty, perk shop, DataStore, floor credits (from the airlock signals), revive, spectator, roof finale (Level 5), reset loop, telemetry |

**Dependency adjustments to the roadmap** (so no phase needs a stub from a later one):

1. The `ProceduralAnimator` core and the player profile move to **P3**. The body renderer and hands need them.
   The Creature profile stays in P4.
2. `LifeStateService` (damage, Downed, 35 s bleedout, execute) moves to **P3**, so the P5 jumpscare and P6 traps
   are complete. P8 adds the teammate revive, the syringe self-revive and spectating on top of it.
3. `LevelDirector` (CurrentLevel, level activation, advance) moves to **P1**, so floors 2–4 can be reached in
   P5–P7 through the dev level-skip. The airlocks (P6) call it.
4. `Timeline` (P3) and the Creature's `Scripted` state (P5) exist before the scripted beats in P6 and P8.
5. `RunLifecycleService` and the Studio dev-run harness land in **P1**. Every phase can be played on its own, and P8
   swaps the harness for the real lobby.
6. Later phases plug into registries owned by earlier ones (§1), so no earlier file is reopened. The only
   exceptions are the two bootstrap lists.
7. The stairwell airlock checkpoints (`CheckpointAirlockService`, with `DoorService` driving the fire doors) move from
   P8 to **P6**, so the demo can be played floor to floor. P8 listens to `FloorCleared` / `Sealed` for credits.

---

## 8. Tooling

```sh
rokit install                                  # rojo / selene / stylua / luau-lsp at the pinned versions
rojo build -o Rovloc.rbxl                      # FIRST: bootstrap the place (applies every engine pin)
# open Rovloc.rbxl in Studio, publish it, then live-sync into that same place:
rojo serve
rojo sourcemap -o sourcemap.json               # luau-lsp type resolution
selene src tests && stylua --check src tests
```

`rojo serve` can't write NotScriptable properties (most Workspace and StarterPlayer pins, and `Lighting.Technology`),
so always serve into a place made by `rojo build`, never into a Studio template. At boot, `ServerMain` checks what
scripts can read: `StreamingEnabled`, `CharacterAutoLoads`, `LuaCharacterController`, and server size ≤ 4. It also
runs a behavioural probe for deferred signals: it fires a `BindableEvent` and checks whether the handler has already
run. If anything fails, it sets `BootError`. Settings that scripts can't read are listed in `docs/PLACE_SETUP.md`.
