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
  ParachutePackCount: 4,
  ParachuteDescentSpeed: 9,
  StaminaMax: 100,
  StaminaSprintDrain: 7, // a full sprint lasts about 14 s (Tunnels: the Creature chases at 16.5, you sprint at 19)
  StaminaScurryDrain: 22,
  StaminaRegen: 14,
  StaminaRegenDelay: 1.2,
  BatteryMax: 100,
  BatteryDrain: 0.6325, // +15 % (harder Standard; the flashlight drains the same on every difficulty)
  BatteryPickupCharge: 45,
  WalkSpeed: 11,
  SprintSpeed: 19,
  CrouchSpeed: 5.5,
  VentCrawlSpeed: 4.5,
  VentScurrySpeed: 9,
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
    ParachuteLookback: [0, 0, 0],
  }),
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
 * @type {Readonly<Record<string, {radius: number, priority: 'Low'|'Normal'|'High'|'Critical', medium: 'Air'|'Vent', interval: number}>>}
 */
export const NoiseKinds = Object.freeze({
  // Tunnels retune (design §2.2): the Creature hears a sprint from far away, a walk from the next junction, a crouch
  // only when it is all but on you
  CrouchWalk: { radius: 5, priority: 'Low', medium: 'Air', interval: 0.6 },
  SlowVentCrawl: { radius: 8, priority: 'Low', medium: 'Vent', interval: 0.7 },
  GrateUnscrew: { radius: 10, priority: 'Low', medium: 'Air', interval: 0.9 },
  Walk: { radius: 22, priority: 'Normal', medium: 'Air', interval: 0.45 },
  Gasp: { radius: 40, priority: 'High', medium: 'Air', interval: 0 },
  FlaskShatter: { radius: 50, priority: 'High', medium: 'Air', interval: 0 },
  Sprint: { radius: 60, priority: 'High', medium: 'Air', interval: 0.3 },
  JumpLand: { radius: 26, priority: 'Normal', medium: 'Air', interval: 0 },
  // climbing into a hiding spot (a locker, a barrel, a cabinet): quietly, or hurried (sprinting a moment before)
  HideEnter: { radius: 8, priority: 'Low', medium: 'Air', interval: 0 },
  HideEnterHurried: { radius: 14, priority: 'Normal', medium: 'Air', interval: 0 },
  VentScurry: { radius: 90, priority: 'High', medium: 'Vent', interval: 0.3 },
  GrateKick: { radius: 130, priority: 'Critical', medium: 'Air', interval: 0 },
  FloorDebris: { radius: 130, priority: 'Critical', medium: 'Air', interval: 0 },
  TrapSnap: { radius: 130, priority: 'Critical', medium: 'Air', interval: 0 },
  DoorSlam: { radius: 90, priority: 'Critical', medium: 'Air', interval: 0 },
  FallingObject: { radius: 24, priority: 'Low', medium: 'Air', interval: 0 },
  Scripted: { radius: 0, priority: 'Low', medium: 'Air', interval: 0 },
  // co-op text chat, should the web ever get one (there is no voice chat on the web)
  ChatMessage: { radius: 25, priority: 'Normal', medium: 'Air', interval: 0 },
  // floor objectives: a working hold (keys in a lock) once a second, a loud single action (the breaker, an exit
  // unlocking)
  ObjectiveWork: { radius: 34, priority: 'Normal', medium: 'Air', interval: 0 },
  ObjectiveClunk: { radius: 110, priority: 'High', medium: 'Air', interval: 0 },
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
  WallOcclusion: 0.6,
  MaxOccludingWalls: 3,
  VentPropagationMultiplier: 1.4,
  PriorityRank: Object.freeze({ Low: 1, Normal: 2, High: 3, Critical: 4 }),
});

/**
 * InputConfig.luau, read from the world (world.json meta.inputConfig: every action, keyed as there) at the engine's
 * start (installInputBindings), with web key codes (KeyboardEvent.code / 'Mouse0') and standard-gamepad button indices.
 * Touch buttons keep their Roblox UDim2 positions: [scaleX, offsetX, scaleY, offsetY] and size in px; their labels
 * stay Strings keys (the touch layer resolves them). What the web does beyond InputConfig:
 *   - LeftControl is not bound: Ctrl+W (crouch while walking) would close the browser tab.
 *   - Menu also answers Escape and the gamepad's Start; Jump is the default character control (Roblox PlayerModule).
 *   - Interact is live while Downed too: the get-up's hold (the GetUp prompt reads its key itself on Roblox).
 *   - CROUCH's touch button sits clear above JUMP (their circles overlapped at -150 / -90); the Radar action's button
 *     reads GOAL while it drives the objective nudge (WebTouch).
 *   - PendingActions: InputConfig's actions whose feature the website does not have yet are not bound at all (no key,
 *     no touch button, never live); the package that builds one takes it off the list.
 * data-test holds the bound table to the export's (every action, its keys, buttons, kind and contexts).
 */
