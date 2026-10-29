// Configuration ported value-for-value from Shared/Config (GameConfig, CameraConfig, NoiseConfig, InputConfig,
// SettingsSchema, WorldConfig). Seconds and studs unless a name says otherwise; 1 stud = 1 unit.

/** GameConfig.luau */
export const GameConfig = Object.freeze({
  MinSquad: 1,
  MaxSquad: 4,
  CountdownSeconds: 8,
  ResultsSeconds: 12,
  MaxHealth: 100,
  BleedoutSeconds: 35,
  ReviveHoldSeconds: 4,
  CheckpointRespawnHealthFraction: 0.5,
  DownedMoveSpeed: 2.5,
  StragglerSeconds: 20,
  TrapDamage: 35,
  TrapSoloPrySeconds: 5,
  TrapRescueSeconds: 1.5,
  TrapLookDownPitch: -35,
  UnscrewSeconds: 3.5,
  KickSeconds: 0,
  StunSeconds: 6,
  FlaskThrowSpeed: 70,
  FlaskThrowCooldown: 1.2,
  FlaskCloudRadius: 14,
  FlaskCloudSeconds: 7,
  FlaskMaxFlightSeconds: 3,
  FlaskVentHopRadius: 2,
  BreathHoldMaxSeconds: 7,
  BreathRecoverPerSecond: 0.6,
  StrugglePressesToEscape: 22,
  StruggleMaxPressesPerSecond: 12,
  ParachutePackCount: 4,
  ParachuteDescentSpeed: 9,
  StaminaMax: 100,
  StaminaSprintDrain: 16,
  StaminaScurryDrain: 22,
  StaminaFreestyleDrain: 20,
  StaminaTreadDrain: 2,
  StaminaRegen: 14,
  StaminaRegenDelay: 1.2,
  OxygenMax: 100,
  OxygenDrain: 7,
  OxygenDrainGrabbed: 9,
  OxygenRegen: 30,
  BatteryMax: 100,
  BatteryDrain: 0.55,
  BatteryPickupCharge: 45,
  WalkSpeed: 11,
  SprintSpeed: 19,
  CrouchSpeed: 5.5,
  VentCrawlSpeed: 4.5,
  VentScurrySpeed: 9,
  TreadSpeed: 4,
  FreestyleSpeed: 9,
  UnderwaterSpeed: 5,
  OneShotLead: 0.2,
  OneShotMaxLate: 1.5,
  ServerTickHz: 10,
  CreditsPerLevelCleared: 20,
  CreditsEscapeBonus: 100,
});

/** Engine physics constants the Roblox place pins (Workspace.Gravity, CharacterService's Humanoid). */
export const PhysicsConfig = Object.freeze({
  Gravity: 196.2,
  JumpHeight: 2.5,
  HipHeight: 2, // R15 normalized: the root centre floats HipHeight + half the root height above the floor
  RootHalfHeight: 1,
  BodyRadius: 1,
  BodyHeight: 5.2, // feet to crown
  StepHeight: 1.6, // stair risers are <= 1 stud (StairwellBuilder MAX_RISE); kerbs and debris a little more
  VentColliderDiameter: 2.6,
  MaxSlopeDeg: 89,
});

/** CameraConfig.luau */
export const CameraConfig = Object.freeze({
  StateOffsets: Object.freeze({
    Standing: [0, 0, 0],
    Crouching: [0, -1.5, 0],
    VentCrawling: [0, -2.1, -0.5],
    DownedCrawling: [0, -2.3, 0],
    LockerPeeking: [0, -0.15, 0],
    SurfaceSwimming: [0, -1.1, 0],
    UnderwaterSwimming: [0, -1.6, -0.3],
    ParachuteLookback: [0, 0, 0],
  }),
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
  FieldOfView: Object.freeze({ Base: 70, SprintBonus: 6, PanicMaxBonus: 12, JumpscareFov: 55, LerpSpeed: 6 }),
  Pitch: Object.freeze({ Min: -80, Max: 80, VentMin: -35, VentMax: 35, TrappedLookDown: -55, ParachuteLookUp: 55 }),
  Bob: Object.freeze({
    WalkFrequency: 1.9,
    WalkPitch: 0.6,
    WalkRoll: 0.45,
    WalkVertical: 0.07,
    SprintMultiplier: 1.7,
    CrouchMultiplier: 0.55,
    VentMultiplier: 0.8,
    IdleBreathFrequency: 0.22,
    IdleBreathPitch: 0.35,
    PanicBreathMultiplier: 2.4,
  }),
  Shake: Object.freeze({ ChaseAmplitude: 0.35, JumpscareAmplitude: 4, ImpactAmplitude: 1.6, Frequency: 14, Decay: 3.5 }),
  Panic: Object.freeze({
    CreatureNearDistance: 18,
    CreatureFarDistance: 80,
    ChaseFloor: 0.55,
    RiseSpeed: 1.5,
    FallSpeed: 0.25,
    Saturation: -0.55,
    Contrast: 0.25,
    TintRed: [255, 205, 205],
    DofFarIntensity: 0.45,
    VignetteTransparencyAtFull: 0.15,
  }),
  Mouse: Object.freeze({ RadiansPerPixel: 0.0035, GamepadRadiansPerSecond: 3.6, TouchRadiansPerPixel: 0.006 }),
});

