// config.js: the floor objectives as the game reads them, and the web's tuning of everything ObjectiveConfig leaves to
// the services (the Roblox port mirrors these numbers).
//
// ObjectiveConfig itself travels as data: meta.objectives.floors (per floor: floor, levelId, id, title, item {prop,
// candidate, count, guarded?, slots?, hold, object}, steps [{id, count, label, seconds?}], lockStep, lockVariant,
// lockReason, holds by prompt kind), meta.objectives.levels[levelId].candidates (layout order) and .places (the
// nearest hiding spot of every step). Nothing here repeats a count, a hold or a candidate: those are read from the data.

/** The web tuning (seconds and studs). */
export const ObjectiveTuning = Object.freeze({
  /** A working hold (unlock, mix, turn, cut) emits its Normal noise at the start and then once a second. */
  WorkNoisePeriod: 1,
  /** Noise kinds (engine/config.js NoiseKinds): working holds, loud single actions, the generator. */
  WorkNoise: 'ObjectiveWork',
  LoudNoise: 'ObjectiveClunk',
  GeneratorNoise: 'GeneratorStart',
  /** Floor 3: a locker search hold, how long an empty one stands ajar (its swing: lockers.js SEARCH_OPEN 0.42). */
  SearchHold: 1,
  SearchEmptySeconds: 0.9,
  /** Floor 2: a thrown acid flask burns the chain when it breaks within this of ChainCentre (ObjectiveConfig: 3). */
  ChainHitRadius: 3,
  /** The unlock: the lock comes off over LockOffSeconds, the door swings DoorDelay after the clunk. */
  LockOffSeconds: 0.9,
  DoorDelay: 0.75,
  /** Floor 0: the basement's mains lights while the power is out (their flicker groups' factor) and the switch-on. */
  PowerOffFactor: 0.04,
  PowerOnSeconds: 2.6,
  /** Floor 0: the breaker lever's throw (ObjectiveConfig LeverThrow, degrees about the lever's X axis). */
  LeverThrowDegrees: 110,
  /** Floor 2: the sash slides from its built pose to SashOpen over this while mixing. */
  SashSeconds: 0.8,
  /** Floor 3: the work lamp's brightness once the generator runs (the LampLens SpotLight's Brightness). */
  WorkLampBrightness: 3,
  /** Floor 4: the hatch swings to HatchOpen over this once the valve is turned; the wheel turns this many times. */
  HatchSeconds: 1.6,
  ValveTurns: 2.5,
  /** Floor 5: the chain and padlock drop this far below their rest. */
  ChainDrop: 1.1,
  /** The Tab nudge on a floor with an objective: available this long after arriving, then every Cooldown. */
  NudgeDelay: 20,
  NudgeCooldown: 30,
  /** First-time objective hints: a station or lock within this of the eye with a clear line. */
  HintRadius: 12,
});

/** The Creature's start on Levels 2 and 3 (spawns.js). */
export const SpawnTuning = Object.freeze({
  /** Walking distance band (zone graph: rooms + doorways) from the entry airlock. */
  MinDistance: 70,
  MaxDistance: 140,
  /** The grace before it patrols, by difficulty. A High / Critical noise of the player's ends it at once. */
  Grace: Object.freeze({ Standard: 20, Nightmare: 12 }),
  /** Eye height of the entry's sample points and the heights checked at an anchor (over its floor). */
  EntryEyeHeight: 4.6,
  AnchorHeights: Object.freeze([2.2, 7.4]),
  /** Entry sample points inset from the entry room's walls. */
  EntryInset: 2,
  /** The held Creature lets go early when the player comes within this, or can see its head from this far. */
  ReleaseNear: 30,
  ReleaseSight: 70,
});

/** The floor objective of `level` (meta.objectives.floors), or null. */
export function floorSpec(meta, level) {
  const floors = meta.objectives && meta.objectives.floors;
  return (floors || []).find((f) => f.levelId === level) || null;
}

/** A prompt hold of a floor by PromptKind; throws on a kind the floor does not use (ObjectiveConfig.hold). */
export function holdOf(spec, kind) {
  const seconds = spec.holds[kind];
  if (!Number.isFinite(seconds)) throw new Error(`ObjectiveConfig: ${spec.id} has no ${kind} hold`);
  return seconds;
}

/** The step spec `id` of a floor. */
export function stepOf(spec, id) {
  return spec.steps.find((s) => s.id === id) || null;
}

/**
 * A room's spoken name from its layout id: the level prefix dropped, words split at underscores and capitals
 * ("L2_ChemPrep_205" -> "Chem Prep 205", "L0_Storage_NW" -> "Storage NW", "L3_LockerRoom_Boys" -> "Locker Room Boys").
 */
export function roomName(id) {
  if (!id) return '';
  const parts = String(id).split('_');
  if (/^L\d+$/.test(parts[0]) || parts[0] === 'Lobby') parts.shift();
  const words = [];
  for (const part of parts) {
    if (/^[A-Z0-9]+$/.test(part)) words.push(part);
    else words.push(...part.replace(/([a-z])([A-Z0-9])/g, '$1 $2').replace(/([0-9])([A-Za-z])/g, '$1 $2').split(' '));
  }
  return words.filter(Boolean).join(' ');
}

/**
 * Compass word of a point on a level ("north-east", "east", ...): north is -Z, east is +X; a side counts when the point
 * lies more than a quarter of the level's span from its centre along that axis. Null near the middle.
 * @param {{aabb: number[]}} levelInfo meta.levels[level] (aabb = minX, minY, minZ, maxX, maxY, maxZ)
 */
export function compassOf(levelInfo, point) {
  const b = levelInfo && levelInfo.aabb;
  if (!b) return null;
  const cx = (b[0] + b[3]) / 2;
  const cz = (b[2] + b[5]) / 2;
  const ew = point.x - cx > (b[3] - b[0]) / 4 ? 'East' : point.x - cx < -(b[3] - b[0]) / 4 ? 'West' : '';
  const ns = point.z - cz < -(b[5] - b[2]) / 4 ? 'North' : point.z - cz > (b[5] - b[2]) / 4 ? 'South' : '';
  const key = ns + ew;
  return key || null;
}
