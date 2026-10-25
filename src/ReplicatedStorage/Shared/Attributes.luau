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
	HeldItem = "HeldItem",
	SyringeCharges = "SyringeCharges",
	Loadout = "Loadout", -- comma-separated PerkIds equipped for the next / current run
	DownedCount = "DownedCount",
	BleedoutEndsAt = "BleedoutEndsAt",
	Ready = "Ready",
	DifficultyVote = "DifficultyVote",
	DataLoaded = "DataLoaded",
	Credits = "Credits",
	RunOutcome = "RunOutcome",
	SpectateReason = "SpectateReason",
	SpectateTargetUserId = "SpectateTargetUserId",
	ZoneId = "ZoneId",
	LevelId = "LevelId",
	WorldAcked = "WorldAcked",
	DevTools = "DevTools", -- true when this player may use dev commands (Studio or allowlist)
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
	DevRun = "DevRun",
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
	FromLevel = "FromLevel",
	ToLevel = "ToLevel",
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
