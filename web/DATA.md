# Rovloc Web world data

How the Roblox world becomes the web game's data, and what is in it.

- **Producer:** W1's tools.
- **Consumer:** everything under `src/`, through `src/engine/data.js`.

```sh
cd web && npm run data        # export (Lune) -> textures (Pillow) -> bake (Node + Playwright Chromium)
node tools/data-test.mjs      # decoder round trip + structural checks
```

| Step | Tool | Output |
| --- | --- | --- |
| export | `tools/export-world.luau` | `build/cache/world-raw.json`: every part, light, SurfaceGui, volume, attachment, entity, graph and layout of a real run's world at RunSeed 20251029 / Standard, built by the game's own builders in the Lune harness |
| textures | `tools/textures.py` | `build/textures/<Id>_{color,normal,orm}.webp` + `textures.json` (cached; reruns are instant) |
| bake | `tools/bake.mjs` (+ `tools/bake/*.mjs`) | `build/world.json`, `build/world.bin`, `build/textures/{decals,wear}_N.webp`, `build/cache/golden.json` |

The bake takes these options:

- `--quality low|high` (default high);
- `--no-decals`;
- `--threads N`;
- `--raw`, `--out`.

build.mjs inlines `world.json`, `world.bin` (gzip, then base64; inflate with DecompressionStream) and every
`build/textures/*.webp`. `build/cache/` holds intermediates and is not inlined.

## Conventions

- **Units and axes:** Roblox studs, Y up, right-handed, the same as three.js. Positions are used as they are.
- **CFrames:** 12 numbers `[x, y, z, R00, R01, R02, R10, R11, R12, R20, R21, R22]`, where `world = p + R * local`.
  For three.js, `cframeToMatrixElements()` gives `Matrix4.fromArray` order. For maths without three.js, use
  `cframeMul` and `cframeInverse`.
- **Colours:** sRGB 0..1 arrays, except light and probe values, which are linear.
- **Light units:** linear Roblox Brightness. A white Brightness-1 light, head-on and next to a surface, gives 1.0.
  - The baked falloff is `brightness * (1 - (d/R)^2)^2 / (1 + 0.004 d^2) * max(N·L, 0) * cone`, where `cone` is a
    smoothstep from the half angle to 0.7 × the half angle. It is recorded in `meta.lighting.falloff`.
  - Dynamic copies of baked lights should use the same falloff.
- **Textures:** upload with `flipY = true` (three.js default). Every UV assumes it.

## world.bin streams (`meta.streams[name] = { offset, length, type }`)

| stream | type | per | coding |
| --- | --- | --- | --- |
| `pos` | u16 ×3 | vertex | quantised in the chunk box (`chunk.quant` = origin xyz, step xyz), delta-coded per chunk |
| `nrm` | i8 ×3 | vertex | normal × 127 |
| `uv` | i16 ×2 | vertex | uv × `chunk.uvScale` (default 64 = 1/64 stud; decals and wear 8192), delta-coded (u16 wrap) |
| `col` | u8 ×3 | vertex | part colour (sRGB) |
| `lit` | u8 ×3 | vertex | baked light, `255 * sqrt(L / 4)`, delta-coded (u8 wrap) |
| `flk` | u8 ×2 | vertex | flicker group id, that group's share of the vertex's light (0..255) |
| `idx` | u16 | index | per chunk, triangles coded as (a − previous a, b − a, c − a), u16 wrap |
| `bone` | u8 | vertex | creature chunks only: bone index (`chunk.boneOffset`) |
| `cpos` | u16 ×3 | collision vertex | per level quant (`collision[level].quant`), delta-coded |
| `cidx` | u32 | collision index | triangle-delta coded, u32 wrap |
| `alpha` | u8 | vertex | transparent chunks only: 1 − Transparency (`chunk.alphaOffset`) |
| `probe` | u8 ×3 | probe | sqrt-encoded like `lit`; base grid, then one extra grid per scripted group reaching the level |

