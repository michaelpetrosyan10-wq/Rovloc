// The Creature's configuration ("the Tall Man", Tunnels design §2). Seconds and studs unless a name says otherwise.
// The numbers are Standard; Nightmare scales them through DifficultyConfig as before (faster, keener senses, a longer
// chase and a shorter teleport cooldown), but nothing outside a Scripted beat ever moves faster than SpeedCap, a
// sprinting player's pace less a margin.
//
// Rig metrics. The rig is R's (CreatureRigBuilder / meta.creature); creatureMetrics(meta) reads its height, hunched
// height, reach and eye height when the export carries them and falls back to MetricDefaults here.

/** CreatureConfig */
export const CreatureConfig = Object.freeze({
  // The Tall Man (CreatureRigBuilder): 11 studs standing, 9 hunched, long arms and fingers, no claws.
  Rig: Object.freeze({
    Height: 11,
    HunchedHeight: 9,
    RootSize: Object.freeze([2.6, 2.6, 1.4]),
    HipHeight: 3.4, // root centre sits HipHeight + RootSize.Y / 2 above the floor
    ArmLength: 6.3,
    FingerLength: 1.3,
  }),
  Hitbox: Object.freeze({
    Biped: Object.freeze([2.6, 11, 2.7]),
    Hunched: Object.freeze([2.6, 9, 4.2]),
    Quadruped: Object.freeze([2.8, 2.8, 6]),
  }),
  // Eye position above the root centre, per PoseMode (Perception and the jumpscare camera); creatureMetrics takes
  // meta.creature.eyeHeightAboveRoot (the rig export) over these when present.
  EyeHeightAboveRoot: Object.freeze({ Biped: 5.64, Hunched: 3.6, Quadruped: 0.5, Stunned: 4.6 }),
  Speeds: Object.freeze({
    Dormant: 0,
    Patrol: 7, // Stalk: slower than a walking player (11)
    InvestigateNoise: 9,
    WallChase: 16.5, // the Chase: a sprinter (19) gains on it, a walker (11) loses ground
    Search: 8,
    HidingResponse: 7,
    Teleport: 7, // the stalk toward its target after it materialises
    Stunned: 3,
    Scripted: 16,
    VentChase: 17, // legacy: the old vent crawl's pace (the view scales its duct scrape by it); never used by the brain
  }),
  /** The most any state but Scripted may move (a sprinting player runs 19). */
  SpeedCap: 18.5,
  /** It walks hunched (poseMode 'Hunched') where the clearance (a lintel, a tunnel's ceiling, a room) is under this. */
  HunchBelow: 12.5,
  Senses: Object.freeze({
    // sight range by the player's light: torch on, torch off in the dark, torch off in a lit pool; crouched x0.75
    SightTorch: 70,
    SightDark: 20,
    SightLit: 38,
    CrouchFactor: 0.75,
    // the probe irradiance (luminance) at the player's chest above which they stand in a lit pool
    LitIrradiance: 0.2,
    // the view cone: wider when the player moves; anything this close is felt whatever the facing
    SightHalfAngle: 55,
    MovingHalfAngle: 75,
    PeripheralRange: 6,
    MovingPeripheralRange: 10,
    MovingSpeed: 2,
    HearingMultiplier: 1,
    MemorySeconds: 9,
    CatchDistance: 4, // catch reach (meta.creature.reach when the rig exports one)
    CatchVertical: 5,
    EmfRadius: 15, // torch static within this
    NearRadius: 25, // heartbeat and breathing within this, seen or not
  }),
  // Looking straight at it: a player whose view centre stays within HalfAngle of its head for Seconds, within
  // LitRange (it stands lit, or their torch is on) or DarkRange, with a clear line, starts a chase.
  Stare: Object.freeze({ HalfAngle: 7, Seconds: 1, LitRange: 45, DarkRange: 18, RevealHalfAngle: 22 }),
  Search: Object.freeze({ MinSeconds: 12, MaxSeconds: 18, Radius: 15, Spots: 4 }),
  Investigate: Object.freeze({ MinSeconds: 6, MaxSeconds: 10, Spots: 2 }),
  // The saw-you-hide rule (HidingResponse) and the hide spots' own limit (the game's hidespots.js)
  Hiding: Object.freeze({
    SeenWindow: 1.5, // seen this recently when they got in: it saw them hide
    StandOff: 2.6, // where it stands, out from the spot's front
    LookAwayMin: 7,
    LookAwayMax: 10,
    LookAwaySeconds: 2.5,
    GruntLead: 0.7, // the low grunt this long before each LookAway
    ReachInSeconds: 30,
    ReachInLead: 0.6, // the ReachIn action runs this long before the catch
    CatchRange: 6, // stepping out within this while it is not looking away is a catch
    KickOutSeconds: 45,
    KickOutWarning: 35,
  }),
  // The teleport (THRESHOLD's jumpscare engine), §2.3
  Teleport: Object.freeze({
    UnseenSeconds: 25, // nobody seen this long
    FirstAfterGrace: 45, // the first one comes this long after the floor's grace
    AfterCatch: 25, // never within this of a catch or a player going down
    MinWalk: 12,
    MaxWalk: 24,
    MinStraight: 12, // never this close (straight line) to anyone
    BehindShare: 0.6,
    Isolated: 25, // a target this far from every teammate weighs more
    LoudWindow: 20, // heard from this recently weighs more
    WarningSeconds: 1.6,
    FlickerRadius: 20,
    FadeOutSeconds: 0.6,
    FadeInSeconds: 0.8,
    StareSeconds: 1.2,
    StalkSeconds: 10, // after the stare it stalks the target; sight alone does not start a chase meanwhile...
    StalkNear: 7, // ...unless they come this close
    ViewHalfAngle: 80, // a player "sees" a point inside this cone of their look with a clear line
    Retries: 2,
  }),
  // A chase that gives up: it FadeOuts and comes back out of sight at least this far from everyone (no upper bound:
  // the nearest such spot to where it vanished, whatever the map's extent)
  GiveUp: Object.freeze({ MinDistance: 45, MaxDistance: Infinity }),
  /** The floor's grace after it is first released on a level (the spawn hold), by difficulty. */
  FloorGrace: Object.freeze({ Standard: 20, Nightmare: 12 }),
  PathAgent: Object.freeze({
    AgentRadius: 2,
    AgentHeight: 8,
    AgentCanJump: false,
    AgentCanClimb: false,
    WaypointSpacing: 4,
  }),
  Repath: Object.freeze({ ChaseInterval: 0.35, PatrolInterval: 2, StuckSeconds: 2.5 }),
  Jumpscare: Object.freeze({ LungeSeconds: 0.45, HoldSeconds: 1.4, FaceDistance: 1.6 }),
  // DOORS-Jack fake-outs: about one hide spot in FakeoutOneIn holds one (seeded per run), at most one per floor per player
  FakeoutOneIn: 12,
});

