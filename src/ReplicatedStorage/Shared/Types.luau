--!strict
-- Cross-cutting type contracts. Module-private shapes live next to their module (exported from it);
-- only types that cross a module, layer or network boundary belong here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

export type MoveState = Enums.MoveState
export type LevelId = Enums.LevelId
export type StatKey = Enums.StatKey
export type PerkId = Enums.PerkId
export type Difficulty = Enums.Difficulty

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Everything a run is started with. Built by RunLifecycleService at Deploying.
export type RunContext = {
	runId: string,
	seed: number,
	difficulty: Enums.Difficulty,
	participants: { Player },
	startedAt: number, -- workspace:GetServerTimeNow()
}

-- Server modules. Every member is optional; ServerMain calls whichever exist.
--   Init:              wire up signals and state. Must not yield.
--   Start:             begin loops. Runs after every Init has returned.
--   BeginRun:          forward order, at Deploying.
--   EndRun:            reverse order, at Resetting. Clean the run trove and release locks.
--   OnPlayerRemoving:  reverse order, before the player's data is released.
export type Service = {
	Name: string,
	Init: (() -> ())?,
	Start: (() -> ())?,
	BeginRun: ((ctx: RunContext) -> ())?,
	EndRun: (() -> ())?,
	OnPlayerRemoving: ((player: Player) -> ())?,
}

-- What clients learn about a run (from ReplicatedStorage attributes).
export type RunInfo = {
	runId: string,
	seed: number,
	difficulty: Enums.Difficulty,
}

-- Client modules. ClientMain calls OnRunStarted / OnRunEnded when ReplicatedStorage.RunId changes.
export type Controller = {
	Name: string,
	Init: (() -> ())?,
	Start: (() -> ())?,
	OnRunStarted: ((info: RunInfo) -> ())?,
	OnRunEnded: (() -> ())?,
}

--------------------------------------------------------------------------------
-- Noise
--------------------------------------------------------------------------------

export type NoiseEvent = {
	position: Vector3,
	radius: number,
	kind: Enums.NoiseKind,
	priority: Enums.NoisePriority,
	levelId: Enums.LevelId?,
	medium: Enums.NoiseMedium,
	ventNodeId: string?,
	sourceUserId: number?,
	serverTime: number,
}

--------------------------------------------------------------------------------
-- Replicated meters: value at time `at`, changing at `rate` per second, clamped to [0, max].
--------------------------------------------------------------------------------

export type Meter = {
	value: number,
	rate: number,
	at: number,
	max: number,
}

--------------------------------------------------------------------------------
-- World graph (rooms + vent nodes, joined by portals). Built from layouts by ZoneGraph.
--------------------------------------------------------------------------------

export type ZoneNodeKind = "Room" | "VentNode"

export type ZoneNode = {
	id: string,
	kind: ZoneNodeKind,
	layoutId: Enums.LayoutId,
	center: Vector3, -- world space
	roomKind: Enums.RoomKind?,
}

export type PortalKind = "Doorway" | "Door" | "Gate" | "Airlock" | "Grate" | "Duct" | "Stair"

export type ZoneEdge = {
	a: string,
	b: string,
	kind: PortalKind,
	portalId: string, -- door id, grate id, duct edge id or stairwell id
	length: number, -- studs between node centers along the portal
}

export type ZoneGraphData = {
	nodes: { [string]: ZoneNode },
	edges: { ZoneEdge },
	adjacency: { [string]: { ZoneEdge } },
}

-- Portal ids that are currently impassable (locked grates, shut gates, sealed airlocks).
export type BlockedSet = { [string]: boolean }

--------------------------------------------------------------------------------
-- Per-run spawn plan (RunDirector output, consumed by WorldService)
--------------------------------------------------------------------------------

export type PlannedProp = {
	kind: string, -- prop builder key registered with ProceduralWorldBuilder.RegisterProp
	anchorId: string,
	levelId: Enums.LayoutId,
	cframe: CFrame, -- world space
	variant: number, -- seeded per prop, for visual variety
}

export type SpawnPlan = {
	seed: number,
	difficulty: Enums.Difficulty,
	props: { PlannedProp },
	lockedGrates: { [string]: boolean },
	rerolls: number,
}

--------------------------------------------------------------------------------
-- Builder registry (ProceduralWorldBuilder.RegisterProp / RegisterRig)
--------------------------------------------------------------------------------

export type PropBuildContext = {
	prop: PlannedProp,
	parent: Instance,
	random: Random,
}

export type PropBuilder = (ctx: PropBuildContext) -> Instance

export type RigBuilder = (parent: Instance, cframe: CFrame) -> Model

--------------------------------------------------------------------------------
-- Hooks that let later systems plug into earlier ones without upward requires
--------------------------------------------------------------------------------

export type MovementVerdict = "Ok" | "Correct" | "Strike"

