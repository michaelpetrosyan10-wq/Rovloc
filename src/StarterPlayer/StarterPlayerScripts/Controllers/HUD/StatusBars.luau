--!strict
-- StatusBars: the player's meters as thin, quiet bars that only speak up when they matter.
--
--   * Battery, stamina and oxygen are extrapolated every frame from their meter attributes (value at `at`, changing
--     at `rate`, clamped to [0, max]), so they move smoothly between the server's rare writes.
--   * A bar is fully shown while it is changing (draining, recharging) or relevant (oxygen underwater, battery while
--     the flashlight is on); a partly spent bar that has gone quiet settles to a dim resting alpha; a full, idle bar
--     fades away and its row collapses. Under 20 % a bar warms toward ember and pulses, faster under 10 %.
--   * Syringe charges show as small pips while any are left.
--   * While Downed, a bleedout bar drains in the downed overlay (from BleedoutEndsAt, server time).
--   * Placement follows the device: bottom-left with a keyboard or gamepad, top-left under the menu button on touch
--     (the left thumb owns the bottom-left there).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Strings = require(ReplicatedStorage.Shared.Strings)

local UIKit = require(script.Parent.UIKit)

local P = Attributes.Player
local Palette = UIKit.Palette

export type MeterSpec = {
	id: string,
	label: string, -- Strings key
	value: string,
	rate: string,
	at: string,
	max: string,
	default: number,
	color: Color3,
}

export type Context = {
	root: Instance, -- HUD content root (safe area)
	downed: Instance, -- the downed overlay's bar slot
	device: () -> string,
}

export type StatusBars = {
	Update: (self: StatusBars, dt: number, hudAlpha: number) -> (),
	Destroy: (self: StatusBars) -> (),
}

type Row = {
	spec: MeterSpec,
	frame: Frame,
	label: TextLabel,
	bar: UIKit.MeterBar,
	alpha: number,
	lastFraction: number?,
	lastActive: number,
}

local FULL = 0.999
local LOW = 0.2
local CRITICAL = 0.1
local LINGER = 2.5 -- seconds a quiet, partly spent bar stays fully shown
local REST_ALPHA = 0.5
local FADE_IN = 6
local FADE_OUT = 1.6
local ROW_HEIGHT = 24
local BAR_WIDTH = 168
local BAR_HEIGHT = 4
local MARGIN = 22
local TOUCH_TOP = 104 -- clears the touch menu button
local PIP_SIZE = Vector2.new(6, 14)
local MAX_PIPS = 4

local METERS: { MeterSpec } = {
	{
		id = "Battery",
		label = "Hud.Battery",
		value = P.Battery,
		rate = P.BatteryRate,
		at = P.BatteryAt,
		max = P.BatteryMax,
		default = GameConfig.BatteryMax,
		color = Palette.Amber,
	},
	{
		id = "Stamina",
		label = "Hud.Stamina",
		value = P.Stamina,
		rate = P.StaminaRate,
		at = P.StaminaAt,
		max = P.StaminaMax,
		default = GameConfig.StaminaMax,
		color = Palette.Moss,
	},
	{
		id = "Oxygen",
		label = "Hud.Oxygen",
		value = P.Oxygen,
		rate = P.OxygenRate,
		at = P.OxygenAt,
		max = P.OxygenMax,
		default = GameConfig.OxygenMax,
		color = Palette.Cyan,
	},
}

local StatusBars = {}

StatusBars.Meters = METERS

--------------------------------------------------------------------------------
-- Pure rules (specced)
--------------------------------------------------------------------------------

-- A meter's fill fraction at `now` (value at `at`, changing at `rate` per second, clamped to [0, max]).
function StatusBars.meterFraction(value: number, rate: number, at: number, max: number, now: number): number
	if max <= 0 then
		return 0
	end
	local extrapolated = value + rate * math.max(0, now - at)
	return math.clamp(extrapolated, 0, max) / max
end

-- How visible a bar should be: shown while changing or relevant, briefly after it went quiet, then resting dim;
-- gone when full and idle.
function StatusBars.targetAlpha(fraction: number, changing: boolean, relevant: boolean, quietFor: number): number
	if changing or relevant then
		return 1
	end
	if fraction >= FULL then
		return 0
	end
	return if quietFor < LINGER then 1 else REST_ALPHA
end

-- The low-meter warning: 0 above LOW, else a pulse in [0, 1] that quickens under CRITICAL.
function StatusBars.lowPulse(fraction: number, t: number): number
	if fraction >= LOW then
		return 0
	end
	local hz = if fraction < CRITICAL then 2.4 else 1.3
	return 0.5 + 0.5 * math.sin(t * hz * math.pi * 2)
