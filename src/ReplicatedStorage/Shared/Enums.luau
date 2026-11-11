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
	| "Hiding"
	| "Trapped"
	| "Parachuting"
	| "Scripted"

export type CameraState =
	"Standing"
	| "Crouching"
	| "VentCrawling"
	| "DownedCrawling"
	| "LockerPeeking"
	| "ParachuteLookback"

export type CameraOverride = "Cutscene" | "Jumpscare" | "Spectating" | "Trapped"

export type LifeState = "Lobby" | "Alive" | "Downed" | "Dead" | "Spectating"

export type ControlLock = "None" | "Trap" | "Locker" | "Jumpscare" | "Cutscene" | "Parachute" | "Airlock"

export type LockMode = "Anchor" | "ServerOwned"

-- Crouch: a crouched player collides only through the parts below a crawlway's mouth (CollisionService).
export type CollisionMode = "Normal" | "Crouch" | "Vent" | "Locked"

-- Patrol is the Stalk and WallChase the Chase (docs/MONSTER.md). The Creature never enters a duct: there is no
-- VentChase. Search (the hiding spots near the last seen point), HidingResponse (it saw someone climb into a hiding
-- spot) and Teleport (the warp beside a player, then the stalk) are the Tall Man's.
export type MonsterState =
	"Dormant"
	| "Patrol"
	| "InvestigateNoise"
	| "WallChase"
	| "Search"
	| "HidingResponse"
	| "Teleport"
	| "Stunned"
	| "Scripted"

-- The view contract's one-shot actions (docs/MONSTER.md section 12): the Creature's Action attribute.
export type CreatureAction = "Stare" | "ReachIn" | "LookAway" | "FadeOut" | "FadeIn" | "Jumpscare"

-- A hiding spot's kind (tag Hideable, attribute HideKind).
export type HideKind = "Locker" | "Barrel" | "Cabinet"

export type PoseMode = "Biped" | "Hunched" | "Quadruped"

export type MatchPhase =
	"Booting"
	| "Lobby"
	| "Countdown"
	| "Deploying"
	| "InRun"
	| "RunEnded"
	| "Results"
	| "Resetting"

-- The six playable levels (docs/design/game-spec-v2.md 0.1, 4.2): the four school levels, which the world builder
-- builds (WorldConfig.LevelOrder), then the two city levels, declared ahead of their builders. Every table keyed by a
-- stage is keyed by these ids (or a SetId), never by a level's number.
export type LevelId =
	"Level0_Basement"
	| "Level1_Hallways"
	| "Level2_Auditorium"
	| "Level3_Roof"
	| "City1_Rooftops"
	| "City2_Airport"

-- The three sets: stages that are scenes rather than levels (StageConfig.Order).
export type SetId = "BackLot" | "Runway" | "Bahamas"

-- A stage of the run (StageConfig): a level or a set.
export type StageId = LevelId | SetId

-- A blueprint id: the lobby or a level. Enums.LayoutId lists the ones the world builder has a layout for (the lobby
-- and the school levels); the city levels have none yet.
export type LayoutId = "Lobby" | LevelId

export type LevelPhase = "Inactive" | "Ready" | "Active" | "Cleared"

export type NoiseKind =
	"CrouchWalk"
	| "SlowVentCrawl"
	| "GrateUnscrew"
	| "Walk"
	| "Sprint"
	| "VentScurry"
	| "GrateKick"
	| "FloorDebris"
	| "TrapSnap"
	| "Gasp"
	| "FlaskShatter"
	| "DoorSlam"
	| "FallingObject"
	| "Scripted"
	-- floor objectives: a working hold once a second, a loud single action
	| "ObjectiveWork"
	| "ObjectiveClunk"
	-- the Tall Man's ears (docs/MONSTER.md 3.1): a landing after a fall, getting into a hiding spot (quietly, or
	-- straight off a sprint), co-op text chat
	| "JumpLand"
	| "HideEnter"
	| "HideEnterHurried"
	| "ChatMessage"

