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
| export | `tools/export-world.luau` | `build/cache/world-raw.json`: every part, light, SurfaceGui, volume, attachment, entity, graph and layout of a real run's world at RunSeed 20251029 / Standard (plus a prop on every candidate anchor a run may pick), built by the game's own builders in the Lune harness, and the shared configs (`configs`, below); `build/cache/run-plans.json`: RunDirector's plans for a spread of seeds (the data test replays them on worldData's port); `build/cache/golden.json`: the shared rules' golden rows (below) |
| textures | `tools/textures.py` | `build/textures/<size>/<Id>_{color,normal,orm}.webp` per graphics tier (2048, 1024, 512, 256) + `textures.json` (cached; reruns are instant) |
| bake | `tools/bake.mjs` (+ `tools/bake/*.mjs`) | `build/world.json`, `build/world.bin`, `build/textures/{decals,wear}_N.webp`, `build/cache/codec-golden.json` (the codec's pre-encoding samples) |

The bake takes these options:

- `--quality low|high` (default high);
- `--no-decals`;
- `--threads N`;
- `--raw`, `--out`.

build.mjs (through `tools/assets.mjs`) ships `world.json` and `world.bin` gzipped (inflated with DecompressionStream),
the texture sets and the atlases two ways: the site (`site/beta/index.html` + content-hashed `site/beta/assets/*`, fetched) and
single files (the lite build and the test pages: base64 in non-executed script tags). The page's asset manifest (an
inline JSON script, `rv-manifest`) names every asset by URL or by `inline:<script id>`. `build/cache/` holds
intermediates and is not shipped.

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

## The shared rules: configs and golden rows

The export finds them itself; nothing in it names a module (a new one is picked up by its own functions):

- **Configs.** Every module of `Shared/Config` and `Shared/Rules` with `exportMeta()` (a plain JSON table of what the
  website needs) lands in `world.json` meta under its name with a lower-case first letter: today `meta.stageConfig`
  (the nine stages, `sneaking`, `playable`), `meta.worldConfig`, `meta.objectiveConfig` (every floor row, the city's
  included: `meta.objectives.floors` keeps the rows of the levels the world builds, with their candidates and places),
  `meta.difficultyConfig` (with `flasksPerStage`), `meta.gameConfig`, `meta.noiseConfig`, `meta.inputConfig` (the
  bindings by key and button names, touch buttons, contexts, Steer's axis), `meta.settingsSchema`,
  `meta.tutorialConfig` (the first-time hints), `meta.livesConfig`, `meta.radarConfig` and `meta.parkourConfig`.
  `meta.exportedConfigs` lists the keys.
- **Golden rows.** Every module with `golden()` (`LivesRules`, `RadarRules`, `ParkourRules`, and the later packages'
  rules) lands in `build/cache/golden.json` as `{ [moduleName]: [{ name, fn, args, expect }] }`: `expect` is what
  `module[fn](...args)` returns, as plain JSON (a Luau nil field is absent; numbers are the exact doubles, so a port
  that does the same operations in the same order matches exactly). The website's port of a module replays every row.

## world.bin streams (`meta.streams[name] = { offset, length, type }`)

| stream | type | per | coding |
| --- | --- | --- | --- |
| `pos` | u16 ×3 | vertex | quantised in the chunk box (`chunk.quant` = origin xyz, step xyz), delta-coded per chunk |
| `nrm` | i8 ×3 | vertex | normal × 127 |
| `uv` | i16 ×2 | vertex | uv × `chunk.uvScale` (default 64 = 1/64 stud; decals and wear 8192), delta-coded (u16 wrap) |
| `col` | u8 ×3 | vertex | part colour (sRGB) |
| `lit` | u8 ×3 | vertex | baked light, `255 * sqrt(L / 4)`, delta-coded (u8 wrap) |
| `flk` | u16 | vertex | flicker group id (0 = steady; ids are world-wide, up to `FLICKER_GROUP_LIMIT` 65535) |
| `fsh` | u8 | vertex | that group's share of the vertex's light (0..255) |
| `idx` | u16 | index | per chunk, triangles coded as (a − previous a, b − a, c − a), u16 wrap |
| `bone` | u8 | vertex | creature chunks only: bone index (`chunk.boneOffset`) |
| `cpos` | u16 ×3 | collision vertex | per level quant (`collision[level].quant`), delta-coded |
| `cidx` | u32 | collision index | triangle-delta coded, u32 wrap |
| `alpha` | u8 | vertex | transparent chunks only: 1 − Transparency (`chunk.alphaOffset`) |
| `probe` | u8 ×3 | probe | sqrt-encoded like `lit`; base grid, then one extra grid per scripted group reaching the level |

`decodeWorld(meta, bin)` undoes all of this. It returns `{ meta, chunks, collision, probes }`, where:

- each chunk's `attributes` hold `position` (f32), `normal` (i8 normalized), `uv` (f32), `color` (u8 normalized),
  `bakedLight` (u16 normalized = linear light ÷ 4, so the shader computes `bakedLight * 4.0`), `flicker` (u16
  (group, share) pairs from `flk` and `fsh`, not normalized) and, where they apply, `alpha` (u8 normalized),
  `skinIndex` and `skinWeight`;
- `chunk.index` is u16;
- each attribute is `{ array, itemSize, normalized }`, ready for `THREE.BufferAttribute`.

## Chunks (`meta.chunks`)

| field | meaning |
| --- | --- |
| `kind` | `static` (world space), `entity` (world space at rest, see Entities), `creature` (rig model space, rest pose) |
| `level` | `Lobby`, `Level0_Basement`, `Level1_Hallways`, `Level2_Auditorium`, `Level3_Roof`, `Stairwells`, `Exterior` (street + skyline), `Creature` |
| `bucket` | `opaque`; `transparent` (glass / water / bulbs; per-vertex `alpha`); `emissive` (Neon: self-lit in its colour × its flicker); `decal`; `wear` |
| `material` | key into `meta.materials` |
| `aabb` | min xyz, max xyz |
| `detail` | static and decal chunks of decorative parts only: their `Detail` level 1..3 (absent: always drawn) |

Static chunks are split per level × bucket × material × Detail level (one 400-stud cell, so a level is one cell: cull
per level). There are about 530 chunks in all.

**Detail (the low graphics settings).** Builders mark purely decorative parts with the Roblox attribute `Detail`
(Attributes.World.Detail): 1 shapes a room's look (the tunnels' mains and cable trays, corpses, service pipes, lore
graffiti), 2 medium (branch pipes and conduits, pipe markers, steam vents, grates, puddles, clutter, decay), 3 small
(debris, rubble, bands, hangers, tags, crumbs). Such a part never collides, is never queried or touched, and carries
no gameplay; collision and navigation geometry never carries the attribute (the collision buffer and every collider
come from colliding parts only). Their geometry and decals are baked into chunks of their own with `chunk.detail`,
so a setting may skip every chunk with `detail >= n` without changing the map, physics, hitboxes or mechanics.
Navigation landmarks (junction plates, region and keep-room stencils, EXIT arrows), signage, lights and every entity
are never Detail.