/** Height of the root's centre above the floor when the Creature stands (CreatureBody.RootHeight). */
export const ROOT_HEIGHT = CreatureConfig.Rig.HipHeight + CreatureConfig.Rig.RootSize[1] / 2;

/** The rig measures the brain falls back to when meta.creature does not carry them (design §2.1). */
export const MetricDefaults = Object.freeze({ height: 11, hunchedHeight: 9, reach: CreatureConfig.Senses.CatchDistance });

/**
 * The rig metrics the brain uses: {height, hunchedHeight, reach, eyeHeights (above the root, per PoseMode)}.
 * meta.creature.height / hunchedHeight / reach / eyeHeight (standing, above the floor) win when exported.
 * @param {any} meta world.json
 */
export function creatureMetrics(meta) {
  const c = (meta && meta.creature) || {};
  const num = (v, d) => (Number.isFinite(v) && v > 0 ? v : d);
  const height = num(c.height, MetricDefaults.height);
  const hunchedHeight = num(c.hunchedHeight, MetricDefaults.hunchedHeight);
  const reach = num(c.reach, MetricDefaults.reach);
  const eyeHeights = { ...CreatureConfig.EyeHeightAboveRoot };
  const exported = c.eyeHeightAboveRoot;
  if (exported && typeof exported === 'object') {
    for (const pose of Object.keys(eyeHeights)) {
      if (Number.isFinite(exported[pose]) && exported[pose] > 0) eyeHeights[pose] = exported[pose];
    }
  } else if (Number.isFinite(c.eyeHeight) && c.eyeHeight > ROOT_HEIGHT) {
    eyeHeights.Biped = c.eyeHeight - ROOT_HEIGHT;
    eyeHeights.Hunched = Math.max(0.5, c.eyeHeight * (hunchedHeight / height) - ROOT_HEIGHT);
    eyeHeights.Stunned = eyeHeights.Hunched;
  }
  return Object.freeze({ height, hunchedHeight, reach, eyeHeights: Object.freeze(eyeHeights) });
}

