--!strict
-- RenderBudgetController: how much light the device may render, as one of the five Graphics tiers.
--
--   * Ceiling. The tier the player picked in the Graphics setting (GraphicsController calls SetCeiling; Max, the
--     default, until then). The client starts at its ceiling.
--   * Frame-rate guard. Frames are counted in 1 s windows. 5 s in a row under 35 FPS drops a tier; 20 s in a row above
--     55 FPS raises one (never above the ceiling); anything between resets both clocks. A tier that is dropped again
--     soon after being raised doubles the time the next raise needs (up to 160 s), so a device on the edge settles
--     instead of flapping. Windows while the window is unfocused, during the first seconds after start (the world
--     streaming in) and across hitches longer than 3 s are ignored. Only this budget follows the guard: the tier's
--     surfaces and post (GraphicsController) stay where the player put them, so nothing pops in and out.
--   * Output. Each tier's Budget is GraphicsConfig's: level-light fixtures, their shadows and the radius past which
--     unshadowed ones go dark (LightingController.SetBudget / SetEffectsBudget), how many of those fixtures keep their
--     shadows, moonlight spills through the windows and how many of them are shadowed, visible light shafts and dust
--     emitters, and, read by their owners through GetBudget / BudgetChanged, depth of field, particle scale, the
--     torches' shadows and haze cone, animation LOD distances and the teammate flashlight cap. Low keeps the torch's
--     shadow and drops the fixtures'; Potato keeps only what a school Chromebook can afford.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local GraphicsConfig = require(ReplicatedStorage.Shared.Config.GraphicsConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

local LightingController = require(script.Parent.LightingController)

local log = Log.new("RenderBudget")

export type Tier = GraphicsConfig.TierName

-- A tier's GraphicsConfig budget, named.
export type Budget = {
	tier: Tier,
	lights: number, -- level-light fixtures rendered at once (nearest first)
	shadows: boolean, -- fixture shadows
	shadowLights: number, -- of the rendered fixtures, the nearest that keep their shadows
	fillRadius: number, -- studs: unshadowed fixtures further than this go dark
	flashlightShadows: boolean, -- the torches' inner cones
	flashlightHaze: boolean, -- the torch's faint visible cone in the haze
	remoteFlashlights: number, -- teammates' flashlight cones rendered at once (nearest first)
	windowLights: number, -- moonlight spills through the nearest windows
	windowShadows: number, -- of those, the nearest that are shadowed (the planks stripe the floor)
	shafts: number, -- visible light shafts (fixture haze cones and window rays), nearest first
	dust: number, -- dust-mote emitters, in the nearest shafts
	particleScale: number, -- emitter rate multiplier
	dof: boolean, -- panic depth of field
	animNear: number, -- studs: full-rate procedural animation inside this
	animFar: number, -- studs: every third frame up to this, frozen beyond
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

-- Worst first: the guard steps along this.
local TIERS: { Tier } = { "Potato", "Low", "Medium", "High", "Max" }

local LOW_FPS = 35
local HIGH_FPS = 55
local DROP_AFTER = 5
local RAISE_AFTER = 20
local MAX_RAISE_AFTER = 160
local FLAP_WINDOW = 30 -- a drop this soon after a raise counts as flapping
local WINDOW = 1
local MAX_WINDOW = 3 -- longer windows are hitches (or a paused client), not a frame rate
local WARMUP = 10

local BUDGETS: { [Tier]: Budget } = {}
for index = 1, #TIERS do
	local name: Tier = TIERS[index]
	local budget = table.clone(GraphicsConfig.tier(name).budget) :: any
	budget.tier = name
	BUDGETS[name] = table.freeze(budget) :: Budget
end
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

-- Moves the ceiling (the Graphics setting changed); the tier is clamped under it.
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

-- Whether `tier` is `floor` or better (effects that only some tiers afford: the flask's glow and aim arc).
function RenderBudgetController.atLeast(tier: Tier, floor: Tier): boolean
	return tierIndex(tier) >= tierIndex(floor)
end

--------------------------------------------------------------------------------
-- Apply
--------------------------------------------------------------------------------

local function publish()
	local budget = BUDGETS[state.tier]
	LightingController.SetBudget(budget.lights, budget.shadows)
	LightingController.SetEffectsBudget({
		shadowLights = budget.shadowLights,
		fillRadius = budget.fillRadius,
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

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function RenderBudgetController.GetBudget(): Budget
	return BUDGETS[state.tier]
end

function RenderBudgetController.GetState(): TierState
	return table.clone(state)
end

-- The Graphics tier is the ceiling. Raising it starts there at once (the player asked for more); lowering it clamps
-- the budget under it.
function RenderBudgetController.SetCeiling(ceiling: Tier)
	if BUDGETS[ceiling] == nil or ceiling == state.ceiling then
		return
	end
	local before: Tier = state.tier
	if tierIndex(ceiling) > tierIndex(state.ceiling) then
		state = RenderBudgetController.newState(ceiling)
	else
		state = RenderBudgetController.withCeiling(state, ceiling)
	end
	if state.tier ~= before then
		log.info("render tier -> %s (Graphics %s)", state.tier, ceiling)
		publish()
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

state = RenderBudgetController.newState(GraphicsConfig.default().name)

function RenderBudgetController.Init()
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
end

return table.freeze(RenderBudgetController)
