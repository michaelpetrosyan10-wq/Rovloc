# Rovloc — Architecture

A 1–4 player co-op first-person survival horror game set in a pitch-black, post-apocalyptic five-level school.
Everything (geometry, the Creature rig, animation, audio and UI) is generated in code. The game ships with
no `.rbxm` models, no `rbxassetid://` animations and no `rbxassetid://` sounds.

---

## 1. Ground rules

| Rule | How it's enforced |
| --- | --- |
| `--!strict` everywhere | Every `.luau` file starts with `--!strict`. `.luaurc` sets `languageMode: strict` for luau-lsp. |
| Works in Rojo **and** Studio | `src/` mirrors the Explorer one-to-one (`src/<Service>/...`). Requires use instance paths (`require(ReplicatedStorage.Shared.Config.GameConfig)`), never string aliases, so the same code runs whether it was synced by Rojo or pasted into Studio. |
| One entry point per side | `ServerScriptService/ServerMain` and `StarterPlayerScripts/ClientMain` require an explicit, ordered module list. Each Service/Controller exposes `Init()` (wire up, no yielding) and `Start()` (begin loops). Nothing auto-loads by scanning folders, so strict typing sees every dependency. |
| Server authority | Clients send *intents* (crouch, throw, struggle press, ready-up). The server validates, mutates state and replicates it through Attributes. Clients never report noise, damage, battery or oxygen. |
| Time sync | Every one-shot event (neck snap, lightning, jumpscare, gate slam) carries a `workspace:GetServerTimeNow()` stamp, so all clients play it on the same frame. |
| Resettable runs | Everything spawned for a run lives under `Workspace.Runtime` and in per-service `Trove`s. `MatchResetService` calls `ResetForRun(seed)` on every service in reverse start order. |
| Procedural only | Geometry uses built-in `Enum.Material`s, Parts, WedgeParts, Attachments and Constraints. Audio layers verified `rbxasset://sounds/` engine files through `SoundEffect` DSP chains. Animation writes `Motor6D.Transform` every frame. |

---

## 2. Repository file tree

Phase tags show which phase writes each file: `[P1]` … `[P8]`.