/**
 * NoiseConfig.luau. Every noise pulse has a stud radius and a priority.
 * @type {Readonly<Record<string, {radius: number, priority: 'Low'|'Normal'|'High'|'Critical', medium: 'Air'|'Vent'|'Water', interval: number}>>}
 */
export const NoiseKinds = Object.freeze({
  CrouchWalk: { radius: 8, priority: 'Low', medium: 'Air', interval: 0.6 },
  SlowVentCrawl: { radius: 8, priority: 'Low', medium: 'Vent', interval: 0.7 },
  GrateUnscrew: { radius: 10, priority: 'Low', medium: 'Air', interval: 0.9 },
  Treading: { radius: 12, priority: 'Low', medium: 'Water', interval: 0.8 },
  Walk: { radius: 30, priority: 'Normal', medium: 'Air', interval: 0.45 },
  Gasp: { radius: 40, priority: 'High', medium: 'Air', interval: 0 },
  FlaskShatter: { radius: 50, priority: 'High', medium: 'Air', interval: 0 },
  Sprint: { radius: 65, priority: 'High', medium: 'Air', interval: 0.3 },
  Freestyle: { radius: 75, priority: 'High', medium: 'Water', interval: 0.35 },
  Splash: { radius: 75, priority: 'High', medium: 'Water', interval: 0 },
  VentScurry: { radius: 90, priority: 'High', medium: 'Vent', interval: 0.3 },
  GrateKick: { radius: 130, priority: 'Critical', medium: 'Air', interval: 0 },
  FloorDebris: { radius: 130, priority: 'Critical', medium: 'Air', interval: 0 },
  TrapSnap: { radius: 130, priority: 'Critical', medium: 'Air', interval: 0 },
  DoorSlam: { radius: 130, priority: 'Critical', medium: 'Air', interval: 0 },
  FallingObject: { radius: 24, priority: 'Low', medium: 'Air', interval: 0 },
  Scripted: { radius: 0, priority: 'Low', medium: 'Air', interval: 0 },
});

export const NoiseConfig = Object.freeze({
  Kinds: NoiseKinds,
  SpeedTiers: [
    { minSpeed: 15, kind: 'Sprint' },
    { minSpeed: 7.5, kind: 'Walk' },
    { minSpeed: 1, kind: 'CrouchWalk' },
  ],
  VentSpeedTiers: [
    { minSpeed: 6.5, kind: 'VentScurry' },
    { minSpeed: 0.75, kind: 'SlowVentCrawl' },
  ],
  WaterSpeedTiers: [
    { minSpeed: 6.5, kind: 'Freestyle' },
    { minSpeed: 0.75, kind: 'Treading' },
  ],
  SplashMeter: Object.freeze({
    perFreestylePulse: 1,
    perSplash: 2.5,
    perTreadingPulse: 0.1,
    decayPerSecond: 0.35,
    grabThreshold: 6,
    rearmBelow: 4,
  }),
  WallOcclusion: 0.6,
  MaxOccludingWalls: 3,
  VentPropagationMultiplier: 1.4,
  PriorityRank: Object.freeze({ Low: 1, Normal: 2, High: 3, Critical: 4 }),
});

/**
 * InputConfig.luau with web key codes (KeyboardEvent.code / 'Mouse0') and standard-gamepad button indices.
 * Touch buttons keep their Roblox UDim2 positions: [scaleX, offsetX, scaleY, offsetY] and size in px.
 * LeftControl is not bound on the web: Ctrl+W (crouch while walking) would close the browser tab.
 */