-- Registered with MovementAuthority. Returns a verdict and, for Correct/Strike, a safe position.
export type MovementValidator = (player: Player, root: BasePart, dt: number) -> (MovementVerdict, Vector3?)

export type LockerVerdict = "Empty" | "HiddenSafe" | "Caught"

-- Registered with MonsterAIService by LockerHidingService.
export type LockerInspector = (locker: Instance) -> LockerVerdict

-- Registered with MonsterAIService by FloodedPoolService. Returns true when the grab started.
export type PoolGrabber = (player: Player) -> boolean

export type LevelContext = {
	levelId: Enums.LevelId,
	run: RunContext,
	root: Model, -- Workspace.School.<levelId>
	runtime: Folder, -- Workspace.Runtime.<levelId>
}

-- Registered with LevelDirector by the per-level controllers.
export type LevelController = {
	LevelId: Enums.LevelId,
	Activate: (ctx: LevelContext) -> (),
	Deactivate: (() -> ())?,
}

--------------------------------------------------------------------------------
-- Network payloads (validated shapes; see Net/RemoteRegistry)
--------------------------------------------------------------------------------

export type ClientWorldReadyPayload = { partCount: number }

-- Level-encoded: every message carries the full intended posture, so a message dropped by the rate limiter is
-- corrected by the next one. `seq` increases per message; the server ignores anything older than the last seen.
export type MoveIntentPayload = { crouch: boolean, sprint: boolean, dive: boolean, seq: number }

export type FlashlightTogglePayload = { on: boolean }

export type ItemThrowPayload = { direction: Vector3 }

export type BreathInputPayload = { held: boolean }

export type StrugglePressPayload = { sequence: number }

export type UseSyringePayload = { mode: Enums.SyringeMode }

export type LobbyActionPayload = {
	action: Enums.LobbyActionKind,
	difficulty: Enums.Difficulty?,
	perk: Enums.PerkId?,
}

export type SpectateCyclePayload = { direction: number } -- -1 or 1

export type SettingsSavePayload = { settings: { [string]: number | boolean } }

export type DevCommandPayload = { command: string, args: { string } }

export type LookRelayPayload = { yaw: number, pitch: number } -- int16-quantized radians (see Validators)

export type PerkPurchaseRequest = { perk: Enums.PerkId }

export type PerkPurchaseResult = { ok: boolean, credits: number, stock: number, reason: string? }

export type OneShotArg = string | number | boolean | Vector3 | CFrame

export type OneShotEvent = {
	seq: number,
	kind: Enums.OneShotKind,
	subject: Instance?,
	startAt: number, -- server time; clients wait until it, or fast-forward if late
	args: { [string]: OneShotArg },
}

export type PrivateCuePayload = {
	kind: Enums.CueKind,
	startAt: number,
	endsAt: number?,
	args: { [string]: OneShotArg },
}

export type AudioCuePayload = {
	preset: string, -- SynthPresets key
	position: Vector3?,
	attach: Instance?, -- BasePart or Attachment to follow
	startAt: number,
	seed: number,
	volume: number?,
	duration: number?, -- looped presets: seconds from startAt until the voice fades out (one-shots ignore it)
	id: number, -- server-assigned cue id; AudioStop { id } ends a looped cue early
}

export type AudioStopPayload = { id: number, fade: number? }

export type ProjectileEventPayload = {
	id: number,
	phase: Enums.ProjectilePhase,
	origin: Vector3,
	velocity: Vector3,
	t0: number,
	hitPosition: Vector3?,
	hitKind: Enums.ProjectileHitKind?,
}

export type LookSample = { userId: number, yaw: number, pitch: number }

export type LookBroadcastPayload = { samples: { LookSample } }

export type RunSummaryPayload = {
	outcome: Enums.RunOutcome,
	runSeconds: number,
	creditsEarned: number,
	bestTime: number?,
	stats: { [string]: number }, -- StatKey -> count
	levelsCleared: number,
}

export type NotifyPayload = { key: string, args: { string } }

export type DevOverlayPayload = {
	kind: "Noise" | "Plan" | "Path" | "Clear",
	position: Vector3?,
	radius: number?,
	label: string?,
	points: { Vector3 }?,
	-- Plan: kinds[i] is the kind of marker points[i] (a planned prop kind such as "BearTrap", "ChemicalFlask",
	-- "Battery", or "LockedGrate" for a grate the director locked); nil or missing entries draw the default marker.
	kinds: { string }?,
	duration: number?,
}

--------------------------------------------------------------------------------
-- Persistence (v1). Owned by PlayerDataStore (P8); declared here so the shop, summary and HUD agree.
--------------------------------------------------------------------------------

export type SettingsBlob = { [string]: number | boolean }

export type PlayerData = {
	v: number,
	Escapes: number,
	SurvivalCredits: number,
	BestTime: { Standard: number?, Nightmare: number? },
	PerkStock: { [string]: number }, -- PerkId -> owned, unused count
	Settings: SettingsBlob,
	LastRunId: string,
}

return {}