`decodeWorld(meta, bin)` undoes all of this. It returns `{ meta, chunks, collision, probes }`, where:

- each chunk's `attributes` hold `position` (f32), `normal` (i8 normalized), `uv` (f32), `color` (u8 normalized),
  `bakedLight` (u16 normalized = linear light ÷ 4, so the shader computes `bakedLight * 4.0`), `flicker` (u8 pair,
  not normalized) and, where they apply, `alpha` (u8 normalized), `skinIndex` and `skinWeight`;
- `chunk.index` is u16;
- each attribute is `{ array, itemSize, normalized }`, ready for `THREE.BufferAttribute`.

## Chunks (`meta.chunks`)

| field | meaning |
| --- | --- |
| `kind` | `static` (world space), `entity` (world space at rest, see Entities), `creature` (rig model space, rest pose) |
| `level` | `Lobby`, `Level0_Basement` … `Level5_Roof`, `Stairwells`, `Exterior` (street + skyline), `Creature` |
| `bucket` | `opaque`; `transparent` (glass / water / bulbs; per-vertex `alpha`); `emissive` (Neon: self-lit in its colour × its flicker); `decal`; `wear` |
| `material` | key into `meta.materials` |
| `aabb` | min xyz, max xyz |

Static chunks are split per level × bucket × material (one 240-stud cell, so a level is about 55 draw calls: cull per
level). There are about 400 chunks in all.

Faces buried in other solid static parts are culled. Large faces are subdivided where light varies:

- 2.4 studs under lights;
- 5 studs where the light is even;
- 8 studs where the face is dark;
- 8 or 16 studs outside.

### Buckets

- **`decal`:** SurfaceGui signage rendered to `textures/decals_N.webp` (RGBA). This covers lobby signs, room
  plates, wayfinding, STAIRS, chalkboards, notices, posters, wet-floor and caution signs, hazard stripes, locker
  numbers, flask labels and EXIT letters.
  - Quads sit 0.015 studs off the face.
  - Draw: alpha blended, depth test, no depth write, polygon offset (−2, −2), after opaque.
  - Colour: `tex.rgb * (li * bakedLight + (1 - li) * brightness)`, with `li` = `material.lightInfluence` and
    `brightness` = `material.brightness`.
  - Self-lit decals (`li` 0, the EXIT letters) carry their fixture's flicker group at share 255.
- **`wear`:** every wall's SurfaceGui grime, soot, corner dirt, water runs and cracks, baked to
  `textures/wear_N.webp` as a multiply factor (painted ÷ bare wall colour, display-encoded; white = untouched).
  - Quads sit 0.01 off the face, cropped to the area they darken.
  - Draw with multiplicative blending (`dst * src`, `DstColor, Zero`) after opaque, sampling the texel raw (no
    colour-space conversion) when the framebuffer is display-encoded.
  - No lighting, no alpha.

## Materials and textures

`meta.materials[key]` holds:

- `material`: the Roblox material, or `Decal` / `Wear`;
- `texture`: the generated texture id, or null;
- `studsPerTile`: a texture repeats every `uv / studsPerTile`;
- `roughness`, `metalness`, `reflectance`: Roblox base-material approximations, used when the texture has no ORM map;
- `emissive`, `glass`;
- decals only: `lightInfluence`, `brightness`;
- wear only: `blend: 'multiply'`.

The key is `<Material>` or `<Material>/<Texture>`.

`meta.textures[id]` holds `{ studsPerTile, reference, maps: { color, normal?, orm? } }`, with paths relative to
`build/`:

- `color`: lossy WebP q85, 512 px, sRGB. Multiply it by the vertex colour. The part colour was already divided by
  `reference`, as Roblox's MaterialVariant tint does.
- `normal`: lossless, 384 px. R = x, G = y in the OpenGL convention; B is stored as 1 (normalize after perturbing).
- `orm`: lossless, 256 px. G = roughness, B = metalness.

