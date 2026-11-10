# Rovloc — Maps

How a floor's map is made: the tunnel planner, its rules, and how to author a floor with it. Level 0 (the basement)
is the worked example; Level 1 (the hallways) and Level 2 (the science wing) are built the same way around their
scripted rooms. The legacy floors (Levels 3–5) are still hand-laid `LayoutSchema` blueprints and keep their old rules
until they are rebuilt on this foundation.

| File (`src/ReplicatedStorage/Shared/World/ProceduralWorldBuilder/`) | What it is |
| --- | --- |
| `TunnelPlanner.luau` | The planner: keep-rooms, ports, barriers, style and regions in; LayoutSchema rooms, doors, anchors, triggers, platforms and `tunnels` (TunnelData) out. Deterministic. |
| `TunnelRules.luau` | The measures and rules every tunnel floor must pass (`LayoutSchema.validate` runs them), the walk graph, teleport points. |
| `Layouts/Level0_Basement.luau` | The basement: its keep-rooms, the planner spec, keep-room furniture, lights and anchors. |
| `Layouts/Level1_Hallways.luau` | The street-level hallways: the checkerboard hall with Classroom 108's scare, the HallwayGate and its vent bypass, the janitor's closet, the main office. |
| `Layouts/Level2_ScienceHall.luau` | The science wing: Chem Prep 205 (the fume hood), Chem Lab 203 and Bio Lab 209 as bridges, the chem and specimen stores. |
| `Props/TunnelDressingBuilder.luau` | The tunnels' dressing: pipes, trays, steam vents, markers, grime, landmarks, floor clutter (all decor, `Detail` 1..3). |
| `Props/HideBuilder.luau` | Barrels and cabinets (hiding spots beside the lockers). |
| `tests/Specs/TunnelPlanner.spec.luau` | The planner's specs: the rules on every tunnel floor, determinism, crawlways, plates, teleport points, hides. |

## 1. The footprint and the towers

Every floor is **400 × 288 studs** (`WorldConfig.FootprintSize`; the legacy floors keep `LegacyFootprint` 240 × 160).
Three stair towers stand against the east wall and three against the west (`WorldConfig.Towers`); their openings on
each floor are near **z 28, 144 and 260** (north, middle, south). The climb zigzags: Level 0 leaves east, Level 1
arrives east and leaves west, Level 2 arrives west and leaves east, and so on. A floor's exit candidates are three
vestibules (`Airlock` rooms) on its exit side; the run's route picks one and jams the others. Its entry vestibules
stand on the other side, under the previous floor's exits.

## 2. Authoring a floor

A floor is a Lua module that builds its keep-rooms, calls `TunnelPlanner.plan(spec)`, merges the plan, then adds the
keep-rooms' own furniture, lights and anchors. The spec:

| Field | Meaning |
| --- | --- |
| `keepRooms` | `{ room, ports, region?, sign? }`: the hand-made rooms the game needs (arrival, objective rooms, exit vestibules). A **port** is a door on one wall (`side` N/S/E/W, `at` its centre along that wall, `kind`, `width`, `height`, `runHeight`); a grid line runs through it and a straight stub joins it to the first crossing on that line, so keep a port's line clear of other rooms. `runHeight` makes the run it opens onto at least that tall (a vestibule's fire door hangs its KEEP CLOSED sign over its head casing: 12.6 lets it fit). `sign` is stencilled beside its doors (leave it off vestibules: SignageBuilder puts STAIRS there). |
| `entry`, `exits` | The arrival keep-room, and the exit vestibules (route candidates). |
| `otherEntries` | The other entry vestibules (a floor above the basement is entered from any of three). Items keep 60 studs walked from each of them too, and the creature spawns are shared out so that each way in has its own in `creatureBand`. |
| `links` | `{ a, b }`: two keep-rooms the layout joins with a door of its own (a vestibule opening straight into a hall, a gate between two halls). The planner walks across them; without a link a keep-room reached only through another keep-room is an island. |
| `barriers` | Wall lines `{ x0, z0, x1, z1 }` no tunnel crosses. They fold the floor into one long walk; a corridor across one can only be a crawlway. |
| `gridX`, `gridZ` | The crossings' lines (else generated every `style.pitch`, jittered). Port lines are added. Keep a crossing's square (`max width / 2 + 2`) clear of the keep-rooms. |
| `crawlSites` | Pinned crawlways `{ x0, z0, x1, z1 }` between two neighbouring crossings (may cut a barrier); nil lets the planner pick them. |
| `style` | Tunnel widths and heights, galleries (`galleryWidth`, `galleryHeight` 14–16, `galleryShare`, `galleryMin`), `length` (target tunnel length), `deadEnds`, `crawlWidth`, `crawlAcrossBarriers`, `crawlMouthsPass` (the thinning keeps two tunnel arms at every crawlway mouth, so no mouth ends up at the tip of a long dead end), niches (`alcoveWidth/Depth/Height` for item shelves, `guardAlcoveWidth/Depth` for guarded items' bays, default 9 × 8, `hideAlcoveWidth/Depth` for hides, default 10 × 7), lights (`lightSpacing`, `deadShare` of bulbs, `flickerShare` of circuits, `plateLampEvery`), palette keys and acoustics. |
| `rules` | The TunnelRules thresholds (section 3); omitted fields use `TunnelRules.Defaults`. |
| `regions` | 4–6 regions `{ id, name, x, z, areas?, medium?, hides?, pipe, band, grime, paint, graffiti, wall?, floor?, wet? }`. A crossing belongs to the region whose `areas` rect holds it, else to the nearest seed `(x, z)` by walking distance (a region never jumps a barrier). `medium` is stencilled on the pipe markers. `hides` picks what the region's hide niches hold: any of `"Barrel"`, `"Cabinet"`, `"Locker"` (a hideable locker backed onto the niche's back wall, its hider stepping out at the front; ids `<prefix>_Locker_Tnn`); nil is barrels and cabinets. |
| `items` | Planner-placed items `{ kind, count, shelf, guard, wall?, areas? }`: on a shelf in an item niche, spread out, at least 60 studs walked from the entry (and from each of `otherEntries`), only where hide niches can serve them; `guard` puts the item in a guard bay (`guardAlcoveWidth` × `guardAlcoveDepth`) with a TrapCandidate (the item's `ref`) just inside its mouth, 2.4 studs off the centre line toward the side the squad comes along the run from (only bays with such a side take a guarded item: one side at least 6 studs nearer the ways in than the other, on foot and through the crawlways alike). The shelf is deep enough that the item's prompt first answers in the mouth, so the shortest walk in, round the near jamb, sets a foot on the pan; a careful player steps round its far side, a lane over 3 studs wide, and takes the item from beside the shelf. `wall` hangs it on a hook on the niche's back wall at height `shelf` instead (no shelf: a key ring); `areas` (`{ x0, z0, x1, z1 }` rects) keeps its niches inside them (Level 1's keys: west of the gate). |
| `hideTargets` | More points that need a hide within `objectiveHideReach` (the vestibules). |
| `traps`, `batteries`, `clutter`, `corpses`, `drips`, `debris`, `scares`, `creatureSpawns`, `creatureBand` | Counts of the dressing anchors and triggers; creature spawns fall within `creatureBand` studs walked from the entry. |
| `attempts`, `crossingTarget`, `seed` | Thinning attempts (the one closest to the target crossing and length wins), and the seed. The planner draws only from `Rng` (`Shared/Util/Rng`: the same numbers in Lune and on Roblox), so a seed plans the same floor for the web's export and a live server. A floor's seed is the first of its old seed, + 1, + 2, … whose plan passes every rule here and every spec (the layout records it). |

What comes out:

- **Rooms:** `Tunnel` (runs: one straight room each; niches are `Tunnel` rooms too), `Gallery` (the longest runs:
  wider, 14–16 high), `Crawlway` (culverts 4 wide, 4.8 high: only a crouched player fits; the Creature never enters)
  and `Solid` fill (the ground between, no floor or zone). Every tunnel-like room is `Tunnel` or `Gallery`: the AI
  treats every other kind as a keep-room.
- **Doors:** open doorways where runs meet (at a crossing one run owns the square, the others open into its sides),
  ports, niche mouths and crawlway mouths (`crawlOnly`, clearance 4.3).
- **Anchors:** Barrel / Cabinet (and Locker) hides, item candidates with guard traps, PatrolWaypoints (each region's
  junctions in a loop, made up with its turns when it has fewer than three; long hops split at a crossing, so no two
  waypoints are more than 110 studs apart), CreatureSpawns, TrapCandidates, BatteryCandidates, Clutter, Corpse
  (against bare wall), DripPipe (clear of the ceiling bulbs).
- **Triggers:** FloorDebris and ScareStep across runs (never within 40 studs walked of the entry).
- **Lights:** caged bulbs every `lightSpacing` wired in local circuits (section 5), red emergency lamps at every
  `plateLampEvery`-th junction plate. No plate (so no lamp) goes on a vestibule stub's walls within 12 studs of the
  fire door: its swing, then its STAIRS sign.
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