Faces buried in other solid static parts are culled. Large faces are subdivided where light varies:

- 2.4 studs under lights;
- 5 studs where the light is even;
- 8 studs where the face is dark;
- 8 or 16 studs outside.

### Buckets

- **`decal`:** SurfaceGui signage rendered to `textures/decals_N.webp` (RGBA). This covers lobby signs, room
  plates, wayfinding, STAIRS, chalkboards, notices, posters, wet-floor and caution signs, hazard stripes, locker
  numbers, flask labels and EXIT letters.
  - Text is drawn as laid out, nothing random: PatrickHand (chalkboards, graffiti, landmarks) in Patrick Hand itself
    (`@fontsource/patrick-hand`), the other Roblox families in the stand-ins `tools/bake/decals.mjs` lists.
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

`meta.textures[id]` holds `{ studsPerTile, reference, maps: { color, normal?, orm? }, tiers }`, with paths relative
to `build/`. `tiers[size].maps` are the graphics tiers' texture sets (`maps` is the 1024 set); the engine takes its
images through the asset manifest, by texture id:

| set | tiers | color (lossy WebP q85, sRGB) | normal (lossless) | orm (lossless) |
| --- | --- | --- | --- | --- |
| 2048 | Max | 2048 px (generated at 2048: `generate.py --size 2048`) | 2048 | 1024 |
| 1024 | High, Medium | 1024 (the 1024 masters Roblox uploads) | 1024 | 512 |
| 512 | Low | 512 | none | none |
| 256 | Potato (the boot set) | 256 | none | none |

- `color`: multiply it by the vertex colour. The part colour was already divided by `reference`, as Roblox's
  MaterialVariant tint does.
- `normal`: R = x, G = y in the OpenGL convention; B is stored as 1 (normalize after perturbing).
- `orm`: G = roughness, B = metalness.