```text
Rovloc/
├── default.project.json                         Rojo project (validated with Rojo 7.7.1)
├── rokit.toml                                   Toolchain pins: rojo, selene, stylua
├── selene.toml                                  Linter (std = "roblox")
├── stylua.toml                                  Formatter (Luau syntax)
├── .luaurc                                      languageMode = strict
├── .gitignore
├── .vscode/
│   ├── extensions.json                          luau-lsp, Rojo, StyLua, selene
│   └── settings.json                            luau-lsp sourcemap → default.project.json
├── docs/
│   └── ARCHITECTURE.md                          This file
└── src/
    ├── ReplicatedFirst/
    │   └── LoadingCurtain.client.luau           [P3] Black curtain + "generating school" status until WorldReady
    │
    ├── ReplicatedStorage/
    │   └── Shared/
    │       ├── Config/
    │       │   ├── GameConfig.luau              [P1] Timers: bleedout 35s, revive 4s, straggler 20s, trap pry 5s/1.5s, stun 6s
    │       │   ├── DifficultyConfig.luau        [P1] Standard vs Nightmare (creature speed, trap count, battery count)
    │       │   ├── NoiseConfig.luau             [P1] Radii: 8 / 30 / 65 / 75 / 90 / 130 + priority tiers
    │       │   ├── CameraConfig.luau            [P1] Camera state offsets, FOV, bob / sway / shake tuning
    │       │   ├── CreatureConfig.luau          [P1] Speeds per state, hearing, sight, EMF radius 45, rig dimensions
    │       │   ├── PerkConfig.luau              [P1] Rusty Screwdriver, Lithium Cell, Adrenaline Syringe (cost + effect)
    │       │   └── WorldConfig.luau             [P1] Floor heights, 3.5×3.5 vent bore, door clearances, zone origins
    │       ├── Types.luau                       [P1] Exported types shared across both sides
    │       ├── Enums.luau                       [P1] CameraState, MoveState, LifeState, MonsterState, MatchPhase, NoiseKind, Difficulty, PerkId, LevelId
    │       ├── Tags.luau                        [P1] CollectionService tag registry (see §5)
    │       ├── Attributes.luau                  [P1] Replicated attribute keys (see §6)
    │       ├── CollisionGroups.luau             [P1] Group names + collision matrix as data (see §4)
    │       ├── Net/
    │       │   ├── init.luau                    [P1] Typed remote wrapper: server creates, client waits
    │       │   └── RemoteRegistry.luau          [P1] Every remote: name, reliable/unreliable, direction
    │       ├── Audio/
    │       │   ├── SoundSynthesizer.luau        [P1] Layered voice engine: Sound layers + DSP chains, envelopes, SoundGroups
    │       │   ├── SoundLibrary.luau            [P1] Verified rbxasset://sounds/ engine-file catalog
    │       │   └── SynthPresets.luau            [P1] Recipes: screech, heartbeat, vent scrape, trap snap, bone crunch,
    │       │                                         drip, glass crunch, drone, EMF static, chem hiss, gate slam,
    │       │                                         light burst, thunder, rain, splash, gasp, breathing
    │       ├── Animation/
    │       │   └── ProceduralAnimator/
    │       │       ├── init.luau                [P3] Core: layered pose blending, springs, server-time one-shots
    │       │       ├── JointMap.luau            [P3] Finds Motor6D (or AnimationConstraint) joints on R15 + Creature rigs
    │       │       └── Profiles/
    │       │           ├── PlayerR15.luau       [P3] Walk, sprint, crouch, vent crawl, downed crawl, swim, trapped, parachute
    │       │           └── Creature.luau        [P4] Biped stalk, sprint, stun flail, 180° neck snap, quadruped spider crawl, lunge, swim
    │       └── Util/
    │           ├── Signal.luau                  [P1] Typed signal
    │           ├── Trove.luau                   [P1] Connection / instance / thread cleanup
    │           ├── Spring.luau                  [P1] Critically damped spring
    │           ├── MathUtil.luau                [P1] Lerp, remap, noise, bezier, angle helpers
    │           ├── SpatialQuery.luau            [P1] RaycastParams / OverlapParams factories per collision group
    │           └── BinaryHeap.luau              [P4] Priority queue for A*
    │
    ├── ServerScriptService/
    │   ├── ServerMain.server.luau               [P1] Bootstrap: Init() all → Start() all, in order
    │   ├── Services/
    │   │   ├── CollisionService.luau            [P1] RegisterCollisionGroup + matrix + auto-assign by tag / character
    │   │   ├── CharacterService.luau            [P1] Spawn / respawn, R15 guard, Humanoid tuning, group assignment
    │   │   ├── AudioService.luau                [P1] SoundGroups, world-anchored one-shots, per-player cues via Net
    │   │   ├── WorldService.luau                [P1] Runs ProceduralWorldBuilder, publishes WorldReady, rebuild hooks
    │   │   ├── NoiseAndDirectorService/
    │   │   │   ├── init.luau                    [P1] Noise bus: Emit(position, radius, kind, source) + Subscribe; director API
    │   │   │   ├── LocomotionNoiseSampler.luau  [P1] 10 Hz server-side sampling of each character's verified movement
    │   │   │   └── RunDirector.luau             [P1] Seeded per-run randomizer: traps, grate locks, flask / battery spawns
    │   │   ├── PlayerStateService.luau          [P3] Authoritative MoveState / CameraState, stamina, intent validation, look relay
    │   │   ├── FlashlightService.luau           [P3] Battery authority, drain, pickups, Lithium Cell perk
    │   │   ├── VentNetworkService/
    │   │   │   ├── init.luau                    [P4] Grates (unscrew / kick), enter / exit, vent occupancy, rail validation
    │   │   │   ├── VentGraph.luau               [P4] Builds the graph from VentNode attachments
    │   │   │   └── VentPathfinder.luau          [P4] A* over VentGraph (BinaryHeap, Euclidean heuristic)
    │   │   ├── MonsterAIService/
    │   │   │   ├── init.luau                    [P5] State machine host + 10 Hz brain tick
    │   │   │   ├── Perception.luau              [P5] Line of sight raycasts, hearing from the noise bus, locker / vent peeks
    │   │   │   ├── Locomotion.luau              [P5] PathfindingService on floors; A* rail through vents; water movement
    │   │   │   ├── JumpscareHandler.luau        [P5] Catch → camera lock, lunge, screech, Downed or execute
    │   │   │   └── States/
    │   │   │       ├── Dormant.luau             [P5]
    │   │   │       ├── Patrol.luau              [P5]
    │   │   │       ├── InvestigateNoise.luau    [P5]
    │   │   │       ├── WallChase.luau           [P5]
    │   │   │       ├── VentChase.luau           [P5]
    │   │   │       ├── Stunned.luau             [P5]
    │   │   │       └── AquaticStalk.luau        [P5]
    │   │   ├── LevelMechanics/
    │   │   │   ├── BearTrapService.luau         [P6] Snap, 35 damage, root lock, solo pry 5s, co-op pry 1.5s
    │   │   │   ├── ClassroomEncounterService.luau [P6] Floor 1 scripted scare + gate slam
    │   │   │   ├── ChemicalProjectileService.luau [P6] Server-verified parabolic flask, shatter, stun cloud
    │   │   │   ├── LockerHidingService.luau     [P7] Enter / exit lockers, creature inspection, hold-breath verdicts
    │   │   │   └── FloodedPoolService.luau      [P7] Swim validation, oxygen, swim stamina, grab + drag struggle, floodlight
    │   │   └── MatchAndDataService/
    │   │       ├── init.luau                    [P8] Match phase machine: Lobby → Countdown → InRun → Escaped / Wiped → Results
    │   │       ├── PlayerDataStore.luau         [P8] Session-locked UpdateAsync, retries, autosave, BindToClose
    │   │       ├── LobbyService.luau            [P8] Ready-up, difficulty vote, late-join spectators
    │   │       ├── PerkShopService.luau         [P8] Credit spend + loadout validation
    │   │       ├── CheckpointAirlockService.luau [P8] Fire doors, 20s straggler timer, respawn at 50% HP, floor credits
    │   │       ├── DownedReviveService.luau     [P8] Downed, 35s bleedout, 4s revive, syringe self-revive, execute
    │   │       ├── SpectatorService.luau        [P8] Spectate targets + teammate camera relay
    │   │       ├── RoofFinaleService.luau       [P8] Door smash, parachute packs, descent, lightning reveal
    │   │       └── MatchResetService.luau       [P8] Full reset + Play Again
    │   └── ProceduralWorldBuilder/
    │       ├── init.luau                        [P1] BuildLobby / BuildSchool / BuildProps / BuildCreature / ClearRuntime
    │       ├── Palette.luau                     [P1] Materials + colour grading (concrete, tile, galvanized steel, rust, ...)
    │       ├── Geometry.luau                    [P1] Part factory: slabs, walls with door / vent cut-outs, trims, pillars, stairs
    │       ├── LightingRig.luau                 [P1] Atmosphere, ColorCorrection, Bloom, Terrain clouds, lightning rig
    │       ├── LobbyBuilder.luau                [P1] Boiler-room safe zone + wrecked bus staging area
    │       ├── SchoolShellBuilder.luau          [P1] Levels 0–5: floors, walls, rooms, corridors, windows, boards
    │       ├── StairwellBuilder.luau            [P1] Stairwells + airlock vestibules between every level
    │       ├── VentShaftBuilder.luau            [P1] 3.5×3.5 galvanized ducts inside walls + VentNode graph
    │       ├── SkylineBuilder.luau              [P1] Ruined city backdrop for the roof finale
    │       ├── Layouts/
    │       │   ├── Level0_Basement.luau         [P1] Data blueprints the builders consume:
    │       │   ├── Level1_Hallways.luau         [P1]   rooms, doors, vent routes, spawn anchors,
    │       │   ├── Level2_ScienceHall.luau      [P1]   trigger volumes, patrol waypoints
    │       │   ├── Level3_Gymnasium.luau        [P1]
    │       │   ├── Level4_FloodedPool.luau      [P1]
    │       │   └── Level5_Roof.luau             [P1]
    │       ├── Props/
    │       │   ├── BearTrapBuilder.luau         [P2] Hinged rusted jaws, spring, chain, stake
    │       │   ├── VentGrateBuilder.luau        [P2] Grate, four screws, hinge, ProximityPrompts
    │       │   ├── ChemicalFlaskBuilder.luau    [P2] Glass flask, glowing liquid, viewmodel template
    │       │   ├── LockerBuilder.luau           [P2] Hideable locker with door hinge + horizontal slits
    │       │   ├── PoolWaterBuilder.luau        [P2] Murky water volumes, collapsed walkways, half-submerged ducts
    │       │   ├── ParachuteBuilder.luau        [P2] Packs, crate, canopy template
    │       │   ├── DoorBuilder.luau             [P2] Airlock fire doors, hallway gate, roof stairwell door
    │       │   ├── PickupBuilder.luau           [P2] Flashlight batteries
    │       │   ├── FloodlightSwitchBuilder.luau [P2] Emergency pool floodlight switch
    │       │   └── SetDressingBuilder.luau      [P2] Ragdoll corpses, smashed lockers, glass / can debris, dripping pipes, lab counters
    │       └── CreatureRigBuilder.luau          [P2] 8.5-stud gaunt rig, Motor6D joints, hair, claws, grin, pinprick pupils
    │
    └── StarterPlayer/
        ├── StarterCharacterScripts/
        │   ├── Animate.client.luau              [P3] Replaces default Animate: drives ProceduralAnimator on own character
        │   └── Health.server.luau               [P1] Replaces default regen: health only changes via server services
        └── StarterPlayerScripts/
            ├── ClientMain.client.luau           [P1] Bootstrap: Init() all → Start() all, in order
            ├── RbxCharacterSounds.client.luau   [P3] Replaces default footsteps: material-aware synthesized footsteps
            └── Controllers/
                ├── AudioController.luau         [P1] Ambient drone bed, zone reverb, client-local cues
                ├── FirstPersonController/
                │   ├── init.luau                [P3] Camera state machine host
                │   ├── CameraStates.luau        [P3] Standing, Crouching, VentCrawling, DownedCrawling, LockerPeeking,
                │   │                                 UnderwaterSwimming, ParachuteLookback + overrides (Trapped, Jumpscare, Cutscene, Spectating)
                │   ├── BodyRenderer.luau        [P3] Keeps arms / torso / legs visible in LockFirstPerson
                │   ├── MovementController.luau  [P3] Crouch / sprint / stamina intents, mobile buttons
                │   ├── ViewBob.luau             [P3] Sine bob, breathing sway, shake
                │   ├── PanicVFX.luau            [P3] ColorCorrection, DepthOfField, FOV warp, vignette
                │   └── Flashlight.luau          [P3] Dual-cone SpotLights, battery HUD, EMF flicker + static
                ├── HUD/
                │   ├── init.luau                [P3]
                │   ├── UIKit.luau               [P3] Procedural UI primitives (no image assets)
                │   ├── StatusBars.luau          [P3] Battery, stamina, oxygen, bleedout
                │   ├── PromptRenderer.luau      [P3] Custom ProximityPrompt style + hold rings
                │   └── MobileControls.luau      [P3] Touch buttons: flashlight, crouch, sprint, throw, breath, struggle
                ├── RemoteCharacterAnimator.luau [P3] Animates teammates' rigs from replicated state
                ├── CreatureAnimationController.luau [P4] Animates the Creature locally from replicated state
                ├── VentController.luau          [P4] Vent entry / exit transitions, rail crawl input, duct audio
                ├── JumpscareController.luau     [P5] Camera lock to face, lunge, screech, flash
                ├── BearTrapController.luau      [P6] Leg-lock camera tilt, shaking-hands pry
                ├── ClassroomEncounterController.luau [P6] Glass crunch, neck-snap stare, light burst
                ├── ChemicalThrowController.luau [P6] Flask viewmodel, aim arc, throw intent
                ├── LockerController.luau        [P7] Locker enter / peek + hold-breath minigame
                ├── SwimController.luau          [P7] First-person swim input, oxygen HUD, underwater VFX
                ├── StruggleController.luau      [P7] Spacebar mash struggle
                ├── LobbyController.luau         [P8] Ready-up, difficulty, perk shop UI
                ├── DownedController.luau        [P8] Downed crawl HUD + self-revive
                ├── SpectatorController.luau     [P8] Q / E teammate cycling through their first-person view
                ├── ParachuteController.luau     [P8] Leap, ripcord, lookback camera
                └── EscapeSummaryController.luau [P8] ESCAPED / WIPED summary + Play Again
```

