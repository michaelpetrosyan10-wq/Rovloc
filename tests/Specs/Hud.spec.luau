--!strict
-- HUD rules (pure): meter extrapolation and bar visibility, the progress-ring masks, key glyph text, UI scale, prompt
-- audience and per-player hold time, teammate channel progress, caption dedupe, toast stacking, the touch-button
-- layout around the jump button, toggle latch reconciliation and the settings slider maths.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local Strings = require(ReplicatedStorage.Shared.Strings)

local HUDFolder = StarterPlayer.StarterPlayerScripts.Controllers.HUD
local Captions = require(HUDFolder.Captions)
local HUD = require(HUDFolder)
local MobileControls = require(HUDFolder.MobileControls)
local PromptRenderer = require(HUDFolder.PromptRenderer)
local SettingsMenu = require(HUDFolder.SettingsMenu)
local StatusBars = require(HUDFolder.StatusBars)
local UIKit = require(HUDFolder.UIKit)

type Expect = SpecRunner.Expect

local ME = 4242
local MATE = 77

local function numberSetting(key: string): SettingsSchema.NumberSetting
	local setting = SettingsSchema.get(key)
	assert(setting and setting.kind == "Number", key .. " is a number setting")
	return setting :: SettingsSchema.NumberSetting
end

-- Touch layout entries for every binding with a touch button (live in `context`, when given).
local function touchEntries(context: string?): { MobileControls.LayoutEntry }
	local entries: { MobileControls.LayoutEntry } = {}
	for action, binding in InputConfig.Bindings do
		local touch = binding.touch
		if touch and (context == nil or table.find(binding.contexts, context :: any) ~= nil) then
			table.insert(entries, { action = action, position = touch.position, size = touch.size })
		end
	end
	return entries
end

local function circleClearsRect(placement: MobileControls.Placement, rect: MobileControls.Rect): boolean
	local center = placement.center
	local closest =
		Vector2.new(math.clamp(center.X, rect.min.X, rect.max.X), math.clamp(center.Y, rect.min.Y, rect.max.Y))
	return (closest - center).Magnitude >= placement.diameter / 2 - 1e-6
end

