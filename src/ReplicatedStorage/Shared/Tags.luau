--!strict
-- CollectionService tag registry. Never type a tag string anywhere else.

local Tags = table.freeze({
	-- Vents
	VentShaft = "VentShaft", -- duct segment part (attrs: SegmentId, LevelId, AdjacentZones, Submerged)
	VentGrate = "VentGrate", -- grate model (attrs: GrateId, GrateState, Lockable, CriticalPath, NodeId)
	VentNode = "VentNode", -- Attachment at every duct junction and opening (attrs: NodeId, Links, LevelId, GrateId?)

	-- Interactive props
	BearTrap = "BearTrap",
	ChemicalItem = "ChemicalItem",
	HideableLocker = "HideableLocker",
	ParachutePack = "ParachutePack",
	BatteryPickup = "BatteryPickup",
	FloodlightSwitch = "FloodlightSwitch",
	ObjectiveItem = "ObjectiveItem", -- a floor objective's carryable item (attrs: Floor, Step, ObjectiveId, AnchorId)
	ObjectiveStation = "ObjectiveStation", -- where a floor objective's step is worked (attrs: Floor, Step, ObjectiveId)
	ExitLock = "ExitLock", -- the lock on a floor's exit (attrs: Floor, Step, ObjectiveId, LockVariant, Locked)
	Interactable = "Interactable", -- any part/model hosting a server-timed ProximityPrompt channel

	-- Doors
	AirlockDoor = "AirlockDoor",
	ScriptedDoor = "ScriptedDoor", -- DoorId = HallwayGate | RoofStairDoor | ClassroomDoor

	-- Volumes (polled by ZoneService; never Touched)
	Zone = "Zone", -- one per room (attrs: ZoneId, LevelId, AcousticPreset)
	CheckpointVolume = "CheckpointVolume",
	ScareTrigger = "ScareTrigger",
	FloorDebris = "FloorDebris",
	PoolWater = "PoolWater",
	LevelExit = "LevelExit",

	-- Navigation & spawning
	PatrolWaypoint = "PatrolWaypoint",
	SpawnAnchor = "SpawnAnchor",
	MonsterPassthrough = "MonsterPassthrough",

	-- Atmosphere
	LevelLight = "LevelLight", -- attrs: LightKind, LevelId, ZoneId, FlickerGroup, BaseBrightness
	AmbientEmitter = "AmbientEmitter", -- attrs: Preset, LevelId
	DripPipe = "DripPipe",
	Corpse = "Corpse",

	-- Actors
	Creature = "Creature",
})

return Tags
