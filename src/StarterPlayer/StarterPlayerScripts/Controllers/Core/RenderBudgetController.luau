--!strict
-- RenderBudgetController: how much the device may render, as one of three tiers.
--
--   * Ceiling. The highest tier the device may reach: the player's own Roblox graphics quality when they set one
--     (levels 1-3 Low, 4-6 Medium, 7-10 High), otherwise the device class (phones and tablets Medium, consoles and
--     desktops High). The client starts at its ceiling.
--   * Adaptation. Frames are counted in 1 s windows. 5 s in a row under 35 FPS drops a tier; 20 s in a row above
--     55 FPS raises one (never above the ceiling); anything between resets both clocks. A tier that is dropped again
--     soon after being raised doubles the time the next raise needs (up to 160 s), so a device on the edge settles
--     instead of flapping. Windows while the window is unfocused, during the first seconds after start (the world
--     streaming in) and across hitches longer than 3 s are ignored.
--   * Output. Each tier is a Budget: level-light fixtures and shadows (applied to LightingController.SetBudget), the
--     atmosphere's extras (how many of those fixtures keep their shadows, moonlight spills through the windows and
--     how many of them are shadowed, visible light shafts and dust emitters: LightingController.SetEffectsBudget),
--     depth of field, particle scale, the torch's haze cone, animation LOD distances and the teammate flashlight cap
--     (read by their owners through GetBudget / BudgetChanged). Low keeps only what a weak device can afford: no
--     shadows, no shafts, no dust, no depth of field, a few unshadowed moonlight spills so the windows still read.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Log = require(ReplicatedStorage.Shared.Util.Log)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

local LightingController = require(script.Parent.LightingController)

local log = Log.new("RenderBudget")

export type Tier = "Low" | "Medium" | "High"

export type Budget = {
	tier: Tier,
	lights: number, -- level-light fixtures rendered at once (nearest first)
	shadows: boolean, -- fixture and flashlight shadows
	shadowLights: number, -- of the rendered fixtures, the nearest that keep their shadows
	windowLights: number, -- moonlight spills through the nearest windows
	windowShadows: number, -- of those, the nearest that are shadowed (the planks stripe the floor)
	shafts: number, -- visible light shafts (fixture haze cones and window rays), nearest first
	dust: number, -- dust-mote emitters, in the nearest shafts
	flashlightHaze: boolean, -- the torch's faint visible cone in the haze
	dof: boolean, -- panic depth of field
	particleScale: number, -- emitter rate multiplier
	animNear: number, -- studs: full-rate procedural animation inside this
	animFar: number, -- studs: every third frame up to this, frozen beyond
	remoteFlashlights: number, -- teammates' flashlight cones rendered at once (nearest first)
}

-- Adaptation state, advanced one FPS window at a time by `step`.
export type TierState = {
	tier: Tier,
	ceiling: Tier,
	lowFor: number, -- consecutive seconds under LOW_FPS
	highFor: number, -- consecutive seconds above HIGH_FPS
	sinceChange: number, -- seconds since the tier last changed
	lastChange: "None" | "Raised" | "Dropped",
	raiseAfter: number, -- seconds above HIGH_FPS a raise currently needs
}

local TIERS: { Tier } = { "Low", "Medium", "High" }

local LOW_FPS = 35
local HIGH_FPS = 55
local DROP_AFTER = 5
local RAISE_AFTER = 20
local MAX_RAISE_AFTER = 160
local FLAP_WINDOW = 30 -- a drop this soon after a raise counts as flapping
local WINDOW = 1
local MAX_WINDOW = 3 -- longer windows are hitches (or a paused client), not a frame rate
local WARMUP = 10

