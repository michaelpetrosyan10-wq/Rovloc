--!strict
-- Onboarding. The title screen and walkthrough's rules (OnboardingController), the objective tracker's goal selection
-- per lobby and level state (ObjectiveTracker), the first-time hints' gate, order and once-only memory
-- (FirstTimeHints), the input glyphs per device (InputGlyphs), the lobby's wayfinding plan (LobbySignage,
-- LobbyBuilder.bus), the saved flags in the Settings blob, and that every key the onboarding shows exists.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local LobbyBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LobbyBuilder)
local LobbyLayout = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Lobby)
local LobbySignage = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LobbySignage)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)
local TutorialConfig = require(ReplicatedStorage.Shared.Config.TutorialConfig)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local MatchAndDataService = require(ServerScriptService.Services.Match.MatchAndDataService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local Controllers = StarterPlayer.StarterPlayerScripts.Controllers
local FirstTimeHints = require(Controllers.HUD.FirstTimeHints)
local InputGlyphs = require(Controllers.HUD.InputGlyphs)
local ObjectiveTracker = require(Controllers.HUD.ObjectiveTracker)
local OnboardingController = require(Controllers.Match.OnboardingController)
local SettingsController = require(Controllers.Core.SettingsController)

type Expect = SpecRunner.Expect

local DEVICES = { "KeyboardMouse", "Gamepad", "Touch" }

local function levelInput(level: string?): ObjectiveTracker.LevelInput
	return {
		level = level,
		airlock = "None",
		insideAirlock = false,
		gateSlammed = false,
		beyondGate = false,
		inVent = false,
		roofDoor = "Closed",
		onRoof = false,
		parachute = "None",
	}
end

local function lobbyInput(): ObjectiveTracker.LobbyInput
	return {
		phase = "Lobby",
		loaded = true,
		inSquad = true,
		ready = false,
		onBus = false,
		voted = false,
		perks = false,
	}
end

local function gate(): FirstTimeHints.GateState
	return {
		enabled = true,
		inRun = true,
		hudVisible = true,
		busy = false,
		context = "OnFoot",
		controlLock = "None",
		chased = false,
		panic = 0.1,
	}
end

local spec = {}

--------------------------------------------------------------------------------
-- Walkthrough and title
--------------------------------------------------------------------------------

spec["walkthrough pages: 6-8 of them, ordered, each with its title, body and art"] = function(t: Expect)
	local pages = TutorialConfig.Pages
	t.truthy(#pages >= 6 and #pages <= 8, "6-8 pages")
	t.eq(pages[1].id, "Goal", "the goal comes first")
	local ids: { [string]: boolean } = {}
	for _, page in pages do
		t.falsy(ids[page.id], page.id .. " is unique")
		ids[page.id] = true
		t.truthy(Strings.has(page.title), page.title)
		for _, device in DEVICES do
			local body = OnboardingController.bodyText(page, device)
			t.truthy(
				body ~= "" and body ~= page.body and not string.find(body, "Tutorial.", 1, true),
				page.id .. " body"
			)
		end
	end
	for _, id in { "Goal", "Creature", "Noise", "Tools", "Teamwork", "Controls", "Lobby" } do
		t.truthy(ids[id], id .. " page exists")
	end
end

spec["page flow: back and next stay in range; the last page reads GOT IT"] = function(t: Expect)
	local count = #TutorialConfig.Pages
	t.eq(OnboardingController.stepPage(1, -1, count), 1, "no page before the first")
	t.eq(OnboardingController.stepPage(1, 1, count), 2)
	t.eq(OnboardingController.stepPage(count, 1, count), count, "no page after the last")
	t.eq(OnboardingController.stepPage(3, -2, count), 1)
	t.eq(OnboardingController.stepPage(1, 99, count), count)
	t.eq(OnboardingController.stepPage(1, 1, 0), 1, "an empty book stays on page 1")
	for index = 1, count - 1 do
		t.eq(OnboardingController.primaryKey(index, count), "Tutorial.Next")
	end
	t.eq(OnboardingController.primaryKey(count, count), "Tutorial.Done")
	t.truthy(Strings.has("Tutorial.Next") and Strings.has("Tutorial.Done") and Strings.has("Tutorial.Back"))
	t.truthy(Strings.has("Tutorial.Skip") and Strings.has("Tutorial.Page"))
end

spec["PLAY runs the walkthrough the first time only; the title never covers a player in a run"] = function(t: Expect)
	t.eq(OnboardingController.afterPlay(false), "Walkthrough")
	t.eq(OnboardingController.afterPlay(true), "Hidden")
	t.truthy(OnboardingController.titleAllowed(nil), "joining: no life state yet")
	t.truthy(OnboardingController.titleAllowed("Lobby"))
	t.truthy(OnboardingController.titleAllowed("Spectating"), "a late joiner watching a run")
	t.truthy(OnboardingController.titleAllowed("Dead"))
	t.falsy(OnboardingController.titleAllowed("Alive"))
	t.falsy(OnboardingController.titleAllowed("Downed"))
end

spec["title stats: credits and escapes once loaded, the loading line before"] = function(t: Expect)
	t.eq(OnboardingController.statsText(nil, nil), Strings.get("Title.Loading"))
	t.eq(OnboardingController.statsText(120, nil), Strings.get("Title.Loading"))
	local line = OnboardingController.statsText(120.7, 3)
	t.truthy(string.find(line, "120", 1, true) and string.find(line, "3", 1, true), line)
	for _, key in { "Title.Name", "Title.Premise", "Title.Play", "Title.HowToPlay", "Title.Settings", "Title.Stats" } do
		t.truthy(Strings.has(key), key)
	end
	t.truthy(Strings.has("Title.FirstTime") and Strings.has("Title.RunUnderway"))
	local teamwork = Strings.get("Tutorial.Teamwork.Body", GameConfig.StragglerSeconds)
	t.truthy(string.find(teamwork, "20", 1, true) ~= nil, "the teamwork page names the airlock wait")
end

spec["controls page: one glyph per row for each device, from the bindings"] = function(t: Expect)
	for _, device in DEVICES do
		local rows = OnboardingController.controlRows(device)
		t.eq(#rows, #TutorialConfig.ControlRows, device .. " rows")
		for _, row in rows do
			t.truthy(row.label ~= "" and not string.find(row.label, "Tutorial.", 1, true), "label " .. row.label)
			local glyph = row.glyph
			t.truthy(glyph.keyCode ~= nil or (glyph.text ~= nil and glyph.text ~= ""), device .. " glyph")
			if glyph.text then
				t.falsy(string.find(glyph.text, "Tutorial.", 1, true), "glyph text " .. glyph.text)
			end
		end
	end
	local sprint = InputGlyphs.forAction("Sprint", "KeyboardMouse")
	t.eq(sprint.keyCode, Enum.KeyCode.LeftShift)
	t.eq(InputGlyphs.forAction("Throw", "KeyboardMouse").text, Strings.get("Input.Mouse.MouseButton1"), "LMB")
	t.eq(InputGlyphs.forAction("Interact", "Gamepad").keyCode, Enum.KeyCode.ButtonX)
	t.eq(InputGlyphs.forAction("Objective", "Gamepad").keyCode, Enum.KeyCode.DPadRight)
	t.eq(InputGlyphs.forAction("Objective", "KeyboardMouse").keyCode, Enum.KeyCode.Tab)
	t.eq(InputGlyphs.forAction("Flashlight", "Touch").text, Strings.get("Input.Flashlight"), "the touch button's label")
	t.eq(InputGlyphs.forAction("Interact", "Touch").text, Strings.get("Tutorial.Control.TapPrompt"), "tap the prompt")
	t.eq(InputGlyphs.forAction("Nonsense", "KeyboardMouse").text, Strings.get("Input.Unbound"))
	-- A pill never draws empty: no text, or only blanks, reads as the unbound mark.
	t.eq(InputGlyphs.pillText({ kind = "Touch", text = "GOAL" }), "GOAL")
	t.eq(InputGlyphs.pillText({ kind = "Keyboard", text = nil }), Strings.get("Input.Unbound"))
	t.eq(InputGlyphs.pillText({ kind = "Touch", text = "" }), Strings.get("Input.Unbound"))
	t.eq(InputGlyphs.pillText({ kind = "Gamepad", text = " \t" }), Strings.get("Input.Unbound"))
	for _, device in DEVICES do
		for action in InputConfig.Bindings do
			local glyph = InputGlyphs.forAction(action, device)
			if glyph.keyCode == nil or glyph.kind == "Touch" then
				t.eq(InputGlyphs.pillText(glyph), glyph.text, action .. " " .. device .. " pill shows its own text")
			end
		end
	end
end

spec["title camera: a closed loop through the drift keys, inside the boiler room"] = function(t: Expect)
	local keys = TutorialConfig.TitleDrift
	local period = TutorialConfig.Timing.TitleDriftPeriod
	t.truthy(#keys >= 4, "enough keys for a loop")
	local eye0, look0 = OnboardingController.drift(keys, 0, period)
	t.near((eye0 - keys[1].eye).Magnitude, 0, 1e-4, "starts on the first key")
	t.near((look0 - keys[1].look).Magnitude, 0, 1e-4)
	local eyeLoop = OnboardingController.drift(keys, period, period)
	t.near((eyeLoop - eye0).Magnitude, 0, 1e-4, "the loop closes")
	local eye2 = OnboardingController.drift(keys, period * 2 / #keys, period)
	t.near((eye2 - keys[3].eye).Magnitude, 0, 1e-4, "passes through every key")
	local boiler = LobbyLayout.rooms[1]
	t.eq(boiler.id, "Lobby_BoilerRoom")
	local previous = eye0
	for step = 1, 400 do
		local eye, look = OnboardingController.drift(keys, period * step / 400, period)
		t.truthy(eye.X > boiler.rect.x + 1 and eye.X < boiler.rect.x + boiler.rect.w - 1, "eye x inside")
		t.truthy(eye.Z > boiler.rect.z + 1 and eye.Z < boiler.rect.z + boiler.rect.d - 1, "eye z inside")
		t.truthy(eye.Y > 2 and eye.Y < LobbyLayout.height - 2, "eye under the ceiling")
		t.truthy((look - eye).Magnitude > 4, "looks somewhere")
		t.truthy((eye - previous).Magnitude < 2, "drifts smoothly")
		previous = eye
	end
end

spec["noise page: rings to scale, the loudest filling the art"] = function(t: Expect)
	t.near(OnboardingController.noiseRing(130, 130, 112), 112, 1e-9)
	t.near(OnboardingController.noiseRing(0, 130, 112), 0, 1e-9)
	t.truthy(OnboardingController.noiseRing(8, 130, 112) < OnboardingController.noiseRing(30, 130, 112))
	t.truthy(OnboardingController.noiseRing(30, 130, 112) < OnboardingController.noiseRing(65, 130, 112))
	t.near(OnboardingController.noiseRing(500, 130, 112), 112, 1e-9, "clamped")
end

--------------------------------------------------------------------------------
-- Saved flags
--------------------------------------------------------------------------------

spec["saved flags: hidden Bool settings, sanitized, saved and loaded with the Settings blob"] = function(t: Expect)
	local keys = { TutorialConfig.TutorialSetting }
	for _, hint in TutorialConfig.Hints do
		table.insert(keys, hint.setting)
	end
	for _, key in keys do
		local setting = SettingsSchema.get(key)
		t.truthy(setting ~= nil, key .. " is in the schema")
		if setting then
			t.eq(setting.kind, "Bool", key .. " is a Bool")
			t.eq(setting.default, false, key .. " starts unseen")
			t.eq(setting.hidden, true, key .. " is hidden from the menu")
			t.truthy(Strings.has(setting.label), key .. " label")
		end
	end
	local shown = SettingsSchema.get(TutorialConfig.HintsSetting)
	t.truthy(shown ~= nil and shown.kind == "Bool" and shown.default == true and not shown.hidden, "Show hints toggle")
	local visible = SettingsSchema.visible()
	for _, setting in visible do
		t.falsy(setting.hidden, setting.key .. " drawn")
	end
	t.eq(#visible + #keys, #SettingsSchema.List, "every hidden entry is an onboarding flag")
	t.truthy(table.find(visible, shown :: any) ~= nil, "the toggle is in the menu")

	-- Client -> server -> store -> client
	local values = SettingsSchema.defaults()
	values[TutorialConfig.TutorialSetting] = true
	values.HintBearTrap = true
	local payload = SettingsController.payload(values)
	local remote = RemoteRegistry.get("SettingsSave")
	local validate = if remote then remote.validate else nil
	t.truthy(validate and validate(payload), "the save passes the server's validator")
	local stored = MatchAndDataService.sanitizeSettings(payload.settings)
	t.eq(stored[TutorialConfig.TutorialSetting], true, "the server keeps the flag")
	t.eq(stored.HintBearTrap, true)
	local decoded = SettingsController.decode(stored)
	t.eq(decoded[TutorialConfig.TutorialSetting], true, "the client reads it back")
	t.eq(decoded.HintFlask, false, "unseen hints stay unseen")
	t.eq(SettingsController.decode("[]")[TutorialConfig.TutorialSetting], false, "a fresh blob: not done")
	t.eq(SettingsSchema.sanitize(TutorialConfig.TutorialSetting, "yes"), nil, "wrong types are dropped")
end

--------------------------------------------------------------------------------
-- Objectives
--------------------------------------------------------------------------------

spec["lobby goal: the bus, then a pad, then waiting; optional lines tick off"] = function(t: Expect)
	local input = lobbyInput()
	local goal = ObjectiveTracker.lobbyObjective(input)
	t.eq(goal.text, "Objective.Lobby.Bus")
	t.eq(goal.target, "Bus")
	t.eq(#goal.optional, 2)
	t.eq(goal.optional[1].text, "Objective.Lobby.Vote")
	t.falsy(goal.optional[1].done)
	input.onBus = true
	goal = ObjectiveTracker.lobbyObjective(input)
	t.eq(goal.text, "Objective.Lobby.Ready")
	t.eq(goal.target, "Pad")
	input.ready = true
	input.voted = true
	goal = ObjectiveTracker.lobbyObjective(input)
	t.eq(goal.text, "Objective.Lobby.Waiting")
	t.eq(goal.target, nil, "no marker once ready")
	t.truthy(goal.optional[1].done, "voted")
	t.falsy(goal.optional[2].done, "no perks yet")
	input.perks = true
	t.truthy(ObjectiveTracker.lobbyObjective(input).optional[2].done)
	input.phase = "Countdown"
	goal = ObjectiveTracker.lobbyObjective(input)
	t.eq(goal.text, "Objective.Lobby.Countdown")
	t.eq(#goal.optional, 0)
	local waiting = lobbyInput()
	waiting.inSquad = false
	t.eq(ObjectiveTracker.lobbyObjective(waiting).text, "Objective.Lobby.NextRun", "over the squad cap")
	waiting.loaded = false
	t.eq(ObjectiveTracker.lobbyObjective(waiting).text, "Objective.Lobby.Bus", "still loading: the bus anyway")
	for _, step in TutorialConfig.LobbySteps do
		t.truthy(Strings.has(step.text), step.text)
	end
end

spec["floor goals: the stairwell each level leaves by"] = function(t: Expect)
	t.eq(ObjectiveTracker.levelObjective(levelInput(nil)), nil)
	t.eq(ObjectiveTracker.levelObjective(levelInput("Lobby")), nil)
	for _, stairwell in WorldConfig.Stairwells do
		local input = levelInput(stairwell.from)
		input.exitTower = stairwell.tower
		local goal = ObjectiveTracker.levelObjective(input)
		t.truthy(goal ~= nil, stairwell.from)
		if goal then
			t.eq(goal.target, "Exit", stairwell.from .. " points at its exit")
			if stairwell.from == "Level4_FloodedPool" then
				t.eq(goal.text, "Objective.PoolStairs", "the pool's exit is the roof stairs")
			else
				t.eq(goal.text, "Objective.Stairwell." .. stairwell.tower, stairwell.from)
			end
			t.truthy(Strings.has(goal.text), goal.text)
			t.truthy(goal.tip and Strings.has(goal.tip), stairwell.from .. " tip")
		end
	end
	local basement = ObjectiveTracker.levelObjective(levelInput("Level0_Basement"))
	t.eq(basement and basement.text, "Objective.Stairwell.East")
	local floor1 = ObjectiveTracker.levelObjective(levelInput("Level1_Hallways"))
	t.eq(floor1 and floor1.text, "Objective.Stairwell.West")
end

spec["floor 1: the gate slam sends you to the vent, then on to the stairwell"] = function(t: Expect)
	local input = levelInput("Level1_Hallways")
	input.gateSlammed = true
	local goal = ObjectiveTracker.levelObjective(input)
	t.eq(goal and goal.text, "Objective.Gate")
	t.eq(goal and goal.target, "BypassVent")
	input.inVent = true
	goal = ObjectiveTracker.levelObjective(input)
	t.eq(goal and goal.text, "Objective.GateVent")
	t.eq(goal and goal.target, nil)
	input.beyondGate = true
	goal = ObjectiveTracker.levelObjective(input)
	t.eq(goal and goal.text, "Objective.Stairwell.West", "past the gate")
	local elsewhere = levelInput("Level2_ScienceHall")
	elsewhere.gateSlammed = true
	goal = ObjectiveTracker.levelObjective(elsewhere)
	t.eq(goal and goal.text, "Objective.Stairwell.East", "only floor 1 has the gate")
end

spec["the airlock countdown takes over: get in, or hold it from inside"] = function(t: Expect)
	for _, level in { "Level0_Basement", "Level1_Hallways", "Level3_Gymnasium" } do
		local input = levelInput(level)
		input.airlock = "Waiting"
		local goal = ObjectiveTracker.levelObjective(input)
		t.eq(goal and goal.text, "Objective.Airlock.Get", level)
		t.eq(goal and goal.target, "Exit")
		input.insideAirlock = true
		goal = ObjectiveTracker.levelObjective(input)
		t.eq(goal and goal.text, "Objective.Airlock.Wait")
		t.eq(goal and goal.target, nil)
		input.airlock = "Sealing"
		goal = ObjectiveTracker.levelObjective(input)
		t.eq(goal and goal.text, "Objective.Airlock.Wait")
	end
end

spec["the roof: out, a way off, the parachutes, the gap, the cord, out"] = function(t: Expect)
	local input = levelInput("Level5_Roof")
	local goal = ObjectiveTracker.levelObjective(input)
	t.eq(goal and goal.text, "Objective.Roof.Out")
	t.eq(goal and goal.target, "RoofDoor")
	input.onRoof = true
	goal = ObjectiveTracker.levelObjective(input)
	t.eq(goal and goal.text, "Objective.Roof.Search")
	t.eq(goal and goal.target, "Crate")
	input.roofDoor = "Smashed"
	goal = ObjectiveTracker.levelObjective(input)
	t.eq(goal and goal.text, "Objective.Roof.Run", "Get to the parachutes!")
	t.eq(goal and goal.target, "Crate")
	input.parachute = "Packed"
	goal = ObjectiveTracker.levelObjective(input)
	t.eq(goal and goal.text, "Objective.Roof.Jump")
	t.eq(goal and goal.target, "Gap")
	input.parachute = "Freefall"
	goal = ObjectiveTracker.levelObjective(input)
	t.eq(goal and goal.text, "Objective.Roof.Cord")
	input.parachute = "Canopy"
	t.eq(ObjectiveTracker.levelObjective(input), nil, "the canopy is ParachuteController's")
	input.parachute = "Landed"
	goal = ObjectiveTracker.levelObjective(input)
	t.eq(goal and goal.text, "Objective.Roof.Landed")
	for _, key in
		{
			"Objective.Roof.Out",
			"Objective.Roof.Search",
			"Objective.Roof.Run",
			"Objective.Roof.Jump",
			"Objective.Roof.Cord",
		}
	do
		t.truthy(Strings.has(key), key)
	end
end

spec["floor cards for every level, faded in, held and out"] = function(t: Expect)
	for _, stairwell in WorldConfig.Stairwells do
		local titleKey, nameKey = ObjectiveTracker.floorCard(stairwell.to)
		t.truthy(titleKey and Strings.has(titleKey), stairwell.to .. " title")
		t.truthy(nameKey and Strings.has(nameKey), stairwell.to .. " name")
	end
	local titleKey = ObjectiveTracker.floorCard("Level0_Basement")
	t.eq(titleKey, "Floor.Level0.Title")
	t.eq(Strings.get("Floor.Level1.Title") .. " — " .. Strings.get("Floor.Level1.Name"), "FLOOR 1 — MAIN HALLWAYS")
	t.eq(ObjectiveTracker.floorCard("Lobby"), nil)
	local timing = TutorialConfig.Timing
	t.eq(ObjectiveTracker.floorCardAlpha(-1), 0)
	t.near(ObjectiveTracker.floorCardAlpha(timing.FloorCardIn / 2), 0.5, 1e-9)
	t.eq(ObjectiveTracker.floorCardAlpha(timing.FloorCardIn + 0.1), 1)
	local done = timing.FloorCardIn + timing.FloorCardHold + timing.FloorCardOut
	t.eq(ObjectiveTracker.floorCardAlpha(done + 0.01), 0)
	t.truthy(ObjectiveTracker.floorCardAlpha(done - timing.FloorCardOut / 2) > 0.4)
end

spec["tracker fade, the direction nudge's cooldown and bearing"] = function(t: Expect)
	t.eq(ObjectiveTracker.trackerAlpha(0, 9, 2), 1)
	t.eq(ObjectiveTracker.trackerAlpha(9, 9, 2), 1)
	t.near(ObjectiveTracker.trackerAlpha(10, 9, 2), 0.5, 1e-9)
	t.eq(ObjectiveTracker.trackerAlpha(30, 9, 2), 0)
	local ready, remaining = ObjectiveTracker.direction(100, -math.huge, 20)
	t.truthy(ready, "never used: ready")
	t.eq(remaining, 0)
	ready, remaining = ObjectiveTracker.direction(105, 100, 20)
	t.falsy(ready, "cooling down")
	t.near(remaining, 15, 1e-9)
	ready = ObjectiveTracker.direction(120, 100, 20)
	t.truthy(ready, "ready again after the cooldown")
	local camera = CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, -1))
	t.near(ObjectiveTracker.bearing(camera, Vector3.new(0, 0, -10)), 0, 1e-4, "ahead")
	t.near(ObjectiveTracker.bearing(camera, Vector3.new(10, 0, 0)), math.pi / 2, 1e-4, "right")
	t.near(ObjectiveTracker.bearing(camera, Vector3.new(-10, 0, 0)), -math.pi / 2, 1e-4, "left")
	t.near(math.abs(ObjectiveTracker.bearing(camera, Vector3.new(0, 0, 10))), math.pi, 1e-4, "behind")
	t.eq(ObjectiveTracker.meters(0), 1)
	t.eq(ObjectiveTracker.meters(100), 28)
	t.eq(ObjectiveTracker.nearest({}, Vector3.zero), nil)
	t.eq(ObjectiveTracker.nearest({ Vector3.new(9, 0, 0), Vector3.new(2, 0, 0) }, Vector3.zero), Vector3.new(2, 0, 0))
end

spec["past the gate: measured along the way from the gate to the exit"] = function(t: Expect)
	local gatePoint, exitPoint = Vector3.new(120, 0, 80), Vector3.new(10, 0, 80)
	t.falsy(ObjectiveTracker.beyond(gatePoint, exitPoint, Vector3.new(130, 0, 80), 3), "east of the gate")
	t.falsy(ObjectiveTracker.beyond(gatePoint, exitPoint, Vector3.new(118, 0, 60), 3), "at the gate")
	t.truthy(ObjectiveTracker.beyond(gatePoint, exitPoint, Vector3.new(100, 5, 40), 3), "west of it")
	t.falsy(ObjectiveTracker.beyond(gatePoint, gatePoint, Vector3.new(0, 0, 0), 3), "no direction")
end

--------------------------------------------------------------------------------
-- First-time hints
--------------------------------------------------------------------------------

spec["hints: every one has its line, glyphs, flag; radii for the things in the world"] = function(t: Expect)
	local ids: { [string]: boolean } = {}
	for _, hint in TutorialConfig.Hints do
		t.falsy(ids[hint.id], hint.id .. " unique")
		ids[hint.id] = true
		t.truthy(Strings.has(hint.text), hint.text)
		t.truthy(#hint.inputs <= 2, hint.id .. " at most two glyphs")
		for _, input in hint.inputs do
			t.truthy(Strings.has(input.label), input.label)
			for _, device in DEVICES do
				local glyph = InputGlyphs.forAction(input.action, device)
				t.truthy(glyph.keyCode ~= nil or glyph.text ~= nil, hint.id .. " " .. device)
			end
		end
		t.eq(hint.setting, "Hint" .. hint.id)
	end
	for _, id in { "BearTrap", "VentGrate", "Flask", "Locker" } do
		local found = false
		for _, hint in TutorialConfig.Hints do
			if hint.id == id then
				found = true
				t.truthy(hint.radius and hint.radius > 4, id .. " radius")
			end
		end
		t.truthy(found, id)
	end
	for _, id in { "DownedTeammate", "Water", "LowBattery", "Airlock" } do
		t.truthy(ids[id], id)
	end
	local airlock = Strings.get("Hint.Airlock", GameConfig.StragglerSeconds)
	t.truthy(string.find(airlock, "20", 1, true) ~= nil, "the airlock hint names the wait")
end

spec["hints wait for a quiet moment"] = function(t: Expect)
	t.truthy(FirstTimeHints.allowed(gate()))
	local function without(edit: (FirstTimeHints.GateState) -> (), label: string)
		local state = gate()
		edit(state)
		t.falsy(FirstTimeHints.allowed(state), label)
	end
	without(function(s)
		s.enabled = false
	end, "hints turned off")
	without(function(s)
		s.inRun = false
	end, "not playing")
	without(function(s)
		s.hudVisible = false
	end, "cutscene: HUD hidden")
	without(function(s)
		s.busy = true
	end, "walkthrough up")
	for _, context in { "Cutscene", "Menu", "Struggle" } do
		without(function(s)
			s.context = context
		end, context)
	end
	for _, lock in { "Cutscene", "Jumpscare", "Drag" } do
		without(function(s)
			s.controlLock = lock
		end, lock)
	end
	without(function(s)
		s.chased = true
	end, "being chased")
	without(function(s)
		s.panic = 0.9
	end, "panicking")
	local vent = gate()
	vent.context = "Vent"
	t.truthy(FirstTimeHints.allowed(vent), "fine in a vent")
	t.truthy(FirstTimeHints.chased("WallChase", 7, 7))
	t.truthy(FirstTimeHints.chased("AquaticStalk", 7, 7))
	t.falsy(FirstTimeHints.chased("WallChase", 8, 7), "chasing someone else")
	t.falsy(FirstTimeHints.chased("Patrol", 7, 7))
	t.falsy(FirstTimeHints.chased(nil, nil, 7))
end

spec["hints: highest priority first, each once only"] = function(t: Expect)
	local seen: { [string]: boolean } = {}
	local dueNow: { [string]: boolean } = { BearTrap = true, LowBattery = true, Airlock = true }
	local shown: { string } = {}
	for _ = 1, 10 do
		local hint = FirstTimeHints.pick(dueNow, seen)
		if not hint then
			break
		end
		table.insert(shown, hint.id)
		seen[hint.id] = true
	end
	t.eq(table.concat(shown, ","), "Airlock,BearTrap,LowBattery", "in priority order, never twice")
	t.eq(FirstTimeHints.pick(dueNow, seen), nil, "all seen")
	t.eq(FirstTimeHints.pick({}, {}), nil, "nothing due")
	t.falsy(FirstTimeHints.seenAll(seen))
	for _, hint in TutorialConfig.Hints do
		seen[hint.id] = true
	end
	t.truthy(FirstTimeHints.seenAll(seen))
	t.truthy(FirstTimeHints.batteryLow(0.15, true))
	t.falsy(FirstTimeHints.batteryLow(0.15, false), "light off")
	t.falsy(FirstTimeHints.batteryLow(0.5, true))
	t.falsy(FirstTimeHints.batteryLow(0, true), "empty: the HUD says so already")
end

--------------------------------------------------------------------------------
-- Lobby wayfinding
--------------------------------------------------------------------------------

spec["the bus: found from the pads, the pads inside it, its entrance outside the rear door"] = function(t: Expect)
	local bus = LobbyBuilder.bus(LobbyLayout)
	t.truthy(bus ~= nil, "the lobby has a bus")
	if not bus then
		return
	end
	for _, anchor in LobbyLayout.anchors do
		if anchor.kind == "ReadyPad" then
			t.truthy(LobbyBuilder.inBus(bus, anchor.pos), anchor.id .. " is in the bus")
		elseif anchor.kind == "PlayerSpawn" then
			t.falsy(LobbyBuilder.inBus(bus, anchor.pos), anchor.id .. " is not")
		end
	end
	t.falsy(LobbyBuilder.inBus(bus, bus.entrance), "the entrance is outside")
	local rear = bus.cframe:PointToObjectSpace(bus.entrance)
	t.truthy(rear.X < -bus.length / 2, "behind the rear wall")
	t.near(rear.Z, 0, 1e-4, "in line with the rear door")
end

spec["the lit path: spawn, through the doorway, to the bus, chevrons evenly along it"] = function(t: Expect)
	local bus = LobbyBuilder.bus(LobbyLayout)
	local route = LobbySignage.route(LobbyLayout, bus)
	t.truthy(#route >= 2, "a route")
	if not bus or #route < 2 then
		return
	end
	local first = route[1]
	t.truthy(first.X > 0 and first.X < 60 and first.Z > 0 and first.Z < 48, "starts in the boiler room")
	t.near((route[#route] - Vector3.new(bus.entrance.X, 0, bus.entrance.Z)).Magnitude, 0, 1e-4, "ends at the bus")
	local crossed = false
	for i = 2, #route do
		if (route[i - 1].X - 60) * (route[i].X - 60) < 0 then
			crossed = true
			local z = route[i - 1].Z
			t.truthy(z > 24 and z < 36, "through the 12-wide doorway at z 30")
		end
	end
	t.truthy(crossed, "the path goes through the doorway")
	t.eq(#LobbySignage.route(LobbyLayout, nil), 0, "no bus, no path")
	local chevrons = LobbySignage.chevrons(route, LobbySignage.ChevronSpacing, 3, 1.5)
	t.truthy(#chevrons >= 8 and #chevrons <= 20, "a modest number of arrows: " .. #chevrons)
	for i, chevron in chevrons do
		t.near(chevron.direction.Magnitude, 1, 1e-4, "unit direction")
		t.near(chevron.direction.Y, 0, 1e-9, "flat")
		if i > 1 then
			local gap = (chevron.position - chevrons[i - 1].position).Magnitude
			t.truthy(
				gap <= LobbySignage.ChevronSpacing + 1e-3 and gap > 1,
				string.format("evenly spaced (%.2f at %d)", gap, i)
			)
		end
	end
	local straight = LobbySignage.chevrons({ Vector3.zero, Vector3.new(10, 0, 0) }, 4, 1, 1)
	t.eq(#straight, 3, "1, 5 and 9 studs along")
	t.near(straight[2].position.X, 5, 1e-9)
	t.eq(#LobbySignage.chevrons({ Vector3.zero }, 4, 0, 0), 0)
end

spec["hanging signs: bus, difficulty and supply, facing the player, under the ceiling"] = function(t: Expect)
	local bus = LobbyBuilder.bus(LobbyLayout)
	local signs = LobbySignage.signs(LobbyLayout, bus, LobbyBuilder.Terminals)
	local kinds: { [string]: number } = {}
	for _, sign in signs do
		kinds[sign.kind] = (kinds[sign.kind] or 0) + 1
		t.near(sign.facing.Magnitude, 1, 1e-4, sign.id .. " facing")
		t.near(sign.facing.Y, 0, 1e-9)
		t.truthy(sign.position.Y + 1.1 < sign.ceiling, sign.id .. " hangs under the ceiling")
		t.truthy(sign.position.Y > 6, sign.id .. " above head height")
		for _, key in LobbySignage.SignText[sign.kind] do
			t.truthy(Strings.has(key), key)
		end
	end
	t.eq(kinds.Bus, 2, "over the doorway and the rear door")
	t.eq(kinds.Difficulty, 1)
	t.eq(kinds.Supply, 2, "over the supply door and the perk console")
	t.eq(Strings.get("LobbySign.Bus"), "BUS — READY UP")
	t.eq(Strings.get("LobbySign.Supply"), "SUPPLY / PERKS")
	t.eq(Strings.get("LobbySign.Difficulty"), "DIFFICULTY")
	for _, sign in signs do
		if sign.id == "Sign_BusDoorway" then
			t.truthy(sign.facing.X < 0, "faces back into the boiler room")
		elseif sign.id == "Sign_SupplyDoor" then
			t.truthy(sign.facing.Z < 0, "faces the boiler room from the supply door")
		end
	end
	local front = LobbySignage.consoleFront(LobbyLayout, LobbyBuilder.Terminals.Difficulty)
	t.truthy(front ~= nil and front.Z > 1.8, "the console's front is in the room")
end

spec["every tracker and hint string exists"] = function(t: Expect)
	local keys = {
		"Objective.Header",
		"Objective.Direction",
		"Objective.DirectionWait",
		"Objective.Distance",
		"Objective.Marker.Bus",
		"Objective.Marker.Pad",
		"Objective.Marker.Goal",
		"Objective.Gate",
		"Objective.GateVent",
		"Objective.PoolStairs",
		"Objective.Airlock.Get",
		"Objective.Airlock.Wait",
		"Objective.Lobby.Waiting",
		"Objective.Lobby.Countdown",
		"Objective.Lobby.NextRun",
		"Objective.Stairwell.East",
		"Objective.Stairwell.West",
		"Lobby.Help",
		"Lobby.HelpMark",
		"Input.Objective",
		"Settings.ShowHints",
	}
	for _, key in keys do
		t.truthy(Strings.has(key), key)
	end
	for _, floor in TutorialConfig.Floors do
		t.truthy(Strings.has(floor.title) and Strings.has(floor.name) and Strings.has(floor.tip), floor.title)
	end
	for _, row in TutorialConfig.ControlRows do
		t.truthy(Strings.has(row.label), row.label)
		local glyph = row.glyph
		if glyph then
			for _, device in DEVICES do
				t.truthy(Strings.has(glyph .. "." .. device), glyph .. "." .. device)
			end
		end
	end
end

return spec