export type NoiseMedium = "Air" | "Vent"

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
	-- a teleport's warning (args: spot, target, seconds): the lights near the spot stutter, a hiss rises there
	| "TeleportWarning"

export type JumpscareKind = "Hallway" | "Vent" | "Locker"

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
	| "Terminal"
	-- floor objectives (ObjectiveConfig)
	| "FitFuse"
	| "Breaker"
	| "Unlock"
	| "Locked"
	-- a teammate drags a hider out of their hiding spot (THRESHOLD's throw)
	| "PullOut"

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

export type Difficulty = "Standard" | "Nightmare"

export type RunOutcome = "Pending" | "Escaped" | "Dead" | "Disconnected"

export type SpectateReason = "None" | "LateJoin" | "Eliminated" | "OverCapacity"

export type DataMode = "Live" | "Ephemeral" | "Guest"

export type LobbyActionKind = "Ready" | "Unready" | "VoteDifficulty" | "EquipPerk" | "UnequipPerk"

export type RoomKind =
	"Corridor"
	| "Classroom"
	| "Boiler"
	| "Storage"
	| "Office"
	| "Restroom"
	| "Chase"
	| "Airlock"
	| "Stairwell"
	| "Roof"
	| "LobbyHall"
	-- tunnel floors (TunnelPlanner): corridors, tall pipe galleries, crawlways the Creature cannot enter, and the
	-- solid ground between them (fill: no floor walked, no zone, no lights)
	| "Tunnel"
	| "Gallery"
	| "Crawlway"
	| "Solid"

export type AnchorKind =
	"PlayerSpawn"
	| "TrapCandidate"
	| "FlaskCandidate"
	| "BatteryCandidate"
	| "PatrolWaypoint"
	| "CreatureSpawn"
	| "CreatureScarePose"
	| "Locker"
	| "Barrel" -- a steel drum to climb into (tunnel hiding spot)
	| "Cabinet" -- a tall slatted steel cabinet (tunnel hiding spot)
	| "ParachuteCrate"
	| "Corpse"
	| "SmashedLocker"
	| "DripPipe"
	| "Clutter"
	| "ReadyPad"
	| "Terminal"
	-- floor objectives: item candidate spots (RunDirector picks the ones a run uses) ...
	| "FuseCandidate"
	| "MasterKeyCandidate"
	-- ... and the stations and locks
	| "BreakerPanel"
	| "ExitLock"

export type TriggerKind = "ScareStep" | "FloorDebris" | "Checkpoint" | "LevelExit"

export type LightKind = "Fluorescent" | "Bulb" | "EmergencyRed" | "ClassroomGlow" | "ExitSign" | "BoilerGlow"

export type AcousticPreset =
	"Room"
	| "Corridor"
	| "Hall"
	| "Vent"
	| "Outdoor"
	| "Stairwell"
	| "Basement"
	| "Lobby"
	-- the tunnel floors: a narrow pipe run, a tall gallery, a culvert you crawl through
	| "Tunnel"
	| "Gallery"
	| "Crawlway"

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
	| "Ripcord"
	| "SpectatePrev"
	| "SpectateNext"
	| "Menu"
	| "Objective"

export type InputContext =
	"Menu"
	| "Cutscene"
	| "Locker"
	| "Trapped"
	| "Downed"
	| "Vent"
	| "Parachute"
	| "OnFoot"
	| "Spectator"

export type InputKind = "Tap" | "Hold" | "Mash" | "Toggle"

export type LogLevel = "Debug" | "Info" | "Warn" | "Error"

export type RemoteKind = "Event" | "Unreliable" | "Function"

export type RemoteDirection = "ToServer" | "ToClient"

export type ProjectilePhase = "Spawn" | "Resolve"

export type ProjectileHitKind = "World" | "Creature" | "Expired"

-- Scare: a moment for one player alone (args.scare: ScareKind): a teleport's reveal, a fake-out, the stare's sting,
-- the chase starting or giving up on them, the torch stuttering in a teleport's warning, a hiding spot's warning knock
-- or its shove out.
export type CueKind = "BreathCheck" | "JumpscareVictim" | "TrapLeg" | "Toast" | "Terminal" | "Scare"

export type ScareKind =
	"Reveal"
	| "Fakeout"
	| "Stare"
	| "ChaseStart"
	| "ChaseEnd"
	| "GiveUp"
	| "TorchStutter"
	| "HideWarn"
	| "HideKick"

-- The roof jump (Player.Parachute, ParachuteService): None (no pack), Packed (a pack on the back, still on the roof),
-- Freefall (off the edge with a pack, cord not pulled), Canopy (descending under the canopy), Landed (down below,
-- held until the jumper's escape is counted).
export type ParachuteState = "None" | "Packed" | "Freefall" | "Canopy" | "Landed"

local Enums = {}

Enums.MoveState = table.freeze({
	"Standing",
	"Sprinting",
	"Crouching",
	"VentCrawling",
	"VentScurrying",
	"DownedCrawling",
	"Hiding",
	"Trapped",
	"Parachuting",
	"Scripted",
} :: { MoveState })

Enums.CameraState = table.freeze({
	"Standing",
	"Crouching",
	"VentCrawling",
	"DownedCrawling",
	"LockerPeeking",
	"ParachuteLookback",
} :: { CameraState })

Enums.CameraOverride = table.freeze({ "Cutscene", "Jumpscare", "Spectating", "Trapped" } :: { CameraOverride })

Enums.LifeState = table.freeze({ "Lobby", "Alive", "Downed", "Dead", "Spectating" } :: { LifeState })

Enums.ControlLock = table.freeze({
	"None",
	"Trap",
	"Locker",
	"Jumpscare",
	"Cutscene",
	"Parachute",
	"Airlock",
} :: { ControlLock })

Enums.LockMode = table.freeze({ "Anchor", "ServerOwned" } :: { LockMode })

Enums.CollisionMode = table.freeze({ "Normal", "Crouch", "Vent", "Locked" } :: { CollisionMode })

Enums.MonsterState = table.freeze({
	"Dormant",
	"Patrol",
	"InvestigateNoise",
	"WallChase",
	"Search",
	"HidingResponse",
	"Teleport",
	"Stunned",
	"Scripted",
} :: { MonsterState })

Enums.CreatureAction =
	table.freeze({ "Stare", "ReachIn", "LookAway", "FadeOut", "FadeIn", "Jumpscare" } :: { CreatureAction })

Enums.HideKind = table.freeze({ "Locker", "Barrel", "Cabinet" } :: { HideKind })

Enums.PoseMode = table.freeze({ "Biped", "Hunched", "Quadruped" } :: { PoseMode })

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

-- Run order: index i is the level the squad plays i-th.
Enums.LevelId = table.freeze({
	"Level0_Basement",
	"Level1_Hallways",
	"Level2_Auditorium",
	"Level3_Roof",
	"City1_Rooftops",
	"City2_Airport",
} :: { LevelId })

Enums.SetId = table.freeze({ "BackLot", "Runway", "Bahamas" } :: { SetId })

Enums.LayoutId = table.freeze({
	"Lobby",
	"Level0_Basement",
	"Level1_Hallways",
	"Level2_Auditorium",
	"Level3_Roof",
} :: { LayoutId })

Enums.LevelPhase = table.freeze({ "Inactive", "Ready", "Active", "Cleared" } :: { LevelPhase })

Enums.NoiseKind = table.freeze({
	"CrouchWalk",
	"SlowVentCrawl",
	"GrateUnscrew",
	"Walk",
	"Sprint",
	"VentScurry",
	"GrateKick",
	"FloorDebris",
	"TrapSnap",
	"Gasp",
	"FlaskShatter",
	"DoorSlam",
	"FallingObject",
	"Scripted",
	"ObjectiveWork",
	"ObjectiveClunk",
	"JumpLand",
	"HideEnter",
	"HideEnterHurried",
	"ChatMessage",
} :: { NoiseKind })

Enums.NoiseMedium = table.freeze({ "Air", "Vent" } :: { NoiseMedium })

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
	"TeleportWarning",
} :: { OneShotKind })