end

-- Fraction of the bleedout left (1 just downed, 0 at expiry).
function StatusBars.bleedoutFraction(endsAt: number, now: number, total: number): number
	if total <= 0 then
		return 0
	end
	return math.clamp((endsAt - now) / total, 0, 1)
end

-- Whether a meter is "relevant" even when steady (shown regardless of being full).
function StatusBars.relevant(id: string, moveState: string, flashlightOn: boolean): boolean
	if id == "Oxygen" then
		return moveState == "Underwater"
	elseif id == "Battery" then
		return flashlightOn
	end
	return false
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function approach(current: number, target: number, dt: number): number
	local speed = if target > current then FADE_IN else FADE_OUT
	return MathUtil.approach(current, target, speed * dt)
end

local function buildRow(parent: Instance, spec: MeterSpec, order: number): Row
	local frame = UIKit.frame(parent, spec.id)
	frame.LayoutOrder = order
	frame.Size = UDim2.fromOffset(BAR_WIDTH, 0)
	frame.ClipsDescendants = true

	local label = UIKit.label(frame, "Label", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ash)
	label.Text = Strings.get(spec.label)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Bottom
	label.Size = UDim2.new(1, 0, 0, 14)
	label.TextWrapped = false
	UIKit.textStroke(label, 0.6)

	local bar = UIKit.meterBar(frame, "Bar", spec.color, BAR_HEIGHT)
	bar.root.Position = UDim2.fromOffset(0, 17)
	return {
		spec = spec,
		frame = frame,
		label = label,
		bar = bar,
		alpha = 0,
		lastFraction = nil,
		lastActive = -math.huge,
	}
end

