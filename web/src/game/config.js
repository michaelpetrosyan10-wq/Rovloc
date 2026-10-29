// Game configuration ported value-for-value from Shared/Config (GameConfig, DifficultyConfig, PerkConfig,
// TutorialConfig) and Shared/Enums (LevelId order, Difficulty, PerkId). Seconds and studs unless a name says otherwise.

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
  ServerTickHz: 10,
  CreditsPerLevelCleared: 20,
  CreditsEscapeBonus: 100,
});

/** Enums.LevelId in run order. */
export const LevelOrder = Object.freeze(['Level0_Basement', 'Level1_Hallways', 'Level2_ScienceHall',
  'Level3_Gymnasium', 'Level4_FloodedPool', 'Level5_Roof']);

/** The level after `levelId` in run order (LevelDirector.nextLevel), or null after the roof. */
export function nextLevel(levelId) {
  const i = LevelOrder.indexOf(levelId);
  return i >= 0 && i + 1 < LevelOrder.length ? LevelOrder[i + 1] : null;
}

/** Enums.Difficulty */
export const Difficulties = Object.freeze(['Standard', 'Nightmare']);

/**
 * DifficultyConfig.luau
 * @typedef {{creatureSpeedMultiplier: number, hearingMultiplier: number, sightRangeMultiplier: number,
 *   trapCount: number, batteriesPerLevel: number, flasksScienceHall: number, flasksPool: number,
 *   lockedGrateFraction: number, catchCooldownSeconds: number, maxChaseSeconds: number,
 *   postAirlockGraceSeconds: number, creditMultiplier: number}} DifficultySpec
 * @type {Readonly<Record<string, DifficultySpec>>}
 */
export const DifficultyConfig = Object.freeze({
  Standard: Object.freeze({
    creatureSpeedMultiplier: 1,
    hearingMultiplier: 1,
    sightRangeMultiplier: 1,
    trapCount: 10,
    batteriesPerLevel: 3,
    flasksScienceHall: 6,
    flasksPool: 2,
    lockedGrateFraction: 0.25,
    catchCooldownSeconds: 18,
    maxChaseSeconds: 40,
    postAirlockGraceSeconds: 12,
    creditMultiplier: 1,
  }),
  Nightmare: Object.freeze({
    creatureSpeedMultiplier: 1.2,
    hearingMultiplier: 1.25,
    sightRangeMultiplier: 1.15,
    trapCount: 16,
    batteriesPerLevel: 1,
    flasksScienceHall: 4,
    flasksPool: 1,
    lockedGrateFraction: 0.45,
    catchCooldownSeconds: 11,
    maxChaseSeconds: 65,
    postAirlockGraceSeconds: 6,
    creditMultiplier: 1.5,
  }),
});

/** Enums.PerkId in declaration order. */
export const PerkIds = Object.freeze(['RustyScrewdriver', 'LithiumCell', 'AdrenalineSyringe']);

/**
 * PerkConfig.luau
 * @type {Readonly<Record<string, {id: string, cost: number, maxEquipped: number, unscrewSeconds?: number,
 *   batteryCapacityMultiplier?: number, syringeCharges?: number}>>}
 */
export const Perks = Object.freeze({
  RustyScrewdriver: Object.freeze({ id: 'RustyScrewdriver', cost: 60, maxEquipped: 1, unscrewSeconds: 1.2 }),
  LithiumCell: Object.freeze({ id: 'LithiumCell', cost: 80, maxEquipped: 1, batteryCapacityMultiplier: 1.5 }),
  AdrenalineSyringe: Object.freeze({ id: 'AdrenalineSyringe', cost: 120, maxEquipped: 1, syringeCharges: 1 }),
});

/** PerkConfig.MaxStock: units of one perk a player may own. */
export const MaxPerkStock = 20;