The page boots on the 256 set and streams its tier's set in the background (`src/engine/textures.js`).

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
- **Flicker groups (`meta.flickerGroups[id]`):** `{ id, name, kind, level, family, initial, lights }`, indexed by id.
  - `kind` `flicker`: the Roblox FlickerGroup. The level is a pure function of (RunSeed or 1, name, server time),
    as in LightingController.
  - `kind` `scripted`: `Scripted:L1_Light_ClassroomGlow[Spill]` (die in the Floor 1 scare's burst) and the tunnel
    floors' steady circuits `Mains:<...>`.
  - **Power circuits (tunnel floors):** TunnelPlanner wires every run's caged bulbs in local circuits of up to four
    neighbours, each its own group: `Mains:L0_<Region>_<nn>` burns steady (`scripted`), a bad circuit
    `Circuit:L0_<Region>_<nn>` flickers (`flicker`); every keep-room is its own `Mains:<roomId>`. A teleport
    warning's flicker therefore touches only the bulbs near it, and the floor's power switch (floor0.js: every group of
    the level whose lights are all bulbs or fluorescents) holds them all down. All `Mains:` / `Circuit:` groups of one
    level form a family: a vertex lit by several carries its dominant one at their pooled share (so a dark floor is
    dark between circuits too), and the probes keep a family's light in one grid. Such a group's `family` is its
    level (else null).
  - **Ids are world-wide and 16-bit.** Every floor numbers its groups in one namespace of 65535
    (`FLICKER_GROUP_LIMIT`), so a light's or a vertex's `group` is all a reader needs: no (level, id) pairs, and a
    stairwell chunk lit by every floor's stairwell groups (or a floor lit through a door by the one below) needs no
    aliases. Names are unique world-wide (TunnelPlanner prefixes its circuits with the floor, `L0_`). The engine's
    flicker table `uFlickerData[id]` and texture (rows of 256: group `g` at texel `(g & 255, g >> 8)`) are sized from
    `flickerGroups.length`. The world has about 240 groups (Level 0: 118); data-test checks that they fit.
  - A vertex's light is `baked × (1 − share + share × level[group])`. Neon glow parts and self-lit decals have share
    255.
- **Probes (`world.probes[level]`):** `{ origin, dims, spacing: 4, data, groups }`, linear RGB irradiance, lit
  omnidirectionally (N·L = 1). Probe (x, y, z) is at `((y * nz + z) * nx + x) * 3`. Probes inside solids are filled
  from their neighbours.
  - `data` excludes the scripted groups. `groups` has one extra grid per scripted group that reaches the level
    (the classroom glow on L1) and one per power family (L0: every `Mains:` /
    `Circuit:` circuit's light, scaled by the family's first steady circuit). Add `level[group] × extra`.
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
- `ParachuteCrate`;
- `ReadyPad`, `Terminal`;
- `Barrel`, `Cabinet`: the tunnels' other hiding spots (HideBuilder; tag `Hideable`, attribute `HideKind`
  `Barrel` / `Cabinet`, lockers carry `HideKind` `Locker` too). Same attachments and Hide prompt as a locker. Most
  stand free in a niche: their anchor's `exit` puts the `ExitAnchor` 1.3 studs off the prop's Left (−X) or Right (+X)
  side, looking out that way (a side the Creature may not be standing on); the rest step out at the front;
- floor objectives (see "Floor objectives" below):
  - items: `Fuse`, `MasterKeys`;
  - stations: `BreakerPanel`;
  - `ExitLock` (one per exit candidate of a floor with a lock step, floors 0-1, on its fire door).

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

**Vent grate looks.** Every `VentGrate` is built in two looks over the same boxes (VentGrateBuilder): galvanized, in
its own nodes (`""`: the frame and the lower knuckle; `Panel`; `Screw1`..`Screw4`), and rusted shut, in each of those
nodes' `Rusted` sub-node (`Rusted`, `Panel/Rusted`, `Screw1/Rusted`, ...: the same boxes in corroded metal, plus weld
beads along the latch and head seams and a rust streak on `Panel/Rusted`, none of them colliding). Each `Rusted` node
pivots where its node rests and has the same colliders. The export shows both looks (its `GrateState` and prompts are
the export seed's). Per run: a grate in the plan's `lockedGrates` is `Locked` (both prompts read "Rusted shut") and
shows its `Rusted` nodes, hiding the galvanized ones; every other grate shows the galvanized look; never both, and a
leaf's two nodes are always posed together. (In Roblox VentGrateBuilder.setLocked does this at build.)

## Floor objectives (`meta.objectives`, objective entities)

Every floor's exit stays locked until its objective is done (ObjectiveConfig in
`src/ReplicatedStorage/Shared/Config/ObjectiveConfig.luau`). `meta.objectives` holds:

- `floors`: the rows of ObjectiveConfig.Floors whose level the world builds (every row, the city's two included, is
  `meta.objectiveConfig.floors`; per floor: `floor`, `levelId`, `id`, `title`, `item` {prop, candidate, count,
  guarded?, hold, object}, `stations` {prop, candidate, count, arcs?} (floors that pick their stations), `mainStation`,
  `steps` [{id, count, label, kind (Find, Deliver, Work, Stations, Survive, Reach), at?, seconds?}], `lockStep`,
  `lockVariant`, `lockReason`, `holds` by prompt kind);
