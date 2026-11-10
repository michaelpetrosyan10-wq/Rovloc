--!strict
-- LockerMotion: a hiding spot's moments on server time (lockers, and the tunnels' barrels and cabinets: HideKind),
-- shared by HideSpotService (the server steps the leaf on Heartbeat for collision, moves the body and judges the
-- hold-breath check) and LockerController (every client renders the same leaf motion every PreRender, flies the hidden
-- player's camera in and out, and predicts their lungs between the server's meter cues).
--
-- Door motions travel as DoorMotion messages (Shared/Sequence/DoorMotion: from, to, seconds, ease, motionId, startAt =
-- the OneShot's) on OneShot "Door" (open / shut) and "LockerRip" (the Creature tearing the door off), with the locker
-- model as the subject and two extra args: `phase` (Phase) and `occupant` (the UserId the motion is about, 0 for
-- none). DoorController ignores them (a hiding spot has no DoorId). Swing poses the spot's leaf (openness 0 shut .. 1
-- open): a locker's door (LockerBuilder.setDoor), a barrel's lid (HideBuilder.lidTransform), a cabinet's door
-- (HideBuilder.doorTransform). Smash poses it torn off (0 shut .. 1 lying on the floor): LockerBuilder.setRipped, or a
-- barrel's lid / a cabinet's door wrenched open and flung in an arc to its "<Leaf>Landing".
--
-- Getting in (enterSchedule, from the open's startAt `s`): the door swings open over OpenSeconds; at s + OpenSeconds
-- the body is moved inside (the HideAnchor, facing out); StepInSeconds later the door swings shut over CloseSeconds;
-- the occupant is settled at the end. Getting out (exitSchedule) mirrors it: open, the body moved out to the exit
-- spot, StepOutSeconds, shut.
--
-- Lungs (breathAt / setHeld / emptyAt): seconds of held breath, 0 .. GameConfig.BreathHoldMaxSeconds. Holding drains
-- one second per second; letting go recovers GameConfig.BreathRecoverPerSecond per second. A change of `held` is
-- recorded with the value at that instant, so the meter is exact at any later time.
--
-- The check (HideSpotService judges; the numbers live here so the client draws the same thresholds): the
-- BreathCheck cue lands WarnSeconds before the Creature's eye is at the slits (the window opens), the window lasts a
-- seeded PeekMin..PeekMax; WarnSeconds + PeekMax stays under the longest hold, so a player who starts holding when
-- warned always has the breath to outlast the peek. A release during the window with less than CalmFraction of the
-- lungs left is a gasp; any other release must be followed by holding again within ReholdGrace.
--
-- Pure (tests/Specs/Lockers.spec.luau): enterSchedule, exitSchedule, breathAt, setHeld, emptyAt, calm, pose.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DoorMotion = require(ReplicatedStorage.Shared.Sequence.DoorMotion)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local HideBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.HideBuilder)
local LockerBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.LockerBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

export type Phase = "Enter" | "Shut" | "Exit" | "Rip"

-- A hidden player's lungs: `value` seconds of breath at server time `at`, holding or not since then.
export type Breath = { value: number, held: boolean, at: number }

-- Server times of a move in or out: the door opens at openAt, the body is moved at moveAt, the door starts shutting
-- at closeAt and is shut at settledAt.
export type Schedule = { openAt: number, moveAt: number, closeAt: number, settledAt: number }

local OPEN_SECONDS = 0.34
local STEP_IN_SECONDS = 0.55
local STEP_OUT_SECONDS = 0.5
local CLOSE_SECONDS = 0.38
local RIP_SECONDS = 0.75

local LockerMotion = {}

LockerMotion.OpenSeconds = OPEN_SECONDS
LockerMotion.StepInSeconds = STEP_IN_SECONDS
LockerMotion.StepOutSeconds = STEP_OUT_SECONDS
LockerMotion.CloseSeconds = CLOSE_SECONDS
LockerMotion.RipSeconds = RIP_SECONDS

-- The lungs and the check.
LockerMotion.BreathMax = GameConfig.BreathHoldMaxSeconds
LockerMotion.DrainPerSecond = 1
LockerMotion.RecoverPerSecond = GameConfig.BreathRecoverPerSecond
LockerMotion.CalmFraction = 0.3 -- a release with at least this share of the lungs left is a quiet breath out
LockerMotion.ReholdGrace = 0.5 -- seconds a quiet breath (or a late start) may last while it is at the slits
LockerMotion.WarnSeconds = 0.9 -- from the BreathCheck cue to the window opening
LockerMotion.PeekMin = 3.5
LockerMotion.PeekMax = 6
LockerMotion.EmptyPeekSeconds = 1.3 -- how long it looks through the slits of an empty locker

-- OneShot args beyond DoorMotion's.
LockerMotion.Args = table.freeze({
	Phase = "phase",
	Occupant = "occupant",
})

-- PrivateCue "BreathCheck" args. `phase` is one of CuePhases.
LockerMotion.CueArgs = table.freeze({
	Phase = "phase",
	Breath = "breath", -- seconds of breath at `breathAt`
	Held = "held",
	BreathAt = "breathAt",
	WarnAt = "warnAt", -- server time the warning began (Window)
	Verdict = "verdict", -- Result: "HiddenSafe" | "Caught" | "Ended"
	Reason = "reason", -- Result: why (see HideSpotService.Reason)
})