/** PerkConfig.holdSeconds: a prompt's hold under the equipped perks. */
export function perkHoldSeconds(kind, baseHold, perks) {
  if (kind === 'Unscrew' && perks.includes('RustyScrewdriver')) {
    return Math.min(baseHold, Perks.RustyScrewdriver.unscrewSeconds ?? GameConfig.UnscrewSeconds);
  }
  return baseHold;
}

/** PerkConfig.batteryCapacity */
export function batteryCapacity(perks) {
  return GameConfig.BatteryMax * (perks.includes('LithiumCell') ? Perks.LithiumCell.batteryCapacityMultiplier : 1);
}

/** PerkConfig.syringeCharges */
export function syringeCharges(perks) {
  return perks.includes('AdrenalineSyringe') ? Perks.AdrenalineSyringe.syringeCharges : 0;
}

/** TutorialConfig.luau */
export const TutorialConfig = Object.freeze({
  TutorialSetting: 'TutorialDone',
  HintsSetting: 'ShowHints',
  Pages: Object.freeze([
    { id: 'Goal', art: 'Goal', title: 'Tutorial.Goal.Title', body: 'Tutorial.Goal.Body', deviceBody: false },
    { id: 'Creature', art: 'Creature', title: 'Tutorial.Creature.Title', body: 'Tutorial.Creature.Body', deviceBody: false },
    { id: 'Noise', art: 'Noise', title: 'Tutorial.Noise.Title', body: 'Tutorial.Noise.Body', deviceBody: false },
    { id: 'Tools', art: 'Tools', title: 'Tutorial.Tools.Title', body: 'Tutorial.Tools.Body', deviceBody: false },
    { id: 'Teamwork', art: 'Teamwork', title: 'Tutorial.Teamwork.Title', body: 'Tutorial.Teamwork.Body', deviceBody: false },
    { id: 'Controls', art: 'Controls', title: 'Tutorial.Controls.Title', body: 'Tutorial.Controls.Body', deviceBody: true },
    { id: 'Lobby', art: 'Lobby', title: 'Tutorial.Lobby.Title', body: 'Tutorial.Lobby.Body', deviceBody: false },
  ]),
  ControlRows: Object.freeze([
    { label: 'Tutorial.Control.Move', glyph: 'Tutorial.Glyph.Move' },
    { label: 'Tutorial.Control.Look', glyph: 'Tutorial.Glyph.Look' },
    { label: 'Tutorial.Control.Sprint', action: 'Sprint' },
    { label: 'Tutorial.Control.Crouch', action: 'Crouch' },
    { label: 'Tutorial.Control.Flashlight', action: 'Flashlight' },
    { label: 'Tutorial.Control.Interact', action: 'Interact' },
    { label: 'Tutorial.Control.Kick', action: 'Kick' },
    { label: 'Tutorial.Control.Throw', action: 'Throw' },
    { label: 'Tutorial.Control.Objective', action: 'Objective' },
    { label: 'Tutorial.Control.Menu', action: 'Menu' },
  ]),
  // Highest priority first.
  Hints: Object.freeze([
    { id: 'Airlock', text: 'Hint.Airlock', inputs: [], setting: 'HintAirlock' },
    { id: 'DownedTeammate', text: 'Hint.DownedTeammate', inputs: [{ action: 'Interact', label: 'Hint.Input.Revive' }], setting: 'HintDownedTeammate' },
    {
      id: 'BearTrap', text: 'Hint.BearTrap', setting: 'HintBearTrap', radius: 16,
      inputs: [{ action: 'Crouch', label: 'Hint.Input.Crouch' }, { action: 'Interact', label: 'Hint.Input.Pry' }],
    },
    {
      id: 'Flask', text: 'Hint.Flask', setting: 'HintFlask', radius: 12,
      inputs: [{ action: 'Interact', label: 'Hint.Input.PickUp' }, { action: 'Throw', label: 'Hint.Input.Throw' }],
    },
    {
      id: 'VentGrate', text: 'Hint.VentGrate', setting: 'HintVentGrate', radius: 11,
      inputs: [{ action: 'Interact', label: 'Hint.Input.Unscrew' }, { action: 'Kick', label: 'Hint.Input.Kick' }],
    },
    {
      id: 'Locker', text: 'Hint.Locker', setting: 'HintLocker', radius: 10,
      inputs: [{ action: 'Interact', label: 'Hint.Input.Hide' }, { action: 'HoldBreath', label: 'Hint.Input.HoldBreath' }],
    },
    { id: 'Water', text: 'Hint.Water', inputs: [{ action: 'Dive', label: 'Hint.Input.Dive' }], setting: 'HintWater' },
    { id: 'LowBattery', text: 'Hint.LowBattery', inputs: [{ action: 'Flashlight', label: 'Hint.Input.Light' }], setting: 'HintLowBattery' },
  ]),
  LowBatteryFraction: 0.2,
  Floors: Object.freeze({
    Level0_Basement: { title: 'Floor.Level0.Title', name: 'Floor.Level0.Name', tip: 'Objective.Tip.Level0', stairwell: 'East' },
    Level1_Hallways: { title: 'Floor.Level1.Title', name: 'Floor.Level1.Name', tip: 'Objective.Tip.Level1', stairwell: 'West' },
    Level2_ScienceHall: { title: 'Floor.Level2.Title', name: 'Floor.Level2.Name', tip: 'Objective.Tip.Level2', stairwell: 'East' },
    Level3_Gymnasium: { title: 'Floor.Level3.Title', name: 'Floor.Level3.Name', tip: 'Objective.Tip.Level3', stairwell: 'West' },
    Level4_FloodedPool: { title: 'Floor.Level4.Title', name: 'Floor.Level4.Name', tip: 'Objective.Tip.Level4', stairwell: 'East' },
    Level5_Roof: { title: 'Floor.Level5.Title', name: 'Floor.Level5.Name', tip: 'Objective.Tip.Level5', stairwell: null },
  }),
  LobbySteps: Object.freeze([
    { id: 'Bus', text: 'Objective.Lobby.Bus', optional: false },
    { id: 'Ready', text: 'Objective.Lobby.Ready', optional: false },
    { id: 'Vote', text: 'Objective.Lobby.Vote', optional: true },
    { id: 'Perks', text: 'Objective.Lobby.Perks', optional: true },
  ]),
  Timing: Object.freeze({
    TrackerHold: 9,
    TrackerFade: 1.6,
    DirectionShow: 3.5,
    DirectionCooldown: 20,
    FloorCardIn: 1.2,
    FloorCardHold: 3.6,
    FloorCardOut: 1.6,
    FloorCardWait: 8,
    HintSeconds: 7,
    HintGap: 5,
    HintPanicMax: 0.55,
    TitleDriftPeriod: 64,
  }),
  // The title camera's loop through the boiler room: level-local points of the Lobby layout (eye, look-at).
  TitleDrift: Object.freeze([
    { eye: [10, 6.5, 42], look: [30, 5.5, 8] },
    { eye: [30, 8, 44], look: [24, 6, 6] },
    { eye: [50, 7, 40], look: [64, 5, 30] },
    { eye: [52, 9.5, 20], look: [30, 6, 6] },
    { eye: [30, 11, 30], look: [8, 5, 8] },
    { eye: [12, 8, 30], look: [40, 4, 10] },
  ]),
});

/** The hidden settings the game keeps (SettingsSchema's hidden Bools). */
export const HiddenSettings = Object.freeze(['TutorialDone', 'HintBearTrap', 'HintVentGrate', 'HintFlask',
  'HintLocker', 'HintDownedTeammate', 'HintWater', 'HintLowBattery', 'HintAirlock']);

/** Enums.StatKey (RunStatsService counters). */
export const StatKeys = Object.freeze(['TrapsTriggered', 'VentsCrawled', 'TimesDowned', 'Revives', 'FlasksThrown',
  'Stuns', 'LockersHidden', 'FloorsCleared', 'CreditsEarned']);