local BUDGETS: { [Tier]: Budget } = {
	Low = table.freeze({
		tier = "Low",
		lights = 16,
		shadows = false,
		shadowLights = 0,
		windowLights = 4,
		windowShadows = 0,
		shafts = 0,
		dust = 0,
		flashlightHaze = false,
		dof = false,
		particleScale = 0.4,
		animNear = 35,
		animFar = 90,
		remoteFlashlights = 1,
	} :: Budget),
	Medium = table.freeze({
		tier = "Medium",
		lights = 30,
		shadows = true,
		shadowLights = 20,
		windowLights = 6,
		windowShadows = 0,
		shafts = 6,
		dust = 3,
		flashlightHaze = true,
		dof = false,
		particleScale = 0.7,
		animNear = 55,
		animFar = 140,
		remoteFlashlights = 2,
	} :: Budget),
	High = table.freeze({
		tier = "High",
		lights = 48,
		shadows = true,
		shadowLights = 40,
		windowLights = 10,
		windowShadows = 4,
		shafts = 14,
		dust = 8,
		flashlightHaze = true,
		dof = true,
		particleScale = 1,
		animNear = 80,
		animFar = 220,
		remoteFlashlights = 3,
	} :: Budget),
}
table.freeze(BUDGETS)

local RenderBudgetController = {}

RenderBudgetController.Name = "RenderBudgetController"
RenderBudgetController.Budgets = BUDGETS
RenderBudgetController.Tiers = table.freeze(TIERS)

local budgetChanged: Signal.Signal<Budget> = Signal.new()
RenderBudgetController.BudgetChanged = budgetChanged

local serviceTrove = Trove.new()
local state: TierState
local focused = true
local startedAt = 0
local windowStart = 0
local windowFrames = 0

--------------------------------------------------------------------------------
-- Pure rules (specced)
--------------------------------------------------------------------------------

local function tierIndex(tier: Tier): number
	return table.find(TIERS, tier) or 1
end

