--!strict
-- WaterRules: the flooded pool's rules shared by the server (FloodedPoolService judges them) and the swimming client
-- (SwimController / StruggleController predict them), so both sides agree on who is in the water, how high a body
-- floats, when a head is under, how the oxygen meter moves and how a struggle progresses. Pure functions only
-- (specs: tests/Specs/Pool.spec.luau).
--
-- Water volumes. Every PoolWater part (SchoolShellBuilder: a basin's volume from its floor up to the water surface;
-- layout triggers such as the half-flooded maintenance duct's lower bore) is an upright box. Its top face is the
-- water surface. Duct floods belong to the vent crawl (VentNetworkService owns those bodies), so they are never
-- swum in.
--
-- Membership (locate). A root enters the water when it is inside a volume's footprint, no lower than BottomSlack under
-- its floor and no higher than EnterAbove over its surface; it stays in while it is inside the footprint and no
-- higher than StayAbove over the surface (hysteresis: a swimmer bobbing at the surface or kicking up never flickers
-- out, a walker on the deck or on a bridge fragment never counts as swimming).
--
-- Floating (floatRootY). A surface swimmer's root floats where their eye (CameraConfig.EyeHeightAboveRoot for the
-- MoveState, the point the Creature's sight and the server's oxygen rule use) sits EyeAbove[state] over the surface:
-- treading keeps the face clear, freestyle rides the bow wave, a downed swimmer floats face up.
--
-- Under (submerged). Underwater (the dive held) and Grabbed always count as under; DownedCrawling never does (a
-- downed swimmer floats); any other state is under while its eye is more than SubmergeMargin below the surface.
--
-- Oxygen (oxygenRate). Held by a jumpscare or cutscene: steady. Grabbed: OxygenDrainGrabbed. In the water and under:
-- OxygenDrain. Otherwise it recovers at OxygenRegen until full, then holds.
--
-- Struggle (newStruggle / press / progressAt / escaped). Each StrugglePress carries a sequence number; a press counts
-- once, only when its sequence is newer than the last one seen, and only while fewer than StruggleMaxPressesPerSecond
-- presses were counted in the last second (anything faster is dropped, never banked). Every counted press adds one;
-- after DecayDelay seconds without one the progress slips back at DecayPerSecond. StrugglePressesToEscape breaks free.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