- `hideReach` (25): how close a hiding spot is to every step;
- `stand`: the guard traps' rules. The fairness rule (ObjectivePlaces.standingSpot): a guarded item is taken from a
  spot `near` (1.6) to `reach` (4) flat studs off it, at least `trapClear` (2.5) from every TrapCandidate a run may arm,
  the body (`body` 1, from `step` 1.6 to `bodyHeight` 5.2 over the floor) clear and the item in sight of the eye (`eye`
  4.5), walked to from a doorway of its room without the foot ever within `panReach` (half a pan's diagonal) of a
  trap. The guard rule (ObjectivePlaces.carelessWalk): the careless walk in, the shortest walk from `approachRun` (8)
  studs back beyond the item's arrival doorway to the first point where its Pickup prompt answers (`promptReach` 7
  from the root, `eye` - 1.5 over the floor), passes within `panCore` (half a pan's side: on the pan at any yaw) of
  its guard;
- `rules`: the fairness and spread rules of the item picks: `entryClearance` (35: studs walked from the floor's
  entry to every candidate), `pickSpacing` (25: studs between two items of one run, horizontal), `pickQuarters` (2:
  three items lie in at least this many quarters of the floor), `pickAttempts` (24: re-shuffles tried), `footprint`
  ([400, 288], `WorldConfig.FootprintSize`: the quarters split it at its centre);
- `levels[levelId]`: `entry` {room, pos (level-local, the centroid of the entry room's PlayerSpawn anchors)},
  `candidates` [{anchorId, room, slot, ref, pos (level-local), planned, entryDistance (studs walked from the entry,
  ObjectivePlaces.walkDistance: door to door across rooms, through the vents a squad can always use, every Gate shut
  and every lockable grate locked), quarter (1 NW, 2 NE, 3 SW, 4 SE), hide {kind, id, distance}, eligible (a run may
  use it: every exported candidate is), stand (guarded items: {pos (level-local, on the floor), reach, trapClear, path
  (level-local [x, z] points: from just inside a doorway of the item's room, every turn, the spot)}), careless
  (guarded items: {door (the arrival doorway: the one the squad reaches first, on foot and crawling alike), walks (one
  per way that doorway's open leaf may hang, a plain doorway one: level-local [x, z] points from the start beyond the
  doorway, every bend round the jambs and what stands in the room, to where the prompt first answers), guardGap (the
  farthest any walk passes from the guard's centre)})}], `picks` (the
  export seed's RunDirector picks: `anchors` in pick order,
  `guards`), `places` (every candidate, station and lock with its nearest hiding spot: `hide` {kind Locker / Vent /
  DarkCorner, id, distance}). The Auditorium's interim floor (ObjectiveConfig `ReachExit`: no item, no lock) has
  an entry and no candidates, picks or places.

| Floor | Item candidates (brief minimum) | Where |
| --- | --- | --- |
| 0 | 14 `Fuse` (12), each with a guard trap spot `L0_TrapGuard_NN` / `L0_TrapGuard_TNN` (its `ref`) on its careless walk in (`careless`) and a standing spot clear of every trap spot (`stand`) | eight in the keep-rooms (the coal heap's front, the cage's shelving, the workbench, by the boilers, past the pumps, before the switchgear), six on the back-wall shelves of tunnel guard bays (9 x 8 niches, the trap in the mouth toward the side the squad comes along the run from) |
| 1 | 14 `MasterKeys` (9), all west of the gate | ten on hooks in tunnel niches west of the gate (TunnelPlanner items, `wall`), two in the janitor's closet, two in the main office |
| 2 | none (reach the east stairs) | the interim Auditorium storey |

Objective entities carry attributes `Floor` (0-5, `StageConfig`'s dense floor), `Step`, `ObjectiveId` (= the entity
type), `LevelId`, `AnchorId` (the entity id), and tags `ObjectiveItem` / `ObjectiveStation` / `ExitLock`.

- **Items** are exported for every candidate, not just the export seed's picks: attribute `Planned` says which ones
  the export seed uses; hide the others and pick per run with RunDirector.pickObjective's rule. One stream per level,
  `Rng.seeded(seed, "Objective|" + levelId)`, over the level's candidates in layout order (all eligible):
  - one item (the master keys): `shuffle(candidates)`, take the first;
  - several items, up to `pickAttempts` passes on the same stream: fuses `shuffle(candidates)` and take, in that
    order, each candidate in another room than the items taken so far and at least `pickSpacing` from each of them,
    until `item.count`. A pass stands when it is full and its three items lie in at least `pickQuarters` quarters;
    otherwise the next pass reshuffles (if none stands, the first fullest pass is used);
  - the basement arms the guard trap (`ref`) of the first two fuses picked.
  Item attributes add `Candidate` (the anchor kind; an item is the prop any run builds on its anchor,
  RunDirector.objectiveProp). Attachments `Grip` (the hand) and `PromptPoint` (a disabled `Pickup` prompt with the
  item's hold).
- **Stations** (nodes = their leaves; each leaf's rest pose is attachment `<Leaf>Rest`):
  - `BreakerPanel`: nodes `Door` (built open, `DoorOpen`), `FuseSlot1..3` (attachments `FuseSlot<i>Seat`: pose a
    fitted fuse so its `Grip` lands there; `FuseSlot<i>Prompt` with a FitFuse prompt, `Slot` i), `Lever` (Breaker
    prompt on `LeverPrompt`; ON is a rotation of `LeverThrow` = 110 degrees about the lever's X axis).
- **ExitLock**: on the exit airlock door's shut leaves (the doors are exported open: close them at run start), with
  `LockVariant` Padlock (L1: node `Padlock`) or Keypad (L0: node `Bar`), `Locked` true, `DoorId` (the door entity's
  id), a `Locked` prompt (hold 0, ActionText "Locked — <reason>") and on L1 an `Unlock` prompt, all on `LockPrompt`.

## Routes: random exits (`meta.routes`, `meta.routePairs`, `meta.routeRule`)

Every floor pair of the four-level school (0→1, 1→2, 2→3; `worldConfig.LevelOrder`) has **three candidate
stairwells**, one per stair tower on its side wall: slot `North` (towers `NorthWest` / `NorthEast`, Z -4..28, opening
at z 12), `Middle` (`West` / `East`, Z 64..96, opening at z 80) and `South` (`SouthWest` / `SouthEast`, Z 132..164,
opening at z 148). East side: 0→1, 2→3; west side: 1→2. A run uses one per pair; **the other two are jammed** for that
run. `meta.stairwells` lists all 9 (`id, pair, slot, tower, from, to, fromRoom, toRoom`; middle ones first) and
`worldConfig.Towers` all six (`minX, maxX, minZ, maxZ, side, openingZ`).

| Pair | North | Middle | South |
| --- | --- | --- | --- |
| 0→1 | `Stairwell_0_1_North`: `L0_AirlockNorthEast` → `L1_AirlockNorthEast` | `Stairwell_0_1`: `L0_AirlockEast` → `L1_AirlockEast` | `Stairwell_0_1_South`: `L0_AirlockSouthEast` → `L1_AirlockSouthEast` |
| 1→2 | `Stairwell_1_2_North`: `L1_AirlockNorthWest` → `L2_AirlockNorthWest` | `Stairwell_1_2` (West) | `Stairwell_1_2_South`: `L1_AirlockSouthWest` → `L2_AirlockSouthWest` |
| 2→3 | `Stairwell_2_3_North`: `L2_AirlockNorthEast` → `L3_RoofAccessNorth` | `Stairwell_2_3`: → `L3_RoofAccess` | `Stairwell_2_3_South`: `L2_AirlockSouthEast` → `L3_RoofAccessSouth` |

- **`meta.routes[from]`** (the shape `worldData.routeCandidates` consumes): the floor's exit candidates in slot order
  North, Middle, South, each `{ id = stairwellId, stairwellId, pair, slot, tower, from, to, fromRoom, toRoom,
  exitDoorIds, entryDoorIds, checkpoint, spawns, exitLock, creatureSpawn, picked }`: the fire door between the floor
  and the exit vestibule, the upper floor's entry door (a fire door, or on the roof the housing's `RoofStairDoor*`),
  the exit vestibule's Checkpoint trigger id, the upper vestibule's PlayerSpawn anchor ids (sorted: slot 1 first),
  the ExitLock entity id on the exit door (none on a floor without a lock step), the housing's CreatureSpawn anchor (roof only) and
  whether it is the export seed's pick.
- **`meta.routePairs`**: `[{ pair, from, to, candidates: [ids], picked }]` (`picked` = RunDirector's route for the
  export seed; `plan.route` holds the same as `{ [from]: id }`).
- **`meta.routeRule`** = RunDirector.pickRoute: for each floor in climbing order, `Rng.seeded(seed, "Route|" +
  from)`; draw `NextInteger(1, 3)` over the candidates in slot order; keep the draw if it is **fair** for the floor's
  entry, else draw again from the same stream, up to `attempts` (8) draws, then take the first fair candidate in slot
  order (else the middle one). The entry is the basement's layout entry, then each pick's `toRoom`. Fair: its exit
  vestibule is at least `fairShare` (0.6) of the longest candidate's walk from the entry (the floor's door / vent walk
  graph, worst case: gates shut, lockable grates locked), and on `creatureSpawnLevels` (`Level2_Auditorium`) the next floor
  keeps at least `minCreatureSpawns` (2) Creature starts (PatrolWaypoint / CreatureSpawn anchors) `creatureBand`
  (70-140) studs walked from that candidate's entry vestibule, outside it and the rooms its doorways open into, and
  outside every objective room (stations and every item candidate's room, whatever a run picks). The verdicts are
  precomputed: `routeRule.checks[from][entryRoom]` = `[{ stairwellId, distance, share, creatureSpawns, fair }]` for
  every way in (the layout entry and each entry vestibule candidate), so a port only needs the draws. Today every
  candidate is fair from every way in (shares 0.78-1.00).
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
  once), 4 PlayerSpawn anchors on entry vestibules, an ExitLock anchor on every exit candidate's fire door (L0-L1) and
  a hideable locker within reach of each new lock. Each roof housing has its `RoofStairDoor` /
  `RoofStairDoorNorth` / `RoofStairDoorSouth` (ScriptedId), a CreatureSpawn behind it (`L3_CreatureSpawn`, `_North`,
  `_South`), 4 PlayerSpawns, the same lamps, and the tower below it.
- **Floor changes for the corner vestibules:** the corner rooms shrank (their side-wall windows went); L0's south-east
  vestibule opens off `L0_Store_E2` (the condemned store stays boarded); L1's open off the outer halls (its west ones
  inside the sealed west half); the interim L2's six vestibules stand at the ends of its corridors.
- **Bear traps, chemical flasks, batteries:** one entity on every candidate anchor a run may pick (every TrapCandidate
  outside the trap-free rooms, every FlaskCandidate (none in the four-level school until flasks are placed again),
  every BatteryCandidate), each exactly the prop a live run builds
  there (a prop's stream and its variant are its anchor's, never the run's: Builder.propRandom, RunDirector.variantOf);
  `Planned` is true on this seed's Standard picks. `worldData.plan` replays RunDirector's draws (`Traps|`, `Flasks|`,
  `Batteries|` streams of the run seed) and shows the entities on its picks. `worldData.variantOf` is
  RunDirector.variantOf (`Rng.seeded(1, "Variant|<kind>|<level>|<anchor>")`, 1..1000000): a chemical flask carried,
  thrown or drawn in a teammate's hand is drawn by `flaskFx.js` from its anchor's variant, with ChemicalFlaskBuilder's
  look (`lookOf` on the same `Rng`: fill line, crack) and liquid colour, so it is the flask the world built there.

## Creature (`meta.creature`)

The Tall Man (CreatureRigBuilder): an 11-stud shadow figure with a porcelain mask.

- **Bones:** `bones[i] = { name, parent, motor, rest, size }`. Bone i is `skinIndex` i. `rest` is the bone part's
  CFrame in model space; the rig is built at the origin facing −Z, HumanoidRootPart at y 4.7.
  - 41 bones: the R15 set plus `Jaw` (the mask's hinged chin), the jointed fingers `<Side>Index`, `Middle`, `Ring`,
    `Pinky`, `Thumb` (each a Motor6D from its Hand), and the tatter chains `Hair<N>_<M>` hanging from the Head.
  - The `Neck` pivot is the top of the long neck: the skull turns on it. The neck column rides the UpperTorso.
- **Joints:** `joints` are the Motor6Ds: `{ name, part0, part1, c0, c1 }`. A joint's transform applies as
  `part1 = part0 * C0 * T * C1⁻¹`.
- **Geometry:** `chunks` are the creature chunks (skinned), one per material:
  - `SmoothPlastic`: the shadow body (near-black, faint sheen), skull, tatters and fingers;
  - `Marble`: Roblox's porcelain mask: the shell (`Mask` and `MaskBrow` on the Head, the `Jaw` ball and its `Chin`),
    the relief parts (`Relief<Name>`) and the jagged `MawShard<N>` hidden inside the shell;
  - `Neon`: the two pinprick pupils on the mask's surface;
  - `Fabric`: the mask's detail drawn in parts for Roblox (eye-hole discs, slit strips, split caps and the black
    sleeve, the chip, crack strips `MaskCrack<N>` with attributes `CrackFrom` / `CrackTo` / `CrackWidth`, streak strips
    `MaskStreak<N>` with `StreakFrom` / `StreakTo` / `StreakWidth`: their face-frame ends and widths).
  - The website hides the Marble, Fabric and Neon chunks and draws its own sculpt of the mask (look.js / mask.js: a
    dense two-piece mesh on the Head and Jaw bones, built at load from the Mask part's attributes) and paints the same
    detail on it (the cracks and streaks from those attributes). The invisible grime cards (`MaskGrimeLeft/Right`,
    Transparency 1, with a SurfaceGui Roblox draws) are not baked.
  - See `docs/MONSTER-LOOK.md` for the joints, actions, timings and tiers both platforms share.
  - The bake tessellates the creature's balls and cylinders finer than the world's (about 0.07 studs per segment,
    up to 40), since the mask fills the screen in a jumpscare.
- **Metrics** (CreatureRigBuilder.Metrics; what the behaviour reads):
  - `height` (11): standing, floor to the crown;
  - `hunchedHeight` (9): bent under a 10-11 stud ceiling;
  - `eyeHeight` (10.34): the standing eyes over the floor; `eyeHeights` per PoseMode over the floor (`Biped`,
    `Hunched`, `Quadruped`); `eyeHeightAboveRoot` per PoseMode over the root centre;
  - `reach` (4): how far from its root a catch reaches;
  - `rootHeight` (4.7), `armLength` (6.3);
  - `hitboxes[poseMode] = { size, offset }`: the CreatureHitbox per PoseMode, `offset` its CFrame relative to the
    root (Biped 2.6 × 11 × 2.7, Hunched 2.6 × 9 × 4.2, both standing on the floor and pushed forward over the jutting
    head).
- **Mask:** the `Mask` part's `attributes` hold the mask both platforms draw, in the face frame (FaceFrontAttachment:
  x right, y up, z back, origin between the pupils, studs): `EyeX`, `EyeHoleWidth`, `EyeHoleHeight`, `EyeHoleDepth`
  (the bores), `PupilGlowRadius`, `PupilScaleRight`, `SlitY`, `SlitHalfWidth`, `SlitUpturn`, `MaskTop`, `ChinY`,
  `MaskDepth`, `ChipAngle`, Roblox's shell sizes `MaskRadius`, `MaskAxisZ`, `ChinRadius`, and the sculpt as strings
  and vectors (CreatureRigBuilder.MaskShape): `MaskOutline` "y:left:right;..." (the outline's half-widths, top down),
  `MaskProfile` "y:z;..." (the centreline's depth), `MaskRelief` "Name:x:y:rx:ry:height:tilt;..." (the relief's bumps,
  studs toward the viewer, negative hollowed), `ChipCentre` / `ChipRadius` (Vector2: the broken-off piece of the rim).
- **Smoke anchors:** `attachments` named `Smoke*` (the shoulders, elbows, every fingertip but the thumbs, the back,
  the back of the skull, and the shroud's: the chest, the flanks, the hips, the thighs), each on a jointed part, with
  attribute `SmokeWeight` (its share of the wisps); the shroud's also carry `SmokeShroud` true (heavy, sinking smoke).
- **Other data:**
  - `parts`: every rig part, with its bone, size and attributes (the hitbox and HumanoidRootPart included);
  - `lights`: none;
  - `attachments`: the FaceFrontAttachment and the smoke anchors;
  - `hipHeight`;
  - `config`: CreatureConfig (the rig block, speeds, senses, hitbox sizes per PoseMode, eye offsets).

## World layout data

| field | contents |
| --- | --- |
| `levels[key]` | `{ origin, elevation, height, aabb, film }` |
| `rooms` | world rects (`x, z, w, d`), floorY, height, kind, acoustic, ambience, floor / wall / ceiling keys. Kind `Yard`: open to the sky; kind `Gap`: an alley, its deck `drop` below the level (its zone carries attribute `Drop`), no floor for the Creature |
| `zones` | the Zone volumes (cframe, size, roomKind, acoustic preset, surface) |
| `anchors` | every layout anchor: PlayerSpawn, CreatureSpawn, CreatureScarePose, PatrolWaypoint (+ `loop`, `order`), Trap / Flask / BatteryCandidate, ParachuteCrate, Locker, Corpse, ... (`cframe`, `room`) |
| `patrolLoops` | `[{ level, loop, waypoints: [{ id, room, pos }] }]` in walking order (the last leads back to the first) |
| `triggers` | ScareStep, FloorDebris, Checkpoint, LevelExit volumes (`cframe`, `size`, `attributes`) |
| `doors` | layout door anchors (Door / Ajar / Gate / Airlock / RoofDoor: cframe looking into the next room, width, height, scriptedId) |
| `layoutDoors` | every layout door incl. Boarded / Doorway, level-local, each with `clearance` (studs of head room: the lintel or the lower ceiling either side, minus the panel) and `crawlOnly` (a crawlway's mouth) |
| `zoneGraph` | `ZoneGraph.build` output: `nodes`, `edges`, `adjacency` (rooms + portals); door edges carry `clearance` and `crawlOnly` (the Creature never takes a crawl-only edge, nor one under 9; it hunches under 12.5) |
| `visibility[level][zoneId]` | the potentially visible set: the zone ids a player in that zone may see (itself and its neighbours through any opening included), sorted; see below |
| `visibilityInfo` | `{ maxDistance, method, levels: { [level]: { zones, pairsTested, rays, meanVisible } } }` |
| `teleportPoints[level]` | tunnel floors: `[{ pos (world), facings, region, zone }]`, on the tunnel and gallery centrelines every 6 studs, never in a crawlway or a doorway (the Creature's teleport candidates) |
| `landmarks[level]` | tunnel floors: `[{ id, kind, region, room, pos (world), normal, text }]`: `JunctionPlate` ("J-07"), `RegionSign` (region and keep-room stencils), `Arrow` (EXIT), `Lore`, `Tag`, `Tally` |
| `regions[level]` | tunnel floors: `[{ id, name, zones, junctions, pipe, band, wet, medium }]`, 4..6 named regions (zones: their rooms, junctions: their plates) |
| `vents.graphs[level]` | `VentGraph.build` output: `nodes` (positions, links, grateId), `grates` (wall CFrame, mouth, lockable, criticalPath), `grateAtNode`, `segments` |
| `vents.nodes`, `vents.grates` | the raw VentNode / grate attachments |
| `stairwells` | WorldConfig.Stairwells: all 15 candidates (`id, pair, slot, tower, from, to, fromRoom, toRoom`), see "Routes" |
| `worldConfig` | WorldConfig as data |
| `windows` | the moonlight window specs (Volumetrics.windowSpecs) |
| `emitters` | the particle emitters the web draws (`src/engine/particles.js`): `[{ id, kind: 'Steam', level, pos, dir, detail }]`, one per SteamVent nozzle (TunnelDressingBuilder) at its `Mouth` attachment, `dir` the plume's way (the mouth's look vector). Decorative only |
| `plan` | the director's plan for the seed (props, lockedGrates, objectives, route; spec v2's `batteries` per sneaking stage `{ anchors (pick order), broken }` and `flasks` per stage, see "Spec v2's picks") |
| `creatureBlocks` | `[{ level, door, cframe, size }]`: the invisible walls across every opening into a Gap (CollisionGroup `CreatureBlock`); the Creature clamps to them, a player never collides with them (the bake leaves them out of the collision buffer). None until a floor has a Gap |
| `layouts` | the raw layout blueprints, level-local as authored |
| `film.levels[key]` | LightingMood.film (exposure, contrast, saturation, lift, bloom, Atmosphere density / offset / haze / glare / colour / decay, sun rays, DOF, vignette, shafts, dust, moon). `film.base` is the base film; `film.levels.Outdoor` is the storm outside |
| `lighting` | `baseline` (LightingRig), `moods` (per level: cast, grade tint, revive, ...), `moonlight`, `fixtureCones` (haze-cone shapes per light kind), `bakedAmbient`, `falloff` |
| `palette` | Palette keys: material, colour, surface, texture |

**Potentially visible sets (`meta.visibility`).** Computed offline in the bake (`tools/bake/pvs.mjs`): for every pair
of zones of a level (layout rooms; a tunnel floor's Solid fill is no zone) within `maxDistance` (300 studs) of each
other, rays between their samples (points across each of their openings at crouched and standing eye height, a step
inside the zone, plus a 6-stud grid over the floor at eye height) against the static structure (colliding, opaque,
non-glass static parts without `Detail`: walls, floors, ceilings, solid furniture). Doors and every other entity
count as open and glass as clear, so the set is conservative; one clear ray makes the pair visible both ways. A
renderer may skip whatever lies in zones outside the camera zone's set (dynamic lights, entities, particles,
decorative chunks); static chunks are one per level, so the engine sorts each one's triangles by the zone they face at
boot (`src/engine/pvs.js`) and draws only the visible zones' ranges.

## Tunnel floors

Levels 0–2 (the basement, the hallways, the science wing) are built by TunnelPlanner (docs/MAPS.md): their rooms are
kind `Tunnel`, `Gallery`, `Crawlway` (culverts only a crouched player fits: their mouths are `crawlOnly`, `clearance`
4.3), keep-rooms (the floor's scripted rooms: `Storage`, `Boiler`, `Office`, `Classroom`, `Corridor`, `Lab`,
`Airlock`) and `Solid` fill (no zone, kept in `layouts` only). Alcoves are `Tunnel` rooms. The planner's data rides
in `layouts.<level>.tunnels` (graph, segments, regions, landmarks, rules, stats) and, ready to use, in
`teleportPoints`, `landmarks`, `regions`, `visibility`, `layoutDoors` / `zoneGraph` flags and the Barrel / Cabinet
(and, on Level 1's Locker Banks, Locker `L1_Locker_Tnn`) entities above. A keep-room's lights are `Mains:<roomId>`;
Level 1's hallway keeps its scripted classroom glow (`Scripted:L1_Light_ClassroomGlow[Spill]`) and its gate's
bypass vent (`L1_Grate_CorridorEast` / `L1_Grate_CorridorWest`, never locked, `criticalPath`): with the gate down,
the vent is the only way west, and the walk graphs (TunnelRules, ObjectivePlaces, the routes) walk it.

## Spec v2's picks (`meta.plan.batteries`, `meta.plan.flasks`, run-plans.json)

RunDirector's new picks ride in the plan beside today's props, each on its own `Rng` stream, so today's picks never
move (the props, objectives, grates and routes replay as before):

- **Radar batteries** (`batteries[level]`, every sneaking stage: RunDirector.pickBatteries): up to RadarConfig's
  `BatteriesMax` (9 [7]) BatteryCandidate anchors in pick order, from `Rng.seeded(seed, "Batteries|" + level)`
  shuffling the candidates in layout order; a squad of n uses the first `RadarRules.batteriesPlaced` (6 [4] + 1 per
  extra player). The first lies 20-60 studs walked from the entry (the route's entry vestibule), the second within 40
  walked of the floor's main station (ObjectiveConfig `mainStation`; the exit lock of the route's exit, the run's
  feeders, or the exit when the floor names none), every pair 30 walked apart, none in a dead end (a room with fewer
  than two ways in or out). Walks are on the objective rules' walk graph (TunnelRules: doors, crawlways, the vents a
  squad can always use; Gates shut). Each slot takes the first shuffled candidate that keeps its rules; a floor that
  cannot degrades to the candidate breaking the fewest rules, then the lowest id, and `broken` counts the rules broken.
  Today's floors have 6 to 13 candidates (36 come with the school's content package), so they degrade; the battery
  props a run shows are still today's (`props`, `Batteries|` picks of `batteriesPerLevel`).
- **Stun flasks** (`flasks[level]`: RunDirector.pickFlasks): DifficultyConfig `flasksPerStage` (3, 3, 2, 2, 2
  [2, 2, 1, 1, 1]) FlaskCandidate anchors from `Rng.seeded(seed, "Flasks|" + level)`, in pick order. None while the
  floors have no FlaskCandidate (data-test then expects no flask entity; with candidates it expects some).
- **Feeders** (`objectives.City1_Rooftops`, once the rooftops have a layout: RunDirector.pickStations): 3 of the 6
  FeederCandidate anchors from the objective's stream `Objective|City1_Rooftops`, at least one north and one south of
  the frame's centre line.

## Known differences from a live server

- None in the world itself: every seeded choice of the builders, the layouts and RunDirector draws from
  `Shared/Util/Rng` (pure Luau, the same numbers in Lune and on Roblox), and everything built is seeded from the
  builder's world seed, never a run's, so the export is part for part what a live server and its clients build (see
  docs/ARCHITECTURE.md, "One world on both platforms"). Run plans: worldData's port draws from the same generator
  (`Rng` in src/game/util.js; `seededRandom` there is the runtime's own mulberry32, for pacing), so a seed picks the
  same objective spots, traps, flasks, batteries, locked grates and exits as a live server.
- The runtime's own randomness (flicker, blackouts, beats, the Creature's spawn and growls, fake-out lockers) is each
  platform's: the same stream keys, not the same numbers.
- Model pivots: an entity's `pivot` is the stored `Model.WorldPivot`; Roblox pivots a model that has a `PrimaryPart` on
  that part (`GetPivot()`), so the two differ for doors, stations, grates and hides (unverified in Studio).
- The client-only light shafts, dust and lightning are not baked; the engine draws them. Moonlight is baked from every
  window, where the Roblox client lights only the nearest few.
