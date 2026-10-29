--!strict
-- Every closed set of string values that crosses the network, lives in an Attribute, or keys a config table.
-- Each set is a string-literal union type (checked statically) plus a frozen value list (checked at runtime by
-- Net validators and attribute readers). Code writes the literals directly, e.g. `local s: Enums.MoveState = "Crouching"`.

export type MoveState =
	"Standing"
	| "Sprinting"
	| "Crouching"
	| "VentCrawling"
	| "VentScurrying"
	| "DownedCrawling"
	| "Treading"
	| "Freestyle"
	| "Underwater"
	| "Hiding"
	| "Trapped"
	| "Grabbed"
	| "Parachuting"
	| "Scripted"

export type CameraState =
	"Standing"
	| "Crouching"
	| "VentCrawling"
	| "DownedCrawling"
	| "LockerPeeking"
	| "SurfaceSwimming"
	| "UnderwaterSwimming"
	| "ParachuteLookback"

export type CameraOverride = "Cutscene" | "Jumpscare" | "Spectating" | "Struggle" | "Trapped"

export type LifeState = "Lobby" | "Alive" | "Downed" | "Dead" | "Spectating"

export type ControlLock = "None" | "Trap" | "Locker" | "Jumpscare" | "Cutscene" | "Drag" | "Parachute" | "Airlock"

export type LockMode = "Anchor" | "ServerOwned"

export type CollisionMode = "Normal" | "Vent" | "Locked"

export type MonsterState =
	"Dormant"
	| "Patrol"
	| "InvestigateNoise"
	| "WallChase"
	| "VentChase"
	| "Stunned"
	| "AquaticStalk"
	| "Scripted"

export type PoseMode = "Biped" | "Hunched" | "Quadruped" | "Swim"

export type MatchPhase =
	"Booting"
	| "Lobby"
	| "Countdown"
	| "Deploying"
	| "InRun"
	| "RunEnded"
	| "Results"
	| "Resetting"

export type LevelId =
	"Level0_Basement"
	| "Level1_Hallways"
	| "Level2_ScienceHall"
	| "Level3_Gymnasium"
	| "Level4_FloodedPool"
	| "Level5_Roof"

export type LayoutId = LevelId | "Lobby"

export type LevelPhase = "Inactive" | "Ready" | "Active" | "Cleared"

export type NoiseKind =
	"CrouchWalk"
	| "SlowVentCrawl"
	| "GrateUnscrew"
	| "Walk"
	| "Sprint"
	| "Treading"
	| "Freestyle"
	| "VentScurry"
	| "GrateKick"
	| "FloorDebris"
	| "TrapSnap"
	| "Gasp"
	| "FlaskShatter"
	| "DoorSlam"
	| "Splash"
	| "FallingObject"
	| "Scripted"

export type NoiseMedium = "Air" | "Vent" | "Water"

export type NoisePriority = "Low" | "Normal" | "High" | "Critical"

export type OneShotKind =
	"Timeline"
	| "Lightning"
	| "LightBurst"
	| "GateSlam"
	| "DoorSmash"
	| "Door"
	| "Jumpscare"
	| "TrapSnap"
	| "GrateKick"
	| "LockerRip"
	| "CreatureVanish"
	| "CreatureReveal"

export type JumpscareKind = "Hallway" | "Vent" | "Locker" | "Underwater"

export type ItemId = "None" | "ChemicalFlask"

export type GrateState = "Closed" | "Unscrewing" | "Open" | "Kicked" | "Locked"

export type DoorKind = "Doorway" | "Door" | "Ajar" | "Gate" | "Airlock" | "RoofDoor" | "Boarded"

export type DoorState = "Open" | "Closed" | "Locked" | "Smashed"

export type PromptKind =
	"Unscrew"
	| "Kick"
	| "TrapPry"
	| "TrapRescue"
	| "Revive"
	| "Pickup"
	| "Hide"
	| "ParachuteGrab"
	| "Floodlight"
	| "Terminal"

export type Audience = "Self" | "Others" | "All"

export type StatKey =
	"TrapsTriggered"
	| "VentsCrawled"
	| "FlasksThrown"
	| "Stuns"
	| "TimesDowned"
	| "Revives"
	| "LockersHidden"
	| "FloorsCleared"
	| "CreditsEarned"

export type PerkId = "RustyScrewdriver" | "LithiumCell" | "AdrenalineSyringe"

export type SyringeMode = "Stamina" | "SelfRevive"

export type Difficulty = "Standard" | "Nightmare"

export type RunOutcome = "Pending" | "Escaped" | "Dead" | "Disconnected"

