--!strict
-- OnboardingController: the title screen and the HOW TO PLAY walkthrough (spec: onboarding brief §1-2).
--
--   * Title screen, once per join. It is mounted under the LoadingCurtain and fades in as the curtain lifts: ROVLOC in
--     a flickering typewriter stencil with a blood shadow, the one-line premise, PLAY, HOW TO PLAY and SETTINGS, and
--     this player's credits and escapes (Player.Credits / Player.Escapes, "Loading your progress..." until the data
--     layer has published them). Behind it the camera drifts slowly through the boiler room (a Cutscene camera
--     override along TutorialConfig.TitleDrift, Catmull-Rom). While it shows: the HUD is hidden, the cursor is free,
--     the "Menu" input context is pushed (gameplay actions unbound) and the walking keys are sunk, and on a gamepad the
--     selection starts on PLAY (up / down move it, A presses). A player already playing (a run that started with them)
--     never sees it, and it closes by itself if a run takes them while it is up.
--       PLAY       into the lobby; the first time (TutorialDone not set) the walkthrough runs first.
--       HOW TO PLAY  the walkthrough, then back to the title.
--       SETTINGS   the HUD's SettingsMenu over the title.
--   * Walkthrough: TutorialConfig.Pages, one taped sheet each with a procedural illustration (Frames only), page count
--     and dots; BACK / SKIP / NEXT (GOT IT on the last). Keys: left / right arrows, d-pad left / right and the bumpers
--     page, Enter goes on, B (gamepad) skips. The Controls page draws the bindings for the current device and redraws
--     when the device changes. Finishing or skipping saves TutorialDone (the hidden setting, saved in the Settings
--     blob through SettingsController; guests and ephemeral data keep it for the session). OpenWalkthrough() replays
--     it from the lobby (ObjectiveTracker's HOW TO PLAY button); it returns to wherever it was opened from.
--   * IsBusy / BusyChanged: true while either screen is up, so the objective tracker and the hints stay quiet.
--
-- Pure (tests/Specs/Onboarding.spec.luau): stepPage, primaryKey, afterPlay, titleAllowed, statsText, bodyText,
-- controlRows, drift, noiseRing.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local LobbyLayout = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Lobby)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local NoiseConfig = require(ReplicatedStorage.Shared.Config.NoiseConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local TutorialConfig = require(ReplicatedStorage.Shared.Config.TutorialConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local CursorController = require(Controllers.Core.CursorController)
local InputController = require(Controllers.Core.InputController)
local SettingsController = require(Controllers.Core.SettingsController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)
local HUD = require(Controllers.HUD)
local InputGlyphs = require(Controllers.HUD.InputGlyphs)
local UIKit = require(Controllers.HUD.UIKit)

local log = Log.new("Onboarding")

local P = Attributes.Player
local Palette = UIKit.Palette

export type Mode = "Hidden" | "Title" | "Walkthrough"
export type ControlRowView = { label: string, glyph: InputGlyphs.Glyph }
export type DriftKey = { eye: Vector3, look: Vector3 }

type Button = { button: TextButton, stroke: UIStroke, primary: boolean, hovered: boolean }

type TitleView = {
	group: CanvasGroup,
	scale: UIScale,
	mark: TextLabel,
	shadow: TextLabel,
	play: Button,
	howTo: Button,
	settings: Button,
	firstTime: TextLabel,
	stats: TextLabel,
	underway: TextLabel,
}

type WalkView = {
	group: CanvasGroup,
	scale: UIScale,
	counter: TextLabel,
	title: TextLabel,
	body: TextLabel,
	arts: { [string]: Frame },
	dots: { Frame },
	back: Button,
	skip: Button,
	nextButton: Button,
	controls: Frame,
	controlCaps: { InputGlyphs.Cap },
	controlLabels: { TextLabel },
}

type View = {
	backdropGui: ScreenGui,
	gui: ScreenGui,
	shade: CanvasGroup,
	dim: Frame,
	title: TitleView,
	walk: WalkView,
	buttons: { Button },
}

local BACKDROP_ORDER = 44
local SCREEN_ORDER = 45 -- above the lobby screens (40), under the settings menu (60)
local TOKEN = "Onboarding"
local PAGE_ACTION = "Rovloc.OnboardingPage"
local BLOCK_ACTION = "Rovloc.OnboardingBlockMove"
local CURTAIN_NAME = "LoadingCurtain"
local TITLE_FADE_IN = 0.7 -- alpha per second
local TITLE_FADE_OUT = 1.6
local WALK_FADE = 3.5
local CAMERA_FOV = 60
local CAMERA_BLEND_OUT = 1.6
local TITLE_WIDTH = 470
local TITLE_HEIGHT = 380 -- design height the title column needs (fit scale)
local SHEET_WIDTH = 620
local SHEET_HEIGHT = 410
local ART_WIDTH = 250
local ART_HEIGHT = 262
local FLICKER_SEED = 1733
local BLOCK_KEYS: { Enum.KeyCode } = {
	Enum.KeyCode.W,
	Enum.KeyCode.A,
	Enum.KeyCode.S,
	Enum.KeyCode.D,
	Enum.KeyCode.Up,
	Enum.KeyCode.Down,
	Enum.KeyCode.Left,
	Enum.KeyCode.Right,
	Enum.KeyCode.Space,
}
local PREV_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.Left] = true,
	[Enum.KeyCode.DPadLeft] = true,
	[Enum.KeyCode.ButtonL1] = true,
}
local NEXT_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.Right] = true,
	[Enum.KeyCode.DPadRight] = true,
	[Enum.KeyCode.ButtonR1] = true,
	[Enum.KeyCode.Return] = true,
	[Enum.KeyCode.KeypadEnter] = true,
}

local OnboardingController = {}

OnboardingController.Name = "OnboardingController"

local busyChanged: Signal.Signal<boolean> = Signal.new()
OnboardingController.BusyChanged = busyChanged

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local view: View? = nil
local mode: Mode = "Hidden"
local returnTo: Mode = "Hidden" -- where the walkthrough goes back to
local page = 1
local clock = 0
local titleAlpha = 0
local walkAlpha = 0
local titleShown = false -- the title has been put up this session (once per join)
local holding = false -- context, cursor, key sinks held
local hudHidden = false
local cameraHeld = false
local renderedDevice: string? = nil

--------------------------------------------------------------------------------
-- Pure (specs: tests/Specs/Onboarding.spec.luau)
--------------------------------------------------------------------------------

-- The page after moving `delta` pages from `index`, kept within 1..count.
function OnboardingController.stepPage(index: number, delta: number, count: number): number
	return math.clamp(math.floor(index + delta), 1, math.max(count, 1))
end