-- Roblox graphics quality (0 = Automatic, 1..10 = the player's slider) -> the tier it allows, or nil for Automatic.
function RenderBudgetController.qualityTier(level: number): Tier?
	if level <= 0 then
		return nil
	elseif level <= 3 then
		return "Low"
	elseif level <= 6 then
		return "Medium"
	end
	return "High"
end

-- The highest tier a device may use: the explicit graphics quality if any, else its device class.
function RenderBudgetController.ceilingFor(isTouch: boolean, isConsole: boolean, qualityLevel: number): Tier
	local fromQuality: Tier? = RenderBudgetController.qualityTier(qualityLevel)
	if fromQuality then
		return fromQuality
	end
	if isTouch and not isConsole then
		return "Medium"
	end
	return "High"
end

function RenderBudgetController.newState(ceiling: Tier): TierState
	return {
		tier = ceiling,
		ceiling = ceiling,
		lowFor = 0,
		highFor = 0,
		sinceChange = 0,
		lastChange = "None",
		raiseAfter = RAISE_AFTER,
	}
end

-- Moves the ceiling (quality setting changed); the tier is clamped under it.
function RenderBudgetController.withCeiling(from: TierState, ceiling: Tier): TierState
	local nextState = table.clone(from)
	nextState.ceiling = ceiling
	if tierIndex(nextState.tier) > tierIndex(ceiling) then
		nextState.tier = ceiling
		nextState.sinceChange = 0
		nextState.lastChange = "Dropped"
	end
	nextState.lowFor = 0
	nextState.highFor = 0
	return nextState
end

-- Advances the adaptation by one FPS window of `seconds`. Returns the new state and whether the tier changed.
function RenderBudgetController.step(from: TierState, fps: number, seconds: number): (TierState, boolean)
	local nextState = table.clone(from)
	nextState.sinceChange += seconds
	local index = tierIndex(nextState.tier)
	if fps < LOW_FPS then
		nextState.highFor = 0
		nextState.lowFor += seconds
		if nextState.lowFor >= DROP_AFTER and index > 1 then
			if nextState.lastChange == "Raised" and nextState.sinceChange <= FLAP_WINDOW then
				nextState.raiseAfter = math.min(nextState.raiseAfter * 2, MAX_RAISE_AFTER)
			end
			nextState.tier = TIERS[index - 1]
			nextState.lowFor = 0
			nextState.sinceChange = 0
			nextState.lastChange = "Dropped"
			return nextState, true
		end
	elseif fps > HIGH_FPS then
		nextState.lowFor = 0
		nextState.highFor += seconds
		if nextState.highFor >= nextState.raiseAfter and index < tierIndex(nextState.ceiling) then
			nextState.tier = TIERS[index + 1]
			nextState.highFor = 0
			nextState.sinceChange = 0
			nextState.lastChange = "Raised"
			return nextState, true
		end
	else
		nextState.lowFor = 0
		nextState.highFor = 0
	end
	-- A tier that has held for a long while has proven itself: forgive earlier flapping.
	if nextState.sinceChange >= MAX_RAISE_AFTER then
		nextState.raiseAfter = RAISE_AFTER
	end
	return nextState, false
end

function RenderBudgetController.budgetFor(tier: Tier): Budget
	return BUDGETS[tier]
end

--------------------------------------------------------------------------------
-- Device
--------------------------------------------------------------------------------

local function qualityLevel(): number
	local level = 0
	xpcall(function()
		local saved = UserSettings().GameSettings.SavedQualityLevel
		level = saved.Value
	end, function(err: any)
		log.warnThrottled("quality", 120, "could not read the graphics quality: %s", tostring(err))
	end)
	return level
end

local function deviceCeiling(): Tier
	local isTouch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local isConsole = GuiService:IsTenFootInterface()
	return RenderBudgetController.ceilingFor(isTouch, isConsole, qualityLevel())
end

--------------------------------------------------------------------------------
-- Apply
--------------------------------------------------------------------------------

local function publish()
	local budget = BUDGETS[state.tier]
	LightingController.SetBudget(budget.lights, budget.shadows)
	LightingController.SetEffectsBudget({
		shadowLights = budget.shadowLights,
		windowLights = budget.windowLights,
		windowShadows = budget.windowShadows,
		shafts = budget.shafts,
		dust = budget.dust,
		particleScale = budget.particleScale,
	})
	budgetChanged:Fire(budget)
end

local function onFrame()
	windowFrames += 1
	local now = os.clock()
	local elapsed = now - windowStart
	if elapsed < WINDOW then
		return
	end
	local frames = windowFrames
	windowStart = now
	windowFrames = 0
	if not focused or elapsed > MAX_WINDOW or now - startedAt < WARMUP then
		return
	end
	local nextState, changedTier = RenderBudgetController.step(state, frames / elapsed, elapsed)
	state = nextState
	if changedTier then
		log.info("render tier -> %s (%.0f FPS)", state.tier, frames / elapsed)
		publish()
	end
end

local function onQualityChanged()
	local ceiling: Tier = deviceCeiling()
	if ceiling == state.ceiling then
		return
	end
	local before: Tier = state.tier
	-- Raising the slider lifts the ceiling and starts there; lowering clamps the tier under it.
	if tierIndex(ceiling) > tierIndex(state.ceiling) then
		state = RenderBudgetController.newState(ceiling)
	else
		state = RenderBudgetController.withCeiling(state, ceiling)
	end
	if state.tier ~= before then
		publish()
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function RenderBudgetController.GetBudget(): Budget
	return BUDGETS[state.tier]
end

function RenderBudgetController.GetState(): TierState
	return table.clone(state)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

state = RenderBudgetController.newState("High")

function RenderBudgetController.Init()
	state = RenderBudgetController.newState(deviceCeiling())
	publish()
end

function RenderBudgetController.Start()
	startedAt = os.clock()
	windowStart = startedAt
	serviceTrove:Connect(RunService.PreRender, onFrame)
	serviceTrove:Connect(UserInputService.WindowFocused, function()
		focused = true
		windowStart = os.clock()
		windowFrames = 0
	end)
	serviceTrove:Connect(UserInputService.WindowFocusReleased, function()
		focused = false
	end)
	xpcall(function()
		local settings = UserSettings().GameSettings
		serviceTrove:Connect(settings:GetPropertyChangedSignal("SavedQualityLevel"), onQualityChanged)
	end, function(err: any)
		log.warnThrottled("qualityWatch", 120, "could not watch the graphics quality: %s", tostring(err))
	end)
end

return table.freeze(RenderBudgetController)
