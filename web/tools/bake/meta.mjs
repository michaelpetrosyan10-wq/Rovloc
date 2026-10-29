// world.json: everything the web game needs besides the vertex streams, in world space and plain JSON. Built from
// the raw export (export-world.luau) and the bake's results. See web/DATA.md for each section.

import { FALLOFF_K, asArray } from './light.mjs';
import { cfInverse, cfMul } from './mesh.mjs';

const IDENTITY = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1];
const r3 = (v) => Math.round(v * 1000) / 1000;
const arr = (v) => (Array.isArray(v) ? v : []);
const obj = (v) => (v && !Array.isArray(v) && typeof v === 'object' ? v : {});

/** Entity type from its tags / name (the gameplay system that owns it). */
function entityType(e) {
  const tags = arr(e.tags);
  const a = obj(e.attributes);
  // floor objectives: items and stations by their ObjectiveId (Fuse, BreakerPanel, CrateChain, ...); door locks
  if (tags.includes('ObjectiveItem') || tags.includes('ObjectiveStation')) return a.ObjectiveId || 'Objective';
  if (tags.includes('ExitLock')) return a.ObjectiveId === 'CrateChain' ? 'CrateChain' : 'ExitLock';
  if (tags.includes('BearTrap')) return 'BearTrap';
  if (tags.includes('BatteryPickup')) return 'Battery';
  if (tags.includes('ChemicalItem')) return 'ChemicalFlask';
  if (tags.includes('VentGrate')) return 'VentGrate';
  if (tags.includes('HideableLocker')) return 'Locker';
  if (tags.includes('FloodlightSwitch')) return 'FloodlightSwitch';
  if (tags.includes('AirlockDoor')) return 'AirlockDoor';
  if (tags.includes('ScriptedDoor')) {
    if (a.ScriptedId === 'EquipmentStoreDoor') return 'StoreDoor';
    if (a.DoorKind === 'Gate') return 'HallwayGate';
    if (a.DoorKind === 'RoofDoor') return 'RoofStairDoor';
    if (a.DoorKind === 'Ajar') return 'ClassroomDoor';
    return 'ScriptedDoor';
  }
  if (/ParachuteCrate/.test(e.name)) return 'ParachuteCrate';
  if (/^ReadyPad_/.test(e.name)) return 'ReadyPad';
  if (/^Terminal_/.test(e.name)) return 'Terminal';
  return e.name.replace(/_.*$/, '');
}

function entityId(e) {
  const a = obj(e.attributes);
  const tags = arr(e.tags);
  // floor objectives: their anchor (a lock also names its door in DoorId; the acid flask borrows the hood's anchor)
  if (tags.includes('ObjectiveItem') || tags.includes('ObjectiveStation') || tags.includes('ExitLock')) {
    return a.ObjectiveId === 'AcidFlask' ? e.name : a.AnchorId || e.name;
  }
  return a.DoorId || a.GrateId || a.AnchorId || e.name;
}

/**
 * @param {any} raw world-raw.json
 * @param {any} r bake results
 */
