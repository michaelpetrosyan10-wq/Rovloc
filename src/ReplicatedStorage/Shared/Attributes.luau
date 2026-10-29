--!strict
-- Attribute key registry + typed accessors. Attributes carry durable, replicated state only;
-- moments travel on the OneShot remote. Never type an attribute name anywhere else.

local Attributes = {}

-- Player (server-written unless noted)
Attributes.Player = table.freeze({
	LifeState = "LifeState",
	MoveState = "MoveState", -- server-confirmed; the owning client predicts locally
	ControlLock = "ControlLock",
	Battery = "Battery",
	BatteryRate = "BatteryRate",
	BatteryAt = "BatteryAt",
	BatteryMax = "BatteryMax",
	Stamina = "Stamina",
	StaminaRate = "StaminaRate",
	StaminaAt = "StaminaAt",
	StaminaMax = "StaminaMax",
	Oxygen = "Oxygen",
	OxygenRate = "OxygenRate",
	OxygenAt = "OxygenAt",
	OxygenMax = "OxygenMax",
	FlashlightOn = "FlashlightOn",
	HeldItem = "HeldItem", -- Enums.ItemId (ChemicalProjectileService)
	HeldItemVariant = "HeldItemVariant", -- the held flask's look (ChemicalFlaskBuilder variant); nil with no item
	-- The floor objective's items this player carries (ObjectiveService is the only writer): "<Kind>:<n>" pairs joined
	-- by ";" in the order first carried (Fuse, MasterKeys, Reagent, CoachKey, ValveWheel, BoltCutters); "" for none.
	Carrying = "Carrying",
	SyringeCharges = "SyringeCharges",
	Loadout = "Loadout", -- comma-separated PerkIds equipped for the next / current run
	PerkStock = "PerkStock", -- PerkShopService: owned, unused perks ("PerkId:count,..."; PerkConfig.encodeStock)
	DownedCount = "DownedCount",
	BleedoutEndsAt = "BleedoutEndsAt",
	Ready = "Ready", -- LobbyService
	DifficultyVote = "DifficultyVote", -- LobbyService: Enums.Difficulty, nil until the player votes
	DataLoaded = "DataLoaded",
	Credits = "Credits",
	Escapes = "Escapes", -- MatchAndDataService: PlayerData.Escapes (the title screen shows it)
	RunOutcome = "RunOutcome",
	SpectateReason = "SpectateReason",
	SpectateTargetUserId = "SpectateTargetUserId",
	ZoneId = "ZoneId",
	LevelId = "LevelId",
	WorldAcked = "WorldAcked",
	DevTools = "DevTools", -- true when this player may use dev commands (Studio, allowlist or experience owner)
	Settings = "Settings", -- JSON SettingsBlob written by the data layer (P8) after loading; clients read it once
	-- The roof jump (ParachuteService is the only writer): Enums.ParachuteState (nil = None), the server time that
	-- state began, and whether the canopy opened by itself (the late auto-deploy: a faster, harder descent).
	Parachute = "Parachute",
	ParachuteAt = "ParachuteAt",
	ParachuteAuto = "ParachuteAuto",
})

-- Workspace.Creature
Attributes.Creature = table.freeze({
	MonsterState = "MonsterState",
	StateSince = "StateSince",
	PoseMode = "PoseMode",
	TargetUserId = "TargetUserId",
	InVent = "InVent",
	VentSegmentId = "VentSegmentId",
	Hidden = "Hidden",
	GrabbedUserId = "GrabbedUserId",
	LevelId = "LevelId",
})