---

## 3. Roblox Studio Explorer hierarchy

### 3a. Edit time (what Rojo syncs, or what you create by hand in Studio)

```text
game
├── Workspace                      StreamingEnabled=false · SignalBehavior=Deferred · RejectCharacterDeletions
│                                  · ValidateEnabledProximityPrompt · Touch events use collision groups
├── Lighting                       Technology=Future · ClockTime 0.5 · Brightness 0 · Ambient black
├── Players                        CharacterAutoLoads=false (CharacterService spawns players)
├── ReplicatedFirst
│   └── LoadingCurtain             LocalScript
├── ReplicatedStorage
│   └── Shared                     Folder
│       ├── Config                 Folder of ModuleScripts
│       ├── Types · Enums · Tags · Attributes · CollisionGroups      ModuleScripts
│       ├── Net                    ModuleScript (+ RemoteRegistry)
│       ├── Audio                  Folder: SoundSynthesizer · SoundLibrary · SynthPresets
│       ├── Animation              Folder: ProceduralAnimator (ModuleScript + JointMap + Profiles)
│       └── Util                   Folder of ModuleScripts
├── ServerScriptService
│   ├── ServerMain                 Script
│   ├── Services                   Folder of ModuleScripts (folders with init.luau are ModuleScripts with children)
│   └── ProceduralWorldBuilder     ModuleScript with child modules
├── SoundService                   AmbientReverb=NoReverb · DopplerScale=0 · RespectFilteringEnabled
├── StarterGui                     ResetPlayerGuiOnSpawn=false (all UI is built in code)
└── StarterPlayer                  GameSettingsAvatar=R15 · AvatarJointUpgrade=Disabled · CameraMode=LockFirstPerson
    ├── StarterCharacterScripts
    │   ├── Animate                LocalScript (replaces default)
    │   └── Health                 Script (replaces default)
    └── StarterPlayerScripts
        ├── ClientMain             LocalScript
        ├── RbxCharacterSounds     LocalScript (replaces default)
        └── Controllers            Folder of ModuleScripts
```

