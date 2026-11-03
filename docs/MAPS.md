# Rovloc — Maps

How a floor's map is made: the tunnel planner, its rules, and how to author a floor with it. Level 0 (the basement)
is the worked example. The legacy floors (Levels 1–5) are still hand-laid `LayoutSchema` blueprints and keep their
old rules until they are rebuilt on this foundation.

| File (`src/ReplicatedStorage/Shared/World/ProceduralWorldBuilder/`) | What it is |
| --- | --- |
| `TunnelPlanner.luau` | The planner: keep-rooms, ports, barriers, style and regions in; LayoutSchema rooms, doors, anchors, triggers, platforms and `tunnels` (TunnelData) out. Deterministic. |
| `TunnelRules.luau` | The measures and rules every tunnel floor must pass (`LayoutSchema.validate` runs them), the walk graph, teleport points. |
| `Layouts/Level0_Basement.luau` | The basement: its keep-rooms, the planner spec, keep-room furniture, lights and anchors. |
| `Props/TunnelDressingBuilder.luau` | The tunnels' dressing: pipes, trays, steam vents, markers, grime, landmarks, floor clutter (all decor, `Detail` 1..3). |
| `Props/HideBuilder.luau` | Barrels and cabinets (hiding spots beside the lockers). |
| `tests/Specs/TunnelPlanner.spec.luau` | The planner's specs: the rules on every tunnel floor, determinism, crawlways, plates, teleport points, hides. |

## 1. The footprint and the towers

Every floor is **400 × 288 studs** (`WorldConfig.FootprintSize`; the legacy floors keep `LegacyFootprint` 240 × 160).
The three stair towers stand against the east wall; their openings on each floor are near **z 28, 144 and 260**
(north, middle, south). A floor's exit candidates are three vestibules (`Airlock` rooms) on those openings; the run's
route picks one and jams the others.

## 2. Authoring a floor

A floor is a Lua module that builds its keep-rooms, calls `TunnelPlanner.plan(spec)`, merges the plan, then adds the
keep-rooms' own furniture, lights and anchors. The spec:

| Field | Meaning |
| --- | --- |
| `keepRooms` | `{ room, ports, region?, sign? }`: the hand-made rooms the game needs (arrival, objective rooms, exit vestibules). A **port** is a door on one wall (`side` N/S/E/W, `at` its centre along that wall, `kind`, `width`); a grid line runs through it and a straight stub joins it to the first crossing on that line, so keep a port's line clear of other rooms. `sign` is stencilled beside its doors (leave it off vestibules: SignageBuilder puts STAIRS there). |
| `entry`, `exits` | The arrival keep-room, and the exit vestibules (route candidates). |
| `barriers` | Wall lines `{ x0, z0, x1, z1 }` no tunnel crosses. They fold the floor into one long walk; a corridor across one can only be a crawlway. |
| `gridX`, `gridZ` | The crossings' lines (else generated every `style.pitch`, jittered). Port lines are added. Keep a crossing's square (`max width / 2 + 2`) clear of the keep-rooms. |
| `crawlSites` | Pinned crawlways `{ x0, z0, x1, z1 }` between two neighbouring crossings (may cut a barrier); nil lets the planner pick them. |
| `style` | Tunnel widths and heights, galleries (`galleryWidth`, `galleryHeight` 14–16, `galleryShare`, `galleryMin`), `length` (target tunnel length), `deadEnds`, `crawlWidth`, niches (`alcoveWidth/Depth/Height` for item shelves, `hideAlcoveWidth/Depth` for hides, default 10 × 7), lights (`lightSpacing`, `deadShare` of bulbs, `flickerShare` of circuits, `plateLampEvery`), palette keys and acoustics. |
| `rules` | The TunnelRules thresholds (section 3); omitted fields use `TunnelRules.Defaults`. |
| `regions` | 4–6 regions `{ id, name, x, z, areas?, medium?, pipe, band, grime, paint, graffiti, wall?, floor?, wet? }`. A crossing belongs to the region whose `areas` rect holds it, else to the nearest seed `(x, z)` by walking distance (a region never jumps a barrier). `medium` is stencilled on the pipe markers. |
| `items` | Planner-placed items `{ kind, count, shelf, guard }`: on a shelf in an item niche, spread out, at least 60 studs walked from the entry, only where hide niches can serve them; `guard` adds a TrapCandidate just inside the niche (the item's `ref`). |
| `hideTargets` | More points that need a hide within `objectiveHideReach` (the vestibules). |
| `traps`, `batteries`, `clutter`, `corpses`, `drips`, `debris`, `scares`, `creatureSpawns`, `creatureBand` | Counts of the dressing anchors and triggers; creature spawns fall within `creatureBand` studs walked from the entry. |
| `attempts`, `crossingTarget`, `seed` | Thinning attempts (the one closest to the target crossing and length wins), and the seed. |

What comes out:

- **Rooms:** `Tunnel` (runs: one straight room each; niches are `Tunnel` rooms too), `Gallery` (the longest runs:
  wider, 14–16 high), `Crawlway` (culverts 4 wide, 4.8 high: only a crouched player fits; the Creature never enters)
  and `Solid` fill (the ground between, no floor or zone). Every tunnel-like room is `Tunnel` or `Gallery`: the AI
  treats every other kind as a keep-room.
- **Doors:** open doorways where runs meet (at a crossing one run owns the square, the others open into its sides),
  ports, niche mouths and crawlway mouths (`crawlOnly`, clearance 4.3).
- **Anchors:** Barrel / Cabinet hides, item candidates with guard traps, PatrolWaypoints (each region's junctions in
  a loop, long hops split so no two waypoints are more than 110 studs apart), CreatureSpawns, TrapCandidates,
  BatteryCandidates, Clutter, Corpse (against bare wall), DripPipe (clear of the ceiling bulbs).
- **Triggers:** FloorDebris and ScareStep across runs (never within 40 studs walked of the entry).
- **Lights:** caged bulbs every `lightSpacing` wired in local circuits (section 5), red emergency lamps at every
  `plateLampEvery`-th junction plate.
- **`tunnels`:** the graph (nodes: Junction / Turn / Pass / End / Port), segments, regions, landmarks (junction plates
  "J-NN" numbered by walking order from the entry, region stencils at region entrances, keep-room names, lore,
  tallies, tags, EXIT arrows), the rules and the planner's stats.

How it plans: a grid of crossings minus what hits a keep-room, an exclusion or a barrier; crawl sites cut first; the
corridors out of crawl reach cut and dead branches pruned; a loop repair (a junction without its loop loses one of its
arms); then thinning in a seeded order while the graph stays connected, every junction keeps a short loop, every
corridor stays within crawl reach and the crossing stays under its maximum, down to `style.length`. Then dead ends,
regions, runs, galleries, niches, items, hides (greedy cover), Solid fill, doors, lights, landmarks, anchors.

## 3. The rules (TunnelRules)

`LayoutSchema.validate` runs them on every tunnel floor; `TunnelPlanner.spec` asserts them.

| Rule | Default | Level 0 |
| --- | --- | --- |
| Connected on foot without any crawlway (every keep-room and vestibule) | — | yes |
| Every junction on a loop of at most `maxLoop` studs | 200 | longest 122 |
| Crossing: the walk from the entry to the farthest exit | 1100–1500 | 1650–1980 (1903) |
| With the crawlways (crouched, 5.5 studs/s) the crossing still takes `crawlCrossingSeconds` | 40 s | 55.5 s |
| Crawlways (count, length, mouth height) | 3–6, ≤ 20, 4.3 | 3–12: 11 |
| A crawlway mouth within `crawlReach` of every tunnel point | 60 | 58.2 |
| A hiding spot within `hideReach` of every tunnel point | 30 | 26.6 |
| A hiding spot within `objectiveHideReach` of every objective place | 25 | yes |
| Dead ends: count, length | ≤ 8, ≤ 25 | 3 (≤ 22) |
| Regions: named, distinct | 4–6 | 5 |
| Galleries 14–16 high; junction plates J-NN | — | yes |

Walking is 11 studs/s: Level 0 crosses in about 2.9 minutes.

## 4. Hiding spots

Lockers (keep-rooms), Barrels and Cabinets (the tunnels) share one convention (HideBuilder, LockerBuilder): tag
`Hideable`, attribute `HideKind`, attachments EntryAnchor / ExitAnchor / HideAnchor / PeekAnchor and a Hide prompt.
Most barrels and cabinets **stand free** in a hide niche (10 × 7): centred, 0.6 off the back wall, front to the run,
with clear floor on both sides; the anchor's `exit` (`Left` / `Right`) puts the ExitAnchor 1.3 studs off that side,
so a hider (or a teammate pulling them out) can come out on a side the Creature is not standing on. The rest (dead-end
drums, the few cabinets against a wide run's wall, the vestibule cabinets) step out at the front. Level 0: 99 hides,
91 freestanding.

## 5. Lights and power

- Every run's bulbs are wired in **circuits** of up to four neighbours, each its own flicker group: steady
  `Mains:<prefix>_<Region>_<nn>`, or a bad circuit `Circuit:<prefix>_<Region>_<nn>` that flickers (`flickerShare` of
  them). Each keep-room is its own `Mains:<roomId>`. So a flicker (the Creature's teleport warning dims the groups of
  the fixtures within 20 studs) stays local.
- The floor's power switch holds every bulb and fluorescent group down until the breaker is thrown (web
  `objectives/floor0.js`); the emergency reds, boiler glows and exit signs carry no group and always burn.
- The bake pools a level's `Mains:` / `Circuit:` light per vertex and per probe (see web/DATA.md), so a dark floor is
  dark between circuits too. The world may hold at most 255 groups (Level 0 uses about 125).

## 6. Dressing and Detail

TunnelDressingBuilder dresses every run: the region's painted mains, branch and conduit with paint bands and hangers,
markers naming the `medium` with a flow arrow, a cable tray on the other wall, steam vents (relief valves teed off the
main, a `Steam` ParticleEmitter, tag `SteamVent`; every stretch of the steam region, a few elsewhere), rust and water
runs down the walls, debris heaps (brick, block, cans, paper) off every doorway, anchor and trigger, puddles and drain
grates in wet regions, coal in the chutes, rubble at dead ends. Every piece is non-colliding, never queried or
touched.

**Detail.** Decorative parts carry the attribute `Detail` (1 shapes the look .. 3 small); a low graphics setting may
hide `Detail >= n` and nothing else changes. Collision and navigation geometry never carries it. Junction plates,
region and keep-room stencils and EXIT arrows are never Detail (players find their way by them). The bake keeps
Detail geometry in chunks of its own (`chunk.detail`).

## 7. Runtime data

The export and bake hand the web runtime (web/DATA.md):

- `meta.teleportPoints[level]` `{ pos, facings, region, zone }`: tunnel and gallery centrelines every 6 studs, never
  in a crawlway or doorway (the Creature's teleport candidates);
- `meta.landmarks[level]`, `meta.regions[level]`;
- `layoutDoors[].clearance` / `crawlOnly` and the zone graph's edges with the same flags (shut under 9, hunch under
  12.5, never crawl-only);
- Barrel / Cabinet entities;
- `meta.visibility[level][zoneId]`: the potentially visible set of every zone, computed offline by rays.

## 8. Checking a floor

```sh
tools/verify.sh                               # rojo, luau-lsp, selene, stylua, the Lune layouts / world / specs
cd web && npm run export && npm run bake      # world-raw.json -> world.json + world.bin (the PVS is baked here)
node tools/data-test.mjs                      # tunnel data, Detail chunks, visibility, hides, flags
npm run check                                 # the deliverable, the engine walk, perf (L1 and L0), screenshots
node tools/objective-run.mjs --floors L0      # the basement played: spawn, fuses, breaker, exit unlocked
```

When the planner fails or a rule does not hold:

- **"found no layout its crawlway sites can cover"**: some tunnel is more than `crawlReach` from every crawl mouth
  (check the far ends of stubs: a vestibule's stub counts), or a junction cannot keep a loop. Move or add crawl sites
  so every mouth sits on the walk, not on a spur.
- **Crossing too short / long:** move barriers (fold more or less), move the exits' band, or adjust `style.length`.
- **Hide reach:** hide niches need 8.5 studs of free ground beside a run; widen the gaps between runs or keep-rooms.
- **A STAIRS sign missing:** the vestibule's stub needs about 12 studs between its rail and the fire door (the
  door's swing and the doorway approach leave the rest); niches keep 11 studs (past their half width) from a
  keep-room's door.
- **Guard traps:** a keep-room fuse's guard stands 2–9 studs from it, in the same room.
- Render the plan to eyeball it: a dump of the layout's rooms, doors, anchors and lights drawn top-down (one of the
  maps' screenshots is exactly that).