export const InputBindings = Object.freeze({
  Sprint: { kind: 'Hold', keyboard: ['ShiftLeft'], gamepad: [10], touch: { label: 'SPRINT', position: [1, -170, 1, -230], size: 76 }, contexts: ['OnFoot', 'Vent', 'Swim'] },
  Crouch: { kind: 'Toggle', keyboard: ['KeyC'], gamepad: [1], touch: { label: 'CROUCH', position: [1, -90, 1, -150], size: 76 }, contexts: ['OnFoot'] },
  Dive: { kind: 'Hold', keyboard: ['KeyC'], gamepad: [1], touch: { label: 'DIVE', position: [1, -90, 1, -150], size: 76 }, contexts: ['Swim'] },
  Flashlight: { kind: 'Tap', keyboard: ['KeyF'], gamepad: [12], touch: { label: 'LIGHT', position: [1, -90, 1, -310], size: 64 }, contexts: ['OnFoot', 'Vent', 'Swim', 'Downed', 'Trapped', 'Locker'] },
  Interact: { kind: 'Hold', keyboard: ['KeyE'], gamepad: [2], touch: null, contexts: ['OnFoot', 'Vent', 'Swim', 'Trapped', 'Locker'] },
  Kick: { kind: 'Tap', keyboard: ['KeyR'], gamepad: [3], touch: null, contexts: ['OnFoot', 'Vent'] },
  Throw: { kind: 'Hold', keyboard: ['Mouse0'], gamepad: [7], touch: { label: 'THROW', position: [1, -250, 1, -150], size: 76 }, contexts: ['OnFoot', 'Vent', 'Swim'] },
  HoldBreath: { kind: 'Hold', keyboard: ['Space'], gamepad: [0], touch: { label: 'HOLD BREATH', position: [1, -110, 1, -130], size: 110 }, contexts: ['Locker'] },
  Struggle: { kind: 'Mash', keyboard: ['Space'], gamepad: [0], touch: { label: 'STRUGGLE', position: [0.5, 0, 1, -140], size: 130 }, contexts: ['Struggle'] },
  Syringe: { kind: 'Tap', keyboard: ['KeyG'], gamepad: [13], touch: { label: 'SYRINGE', position: [1, -170, 1, -310], size: 64 }, contexts: ['OnFoot', 'Downed', 'Vent', 'Swim'] },
  Ripcord: { kind: 'Tap', keyboard: ['Space'], gamepad: [0], touch: { label: 'PULL', position: [0.5, 0, 1, -140], size: 130 }, contexts: ['Parachute'] },
  SpectatePrev: { kind: 'Tap', keyboard: ['KeyQ'], gamepad: [4], touch: { label: 'PREV', position: [0, 70, 0.5, 0], size: 70 }, contexts: ['Spectator'] },
  SpectateNext: { kind: 'Tap', keyboard: ['KeyE'], gamepad: [5], touch: { label: 'NEXT', position: [1, -70, 0.5, 0], size: 70 }, contexts: ['Spectator'] },
  Menu: { kind: 'Tap', keyboard: ['KeyM', 'Escape'], gamepad: [8, 9], touch: { label: 'MENU', position: [0, 60, 0, 60], size: 56 }, contexts: ['Menu', 'OnFoot', 'Vent', 'Swim', 'Downed', 'Trapped', 'Locker', 'Spectator'] },
  Objective: { kind: 'Tap', keyboard: ['Tab'], gamepad: [15], touch: { label: 'GOAL', position: [0, 60, 0, 124], size: 56 }, contexts: ['OnFoot', 'Vent', 'Swim'] },
  // The default character controls (Roblox PlayerModule): live wherever no context action claims Space.
  Jump: { kind: 'Hold', keyboard: ['Space'], gamepad: [0], touch: { label: 'JUMP', position: [1, -95, 1, -90], size: 70 }, contexts: ['OnFoot'] },
});

/** Context priority, highest first (Enums.InputContext). OnFoot is the baseline. */
export const InputContexts = Object.freeze(['Menu', 'Cutscene', 'Struggle', 'Locker', 'Trapped', 'Downed', 'Vent',
  'Swim', 'Parachute', 'OnFoot', 'Spectator']);