export const PendingActions = Object.freeze(['LookBack', 'Fire', 'LowerGun', 'Steer', 'PullUp']);

/** Roblox Enum.KeyCode / UserInputType names -> KeyboardEvent.code ('Mouse0': the left button). */
const KEY_CODES = Object.freeze({
  Space: 'Space', LeftShift: 'ShiftLeft', Tab: 'Tab', Return: 'Enter', Left: 'ArrowLeft', Right: 'ArrowRight',
  Up: 'ArrowUp', Down: 'ArrowDown', MouseButton1: 'Mouse0',
});
/** Keys the web leaves unbound (see above). */
const UNBOUND_KEYS = new Set(['LeftControl']);
/** Roblox gamepad KeyCodes -> standard-mapping button indices (Thumbstick1 is the move stick, no button). */
const PAD_BUTTONS = Object.freeze({
  ButtonA: 0, ButtonB: 1, ButtonX: 2, ButtonY: 3, ButtonL1: 4, ButtonR1: 5, ButtonL2: 6, ButtonR2: 7, ButtonSelect: 8,
  ButtonStart: 9, ButtonL3: 10, ButtonR3: 11, DPadUp: 12, DPadDown: 13, DPadLeft: 14, DPadRight: 15,
});
/** The web's additions to an exported action's keys, buttons and contexts. */
const WEB_EXTRA = Object.freeze({
  Menu: { keyboard: ['Escape'], gamepad: [9], contexts: [] },
  Interact: { keyboard: [], gamepad: [], contexts: ['Downed'] },
});
/** The web's own touch placement and labels (Strings keys) of an exported action's button. */
export const WebTouch = Object.freeze({
  Crouch: { position: [1, -90, 1, -172] },
  Radar: { label: 'Input.Objective' },
});
/** The actions the web adds (the default character controls). */
const WEB_ACTIONS = Object.freeze({
  Jump: { kind: 'Hold', keyboard: ['Space'], gamepad: [0], touch: { label: 'Input.Jump', position: [1, -95, 1, -90], size: 70 }, contexts: ['OnFoot'] },
});

/** One Roblox key name as a KeyboardEvent.code (letters and digits by rule, the rest by table), or null. */
export function webKey(name) {
  if (UNBOUND_KEYS.has(name)) return null;
  if (KEY_CODES[name]) return KEY_CODES[name];
  if (/^[A-Z]$/.test(name)) return `Key${name}`;
  if (/^(Zero|One|Two|Three|Four|Five|Six|Seven|Eight|Nine)$/.test(name)) {
    return `Digit${['Zero', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine'].indexOf(name)}`;
  }
  return null;
}

/**
 * The web's bindings for an exported InputConfig ({bindings: {Action: {kind, keyboard, gamepad, touch?, contexts}}}).
 * @param {{bindings: Record<string, any>}} inputConfig
 */
export function inputBindingsFrom(inputConfig) {
  const out = {};
  const exported = (inputConfig && inputConfig.bindings) || {};
  for (const action of Object.keys(exported).sort()) {
    if (PendingActions.includes(action)) continue;
    const b = exported[action];
    const extra = WEB_EXTRA[action] || { keyboard: [], gamepad: [], contexts: [] };
    const keyboard = [...(b.keyboard || []).map(webKey).filter(Boolean), ...extra.keyboard];
    const gamepad = [...(b.gamepad || []).map((n) => PAD_BUTTONS[n]).filter((n) => n !== undefined), ...extra.gamepad];
    const touch = b.touch ? { ...b.touch, ...(WebTouch[action] || {}) } : null;
    out[action] = Object.freeze({ kind: b.kind, keyboard, gamepad, touch, contexts: [...(b.contexts || []), ...extra.contexts] });
  }
  for (const [action, b] of Object.entries(WEB_ACTIONS)) out[action] = Object.freeze(b);
  return out;
}

/** The engine's bindings, filled from the world once at start (installInputBindings). */
export const InputBindings = {};

/** Fills InputBindings from the world's meta.inputConfig (the engine's constructor, before its Input exists). */
export function installInputBindings(meta) {
  for (const k of Object.keys(InputBindings)) delete InputBindings[k];
  Object.assign(InputBindings, inputBindingsFrom(meta && meta.inputConfig));
}

/** Context priority, highest first (Enums.InputContext). OnFoot is the baseline. */
export const InputContexts = Object.freeze(['Menu', 'Cutscene', 'Locker', 'Trapped', 'Downed', 'Vent', 'Parachute',
  'OnFoot', 'Spectator']);