-- The primary button's Strings key on page `index` of `count`: NEXT, or GOT IT on the last page.
function OnboardingController.primaryKey(index: number, count: number): string
	return if index >= count then "Tutorial.Done" else "Tutorial.Next"
end

-- Where PLAY leads: the walkthrough until it has been finished or skipped once, then straight into the lobby.
function OnboardingController.afterPlay(tutorialDone: boolean): Mode
	return if tutorialDone then "Hidden" else "Walkthrough"
end

-- Whether the title screen may go up for a player in `lifeState` (never over someone already playing a run).
function OnboardingController.titleAllowed(lifeState: unknown): boolean
	return lifeState ~= "Alive" and lifeState ~= "Downed"
end

-- The stats line: credits and escapes once the data layer has published them, else the loading line.
function OnboardingController.statsText(credits: unknown, escapes: unknown): string
	if type(credits) ~= "number" or type(escapes) ~= "number" then
		return Strings.get("Title.Loading")
	end
	return Strings.get("Title.Stats", math.floor(credits), math.floor(escapes))
end

-- A page's body text for the device (the Controls page has one per device; Teamwork names the airlock's wait).
function OnboardingController.bodyText(entry: TutorialConfig.Page, device: string): string
	if entry.deviceBody then
		return Strings.get(entry.body .. "." .. device)
	elseif entry.id == "Teamwork" then
		return Strings.get(entry.body, GameConfig.StragglerSeconds)
	end
	return Strings.get(entry.body)
end

-- The Controls page's rows for the device: each label and the glyph that stands for it.
function OnboardingController.controlRows(device: string): { ControlRowView }
	local out: { ControlRowView } = {}
	for _, row in TutorialConfig.ControlRows do
		local glyph: InputGlyphs.Glyph
		local action = row.action
		if action then
			glyph = InputGlyphs.forAction(action, device)
		else
			local kind: UIKit.GlyphKind = if device == "Touch"
				then "Touch"
				elseif device == "Gamepad" then "Gamepad"
				else "Keyboard"
			glyph = { kind = kind, text = Strings.get((row.glyph or "") .. "." .. device) }
		end
		table.insert(out, { label = Strings.get(row.label), glyph = glyph })
	end
	return out
end

local function catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, f: number): Vector3
	local f2, f3 = f * f, f * f * f
	return (p1 * 2 + (p2 - p0) * f + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * f2 + (p1 * 3 - p0 - p2 * 3 + p3) * f3) * 0.5
end

-- The title camera at time `t` on a looping Catmull-Rom path through `keys` (one loop per `period` seconds): the
-- eye and the point it looks at, in the keys' own space.
function OnboardingController.drift(keys: { DriftKey }, t: number, period: number): (Vector3, Vector3)
	local n = #keys
	if n == 0 then
		return Vector3.zero, -Vector3.zAxis
	elseif n == 1 then
		return keys[1].eye, keys[1].look
	end
	local u = ((t % period) / period) * n
	local i = math.floor(u)
	local f = u - i
	local function at(offset: number): DriftKey
		return keys[((i + offset) % n) + 1]
	end
	local k0, k1, k2, k3 = at(-1), at(0), at(1), at(2)
	return catmull(k0.eye, k1.eye, k2.eye, k3.eye, f), catmull(k0.look, k1.look, k2.look, k3.look, f)
end

-- A noise radius drawn as a ring: `pixels` for the loudest kind, area-true (square root) for the rest.
function OnboardingController.noiseRing(radius: number, loudest: number, pixels: number): number
	return pixels * math.sqrt(math.clamp(radius / math.max(loudest, 1e-3), 0, 1))
end

--------------------------------------------------------------------------------
-- Small builders
--------------------------------------------------------------------------------

local function play(preset: string)
	xpcall(function()
		AudioController.PlayLocal(preset)
	end, function(err: any)
		log.warnThrottled("sound", 60, "ui sound failed: %s", tostring(err))
	end)
end

local function makeButton(
	parent: Instance,
	name: string,
	text: string,
	size: UDim2,
	primary: boolean,
	highlight: Frame
): Button
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = size
	button.BackgroundColor3 = if primary then Palette.Raised else Palette.Panel
	button.BackgroundTransparency = if primary then 0.05 else 0.2
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.FontFace = if primary then UIKit.Fonts.Heavy else UIKit.Fonts.Strong
	button.TextSize = if primary then 20 else UIKit.TextSize.Body + 1
	button.TextColor3 = Palette.Bone
	button.Text = text
	button.Selectable = true
	button.SelectionImageObject = highlight
	button.Parent = parent
	UIKit.corner(button, UDim.new(0, 5))
	local stroke =
		UIKit.stroke(button, if primary then Palette.Amber else Palette.StrokeDim, if primary then 1.5 else 1, 0)
	local entry: Button = { button = button, stroke = stroke, primary = primary, hovered = false }
	button.MouseEnter:Connect(function()
		entry.hovered = true
	end)
	button.MouseLeave:Connect(function()
		entry.hovered = false
	end)
	return entry
end

local function ring(parent: Instance, name: string, diameter: number, color: Color3, transparency: number): Frame
	local frame = UIKit.frame(parent, name)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(diameter, diameter)
	UIKit.round(frame)
	UIKit.stroke(frame, color, 2, transparency)
	return frame
end

local function dot(parent: Instance, name: string, diameter: number, color: Color3, position: UDim2): Frame
	local frame = UIKit.fill(parent, name, color, 0)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = position
	frame.Size = UDim2.fromOffset(diameter, diameter)
	UIKit.round(frame)
	return frame
end

local function caption(parent: Instance, name: string, text: string, position: UDim2, color: Color3?): TextLabel
	local label = UIKit.label(parent, name, UIKit.Fonts.Strong, UIKit.TextSize.Caps, color or Palette.Ash)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = position
	label.Size = UDim2.fromOffset(110, 16)
	label.TextWrapped = false
	label.Text = text
	return label
end

local function block(
	parent: Instance,
	name: string,
	color: Color3,
	transparency: number,
	position: UDim2,
	size: UDim2
): Frame
	local frame = UIKit.fill(parent, name, color, transparency)
	frame.Position = position
	frame.Size = size
	return frame
end

--------------------------------------------------------------------------------
-- Illustrations (one Frame of ART_WIDTH x ART_HEIGHT each)
--------------------------------------------------------------------------------