/** SettingsSchema.luau (+ the web's Quality entry, which the Roblox engine picked by itself). */
export const SettingsList = Object.freeze([
  { key: 'MouseSensitivity', kind: 'Number', label: 'Mouse sensitivity', min: 0.2, max: 3, step: 0.05, default: 1 },
  { key: 'GamepadSensitivity', kind: 'Number', label: 'Gamepad sensitivity', min: 0.2, max: 3, step: 0.05, default: 1 },
  { key: 'TouchSensitivity', kind: 'Number', label: 'Touch sensitivity', min: 0.2, max: 3, step: 0.05, default: 1 },
  { key: 'InvertY', kind: 'Bool', label: 'Invert look', default: false },
  { key: 'BaseFov', kind: 'Number', label: 'Field of view', min: 60, max: 90, step: 1, default: 70 },
  { key: 'MotionScale', kind: 'Number', label: 'Camera motion', min: 0, max: 1, step: 0.05, default: 1 },
  { key: 'FlashScale', kind: 'Number', label: 'Flashes and flicker', min: 0, max: 1, step: 0.05, default: 1 },
  { key: 'MasterVolume', kind: 'Number', label: 'Master volume', min: 0, max: 1, step: 0.05, default: 1 },
  { key: 'AmbienceVolume', kind: 'Number', label: 'Ambience', min: 0, max: 1, step: 0.05, default: 0.85 },
  { key: 'WorldVolume', kind: 'Number', label: 'World', min: 0, max: 1, step: 0.05, default: 1 },
  { key: 'MonsterVolume', kind: 'Number', label: 'Creature', min: 0, max: 1, step: 0.05, default: 1 },
  { key: 'PlayerVolume', kind: 'Number', label: 'Player', min: 0, max: 1, step: 0.05, default: 0.9 },
  { key: 'UIVolume', kind: 'Number', label: 'Interface', min: 0, max: 1, step: 0.05, default: 0.8 },
  { key: 'Captions', kind: 'Bool', label: 'Captions', default: false },
  { key: 'ShowHints', kind: 'Bool', label: 'Hints', default: true },
  { key: 'Quality', kind: 'Choice', label: 'Graphics quality', options: ['Auto', 'Low', 'Medium', 'High'], default: 'Auto' },
  { key: 'TutorialDone', kind: 'Bool', label: 'Tutorial done', hidden: true, default: false },
  { key: 'HintBearTrap', kind: 'Bool', label: 'Hint seen', hidden: true, default: false },
  { key: 'HintVentGrate', kind: 'Bool', label: 'Hint seen', hidden: true, default: false },
  { key: 'HintFlask', kind: 'Bool', label: 'Hint seen', hidden: true, default: false },
  { key: 'HintLocker', kind: 'Bool', label: 'Hint seen', hidden: true, default: false },
  { key: 'HintDownedTeammate', kind: 'Bool', label: 'Hint seen', hidden: true, default: false },
  { key: 'HintWater', kind: 'Bool', label: 'Hint seen', hidden: true, default: false },
  { key: 'HintLowBattery', kind: 'Bool', label: 'Hint seen', hidden: true, default: false },
  { key: 'HintAirlock', kind: 'Bool', label: 'Hint seen', hidden: true, default: false },
]);