Enums.JumpscareKind = table.freeze({ "Hallway", "Vent", "Locker" } :: { JumpscareKind })

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
	"Terminal",
	"FitFuse",
	"Breaker",
	"Unlock",
	"Locked",
	"PullOut",
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
	"Boiler",
	"Storage",
	"Office",
	"Restroom",
	"Chase",
	"Airlock",
	"Stairwell",
	"Roof",
	"LobbyHall",
	"Tunnel",
	"Gallery",
	"Crawlway",
	"Solid",
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
	"Barrel",
	"Cabinet",
	"ParachuteCrate",
	"Corpse",
	"SmashedLocker",
	"DripPipe",
	"Clutter",
	"ReadyPad",
	"Terminal",
	"FuseCandidate",
	"MasterKeyCandidate",
	"BreakerPanel",
	"ExitLock",
} :: { AnchorKind })

Enums.TriggerKind = table.freeze({ "ScareStep", "FloorDebris", "Checkpoint", "LevelExit" } :: { TriggerKind })

Enums.LightKind = table.freeze({
	"Fluorescent",
	"Bulb",
	"EmergencyRed",
	"ClassroomGlow",
	"ExitSign",
	"BoilerGlow",
} :: { LightKind })

Enums.AcousticPreset = table.freeze({
	"Room",
	"Corridor",
	"Hall",
	"Vent",
	"Outdoor",
	"Stairwell",
	"Basement",
	"Lobby",
	"Tunnel",
	"Gallery",
	"Crawlway",
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
	"Ripcord",
	"SpectatePrev",
	"SpectateNext",
	"Menu",
	"Objective",
} :: { InputAction })