local function artGoal(art: Frame)
	-- Six floors stacked bottom (basement) to top (roof); a climbing dotted line; a parachute off the top.
	local floors = 6
	local h, gap, w = 26, 8, 150
	local left = 20
	local bottom = ART_HEIGHT - 16
	for i = 1, floors do
		local y = bottom - i * h - (i - 1) * gap
		local slab = block(
			art,
			"Floor" .. i,
			if i == floors then Palette.Track else Palette.Raised,
			0.1,
			UDim2.fromOffset(left, y),
			UDim2.fromOffset(w, h)
		)
		UIKit.stroke(slab, Palette.StrokeDim, 1, 0)
		local key = if i == 1
			then Strings.get("Tutorial.Art.Basement")
			elseif i == floors then Strings.get("Tutorial.Art.Roof")
			else Strings.get("Tutorial.Art.Floor", i - 1)
		local label = UIKit.label(slab, "Label", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ash)
		label.Text = key
		label.TextWrapped = false
		local mark = dot(art, "Climb" .. i, 6, Palette.Amber, UDim2.fromOffset(left + w + 18, y + h / 2))
		mark.BackgroundTransparency = 0.15 + 0.1 * (floors - i)
	end
	dot(art, "You", 12, Palette.Amber, UDim2.fromOffset(left + w + 18, bottom - h / 2))
	-- The canopy: the top half of a disc, two risers down to the jumper.
	local clip = UIKit.frame(art, "Canopy")
	clip.ClipsDescendants = true
	clip.Position = UDim2.fromOffset(left + w + 4, 2)
	clip.Size = UDim2.fromOffset(58, 22)
	local disc = UIKit.fill(clip, "Disc", Palette.Ember, 0.05)
	disc.Size = UDim2.fromOffset(58, 44)
	UIKit.round(disc)
	for index, x in { 8, 50 } do
		local riser = block(
			art,
			"Riser" .. index,
			Palette.Ash,
			0.2,
			UDim2.fromOffset(left + w + 4 + x, 22),
			UDim2.fromOffset(1, 16)
		)
		riser.Rotation = if index == 1 then -22 else 22
	end
	dot(art, "Jumper", 8, Palette.Bone, UDim2.fromOffset(left + w + 33, 42))
end

local function artCreature(art: Frame)
	-- An eye with sound rings to its left (HEARS) and a sight cone to its right (SEES).
	for index, diameter in { 70, 120, 170 } do
		local wave = ring(art, "Wave" .. index, diameter, Palette.Ash, 0.35 + index * 0.15)
		wave.Position = UDim2.fromOffset(70, 110)
	end
	local eye = UIKit.fill(art, "Eye", Palette.Bone, 0.05)
	eye.AnchorPoint = Vector2.new(0.5, 0.5)
	eye.Position = UDim2.fromOffset(150, 110)
	eye.Size = UDim2.fromOffset(110, 56)
	UIKit.corner(eye, UDim.new(0.5, 0))
	dot(eye, "Iris", 40, Palette.Blood, UDim2.fromScale(0.5, 0.5))
	local pupil = block(eye, "Pupil", Palette.Ink, 0, UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(6, 34))
	pupil.AnchorPoint = Vector2.new(0.5, 0.5)
	UIKit.corner(pupil, UDim.new(0.5, 0))
	local cone = block(art, "Sight", Palette.Amber, 0.55, UDim2.fromOffset(205, 82), UDim2.fromOffset(45, 56))
	UIKit.gradient(cone, 0, { { 0, 0.2 }, { 1, 1 } })
	caption(art, "Hears", Strings.get("Tutorial.Art.Hears"), UDim2.fromOffset(70, 210))
	caption(art, "Sees", Strings.get("Tutorial.Art.Sees"), UDim2.fromOffset(200, 210))
end

local function artNoise(art: Frame)
	-- Rings to scale (area-true) for crouch, walk, sprint and a grate kick around the player.
	local kinds = NoiseConfig.Kinds
	local loudest = kinds.GrateKick.radius
	local entries: { { name: string, radius: number, label: string, color: Color3 } } = {
		{ name = "Kick", radius = kinds.GrateKick.radius, label = "Tutorial.Art.Kick", color = Palette.Blood },
		{ name = "Sprint", radius = kinds.Sprint.radius, label = "Tutorial.Art.Sprint", color = Palette.Ember },
		{ name = "Walk", radius = kinds.Walk.radius, label = "Tutorial.Art.Walk", color = Palette.Amber },
		{ name = "Crouch", radius = kinds.CrouchWalk.radius, label = "Tutorial.Art.Crouch", color = Palette.Moss },
	}
	for _, entry in entries do
		local diameter = 2 * OnboardingController.noiseRing(entry.radius, loudest, 112)
		local circle = ring(art, entry.name, diameter, entry.color, 0.15)
		circle.Position = UDim2.fromOffset(ART_WIDTH / 2, 120)
		local label = caption(
			art,
			entry.name .. "Label",
			Strings.get(entry.label),
			UDim2.fromOffset(ART_WIDTH / 2, 0),
			entry.color
		)
		label.Position = UDim2.fromOffset(ART_WIDTH / 2, 120 - diameter / 2 - 8)
	end
	dot(art, "You", 8, Palette.Bone, UDim2.fromOffset(ART_WIDTH / 2, 120))
end

local function artTools(art: Frame)
	-- Four tiles: flashlight, flask, vent grate, locker.
	local tiles: { { name: string, label: string } } = {
		{ name = "Light", label = "Tutorial.Art.Light" },
		{ name = "Flask", label = "Tutorial.Art.Flask" },
		{ name = "Vent", label = "Tutorial.Art.Vent" },
		{ name = "Locker", label = "Tutorial.Art.Locker" },
	}
	for index, entry in tiles do
		local col, row = (index - 1) % 2, (index - 1) // 2
		local tile = UIKit.fill(art, entry.name, Palette.Raised, 0.15)
		tile.Position = UDim2.fromOffset(8 + col * 122, 4 + row * 128)
		tile.Size = UDim2.fromOffset(112, 118)
		UIKit.corner(tile, UDim.new(0, 6))
		UIKit.stroke(tile, Palette.StrokeDim, 1, 0)
		caption(tile, "Caption", Strings.get(entry.label), UDim2.new(0.5, 0, 1, -12))
		if entry.name == "Light" then
			block(tile, "Body", Palette.Smoke, 0, UDim2.fromOffset(16, 44), UDim2.fromOffset(36, 16))
			block(tile, "Head", Palette.Ash, 0, UDim2.fromOffset(50, 38), UDim2.fromOffset(10, 28))
			local beam = block(tile, "Beam", Palette.Amber, 0.35, UDim2.fromOffset(60, 30), UDim2.fromOffset(44, 44))
			UIKit.gradient(beam, 0, { { 0, 0.1 }, { 1, 1 } })
		elseif entry.name == "Flask" then
			block(tile, "Neck", Palette.Ash, 0.1, UDim2.fromOffset(50, 18), UDim2.fromOffset(12, 22))
			local bulb = dot(tile, "Bulb", 46, Palette.Moss, UDim2.fromOffset(56, 62))
			UIKit.stroke(bulb, Palette.Bone, 1, 0.4)
		elseif entry.name == "Vent" then
			local frame = block(tile, "Frame", Palette.Track, 0, UDim2.fromOffset(24, 18), UDim2.fromOffset(64, 60))
			UIKit.stroke(frame, Palette.Ash, 2, 0.1)
			for slat = 1, 5 do
				block(
					frame,
					"Slat" .. slat,
					Palette.Ink,
					0.1,
					UDim2.fromOffset(6, slat * 10 - 4),
					UDim2.new(1, -12, 0, 4)
				)
			end
		else
			local door = block(tile, "Door", Palette.Smoke, 0, UDim2.fromOffset(36, 8), UDim2.fromOffset(40, 82))
			UIKit.stroke(door, Palette.Ash, 1, 0.2)
			for slit = 1, 3 do
				block(door, "Slit" .. slit, Palette.Ink, 0, UDim2.fromOffset(8, 6 + slit * 6), UDim2.new(1, -16, 0, 3))
			end
		end
	end
