// The Creature's configuration, ported value for value from Shared/Config (CreatureConfig, DifficultyConfig,
// NoiseConfig, GameConfig, CameraConfig, WorldConfig). Seconds and studs unless a name says otherwise.

/** CreatureConfig.luau */
export const CreatureConfig = Object.freeze({
  Rig: Object.freeze({
    Height: 8.5,
    RootSize: Object.freeze([2.6, 2.6, 1.4]),
    HipHeight: 3.4, // root centre sits HipHeight + RootSize.Y / 2 above the floor
    ArmLength: 4.6,
    ClawLength: 0.5,
  }),
  Hitbox: Object.freeze({
    Biped: Object.freeze([3, 8, 2]),
    Hunched: Object.freeze([3, 6, 3]),
    Quadruped: Object.freeze([2.8, 2.8, 6]),
    Swim: Object.freeze([3, 3, 7]),
  }),
  // Eye position above the root centre, per PoseMode (Perception and the jumpscare camera).
  EyeHeightAboveRoot: Object.freeze({ Biped: 3.1, Hunched: 1.6, Quadruped: 0.5, Swim: 0.4 }),
  Speeds: Object.freeze({
    Dormant: 0,
    Patrol: 8,
    InvestigateNoise: 13,
    WallChase: 21,
    VentChase: 17,
    Stunned: 3,
    AquaticStalk: 6.5, // slower than a freestyle swimmer (9), faster than one treading water (4)
    AquaticLunge: 18,
    Scripted: 16,
  }),
  Senses: Object.freeze({
    SightRange: 95,
    SightHalfAngle: 62,
    PeripheralRange: 14,
    DarknessSightMultiplier: 0.6,
    HearingMultiplier: 1,
    MemorySeconds: 9,
    CatchDistance: 4.6,
    VentCatchDistance: 3.4,
    EmfRadius: 45,
  }),
  PathAgent: Object.freeze({
    AgentRadius: 2,
    AgentHeight: 8,
    AgentCanJump: false,
    AgentCanClimb: false,
    WaypointSpacing: 4,
  }),
  Repath: Object.freeze({ ChaseInterval: 0.35, PatrolInterval: 2, StuckSeconds: 2.5 }),
  Jumpscare: Object.freeze({ LungeSeconds: 0.45, HoldSeconds: 1.4, FaceDistance: 1.6 }),
  // The pool (Level 4 fairness): every lunge is telegraphed (rising bubbles, a ripple ring and a low growl at its
  // origin) for TelegraphSeconds and may then run for LungeWindow before a new telegraph is needed; LungeCooldown
  // after a lunge that missed. Any swim but a lunge is capped at the AquaticStalk pace. The Creature leaves a pool only
  // through its vent route (VentExitOnly). PoolGraceSeconds after the player first enters a pool room it leaves them
  // alone there; after any grab it retreats to the far end of the water for GrabRetreatSeconds.
  Water: Object.freeze({
    LungeRange: 9,
    TelegraphSeconds: 1.2,
    LungeWindow: 2.5,
    LungeCooldown: 2,
    VentExitOnly: true,
    PoolGraceSeconds: 20,
    GrabRetreatSeconds: 15,
  }),
});

/** Height of the root's centre above the floor when the Creature stands (CreatureBody.RootHeight). */
export const ROOT_HEIGHT = CreatureConfig.Rig.HipHeight + CreatureConfig.Rig.RootSize[1] / 2;

/**
 * DifficultyConfig.luau
 * @typedef {{creatureSpeedMultiplier: number, hearingMultiplier: number, sightRangeMultiplier: number,
 *   catchCooldownSeconds: number, maxChaseSeconds: number, postAirlockGraceSeconds: number}} DifficultySpec
 */
export const DifficultyConfig = Object.freeze({
  Standard: Object.freeze({
    creatureSpeedMultiplier: 1,
    hearingMultiplier: 1,
    sightRangeMultiplier: 1,
    catchCooldownSeconds: 18,
    maxChaseSeconds: 40,
    postAirlockGraceSeconds: 12,
  }),
  Nightmare: Object.freeze({
    creatureSpeedMultiplier: 1.2,
    hearingMultiplier: 1.25,
    sightRangeMultiplier: 1.15,
    catchCooldownSeconds: 11,
    maxChaseSeconds: 65,
    postAirlockGraceSeconds: 6,
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
    Treading: 0.4,
    Freestyle: 0.2,
    Underwater: -0.6,
    Hiding: 1.3,
    Trapped: 1.1,
    Grabbed: -0.6,
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

/** The MonsterState names (Enums.MonsterState). */
export const MonsterStates = Object.freeze([
  'Dormant', 'Patrol', 'InvestigateNoise', 'WallChase', 'VentChase', 'Stunned', 'AquaticStalk', 'Scripted',
]);

/** Enums.PoseMode */
export const PoseModes = Object.freeze(['Biped', 'Hunched', 'Quadruped', 'Swim']);

/** Enums.NoisePriority */
export const NoisePriorities = Object.freeze(['Low', 'Normal', 'High', 'Critical']);

/** Enums.JumpscareKind */
export const JumpscareKinds = Object.freeze(['Hallway', 'Vent', 'Locker', 'Underwater']);