export type SpectateReason = "None" | "LateJoin" | "Eliminated" | "OverCapacity"

export type DataMode = "Live" | "Ephemeral" | "Guest"

export type LobbyActionKind = "Ready" | "Unready" | "VoteDifficulty" | "EquipPerk" | "UnequipPerk"

export type RoomKind =
	"Corridor"
	| "Classroom"
	| "Lab"
	| "LockerRoom"
	| "Gym"
	| "Pool"
	| "Boiler"
	| "Storage"
	| "Office"
	| "Restroom"
	| "Chase"
	| "Airlock"
	| "Stairwell"
	| "Roof"
	| "LobbyHall"

export type AnchorKind =
	"PlayerSpawn"
	| "TrapCandidate"
	| "FlaskCandidate"
	| "BatteryCandidate"
	| "PatrolWaypoint"
	| "CreatureSpawn"
	| "CreatureScarePose"
	| "Locker"
	| "ParachuteCrate"
	| "FloodlightSwitch"
	| "LabCounter"
	| "Corpse"
	| "SmashedLocker"
	| "DripPipe"
	| "Clutter"
	| "ReadyPad"
	| "Terminal"

export type TriggerKind = "ScareStep" | "FloorDebris" | "Checkpoint" | "PoolWater" | "LevelExit"

export type LightKind =
	"Fluorescent"
	| "Bulb"
	| "EmergencyRed"
	| "ClassroomGlow"
	| "Floodlight"
	| "ExitSign"
	| "BoilerGlow"

export type AcousticPreset =
	"Room"
	| "Corridor"
	| "Hall"
	| "Vent"
	| "Underwater"
	| "Outdoor"
	| "Stairwell"
	| "Basement"
	| "Lobby"

export type AudioBus = "Ambience" | "World" | "Monster" | "Player" | "Body" | "UI"

export type SurfaceKind = "Concrete" | "Tile" | "Wood" | "Metal" | "Water" | "Glass" | "Grass" | "Carpet"

export type InputAction =
	"Sprint"
	| "Crouch"
	| "Flashlight"
	| "Interact"
	| "Kick"
	| "Throw"
	| "HoldBreath"
	| "Struggle"
	| "Syringe"
	| "Ripcord"
	| "SpectatePrev"
	| "SpectateNext"
	| "Dive"
	| "Menu"
	| "Objective"

export type InputContext =
	"Menu"
	| "Cutscene"
	| "Struggle"
	| "Locker"
	| "Trapped"
	| "Downed"
	| "Vent"
	| "Swim"
	| "Parachute"
	| "OnFoot"
	| "Spectator"

export type InputKind = "Tap" | "Hold" | "Mash" | "Toggle"

export type LogLevel = "Debug" | "Info" | "Warn" | "Error"

export type RemoteKind = "Event" | "Unreliable" | "Function"

export type RemoteDirection = "ToServer" | "ToClient"

export type ProjectilePhase = "Spawn" | "Resolve"

export type ProjectileHitKind = "World" | "Creature" | "Water" | "Expired"

export type CueKind = "BreathCheck" | "Struggle" | "JumpscareVictim" | "TrapLeg" | "Toast" | "Terminal"

-- The roof jump (Player.Parachute, ParachuteService): None (no pack), Packed (a pack on the back, still on the roof),
-- Freefall (off the edge with a pack, cord not pulled), Canopy (descending under the canopy), Landed (down below,
-- held for the finale), Falling (off the edge without a pack: a fatal fall).
export type ParachuteState = "None" | "Packed" | "Freefall" | "Canopy" | "Landed" | "Falling"

local Enums = {}

Enums.MoveState = table.freeze({
	"Standing",
	"Sprinting",
	"Crouching",
	"VentCrawling",
	"VentScurrying",
	"DownedCrawling",
	"Treading",
	"Freestyle",
	"Underwater",
	"Hiding",
	"Trapped",
	"Grabbed",
	"Parachuting",
	"Scripted",
} :: { MoveState })

Enums.CameraState = table.freeze({
	"Standing",
	"Crouching",
	"VentCrawling",
	"DownedCrawling",
	"LockerPeeking",
	"SurfaceSwimming",
	"UnderwaterSwimming",
	"ParachuteLookback",
} :: { CameraState })

Enums.CameraOverride =
	table.freeze({ "Cutscene", "Jumpscare", "Spectating", "Struggle", "Trapped" } :: { CameraOverride })

Enums.LifeState = table.freeze({ "Lobby", "Alive", "Downed", "Dead", "Spectating" } :: { LifeState })

Enums.ControlLock = table.freeze({
	"None",
	"Trap",
	"Locker",
	"Jumpscare",
	"Cutscene",
	"Drag",
	"Parachute",
	"Airlock",
} :: { ControlLock })