end

local function figure(parent: Instance, name: string, position: UDim2, rotation: number, color: Color3): Frame
	local root = UIKit.frame(parent, name)
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = position
	root.Size = UDim2.fromOffset(30, 70)
	root.Rotation = rotation
	dot(root, "Head", 18, color, UDim2.fromOffset(15, 9))
	local body = block(root, "Body", color, 0, UDim2.fromOffset(6, 20), UDim2.fromOffset(18, 48))
	UIKit.corner(body, UDim.new(0, 6))
	return root
end

local function artTeamwork(art: Frame)
	-- A teammate down, another kneeling with a cross over them; the stairwell's countdown ring.
	figure(art, "Standing", UDim2.fromOffset(46, 92), 0, Palette.Bone)
	figure(art, "Downed", UDim2.fromOffset(110, 112), 90, Palette.Ember)
	local cross = UIKit.frame(art, "Cross")
	cross.AnchorPoint = Vector2.new(0.5, 0.5)
	cross.Position = UDim2.fromOffset(110, 70)
	cross.Size = UDim2.fromOffset(20, 20)
	block(cross, "V", Palette.Moss, 0, UDim2.fromOffset(7, 0), UDim2.fromOffset(6, 20))
	block(cross, "H", Palette.Moss, 0, UDim2.fromOffset(0, 7), UDim2.fromOffset(20, 6))
	caption(art, "Revive", Strings.get("Tutorial.Art.Revive"), UDim2.fromOffset(80, 150), Palette.Moss)
	local timer = UIKit.ring(art, "Timer", 74, 5, Palette.Amber)
	timer.root.AnchorPoint = Vector2.new(0.5, 0.5)
	timer.root.Position = UDim2.fromOffset(196, 198)
	timer:SetProgress(0.7)
	local countdown = UIKit.label(timer.root, "Time", UIKit.Fonts.Heavy, 18, Palette.Bone)
	countdown.Text = Strings.formatTime(GameConfig.StragglerSeconds)
	countdown.TextWrapped = false
	caption(art, "Seal", Strings.get("Tutorial.Art.Seal"), UDim2.fromOffset(196, 248))
end

local function artLobby(art: Frame)
	-- The lobby's floor plan to scale: rooms, the bus, the consoles and the glowing route.
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	for _, room in LobbyLayout.rooms do
		minX, minZ = math.min(minX, room.rect.x), math.min(minZ, room.rect.z)
		maxX, maxZ = math.max(maxX, room.rect.x + room.rect.w), math.max(maxZ, room.rect.z + room.rect.d)
	end
	local scale = math.min((ART_WIDTH - 12) / (maxX - minX), (ART_HEIGHT - 40) / (maxZ - minZ))
	local function at(x: number, z: number): UDim2
		return UDim2.fromOffset(6 + (x - minX) * scale, 6 + (z - minZ) * scale)
	end
	for _, room in LobbyLayout.rooms do
		local frame = block(
			art,
			room.id,
			Palette.Raised,
			0.2,
			at(room.rect.x, room.rect.z),
			UDim2.fromOffset(room.rect.w * scale, room.rect.d * scale)
		)
		UIKit.stroke(frame, Palette.StrokeDim, 1, 0)
	end
	local pads: { LayoutSchema.Anchor } = {}
	local spawn = Vector3.zero
	local spawns = 0
	for _, anchor in LobbyLayout.anchors do
		if anchor.kind == "ReadyPad" then
			table.insert(pads, anchor)
		elseif anchor.kind == "PlayerSpawn" then
			spawn += anchor.pos
			spawns += 1
		elseif anchor.kind == "Terminal" then
			local id = anchor.id
			local key = if string.find(id, "Difficulty", 1, true) then "Tutorial.Art.Console" else "Tutorial.Art.Supply"
			local mark = dot(art, id, 9, Palette.Moss, at(anchor.pos.X, anchor.pos.Z))
			mark.ZIndex = 3
			local label = caption(art, id .. "Label", Strings.get(key), at(anchor.pos.X, anchor.pos.Z), Palette.Moss)
			label.Position = at(anchor.pos.X, anchor.pos.Z) + UDim2.fromOffset(if anchor.pos.X < 10 then 34 else 0, 14)
		end
	end
	if #pads > 0 then
		local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
		for _, pad in pads do
			x0, x1 = math.min(x0, pad.pos.X), math.max(x1, pad.pos.X)
			z0, z1 = math.min(z0, pad.pos.Z), math.max(z1, pad.pos.Z)
		end
		local bus = block(
			art,
			"Bus",
			Palette.Amber,
			0.55,
			at(x0 - 6, z0 - 4.5),
			UDim2.fromOffset((x1 - x0 + 12) * scale, 9 * scale)
		)
		UIKit.corner(bus, UDim.new(0, 3))
		local label =
			caption(art, "BusLabel", Strings.get("Tutorial.Art.Bus"), at((x0 + x1) / 2, z0 + 12), Palette.Amber)
		label.ZIndex = 3
		if spawns > 0 then
			local start = spawn / spawns
			dot(art, "Start", 10, Palette.Bone, at(start.X, start.Z))
			caption(art, "StartLabel", Strings.get("Tutorial.Art.Start"), at(start.X, start.Z + 7), Palette.Bone)
			local target = Vector3.new(x0 - 7, 0, (z0 + z1) / 2)
			for step = 1, 7 do
				local p = start:Lerp(target, step / 8)
				local mark = dot(art, "Route" .. step, 5, Palette.Amber, at(p.X, p.Z))
				mark.BackgroundTransparency = 0.1
			end
		end
	end
end

