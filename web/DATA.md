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
- `ReadyPad`, `Terminal`.

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
| `stairwells` | WorldConfig.Stairwells (towers, from / to rooms) |
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