/**
 * SettingsSchema.luau, read from the world (meta.settingsSchema: every setting, keyed as there; a Choice's default is
 * its option's 1-based index there and its option here) at the engine's start (installSettings), plus the web's
 * Supersample (Max+: Max rendered at 150 % and scaled down; only shown and only used at Max). PendingSettings: the
 * settings whose feature the website does not have yet keep their stored value but are never shown; the package that
 * builds one takes it off the list.
 */
export const PendingSettings = Object.freeze(['Brightness', 'LeapAssist', 'MonsterVoice', 'SayNames', 'VoiceVolume',
  'ReplayCutscenes']);

const WEB_SETTINGS = Object.freeze([
  { key: 'Supersample', kind: 'Bool', label: 'Settings.Supersample', default: false },
]);

/** The web's settings list for an exported SettingsSchema ({list: [{key, kind, label, default, ...}]}). */
export function settingsFrom(schema) {
  const out = [];
  for (const s of (schema && Array.isArray(schema.list) ? schema.list : [])) {
    const row = { ...s };
    if (s.kind === 'Choice') row.default = s.options[(s.default || 1) - 1];
    if (PendingSettings.includes(s.key)) row.hidden = true;
    out.push(Object.freeze(row));
  }
  for (const s of WEB_SETTINGS) out.push(s);
  return out;
}

/** The engine's settings, filled from the world once at start (installSettings). */
export const SettingsList = [];

/** Fills SettingsList from the world's meta.settingsSchema (the engine's constructor, before its Settings exist). */
export function installSettings(meta) {
  SettingsList.length = 0;
  SettingsList.push(...settingsFrom(meta && meta.settingsSchema));
}

/**
 * WorldConfig.luau (the parts the engine needs; the full layout, the footprint included, comes with the world data in
 * world.json's `worldConfig`).
 */
export const WorldConfig = Object.freeze({
  SlabThickness: 2,
  GroundY: 18,
  Levels: Object.freeze({
    Level0_Basement: { elevation: 0, height: 16 },
    Level1_Hallways: { elevation: 18, height: 14 },
    Level2_Auditorium: { elevation: 34, height: 28 },
    Level3_Roof: { elevation: 64, height: 0 },
  }),
  LevelOrder: Object.freeze(['Level0_Basement', 'Level1_Hallways', 'Level2_Auditorium', 'Level3_Roof']),
  LobbyOrigin: [-800, 0, 0],
  Towers: Object.freeze({
    West: { minX: -28, maxX: 0, minZ: 128, maxZ: 160 },
    East: { minX: 400, maxX: 428, minZ: 128, maxZ: 160 },
  }),
  Stairwells: Object.freeze([
    { id: 'Stairwell_0_1', from: 'Level0_Basement', to: 'Level1_Hallways', tower: 'East', fromRoom: 'L0_AirlockEast', toRoom: 'L1_AirlockEast' },
    { id: 'Stairwell_1_2', from: 'Level1_Hallways', to: 'Level2_Auditorium', tower: 'West', fromRoom: 'L1_AirlockWest', toRoom: 'L2_AirlockWest' },
    { id: 'Stairwell_2_3', from: 'Level2_Auditorium', to: 'Level3_Roof', tower: 'East', fromRoom: 'L2_AirlockEast', toRoom: 'L3_RoofAccess' },
  ]),
  VentBore: 3.5,
  ParapetHeight: 3.5,
});

/** The MoveStates (Enums.MoveState). */
export const MoveStates = Object.freeze(['Standing', 'Sprinting', 'Crouching', 'VentCrawling', 'VentScurrying',
  'DownedCrawling', 'Hiding', 'Trapped', 'Parachuting', 'Scripted']);

/** Override MoveStates, highest priority first (PlayerStateService.OverridePriority). */
export const OverridePriority = Object.freeze(['Scripted', 'Trapped', 'Hiding', 'Parachuting', 'DownedCrawling']);

/** Humanoid.WalkSpeed per MoveState (PlayerStateService WALK_SPEED). */
export const WalkSpeeds = Object.freeze({
  Standing: GameConfig.WalkSpeed,
  Sprinting: GameConfig.SprintSpeed,
  Crouching: GameConfig.CrouchSpeed,
  VentCrawling: GameConfig.VentCrawlSpeed,
  VentScurrying: GameConfig.VentScurrySpeed,
  DownedCrawling: GameConfig.DownedMoveSpeed,
  Hiding: 0,
  Trapped: 0,
  Parachuting: GameConfig.WalkSpeed,
  Scripted: 0,
});

/** Stamina drained per second per MoveState (PlayerStateService DRAIN). */
export const StaminaDrain = Object.freeze({
  Sprinting: GameConfig.StaminaSprintDrain,
  VentScurrying: GameConfig.StaminaScurryDrain,
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