Rojo file-name mapping, for Studio users: `X.server.luau` → **Script**, `X.client.luau` → **LocalScript**,
`X.luau` → **ModuleScript**, a folder holding `init.luau` → **ModuleScript** whose children are the other files.

### 3b. Run time (built by code; never saved in the place file)

```text
Workspace
├── Lobby                          Model  Boiler room / bus safe zone: ReadyPads, DifficultyTerminal, PerkLocker, LobbySpawns
├── School                         Model
│   ├── Level0_Basement            Model  Shell · Lights · Anchors · Triggers · Waypoints
│   ├── Level1_Hallways            Model
│   ├── Level2_ScienceHall         Model
│   ├── Level3_Gymnasium           Model
│   ├── Level4_FloodedPool         Model
│   ├── Level5_Roof                Model
│   ├── Stairwells                 Model  Stairwell_0_1 … Stairwell_4_5 (AirlockDoor + CheckpointVolume each)
│   └── VentNetwork                Model  Duct segments [VentShaft] carrying VentNode attachments [VentNode]
├── Skyline                        Model  Ruined city silhouettes, fog cards
├── Creature                       Model  [P2] Humanoid · HumanoidRootPart · Motor6D rig
└── Runtime                        Folder Per-run spawns: traps, flasks, batteries, projectiles, clouds, corpses (wiped on reset)

Lighting                           Atmosphere · ColorCorrection · Bloom · SunRays (+ client-local Panic CC / DOF)
Workspace.Terrain                  Clouds (storm deck)
ReplicatedStorage
├── Shared                         (Rojo)
├── Net                            Folder  RemoteEvent / UnreliableRemoteEvent / RemoteFunction (created by Net)
└── Prefabs                        Folder  Client-cloneable procedural templates (flask viewmodel, canopy, battery)
ServerStorage
└── Templates                      Folder  Server-only templates (Creature master, prop masters)
SoundService
└── Master                         SoundGroup ▸ Ambience · World · Monster · Player · UI (nested SoundGroups)
```