local function buildControls(art: Frame): (Frame, { InputGlyphs.Cap }, { TextLabel })
	local list = UIKit.frame(art, "Rows")
	UIKit.list(list, Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)
	local caps: { InputGlyphs.Cap } = {}
	local labels: { TextLabel } = {}
	for index in TutorialConfig.ControlRows do
		local row = UIKit.frame(list, "Row" .. index)
		row.LayoutOrder = index
		row.Size = UDim2.new(1, 0, 0, 24)
		local slot = UIKit.frame(row, "Glyph")
		slot.Size = UDim2.fromOffset(96, 24)
		UIKit.list(
			slot,
			Enum.FillDirection.Horizontal,
			0,
			Enum.HorizontalAlignment.Right,
			Enum.VerticalAlignment.Center
		)
		local cap = InputGlyphs.cap(slot, "Cap", 22)
		local label = UIKit.label(row, "Label", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Bone)
		label.Position = UDim2.fromOffset(106, 0)
		label.Size = UDim2.new(1, -106, 1, 0)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextWrapped = false
		label.TextTruncate = Enum.TextTruncate.AtEnd
		table.insert(caps, cap)
		table.insert(labels, label)
	end
	return list, caps, labels
end

--------------------------------------------------------------------------------
-- Screens
--------------------------------------------------------------------------------

local function buildTitle(layer: Frame, highlight: Frame): TitleView
	local group = Instance.new("CanvasGroup")
	group.Name = "Title"
	group.BackgroundTransparency = 1
	group.BorderSizePixel = 0
	group.AnchorPoint = Vector2.new(0, 0.5)
	group.Position = UDim2.fromScale(0.07, 0.5)
	group.Size = UDim2.fromOffset(TITLE_WIDTH, TITLE_HEIGHT)
	group.GroupTransparency = 1
	group.Parent = layer
	local scale = Instance.new("UIScale")
	scale.Parent = group
	UIKit.list(group, Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center)

	local markSlot = UIKit.frame(group, "Mark")
	markSlot.LayoutOrder = 1
	markSlot.Size = UDim2.new(1, 0, 0, 96)
	local shadow = UIKit.label(markSlot, "Shadow", UIKit.Fonts.Title, 92, Palette.Blood)
	shadow.Position = UDim2.fromOffset(4, 4)
	shadow.TextXAlignment = Enum.TextXAlignment.Left
	shadow.TextWrapped = false
	shadow.Text = Strings.get("Title.Name")
	shadow.TextTransparency = 0.25
	local mark = UIKit.label(markSlot, "Text", UIKit.Fonts.Title, 92, Palette.Bone)
	mark.TextXAlignment = Enum.TextXAlignment.Left
	mark.TextWrapped = false
	mark.Text = Strings.get("Title.Name")
	UIKit.textStroke(mark, 0.3)
	local scratch = block(markSlot, "Scratch", Palette.Blood, 0.1, UDim2.new(0, 2, 1, -6), UDim2.new(0.72, 0, 0, 2))
	UIKit.gradient(scratch, 0, { { 0, 0 }, { 0.7, 0.3 }, { 1, 1 } })

	local premise = UIKit.label(group, "Premise", UIKit.Fonts.Body, UIKit.TextSize.Body + 1, Palette.Ash)
	premise.LayoutOrder = 2
	premise.Size = UDim2.new(1, -40, 0, 0)
	premise.AutomaticSize = Enum.AutomaticSize.Y
	premise.TextXAlignment = Enum.TextXAlignment.Left
	premise.Text = Strings.get("Title.Premise")
	UIKit.textStroke(premise, 0.5)

	local spacer = UIKit.frame(group, "Spacer")
	spacer.LayoutOrder = 3
	spacer.Size = UDim2.new(1, 0, 0, 6)

	local playButton = makeButton(group, "Play", Strings.get("Title.Play"), UDim2.fromOffset(300, 52), true, highlight)
	playButton.button.LayoutOrder = 4
	local firstTime = UIKit.label(group, "FirstTime", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Amber)
	firstTime.LayoutOrder = 5
	firstTime.Size = UDim2.new(1, 0, 0, 16)
	firstTime.TextXAlignment = Enum.TextXAlignment.Left
	firstTime.Text = Strings.get("Title.FirstTime")
	local howTo =
		makeButton(group, "HowToPlay", Strings.get("Title.HowToPlay"), UDim2.fromOffset(300, 46), false, highlight)
	howTo.button.LayoutOrder = 6
	local settings =
		makeButton(group, "Settings", Strings.get("Title.Settings"), UDim2.fromOffset(300, 46), false, highlight)
	settings.button.LayoutOrder = 7
	playButton.button.NextSelectionDown = howTo.button
	howTo.button.NextSelectionUp = playButton.button
	howTo.button.NextSelectionDown = settings.button
	settings.button.NextSelectionUp = howTo.button

	local stats = UIKit.label(group, "Stats", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Ash)
	stats.LayoutOrder = 8
	stats.Size = UDim2.new(1, 0, 0, 22)
	stats.TextXAlignment = Enum.TextXAlignment.Left
	stats.TextWrapped = false
	local underway = UIKit.label(group, "Underway", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Ember)
	underway.LayoutOrder = 9
	underway.Size = UDim2.new(1, -40, 0, 0)
	underway.AutomaticSize = Enum.AutomaticSize.Y
	underway.TextXAlignment = Enum.TextXAlignment.Left
	underway.Text = Strings.get("Title.RunUnderway")
	underway.Visible = false

	return {
		group = group,
		scale = scale,
		mark = mark,
		shadow = shadow,
		play = playButton,
		howTo = howTo,
		settings = settings,
		firstTime = firstTime,
		stats = stats,
		underway = underway,
	}
end