LockerMotion.CuePhases = table.freeze({
	Window = "Window", -- startAt = the window opens, endsAt = it closes
	Meter = "Meter", -- the server's lungs after a hold changed (startAt = breathAt)
	Result = "Result", -- the check is over
})

LockerMotion.Phases = table.freeze({ "Enter", "Shut", "Exit", "Rip" } :: { Phase })

--------------------------------------------------------------------------------
-- Schedules
--------------------------------------------------------------------------------

-- Getting in: the door opens at `startAt`.
function LockerMotion.enterSchedule(startAt: number): Schedule
	local moveAt = startAt + OPEN_SECONDS
	local closeAt = moveAt + STEP_IN_SECONDS
	return { openAt = startAt, moveAt = moveAt, closeAt = closeAt, settledAt = closeAt + CLOSE_SECONDS }
end

-- Getting out: the door opens at `startAt`.
function LockerMotion.exitSchedule(startAt: number): Schedule
	local moveAt = startAt + OPEN_SECONDS
	local closeAt = moveAt + STEP_OUT_SECONDS
	return { openAt = startAt, moveAt = moveAt, closeAt = closeAt, settledAt = closeAt + CLOSE_SECONDS }
end

--------------------------------------------------------------------------------
-- Lungs
--------------------------------------------------------------------------------

-- A full pair of lungs, not holding, at `now`.
function LockerMotion.fullBreath(now: number): Breath
	return { value = LockerMotion.BreathMax, held = false, at = now }
end

-- Seconds of breath at server time `now` (never before `breath.at`).
function LockerMotion.breathAt(breath: Breath, now: number): number
	local elapsed = math.max(0, now - breath.at)
	if breath.held then
		return math.max(0, breath.value - LockerMotion.DrainPerSecond * elapsed)
	end
	return math.min(LockerMotion.BreathMax, breath.value + LockerMotion.RecoverPerSecond * elapsed)
end

-- The lungs from `now` on, holding or not. The same `held` keeps the record (and its `at`) unchanged.
function LockerMotion.setHeld(breath: Breath, held: boolean, now: number): Breath
	if breath.held == held then
		return breath
	end
	local at = math.max(now, breath.at)
	return { value = LockerMotion.breathAt(breath, at), held = held, at = at }
end

-- Server time a held breath runs out (nil while not holding).
function LockerMotion.emptyAt(breath: Breath): number?
	if not breath.held then
		return nil
	end
	return breath.at + breath.value / LockerMotion.DrainPerSecond
end

-- Whether letting go with `value` seconds of breath left is a quiet breath out (not a gasp).
function LockerMotion.calm(value: number): boolean
	return value >= LockerMotion.CalmFraction * LockerMotion.BreathMax - 1e-9
end

-- The lungs as a share of their capacity.
function LockerMotion.fraction(value: number): number
	return MathUtil.clamp01(value / LockerMotion.BreathMax)
end

--------------------------------------------------------------------------------
-- Door poses
--------------------------------------------------------------------------------

-- Poses `model`'s door for a motion of `mode` at `value` (Swing: openness; Smash: rip progress). False when the model
-- is not a locker.
local LEAF_WRENCH = 0.3 -- the share of a rip spent wrenching the leaf open
local LEAF_ARC = 1.2 -- studs the torn leaf rises over its flight

-- A barrel's lid or a cabinet's door `t` of the way through being torn off (0 shut .. 1 lying at its Landing).
local function rippedLeaf(model: Model, leaf: string, open: CFrame, t: number): boolean
	local base = model.PrimaryPart
	local rest = PropKit.leafRest(model, leaf)
	local landing = if base then base:FindFirstChild(leaf .. "Landing") else nil
	local progress = math.clamp(t, 0, 1)
	if not (base and rest and landing and landing:IsA("Attachment")) then
		return PropKit.poseLeaf(model, leaf, CFrame.new():Lerp(open, progress))
	end
	local landed = rest:ToObjectSpace(base.CFrame * landing.CFrame)
	if progress <= LEAF_WRENCH then
		local s = progress / LEAF_WRENCH
		return PropKit.poseLeaf(model, leaf, CFrame.new():Lerp(open, 1 - (1 - s) * (1 - s)))
	end
	local s = (progress - LEAF_WRENCH) / (1 - LEAF_WRENCH)
	return PropKit.poseLeaf(model, leaf, CFrame.new(0, 4 * LEAF_ARC * s * (1 - s), 0) * open:Lerp(landed, s))
end

function LockerMotion.pose(model: Model, mode: DoorMotion.Mode, value: number): boolean
	local kind = model:GetAttribute("HideKind")
	if kind == "Barrel" then
		if mode == "Smash" then
			return rippedLeaf(model, "Lid", HideBuilder.lidTransform(1), value)
		end
		return PropKit.poseLeaf(model, "Lid", HideBuilder.lidTransform(value))
	elseif kind == "Cabinet" then
		if mode == "Smash" then
			return rippedLeaf(model, "Door", HideBuilder.doorTransform(1), value)
		end
		return PropKit.poseLeaf(model, "Door", HideBuilder.doorTransform(value))
	end
	if mode == "Smash" then
		return LockerBuilder.setRipped(model, value)
	end
	return LockerBuilder.setDoor(model, value)
end

return table.freeze(LockerMotion)