Enums.LockMode = table.freeze({ "Anchor", "ServerOwned" } :: { LockMode })

Enums.CollisionMode = table.freeze({ "Normal", "Vent", "Locked" } :: { CollisionMode })

Enums.MonsterState = table.freeze({
	"Dormant",
	"Patrol",
	"InvestigateNoise",
	"WallChase",
	"VentChase",
	"Stunned",
	"AquaticStalk",
	"Scripted",
} :: { MonsterState })

Enums.PoseMode = table.freeze({ "Biped", "Hunched", "Quadruped", "Swim" } :: { PoseMode })

Enums.MatchPhase = table.freeze({
	"Booting",
	"Lobby",
	"Countdown",
	"Deploying",
	"InRun",
	"RunEnded",
	"Results",
	"Resetting",
} :: { MatchPhase })

-- Run order: index i is the level the squad clears i-th.
Enums.LevelId = table.freeze({
	"Level0_Basement",
	"Level1_Hallways",
	"Level2_ScienceHall",
	"Level3_Gymnasium",
	"Level4_FloodedPool",
	"Level5_Roof",
} :: { LevelId })

Enums.LayoutId = table.freeze({
	"Lobby",
	"Level0_Basement",
	"Level1_Hallways",
	"Level2_ScienceHall",
	"Level3_Gymnasium",
	"Level4_FloodedPool",
	"Level5_Roof",
} :: { LayoutId })

Enums.LevelPhase = table.freeze({ "Inactive", "Ready", "Active", "Cleared" } :: { LevelPhase })

Enums.NoiseKind = table.freeze({
	"CrouchWalk",
	"SlowVentCrawl",
	"GrateUnscrew",
	"Walk",
	"Sprint",
	"Treading",
	"Freestyle",
	"VentScurry",
	"GrateKick",
	"FloorDebris",
	"TrapSnap",
	"Gasp",
	"FlaskShatter",
	"DoorSlam",
	"Splash",
	"FallingObject",
	"Scripted",
} :: { NoiseKind })

Enums.NoiseMedium = table.freeze({ "Air", "Vent", "Water" } :: { NoiseMedium })

Enums.NoisePriority = table.freeze({ "Low", "Normal", "High", "Critical" } :: { NoisePriority })

Enums.OneShotKind = table.freeze({
	"Timeline",
	"Lightning",
	"LightBurst",
	"GateSlam",
	"DoorSmash",
	"Door",
	"Jumpscare",
	"TrapSnap",
	"GrateKick",
	"LockerRip",
	"CreatureVanish",
	"CreatureReveal",
} :: { OneShotKind })

Enums.JumpscareKind = table.freeze({ "Hallway", "Vent", "Locker", "Underwater" } :: { JumpscareKind })

Enums.ItemId = table.freeze({ "None", "ChemicalFlask" } :: { ItemId })

Enums.GrateState = table.freeze({ "Closed", "Unscrewing", "Open", "Kicked", "Locked" } :: { GrateState })

Enums.DoorKind = table.freeze({ "Doorway", "Door", "Ajar", "Gate", "Airlock", "RoofDoor", "Boarded" } :: { DoorKind })

Enums.DoorState = table.freeze({ "Open", "Closed", "Locked", "Smashed" } :: { DoorState })

Enums.PromptKind = table.freeze({
	"Unscrew",
	"Kick",
	"TrapPry",
	"TrapRescue",
	"Revive",
	"Pickup",
	"Hide",
	"ParachuteGrab",
	"Floodlight",
	"Terminal",
} :: { PromptKind })

Enums.Audience = table.freeze({ "Self", "Others", "All" } :: { Audience })

Enums.StatKey = table.freeze({
	"TrapsTriggered",
	"VentsCrawled",
	"FlasksThrown",
	"Stuns",
	"TimesDowned",
	"Revives",
	"LockersHidden",
	"FloorsCleared",
	"CreditsEarned",
} :: { StatKey })

Enums.PerkId = table.freeze({ "RustyScrewdriver", "LithiumCell", "AdrenalineSyringe" } :: { PerkId })

Enums.SyringeMode = table.freeze({ "Stamina", "SelfRevive" } :: { SyringeMode })

Enums.Difficulty = table.freeze({ "Standard", "Nightmare" } :: { Difficulty })

Enums.RunOutcome = table.freeze({ "Pending", "Escaped", "Dead", "Disconnected" } :: { RunOutcome })

Enums.SpectateReason = table.freeze({ "None", "LateJoin", "Eliminated", "OverCapacity" } :: { SpectateReason })