-- ReplicatedStorage (match-wide)
Attributes.Match = table.freeze({
	MatchPhase = "MatchPhase",
	RunId = "RunId",
	RunSeed = "RunSeed",
	Difficulty = "Difficulty",
	CurrentLevel = "CurrentLevel",
	LevelPhase = "LevelPhase",
	RunStartedAt = "RunStartedAt",
	RunEndedAt = "RunEndedAt",
	WorldReady = "WorldReady",
	WorldPartCount = "WorldPartCount",
	DataMode = "DataMode",
	BootError = "BootError",
	-- Server time the Results screen returns everyone to the lobby (MatchResetService is the only writer; nil
	-- outside Results). EscapeSummaryController draws its auto-return countdown from it.
	ResultsEndsAt = "ResultsEndsAt",
	-- Lobby (LobbyService is the only writer)
	CountdownEndsAt = "CountdownEndsAt", -- server time the lobby countdown deploys at; nil while not counting down
	LobbySquad = "LobbySquad", -- comma-separated UserIds of the next run's squad (slot order, at most MaxSquad)
	LobbyDifficulty = "LobbyDifficulty", -- the difficulty the squad's votes currently select
	-- Dev taint (DevToolsService is the only writer). True from the first state-changing dev command while a run
	-- exists (devrun, level, next, noise, and every later-phase command not registered read-only) until the match is
	-- back in the Lobby phase, so it still reads true through RunEnded / Results / Resetting. MatchAndDataService (P8)
	-- must not award Escapes, SurvivalCredits or BestTime (nor stamp LastRunId) for a run that ended with DevRun true.
	DevRun = "DevRun",
	-- Floor objectives (ObjectiveService is the only writer; ObjectiveConfig; nil outside a run):
	ObjectiveLevel = "ObjectiveLevel", -- the level whose objective the rest describe
	ObjectiveSteps = "ObjectiveSteps", -- "<StepId>=<done>" pairs joined by ";" in the floor's step order
	ObjectiveUnlocked = "ObjectiveUnlocked", -- the floor's exit (the crate on the roof) is open
	ObjectiveTimerEndsAt = "ObjectiveTimerEndsAt", -- server time a timed step (the door motor) completes
	ObjectiveActivatedAt = "ObjectiveActivatedAt", -- server time the squad arrived on the floor (the Tab nudge waits)
	ObjectiveTargets = "ObjectiveTargets", -- where the next undone step is worked: "<room>|x|y|z" joined by ";"
	-- The basement's mains while the power is out (Floor 0): the level whose Bulb / Fluorescent flicker groups burn at
	-- ObjectiveConfig.Tuning.PowerOffFactor, and once the main breaker is thrown the server time their seeded switch-on
	-- stutter (PowerOnSeconds) starts.
	PowerOffLevel = "PowerOffLevel",
	PowerOnAt = "PowerOnAt",
})

-- World instances (written by builders, mutated by services)
Attributes.World = table.freeze({
	LayoutId = "LayoutId",
	LevelId = "LevelId",
	ZoneId = "ZoneId",
	RoomKind = "RoomKind",
	AcousticPreset = "AcousticPreset",
	SegmentId = "SegmentId",
	AdjacentZones = "AdjacentZones", -- comma-separated ZoneIds
	Submerged = "Submerged",
	NodeId = "NodeId",
	Links = "Links", -- comma-separated NodeIds
	GrateId = "GrateId",
	GrateState = "GrateState",
	Lockable = "Lockable",
	CriticalPath = "CriticalPath",
	FacingZoneId = "FacingZoneId",
	DoorId = "DoorId",
	DoorKind = "DoorKind",
	DoorState = "DoorState",
	ScriptedId = "ScriptedId", -- Door_<id> anchors: the ScriptedDoor id (HallwayGate, RoofStairDoor, ClassroomDoor,
	-- EquipmentStoreDoor)
	DoorWidth = "DoorWidth", -- Door_<id> anchors: clear opening width
	DoorHeight = "DoorHeight", -- Door_<id> anchors: clear opening height
	FromLevel = "FromLevel",
	ToLevel = "ToLevel",
	StairwellId = "StairwellId", -- stairwell doors (fire doors, roof housing doors): the WorldConfig.Stairwells id
	RouteSlot = "RouteSlot", -- stairwell doors: "North" | "Middle" | "South"
	RouteRole = "RouteRole", -- stairwell doors: "Exit" (the lower floor's) or "Entry" (the upper floor's)
	Jammed = "Jammed", -- stairwell doors: true when the run's route does not use the stairwell (shut, Locked)
	StragglerDeadline = "StragglerDeadline",
	AnchorId = "AnchorId",
	AnchorKind = "AnchorKind",
	TriggerId = "TriggerId",
	TriggerKind = "TriggerKind",
	LightKind = "LightKind",
	FlickerGroup = "FlickerGroup",
	BaseBrightness = "BaseBrightness",
	Preset = "Preset",
	Armed = "Armed",
	TrappedUserId = "TrappedUserId",
	OccupantUserId = "OccupantUserId",
	DoorOpen = "DoorOpen",
	TakenByUserId = "TakenByUserId",
	On = "On",
	HeldByUserId = "HeldByUserId",
	Charge = "Charge",
	ChannelActor = "ChannelActor",
	ChannelStartedAt = "ChannelStartedAt",
	ChannelDuration = "ChannelDuration",
	PromptKind = "PromptKind",
	Audience = "Audience",
	OwnerUserId = "OwnerUserId",
	BaseHold = "BaseHold",
	Surface = "Surface",
	ExpectedParts = "ExpectedParts",
	-- Floor objectives (ObjectiveConfig)
	Floor = "Floor", -- 0 (basement) .. 5 (roof)
	Step = "Step", -- the objective step a prop or prompt serves (ObjectiveConfig step id)
	ObjectiveId = "ObjectiveId", -- what the prop is: Fuse, BreakerPanel, ExitLock, ...
	Slot = "Slot", -- which of a step's items or sockets (reagent colour 1..3, fuse slot 1..3)
	LockVariant = "LockVariant", -- Padlock | Chain | Keypad
	Locked = "Locked", -- an objective lock still holds (builders leave true)
	LockerId = "LockerId", -- the hideable locker (Locker anchor id) a coach's key hangs in
	Candidate = "Candidate", -- an objective item's candidate anchor kind
})