| Rule | Default | Level 0 | Level 1 | Level 2 | Level 3 | Level 4 |
| --- | --- | --- | --- | --- | --- | --- |
| Connected on foot without any crawlway (every keep-room and vestibule) | — | yes | yes (the gate's vent counts) | yes | yes | yes |
| Every junction on a loop of at most `maxLoop` studs | 200 | longest 122 | longest 152 | longest 196 | longest 148 | longest 140 |
| Crossing: the walk from the entry to the farthest exit | 1100–1500 | 1650–1980 (1901) | 1650–1980 (1685) | 1650–1980 (1842) | 1650–1980 (1675) | 1400–1980 (1493) |
| With the crawlways (crouched, 5.5 studs/s) the crossing still takes `crawlCrossingSeconds` | 40 s | 55.4 s | 69.0 s | 65.8 s | 70.8 s | 60.9 s |
| Crawlways (count, length, mouth height) | 3–6, ≤ 20, 4.3 | 3–12: 11 | 3–18: 18 | 3–16: 14 | 3–18: 17 | 3–16: 15 |
| A crawlway mouth within `crawlReach` of every tunnel point | 60 | 58.2 | 56.4 | 58.2 | 58.2 | 58.9 |
| A hiding spot within `hideReach` of every tunnel point | 30 | 26.9 | 29.4 | 26.2 | 29.6 | 27.0 |
| A hiding spot within `objectiveHideReach` of every objective place | 25 | yes | yes | yes | yes | yes |
| Dead ends: count, length | ≤ 8, ≤ 25 | 3 (≤ 22) | 1 (≤ 20) | 6 (≤ 24) | 7 (≤ 24) | 4 (≤ 24) |
| Regions: named, distinct | 4–6 | 5 | 5 | 5 | 5 | 5 |
| Galleries 14–16 high; junction plates J-NN | — | yes | yes | yes | yes | yes |
| Seed (`Layouts/<floor>.luau`) | — | 20261103 | 20261104 | 20261105 | 20261134 | 20261130 |

Walking is 11 studs/s: Level 0 crosses in about 2.9 minutes, Level 1 in about 2.6, Level 2 in about 2.8, Level 3 in
about 2.5, Level 4 in about 2.3.

**Vents.** The walk graph (`TunnelRules.walkGraph`) walks the vents a squad can always use, whatever its `crawl`
flag: the grates that never lock and that no HatchValve keeps shut (timed, at `TunnelRules.VentSpeed`, 4.5 studs/s).
A floor's script may make such a vent the only way on: Level 1's gate shuts the hallway, and its bypass vent (two
grates, never locked, `criticalPath`) carries the crossing past it.

## 4. Hiding spots

Lockers (keep-rooms), Barrels and Cabinets (the tunnels) share one convention (HideBuilder, LockerBuilder): tag
`Hideable`, attribute `HideKind`, attachments EntryAnchor / ExitAnchor / HideAnchor / PeekAnchor and a Hide prompt.
Most barrels and cabinets **stand free** in a hide niche (10 × 7): centred, 0.6 off the back wall, front to the run,
with clear floor on both sides; the anchor's `exit` (`Left` / `Right`) puts the ExitAnchor 1.3 studs off that side,
so a hider (or a teammate pulling them out) can come out on a side the Creature is not standing on. The rest (dead-end
drums, the few cabinets against a wide run's wall, the vestibule cabinets) step out at the front. Level 0: 102 barrels
and cabinets, 93 freestanding.

## 5. Lights and power

- Every run's bulbs are wired in **circuits** of up to four neighbours, each its own flicker group: steady
  `Mains:<prefix>_<Region>_<nn>`, or a bad circuit `Circuit:<prefix>_<Region>_<nn>` that flickers (`flickerShare` of
  them). Each keep-room is its own `Mains:<roomId>`. So a flicker (the Creature's teleport warning dims the groups of
  the fixtures within 20 studs) stays local.
- The floor's power switch holds every bulb and fluorescent group down until the breaker is thrown (web
  `objectives/floor0.js`); the emergency reds, boiler glows and exit signs carry no group and always burn.
- The bake pools a level's `Mains:` / `Circuit:` light per vertex and per probe (see web/DATA.md), so a dark floor is
  dark between circuits too. Group ids are world-wide and 16-bit (up to 65535 groups in all, so every tunnel floor
  can wire its own hundred-odd circuits; Level 0 has 118 groups); keep the floor prefix in the names, which must be
  unique world-wide.
- On the web the power cut is a hold on each mains group: a teleport warning's stutter only dims a held group, and a
  scene's light override (the boiler surge) hands it back to the hold when it ends, so a cut circuit stays dark.

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
npm run check                                 # the deliverable, the engine walk, perf (L1, L0, L2), screenshots
node tools/objective-run.mjs --floors L0,L1,L2 --seeds 1029   # each floor played: spawn, objective, exit unlocked
```

When the planner fails or a rule does not hold:

- **"found no layout its crawlway sites can cover"**: some tunnel is more than `crawlReach` from every crawl mouth
  (check the far ends of stubs: a vestibule's stub counts), or a junction cannot keep a loop. Move or add crawl sites
  so every mouth sits on the walk, not on a spur.
- **Crossing too short / long:** move barriers (fold more or less), move the exits' band, or adjust `style.length`.
- **Hide reach:** hide niches need 8.5 studs of free ground beside a run; widen the gaps between runs or keep-rooms.
- **A STAIRS sign missing:** the vestibule's stub needs about 12 studs between its rail and the fire door (the
  door's swing and the doorway approach leave the rest; the planner keeps junction plates and their red lamps off
  that stretch); niches keep 11 studs (past their half width) from a keep-room's door. A fire door's own KEEP CLOSED
  sign needs a run about 12 studs tall (`runHeight` 12.6 on every tunnel floor's vestibule ports) and a vestibule at
  least 13 tall; `PropsVentsDoors.spec` checks every floor's fire doors for it.
- **Guard traps:** a keep-room fuse's guard stands 2–9 studs from it, in the same room, on the careless walk in but
  never sealing the item off:
  - **On the careless walk** (ObjectivePlaces.carelessWalk): the shortest walk, a body (1 stud) clear of the walls and
    of what stands in the room, from 8 studs back in the room beyond the room's arrival doorway (straight out, or
    along the run it opens off: the doorway, and the side of it, the squad reaches first from the floor's ways in, on
    foot and through the crawlways alike) to the first point where the item's Pickup prompt (7 studs) answers passes
    within half a pan's side (1.1) of the guard, so the foot lands on the pan whatever the trap's yaw. With an ordinary door, the walk is held for each way its open leaf may
    hang. Put the guard on that line, between the doorway and where the prompt first answers; a guard beside the line,
    or past the point where the prompt answers, fails it.
  - **Never sealing it:** every guarded item keeps a spot to stand beside it (ObjectivePlaces.standingSpot: 1.6–4
    studs off it, 2.5 from every trap spot a run may arm, in sight, walked to from a doorway of its room without a
    foot on any pan and round the open door leaves). A guard that blocks a gap or a slot fails it.
  - `Objectives.spec` and `web/tools/data-test.mjs` hold every fuse candidate, tunnel bays included, to both (the data
    test on the baked collision).
- Render the plan to eyeball it: a dump of the layout's rooms, doors, anchors and lights drawn top-down (one of the
  maps' screenshots is exactly that).

## 9. The rebuilt floors

**Level 1 (the hallways).** Entered from the east vestibules (the basement's exits), left by the west ones (Padlock
ExitLocks). The arrival is the old checkerboard hallway, kept short (`L1_Corridor_East`, 96 × 14) with Classroom 108
off its north side (the ajar door, the glow lights, the glass ScareStep, the Creature's scare pose) and the HallwayGate
at its west end sealing it from `L1_Corridor_West`. The gate's bypass is a vent kept as a vent (both runtimes crawl
vents, and crouch through crawlways): a grate low in the hallway's north wall ten studs east of the gate, one in the west
hall ten studs west of it, the duct in the chase behind them; neither ever locks. Regions: Locker Banks (east; its hide
niches hold lockers), Offices & Records, Library Stacks, Collapsed Main Hall, Kitchen Service. Keep-rooms: the
janitor's closet and the main office. The master keys: 14 candidates, all west of the gate: ten on hooks in tunnel
niches (`items.wall`, `items.areas`), two in the janitor's closet, two in the main office.

**Level 2 (the science wing).** Entered from the west vestibules, left by the east ones (Chain ExitLocks). Chem Lab
203 and Bio Lab 209 straddle two of the barriers, so the walk crosses each lab; Chem Prep 205 opens off Bio Lab 209
(the FumeHood and its AcidFlaskSpot), the chem store off the north fume ducts, the specimen store off the cold-storage
lane. Regions: Prep Corridors, Cold Storage, Fume Ducts, Utility Corridors, Chem Stores. Reagents: 15 candidates,
five of each kind (they cycle through the kinds in layout order): five on tunnel niche shelves, six on the labs'
islands, two on each store's shelving. Stun flasks: 16 FlaskCandidates, ten on the lab benches and six in tunnel
caches (niche shelves).

Both keep every scripted id the two runtimes use (anchors, triggers, doors, lights, grates; web/DATA.md lists them).
