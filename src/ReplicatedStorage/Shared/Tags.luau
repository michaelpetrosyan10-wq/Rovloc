--!strict
-- CollectionService tag registry. Never type a tag string anywhere else.

local Tags = table.freeze({
	-- Vents
	VentShaft = "VentShaft", -- duct segment part (attrs: SegmentId, LevelId, AdjacentZones)
	VentGrate = "VentGrate", -- grate model (attrs: GrateId, GrateState, Lockable, CriticalPath, NodeId)
	VentNode = "VentNode", -- Attachment at every duct junction and opening (attrs: NodeId, Links, LevelId, GrateId?)

	-- Interactive props
	BearTrap = "BearTrap",
	ChemicalItem = "ChemicalItem",
	HideableLocker = "HideableLocker",
	Hideable = "Hideable", -- every hiding spot (lockers, barrels, cabinets); its HideKind attribute says which
	ParachutePack = "ParachutePack",
	BatteryPickup = "BatteryPickup",
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
	LevelExit = "LevelExit",
	-- spec v2's trigger kinds (Enums.TriggerKind)
	GatherZone = "GatherZone", -- a squad gathers here before a scene
	ShutterLine = "ShutterLine", -- the bell tower's shutter: the Last Run is saved by the first runner under it
	FallZone = "FallZone", -- a fall that lands on a deck (never damage)
	ChuteHatch = "ChuteHatch", -- the Back Lot's chute into the basement
	JumpGate = "JumpGate", -- the roof's jump

	-- Navigation & spawning
	PatrolWaypoint = "PatrolWaypoint",
	SpawnAnchor = "SpawnAnchor",
	MonsterPassthrough = "MonsterPassthrough",
	CreatureBlock = "CreatureBlock", -- the invisible wall across an opening into a Gap (attrs: DoorId, LevelId)

	-- Atmosphere
	LevelLight = "LevelLight", -- attrs: LightKind, LevelId, ZoneId, FlickerGroup, BaseBrightness
	AmbientEmitter = "AmbientEmitter", -- attrs: Preset, LevelId
	DripPipe = "DripPipe",
	SteamVent = "SteamVent", -- a tunnel's leaking relief valve (its nozzle part; a "Steam" ParticleEmitter under it)
	Corpse = "Corpse",

	-- Actors
	Creature = "Creature",
})

return Tags