---

## 4. Collision groups

`CollisionService` registers the groups with `PhysicsService:RegisterCollisionGroup` and applies this matrix
(✓ = collide). The user's four required groups (Players, Monster, CorpseProps, Projectiles) are joined by two
helpers that make the vent and doorway guarantees hold.

| | Default | Players | Monster | CorpseProps | Projectiles | MonsterPassthrough | Kinematic |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| **Default** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| **Players** | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ |
| **Monster** | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ |
| **CorpseProps** | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ |
| **Projectiles** | ✓ | ✗ | ✓ | ✗ | ✗ | ✓ | ✗ |
| **MonsterPassthrough** | ✓ | ✓ | ✗ | ✓ | ✓ | ✓ | ✗ |
| **Kinematic** | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |

- **Players ✗ Players.** Teammates can't wedge or fling each other anywhere, vents included.
- **Kinematic** is for characters on scripted motion: vent crawl (players and the Creature), locker hiding, the
  underwater drag. They ride the VentNode rail or a scripted path under `AlignPosition` and touch nothing, so
  the 3.5×3.5 duct can't trap or fling anyone.
- **Monster ✗ MonsterPassthrough / CorpseProps / Players.** Door trims, lockers, desks, debris and ragdolls
  never block the Creature. Those props also carry `PathfindingModifier { PassThrough = true }`. Only the
  Creature's HumanoidRootPart collides; its limbs are `CanCollide=false, Massless=true`. Doorways are built at
  10 studs clear, and the Creature ducks through them procedurally.