Enums.DataMode = table.freeze({ "Live", "Ephemeral", "Guest" } :: { DataMode })

Enums.LobbyActionKind = table.freeze({
	"Ready",
	"Unready",
	"VoteDifficulty",
	"EquipPerk",
	"UnequipPerk",
} :: { LobbyActionKind })

Enums.RoomKind = table.freeze({
	"Corridor",
	"Classroom",
	"Lab",
	"LockerRoom",
	"Gym",
	"Pool",
	"Boiler",
	"Storage",
	"Office",
	"Restroom",
	"Chase",
	"Airlock",
	"Stairwell",
	"Roof",
	"LobbyHall",
} :: { RoomKind })

Enums.AnchorKind = table.freeze({
	"PlayerSpawn",
	"TrapCandidate",
	"FlaskCandidate",
	"BatteryCandidate",
	"PatrolWaypoint",
	"CreatureSpawn",
	"CreatureScarePose",
	"Locker",
	"ParachuteCrate",
	"FloodlightSwitch",
	"LabCounter",
	"Corpse",
	"SmashedLocker",
	"DripPipe",
	"Clutter",
	"ReadyPad",
	"Terminal",
} :: { AnchorKind })

Enums.TriggerKind =
	table.freeze({ "ScareStep", "FloorDebris", "Checkpoint", "PoolWater", "LevelExit" } :: { TriggerKind })

Enums.LightKind = table.freeze({
	"Fluorescent",
	"Bulb",
	"EmergencyRed",
	"ClassroomGlow",
	"Floodlight",
	"ExitSign",
	"BoilerGlow",
} :: { LightKind })

Enums.AcousticPreset = table.freeze({
	"Room",
	"Corridor",
	"Hall",
	"Vent",
	"Underwater",
	"Outdoor",
	"Stairwell",
	"Basement",
	"Lobby",
} :: { AcousticPreset })

-- Body = sounds inside the listener (heartbeat, breathing, EMF static): EQ only, never room reverb.
Enums.AudioBus = table.freeze({ "Ambience", "World", "Monster", "Player", "Body", "UI" } :: { AudioBus })

Enums.SurfaceKind = table.freeze({
	"Concrete",
	"Tile",
	"Wood",
	"Metal",
	"Water",
	"Glass",
	"Grass",
	"Carpet",
} :: { SurfaceKind })

Enums.InputAction = table.freeze({
	"Sprint",
	"Crouch",
	"Flashlight",
	"Interact",
	"Kick",
	"Throw",
	"HoldBreath",
	"Struggle",
	"Syringe",
	"Ripcord",
	"SpectatePrev",
	"SpectateNext",
	"Dive",
	"Menu",
	"Objective",
} :: { InputAction })

-- Highest priority first: the first context on the stack that binds an action wins it.
Enums.InputContext = table.freeze({
	"Menu",
	"Cutscene",
	"Struggle",
	"Locker",
	"Trapped",
	"Downed",
	"Vent",
	"Swim",
	"Parachute",
	"OnFoot",
	"Spectator",
} :: { InputContext })

Enums.InputKind = table.freeze({ "Tap", "Hold", "Mash", "Toggle" } :: { InputKind })

Enums.LogLevel = table.freeze({ "Debug", "Info", "Warn", "Error" } :: { LogLevel })

Enums.RemoteKind = table.freeze({ "Event", "Unreliable", "Function" } :: { RemoteKind })

Enums.RemoteDirection = table.freeze({ "ToServer", "ToClient" } :: { RemoteDirection })

Enums.ProjectilePhase = table.freeze({ "Spawn", "Resolve" } :: { ProjectilePhase })

Enums.ProjectileHitKind = table.freeze({ "World", "Creature", "Water", "Expired" } :: { ProjectileHitKind })

Enums.CueKind = table.freeze({
	"BreathCheck",
	"Struggle",
	"JumpscareVictim",
	"TrapLeg",
	"Toast",
	"Terminal", -- a lobby terminal opened for this player (args.terminal = its AnchorId)
} :: { CueKind })

Enums.ParachuteState =
	table.freeze({ "None", "Packed", "Freefall", "Canopy", "Landed", "Falling" } :: { ParachuteState })

-- Runtime membership test used by validators and attribute readers.
function Enums.has<T>(list: { T }, value: unknown): boolean
	if type(value) ~= "string" then
		return false
	end
	return table.find(list, value :: any) ~= nil
end

-- Position of a level in run order (1-based), or nil for unknown ids.
function Enums.levelIndex(levelId: string): number?
	return table.find(Enums.LevelId, levelId :: any)
end

return table.freeze(Enums)