/** WorldConfig.luau (the parts the engine needs; the full layout comes with the world data). */
export const WorldConfig = Object.freeze({
  FootprintSize: [240, 160],
  SlabThickness: 2,
  GroundY: 18,
  Levels: Object.freeze({
    Level0_Basement: { elevation: 0, height: 16 },
    Level1_Hallways: { elevation: 18, height: 14 },
    Level2_ScienceHall: { elevation: 34, height: 14 },
    Level3_Gymnasium: { elevation: 50, height: 30 },
    Level4_FloodedPool: { elevation: 82, height: 28 },
    Level5_Roof: { elevation: 112, height: 0 },
  }),
  LevelOrder: Object.freeze(['Level0_Basement', 'Level1_Hallways', 'Level2_ScienceHall', 'Level3_Gymnasium',
    'Level4_FloodedPool', 'Level5_Roof']),
  LobbyOrigin: [-800, 0, 0],
  Towers: Object.freeze({
    West: { minX: -28, maxX: 0, minZ: 64, maxZ: 96 },
    East: { minX: 240, maxX: 268, minZ: 64, maxZ: 96 },
  }),
  Stairwells: Object.freeze([
    { id: 'Stairwell_0_1', from: 'Level0_Basement', to: 'Level1_Hallways', tower: 'East', fromRoom: 'L0_AirlockEast', toRoom: 'L1_AirlockEast' },
    { id: 'Stairwell_1_2', from: 'Level1_Hallways', to: 'Level2_ScienceHall', tower: 'West', fromRoom: 'L1_AirlockWest', toRoom: 'L2_AirlockWest' },
    { id: 'Stairwell_2_3', from: 'Level2_ScienceHall', to: 'Level3_Gymnasium', tower: 'East', fromRoom: 'L2_AirlockEast', toRoom: 'L3_AirlockEast' },
    { id: 'Stairwell_3_4', from: 'Level3_Gymnasium', to: 'Level4_FloodedPool', tower: 'West', fromRoom: 'L3_AirlockWest', toRoom: 'L4_AirlockWest' },
    { id: 'Stairwell_4_5', from: 'Level4_FloodedPool', to: 'Level5_Roof', tower: 'East', fromRoom: 'L4_AirlockEast', toRoom: 'L5_RoofAccess' },
  ]),
  VentBore: 3.5,
  WaterSurfaceOffset: -1,
  ParapetHeight: 3.5,
});

/** The MoveStates (Enums.MoveState). */
export const MoveStates = Object.freeze(['Standing', 'Sprinting', 'Crouching', 'VentCrawling', 'VentScurrying',
  'DownedCrawling', 'Treading', 'Freestyle', 'Underwater', 'Hiding', 'Trapped', 'Grabbed', 'Parachuting', 'Scripted']);

/** Override MoveStates, highest priority first (PlayerStateService.OverridePriority). */
export const OverridePriority = Object.freeze(['Scripted', 'Grabbed', 'Trapped', 'Hiding', 'Parachuting',
  'DownedCrawling']);

/** Humanoid.WalkSpeed per MoveState (PlayerStateService WALK_SPEED). */
export const WalkSpeeds = Object.freeze({
  Standing: GameConfig.WalkSpeed,
  Sprinting: GameConfig.SprintSpeed,
  Crouching: GameConfig.CrouchSpeed,
  VentCrawling: GameConfig.VentCrawlSpeed,
  VentScurrying: GameConfig.VentScurrySpeed,
  DownedCrawling: GameConfig.DownedMoveSpeed,
  Treading: GameConfig.TreadSpeed,
  Freestyle: GameConfig.FreestyleSpeed,
  Underwater: GameConfig.UnderwaterSpeed,
  Hiding: 0,
  Trapped: 0,
  Grabbed: 0,
  Parachuting: GameConfig.WalkSpeed,
  Scripted: 0,
});

/** Stamina drained per second per MoveState (PlayerStateService DRAIN). */
export const StaminaDrain = Object.freeze({
  Sprinting: GameConfig.StaminaSprintDrain,
  VentScurrying: GameConfig.StaminaScurryDrain,
  Freestyle: GameConfig.StaminaFreestyleDrain,
  Treading: GameConfig.StaminaTreadDrain,
});

/** Roblox Enum.Material names -> footstep SurfaceKind (CharacterAnimationController's Palette-derived table). */
export const MaterialSurface = Object.freeze({
  Concrete: 'Concrete', Slate: 'Concrete', Cobblestone: 'Concrete', Brick: 'Concrete', Asphalt: 'Concrete',
  Pavement: 'Concrete', Basalt: 'Concrete', Rock: 'Concrete', SmoothPlastic: 'Tile', Plastic: 'Tile',
  Marble: 'Tile', Granite: 'Tile', Pebble: 'Concrete', Sandstone: 'Concrete', Limestone: 'Concrete',
  Wood: 'Wood', WoodPlanks: 'Wood', Metal: 'Metal', DiamondPlate: 'Metal', CorrodedMetal: 'Metal', Foil: 'Metal',
  Grass: 'Grass', LeafyGrass: 'Grass', Ground: 'Grass', Mud: 'Grass', Sand: 'Grass', Fabric: 'Carpet',
  Carpet: 'Carpet', Rubber: 'Carpet', Glass: 'Glass', Ice: 'Glass', Water: 'Water', Neon: 'Tile',
});

export const SurfaceKinds = Object.freeze(['Concrete', 'Tile', 'Wood', 'Metal', 'Water', 'Glass', 'Grass', 'Carpet']);