/**
 * DifficultyConfig
 * @typedef {{creatureSpeedMultiplier: number, hearingMultiplier: number, sightRangeMultiplier: number,
 *   catchCooldownSeconds: number, maxChaseSeconds: number, chaseLostSeconds: number, postAirlockGraceSeconds: number,
 *   teleportCooldown: readonly number[], reachInSeconds: number}} DifficultySpec
 */
export const DifficultyConfig = Object.freeze({
  Standard: Object.freeze({
    creatureSpeedMultiplier: 1,
    hearingMultiplier: 1, // the design's radii are the Standard reach
    sightRangeMultiplier: 1,
    catchCooldownSeconds: 14.4,
    maxChaseSeconds: 22, // a chase gives up (FadeOut) after this, whatever happens
    chaseLostSeconds: 4, // line of sight lost this long: it searches the last seen point
    postAirlockGraceSeconds: 12,
    teleportCooldown: Object.freeze([60, 120]),
    reachInSeconds: 30,
  }),
  Nightmare: Object.freeze({
    creatureSpeedMultiplier: 1.2, // capped at SpeedCap
    hearingMultiplier: 1.25,
    sightRangeMultiplier: 1.15,
    catchCooldownSeconds: 8.8,
    maxChaseSeconds: 28,
    chaseLostSeconds: 5,
    postAirlockGraceSeconds: 6,
    teleportCooldown: Object.freeze([40, 80]),
    reachInSeconds: 24,
  }),
});

/** @param {string} difficulty @returns {DifficultySpec} */
export function difficultySpec(difficulty) {
  return difficulty === 'Nightmare' ? DifficultyConfig.Nightmare : DifficultyConfig.Standard;
}

/** NoiseConfig.luau (the parts Hearing reads). */
export const NoiseConfig = Object.freeze({
  WallOcclusion: 0.6,
  MaxOccludingWalls: 3,
  VentPropagationMultiplier: 1.4,
});

/** GameConfig.luau (the parts the Creature reads). */
export const GameConfig = Object.freeze({
  ServerTickHz: 10,
  StunSeconds: 6,
  OneShotLead: 0.2,
  BreathHoldMaxSeconds: 7,
});

/** CameraConfig.luau (the parts the Creature reads). */
export const CameraConfig = Object.freeze({
  EyeHeightAboveRoot: Object.freeze({
    Standing: 1.5,
    Sprinting: 1.4,
    Crouching: 0,
    VentCrawling: -0.6,
    VentScurrying: -0.6,
    DownedCrawling: -0.8,
    Hiding: 1.3,
    Trapped: 1.1,
    Parachuting: 1.5,
    Scripted: 1.5,
  }),
  JumpscareFov: 55,
  JumpscareShakeAmplitude: 4,
});

/** WorldConfig.luau (the parts the Creature reads; world.json's worldConfig overrides when present). */
export const WorldDefaults = Object.freeze({
  VentBore: 3.5,
  VentShell: 0.2,
  WallThickness: 1,
  VentCenterHeight: 2,
  DoorWidth: 6,
  AirlockDoorWidth: 8,
  DoorHeight: 10,
});

/**
 * The MonsterState names. Patrol is the Stalk, WallChase the Chase. VentChase is gone (it never enters a duct);
 * Search, HidingResponse and Teleport are new.
 */
export const MonsterStates = Object.freeze([
  'Dormant', 'Patrol', 'InvestigateNoise', 'WallChase', 'Search', 'HidingResponse', 'Teleport', 'Stunned', 'Scripted',
]);

/** Enums.PoseMode (the body's; the view contract's poseMode adds 'Stunned' and never says 'Quadruped'). */
export const PoseModes = Object.freeze(['Biped', 'Hunched', 'Quadruped']);

/** The view contract's one-shot actions (service.js viewState). */
export const ViewActions = Object.freeze(['Stare', 'ReachIn', 'LookAway', 'FadeOut', 'FadeIn', 'Jumpscare']);

/** Enums.NoisePriority */
export const NoisePriorities = Object.freeze(['Low', 'Normal', 'High', 'Critical']);

/** Enums.JumpscareKind */
export const JumpscareKinds = Object.freeze(['Hallway', 'Vent', 'Locker']);
