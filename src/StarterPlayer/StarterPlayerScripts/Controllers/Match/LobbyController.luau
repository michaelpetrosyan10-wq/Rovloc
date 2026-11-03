--!strict
-- LobbyController: the lobby on this client (spec §1). LobbyService and PerkShopService (server) run the lobby; this
-- controller only reads what they replicate and sends intents.
--
--   * Lobby HUD, shown while the match is in Lobby / Countdown and this player is in the lobby (LifeState Lobby):
--       - a banner top-centre: "Waiting for the squad (2 / 3 ready)", or the countdown to ReplicatedStorage
--         CountdownEndsAt (server time, extrapolated every frame) with a draining bar, a click on every second and a
--         confirm / back sound when it starts / stops;
--       - the squad panel on the left: the next run's squad (LobbySquad, slot order) with a READY / NOT READY tag
--         and each member's difficulty vote, the difficulty the votes pick (LobbyDifficulty), this player's credits
--         (Player.Credits), and below it the players waiting for the next run (over the cap) or still loading;
--       - a device-aware hint at the bottom (step onto a pad, or press R / Y / tap READY UP), and on touch a READY UP /
--         STAND DOWN button. R (keyboard) and Y (gamepad) toggle Ready through LobbyAction while the lobby HUD shows
--         and no console screen is open (they sink the in-run Kick binding, which has nothing to kick here).
--   * Ready pads: every pad's Neon lamp band is lit from its OccupantUserId: moss when the occupant is Ready, ember
--     when they cannot ready (waiting / loading), the builder's dim amber when free.
--   * Consoles. PrivateCue "Terminal" { terminal } (the server accepted this player's terminal prompt) opens that
--     console's screen: the "Menu" input context, a free cursor and no prompts while it is open; gamepad selection
--     starts on its first control and B closes it; it closes on Close, when the player walks out of reach
--     (CLOSE_DISTANCE from the screen, inside the server's reach) or the lobby ends.
--       - Difficulty: Standard and Nightmare cards (what Nightmare changes, from DifficultyConfig), each card's
--         squad votes and this player's vote; selecting a card sends LobbyAction VoteDifficulty.
--       - Loadout: credits, then one row per perk (name, description, cost, owned stock from Player.PerkStock,
--         EQUIPPED), Buy (PerkPurchase, one request in flight per perk; the reply's reason is shown on the screen)
--         and Equip / Unequip (LobbyAction).
-- The camera stays the normal first-person view (FirstPersonController owns it in the lobby too).
--
-- Pure (tests/Specs/Lobby.spec.luau): parseSquad, hintState, hintKey, statusText, voteCounts, nightmareLines, shopRow,
-- lampColor, visible, inReach, secondCrossed.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LobbyBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LobbyBuilder)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local PerkConfig = require(ReplicatedStorage.Shared.Config.PerkConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local CursorController = require(Controllers.Core.CursorController)
local InputController = require(Controllers.Core.InputController)
local HUD = require(Controllers.HUD)
local UIKit = require(Controllers.HUD.UIKit)

local log = Log.new("LobbyClient")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World
local Palette = UIKit.Palette

export type HintState = "Loading" | "ReadyUp" | "Ready" | "Full"

export type ShopRow = {
	buyEnabled: boolean,
	buyText: string,
	ownedText: string,
	costText: string,
	equipEnabled: boolean,
	equipText: string,
	equipped: boolean,
}

type SquadRow = { frame: Frame, name: TextLabel, status: TextLabel, vote: TextLabel }

type DifficultyCard = {
	difficulty: Enums.Difficulty,
	button: TextButton,
	stroke: UIStroke,
	votes: TextLabel,
	mine: TextLabel,
}

type PerkRow = {
	perk: Enums.PerkId,
	owned: TextLabel,
	cost: TextLabel,
	equippedTag: TextLabel,
	buy: TextButton,
	equip: TextButton,
}

type Screen = {
	gui: ScreenGui,
	backdrop: Frame,
	panel: Frame,
	scale: UIScale,
	title: TextLabel,
	difficulty: Frame,
	shop: Frame,
	cards: { DifficultyCard },
	result: TextLabel,
	credits: TextLabel,
	rows: { PerkRow },
	status: TextLabel,
	close: TextButton,
}

type View = {
	gui: ScreenGui,
	layer: Frame,
	scale: UIScale,
	root: Frame,
	groups: { CanvasGroup },
	bannerLabel: TextLabel,
	bar: UIKit.MeterBar,
	difficultyLine: TextLabel,
	creditsLine: TextLabel,
	waitingList: Frame,
	waitingTitle: TextLabel,
	squadRows: { SquadRow },
	waitingRows: { SquadRow },
	hint: TextLabel,
	readyButton: UIKit.RoundButton,
	readyLabel: TextLabel,
	screen: Screen,
}

local LOBBY_ORDER = 21 -- above the HUD (20), under the airlock banner (22)
local SCREEN_ORDER = 40 -- under the settings menu (60)
local TOKEN = "LobbyTerminal"
local READY_ACTION = "Rovloc.LobbyReady"
local CLOSE_ACTION = "Rovloc.LobbyTerminalClose"
local READY_KEYS: { Enum.KeyCode } = { Enum.KeyCode.R, Enum.KeyCode.ButtonY }
local CLOSE_DISTANCE = LobbyBuilder.TerminalPromptDistance + 4 -- the server keeps accepting up to +6
local FADE_IN = 5
local FADE_OUT = 3
local LAMP_INTERVAL = 0.2
local PANEL_WIDTH = 260
local ROW_HEIGHT = 26
local BANNER_WIDTH = 440
local BANNER_TOP = 0.13
local SCREEN_MAX = Vector2.new(560, 640)
local READY_BUTTON_SIZE = 96
local LAMP_READY = Palette.Moss
local LAMP_BLOCKED = Palette.Ember
local LOBBY_STATE: Enums.LifeState = "Lobby"
local LOBBY_PHASES: { [string]: boolean } = { Lobby = true, Countdown = true }

local LobbyController = {}

LobbyController.Name = "LobbyController"
LobbyController.CloseDistance = CLOSE_DISTANCE

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local view: View? = nil
local alpha = 0
local lampClock = 0
local readyBound = false
local openTerminal: string? = nil
local terminalPosition: Vector3? = nil
local screenAlpha = 0
local lastRemaining: number? = nil
local wasCounting = false
local buying: { [string]: boolean } = {}
local shopStatus = ""

--------------------------------------------------------------------------------
-- Pure (specs: tests/Specs/Lobby.spec.luau)
--------------------------------------------------------------------------------

-- ReplicatedStorage.LobbySquad ("123,456") into UserIds, in slot order.
function LobbyController.parseSquad(value: unknown): { number }
	local out: { number } = {}
	if type(value) ~= "string" then
		return out
	end
	for entry in string.gmatch(value, "[^,]+") do
		local id = tonumber(entry)
		if id and id == math.floor(id) then
			table.insert(out, id)
		end
	end
	return out
end

-- Which hint this player reads.
function LobbyController.hintState(loaded: boolean, inSquad: boolean, ready: boolean): HintState
	if not loaded then
		return "Loading"
	elseif not inSquad then
		return "Full"
	end
	return if ready then "Ready" else "ReadyUp"
end

-- The Strings key of a hint for an input device ("KeyboardMouse" | "Gamepad" | "Touch").
function LobbyController.hintKey(state: HintState, device: string): string
	if state == "Loading" then
		return "Lobby.Hint.Loading"
	elseif state == "Full" then
		return "Lobby.Hint.Full"
	end
	local suffix = if device == "Gamepad" or device == "Touch" then device else "KeyboardMouse"
	return string.format("Lobby.Hint.%s.%s", state, suffix)
end

-- The banner's line, and the countdown bar's fraction while counting down (nil otherwise).
function LobbyController.statusText(
	endsAt: number?,
	now: number,
	readyCount: number,
	squadCount: number
): (string, number?)
	if endsAt ~= nil and MathUtil.isFinite(endsAt) then
		local remaining = math.max(0, endsAt - now)
		local fraction = math.clamp(remaining / math.max(GameConfig.CountdownSeconds, 1e-3), 0, 1)
		return Strings.get("Lobby.Countdown", math.ceil(remaining)), fraction
	end
	return Strings.get("Lobby.WaitingForSquad", readyCount, math.max(squadCount, GameConfig.MinSquad)), nil
end

-- Standard and Nightmare vote counts.
function LobbyController.voteCounts(votes: { string }): (number, number)
	local standard, nightmare = 0, 0
	for _, vote in votes do
		if vote == "Standard" then
			standard += 1
		elseif vote == "Nightmare" then
			nightmare += 1
		end
	end
	return standard, nightmare
end

-- What Nightmare changes, line by line, from DifficultyConfig.
function LobbyController.nightmareLines(): { string }
	local standard = DifficultyConfig.Standard
	local nightmare = DifficultyConfig.Nightmare
	local function percent(multiplier: number): number
		return math.round((multiplier - 1) * 100)
	end
	return {
		Strings.get(
			"Lobby.Nightmare.Speed",
			percent(nightmare.creatureSpeedMultiplier),
			percent(nightmare.hearingMultiplier)
		),
		Strings.get("Lobby.Nightmare.Traps", nightmare.trapCount, standard.trapCount),
		Strings.get("Lobby.Nightmare.Batteries", nightmare.batteriesPerLevel, standard.batteriesPerLevel),
		Strings.get(
			"Lobby.Nightmare.Grates",
			math.round(nightmare.lockedGrateFraction * 100),
			math.round(standard.lockedGrateFraction * 100)
		),
		Strings.get("Lobby.Nightmare.Credits", nightmare.creditMultiplier),
	}
end

-- One perk row of the shop for a player with `credits`, `stock` owned and the perk `equipped` or not.
function LobbyController.shopRow(perk: string, credits: number, stock: number, equipped: boolean): ShopRow
	local spec = PerkConfig.get(perk)
	local cost = if spec then spec.cost else 0
	return {
		buyEnabled = spec ~= nil and credits >= cost and stock < PerkConfig.MaxStock,
		buyText = Strings.get("Lobby.Buy", cost),
		ownedText = Strings.get("Lobby.Owned", stock),
		costText = Strings.get("Lobby.Credits", cost),
		equipEnabled = equipped or stock >= 1,
		equipText = Strings.get(if equipped then "Lobby.Unequip" else "Lobby.Equip"),
		equipped = equipped,
	}
end

-- A pad lamp's colour: free, an occupant who is Ready, or one who cannot ready.
function LobbyController.lampColor(occupied: boolean, ready: boolean): Color3
	if not occupied then
		return LobbyBuilder.PadLampIdle
	end
	return if ready then LAMP_READY else LAMP_BLOCKED
end

-- Whether the lobby HUD shows for a match phase and this player's life state.
function LobbyController.visible(phase: unknown, lifeState: unknown): boolean
	return type(phase) == "string" and LOBBY_PHASES[phase] == true and (lifeState == nil or lifeState == LOBBY_STATE)
end

-- Whether a console screen may stay open `distance` studs from its screen (nil: no body).
function LobbyController.inReach(distance: number?): boolean
	return distance ~= nil and distance <= CLOSE_DISTANCE
end

-- Whether the countdown crossed a whole second between two remaining-time samples.
function LobbyController.secondCrossed(before: number?, after: number): boolean
	if before == nil then
		return false
	end
	return math.ceil(after) < math.ceil(before) and after > 0
end

--------------------------------------------------------------------------------
-- Reads
--------------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function phaseNow(): unknown
	return ReplicatedStorage:GetAttribute(M.MatchPhase)
end

local function lobbyShown(): boolean
	local player = localPlayer
	local lifeState = if player then player:GetAttribute(P.LifeState) else nil
	return HUD.IsVisible() and LobbyController.visible(phaseNow(), lifeState)
end

local function squadPlayers(): { Player }
	local out: { Player } = {}
	for _, id in LobbyController.parseSquad(ReplicatedStorage:GetAttribute(M.LobbySquad)) do
		local player = Players:GetPlayerByUserId(id)
		if player then
			table.insert(out, player)
		end
	end
	return out
end

local function displayName(player: Player): string
	local name = if player.DisplayName ~= "" then player.DisplayName else player.Name
	return if player == localPlayer then Strings.get("Lobby.You", name) else name
end

local function difficultyName(value: unknown): string
	local difficulty = if Enums.has(Enums.Difficulty, value) then value :: string else "Standard"
	return Strings.get("Lobby.Difficulty." .. difficulty)
end

local function localStock(): { [string]: number }
	local player = localPlayer
	return if player then PerkConfig.decodeStock(player:GetAttribute(P.PerkStock)) else {}
end

local function localLoadout(): { Enums.PerkId }
	local player = localPlayer
	return if player then PerkConfig.parseLoadout(player:GetAttribute(P.Loadout)) else {}
end

local function localCredits(): number
	local player = localPlayer
	return if player then math.floor(Attributes.getNumber(player, P.Credits, 0)) else 0
end

local function setText(label: TextLabel, text: string)
	if label.Text ~= text then
		label.Text = text
	end
end

local function setButtonText(button: TextButton, text: string)
	if button.Text ~= text then
		button.Text = text
	end
end

local function play(preset: string)
	xpcall(function()
		AudioController.PlayLocal(preset)
	end, function(err: any)
		log.warnThrottled("sound", 60, "ui sound failed: %s", tostring(err))
	end)
end

local function sendAction(payload: Types.LobbyActionPayload)
	Net.Client.fire("LobbyAction", payload)
end

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

local function textButton(parent: Instance, name: string, height: number, highlight: Frame): (TextButton, UIStroke)
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = UDim2.new(1, 0, 0, height)
	button.BackgroundColor3 = Palette.Raised
	button.BackgroundTransparency = 0.1
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.FontFace = UIKit.Fonts.Strong
	button.TextSize = UIKit.TextSize.Body
	button.TextColor3 = Palette.Bone
	button.Text = ""
	button.Selectable = true
	button.SelectionImageObject = highlight
	button.Parent = parent
	UIKit.corner(button, UDim.new(0, 6))
	local stroke = UIKit.stroke(button, Palette.StrokeDim, 1, 0)
	return button, stroke
end

local function setEnabled(button: TextButton, enabled: boolean)
	if button.Active ~= enabled then
		button.Active = enabled
		button.Selectable = enabled
		button.TextTransparency = if enabled then 0 else 0.55
		button.BackgroundTransparency = if enabled then 0.1 else 0.5
	end
end

local function squadRow(parent: Instance, order: number): SquadRow
	local frame = UIKit.frame(parent, "Row" .. order)
	frame.LayoutOrder = order
	frame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	local name = UIKit.label(frame, "Name", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Bone)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.TextWrapped = false
	name.Size = UDim2.new(0.5, -4, 1, 0)
	local vote = UIKit.label(frame, "Vote", UIKit.Fonts.Body, UIKit.TextSize.Caps, Palette.Ash)
	vote.TextXAlignment = Enum.TextXAlignment.Right
	vote.TextWrapped = false
	vote.Position = UDim2.fromScale(0.5, 0)
	vote.Size = UDim2.new(0.22, 0, 1, 0)
	local status = UIKit.label(frame, "Status", UIKit.Fonts.Heavy, UIKit.TextSize.Caps, Palette.Ash)
	status.TextXAlignment = Enum.TextXAlignment.Right
	status.TextWrapped = false
	status.AnchorPoint = Vector2.new(1, 0)
	status.Position = UDim2.fromScale(1, 0)
	status.Size = UDim2.new(0.28, 0, 1, 0)
	frame.Visible = false
	return { frame = frame, name = name, status = status, vote = vote }
end

local function buildDifficulty(parent: Instance, highlight: Frame): (Frame, { DifficultyCard }, TextLabel)
	local content = UIKit.frame(parent, "Difficulty")
	content.Size = UDim2.fromScale(1, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.list(content, Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	local cards: { DifficultyCard } = {}
	for index, difficulty: Enums.Difficulty in Enums.Difficulty do
		local button, stroke = textButton(content, difficulty, 0, highlight)
		button.LayoutOrder = index
		button.AutomaticSize = Enum.AutomaticSize.Y
		button.TextXAlignment = Enum.TextXAlignment.Left
		UIKit.padding(button, 14, 10)
		UIKit.list(button, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)
		local name = UIKit.label(button, "Name", UIKit.Fonts.Title, UIKit.TextSize.Title, Palette.Bone)
		name.LayoutOrder = 1
		name.Size = UDim2.new(1, 0, 0, 30)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Text = Strings.get("Lobby.Difficulty." .. difficulty)
		local lines: { string } = if difficulty == "Nightmare"
			then { Strings.get("Lobby.Difficulty.NightmareHint"), table.unpack(LobbyController.nightmareLines()) }
			else { Strings.get("Lobby.Difficulty.StandardHint") }
		for lineIndex, text in lines do
			local color = if lineIndex == 1 then Palette.Bone else Palette.Ash
			local line = UIKit.label(button, "Line" .. lineIndex, UIKit.Fonts.Body, UIKit.TextSize.Small, color)
			line.LayoutOrder = 1 + lineIndex
			line.Size = UDim2.fromScale(1, 0)
			line.AutomaticSize = Enum.AutomaticSize.Y
			line.TextXAlignment = Enum.TextXAlignment.Left
			line.Text = text
		end
		local footer = UIKit.frame(button, "Footer")
		footer.LayoutOrder = 100
		footer.Size = UDim2.new(1, 0, 0, 20)
		local votes = UIKit.label(footer, "Votes", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Ash)
		votes.TextXAlignment = Enum.TextXAlignment.Left
		votes.Size = UDim2.fromScale(0.5, 1)
		local mine = UIKit.label(footer, "Mine", UIKit.Fonts.Heavy, UIKit.TextSize.Caps, Palette.Amber)
		mine.TextXAlignment = Enum.TextXAlignment.Right
		mine.AnchorPoint = Vector2.new(1, 0)
		mine.Position = UDim2.fromScale(1, 0)
		mine.Size = UDim2.fromScale(0.5, 1)
		mine.Text = Strings.get("Lobby.YourVote")
		table.insert(cards, { difficulty = difficulty, button = button, stroke = stroke, votes = votes, mine = mine })
	end
	local rule = UIKit.label(content, "Rule", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Ash)
	rule.LayoutOrder = 50
	rule.Size = UDim2.fromScale(1, 0)
	rule.AutomaticSize = Enum.AutomaticSize.Y
	rule.Text = Strings.get("Lobby.VoteRule")
	local result = UIKit.label(content, "Result", UIKit.Fonts.Strong, UIKit.TextSize.Body, Palette.Amber)
	result.LayoutOrder = 51
	result.Size = UDim2.new(1, 0, 0, 22)
	return content, cards, result
end

local function buildShop(parent: Instance, highlight: Frame): (Frame, { PerkRow }, TextLabel, TextLabel)
	local content = UIKit.frame(parent, "Shop")
	content.Size = UDim2.fromScale(1, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.list(content, Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	local credits = UIKit.label(content, "Credits", UIKit.Fonts.Strong, UIKit.TextSize.Hint, Palette.Amber)
	credits.LayoutOrder = 0
	credits.Size = UDim2.new(1, 0, 0, 26)
	credits.TextXAlignment = Enum.TextXAlignment.Left
	local rows: { PerkRow } = {}
	for index, perk: Enums.PerkId in Enums.PerkId do
		local card = UIKit.fill(content, perk, Palette.Raised, 0.25)
		card.LayoutOrder = index
		card.Size = UDim2.fromScale(1, 0)
		card.AutomaticSize = Enum.AutomaticSize.Y
		UIKit.corner(card, UDim.new(0, 6))
		UIKit.stroke(card, Palette.StrokeDim, 1, 0)
		UIKit.padding(card, 14, 10)
		UIKit.list(card, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)
		local header = UIKit.frame(card, "Header")
		header.LayoutOrder = 1
		header.Size = UDim2.new(1, 0, 0, 24)
		local name = UIKit.label(header, "Name", UIKit.Fonts.Strong, UIKit.TextSize.Hint, Palette.Bone)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextWrapped = false
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Size = UDim2.fromScale(0.7, 1)
		name.Text = Strings.get("Perk." .. perk)
		local equippedTag = UIKit.label(header, "Equipped", UIKit.Fonts.Heavy, UIKit.TextSize.Caps, Palette.Moss)
		equippedTag.TextXAlignment = Enum.TextXAlignment.Right
		equippedTag.AnchorPoint = Vector2.new(1, 0)
		equippedTag.Position = UDim2.fromScale(1, 0)
		equippedTag.Size = UDim2.fromScale(0.3, 1)
		equippedTag.Text = Strings.get("Lobby.Equipped")
		local description = UIKit.label(card, "Description", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Ash)
		description.LayoutOrder = 2
		description.Size = UDim2.fromScale(1, 0)
		description.AutomaticSize = Enum.AutomaticSize.Y
		description.TextXAlignment = Enum.TextXAlignment.Left
		description.Text = Strings.get("Perk." .. perk .. ".Desc")
		local facts = UIKit.frame(card, "Facts")
		facts.LayoutOrder = 3
		facts.Size = UDim2.new(1, 0, 0, 20)
		local owned = UIKit.label(facts, "Owned", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Bone)
		owned.TextXAlignment = Enum.TextXAlignment.Left
		owned.Size = UDim2.fromScale(0.5, 1)
		local cost = UIKit.label(facts, "Cost", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Amber)
		cost.TextXAlignment = Enum.TextXAlignment.Right
		cost.AnchorPoint = Vector2.new(1, 0)
		cost.Position = UDim2.fromScale(1, 0)
		cost.Size = UDim2.fromScale(0.5, 1)
		local buttons = UIKit.frame(card, "Buttons")
		buttons.LayoutOrder = 4
		buttons.Size = UDim2.new(1, 0, 0, UIKit.MinTouchTarget)
		local buy = textButton(buttons, "Buy", UIKit.MinTouchTarget, highlight)
		buy.Size = UDim2.new(0.5, -5, 1, 0)
		local equip = textButton(buttons, "Equip", UIKit.MinTouchTarget, highlight)
		buy.NextSelectionRight = equip
		equip.NextSelectionLeft = buy
		equip.AnchorPoint = Vector2.new(1, 0)
		equip.Position = UDim2.fromScale(1, 0)
		equip.Size = UDim2.new(0.5, -5, 1, 0)
		table.insert(rows, {
			perk = perk,
			owned = owned,
			cost = cost,
			equippedTag = equippedTag,
			buy = buy,
			equip = equip,
		})
	end
	local hint = UIKit.label(content, "EquipHint", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Ash)
	hint.LayoutOrder = 50
	hint.Size = UDim2.fromScale(1, 0)
	hint.AutomaticSize = Enum.AutomaticSize.Y
	hint.Text = Strings.get("Lobby.EquipHint")
	local status = UIKit.label(content, "Status", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Bone)
	status.LayoutOrder = 51
	status.Size = UDim2.new(1, 0, 0, 20)
	return content, rows, credits, status
end

local function buildScreen(parent: Instance): Screen
	local gui = UIKit.screenGui("LobbyTerminal", SCREEN_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	gui.Enabled = false
	local backdrop = UIKit.fill(gui, "Backdrop", Palette.Ink, 1)
	backdrop.Active = true
	UIKit.gradient(backdrop, 90, { { 0, 0.2 }, { 0.5, 0.4 }, { 1, 0.15 } })
	local panel = UIKit.panel(backdrop, "Panel", 0.06, 4417)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.92, 0.9)
	UIKit.sizeLimit(panel, Vector2.new(280, 240), SCREEN_MAX)
	local scale = Instance.new("UIScale")
	scale.Parent = panel

	local title = UIKit.label(panel, "Title", UIKit.Fonts.Title, UIKit.TextSize.Title, Palette.Bone)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextWrapped = false
	title.Position = UDim2.fromOffset(22, 14)
	title.Size = UDim2.new(1, -44, 0, 34)
	local rule = UIKit.fill(panel, "Rule", Palette.Blood, 0.1)
	rule.Position = UDim2.fromOffset(22, 52)
	rule.Size = UDim2.new(0, 64, 0, 2)
	UIKit.gradient(rule, 0, { { 0, 0 }, { 1, 1 } })

	local body = Instance.new("ScrollingFrame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.Position = UDim2.fromOffset(12, 64)
	body.Size = UDim2.new(1, -24, 1, -64 - 76)
	body.CanvasSize = UDim2.fromScale(0, 0)
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.ScrollingDirection = Enum.ScrollingDirection.Y
	body.ScrollBarThickness = 3
	body.ScrollBarImageColor3 = Palette.Stroke
	body.ScrollBarImageTransparency = 0.3
	body.Selectable = false
	body.Parent = panel
	UIKit.padding(body, 10, 4)

	local highlight = UIKit.frame(nil, "Selection")
	UIKit.corner(highlight, UDim.new(0, 6))
	UIKit.stroke(highlight, Palette.Amber, 1.5, 0.15)
	serviceTrove:Add(highlight)

	local difficulty, cards, result = buildDifficulty(body, highlight)
	local shop, rows, credits, status = buildShop(body, highlight)

	local close = textButton(panel, "Close", 48, highlight)
	close.AnchorPoint = Vector2.new(0.5, 1)
	close.Position = UDim2.new(0.5, 0, 1, -16)
	close.Size = UDim2.new(1, -44, 0, 48)
	close.Text = Strings.get("Lobby.Close")

	gui.Parent = parent
	return {
		gui = gui,
		backdrop = backdrop,
		panel = panel,
		scale = scale,
		title = title,
		difficulty = difficulty,
		shop = shop,
		cards = cards,
		result = result,
		credits = credits,
		rows = rows,
		status = status,
		close = close,
	}
end

local function build(parent: Instance): View
	local gui = UIKit.screenGui("Lobby", LOBBY_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	local layer = UIKit.frame(gui, "Layer")
	local scale = Instance.new("UIScale")
	scale.Parent = layer
	local root = UIKit.frame(layer, "Root")
	root.Visible = false

	-- Each panel fades as one group (a group sized to its panel: no full-screen render target).
	local function group(name: string, anchor: Vector2, position: UDim2, width: number): CanvasGroup
		local canvas = Instance.new("CanvasGroup")
		canvas.Name = name
		canvas.BackgroundTransparency = 1
		canvas.BorderSizePixel = 0
		canvas.AnchorPoint = anchor
		canvas.Position = position
		canvas.Size = UDim2.fromOffset(width, 0)
		canvas.AutomaticSize = Enum.AutomaticSize.Y
		canvas.GroupTransparency = 1
		canvas.Parent = root
		return canvas
	end

	-- Banner
	local bannerGroup = group("BannerGroup", Vector2.new(0.5, 0), UDim2.fromScale(0.5, BANNER_TOP), BANNER_WIDTH)
	local banner = UIKit.panel(bannerGroup, "Banner", 0.2, 5503)
	banner.Size = UDim2.fromScale(1, 0)
	banner.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.padding(banner, 20, 12)
	UIKit.list(banner, Enum.FillDirection.Vertical, 9, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top)
	local bannerLabel = UIKit.label(banner, "Text", UIKit.Fonts.Title, UIKit.TextSize.Hint + 2, Palette.Bone)
	bannerLabel.LayoutOrder = 1
	bannerLabel.Size = UDim2.fromScale(1, 0)
	bannerLabel.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.textStroke(bannerLabel, 0.35)
	local bar = UIKit.meterBar(banner, "Timer", Palette.Amber, 4)
	bar.root.LayoutOrder = 2

	-- Squad panel
	local squadGroup = group("SquadGroup", Vector2.new(0, 0.5), UDim2.new(0, 16, 0.42, 0), PANEL_WIDTH)
	local squad = UIKit.panel(squadGroup, "Squad", 0.22, 5519)
	squad.Size = UDim2.fromScale(1, 0)
	squad.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.padding(squad, 14, 10)
	UIKit.list(squad, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)
	local lobbyTitle = UIKit.label(squad, "Title", UIKit.Fonts.Title, UIKit.TextSize.Small, Palette.Ash)
	lobbyTitle.LayoutOrder = 1
	lobbyTitle.Size = UDim2.new(1, 0, 0, 18)
	lobbyTitle.TextXAlignment = Enum.TextXAlignment.Left
	lobbyTitle.Text = Strings.get("Lobby.Title")
	local squadTitle = UIKit.label(squad, "SquadTitle", UIKit.Fonts.Heavy, UIKit.TextSize.Caps, Palette.Bone)
	squadTitle.TextWrapped = false
	squadTitle.LayoutOrder = 2
	squadTitle.Size = UDim2.new(1, 0, 0, 18)
	squadTitle.TextXAlignment = Enum.TextXAlignment.Left
	squadTitle.Text = Strings.get("Lobby.Squad")
	local squadList = UIKit.frame(squad, "List")
	squadList.LayoutOrder = 3
	squadList.Size = UDim2.fromScale(1, 0)
	squadList.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.list(squadList, Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)
	local difficultyLine = UIKit.label(squad, "Difficulty", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Amber)
	difficultyLine.LayoutOrder = 4
	difficultyLine.Size = UDim2.new(1, 0, 0, 22)
	difficultyLine.TextXAlignment = Enum.TextXAlignment.Left
	local creditsLine = UIKit.label(squad, "Credits", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Bone)
	creditsLine.LayoutOrder = 5
	creditsLine.Size = UDim2.new(1, 0, 0, 20)
	creditsLine.TextXAlignment = Enum.TextXAlignment.Left
	local waitingTitle = UIKit.label(squad, "WaitingTitle", UIKit.Fonts.Heavy, UIKit.TextSize.Caps, Palette.Ash)
	waitingTitle.LayoutOrder = 6
	waitingTitle.Size = UDim2.new(1, 0, 0, 18)
	waitingTitle.TextXAlignment = Enum.TextXAlignment.Left
	waitingTitle.Text = Strings.get("Lobby.WaitingList")
	local waitingList = UIKit.frame(squad, "Waiting")
	waitingList.LayoutOrder = 7
	waitingList.Size = UDim2.fromScale(1, 0)
	waitingList.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.list(waitingList, Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)
	local terminals = UIKit.label(squad, "Terminals", UIKit.Fonts.Body, UIKit.TextSize.Caps, Palette.Smoke)
	terminals.LayoutOrder = 8
	terminals.Size = UDim2.fromScale(1, 0)
	terminals.AutomaticSize = Enum.AutomaticSize.Y
	terminals.TextXAlignment = Enum.TextXAlignment.Left
	terminals.Text = Strings.get("Lobby.Hint.Terminals")

	local squadRows: { SquadRow } = {}
	local waitingRows: { SquadRow } = {}
	for index = 1, GameConfig.MaxSquad do
		table.insert(squadRows, squadRow(squadList, index))
	end

	-- Hint + touch button
	local hint = UIKit.label(root, "Hint", UIKit.Fonts.Title, UIKit.TextSize.Hint, Palette.Bone)
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.new(0.5, 0, 1, -64)
	hint.Size = UDim2.new(0.8, 0, 0, 0)
	hint.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.textStroke(hint, 0.3)
	local readyButton = UIKit.roundButton(root, "Ready", Strings.get("Lobby.ReadyButton"), READY_BUTTON_SIZE)
	readyButton.button.Position = UDim2.new(0.5, 0, 1, -170)
	readyButton.button.Visible = false
	local readyLabel = readyButton.button:FindFirstChild("Label")
	assert(readyLabel and readyLabel:IsA("TextLabel"), "UIKit.roundButton has a Label")

	gui.Parent = parent
	local screen = buildScreen(parent)
	return {
		gui = gui,
		layer = layer,
		scale = scale,
		root = root,
		groups = { bannerGroup, squadGroup },
		bannerLabel = bannerLabel,
		bar = bar,
		difficultyLine = difficultyLine,
		creditsLine = creditsLine,
		waitingList = waitingList,
		waitingTitle = waitingTitle,
		squadRows = squadRows,
		waitingRows = waitingRows,
		hint = hint,
		readyButton = readyButton,
		readyLabel = readyLabel,
		screen = screen,
	}
end

--------------------------------------------------------------------------------
-- Ready toggle
--------------------------------------------------------------------------------

local function localReady(): boolean
	local player = localPlayer
	return player ~= nil and Attributes.getBool(player, P.Ready, false)
end

local function toggleReady()
	sendAction({ action = if localReady() then "Unready" else "Ready" })
	play("UiClick")
end

local function onReadyKey(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		toggleReady()
	end
	return Enum.ContextActionResult.Sink
end

local function bindReady(bound: boolean)
	if bound == readyBound then
		return
	end
	readyBound = bound
	if bound then
		ContextActionService:BindActionAtPriority(
			READY_ACTION,
			onReadyKey,
			false,
			InputConfig.ActionPriority + 1,
			table.unpack(READY_KEYS)
		)
	else
		ContextActionService:UnbindAction(READY_ACTION)
	end
end

--------------------------------------------------------------------------------
-- Console screens
--------------------------------------------------------------------------------

local function screenPart(terminalId: string): BasePart?
	local lobby = Instances.lobby()
	local props = if lobby then lobby:FindFirstChild(Instances.Names.Props) else nil
	local model = if props then props:FindFirstChild(LobbyBuilder.terminalName(terminalId)) else nil
	local screen = if model then model:FindFirstChild("Screen") else nil
	return if screen and screen:IsA("BasePart") then screen else nil
end

local function closeScreen(silent: boolean?)
	local current = view
	if openTerminal == nil then
		return
	end
	openTerminal = nil
	terminalPosition = nil
	ContextActionService:UnbindAction(CLOSE_ACTION)
	local selected = GuiService.SelectedObject
	if current and selected and selected:IsDescendantOf(current.screen.gui) then
		GuiService.SelectedObject = nil
	end
	InputController.PopContext(TOKEN)
	CursorController.Release(TOKEN)
	HUD.SetPromptsSuppressed(TOKEN, false)
	if not silent then
		play("UiBack")
	end
end

local function onCloseKey(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		closeScreen()
	end
	return Enum.ContextActionResult.Sink
end

local function firstControl(screen: Screen, terminalId: string): GuiObject?
	if terminalId == LobbyBuilder.Terminals.Difficulty then
		local card = screen.cards[1]
		return if card then card.button else nil
	end
	for _, row in screen.rows do
		if row.buy.Selectable then
			return row.buy
		end
		if row.equip.Selectable then
			return row.equip
		end
	end
	return screen.close
end

local function openScreen(terminalId: string)
	local current = view
	if not current or not lobbyShown() then
		return
	end
	if terminalId ~= LobbyBuilder.Terminals.Difficulty and terminalId ~= LobbyBuilder.Terminals.Perks then
		return
	end
	if openTerminal == terminalId then
		return
	end
	if openTerminal ~= nil then
		closeScreen(true)
	end
	local part = screenPart(terminalId)
	openTerminal = terminalId
	terminalPosition = if part then part.CFrame.Position else nil
	shopStatus = ""
	local screen = current.screen
	local isDifficulty = terminalId == LobbyBuilder.Terminals.Difficulty
	screen.difficulty.Visible = isDifficulty
	screen.shop.Visible = not isDifficulty
	setText(screen.title, Strings.get(if isDifficulty then "Lobby.Difficulty" else "Lobby.PerkShop"))
	screen.gui.Enabled = true
	screen.panel.Visible = true -- selectable from the first frame (the fade only moves it)
	InputController.PushContext("Menu", TOKEN)
	CursorController.RequestFree(TOKEN)
	HUD.SetPromptsSuppressed(TOKEN, true)
	ContextActionService:BindActionAtPriority(
		CLOSE_ACTION,
		onCloseKey,
		false,
		InputConfig.ActionPriority + 1,
		Enum.KeyCode.ButtonB
	)
	if InputController.GetDevice() == "Gamepad" then
		GuiService.SelectedObject = firstControl(screen, terminalId)
	end
	play("UiConfirm")
end

local function buy(perk: Enums.PerkId)
	if buying[perk] then
		return
	end
	buying[perk] = true
	play("UiClick")
	task.spawn(function()
		local ok, result = Net.Client.invoke("PerkPurchase", { perk = perk } :: Types.PerkPurchaseRequest)
		buying[perk] = nil
		local reply = if ok and type(result) == "table" then result :: Types.PerkPurchaseResult else nil
		if reply and reply.ok == true then
			shopStatus = Strings.get("Lobby.Purchased", Strings.get("Perk." .. perk))
			play("UiConfirm")
		else
			local reason = if reply and type(reply.reason) == "string" then reply.reason else nil
			shopStatus = Strings.get(if reason and Strings.has(reason) then reason else "Lobby.PurchaseFailed")
			play("UiBack")
		end
	end)
end

local function toggleEquip(perk: Enums.PerkId)
	local equipped = table.find(localLoadout(), perk) ~= nil
	sendAction({ action = if equipped then "UnequipPerk" else "EquipPerk", perk = perk })
	play("UiClick")
end

local function vote(difficulty: Enums.Difficulty)
	sendAction({ action = "VoteDifficulty", difficulty = difficulty })
	play("UiClick")
end

local function wireScreen(screen: Screen)
	serviceTrove:Connect(screen.close.Activated, function()
		closeScreen()
	end)
	for _, card in screen.cards do
		serviceTrove:Connect(card.button.Activated, function()
			vote(card.difficulty)
		end)
	end
	for _, row in screen.rows do
		serviceTrove:Connect(row.buy.Activated, function()
			if row.buy.Active then
				buy(row.perk)
			end
		end)
		serviceTrove:Connect(row.equip.Activated, function()
			if row.equip.Active then
				toggleEquip(row.perk)
			end
		end)
	end
end

local function refreshScreen(screen: Screen, squad: { Player })
	local terminalId = openTerminal
	if terminalId == LobbyBuilder.Terminals.Difficulty then
		local cast: { string } = {}
		for _, member in squad do
			local value = member:GetAttribute(P.DifficultyVote)
			if type(value) == "string" then
				table.insert(cast, value)
			end
		end
		local standard, nightmare = LobbyController.voteCounts(cast)
		local player = localPlayer
		local mine = if player then player:GetAttribute(P.DifficultyVote) else nil
		for _, card in screen.cards do
			local count = if card.difficulty == "Nightmare" then nightmare else standard
			setText(card.votes, Strings.get("Lobby.Votes", count))
			card.mine.Visible = mine == card.difficulty
			local color = if mine == card.difficulty then Palette.Amber else Palette.StrokeDim
			if card.stroke.Color ~= color then
				card.stroke.Color = color
			end
		end
		setText(
			screen.result,
			Strings.get("Lobby.DifficultyCurrent", difficultyName(ReplicatedStorage:GetAttribute(M.LobbyDifficulty)))
		)
	elseif terminalId == LobbyBuilder.Terminals.Perks then
		local credits = localCredits()
		local stock = localStock()
		local loadout = localLoadout()
		setText(screen.credits, Strings.get("Lobby.Credits", credits))
		for _, row in screen.rows do
			local shown =
				LobbyController.shopRow(row.perk, credits, stock[row.perk] or 0, table.find(loadout, row.perk) ~= nil)
			setText(row.owned, shown.ownedText)
			setText(row.cost, shown.costText)
			setButtonText(row.buy, shown.buyText)
			setButtonText(row.equip, shown.equipText)
			row.equippedTag.Visible = shown.equipped
			setEnabled(row.buy, shown.buyEnabled and not buying[row.perk])
			setEnabled(row.equip, shown.equipEnabled)
		end
		setText(screen.status, shopStatus)
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function fillRow(row: SquadRow, player: Player, inSquad: boolean)
	row.frame.Visible = true
	setText(row.name, displayName(player))
	if inSquad then
		local isReady = Attributes.getBool(player, P.Ready, false)
		setText(row.status, Strings.get(if isReady then "Lobby.Ready" else "Lobby.Unready"))
		local color = if isReady then Palette.Moss else Palette.Ash
		if row.status.TextColor3 ~= color then
			row.status.TextColor3 = color
		end
		local voted = player:GetAttribute(P.DifficultyVote)
		setText(
			row.vote,
			if Enums.has(Enums.Difficulty, voted) then difficultyName(voted) else Strings.get("Lobby.NoVote")
		)
	else
		local loaded = Attributes.getBool(player, P.DataLoaded, false)
		setText(row.status, if loaded then "" else Strings.get("Lobby.Loading"))
		setText(row.vote, "")
	end
end

local function updateSquad(current: View, squad: { Player })
	for index, row in current.squadRows do
		local member = squad[index]
		if member then
			fillRow(row, member, true)
		else
			row.frame.Visible = false
		end
	end
	local waiting: { Player } = {}
	for _, player in Players:GetPlayers() do
		if table.find(squad, player) == nil then
			table.insert(waiting, player)
		end
	end
	while #current.waitingRows < #waiting do
		table.insert(current.waitingRows, squadRow(current.waitingList, #current.waitingRows + 1))
	end
	for index, row in current.waitingRows do
		local player = waiting[index]
		if player then
			fillRow(row, player, false)
		else
			row.frame.Visible = false
		end
	end
	current.waitingTitle.Visible = #waiting > 0
	setText(
		current.difficultyLine,
		Strings.get("Lobby.DifficultyCurrent", difficultyName(ReplicatedStorage:GetAttribute(M.LobbyDifficulty)))
	)
	setText(current.creditsLine, Strings.get("Lobby.Credits", localCredits()))
end

local function updateLamps()
	local lobby = Instances.lobby()
	local props = if lobby then lobby:FindFirstChild(Instances.Names.Props) else nil
	if not props then
		return
	end
	for _, child in props:GetChildren() do
		local id = child:GetAttribute(W.AnchorId)
		if not child:IsA("BasePart") or type(id) ~= "string" or child.Name ~= LobbyBuilder.padName(id) then
			continue
		end
		local lamp = props:FindFirstChild(LobbyBuilder.lampName(id))
		if not lamp or not lamp:IsA("BasePart") then
			continue
		end
		local occupantId = child:GetAttribute(W.OccupantUserId)
		local occupant = if type(occupantId) == "number" then Players:GetPlayerByUserId(occupantId) else nil
		local color =
			LobbyController.lampColor(occupant ~= nil, occupant ~= nil and Attributes.getBool(occupant, P.Ready, false))
		if lamp.Color ~= color then
			lamp.Color = color
		end
	end
end

local function updateCountdown(current: View, squad: { Player })
	local raw = ReplicatedStorage:GetAttribute(M.CountdownEndsAt)
	local endsAt = if type(raw) == "number" then raw else nil
	local readyCount = 0
	for _, member in squad do
		if Attributes.getBool(member, P.Ready, false) then
			readyCount += 1
		end
	end
	local now = serverNow()
	local text, fraction = LobbyController.statusText(endsAt, now, readyCount, #squad)
	setText(current.bannerLabel, text)
	current.bar.root.Visible = fraction ~= nil
	if fraction then
		current.bar:SetFraction(fraction)
	end
	local counting = endsAt ~= nil
	if counting and not wasCounting then
		play("UiConfirm")
	elseif wasCounting and not counting and phaseNow() == "Lobby" then
		play("UiBack")
	end
	wasCounting = counting
	if endsAt then
		local remaining = math.max(0, endsAt - now)
		if LobbyController.secondCrossed(lastRemaining, remaining) then
			play("UiClick")
		end
		lastRemaining = remaining
	else
		lastRemaining = nil
	end
end

local function step(dt: number)
	local current = view
	if not current then
		return
	end
	local camera = Workspace.CurrentCamera
	if camera then
		local nextScale = UIKit.scaleFor(camera.ViewportSize)
		if math.abs(current.scale.Scale - nextScale) > 1e-3 then
			current.scale.Scale = nextScale
			-- The UIScale grows the layer from its top-left corner: size it so the scaled layer still fills the screen
			-- (as the HUD's layer does), or the banner drifts off centre and the hint off the bottom edge.
			current.layer.Size = UDim2.fromScale(1 / nextScale, 1 / nextScale)
		end
		local screenScale = current.screen.scale
		if math.abs(screenScale.Scale - nextScale) > 1e-3 then
			-- The UIScale grows the panel too: size it so the scaled panel still fits the screen.
			screenScale.Scale = nextScale
			current.screen.panel.Size = UDim2.fromScale(0.92 / nextScale, 0.9 / nextScale)
		end
	end

	local shown = lobbyShown()
	alpha = MathUtil.approach(alpha, if shown then 1 else 0, (if shown then FADE_IN else FADE_OUT) * dt)
	local root = current.root
	local showing = alpha > 1e-3
	if root.Visible ~= showing then
		root.Visible = showing
	end
	for _, canvas in current.groups do
		if math.abs(canvas.GroupTransparency - (1 - alpha)) > 1e-3 then
			canvas.GroupTransparency = 1 - alpha
		end
	end
	UIKit.setTextTransparency(current.hint, 1 - alpha)
	current.readyButton:SetAlpha(alpha)
	bindReady(shown and openTerminal == nil and InputController.GetContext() ~= "Menu")

	if not shown then
		if openTerminal ~= nil then
			closeScreen(true)
		end
		wasCounting = false
		lastRemaining = nil
	else
		local squad = squadPlayers()
		updateSquad(current, squad)
		updateCountdown(current, squad)
		local player = localPlayer
		local loaded = player ~= nil and Attributes.getBool(player, P.DataLoaded, false)
		local inSquad = player ~= nil and table.find(squad, player) ~= nil
		local isReady = localReady()
		local state: HintState = LobbyController.hintState(loaded, inSquad, isReady)
		local device = InputController.GetDevice()
		setText(current.hint, Strings.get(LobbyController.hintKey(state, device)))
		local button = current.readyButton
		button.button.Visible = device == "Touch" and inSquad and loaded
		button:SetLatched(isReady)
		setText(current.readyLabel, Strings.get(if isReady then "Lobby.UnreadyButton" else "Lobby.ReadyButton"))
		button:Step(dt)
		lampClock += dt
		if lampClock >= LAMP_INTERVAL then
			lampClock = 0
			updateLamps()
		end
		if openTerminal ~= nil then
			local body = if player then Instances.characterRoot(player) else nil
			local target = terminalPosition
			local distance = if body and target then (body.CFrame.Position - target).Magnitude else nil
			if not LobbyController.inReach(distance) then
				closeScreen()
			else
				refreshScreen(current.screen, squad)
			end
		end
	end

	local open = openTerminal ~= nil
	screenAlpha =
		MathUtil.approach(screenAlpha, if open then 1 else 0, (if open then FADE_IN * 1.6 else FADE_OUT * 2) * dt)
	local screen = current.screen
	if not open and screenAlpha <= 0 then
		if screen.gui.Enabled then
			screen.gui.Enabled = false
		end
		return
	end
	local eased = screenAlpha * screenAlpha * (3 - 2 * screenAlpha)
	screen.backdrop.BackgroundTransparency = UIKit.fade(0.3, eased)
	screen.panel.Position = UDim2.new(0.5, 0, 0.5, math.floor((1 - eased) * 18))
	screen.panel.Visible = open or eased > 0.02
end

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------

local function onPrivateCue(payload: any)
	if type(payload) ~= "table" or payload.kind ~= "Terminal" then
		return
	end
	local args: { [string]: any } = if type(payload.args) == "table" then payload.args else {}
	local terminal = args.terminal
	if type(terminal) == "string" then
		openScreen(terminal)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function LobbyController.Init()
	serviceTrove:Add(function()
		closeScreen(true)
		bindReady(false)
		local current = view
		view = nil
		if current then
			current.gui:Destroy()
			current.screen.gui:Destroy()
		end
	end)
end

function LobbyController.Start()
	local player = localPlayer
	if not player then
		log.warn("no local player; the lobby HUD is not shown")
		return
	end
	local gui = player:WaitForChild("PlayerGui")
	xpcall(function()
		local built = build(gui)
		view = built
		wireScreen(built.screen)
		serviceTrove:Connect(built.readyButton.button.Activated, toggleReady)
		serviceTrove:Connect(built.readyButton.button.MouseButton1Down, function()
			built.readyButton:SetPressed(true)
		end)
		serviceTrove:Connect(built.readyButton.button.MouseButton1Up, function()
			built.readyButton:SetPressed(false)
		end)
		serviceTrove:Connect(built.readyButton.button.MouseLeave, function()
			built.readyButton:SetPressed(false)
		end)
	end, function(err: any)
		log.error("lobby HUD failed to build: %s\n%s", tostring(err), debug.traceback())
	end)
	local cue = Net.Client.on("PrivateCue", onPrivateCue)
	if cue then
		serviceTrove:Add(cue)
	end
	serviceTrove:Connect(RunService.PreRender, step)
end

function LobbyController.OnRunStarted(_info: Types.RunInfo)
	closeScreen(true)
	buying = {}
end

return table.freeze(LobbyController)