return {
	["meters extrapolate from their last write and clamp to [0, max]"] = function(t: Expect)
		t.near(StatusBars.meterFraction(80, -10, 100, 100, 102), 0.6, 1e-9, "two seconds of drain")
		t.near(StatusBars.meterFraction(80, -10, 100, 100, 120), 0, 1e-9, "never below empty")
		t.near(StatusBars.meterFraction(40, 14, 100, 100, 110), 1, 1e-9, "regen stops at full")
		t.near(StatusBars.meterFraction(50, -5, 100, 100, 99), 0.5, 1e-9, "a write from the future does not run back")
		t.near(StatusBars.meterFraction(75, 0, 100, 150, 500), 0.5, 1e-9, "steady meters hold")
		t.eq(StatusBars.meterFraction(10, 1, 0, 0, 5), 0, "a zero max reads empty")
		-- Battery drain over a full cell matches GameConfig (about three minutes).
		local seconds = GameConfig.BatteryMax / GameConfig.BatteryDrain
		t.near(
			StatusBars.meterFraction(GameConfig.BatteryMax, -GameConfig.BatteryDrain, 0, GameConfig.BatteryMax, seconds),
			0,
			1e-9
		)
	end,

	["bars show while changing or relevant, rest dim when spent, vanish when full"] = function(t: Expect)
		t.eq(StatusBars.targetAlpha(1, false, false, 10), 0, "full and idle: gone")
		t.eq(StatusBars.targetAlpha(1, true, false, 10), 1, "regenerating to full: shown")
		t.eq(StatusBars.targetAlpha(1, false, true, 10), 1, "relevant: shown even when full")
		t.eq(StatusBars.targetAlpha(0.6, false, false, 0.5), 1, "just went quiet: still shown")
		local resting = StatusBars.targetAlpha(0.6, false, false, 30)
		t.truthy(resting > 0 and resting < 1, "a quiet, spent bar rests dim")
		t.truthy(StatusBars.relevant("Oxygen", "Underwater", false))
		t.falsy(StatusBars.relevant("Oxygen", "Treading", false))
		t.truthy(StatusBars.relevant("Battery", "Standing", true))
		t.falsy(StatusBars.relevant("Battery", "Standing", false))
		t.falsy(StatusBars.relevant("Stamina", "Sprinting", true))
	end,

	["low meters pulse, faster when critical; bleedout drains from BleedoutEndsAt"] = function(t: Expect)
		for step = 0, 40 do
			t.eq(StatusBars.lowPulse(0.5, step * 0.05), 0, "no pulse above 20%")
			local low = StatusBars.lowPulse(0.15, step * 0.05)
			t.truthy(low >= 0 and low <= 1)
		end
		-- The critical pulse completes more cycles in the same time.
		local function crossings(fraction: number): number
			local count, last = 0, StatusBars.lowPulse(fraction, 0) > 0.5
			for step = 1, 400 do
				local now = StatusBars.lowPulse(fraction, step * 0.01) > 0.5
				if now ~= last then
					count += 1
					last = now
				end
			end
			return count
		end
		t.truthy(crossings(0.05) > crossings(0.15), "critical beats faster")
		local total = GameConfig.BleedoutSeconds
		t.eq(StatusBars.bleedoutFraction(1000 + total, 1000, total), 1)
		t.near(StatusBars.bleedoutFraction(1000 + total, 1000 + total / 2, total), 0.5, 1e-9)
		t.eq(StatusBars.bleedoutFraction(1000, 1010, total), 0)
		t.eq(StatusBars.bleedoutFraction(1000, 990, 0), 0)
	end,

	["progress ring masks sweep clockwise through both halves"] = function(t: Expect)
		local cases: { { number } } = {
			-- progress, right rotation, left rotation
			{ 0, 0, 180 },
			{ 0.25, 90, 180 },
			{ 0.5, 180, 180 },
			{ 0.75, 180, 270 },
			{ 1, 180, 360 },
			{ 1.5, 180, 360 },
			{ -1, 0, 180 },
		}
		for _, case in cases do
			local right, left, rightVisible, leftVisible = UIKit.ringRotations(case[1])
			t.near(right, case[2], 1e-9, "right @" .. case[1])
			t.near(left, case[3], 1e-9, "left @" .. case[1])
			t.eq(rightVisible, case[1] > 0, "right half visible @" .. case[1])
			t.eq(leftVisible, case[1] > 0.5, "left half visible @" .. case[1])
		end
		local lastRight, lastLeft = -1, -1
		for step = 0, 100 do
			local right, left = UIKit.ringRotations(step / 100)
			t.truthy(right >= lastRight and left >= lastLeft, "the sweep never runs backwards")
			lastRight, lastLeft = right, left
		end
	end,

	["UI scale keeps phones legible and grows on big screens"] = function(t: Expect)
		t.near(UIKit.scaleFor(Vector2.new(844, 390)), 0.9, 1e-9, "landscape phone: clamped up")
		t.near(UIKit.scaleFor(Vector2.new(1280, 720)), 1, 1e-9)
		t.near(UIKit.scaleFor(Vector2.new(1920, 1080)), 1.3, 1e-9, "desktop: clamped down")
		t.eq(UIKit.scaleFor(Vector2.new(0, 0)), 1, "no viewport yet")
		t.near(UIKit.fade(0.2, 1), 0.2, 1e-9)
		t.near(UIKit.fade(0.2, 0), 1, 1e-9)
		t.near(UIKit.fade(0.2, 0.5), 0.6, 1e-9)
		-- The smallest touch button never drops under a 44 px target.
		for _, binding in InputConfig.Bindings do
			local touch = binding.touch
			if touch then
				t.truthy(
					touch.size * MobileControls.touchScale(0.5) >= UIKit.MinTouchTarget - 1e-6,
					binding.action .. " target"
				)
			end
		end
	end,

	["key glyphs read as short labels"] = function(t: Expect)
		t.eq(UIKit.glyphText(Enum.KeyCode.ButtonX, nil), "X")
		t.eq(UIKit.glyphText(Enum.KeyCode.ButtonA, "ButtonA"), "A")
		t.eq(UIKit.glyphText(Enum.KeyCode.ButtonL1, nil), "L1")
		t.eq(UIKit.glyphText(Enum.KeyCode.E, "e"), "E")
		t.eq(UIKit.glyphText(Enum.KeyCode.R, "R"), "R")
		t.eq(UIKit.glyphText(Enum.KeyCode.LeftShift, ""), "LeftShift", "no localized text: the key's name")
		t.eq(UIKit.glyphText(Enum.KeyCode.G, nil), "G")
		t.truthy(UIKit.dpadArm(Enum.KeyCode.DPadDown) == Vector2.new(0, 1))
		t.truthy(UIKit.dpadArm(Enum.KeyCode.DPadUp) == Vector2.new(0, -1))
		t.eq(UIKit.dpadArm(Enum.KeyCode.ButtonX), nil)
	end,

	["prompt audience: Self needs my ownership, Others needs someone else's"] = function(t: Expect)
		t.truthy(PromptRenderer.audienceAllows("Self", ME, ME))
		t.falsy(PromptRenderer.audienceAllows("Self", MATE, ME))
		t.falsy(PromptRenderer.audienceAllows("Self", nil, ME), "Self with no owner shows to nobody")
		t.falsy(PromptRenderer.audienceAllows("Self", 0, ME))
		t.falsy(PromptRenderer.audienceAllows("Others", ME, ME))
		t.truthy(PromptRenderer.audienceAllows("Others", MATE, ME))
		t.truthy(PromptRenderer.audienceAllows("Others", nil, ME), "Others with no owner shows to everyone")
		t.truthy(PromptRenderer.audienceAllows("All", ME, ME))
		t.truthy(PromptRenderer.audienceAllows(nil, MATE, ME), "no audience: everyone")
		t.truthy(PromptRenderer.audienceAllows("Bogus", MATE, ME), "unknown audience: everyone")
		-- The bear trap's two prompts: the victim sees only Pry, a teammate only Rescue.
		t.truthy(PromptRenderer.audienceAllows("Self", ME, ME) and not PromptRenderer.audienceAllows("Others", ME, ME))
		t.truthy(
			PromptRenderer.audienceAllows("Others", ME, MATE) and not PromptRenderer.audienceAllows("Self", ME, MATE)
		)
	end,

	["prompt hold time follows the shared perk rule"] = function(t: Expect)
		local unscrew = GameConfig.UnscrewSeconds
		t.near(PromptRenderer.holdSeconds("Unscrew", unscrew, "", 0), unscrew, 1e-9)
		t.near(PromptRenderer.holdSeconds("Unscrew", unscrew, "RustyScrewdriver", 0), 1.2, 1e-9, "the screwdriver")
		t.near(PromptRenderer.holdSeconds("Unscrew", unscrew, "LithiumCell, RustyScrewdriver", 0), 1.2, 1e-9)
		t.near(PromptRenderer.holdSeconds("TrapPry", 5, "RustyScrewdriver", 0), 5, 1e-9, "only Unscrew is shortened")
		t.near(PromptRenderer.holdSeconds("Kick", 0, "RustyScrewdriver", 3), 0, 1e-9, "instant stays instant")
		t.near(PromptRenderer.holdSeconds("Unscrew", 0.8, "RustyScrewdriver", 0), 0.8, 1e-9, "never longer than base")
		t.near(PromptRenderer.holdSeconds("Pickup", nil, "", 0.4), 0.4, 1e-9, "no BaseHold: the prompt's own")
		t.near(PromptRenderer.holdSeconds("Pickup", -1, "", 0.4), 0.4, 1e-9, "a bad BaseHold is ignored")
		t.near(PromptRenderer.holdSeconds("Unscrew", unscrew, 17, 0), unscrew, 1e-9, "a garbage loadout is no perks")
		t.near(PromptRenderer.holdSeconds(nil, 2, "RustyScrewdriver", 0), 2, 1e-9)
	end,

	["teammate channels run on server time; glyphs follow the input type"] = function(t: Expect)
		t.eq(PromptRenderer.channelProgress(100, 4, 100), 0)
		t.near(PromptRenderer.channelProgress(100, 4, 101), 0.25, 1e-9)
		t.eq(PromptRenderer.channelProgress(100, 4, 110), 1)
		t.eq(PromptRenderer.channelProgress(100, 4, 90), 0, "a start in the future reads 0")
		t.eq(PromptRenderer.channelProgress(100, 0, 100), 1, "instant channels are done")
		t.eq(PromptRenderer.glyphKind(Enum.ProximityPromptInputType.Keyboard), "Keyboard")
		t.eq(PromptRenderer.glyphKind(Enum.ProximityPromptInputType.Gamepad), "Gamepad")
		t.eq(PromptRenderer.glyphKind(Enum.ProximityPromptInputType.Touch), "Touch")
		for _, device in { "KeyboardMouse", "Gamepad", "Touch" } do
			local inputType = PromptRenderer.inputTypeFor(device)
			local expected = if device == "KeyboardMouse" then "Keyboard" else device
			t.eq(PromptRenderer.glyphKind(inputType), expected, device)
		end
	end,

	["captions dedupe repeats, keep three lines and fade"] = function(t: Expect)
		local lines: { Captions.Line } = {}
		local first = Captions.push(lines, "Caption.Screech", "Screech", 10, 1)
		local again = Captions.push(lines, "Caption.Screech", "Screech", 10 + Captions.Dedupe * 0.9, 2)
		t.eq(again, first, "a repeat inside the window refreshes the line")
		t.eq(#lines, 1)
		t.eq(first.refreshedAt, 10 + Captions.Dedupe * 0.9)
		Captions.push(lines, "Caption.Screech", "Screech", 10 + Captions.Dedupe * 0.9 + Captions.Dedupe + 0.1, 3)
		t.eq(#lines, 2, "after the window it is a new line")
		Captions.push(lines, "Caption.Drip", "Drip", 20, 4)
		Captions.push(lines, "Caption.Thunder", "Thunder", 20.1, 5)
		t.eq(#lines, Captions.MaxLines)
		t.eq(lines[1].id, 3, "the oldest gave way")
		t.eq(lines[3].key, "Caption.Thunder")

		local line = lines[3]
		t.eq(Captions.alpha(line, line.bornAt), 0, "fades in from nothing")
		t.eq(Captions.alpha(line, line.bornAt + 1), 1)
		t.eq(Captions.alpha(line, line.bornAt + 60), 0, "faded out long after")
		Captions.expire(lines, 200)
		t.eq(#lines, 0, "expired lines are dropped")
		t.truthy(Strings.has("Caption.Screech"), "captions are Strings keys")
	end,

	["toasts refresh repeats, keep three and dismiss the oldest"] = function(t: Expect)
		local list: { HUD.Toast } = {}
		local a = HUD.pushToast(list, "one", 0, 4, 1)
		local again = HUD.pushToast(list, "one", 0.5, 4, 2)
		t.eq(again, a)
		t.eq(a.expiresAt, 4.5, "refresh extends the toast")
		HUD.pushToast(list, "two", 1, 4, 3)
		HUD.pushToast(list, "three", 1, 4, 4)
		HUD.pushToast(list, "four", 1, 4, 5)
		t.truthy(a.dismissed, "the oldest of four is dismissed")
		local live = 0
		for _, toast in list do
			if not toast.dismissed then
				live += 1
			end
		end
		t.eq(live, 3)
		local late = HUD.pushToast(list, "one", 9, 4, 6)
		t.truthy(late ~= a, "after the window the same text is a new toast")
		t.truthy(HUD.readSeconds("short", 3, 14) >= 3)
		t.eq(HUD.readSeconds(string.rep("x", 2000), 3, 14), 14)
	end,

	["the data banner speaks only for unsaved modes; heartbeats stay in range"] = function(t: Expect)
		t.eq(HUD.dataBanner("Ephemeral"), "Boot.DataEphemeral")
		t.eq(HUD.dataBanner("Guest"), "Boot.DataGuest")
		t.eq(HUD.dataBanner("Live"), nil)
		t.eq(HUD.dataBanner(nil), nil)
		t.truthy(Strings.has("Boot.DataEphemeral") and Strings.has("Boot.DataGuest"))
		local peak = 0
		for step = 0, 200 do
			local value = HUD.heartbeat(step * 0.01, 60)
			t.truthy(value >= 0 and value <= 1)
			peak = math.max(peak, value)
		end
		t.truthy(peak > 0.9, "each beat peaks")
	end,

	["touch buttons sit where InputConfig puts them when nothing is in the way"] = function(t: Expect)
		local screen = Vector2.new(844, 390)
		local placements = MobileControls.layout(touchEntries(), screen, nil, 1)
		local crouch = placements.Crouch
		t.truthy(crouch.center == Vector2.new(844 - 90, 390 - 150), "Crouch at its InputConfig spot")
		t.eq(crouch.diameter, 76)
		local menu = placements.Menu
		t.truthy(menu.center == Vector2.new(60, 60))
		for action, placement in placements do
			local r = placement.diameter / 2
			t.truthy(placement.center.X - r >= 0 and placement.center.X + r <= screen.X, action .. " inside X")
			t.truthy(placement.center.Y - r >= 0 and placement.center.Y + r <= screen.Y, action .. " inside Y")
		end
	end,

	["the bottom-right cluster lifts together to clear the jump button"] = function(t: Expect)
		local screen = Vector2.new(1180, 820)
		-- The PlayerModule's large-screen jump button (120 px at (1, -170, 1, -210)), padded by 10.
		local jump: MobileControls.Rect = {
			min = Vector2.new(screen.X - 170 - 10, screen.Y - 210 - 10),
			max = Vector2.new(screen.X - 50 + 10, screen.Y - 90 + 10),
		}
		local onFoot = touchEntries("OnFoot")
		local free = MobileControls.layout(onFoot, screen, nil, 1)
		local placed = MobileControls.layout(onFoot, screen, jump, 1)
		local lift = free.Crouch.center.Y - placed.Crouch.center.Y
		t.truthy(lift > 0, "the cluster moved up")
		for _, action in { "Crouch", "Sprint", "Flashlight", "Syringe", "Throw" } do
			t.truthy(circleClearsRect(placed[action], jump), action .. " clears the jump button")
			t.near(free[action].center.X, placed[action].center.X, 1e-6, action .. " keeps its column")
			t.near(free[action].center.Y - placed[action].center.Y, lift, 1e-6, action .. " moved with the cluster")
		end
		t.truthy(placed.Menu.center == free.Menu.center, "the top-left menu button is not affected")
		t.eq(placed.HoldBreath, nil, "buttons of other contexts are not laid out")

		-- In the locker the big breath button is the one that needs clearing.
		local locker = MobileControls.layout(touchEntries("Locker"), screen, jump, 1)
		t.truthy(circleClearsRect(locker.HoldBreath, jump), "HoldBreath clears the jump button")
		local spectator = MobileControls.layout(touchEntries("Spectator"), screen, jump, 1)
		local spectatorFree = MobileControls.layout(touchEntries("Spectator"), screen, nil, 1)
		t.truthy(spectator.SpectatePrev.center == spectatorFree.SpectatePrev.center, "mid-screen buttons stay put")
	end,

	["bottom-centre buttons lift on their own; latches trust the server after a moment"] = function(t: Expect)
		local screen = Vector2.new(800, 400)
		local jump: MobileControls.Rect = {
			min = Vector2.new(330, 220),
			max = Vector2.new(470, 330),
		}
		local placed = MobileControls.layout(touchEntries(), screen, jump, 1)
		t.truthy(circleClearsRect(placed.Struggle, jump), "Struggle clears the rect")
		t.truthy(circleClearsRect(placed.Ripcord, jump), "Ripcord clears the rect")
		t.near(placed.Struggle.center.X, 400, 1e-6, "still centred")

		t.truthy(MobileControls.reconcileLatch("Crouch", true, "Standing", 0.1), "a fresh press waits for the server")
		t.falsy(MobileControls.reconcileLatch("Crouch", true, "Standing", 2), "the server wins after the wait")
		t.truthy(MobileControls.reconcileLatch("Crouch", true, "Crouching", 0), "server agreement is immediate")
		t.truthy(
			MobileControls.reconcileLatch("Crouch", false, "Crouching", math.huge),
			"a keyboard crouch latches too"
		)
		t.falsy(MobileControls.reconcileLatch("Crouch", false, "Crouching", 0.1), "a fresh release is not undone")
		t.truthy(MobileControls.reconcileLatch("Sprint", true, "Standing", 5), "non-toggles keep their own state")
		t.truthy(MobileControls.relevant("Syringe", { syringeCharges = 1, heldItem = "None" }))
		t.falsy(MobileControls.relevant("Syringe", { syringeCharges = 0, heldItem = "None" }))
		t.falsy(MobileControls.relevant("Throw", { syringeCharges = 0, heldItem = "None" }))
		t.truthy(MobileControls.relevant("Throw", { syringeCharges = 0, heldItem = "ChemicalFlask" }))
		t.truthy(MobileControls.relevant("Sprint", { syringeCharges = 0, heldItem = "None" }))
	end,

	["UIKit primitives build and their setters drive the instances"] = function(t: Expect)
		local scratch = Instance.new("Folder")
		local screen = UIKit.screenGui("Spec", 1, Enum.ScreenInsets.CoreUISafeInsets)
		screen.Parent = scratch
		local root = UIKit.frame(screen, "Root")

		local ring = UIKit.ring(root, "Ring", 46, 2, UIKit.Palette.Bone)
		local right = ring.root:FindFirstChild("Right") :: Frame
		local left = ring.root:FindFirstChild("Left") :: Frame
		local function mask(half: Frame): UIGradient
			local arc = half:FindFirstChild("Arc") :: Frame
			local stroke = arc:FindFirstChildOfClass("UIStroke") :: UIStroke
			return stroke:FindFirstChildOfClass("UIGradient") :: UIGradient
		end
		t.truthy(right.ClipsDescendants and left.ClipsDescendants, "each half clips its ring")
		ring:SetProgress(0)
		t.falsy(right.Visible or left.Visible, "empty ring")
		ring:SetProgress(0.3)
		t.truthy(right.Visible and not left.Visible)
		t.near(mask(right).Rotation, 108, 1e-3)
		ring:SetProgress(0.8)
		t.truthy(right.Visible and left.Visible)
		t.near(mask(right).Rotation, 180, 1e-3)
		t.near(mask(left).Rotation, 288, 1e-3)
		ring:SetAlpha(0)
		t.near((mask(right).Parent :: UIStroke).Transparency, 1, 1e-6, "a hidden ring is fully transparent")

		local bar = UIKit.meterBar(root, "Bar", UIKit.Palette.Amber, 4)
		bar:SetFraction(0.25)
		t.near(bar.fill.Size.X.Scale, 0.25, 1e-6)
		bar:SetFraction(0)
		t.falsy(bar.fill.Visible, "an empty bar hides its fill")
		bar:SetAlpha(0.5)
		t.near(bar.fill.BackgroundTransparency, 0.5, 1e-6)

		local cap = UIKit.keyCap(root, "Key", 34)
		local capFrame = cap.root:FindFirstChild("Cap") :: Frame
		local text = capFrame:FindFirstChild("Text") :: TextLabel
		local dpad = capFrame:FindFirstChild("DPad") :: Frame
		local tap = capFrame:FindFirstChild("Tap") :: Frame
		cap:SetGlyph("Keyboard", Enum.KeyCode.E)
		t.truthy(text.Visible and not dpad.Visible and not tap.Visible)
		t.eq(text.Text, "E")
		cap:SetGlyph("Gamepad", Enum.KeyCode.ButtonX)
		t.eq(text.Text, "X")
		t.truthy(text.TextColor3 == UIKit.Palette.GamepadX, "face buttons carry their tint")
		cap:SetGlyph("Gamepad", Enum.KeyCode.DPadDown)
		t.truthy(dpad.Visible and not text.Visible, "d-pad glyph")
		local down = dpad:FindFirstChild("DPadDown") :: Frame
		local up = dpad:FindFirstChild("DPadUp") :: Frame
		t.truthy(down.BackgroundTransparency < up.BackgroundTransparency, "the pressed arm is lit")
		cap:SetGlyph("Touch", nil)
		t.truthy(tap.Visible and not text.Visible and not dpad.Visible, "touch mark")

		local vignette = UIKit.vignette(root, "Vignette", UIKit.Palette.Blood, 0.3, 0.1)
		vignette:SetAlpha(0)
		for _, edge in vignette.root:GetChildren() do
			if edge:IsA("Frame") then
				t.near(edge.BackgroundTransparency, 1, 1e-6, "hidden vignette")
			end
		end
		vignette:SetAlpha(1)
		local edge = vignette.root:FindFirstChild("Edge1") :: Frame
		t.near(edge.BackgroundTransparency, 0.1, 1e-6)

		local panel = UIKit.panel(root, "Panel", 0.1, 7)
		local grain = panel:FindFirstChild("Grain") :: Frame
		t.truthy(grain and grain.ZIndex < 1, "grain sits under the panel's content")

		local button = UIKit.roundButton(root, "Crouch", Strings.get("Input.Crouch"), 76)
		button:SetLatched(true)
		local rim = button.button:FindFirstChildOfClass("UIStroke") :: UIStroke
		t.truthy(rim.Color == UIKit.Palette.Amber, "latched buttons warm their rim")
		button:SetPressed(true)
		for _ = 1, 30 do
			button:Step(1 / 60)
		end
		local scale = button.button:FindFirstChildOfClass("UIScale") :: UIScale
		t.truthy(scale.Scale < 0.95, "pressed buttons sink")

		local toggle = UIKit.toggle(root, "Switch")
		toggle:SetOn(true, true)
		local knob = toggle.root:FindFirstChild("Knob") :: Frame
		t.eq(knob.Position.X.Offset, 34, "an instant switch lands on the right")
		toggle:SetOn(false)
		for _ = 1, 120 do
			toggle:Step(1 / 60)
		end
		t.near(knob.Position.X.Offset, 12, 0.05, "an animated switch settles on the left")
		scratch:Destroy()
	end,

	["settings sliders snap to the schema step and stay in range"] = function(t: Expect)
		local fov = numberSetting("BaseFov")
		t.eq(SettingsMenu.valueAt(fov, 0), fov.min)
		t.eq(SettingsMenu.valueAt(fov, 1), fov.max)
		t.eq(SettingsMenu.valueAt(fov, 0.5), 75)
		t.eq(SettingsMenu.format(fov, 75), "75")
		t.near(SettingsMenu.fractionOf(fov, 75), 0.5, 1e-9)
		t.eq(SettingsMenu.stepped(fov, 90, 1), 90, "no step past the max")
		t.eq(SettingsMenu.stepped(fov, 70, -1), 69)

		local sensitivity = numberSetting("MouseSensitivity")
		local value = SettingsMenu.valueAt(sensitivity, 0.3)
		t.near(value / sensitivity.step, math.round(value / sensitivity.step), 1e-6, "on a step")
		t.near(SettingsMenu.stepped(sensitivity, 1, 1), 1.05, 1e-9)
		t.near(SettingsMenu.stepped(sensitivity, sensitivity.min, -1), sensitivity.min, 1e-9)
		t.eq(SettingsMenu.format(sensitivity, 1.05), "1.05")
		for _, setting in SettingsSchema.List do
			t.truthy(Strings.has(setting.label), "label for " .. setting.key)
			if setting.kind == "Number" then
				local numeric = setting :: SettingsSchema.NumberSetting
				for step = 0, 20 do
					local snapped = SettingsMenu.valueAt(numeric, step / 20)
					t.truthy(snapped >= numeric.min and snapped <= numeric.max, numeric.key .. " in range")
				end
			end
		end
		t.truthy(Strings.has("Settings.Title") and Strings.has("Settings.Close"))
	end,
}