local function buildWalkthrough(layer: Frame, highlight: Frame): WalkView
	local group = Instance.new("CanvasGroup")
	group.Name = "Walkthrough"
	group.BackgroundTransparency = 1
	group.BorderSizePixel = 0
	group.AnchorPoint = Vector2.new(0.5, 0.5)
	group.Position = UDim2.fromScale(0.5, 0.5)
	group.Size = UDim2.fromOffset(SHEET_WIDTH + 40, SHEET_HEIGHT + 40)
	group.GroupTransparency = 1
	group.Visible = false
	group.Parent = layer
	local scale = Instance.new("UIScale")
	scale.Parent = group

	local sheet = UIKit.panel(group, "Sheet", 0.04, 9071)
	sheet.AnchorPoint = Vector2.new(0.5, 0.5)
	sheet.Position = UDim2.fromScale(0.5, 0.5)
	sheet.Size = UDim2.fromOffset(SHEET_WIDTH, SHEET_HEIGHT)
	sheet.Rotation = -0.6
	for index, x in { 0.12, 0.88 } do
		local tape = block(sheet, "Tape" .. index, Palette.Bone, 0.62, UDim2.fromScale(x, 0), UDim2.fromOffset(76, 20))
		tape.AnchorPoint = Vector2.new(0.5, 0.5)
		tape.Rotation = if index == 1 then -9 else 7
		tape.ZIndex = 5
	end

	local header = UIKit.label(sheet, "Header", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ash)
	header.Position = UDim2.fromOffset(24, 14)
	header.Size = UDim2.fromOffset(200, 18)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = Strings.get("Tutorial.Header")
	local counter = UIKit.label(sheet, "Counter", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ash)
	counter.AnchorPoint = Vector2.new(1, 0)
	counter.Position = UDim2.new(1, -24, 0, 14)
	counter.Size = UDim2.fromOffset(80, 18)
	counter.TextXAlignment = Enum.TextXAlignment.Right
	local rule = block(sheet, "Rule", Palette.StrokeDim, 0, UDim2.fromOffset(24, 36), UDim2.new(1, -48, 0, 1))
	rule.ZIndex = 2

	local artArea = UIKit.frame(sheet, "Art")
	artArea.Position = UDim2.fromOffset(24, 48)
	artArea.Size = UDim2.fromOffset(ART_WIDTH, ART_HEIGHT)
	local arts: { [string]: Frame } = {}
	local builders: { [string]: (Frame) -> () } = {
		Goal = artGoal,
		Creature = artCreature,
		Noise = artNoise,
		Tools = artTools,
		Teamwork = artTeamwork,
		Lobby = artLobby,
	}
	local controls: Frame? = nil
	local controlCaps: { InputGlyphs.Cap } = {}
	local controlLabels: { TextLabel } = {}
	for _, entry in TutorialConfig.Pages do
		local art = UIKit.frame(artArea, entry.id)
		art.Visible = false
		art.ClipsDescendants = true
		local builder = builders[entry.art]
		if builder then
			builder(art)
		elseif entry.art == "Controls" then
			controls, controlCaps, controlLabels = buildControls(art)
		end
		arts[entry.id] = art
	end

	local title = UIKit.label(sheet, "Title", UIKit.Fonts.Title, UIKit.TextSize.Title, Palette.Bone)
	title.Position = UDim2.fromOffset(ART_WIDTH + 48, 52)
	title.Size = UDim2.new(1, -(ART_WIDTH + 72), 0, 34)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextWrapped = false
	UIKit.textStroke(title, 0.4)
	local body = UIKit.label(sheet, "Body", UIKit.Fonts.Body, UIKit.TextSize.Body + 1, Palette.Bone)
	body.Position = UDim2.fromOffset(ART_WIDTH + 48, 96)
	body.Size = UDim2.new(1, -(ART_WIDTH + 72), 0, ART_HEIGHT - 52)
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.LineHeight = 1.15

	local dotsRow = UIKit.frame(sheet, "Dots")
	dotsRow.AnchorPoint = Vector2.new(0.5, 1)
	dotsRow.Position = UDim2.new(0.5, 0, 1, -76)
	dotsRow.Size = UDim2.fromOffset(200, 10)
	UIKit.list(
		dotsRow,
		Enum.FillDirection.Horizontal,
		8,
		Enum.HorizontalAlignment.Center,
		Enum.VerticalAlignment.Center
	)
	local dots: { Frame } = {}
	for index in TutorialConfig.Pages do
		local pip = UIKit.fill(dotsRow, "Dot" .. index, Palette.Smoke, 0)
		pip.LayoutOrder = index
		pip.Size = UDim2.fromOffset(8, 8)
		UIKit.round(pip)
		table.insert(dots, pip)
	end

	local back = makeButton(sheet, "Back", Strings.get("Tutorial.Back"), UDim2.fromOffset(120, 46), false, highlight)
	back.button.AnchorPoint = Vector2.new(0, 1)
	back.button.Position = UDim2.new(0, 24, 1, -18)
	local skip = makeButton(sheet, "Skip", Strings.get("Tutorial.Skip"), UDim2.fromOffset(110, 46), false, highlight)
	skip.button.AnchorPoint = Vector2.new(0, 1)
	skip.button.Position = UDim2.new(0, 156, 1, -18)
	skip.button.TextColor3 = Palette.Ash
	local nextButton =
		makeButton(sheet, "Next", Strings.get("Tutorial.Next"), UDim2.fromOffset(180, 46), true, highlight)
	nextButton.button.AnchorPoint = Vector2.new(1, 1)
	nextButton.button.Position = UDim2.new(1, -24, 1, -18)
	back.button.NextSelectionRight = skip.button
	skip.button.NextSelectionLeft = back.button
	skip.button.NextSelectionRight = nextButton.button
	nextButton.button.NextSelectionLeft = skip.button

	return {
		group = group,
		scale = scale,
		counter = counter,
		title = title,
		body = body,
		arts = arts,
		dots = dots,
		back = back,
		skip = skip,
		nextButton = nextButton,
		controls = controls or UIKit.frame(nil, "Rows"),
		controlCaps = controlCaps,
		controlLabels = controlLabels,
	}
end