function StatusBars.mount(ctx: Context): StatusBars
	local player = Players.LocalPlayer

	local cluster = UIKit.frame(ctx.root, "StatusBars")
	cluster.AutomaticSize = Enum.AutomaticSize.Y
	cluster.Size = UDim2.fromOffset(BAR_WIDTH, 0)
	UIKit.list(cluster, Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom)

	local rows: { Row } = {}
	for index, spec in METERS do
		table.insert(rows, buildRow(cluster, spec, index))
	end

	-- Syringe pips
	local syringe = UIKit.frame(cluster, "Syringe")
	syringe.LayoutOrder = #METERS + 1
	syringe.Size = UDim2.fromOffset(BAR_WIDTH, 0)
	syringe.ClipsDescendants = true
	local syringeLabel = UIKit.label(syringe, "Label", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ash)
	syringeLabel.Text = Strings.get("Input.Syringe")
	syringeLabel.TextXAlignment = Enum.TextXAlignment.Left
	syringeLabel.TextYAlignment = Enum.TextYAlignment.Center
	syringeLabel.TextWrapped = false
	syringeLabel.Size = UDim2.new(0, 70, 0, ROW_HEIGHT)
	UIKit.textStroke(syringeLabel, 0.6)
	local pips: { Frame } = {}
	for index = 1, MAX_PIPS do
		local pip = UIKit.fill(syringe, "Pip" .. index, Palette.Bone, 0)
		pip.AnchorPoint = Vector2.new(0, 0.5)
		pip.Size = UDim2.fromOffset(PIP_SIZE.X, PIP_SIZE.Y)
		pip.Position = UDim2.new(0, 72 + (index - 1) * (PIP_SIZE.X + 5), 0, ROW_HEIGHT / 2)
		UIKit.corner(pip, UDim.new(0, 2))
		pips[index] = pip
	end
	local syringeAlpha = 0
	local lastCharges = -1
	local chargesChangedAt = -math.huge

	-- Bleedout bar (lives in the downed overlay)
	local bleed = UIKit.frame(ctx.downed, "Bleedout")
	bleed.Size = UDim2.new(1, 0, 0, 30)
	local bleedLabel = UIKit.label(bleed, "Label", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ember)
	bleedLabel.Text = Strings.get("Hud.Bleedout")
	bleedLabel.Size = UDim2.new(1, 0, 0, 14)
	bleedLabel.TextWrapped = false
	UIKit.textStroke(bleedLabel, 0.5)
	local bleedBar = UIKit.meterBar(bleed, "Bar", Palette.Blood, 5)
	bleedBar.root.Position = UDim2.fromOffset(0, 20)

	local clock = 0
	local placedForTouch: boolean? = nil
	local handle = {} :: StatusBars

	function handle.Update(_self: StatusBars, dt: number, hudAlpha: number)
		clock += dt
		if not player then
			return
		end
		local now = Workspace:GetServerTimeNow()
		local lifeState = Attributes.getString(player, P.LifeState, "Lobby")
		local moveState = Attributes.getString(player, P.MoveState, "Standing")
		local flashlightOn = Attributes.getBool(player, P.FlashlightOn, false)
		local watching = lifeState == "Dead" or lifeState == "Spectating"

		-- Placement by device
		local touch = ctx.device() == "Touch"
		if touch ~= placedForTouch then
			placedForTouch = touch
			cluster.AnchorPoint = if touch then Vector2.new(0, 0) else Vector2.new(0, 1)
			cluster.Position = if touch then UDim2.fromOffset(MARGIN, TOUCH_TOP) else UDim2.new(0, MARGIN, 1, -MARGIN)
		end

		for _, row in rows do
			local spec = row.spec
			local max = Attributes.getNumber(player, spec.max, spec.default)
			local value = Attributes.getNumber(player, spec.value, max)
			local rate = Attributes.getNumber(player, spec.rate, 0)
			local at = Attributes.getNumber(player, spec.at, now)
			local fraction = StatusBars.meterFraction(value, rate, at, max, now)
			-- Changing = the shown fraction actually moved (a rate pinned against empty or full is not change).
			local last = row.lastFraction
			local changing = last ~= nil and math.abs(fraction - last) > 1e-6
			row.lastFraction = fraction
			if changing then
				row.lastActive = clock
			end
			local relevant = StatusBars.relevant(spec.id, moveState, flashlightOn)
			local target = if watching
				then 0
				else StatusBars.targetAlpha(fraction, changing, relevant, clock - row.lastActive)
			row.alpha = approach(row.alpha, target, dt)

			local shown = row.alpha * hudAlpha
			local height = math.floor(ROW_HEIGHT * MathUtil.smoothstep(0, 1, math.min(row.alpha * 3, 1)) + 0.5)
			if row.frame.Size.Y.Offset ~= height then
				row.frame.Size = UDim2.fromOffset(BAR_WIDTH, height)
			end
			row.frame.Visible = height > 0

			local pulse = StatusBars.lowPulse(fraction, clock)
			local warmth = if fraction < LOW then 0.45 + 0.55 * pulse else 0
			row.bar:SetFraction(fraction)
			row.bar:SetColor(spec.color:Lerp(Palette.Ember, warmth))
			row.bar:SetAlpha(shown * (1 - 0.35 * pulse))
			UIKit.setTextTransparency(row.label, UIKit.fade(0.1, shown))
			row.label.TextColor3 = if fraction < LOW then Palette.Ash:Lerp(Palette.Ember, warmth) else Palette.Ash
		end

		-- Syringe
		local charges = math.max(0, math.floor(Attributes.getNumber(player, P.SyringeCharges, 0)))
		if charges ~= lastCharges then
			if lastCharges >= 0 then
				chargesChangedAt = clock
			end
			lastCharges = charges
		end
		local syringeTarget = 0
		if charges > 0 and not watching and lifeState ~= "Lobby" then
			syringeTarget = if lifeState == "Downed" or clock - chargesChangedAt < LINGER then 1 else REST_ALPHA
		end
		syringeAlpha = approach(syringeAlpha, syringeTarget, dt)
		local syringeHeight = math.floor(ROW_HEIGHT * MathUtil.smoothstep(0, 1, math.min(syringeAlpha * 3, 1)) + 0.5)
		if syringe.Size.Y.Offset ~= syringeHeight then
			syringe.Size = UDim2.fromOffset(BAR_WIDTH, syringeHeight)
		end
		syringe.Visible = syringeHeight > 0
		local syringeShown = syringeAlpha * hudAlpha
		UIKit.setTextTransparency(syringeLabel, UIKit.fade(0.1, syringeShown))
		for index, pip in pips do
			pip.Visible = index <= charges
			UIKit.setTransparency(pip, UIKit.fade(0.05, syringeShown))
		end

		-- Bleedout
		if lifeState == "Downed" then
			local endsAt = Attributes.getNumber(player, P.BleedoutEndsAt, now)
			local fraction = StatusBars.bleedoutFraction(endsAt, now, GameConfig.BleedoutSeconds)
			local beat = 0.5 + 0.5 * math.sin(clock * (1.2 + 1.6 * (1 - fraction)) * math.pi * 2)
			bleedBar:SetFraction(fraction)
			bleedBar:SetColor(Palette.Blood:Lerp(Palette.Ember, beat * 0.6))
			bleedBar:SetAlpha(hudAlpha)
			UIKit.setTextTransparency(bleedLabel, UIKit.fade(0.15 * beat, hudAlpha))
		end
	end

	function handle.Destroy(_self: StatusBars)
		cluster:Destroy()
		bleed:Destroy()
	end

	return handle
end

return table.freeze(StatusBars)
