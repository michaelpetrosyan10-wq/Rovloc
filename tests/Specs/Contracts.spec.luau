--!strict
-- The contracts spec v2 adds (docs/design/game-spec-v2.md 6, "Contracts WP01 adds"), each held to the spec's text: the
-- match phase, room kinds, gate and hide skins, anchor and trigger kinds, move and camera states with their eyes, input
-- contexts and actions with the control tables' bindings, the noises and their loudness, the prompt kinds, the settings
-- and first-time hints with their strings; the tags and attributes that carry them; the city's objectives as data; the
-- stun flasks per stage; every exported config plain data; the prop builder registry that finds its own builders.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local NoiseConfig = require(ReplicatedStorage.Shared.Config.NoiseConfig)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Props = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local StageConfig = require(ReplicatedStorage.Shared.Config.StageConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local TutorialConfig = require(ReplicatedStorage.Shared.Config.TutorialConfig)
local RuleGolden = require(script.Parent.Parent.RuleGolden)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local function has(list: { any }, values: { string }, t: Expect, what: string)
	for _, value in values do
		t.truthy(table.find(list, value :: any) ~= nil, what .. " has " .. value)
	end
	local seen: { [any]: boolean } = {}
	for _, value in list do
		t.falsy(seen[value], what .. ": " .. tostring(value) .. " once")
		seen[value] = true
	end
end

local function names(list: { Enum.KeyCode | Enum.UserInputType }): string
	local out: { string } = {}
	for _, input in list do
		table.insert(out, input.Name)
	end
	return table.concat(out, ",")
end

return {
	["the match phase Prologue comes between Deploying and InRun"] = function(t: Expect)
		local at = table.find(Enums.MatchPhase, "Prologue")
		t.truthy(at ~= nil, "Prologue")
		t.eq(Enums.MatchPhase[(at :: number) - 1], "Deploying")
		t.eq(Enums.MatchPhase[(at :: number) + 1], "InRun")
	end,

	["room kinds, gate skins, hide skins, anchor and trigger kinds"] = function(t: Expect)
		has(
			Enums.RoomKind,
			{ "Foyer", "Auditorium", "Stage", "Dressing", "Tower", "Hangar", "Yard", "Gap" },
			t,
			"RoomKind"
		)
		has(Enums.GateSkin, { "BrickFlat", "HangarDoor", "MeshGate", "Shutter" }, t, "GateSkin")
		t.eq(#Enums.GateSkin, 4)
		local skins: { [string]: { string } } = {
			Locker = { "Wardrobe", "MeterCloset", "ToolCrib" },
			Cabinet = {
				"FilmCabinet",
				"TicketBooth",
				"PropTrunk",
				"RoadCase",
				"ACHousing",
				"BaggageCart",
				"ToolChest",
				"CheckInDesk",
			},
			Barrel = { "TarDrum", "RainButt", "OilDrum" },
		}
		local count = 0
		for kind, list in skins do
			for _, skin in list do
				count += 1
				t.truthy(table.find(Enums.HideSkin, skin :: any) ~= nil, skin)
				t.eq(Enums.HideSkinKind[skin], kind, skin .. " dresses a " .. kind)
				t.truthy(Strings.has("Prompt.Hide." .. skin), skin .. " has its name")
			end
		end
		t.eq(#Enums.HideSkin, count, "every skin of 3.6, no other")
		has(Enums.AnchorKind, {
			"FilmReelCandidate",
			"Projector",
			"SpeakerPoint",
			"GhostLight",
			"CourseNode",
			"LeapStrip",
			"RevolverLockbox",
			"JumpKit",
			"FeederCandidate",
			"FuelCanCandidate",
			"WingFiller",
			"HangarSwitch",
			"CabinDoor",
			"Seat",
			"LandingMark",
			"CutsceneMark",
			"BinStart",
			"WallPhone",
			"Billboard",
			"FlapBoard",
		}, t, "AnchorKind")
		has(Enums.TriggerKind, { "GatherZone", "Shutter", "FallZone", "ChuteHatch", "JumpGate" }, t, "TriggerKind")
		for _, tag in
			{ Tags.GatherZone, Tags.ShutterLine, Tags.FallZone, Tags.ChuteHatch, Tags.JumpGate, Tags.CreatureBlock }
		do
			t.truthy(type(tag) == "string" and tag ~= "", "a tag")
		end
		local W = Attributes.World
		t.truthy(W.HideSkin and W.GateSkin and W.GateHidden and W.Drop, "world attributes")
		local P = Attributes.Player
		t.truthy(P.RadarCharges and P.StageRespawns and P.RunRespawns and P.SyringeRespawns, "lives and radar")
		t.truthy(P.GetUpUsed and P.IgnoredUntil, "the get-up and the grace")
		local M = Attributes.Match
		t.truthy(M.RadarScanBy and M.RadarScanAt and M.RadarScanSeconds and M.ChaseFailures, "the squad's scan, chases")
	end,

	["move states Sliding, Leaping, Seated with their eyes; camera states Cinematic, Cockpit, LookBack"] = function(
		t: Expect
	)
		has(Enums.MoveState, { "Sliding", "Leaping", "Seated" }, t, "MoveState")
		has(Enums.CameraState, { "Cinematic", "Cockpit", "LookBack" }, t, "CameraState")
		local eye = CameraConfig.EyeHeightAboveRoot
		t.eq(eye.Sliding, eye.Crouching, "a slide's eye is a crouch's")
		t.eq(eye.Seated, 1.2, "a seat's eye is 1.2 over the root")
		t.eq(eye.Leaping, eye.Sprinting, "the leap's eye rides the curve at the sprint height")
		for _, state in Enums.MoveState do
			t.eq(type(eye[state]), "number", state .. " has an eye")
		end
		for _, state in Enums.CameraState do
			t.eq(typeof(CameraConfig.StateOffsets[state]), "Vector3", state .. " has an offset")
		end
	end,

	["input contexts and actions: Radar for Objective, the spec's keys, pads and touch buttons"] = function(t: Expect)
		has(Enums.InputContext, { "Revolver", "Cockpit", "Seat" }, t, "InputContext")
		local onFoot = table.find(Enums.InputContext, "OnFoot") :: number
		for _, context in { "Revolver", "Cockpit", "Seat" } do
			t.truthy((table.find(Enums.InputContext, context :: any) :: number) < onFoot, context .. " above OnFoot")
		end
		t.falsy(table.find(Enums.InputAction, "Objective" :: any), "Objective became Radar")
		has(Enums.InputAction, { "Radar", "LookBack", "Skip", "Fire", "LowerGun", "Steer", "PullUp" }, t, "InputAction")
		local B = InputConfig.Bindings
		local want: { [string]: { keyboard: string, gamepad: string, touch: string?, kind: string } } = {
			Radar = { keyboard = "Tab", gamepad = "DPadRight", touch = "Input.Radar", kind = "Tap" },
			LookBack = { keyboard = "V", gamepad = "ButtonR3", touch = "Input.LookBack", kind = "Hold" },
			Skip = { keyboard = "Return", gamepad = "ButtonY", touch = "Input.Skip", kind = "Hold" },
			Fire = { keyboard = "MouseButton1", gamepad = "ButtonR2", touch = "Input.Fire", kind = "Tap" },
			LowerGun = { keyboard = "G", gamepad = "DPadDown", touch = "Input.LowerGun", kind = "Hold" },
			Steer = { keyboard = "A,D,Left,Right", gamepad = "Thumbstick1", kind = "Hold" },
			PullUp = { keyboard = "Space,S", gamepad = "ButtonA", touch = "Input.PullUp", kind = "Hold" },
		}
		for action, spec in want do
			local binding = B[action]
			t.truthy(binding ~= nil, action)
			if not binding then
				continue
			end
			t.eq(names(binding.keyboard), spec.keyboard, action .. " keyboard")
			t.eq(names(binding.gamepad), spec.gamepad, action .. " gamepad")
			t.eq(binding.kind, spec.kind, action .. " kind")
			local touch = binding.touch
			t.eq(if touch then touch.label else nil, spec.touch, action .. " touch button")
			if touch then
				t.truthy(Strings.has(touch.label), touch.label)
			end
		end
		t.eq((B.Fire.touch :: InputConfig.TouchButton).size, 120, "FIRE is a 120 px button")
		t.eq((B.PullUp.touch :: InputConfig.TouchButton).size, 130, "PULL UP is 130 px")
		local axis = B.Steer.axis :: InputConfig.Axis
		t.eq(names(axis.negative), "A,Left")
		t.eq(names(axis.positive), "D,Right")
		t.eq(axis.stick, Enum.KeyCode.Thumbstick1)
		t.eq(#axis.pads, 2, "two steering pads")
		for _, pad in axis.pads do
			t.eq(pad.size, 110, "each 110 px")
			t.truthy(Strings.has(pad.label), pad.label)
		end
		for _, key in { Enum.KeyCode.Space, Enum.KeyCode.ButtonB } do
			t.falsy(table.find(B.Skip.keyboard, key) or table.find(B.Skip.gamepad, key), "never Space or B for Skip")
		end
		t.truthy(table.find(B.Crouch.keyboard, Enum.KeyCode.C) and table.find(B.Crouch.gamepad, Enum.KeyCode.ButtonB))
		t.truthy(table.find(B.Fire.contexts, "Revolver") and table.find(B.LowerGun.contexts, "Revolver"))
		t.truthy(table.find(B.Steer.contexts, "Cockpit") and table.find(B.PullUp.contexts, "Cockpit"))
		t.truthy(table.find(B.LookBack.contexts, "OnFoot") and table.find(B.LookBack.contexts, "Seat"), "look back")
		t.falsy(table.find(B.Throw.contexts, "Revolver"), "the revolver replaces Throw")
		t.eq(InputConfig.exportMeta().bindings.Radar.keyboard[1], "Tab", "exportMeta by key names")
	end,

	["the noises and their loudness"] = function(t: Expect)
		local want: { [string]: { number | string } } = {
			Slide = { 60, "High" },
			HardLanding = { 60, "High" },
			LampStrike = { 130, "Critical" },
			FilmScore = { 90, "Normal" },
			ProjectorRun = { 30, "Normal" },
			MotorStart = { 130, "Critical" },
			MotorRun = { 90, "Normal" },
			EngineStart = { 170, "Critical" },
		}
		for kind, spec in want do
			t.truthy(table.find(Enums.NoiseKind, kind :: any) ~= nil, kind)
			local noise = NoiseConfig.Kinds[kind]
			t.truthy(noise and noise.radius == spec[1] and noise.priority == spec[2], kind)
		end
		t.eq(NoiseConfig.Kinds.MotorRun.interval, 4, "the door's motor every 4 s")
		for _, kind in Enums.NoiseKind do
			t.truthy(NoiseConfig.Kinds[kind] ~= nil, kind .. " has its noise")
		end
	end,

	["the prompt kinds and their strings"] = function(t: Expect)
		local kinds = {
			"PushLid",
			"ClimbIn",
			"WakeHim",
			"AnswerPhone",
			"ThreadReel",
			"StrikeLamp",
			"GetUp",
			"OpenLockbox",
			"TakeRevolver",
			"PickUpRevolver",
			"CloseFeeder",
			"FuelPlane",
			"HangarSwitch",
			"Board",
			"StartEngines",
		}
		has(Enums.PromptKind, kinds, t, "PromptKind")
		for _, kind in kinds do
			t.truthy(Strings.has("Prompt." .. kind), kind)
		end
	end,

	["the settings: leap assist, the monster's voice and names, the voice volume, cutscenes on replays"] = function(
		t: Expect
	)
		local function choice(key: string): SettingsSchema.ChoiceSetting
			local setting = SettingsSchema.get(key)
			assert(setting and setting.kind == "Choice", key)
			return setting :: SettingsSchema.ChoiceSetting
		end
		local leap = choice("LeapAssist")
		t.eq(table.concat(leap.options, ","), "Auto,On,Off")
		t.eq(leap.options[leap.default], "Auto", "on for touch and gamepad, off for the keyboard")
		local voice = choice("MonsterVoice")
		t.eq(table.concat(voice.options, ","), "VoiceAndSubtitles,SubtitlesOnly")
		t.eq(voice.default, 1)
		local replays = choice("ReplayCutscenes")
		t.eq(replays.options[replays.default], "Short")
		local sayNames = SettingsSchema.get("SayNames")
		t.truthy(sayNames and sayNames.kind == "Bool" and sayNames.default == true, "the monster says names: On")
		local volume = SettingsSchema.get("VoiceVolume")
		t.truthy(volume and volume.kind == "Number", "the voice volume")
		for _, setting in SettingsSchema.visible() do
			t.truthy(Strings.has(setting.label), setting.label)
			if setting.kind == "Choice" then
				for _, option in (setting :: SettingsSchema.ChoiceSetting).options do
					t.truthy(Strings.has(setting.label .. "." .. option), setting.label .. "." .. option)
					t.truthy(
						Strings.has(setting.label .. "." .. option .. ".Info"),
						setting.label .. "." .. option .. ".Info"
					)
				end
			end
		end
		t.eq(SettingsSchema.exportMeta().list[1].key, "Graphics", "exportMeta in menu order")
	end,

	["the first-time hints: Hurdle, Slide, Leap, Radar, GetUp, Revolver, Takeoff"] = function(t: Expect)
		for _, id in { "Hurdle", "Slide", "Leap", "Radar", "GetUp", "Revolver", "Takeoff" } do
			local found: TutorialConfig.Hint? = nil
			for _, hint in TutorialConfig.Hints do
				if hint.id == id then
					found = hint
				end
			end
			t.truthy(found ~= nil, id)
			if found then
				t.truthy(Strings.has(found.text), found.text)
				local flag = SettingsSchema.get(found.setting)
				t.truthy(flag and flag.kind == "Bool" and flag.hidden and flag.default == false, found.setting)
			end
		end
	end,

	["stages: the seven playable, the five sneaking"] = function(t: Expect)
		t.eq(
			table.concat(StageConfig.Playable, ","),
			"Level0_Basement,Level1_Hallways,Level2_Auditorium,Level3_Roof,City1_Rooftops,City2_Airport,Runway"
		)
		t.eq(
			table.concat(StageConfig.Sneaking, ","),
			"Level0_Basement,Level1_Hallways,Level2_Auditorium,City1_Rooftops,City2_Airport"
		)
		t.falsy(
			StageConfig.isPlayable("BackLot") or StageConfig.isPlayable("Bahamas") or StageConfig.isPlayable("Nope")
		)
		t.falsy(StageConfig.isSneaking("Level3_Roof") or StageConfig.isSneaking("Runway"))
	end,

	["the city's objectives as data: the feeders (3 of 6, both arcs) and Preflight"] = function(t: Expect)
		local roofs = ObjectiveConfig.forLevel("City1_Rooftops")
		t.truthy(roofs ~= nil, "floor 4")
		if roofs then
			t.eq(roofs.floor, 4)
			t.eq(roofs.id, "PowerSkybridge")
			local stations = roofs.stations :: ObjectiveConfig.StationSpec
			t.truthy(stations.prop == "FeederCabinet" and stations.candidate == "FeederCandidate", "the feeders")
			t.truthy(stations.count == 3 and stations.arcs == true, "3 of 6 on both arcs")
			t.eq(#roofs.steps, 1)
			t.truthy(roofs.steps[1].id == "CloseFeeders" and roofs.steps[1].count == 3)
			t.truthy(roofs.lockStep == "CloseFeeders" and roofs.lockVariant == "Keypad")
			t.eq(ObjectiveConfig.hold(roofs, "CloseFeeder"), 3)
		end
		local airport = ObjectiveConfig.forLevel("City2_Airport")
		t.truthy(airport ~= nil, "floor 5")
		if airport then
			t.eq(airport.floor, 5)
			t.eq(airport.id, "Preflight")
			local item = airport.item :: ObjectiveConfig.ItemSpec
			t.truthy(item.prop == "FuelCan" and item.candidate == "FuelCanCandidate" and item.count == 2, "2 cans")
			t.truthy(item.hold == 0.6 and item.object == "Prompt.FuelCan")
			local ids: { string } = {}
			for _, step in airport.steps do
				table.insert(ids, step.id .. "x" .. step.count)
			end
			t.eq(table.concat(ids, ","), "FindFuelx2,FuelPlanex2,OpenHangarx1,Boardx1")
			t.eq(airport.steps[3].seconds, 20, "the door's 20 s")
			t.eq(airport.lockStep, "Board")
			local holds: { [string]: number } = { FuelPlane = 2.5, HangarSwitch = 2, Board = 0.8, StartEngines = 3 }
			for kind, seconds in holds do
				t.eq(ObjectiveConfig.hold(airport, kind), seconds, kind)
			end
		end
		local auditorium = ObjectiveConfig.forLevel("Level2_Auditorium")
		t.truthy(auditorium and auditorium.id == "ReachExit", "the Auditorium stays the interim crossing")
		t.eq(ObjectiveConfig.forLevel("Level3_Roof"), nil, "the roof has no floor objective")
		local vocabulary = { Find = true, Deliver = true, Work = true, Stations = true, Survive = true, Reach = true }
		for _, spec in ObjectiveConfig.Floors do
			t.truthy(Strings.has(spec.title), spec.title)
			t.eq(StageConfig.floorOf(spec.levelId), spec.floor, spec.levelId .. " floor")
			for _, step in spec.steps do
				t.truthy(vocabulary[step.kind], spec.id .. "/" .. step.id .. " kind " .. tostring(step.kind))
				t.truthy(Strings.has(step.label), step.label)
				if step.at then
					t.truthy(table.find(Enums.AnchorKind, step.at) ~= nil, step.id .. " at " .. step.at)
				end
			end
			for kind in spec.holds do
				t.truthy(table.find(Enums.PromptKind, kind :: any) ~= nil, spec.id .. " hold " .. kind)
			end
		end
	end,

	["stun flasks a run places: 3, 3, 2, 2, 2 [2, 2, 1, 1, 1]"] = function(t: Expect)
		local order = { "Level0_Basement", "Level1_Hallways", "Level2_Auditorium", "City1_Rooftops", "City2_Airport" }
		local standard, nightmare = { 3, 3, 2, 2, 2 }, { 2, 2, 1, 1, 1 }
		local total, totalN = 0, 0
		for i, stage in order do
			t.eq(DifficultyConfig.Standard.flasksPerStage[stage], standard[i], stage)
			t.eq(DifficultyConfig.Nightmare.flasksPerStage[stage], nightmare[i], stage)
			total += standard[i]
			totalN += nightmare[i]
		end
		t.truthy(total == 12 and totalN == 7, "12 [7] in a run")
	end,

	["every exported config and golden is plain data"] = function(t: Expect)
		local exported: { string } = {}
		for _, folderName in { "Config", "Rules" } do
			local folder = ReplicatedStorage.Shared:FindFirstChild(folderName)
			t.truthy(folder ~= nil, folderName)
			for _, child in (if folder then folder:GetChildren() else {}) :: { Instance } do
				if not child:IsA("ModuleScript") then
					continue
				end
				local module = (require(child) :: any) :: { [string]: any }
				if type(module.exportMeta) == "function" then
					table.insert(exported, child.Name)
					local ok, at = RuleGolden.plain(module.exportMeta(), child.Name)
					t.truthy(ok, child.Name .. ".exportMeta: " .. at)
				end
				if type(module.golden) == "function" then
					local ok, at = RuleGolden.plain(module.golden(), child.Name)
					t.truthy(ok, child.Name .. ".golden: " .. at)
				end
			end
		end
		for _, name in
			{
				"StageConfig",
				"WorldConfig",
				"ObjectiveConfig",
				"DifficultyConfig",
				"GameConfig",
				"NoiseConfig",
				"InputConfig",
				"SettingsSchema",
				"TutorialConfig",
				"LivesConfig",
				"RadarConfig",
				"ParkourConfig",
			}
		do
			t.truthy(table.find(exported, name) ~= nil, name .. " exports its meta")
		end
	end,

	["the prop builder registry finds its builders, sorted, and skips the kits"] = function(t: Expect)
		local found: { string } = {}
		for _, entry in Props.modules() do
			table.insert(found, entry.name)
		end
		local sorted = table.clone(found)
		table.sort(sorted)
		t.eq(table.concat(found, ","), table.concat(sorted, ","), "in name order")
		for _, builder in
			{
				"BearTrapBuilder",
				"BreakerPanelBuilder",
				"ChemicalFlaskBuilder",
				"DecayBuilder",
				"DoorBuilder",
				"FurnitureBuilder",
				"HideBuilder",
				"LockBuilder",
				"LockerBuilder",
				"ObjectiveItemBuilder",
				"ParachuteBuilder",
				"PickupBuilder",
				"ServicePipeBuilder",
				"SetDressingBuilder",
				"SignageBuilder",
				"TunnelDressingBuilder",
				"VentGrateBuilder",
			}
		do
			t.truthy(table.find(found, builder) ~= nil, builder .. " is found")
		end
		for _, kit in { "PropKit", "ObjectiveKit", "WallPlanner" } do
			t.falsy(table.find(found, kit), kit .. " registers nothing")
		end
		local kinds: { string } = {}
		local function note(kind: string)
			table.insert(kinds, kind)
		end
		Props.registerAll({
			prop = function(kind: string)
				note("prop:" .. kind)
			end,
			fixture = function(kind: string)
				note("fixture:" .. kind)
			end,
			static = function(kind: string)
				note("static:" .. kind)
			end,
			rig = function(kind: string)
				note("rig:" .. kind)
			end,
			cosmetic = function(kind: string)
				note("cosmetic:" .. kind)
			end,
		} :: any)
		t.truthy(table.find(kinds, "prop:BearTrap") ~= nil and table.find(kinds, "prop:Battery") ~= nil, "plan props")
		t.truthy(#kinds >= 17, string.format("%d kinds registered", #kinds))
	end,
}