-- Highest priority first: the first context on the stack that binds an action wins it.
Enums.InputContext = table.freeze({
	"Menu",
	"Cutscene",
	"Locker",
	"Trapped",
	"Downed",
	"Vent",
	"Parachute",
	"OnFoot",
	"Spectator",
} :: { InputContext })

Enums.InputKind = table.freeze({ "Tap", "Hold", "Mash", "Toggle" } :: { InputKind })

Enums.LogLevel = table.freeze({ "Debug", "Info", "Warn", "Error" } :: { LogLevel })

Enums.RemoteKind = table.freeze({ "Event", "Unreliable", "Function" } :: { RemoteKind })

Enums.RemoteDirection = table.freeze({ "ToServer", "ToClient" } :: { RemoteDirection })

Enums.ProjectilePhase = table.freeze({ "Spawn", "Resolve" } :: { ProjectilePhase })

Enums.ProjectileHitKind = table.freeze({ "World", "Creature", "Expired" } :: { ProjectileHitKind })

Enums.CueKind = table.freeze({
	"BreathCheck",
	"JumpscareVictim",
	"TrapLeg",
	"Toast",
	"Terminal", -- a lobby terminal opened for this player (args.terminal = its AnchorId)
	"Scare",
} :: { CueKind })

Enums.ScareKind = table.freeze({
	"Reveal",
	"Fakeout",
	"Stare",
	"ChaseStart",
	"ChaseEnd",
	"GiveUp",
	"TorchStutter",
	"HideWarn",
	"HideKick",
} :: { ScareKind })

Enums.ParachuteState = table.freeze({ "None", "Packed", "Freefall", "Canopy", "Landed" } :: { ParachuteState })

-- Runtime membership test used by validators and attribute readers.
function Enums.has<T>(list: { T }, value: unknown): boolean
	if type(value) ~= "string" then
		return false
	end
	return table.find(list, value :: any) ~= nil
end

return table.freeze(Enums)