function Attributes.getString(instance: Instance, key: string, default: string): string
	local value = instance:GetAttribute(key)
	if type(value) == "string" then
		return value
	end
	return default
end

function Attributes.getNumber(instance: Instance, key: string, default: number): number
	local value = instance:GetAttribute(key)
	if type(value) == "number" and value == value then
		return value
	end
	return default
end

function Attributes.getBool(instance: Instance, key: string, default: boolean): boolean
	local value = instance:GetAttribute(key)
	if type(value) == "boolean" then
		return value
	end
	return default
end

function Attributes.getVector3(instance: Instance, key: string, default: Vector3): Vector3
	local value = instance:GetAttribute(key)
	if typeof(value) == "Vector3" then
		return value :: Vector3
	end
	return default
end

-- Reads a string attribute and returns it only if it belongs to `allowed` (an Enums value list).
function Attributes.getEnum<T>(instance: Instance, key: string, allowed: { T }, default: T): T
	local value = instance:GetAttribute(key)
	if type(value) == "string" and table.find(allowed, value :: any) ~= nil then
		return (value :: any) :: T
	end
	return default
end

-- Splits a comma-separated list attribute ("a,b,c") into its non-empty entries.
function Attributes.getList(instance: Instance, key: string): { string }
	local value = instance:GetAttribute(key)
	local out: { string } = {}
	if type(value) ~= "string" or value == "" then
		return out
	end
	for entry in string.gmatch(value, "[^,]+") do
		table.insert(out, entry)
	end
	return out
end

function Attributes.joinList(entries: { string }): string
	return table.concat(entries, ",")
end

-- Writes only when the value actually changes, so AttributeChanged listeners see real transitions.
function Attributes.set(instance: Instance, key: string, value: any)
	if instance:GetAttribute(key) ~= value then
		instance:SetAttribute(key, value)
	end
end

-- Server-time meter helpers (see Types.Meter). Clients extrapolate between writes.
function Attributes.writeMeter(
	instance: Instance,
	valueKey: string,
	rateKey: string,
	atKey: string,
	value: number,
	rate: number,
	at: number
)
	instance:SetAttribute(valueKey, value)
	instance:SetAttribute(rateKey, rate)
	instance:SetAttribute(atKey, at)
end

function Attributes.readMeter(
	instance: Instance,
	valueKey: string,
	rateKey: string,
	atKey: string,
	max: number,
	now: number
): number
	local value = Attributes.getNumber(instance, valueKey, max)
	local rate = Attributes.getNumber(instance, rateKey, 0)
	local at = Attributes.getNumber(instance, atKey, now)
	return math.clamp(value + rate * math.max(0, now - at), 0, max)
end

return table.freeze(Attributes)