export type Volume = {
	id: string,
	cframe: CFrame,
	size: Vector3,
	surface: number, -- world Y of the water surface (the box's top)
	bottom: number, -- world Y of the box's floor
	duct: boolean, -- a flooded duct (crawled, never swum)
	part: BasePart?,
}

export type OxygenInput = {
	inWater: boolean,
	submerged: boolean,
	grabbed: boolean,
	held: boolean, -- a jumpscare or cutscene has the body: the meter waits
	oxygen: number,
	max: number,
}

export type Struggle = {
	progress: number, -- presses banked at `at`
	at: number,
	lastPressAt: number,
	lastSequence: number,
	window: { number }, -- times of the presses counted in the last second
	counted: number,
}

export type PressVerdict = "Counted" | "Stale" | "TooFast"

local ENTER_ABOVE = 0.5
local STAY_ABOVE = 1.8
local BOTTOM_SLACK = 0.6
local SUBMERGE_MARGIN = 0.12
local DECAY_DELAY = 0.6
local DECAY_PER_SECOND = 2.5
local PRESS_WINDOW = 1

local EYE_ABOVE: { [string]: number } = {
	Treading = 0.35,
	Freestyle = 0.2,
	DownedCrawling = 0.3,
}
local DEFAULT_EYE_ABOVE = 0.35

local WaterRules = {}

WaterRules.EnterAbove = ENTER_ABOVE
WaterRules.StayAbove = STAY_ABOVE
WaterRules.BottomSlack = BOTTOM_SLACK
WaterRules.SubmergeMargin = SUBMERGE_MARGIN
WaterRules.DecayDelay = DECAY_DELAY
WaterRules.DecayPerSecond = DECAY_PER_SECOND
WaterRules.PressesToEscape = GameConfig.StrugglePressesToEscape
WaterRules.MaxPressesPerSecond = GameConfig.StruggleMaxPressesPerSecond
WaterRules.EyeAbove = table.freeze(table.clone(EYE_ABOVE))

--------------------------------------------------------------------------------
-- Volumes
--------------------------------------------------------------------------------

-- The water volume of a box (an upright PoolWater part's CFrame and Size).
function WaterRules.volumeOf(id: string, cframe: CFrame, size: Vector3, duct: boolean, part: BasePart?): Volume
	local half = size.Y / 2
	return {
		id = id,
		cframe = cframe,
		size = size,
		surface = cframe.Position.Y + half,
		bottom = cframe.Position.Y - half,
		duct = duct,
		part = part,
	}
end

-- Whether `point` lies over `volume`'s footprint.
function WaterRules.overFootprint(volume: Volume, point: Vector3): boolean
	local p = volume.cframe:PointToObjectSpace(point)
	return math.abs(p.X) <= volume.size.X / 2 and math.abs(p.Z) <= volume.size.Z / 2
end

-- Whether a root at `point` is in `volume` with at most `above` studs over its surface.
function WaterRules.contains(volume: Volume, point: Vector3, above: number): boolean
	if not MathUtil.isFiniteVector(point) then
		return false
	end
	if point.Y < volume.bottom - BOTTOM_SLACK or point.Y > volume.surface + above then
		return false
	end
	return WaterRules.overFootprint(volume, point)
end

-- The volume a root at `point` swims in (see the header): `current` while it stays in, else the first swimmable
-- volume it entered, else nil.
function WaterRules.locate(volumes: { Volume }, point: Vector3, current: Volume?): Volume?
	if current and not current.duct and WaterRules.contains(current, point, STAY_ABOVE) then
		return current
	end
	for _, volume in volumes do
		if not volume.duct and WaterRules.contains(volume, point, ENTER_ABOVE) then
			return volume
		end
	end
	return nil
end

-- The swimmable volume whose footprint holds `point` with `point` between its floor and `reach` over its surface
-- (the camera's water for the underwater view), nil when none.
function WaterRules.volumeAround(volumes: { Volume }, point: Vector3, reach: number): Volume?
	for _, volume in volumes do
		if not volume.duct and WaterRules.contains(volume, point, reach) then
			return volume
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Floating and breathing
--------------------------------------------------------------------------------

-- The server's eye height above the root for `state` (CameraConfig.EyeHeightAboveRoot).
function WaterRules.eyeHeight(state: string): number
	local heights = CameraConfig.EyeHeightAboveRoot
	return heights[state] or heights.Standing
end

-- How far over the surface a floating swimmer in `state` keeps their eye.
function WaterRules.eyeAbove(state: string): number
	return EYE_ABOVE[state] or DEFAULT_EYE_ABOVE
end

-- The root height a surface swimmer in `state` floats at over water whose surface is `surface`.
function WaterRules.floatRootY(surface: number, state: string): number
	return surface + WaterRules.eyeAbove(state) - WaterRules.eyeHeight(state)
end

-- How far the eye of a root at `rootY` in `state` is below `surface` (negative when it is above).
function WaterRules.eyeDepth(state: string, rootY: number, surface: number): number
	return surface - (rootY + WaterRules.eyeHeight(state))
end

-- Whether a swimmer in `state` with the root at `rootY` has their head under (see the header).
function WaterRules.submerged(state: string, rootY: number, surface: number): boolean
	if state == "Underwater" or state == "Grabbed" then
		return true
	end
	if state == "DownedCrawling" then
		return false
	end
	return WaterRules.eyeDepth(state, rootY, surface) > SUBMERGE_MARGIN
end

-- The oxygen meter's rate per second (see the header).
function WaterRules.oxygenRate(input: OxygenInput): number
	if input.held then
		return 0
	end
	if input.grabbed then
		return -GameConfig.OxygenDrainGrabbed
	end
	if input.inWater and input.submerged then
		return -GameConfig.OxygenDrain
	end
	if input.oxygen < input.max then
		return GameConfig.OxygenRegen
	end
	return 0
end

-- Seconds of air left at `oxygen` while draining at `drain` per second (math.huge when it is not draining).
function WaterRules.secondsLeft(oxygen: number, drain: number): number
	if drain <= 0 then
		return math.huge
	end
	return math.max(0, oxygen) / drain
end

--------------------------------------------------------------------------------
-- Struggle
--------------------------------------------------------------------------------

function WaterRules.newStruggle(now: number): Struggle
	return { progress = 0, at = now, lastPressAt = -math.huge, lastSequence = -1, window = {}, counted = 0 }
end

-- The struggle's progress (presses, 0 .. PressesToEscape) at `now`, after any decay.
function WaterRules.progressAt(struggle: Struggle, now: number): number
	local decayFrom = math.max(struggle.at, struggle.lastPressAt + DECAY_DELAY)
	local decay = math.max(0, now - decayFrom) * DECAY_PER_SECOND
	return math.clamp(struggle.progress - decay, 0, WaterRules.PressesToEscape)
end

-- The progress as a fraction of a break-free (0..1) at `now`.
function WaterRules.progressFraction(struggle: Struggle, now: number): number
	return MathUtil.clamp01(WaterRules.progressAt(struggle, now) / WaterRules.PressesToEscape)
end

-- Whether a press numbered `sequence` at `now` would count, without counting it.
function WaterRules.wouldCount(struggle: Struggle, sequence: number, now: number): PressVerdict
	if sequence <= struggle.lastSequence then
		return "Stale"
	end
	local recent = 0
	for _, at in struggle.window do
		if now - at < PRESS_WINDOW then
			recent += 1
		end
	end
	if recent >= WaterRules.MaxPressesPerSecond then
		return "TooFast"
	end
	return "Counted"
end

-- Applies one StrugglePress (see the header). A press that comes too fast still uses up its sequence number.
function WaterRules.press(struggle: Struggle, sequence: number, now: number): PressVerdict
	local verdict: PressVerdict = WaterRules.wouldCount(struggle, sequence, now)
	if verdict == "Stale" then
		return verdict
	end
	struggle.lastSequence = sequence
	local window = struggle.window
	for index = #window, 1, -1 do
		if now - window[index] >= PRESS_WINDOW then
			table.remove(window, index)
		end
	end
	if verdict == "TooFast" then
		return verdict
	end
	struggle.progress = math.min(WaterRules.PressesToEscape, WaterRules.progressAt(struggle, now) + 1)
	struggle.at = now
	struggle.lastPressAt = now
	struggle.counted += 1
	table.insert(window, now)
	return verdict
end

-- Whether the struggle has broken free at `now`.
function WaterRules.escaped(struggle: Struggle, now: number): boolean
	return WaterRules.progressAt(struggle, now) >= WaterRules.PressesToEscape - 1e-6
end

return table.freeze(WaterRules)