- **Projectiles.** Flasks are simulated on the server with stepped raycasts using
  `RaycastParams.CollisionGroup = "Projectiles"`. They hit walls, props and the Creature, and pass through players and corpses.

---

## 5. CollectionService tags

`VentShaft` · `VentGrate` · `VentNode` · `BearTrap` · `ChemicalItem` · `HideableLocker` · `ParachutePack` ·
`BatteryPickup` · `FloorDebris` · `DripPipe` · `Corpse` · `PoolWater` · `FloodlightSwitch` · `AirlockDoor` ·
`CheckpointVolume` · `ScareTrigger` · `PatrolWaypoint` · `SpawnAnchor` · `MonsterPassthrough`

---

## 6. Replicated state contract (Attributes)

| Owner | Attributes |
| --- | --- |
| `Player` | `LifeState`, `MoveState`, `CameraState`, `Battery`, `Stamina`, `Oxygen`, `DownedCount`, `Ready`, `Loadout` |
| `Workspace.Creature` | `MonsterState`, `StateSince`, `PoseMode` (Biped / Quadruped / Swim), `TargetUserId`, `InVent`, `OneShot`, `OneShotAt` |
| `ReplicatedStorage` | `MatchPhase`, `RunSeed`, `Difficulty`, `CurrentLevel`, `WorldReady` |

The Creature is simulated on the server (network owner `nil`). Every client animates it locally: the
`ProceduralAnimator` reads `PoseMode`, the root velocity and the `OneShot` / `OneShotAt` pair. Writing joint
transforms on the server would cost bandwidth and stutter; this way every client renders a smooth, identical pose.

---

## 7. Eight-phase build order

| Phase | Scope | Files |
| --- | --- | --- |
| **1** | Shared config, types and net layer · collision groups · `SoundSynthesizer` · `NoiseAndDirectorService` · `ProceduralWorldBuilder` part 1 (lobby, 5-level shell, stairwells, wall vents + VentNode graph, apocalyptic lighting) | All `[P1]` |
| **2** | `ProceduralWorldBuilder` part 2: bear traps, grates, flasks, lockers, pool water, parachutes, doors, dressing + Creature rig | All `[P2]` |
| **3** | `FirstPersonController`, flashlight + EMF, view-bob, panic VFX, horror HUD, `ProceduralAnimator` core + player profile | All `[P3]` |
| **4** | `VentNetworkService` (unscrew vs kick, crawl transitions, A*) + `ProceduralAnimator` Creature profile | All `[P4]` |
| **5** | `MonsterAIService`: all 7 states, noise investigation, vent chase, jumpscare | All `[P5]` |
| **6** | Bear traps, Floor 1 classroom encounter, Floor 2 chemical stun physics | All `[P6]` |
| **7** | Floor 3 lockers + hold breath, Floor 4 swim / oxygen / drag struggle | All `[P7]` |
| **8** | `MatchAndDataService`: lobby, perks, DataStore, airlocks, downed / revive, spectator, roof finale, reset | All `[P8]` |

**One dependency change.** The `ProceduralAnimator` core and the player R15 profile move from Phase 4 to
Phase 3. The body renderer needs real leg and arm motion the first time you look down. Phase 4 still builds
every Creature animation listed in the roadmap.

---

## 8. Tooling

```sh
rokit install                                   # rojo / selene / stylua at the pinned versions
rojo serve                                      # live-sync into Studio (Rojo plugin)
rojo build -o Rovloc.rbxlx                      # one-shot place file (Studio-only workflow)
rojo sourcemap -o sourcemap.json                # luau-lsp type resolution
selene src && stylua --check src
```