The atlases `Decals<N>` and `Wear<N>` have `atlas: true` and `studsPerTile` 1.

## Light, flicker, probes

- **Baked light:** `bakedLight` is the sum of:
  - direct light from every burning Light after LightingMood (Fluorescent SurfaceLights as area emitters, bulbs,
    emergency reds, exit signs, boiler glows, the burning gym high-bay), with 5 jittered shadow rays per light;
  - the moonlight window spills (`kind` Moonlight);
  - `Lighting.Ambient` × 4.5 (linear) × soft AO (14 rays, 6 studs);
  - `OutdoorAmbient` × 2.2 × sky openness (6 rays);
  - a dim moon on surfaces open to the sky.
- **Lights (`meta.lights`):** every Roblox light (burning or not) plus the moon spills. Fields:
  - geometry: `id` (fixture name, e.g. `L1_Light_ClassroomGlow`), `kind`, `cls` (point, spot or surface), `pos`,
    `dir`, `angle`, `color`, `brightness`, `range`, `shadows`;
  - state: `broken`, `baked`;
  - grouping: `group`, `flickerGroup` (Roblox name), `level`, `room`, `entity`.
- **Flicker groups (`meta.flickerGroups[id]`):** `{ name, kind, initial, lights }`.
  - `kind` `flicker`: the Roblox FlickerGroup. The level is a pure function of (RunSeed or 1, name, server time),
    as in LightingController.
  - `kind` `scripted`: `Scripted:Floodlights` (L4 pool, `initial` 0, on at the switch) and
    `Scripted:L1_Light_ClassroomGlow[Spill]` (die in the Floor 1 scare's burst).
  - A vertex's light is `baked × (1 − share + share × level[group])`. Neon glow parts and self-lit decals have share
    255.
- **Probes (`world.probes[level]`):** `{ origin, dims, spacing: 4, data, groups }`, linear RGB irradiance, lit
  omnidirectionally (N·L = 1). Probe (x, y, z) is at `((y * nz + z) * nx + x) * 3`. Probes inside solids are filled
  from their neighbours.
  - `data` excludes the scripted groups. `groups` has one extra grid per scripted group that reaches the level
    (`Scripted:Floodlights` on L4, the classroom glow on L1). Add `level[group] × extra`.
  - `sampleProbe(grid, x, y, z, out, groupLevels)` does this when given the group levels (for example the flicker
    table).
  - Use probes for anything that moves: the creature, hands, held items, open doors.

## Collision (`world.collision[level]`)

`{ position: f32, index: u32 }` holds the coarse triangles of every colliding static part, invisible colliders
included, for the BVH. `meta.collision[level].parts` gives the part count. Entity colliders are not in it; they are
the boxes in `meta.entities[i].colliders`.

## Entities (`meta.entities`)

Each entity is one interactive or scripted object of a run. `type` is one of:

- `AirlockDoor`, `HallwayGate`, `ClassroomDoor`, `RoofStairDoor`;
- `VentGrate`, `BearTrap`, `Locker`, `ChemicalFlask`, `Battery`;
- `ParachuteCrate`, `FloodlightSwitch`;
- `ReadyPad`, `Terminal`;
- floor objectives (see "Floor objectives" below):
  - items: `Fuse`, `MasterKeys`, `ReagentJar`, `CoachKey`, `ValveWheel`, `BoltCutters`, `AcidFlask`;
  - stations: `BreakerPanel`, `FumeHood`, `Generator`, `HatchValve`, `StoreLock`, `CrateChain`;
  - `ExitLock` (one per exit candidate on floors 0-4, on its fire door) and `StoreDoor` (the Level 3 equipment store's steel
    door, `DoorKind` RoofDoor, `ScriptedId` EquipmentStoreDoor).

Fields:

| field | meaning |
| --- | --- |
| `id` | DoorId / GrateId / AnchorId / name |
| `level` | level key |
| `attributes` | every Roblox attribute (GrateState from the plan, Armed, DoorKind / DoorState, Charge, ...) |
| `tags` | Roblox tags |
| `pivot` | rest CFrame |
| `nodes` | `[{ path, pivot }]`: the leaves (sub-Models: door leaves, locker door, grate panel and screws, trap jaws / springs / pan, crate packs, switch lever, ...). `pivot` is the leaf's hinge / slide origin at rest (PropKit leaves) |
| `attachments` | name → world CFrame at rest: `<Leaf>Rest/Open/Centre/Smashed` poses, PromptPoint, EntryAnchor / ExitAnchor, HideAnchor / PeekAnchor, GrabPoint, ... |
| `prompts` | ProximityPrompts: name, host, action / object text, hold, distance, attributes |
| `colliders` | `[{ node, cf (node space), size, shape, group }]` |
| `ranges` | `[{ chunk, start, count, node }]`: where its vertices are |

Entity geometry is batched: chunks per level × bucket × material in world space at the rest pose, with
`chunk.ranges` = `[{ entity, node, start, count }]` tiling the chunk. To move node `n` of entity `e` to pivot `P`,
let `M = P × inverse(entityNodeRest(e, n))`. Then either:

- CPU: `poseEntityRange(chunk, range, M, restCache)`, then upload that slice; `M = null` hides the node;
- GPU: use `nodeIndexAttribute(chunk)` and fetch `M` per node in the vertex shader.

Root parts use node `""` and move with the entity pivot.

## Floor objectives (`meta.objectives`, objective entities)

Every floor's exit stays locked until its objective is done (ObjectiveConfig in
`src/ReplicatedStorage/Shared/Config/ObjectiveConfig.luau`). `meta.objectives` holds:

- `floors`: ObjectiveConfig.Floors as data (per floor: `floor`, `levelId`, `id`, `title`, `item` {prop, candidate,
  count, guarded?, slots?, hold, object}, `steps` [{id, count, label, seconds?}], `lockStep`, `lockVariant`,
  `lockReason`, `holds` by prompt kind);
- `hideReach` (25): how close a hiding spot is to every step;
- `rules`: the fairness and spread rules of the item picks: `entryClearance` (35: studs walked from the floor's
  entry to every candidate), `pickSpacing` (25: studs between two items of one run, horizontal), `pickQuarters` (2:
  three items lie in at least this many quarters of the floor), `pickAttempts` (24: re-shuffles tried), `footprint`
  ([240, 160]: the quarters split it at its centre);
- `levels[levelId]`: `entry` {room, pos (level-local, the centroid of the entry room's PlayerSpawn anchors)},
  `candidates` [{anchorId, room, slot, ref, pos (level-local), planned, entryDistance (studs walked from the entry,
  ObjectivePlaces.walkDistance: door to door across rooms, through the vents a squad can always use, every Gate shut
  and every lockable grate locked), quarter (1 NW, 2 NE, 3 SW, 4 SE), hide {kind, id, distance}, eligible (a run may
  use it: every exported candidate is)}], `picks` (the export seed's RunDirector picks: `anchors` in pick order,
  `guards`), `places` (every candidate, station and lock with its nearest hiding spot: `hide` {kind Locker / Vent /
  DarkCorner / DryFooting / Cover, id, distance}).

| Floor | Item candidates (brief minimum) | Where |
| --- | --- | --- |
| 0 | 13 `Fuse` (12), each with a guard trap spot `L0_TrapGuard_NN` (its `ref`) | benches, shelves (new statics `L0_Shelf_Furniture`, `L0_Shelf_Archive`, `L0_Shelf_E1`), by the boilers, pumps, switchgear, water heaters, washers, coal heap |
| 1 | 10 `MasterKeys` (9), all west of the gate | nails in the janitor's closet, lounge, book store, stores, kitchen, classrooms 113 / 131, cafeteria, art room, library (new hideable lockers `L1_Locker_07..11` beside the new ones) |
| 2 | 12 `ReagentJar` (12), four per kind | lab worktops all over the floor (new hideable locker `L2_Locker_05` in chem lab 201) |
| 3 | 32 `CoachKey` (12) | inside every locker of both locker rooms (`ref` = the locker) |
| 4 | 8 `ValveWheel` (6) | the deep pool floor in open water, never under a walkway, each 12 studs or less of swim from dry footing |
| 5 | 9 `BoltCutters` (8) | against the HVAC units, the water tank, the boiler flue and the tool locker (new static `L5_ToolLocker`), on the maintenance box |

Objective entities carry attributes `Floor` (0-5), `Step`, `ObjectiveId` (= the entity type), `LevelId`, `AnchorId`
(the entity id; the acid flask's id is its name), and tags `ObjectiveItem` / `ObjectiveStation` / `ExitLock`.

- **Items** are exported for every candidate, not just the export seed's picks: attribute `Planned` says which ones
  the export seed uses; hide the others and pick per run with RunDirector.pickObjective's rule. One stream per level,
  `seededRandom(seed, "Objective|" + levelId)`, over the level's candidates in layout order (all eligible):
  - one item (keys, coach key, valve wheel, bolt cutters): `shuffle(candidates)`, take the first;
  - several items, up to `pickAttempts` passes on the same stream: fuses `shuffle(candidates)` and take, in that
    order, each candidate in another room than the items taken so far and at least `pickSpacing` from each of them,
    until `item.count`; reagents (slot of candidate i = `(i - 1) % 3 + 1`) for k = 1..3 `shuffle(slot k's
    candidates)` and take the first that keeps the same rule. A pass stands when it is full and its three items lie
    in at least `pickQuarters` quarters; otherwise the next pass reshuffles (if none stands, the first fullest pass
    is used). Slot = pick order (reagents: the kind);
  - the basement arms the guard trap (`ref`) of the first two fuses picked.
  Item attributes add `Slot` (a reagent's colour / kind 1-3), `Candidate` (the anchor kind). Attachments `Grip`
  (the hand), `PromptPoint` (a disabled `Pickup` prompt with the item's hold), and on the valve wheel `Hub` (its axis
  is the UpVector). The `AcidFlask` stands at the fume hood's `AcidFlaskSpot` with `Planned` false: show it when the
  mix is done.
- **Stations** (nodes = their leaves; each leaf's rest pose is attachment `<Leaf>Rest`):
  - `BreakerPanel`: nodes `Door` (built open, `DoorOpen`), `FuseSlot1..3` (attachments `FuseSlot<i>Seat`: pose a
    fitted fuse so its `Grip` lands there; `FuseSlot<i>Prompt` with a FitFuse prompt, `Slot` i), `Lever` (Breaker
    prompt on `LeverPrompt`; ON is a rotation of `LeverThrow` = 110 degrees about the lever's X axis);
  - `FumeHood`: node `Sash` (slides up, `SashOpen`), Mix prompt on `MixPrompt`, `ReagentSlot1..3`, `AcidFlaskSpot`,
    `Exhaust`;
  - `Generator`: node `PullCord` (slides out, `PullOut`), Generator prompt on `PullPrompt`, `Exhaust`, `LampHead` and
    a disabled SpotLight `WorkLamp` in `LampLens`;
  - `HatchValve`: nodes `Hatch` (top-hinged, `HatchOpen`) and `Stem` (turns about its axis), FitValve + TurnValve
    prompts on `ValvePrompt`, `WheelSeat` (pose the wheel so its `Hub` lands there), `GrateId` = the duct grate it
    shuts (the grate is unusable while the hatch is shut);
  - `StoreLock`: the equipment store door's padlock (node `Padlock`), Locked + Unlock prompts on `LockPrompt`;
  - `CrateChain`: nodes `Chain` and `Padlock`, Locked + CutChain prompts on `LockPrompt`, `ChainCentre`.
- **ExitLock**: on the exit airlock door's shut leaves (the doors are exported open: close them at run start), with
  `LockVariant` Padlock (L1: node `Padlock`), Chain (L2: nodes `Chain`, `Padlock`; `ChainCentre` is the throw target)
  or Keypad (L0, L3, L4: node `Bar`), `Locked` true, `DoorId` (the door entity's id), a `Locked` prompt (hold 0,
  ActionText "Locked — <reason>") and on L1 an `Unlock`, on L2 a `Pour` prompt, all on `LockPrompt`.

## Routes: random exits (`meta.routes`, `meta.routePairs`, `meta.routeRule`)

Every floor pair (1-5) has **three candidate stairwells**, one per stair tower on its side wall: slot `North`
(towers `NorthWest` / `NorthEast`, Z -4..28, opening at z 12), `Middle` (`West` / `East`, Z 64..96, opening at z 80;
the five original ids) and `South` (`SouthWest` / `SouthEast`, Z 132..164, opening at z 148). East side: 0→1, 2→3,
4→5; west side: 1→2, 3→4. A run uses one per pair; **the other two are jammed** for that run. `meta.stairwells`
lists all 15 (`id, pair, slot, tower, from, to, fromRoom, toRoom`; middle ones first) and `worldConfig.Towers` all six
(`minX, maxX, minZ, maxZ, side, openingZ`).

| Pair | North | Middle | South |
| --- | --- | --- | --- |
| 0→1 | `Stairwell_0_1_North`: `L0_AirlockNorthEast` → `L1_AirlockNorthEast` | `Stairwell_0_1`: `L0_AirlockEast` → `L1_AirlockEast` | `Stairwell_0_1_South`: `L0_AirlockSouthEast` → `L1_AirlockSouthEast` |
| 1→2 | `Stairwell_1_2_North`: `L1_AirlockNorthWest` → `L2_AirlockNorthWest` | `Stairwell_1_2` (West) | `Stairwell_1_2_South`: `L1_AirlockSouthWest` → `L2_AirlockSouthWest` |
| 2→3 | `Stairwell_2_3_North`: `L2_AirlockNorthEast` → `L3_AirlockNorthEast` | `Stairwell_2_3` (East) | `Stairwell_2_3_South`: `L2_AirlockSouthEast` → `L3_AirlockSouthEast` |
| 3→4 | `Stairwell_3_4_North`: `L3_AirlockNorthWest` → `L4_AirlockNorthWest` | `Stairwell_3_4` (West) | `Stairwell_3_4_South`: `L3_AirlockSouthWest` → `L4_AirlockSouthWest` |
| 4→5 | `Stairwell_4_5_North`: `L4_AirlockNorthEast` → `L5_RoofAccessNorth` | `Stairwell_4_5`: → `L5_RoofAccess` | `Stairwell_4_5_South`: `L4_AirlockSouthEast` → `L5_RoofAccessSouth` |

- **`meta.routes[from]`** (the shape `worldData.routeCandidates` consumes): the floor's exit candidates in slot order
  North, Middle, South, each `{ id = stairwellId, stairwellId, pair, slot, tower, from, to, fromRoom, toRoom,
  exitDoorIds, entryDoorIds, checkpoint, spawns, exitLock, creatureSpawn, picked }`: the fire door between the floor
  and the exit vestibule, the upper floor's entry door (a fire door, or on the roof the housing's `RoofStairDoor*`),
  the exit vestibule's Checkpoint trigger id, the upper vestibule's PlayerSpawn anchor ids (sorted: slot 1 first),
  the ExitLock entity id on the exit door (none on the roof), the housing's CreatureSpawn anchor (roof only) and
  whether it is the export seed's pick.
- **`meta.routePairs`**: `[{ pair, from, to, candidates: [ids], picked }]` (`picked` = RunDirector's route for the
  export seed; `plan.route` holds the same as `{ [from]: id }`).
- **`meta.routeRule`** = RunDirector.pickRoute: for each floor in climbing order, `seededRandom(seed, "Route|" +
  from)`; draw `NextInteger(1, 3)` over the candidates in slot order; keep the draw if it is **fair** for the floor's
  entry, else draw again from the same stream, up to `attempts` (8) draws, then take the first fair candidate in slot
  order (else the middle one). The entry is the basement's layout entry, then each pick's `toRoom`. Fair: its exit
  vestibule is at least `fairShare` (0.6) of the longest candidate's walk from the entry (the floor's door / vent walk
  graph, worst case: gates shut, lockable grates locked), and on `creatureSpawnLevels` (Levels 2, 3) the next floor
  keeps at least `minCreatureSpawns` (2) Creature starts (PatrolWaypoint / CreatureSpawn anchors) `creatureBand`
  (70-140) studs walked from that candidate's entry vestibule, outside it and the rooms its doorways open into, and
  outside every objective room (stations and every item candidate's room, whatever a run picks). The verdicts are
  precomputed: `routeRule.checks[from][entryRoom]` = `[{ stairwellId, distance, share, creatureSpawns, fair }]` for
  every way in (the layout entry and each entry vestibule candidate), so a port only needs the draws. Today every
  candidate is fair from every way in (shares 0.82-1.00).
- **Jam state.** Every stairwell door entity (`AirlockDoor` on both floors, the roof housings' `RoofStairDoor`)
  carries `StairwellId`, `RouteSlot`, `RouteRole` (`Exit` on the lower floor, `Entry` on the upper) and `Jammed` (the
  export seed's state), and has node **`Jam`** (no rest pose, never posed: a fallen slab leaning on the back of the
  shut leaves, rubble, a bent rebar and a buckled lintel, on the vestibule side so it shows through the wired glass;
  non-colliding) and a `Locked` prompt on attachment `JamPrompt` ("Jammed — this stairwell has collapsed", hold 0,
  enabled only while jammed). The export shows every `Jam` node. Per run: for each door whose `StairwellId` is not the
  run's pick for its pair, set it shut and `Locked` (and keep it so), show `Jam`, enable the prompt; on the picked
  route's doors hide `Jam`. (In Roblox DoorBuilder.setJammed does this at build and DoorService starts such a door
  Locked.)
- **Per vestibule:** a Checkpoint volume, a dim EmergencyRed lamp (the same whichever route is picked; light is baked
  once), 4 PlayerSpawn anchors on entry vestibules, an ExitLock anchor on every exit candidate's fire door (L0-L4) and
  a hideable locker within reach of each new lock. Each roof housing has its `RoofStairDoor` /
  `RoofStairDoorNorth` / `RoofStairDoorSouth` (ScriptedId), a CreatureSpawn behind it (`L5_CreatureSpawn`, `_North`,
  `_South`), 4 PlayerSpawns, the same lamps, and the tower below it.
- **Floor changes for the corner vestibules:** the corner rooms shrank (their side-wall windows went); L0's south-east
  vestibule opens off `L0_Store_E2` (the condemned store stays boarded); L1-L3's open off the outer halls (L1's west
  ones inside the sealed west half); L3's west halls are caved in at x = 60 (`L3_Door_NorthCaveIn` /
  `L3_Door_SouthCaveIn`, Boarded; new rooms `L3_NorthHall_Mid` / `L3_SouthHall_Mid`), so the corner exits are only
  reached across the gym floor; L4's corner vestibules open off the corner rooms, the east ones reached only from the
  east deck: `L4_ChlorineHall` (x 214..228, z 25..30, a passage from the deck to the chlorine store; the maintenance
  chase now ends at x 214) and a door from the deck into the scoreboard room (its door to `L4_Storage_E2` went).
- **Bear traps:** 16 trap entities (Nightmare's trapCount): this seed's Standard traps (`Planned` true) and the rest
  of the Nightmare plan's (`Planned` false); `worldData.plan` moves as many as a run's difficulty needs.

## Creature (`meta.creature`)

- **Bones:** `bones[i] = { name, parent, motor, rest, size }`. Bone i is `skinIndex` i. `rest` is the bone part's
  CFrame in model space; the rig is built at the origin facing −Z, HumanoidRootPart at y 4.7.
- **Joints:** `joints` are the Motor6Ds: `{ name, part0, part1, c0, c1 }`. A joint's transform applies as
  `part1 = part0 * C0 * T * C1⁻¹`.
- **Geometry:** `chunks` are the creature chunks (skinned).
- **Other data:**
  - `parts`: every rig part, with its bone, size and attributes (the hitbox and HumanoidRootPart included);
  - `lights`: eye glow;
  - `attachments`;
  - `hipHeight`;
  - `config`: CreatureConfig (speeds, senses, hitbox sizes per PoseMode, eye offsets).

## World layout data

| field | contents |
| --- | --- |
| `levels[key]` | `{ origin, elevation, height, aabb, film }` |
| `rooms` | world rects (`x, z, w, d`), floorY, height, kind, acoustic, ambience, floor / wall / ceiling keys |
| `zones` | the Zone volumes (cframe, size, roomKind, acoustic preset, surface) |
| `anchors` | every layout anchor: PlayerSpawn, CreatureSpawn, CreatureScarePose, PatrolWaypoint (+ `loop`, `order`), Trap / Flask / BatteryCandidate, ParachuteCrate, Locker, Corpse, ... (`cframe`, `room`) |
| `patrolLoops` | `[{ level, loop, waypoints: [{ id, room, pos }] }]` in walking order (the last leads back to the first) |
| `triggers` | ScareStep, FloorDebris, Checkpoint, PoolWater, LevelExit volumes (`cframe`, `size`, `attributes`) |
| `pools` | PoolWater volumes as surface Y, rect and depth (`basins`: the layout basins) |
| `doors` | layout door anchors (Door / Ajar / Gate / Airlock / RoofDoor: cframe looking into the next room, width, height, scriptedId) |
| `layoutDoors` | every layout door incl. Boarded / Doorway, level-local |
| `zoneGraph` | `ZoneGraph.build` output: `nodes`, `edges`, `adjacency` (rooms + portals) |
| `vents.graphs[level]` | `VentGraph.build` output: `nodes` (positions, links, grateId), `grates` (wall CFrame, mouth, lockable, criticalPath), `grateAtNode`, `segments` |
| `vents.nodes`, `vents.grates` | the raw VentNode / grate attachments |
| `stairwells` | WorldConfig.Stairwells: all 15 candidates (`id, pair, slot, tower, from, to, fromRoom, toRoom`), see "Routes" |
| `worldConfig` | WorldConfig as data |
| `windows` | the moonlight window specs (Volumetrics.windowSpecs) |
| `plan` | the director's plan for the seed (props, lockedGrates) |
| `layouts` | the raw layout blueprints, level-local as authored |
| `film.levels[key]` | LightingMood.film (exposure, contrast, saturation, lift, bloom, Atmosphere density / offset / haze / glare / colour / decay, sun rays, DOF, vignette, shafts, dust, moon). `film.base` is the base film; `film.levels.Outdoor` is the storm outside |
| `lighting` | `baseline` (LightingRig), `moods` (per level: cast, grade tint, revive, ...), `moonlight`, `fixtureCones` (haze-cone shapes per light kind), `bakedAmbient`, `falloff` |
| `palette` | Palette keys: material, colour, surface, texture |

## Known differences from a live server

- The Lune harness's `Random` is a deterministic xorshift, not Roblox's PCG32. Seeded choices are fixed and
  reproducible but are not the ones a live server would make for the same seed: which traps, flasks and batteries,
  which grates are locked, which dead tubes revive, and the strip-fixture variants.
- The client-only light shafts, dust and lightning are not baked; the engine draws them. Moonlight is baked from every
  window, where the Roblox client lights only the nearest few.