local function build(parent: Instance): View
	local backdropGui = UIKit.screenGui("OnboardingBackdrop", BACKDROP_ORDER, Enum.ScreenInsets.None)
	backdropGui.Enabled = false
	-- The title's shade: dark on the left where the words sit, open on the right where the boiler room shows.
	local shade = Instance.new("CanvasGroup")
	shade.Name = "Shade"
	shade.BackgroundTransparency = 1
	shade.BorderSizePixel = 0
	shade.Size = UDim2.fromScale(1, 1)
	shade.GroupTransparency = 1
	shade.Parent = backdropGui
	local wash = UIKit.fill(shade, "Wash", Palette.Ink, 0)
	UIKit.gradient(wash, 0, { { 0, 0.02 }, { 0.38, 0.25 }, { 0.7, 0.85 }, { 1, 0.95 } })
	local vignette = UIKit.vignette(shade, "Edges", Palette.Ink, 0.22, 0.1)
	vignette:SetAlpha(1)
	local dim = UIKit.fill(backdropGui, "Dim", Palette.Ink, 1)

	local gui = UIKit.screenGui("Onboarding", SCREEN_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	gui.Enabled = false
	local layer = UIKit.frame(gui, "Layer")
	local highlight = UIKit.frame(nil, "Selection")
	UIKit.corner(highlight, UDim.new(0, 6))
	UIKit.stroke(highlight, Palette.Amber, 2, 0.05)

	local title = buildTitle(layer, highlight)
	local walk = buildWalkthrough(layer, highlight)
	backdropGui.Parent = parent
	gui.Parent = parent
	return {
		backdropGui = backdropGui,
		gui = gui,
		shade = shade,
		dim = dim,
		title = title,
		walk = walk,
		buttons = {
			title.play,
			title.howTo,
			title.settings,
			walk.back,
			walk.skip,
			walk.nextButton,
		},
	}
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local function isBusy(): boolean
	return mode ~= "Hidden" or titleAlpha > 0.02 or walkAlpha > 0.02
end

local function sinkKey(_action: string, _state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	return Enum.ContextActionResult.Sink
end

local function selectFor(button: TextButton)
	if InputController.GetDevice() == "Gamepad" then
		GuiService.SelectedObject = button
	end
end

local function hold(on: boolean)
	if on == holding then
		return
	end
	holding = on
	if on then
		CursorController.RequestFree(TOKEN)
		InputController.PushContext("Menu", TOKEN)
		ContextActionService:BindActionAtPriority(
			BLOCK_ACTION,
			sinkKey,
			false,
			Enum.ContextActionPriority.High.Value,
			table.unpack(BLOCK_KEYS)
		)
		busyChanged:Fire(true)
	else
		ContextActionService:UnbindAction(BLOCK_ACTION)
		CursorController.Release(TOKEN)
		InputController.PopContext(TOKEN)
		local current = view
		local selected = GuiService.SelectedObject
		if current and selected and selected:IsDescendantOf(current.gui) then
			GuiService.SelectedObject = nil
		end
		busyChanged:Fire(false)
	end
end

local function hideHud()
	if HUD.IsVisible() then
		hudHidden = true
		HUD.SetVisible(false)
	end
end

local function restoreHud()
	if hudHidden then
		hudHidden = false
		HUD.SetVisible(true)
	end
end

local function cameraFrame(): CFrame
	local origin = WorldConfig.levelOrigin("Lobby")
	local eye, look =
		OnboardingController.drift(TutorialConfig.TitleDrift, clock, TutorialConfig.Timing.TitleDriftPeriod)
	return CFrame.lookAt(origin + eye, origin + look)
end

local function holdCamera(on: boolean)
	if on == cameraHeld then
		return
	end
	cameraHeld = on
	if on then
		FirstPersonController.PushOverride("Cutscene", {
			cframe = cameraFrame,
			fov = CAMERA_FOV,
			blendIn = 0.05,
			blendOut = CAMERA_BLEND_OUT,
		})
	else
		FirstPersonController.PopOverride("Cutscene")
	end
end

local function renderPage()
	local current = view
	if not current then
		return
	end
	local walk = current.walk
	local count = #TutorialConfig.Pages
	local entry = TutorialConfig.Pages[page]
	if not entry then
		return
	end
	local device = InputController.GetDevice()
	renderedDevice = device
	walk.counter.Text = Strings.get("Tutorial.Page", page, count)
	walk.title.Text = Strings.get(entry.title)
	walk.body.Text = OnboardingController.bodyText(entry, device)
	for id, art in walk.arts do
		art.Visible = id == entry.id
	end
	for index, pip in walk.dots do
		pip.BackgroundColor3 = if index == page
			then Palette.Amber
			elseif index < page then Palette.Ash
			else Palette.Smoke
		pip.Size = if index == page then UDim2.fromOffset(18, 8) else UDim2.fromOffset(8, 8)
	end
	walk.back.button.Visible = page > 1
	walk.back.button.Selectable = page > 1
	walk.nextButton.button.Text = Strings.get(OnboardingController.primaryKey(page, count))
	if entry.art == "Controls" then
		for index, row in OnboardingController.controlRows(device) do
			local cap = walk.controlCaps[index]
			local label = walk.controlLabels[index]
			if cap and label then
				cap:SetGlyph(row.glyph)
				label.Text = row.label
			end
		end
	end
end

local function closeAll()
	mode = "Hidden"
	ContextActionService:UnbindAction(PAGE_ACTION)
	holdCamera(false)
	hold(false)
	restoreHud()
end

local function onPageKey(_action: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin or mode ~= "Walkthrough" then
		return Enum.ContextActionResult.Sink
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.ButtonB then
		OnboardingController.FinishWalkthrough()
	elseif PREV_KEYS[key] then
		OnboardingController.Turn(-1)
	elseif NEXT_KEYS[key] then
		OnboardingController.Turn(1)
	end
	return Enum.ContextActionResult.Sink
end

local function openTitle()
	local current = view
	if not current or mode ~= "Hidden" then
		return
	end
	mode = "Title"
	titleShown = true
	hideHud()
	hold(true)
	holdCamera(true)
	selectFor(current.title.play.button)
end

local function enterWalkthrough(from: Mode)
	local current = view
	if not current then
		return
	end
	returnTo = from
	mode = "Walkthrough"
	page = 1
	hideHud()
	hold(true)
	ContextActionService:UnbindAction(PAGE_ACTION)
	ContextActionService:BindActionAtPriority(
		PAGE_ACTION,
		onPageKey,
		false,
		InputConfig.ActionPriority + 2,
		Enum.KeyCode.Left,
		Enum.KeyCode.Right,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight,
		Enum.KeyCode.ButtonL1,
		Enum.KeyCode.ButtonR1,
		Enum.KeyCode.Return,
		Enum.KeyCode.KeypadEnter,
		Enum.KeyCode.ButtonB
	)
	renderPage()
	selectFor(current.walk.nextButton.button)
	play("UiConfirm")
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function OnboardingController.IsBusy(): boolean
	return isBusy()
end

function OnboardingController.GetMode(): Mode
	return mode
end

-- Replays the walkthrough from the lobby (no-op while a screen is already up or for a player in a run).
function OnboardingController.OpenWalkthrough()
	local player = localPlayer
	if mode ~= "Hidden" or not player or not OnboardingController.titleAllowed(player:GetAttribute(P.LifeState)) then
		return
	end
	enterWalkthrough("Hidden")
end

-- Moves the walkthrough `delta` pages; past the last page it finishes.
function OnboardingController.Turn(delta: number)
	if mode ~= "Walkthrough" then
		return
	end
	local count = #TutorialConfig.Pages
	if delta > 0 and page >= count then
		OnboardingController.FinishWalkthrough()
		return
	end
	local nextPage = OnboardingController.stepPage(page, delta, count)
	if nextPage ~= page then
		page = nextPage
		play("UiClick")
		renderPage()
	end
	local current = view
	if current then
		local selected = GuiService.SelectedObject
		if selected == nil or not selected.Visible then
			selectFor(current.walk.nextButton.button)
		end
	end
end

-- Ends the walkthrough (finished or skipped: either way it is remembered) and returns to where it was opened.
function OnboardingController.FinishWalkthrough()
	if mode ~= "Walkthrough" then
		return
	end
	SettingsController.Set(TutorialConfig.TutorialSetting, true)
	ContextActionService:UnbindAction(PAGE_ACTION)
	play("UiBack")
	if returnTo == "Title" then
		mode = "Title"
		local current = view
		if current then
			selectFor(current.title.howTo.button)
		end
	else
		closeAll()
	end
end

local function pressPlay()
	if mode ~= "Title" then
		return
	end
	play("UiConfirm")
	holdCamera(false)
	if OnboardingController.afterPlay(SettingsController.GetBool(TutorialConfig.TutorialSetting)) == "Walkthrough" then
		enterWalkthrough("Hidden")
	else
		closeAll()
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function curtainUp(): boolean
	local player = localPlayer
	local gui = if player then player:FindFirstChildOfClass("PlayerGui") else nil
	return gui ~= nil and gui:FindFirstChild(CURTAIN_NAME) ~= nil
end

local function fitScale(width: number, height: number): number
	local camera = Workspace.CurrentCamera
	if not camera then
		return 1
	end
	local viewport = camera.ViewportSize
	local base = UIKit.scaleFor(viewport)
	return math.min(base, viewport.X * 0.94 / width, viewport.Y * 0.9 / height)
end

local function step(dt: number)
	local current = view
	if not current then
		return
	end
	clock += dt
	local player = localPlayer
	local lifeState = if player then player:GetAttribute(P.LifeState) else nil
	if mode ~= "Hidden" and not OnboardingController.titleAllowed(lifeState) then
		closeAll()
	end
	if mode ~= "Hidden" and HUD.IsVisible() then
		hideHud()
	end

	local covered = curtainUp()
	local titleUp = mode == "Title" or (mode == "Walkthrough" and returnTo == "Title")
	local titleTarget = if titleUp and not covered then 1 else 0
	titleAlpha = MathUtil.approach(
		titleAlpha,
		titleTarget,
		dt * (if titleTarget > titleAlpha then TITLE_FADE_IN else TITLE_FADE_OUT)
	)
	local walkTarget = if mode == "Walkthrough" then 1 else 0
	walkAlpha = MathUtil.approach(walkAlpha, walkTarget, dt * WALK_FADE)

	local active = titleAlpha > 0.001 or walkAlpha > 0.001 or mode ~= "Hidden"
	current.gui.Enabled = active
	current.backdropGui.Enabled = active

	local title = current.title
	current.shade.GroupTransparency = 1 - titleAlpha
	current.dim.BackgroundTransparency = UIKit.fade(0.35, walkAlpha)
	title.group.GroupTransparency = 1 - titleAlpha * (1 - walkAlpha)
	title.group.Visible = titleAlpha > 0.001
	title.scale.Scale = fitScale(TITLE_WIDTH + 80, TITLE_HEIGHT)

	if title.group.Visible then
		-- A failing bulb: the mark dips now and then.
		local flicker = MathUtil.noise1(clock * 2.6, FLICKER_SEED)
		local dip = if flicker > 0.78 then 0.5 else 0
		title.mark.TextTransparency = dip
		title.shadow.TextTransparency = 0.25 + dip * 0.5
		local credits = if player then player:GetAttribute(P.Credits) else nil
		local escapes = if player then player:GetAttribute(P.Escapes) else nil
		local loaded = player ~= nil and player:GetAttribute(P.DataLoaded) == true
		title.stats.Text = OnboardingController.statsText(
			if loaded then credits else nil,
			if loaded then (if type(escapes) == "number" then escapes else 0) else nil
		)
		title.firstTime.Visible = not SettingsController.GetBool(TutorialConfig.TutorialSetting)
		local phase = ReplicatedStorage:GetAttribute(Attributes.Match.MatchPhase)
		title.underway.Visible = phase == "InRun" or phase == "Deploying"
	end

	local walk = current.walk
	walk.group.Visible = walkAlpha > 0.001
	walk.group.GroupTransparency = 1 - walkAlpha
	walk.scale.Scale = fitScale(SHEET_WIDTH + 40, SHEET_HEIGHT + 40)
	if mode == "Walkthrough" and renderedDevice ~= InputController.GetDevice() then
		renderPage()
	end

	local selected = GuiService.SelectedObject
	for _, entry in current.buttons do
		local lit = entry.hovered or selected == entry.button
		entry.stroke.Color = if lit or entry.primary then Palette.Amber else Palette.StrokeDim
		entry.stroke.Thickness = if lit then 2 else if entry.primary then 1.5 else 1
		entry.button.BackgroundColor3 = if lit
			then Palette.Track
			elseif entry.primary then Palette.Raised
			else Palette.Panel
	end
	-- A gamepad that lost its selection (the settings menu closed over the title) gets it back.
	if InputController.GetDevice() == "Gamepad" and selected == nil then
		if mode == "Title" and titleAlpha > 0.5 then
			GuiService.SelectedObject = title.play.button
		elseif mode == "Walkthrough" and walkAlpha > 0.5 then
			GuiService.SelectedObject = walk.nextButton.button
		end
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function OnboardingController.Init() end

function OnboardingController.Start()
	local player = localPlayer
	if not player then
		return
	end
	local gui = player:WaitForChild("PlayerGui")
	local ok = xpcall(function()
		view = build(gui)
	end, function(err: any)
		log.error("onboarding failed to mount: %s\n%s", tostring(err), debug.traceback())
	end)
	local current = view
	if not ok or not current then
		return
	end
	serviceTrove:Add(current.gui)
	serviceTrove:Add(current.backdropGui)

	serviceTrove:Connect(current.title.play.button.Activated, pressPlay)
	serviceTrove:Connect(current.title.howTo.button.Activated, function()
		if mode == "Title" then
			enterWalkthrough("Title")
		end
	end)
	serviceTrove:Connect(current.title.settings.button.Activated, function()
		if mode == "Title" then
			play("UiClick")
			HUD.OpenSettings()
		end
	end)
	serviceTrove:Connect(current.walk.back.button.Activated, function()
		OnboardingController.Turn(-1)
	end)
	serviceTrove:Connect(current.walk.nextButton.button.Activated, function()
		OnboardingController.Turn(1)
	end)
	serviceTrove:Connect(current.walk.skip.button.Activated, function()
		OnboardingController.FinishWalkthrough()
	end)
	serviceTrove:Add(InputController.DeviceChanged:Connect(function()
		local now = view
		if not now then
			return
		end
		if mode == "Title" then
			selectFor(now.title.play.button)
		elseif mode == "Walkthrough" then
			renderPage()
			selectFor(now.walk.nextButton.button)
		end
	end))
	serviceTrove:Connect(RunService.PreRender, function(dt: number)
		xpcall(step, function(err: any)
			log.warnThrottled("step", 10, "onboarding step failed: %s\n%s", tostring(err), debug.traceback())
		end, dt)
	end)

	if not titleShown and OnboardingController.titleAllowed(player:GetAttribute(P.LifeState)) then
		openTitle()
	end
end

function OnboardingController.OnRunStarted(_info: Types.RunInfo) end

function OnboardingController.OnRunEnded() end

return table.freeze(OnboardingController)