export function buildMeta(raw, r) {
  const levelKeys = [...new Set([...raw.layoutIds, 'Stairwells', 'Exterior'])];
  const levels = {};
  for (const key of levelKeys) {
    const info = raw.levels[key];
    const b = r.levelBounds[key];
    levels[key] = {
      origin: info ? info.origin : [0, 0, 0],
      elevation: info ? info.elevation : 0,
      height: info && info.height !== undefined ? info.height : null,
      aabb: b ? b.map(r3) : null,
      film: raw.lighting.films[key] ? key : 'Outdoor',
    };
  }

  // lights: every Roblox Light (burning or not) + the moonlight spills; `baked` marks the ones in the vertex light
  const bakedByIndex = new Map();
  for (const l of r.lights) if (l.index >= 0) bakedByIndex.set(l.index, l);
  const lights = [];
  const lightIndexOfRaw = new Map();
  raw.lights.forEach((l, i) => {
    const fixture = raw.fixtures[l.fixture - 1];
    const fa = obj(fixture.attributes);
    const baked = bakedByIndex.get(i);
    lightIndexOfRaw.set(i, lights.length);
    lights.push({
      id: fixture.name,
      name: l.name,
      kind: fa.LightKind || null,
      cls: l.class === 'PointLight' ? 'point' : l.class === 'SpotLight' ? 'spot' : 'surface',
      pos: baked ? baked.pos.map(r3) : l.partCFrame.slice(0, 3),
      dir: baked && baked.dir ? baked.dir.map(r3) : null,
      angle: l.angle ?? null,
      face: l.face ?? null,
      color: l.color,
      brightness: baked ? baked.brightness : l.brightness,
      range: l.range,
      shadows: l.shadows,
      broken: !l.enabled || !(l.brightness > 0),
      baked: !!baked,
      group: baked ? baked.group : 0,
      level: fa.LevelId || null,
      room: fa.ZoneId || null,
      fixtureCFrame: fixture.cframe,
      fixtureSize: fixture.size,
      baseBrightness: fa.BaseBrightness ?? null,
      flickerGroup: fa.FlickerGroup || null,
      entity: l.entity ? l.entity - 1 : null,
    });
  });
  for (const l of r.lights) {
    if (l.index >= 0) continue;
    lights.push({
      id: l.fixture,
      name: 'Moonlight',
      kind: 'Moonlight',
      cls: 'spot',
      pos: l.pos.map(r3),
      dir: l.dir.map(r3),
      angle: raw.lighting.moonlight.angle,
      face: 'Front',
      color: raw.lighting.moonlight.color,
      brightness: l.brightness,
      range: l.range,
      shadows: true,
      broken: false,
      baked: true,
      group: 0,
      level: l.level,
      room: null,
      entity: null,
    });
  }
  const flickerGroups = r.groups.map((g) => ({
    id: g.id,
    name: g.name,
    kind: g.kind,
    level: g.level || null,
    initial: g.initial,
    lights: g.lights.map((i) => lightIndexOfRaw.get(i)),
  }));

  // entities
  // where each entity's vertices live: (chunk, first vertex within the chunk, count, node)
  const entityRanges = new Map();
  for (const c of r.chunks) {
    if (c.kind !== 'entity') continue;
    for (const g of c.ranges) {
      if (!entityRanges.has(g.entity)) entityRanges.set(g.entity, []);
      entityRanges.get(g.entity).push({ chunk: c.id, start: g.start, count: g.count, node: g.node });
    }
  }
  const entityAttachments = new Map();
  for (const a of raw.attachments) {
    if (!a.entity) continue;
    if (!entityAttachments.has(a.entity - 1)) entityAttachments.set(a.entity - 1, {});
    entityAttachments.get(a.entity - 1)[a.name] = a.cframe;
  }
  const entityColliders = new Map();
  for (const p of raw.parts) {
    if (!p.entity || !p.canCollide) continue;
    const e = raw.entities[p.entity - 1];
    const node = p.node || '';
    const frame = node ? (arr(e.nodes).find((n) => n.path === node) || {}).pivot || e.pivot : e.pivot;
    const local = cfMul(cfInverse(frame || IDENTITY), p.cf);
    if (!entityColliders.has(p.entity - 1)) entityColliders.set(p.entity - 1, []);
    entityColliders.get(p.entity - 1).push({ node, cf: local.map((v) => Math.round(v * 1e5) / 1e5), size: p.size, shape: p.shape, group: p.group });
  }
  const entities = raw.entities.map((e, i) => ({
    index: i,
    type: entityType(e),
    id: entityId(e),
    name: e.name,
    level: e.level,
    attributes: obj(e.attributes),
    tags: arr(e.tags),
    pivot: e.pivot || IDENTITY,
    primaryPart: e.primaryPart || null,
    nodes: arr(e.nodes).map((n) => ({ path: n.path, pivot: n.pivot || null, attributes: obj(n.attributes) })),
    attachments: entityAttachments.get(i) || {},
    prompts: arr(e.prompts),
    colliders: entityColliders.get(i) || [],
    ranges: entityRanges.get(i) || [],
  }));

  // anchors / waypoints / layout doors from the level attachments
  const anchors = [];
  const doors = [];
  const ventNodes = [];
  const grateMouths = [];
  for (const a of raw.attachments) {
    if (a.entity) continue;
    const at = obj(a.attributes);
    if (at.AnchorKind) {
      const anchor = { id: at.AnchorId || a.name, kind: at.AnchorKind, level: at.LevelId || null, room: at.ZoneId || null, cframe: a.cframe, attributes: at, tags: arr(a.tags) };
      // patrol loops (Brain.levelInfo): "<prefix>_WP_<loop>_<NN>", waypoint i leads to i + 1, the last back to the first
      const wp = at.AnchorKind === 'PatrolWaypoint' ? /_WP_(.+)_(\d+)$/.exec(anchor.id) : null;
      if (wp) {
        anchor.loop = wp[1];
        anchor.order = Number(wp[2]);
      }
      anchors.push(anchor);
    } else if (at.DoorId) {
      doors.push({ id: at.DoorId, kind: at.DoorKind, level: at.LevelId, width: at.DoorWidth, height: at.DoorHeight, scriptedId: at.ScriptedId || null, cframe: a.cframe });
    } else if (arr(a.tags).includes('VentNode')) {
      ventNodes.push({ id: at.NodeId, level: at.LevelId, links: (at.Links || '').split(',').filter(Boolean), cframe: a.cframe, attributes: at });
    } else if (at.GrateId) {
      grateMouths.push({ id: at.GrateId, cframe: a.cframe, attributes: at });
    }
  }

  const patrolLoops = {};
  for (const a of anchors) {
    if (!a.loop) continue;
    const key = `${a.level}|${a.loop}`;
    (patrolLoops[key] ||= { level: a.level, loop: a.loop, waypoints: [] }).waypoints.push(a);
  }
  for (const l of Object.values(patrolLoops)) l.waypoints = l.waypoints.sort((x, y) => x.order - y.order).map((w) => ({ id: w.id, room: w.room, pos: w.cframe.slice(0, 3) }));

  // volumes: zones (rooms) and triggers
  const zones = [];
  const triggers = [];
  for (const v of raw.volumes) {
    const at = obj(v.attributes);
    const tags = arr(v.tags);
    if (tags.includes('Zone')) {
      zones.push({ id: at.ZoneId, level: at.LevelId, roomKind: at.RoomKind || null, acoustic: at.AcousticPreset || null, surface: at.Surface || null, cframe: v.cframe, size: v.size });
    } else if (at.TriggerKind) {
      triggers.push({ id: at.TriggerId || v.name, kind: at.TriggerKind, level: at.LevelId || v.level, room: at.ZoneId || null, cframe: v.cframe, size: v.size, attributes: at, tags });
    }
  }

  // rooms in world space from the layouts (rects, heights, kind, acoustics, ambience)
  const rooms = [];
  for (const id of raw.layoutIds) {
    const layout = raw.layouts[id];
    const origin = raw.levels[id].origin;
    for (const room of arr(layout.rooms)) {
      const rect = room.rect;
      rooms.push({
        id: room.id,
        level: id,
        kind: room.kind,
        rect: { x: origin[0] + rect.x, z: origin[2] + rect.z, w: rect.w, d: rect.d },
        floorY: origin[1] + (room.floorY || 0),
        height: room.height ?? layout.height,
        noCeiling: !!room.noCeiling,
        acoustic: room.acoustic || layout.acoustic || null,
        ambience: room.ambience || layout.ambience || null,
        floor: room.floor || null,
        wall: room.wall || null,
        ceiling: room.ceiling || null,
      });
    }
  }

  // layout doors in local form (incl. Boarded / Doorway) so navigation can reason about them
  const layoutDoors = [];
  for (const id of raw.layoutIds) {
    for (const d of arr(raw.layouts[id].doors)) layoutDoors.push({ level: id, ...d });
  }

  const pools = triggers
    .filter((t) => t.kind === 'PoolWater')
    .map((t) => ({ id: t.id, level: t.level, room: t.room, surfaceY: r3(t.cframe[1] + t.size[1] / 2), rect: { x: r3(t.cframe[0] - t.size[0] / 2), z: r3(t.cframe[2] - t.size[2] / 2), w: t.size[0], d: t.size[2] }, depth: t.size[1], cframe: t.cframe, size: t.size }));
  const basins = [];
  for (const id of raw.layoutIds) for (const b of arr(raw.layouts[id].basins)) basins.push({ level: id, ...b, origin: raw.levels[id].origin });

  // creature: bones (Motor6D tree) + joints
  const creature = raw.creature
    ? {
        attributes: obj(raw.creature.attributes),
        primaryPart: raw.creature.primaryPart,
        hipHeight: raw.creature.hipHeight,
        // bone i = skinIndex i; parent from the Motor6D tree (part0 -> part1); rest = the bone part's CFrame in
        // model space (the rig is built at the origin facing -Z)
        bones: r.creatureBones.bones.map((name) => {
          const part = raw.creature.parts.find((p) => p.name === name);
          const motor = raw.creature.joints.find((j) => j.class === 'Motor6D' && j.part1 === name);
          return { name, parent: motor ? motor.part0 : null, motor: motor ? motor.name : null, rest: part ? part.cf : IDENTITY, size: part ? part.size : null };
        }),
        joints: raw.creature.joints.filter((j) => j.class === 'Motor6D'),
        parts: raw.creature.parts.map((p) => ({ name: p.name, bone: r.creatureBones.boneOf.get(p.name) || null, cf: p.cf, size: p.size, transparency: p.transparency, canCollide: p.canCollide, attributes: obj(p.attributes) })),
        lights: raw.creature.lights,
        attachments: raw.creature.attachments,
        chunks: r.chunks.filter((c) => c.kind === 'creature').map((c) => c.id),
        config: raw.creature.config,
      }
    : null;

  const films = {};
  for (const [k, v] of Object.entries(raw.lighting.films)) films[k] = v;
  films.Outdoor = raw.lighting.outdoorFilm;

  return {
    format: r.format,
    generator: 'web/tools/bake.mjs',
    seed: raw.seed,
    difficulty: raw.difficulty,
    quality: r.quality,
    bakeSettings: r.settings,
    stats: r.stats,
    encoding: { lightScale: r.lightScale, uvScale: r.uvScale, light: 'sqrt', positions: 'u16 per chunk quant' },
    streams: r.streams,
    levels,
    materials: r.materials,
    textures: r.textures,
    lighting: {
      baseline: raw.lighting.baseline,
      properties: raw.lighting.properties,
      moonlight: raw.lighting.moonlight,
      moods: raw.lighting.moods,
      maxBrightness: raw.lighting.maxBrightness,
      fixtureCones: raw.lighting.fixtureCones,
      bakedAmbient: r.ambient,
      falloff: { window: '(1-(d/R)^2)^2', inverseSquareK: FALLOFF_K, formula: 'brightness * (1-(d/R)^2)^2 / (1 + k d^2) * lambert * cone' },
    },
    film: { base: raw.lighting.baseFilm, levels: films },
    palette: raw.palette,
    lights,
    flickerGroups,
    chunks: r.chunks,
    collision: r.collision,
    probes: r.probes,
    entities,
    anchors,
    patrolLoops: Object.values(patrolLoops),
    doors,
    layoutDoors,
    triggers,
    zones,
    rooms,
    pools,
    basins,
    zoneGraph: raw.zoneGraph,
    vents: { graphs: raw.ventGraphs, nodes: ventNodes, grates: grateMouths },
    stairwells: raw.worldConfig.Stairwells,
    worldConfig: raw.worldConfig,
    windows: raw.windows,
    plan: raw.plan,
    objectives: raw.objectives || null,
    // routes: per floor (from level) its exit stairwell candidates, the shape worldData.routeCandidates consumes;
    // routePairs: per floor pair the candidate ids and this seed's pick; routeRule: the pick rule + fairness verdicts
    routes: raw.routes || null,
    routePairs: raw.routePairs || null,
    routeRule: raw.routeRule || null,
    layouts: raw.layouts,
    creature,
  };
}
