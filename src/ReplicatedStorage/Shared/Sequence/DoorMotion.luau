--!strict
-- DoorMotion: one fixture door's motion on server time, shared by DoorService (the server steps the anchored leaves
-- every Heartbeat, so collision follows the door) and DoorController (every client renders the same motion every
-- PreRender), so both sides pose identical leaves at the same server time and the server's final pose lands exactly
-- where the clients' rendering ends.
--
-- A motion moves one value from `from` to `to` over `seconds`, starting at server time `startAt`:
--   Swing  openness, 0 shut .. 1 fully open: the leaves swing about their hinges, the grille's sections slide up into
--          the housing (DoorBuilder.openTransform).
--   Smash  smash progress, 0 shut .. 1 smashed (DoorBuilder.smashedTransform). A door torn apart while it stands open
--          (`smashFrom` > 0, its openness at that moment) starts from that open pose and loses it as the leaves fly,
--          so nothing snaps shut first.
-- Before startAt a motion holds `from`; seconds <= 0 is a snap. Eases: Linear; InOut (smoothstep: a door closer, a
-- door opening); In (quadratic: a grille dropping under its own weight).
--
-- OneShot args (Types.OneShotArg values; DoorService encodes them, DoorController decodes them):
--   doorId, levelId   which door (the OneShot subject is the door model too)
--   mode, from, to, seconds, ease, smashFrom   the motion (startAt is the OneShot's)
--   motionId          per door, increasing: a client drops a message older than one it already played
--   state             the DoorState the door is in once this motion was decided
--   held              true: the server stopped the leaves short of a player at `to` (from = to, seconds = 0)
--
-- Pure (tests/Specs/Doors.spec.luau): ease, valueAt, endsAt, toArgs, fromArgs; transforms / pose / opennessOf read and
-- write a built door model through DoorBuilder + PropKit only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Types = require(ReplicatedStorage.Shared.Types)

local DoorBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.DoorBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local W = Attributes.World

export type Mode = "Swing" | "Smash"

export type Ease = "Linear" | "InOut" | "In"

export type Motion = {
	mode: Mode,
	from: number,
	to: number,
	startAt: number, -- server time
	seconds: number,
	ease: Ease,
	smashFrom: number, -- Smash: the openness the leaves are torn from (0 for Swing)
}

-- One door motion as it travels in a OneShot.
export type Message = {
	doorId: string,
	levelId: string,
	motionId: number,
	state: Enums.DoorState,
	held: boolean,
	motion: Motion,
}

local MODES: { Mode } = { "Swing", "Smash" }
local EASES: { Ease } = { "Linear", "InOut", "In" }

-- The longest motion a message may carry (anything longer is malformed).
local MAX_SECONDS = 30

local DoorMotion = {}

DoorMotion.Modes = table.freeze(table.clone(MODES))
DoorMotion.Eases = table.freeze(table.clone(EASES))
DoorMotion.MaxSeconds = MAX_SECONDS

--------------------------------------------------------------------------------
-- Timing
--------------------------------------------------------------------------------

-- `t` (0..1, clamped) through the ease curve; every curve starts at 0 and ends at 1.
function DoorMotion.ease(kind: Ease, t: number): number
	local x = math.clamp(t, 0, 1)
	if kind == "InOut" then
		return x * x * (3 - 2 * x)
	elseif kind == "In" then
		return x * x
	end
	return x
end

-- Server time the motion ends at.
function DoorMotion.endsAt(motion: Motion): number
	return motion.startAt + math.max(0, motion.seconds)
end

-- The motion's value at server time `now`, and whether it has finished. It holds `from` until startAt; a motion of
-- zero seconds is at `to` from its startAt on.
function DoorMotion.valueAt(motion: Motion, now: number): (number, boolean)
	if now < motion.startAt then
		return motion.from, false
	end
	if motion.seconds <= 0 then
		return motion.to, true
	end
	local t = (now - motion.startAt) / motion.seconds
	if t >= 1 then
		return motion.to, true
	end
	return motion.from + (motion.to - motion.from) * DoorMotion.ease(motion.ease, t), false
end

--------------------------------------------------------------------------------
-- Poses
--------------------------------------------------------------------------------

-- Every leaf's transform from its rest pivot for `mode` at `value`, by leaf name (leaves without poses are left out).
function DoorMotion.transforms(model: Model, mode: Mode, value: number, smashFrom: number?): { [string]: CFrame }
	local out: { [string]: CFrame } = {}
	local from = math.clamp(smashFrom or 0, 0, 1)
	for _, name in DoorBuilder.leafNames(model) do
		if mode == "Smash" then
			local smashed = DoorBuilder.smashedTransform(model, name, value)
			if smashed and from > 0 then
				local open = DoorBuilder.openTransform(model, name, from)
				if open then
					-- the open swing unwinds as the leaf is torn away: exactly the open pose at 0, the smashed one at 1
					smashed = smashed * CFrame.new():Lerp(open, 1 - DoorMotion.ease("InOut", value))
				end
			end
			if smashed then
				out[name] = smashed
			end
		else
			local open = DoorBuilder.openTransform(model, name, value)
			if open then
				out[name] = open
			end
		end
	end
	return out
end

-- Poses every leaf of `model` for `mode` at `value`. False when the door has no leaves or a leaf has no poses.
function DoorMotion.pose(model: Model, mode: Mode, value: number, smashFrom: number?): boolean
	local names = DoorBuilder.leafNames(model)
	if #names == 0 then
		return false
	end
	local transforms = DoorMotion.transforms(model, mode, value, smashFrom)
	local ok = true
	for _, name in names do
		local transform = transforms[name]
		if not (transform and PropKit.poseLeaf(model, name, transform)) then
			ok = false
		end
	end
	return ok
end

-- How far open `model` stands now (0 shut .. 1 fully open), measured on its first leaf against its fully open pose.
function DoorMotion.opennessOf(model: Model): number
	local name = DoorBuilder.leafNames(model)[1]
	if not name then
		return 0
	end
	local current = PropKit.leafTransform(model, name)
	local full = DoorBuilder.openTransform(model, name, 1)
	if not (current and full) then
		return 0
	end
	if model:GetAttribute(W.DoorKind) == "Gate" then
		local travel = full.Position
		local length = travel:Dot(travel)
		if length < 1e-8 then
			return 0
		end
		return math.clamp(current.Position:Dot(travel) / length, 0, 1)
	end
	local _, fullAngle = full:ToAxisAngle()
	local _, angle = current:ToAxisAngle()
	fullAngle = math.abs(MathUtil.wrapAngle(fullAngle))
	angle = math.abs(MathUtil.wrapAngle(angle))
	if fullAngle < 1e-6 then
		return 0
	end
	return math.clamp(angle / fullAngle, 0, 1)
end

--------------------------------------------------------------------------------
-- OneShot args
--------------------------------------------------------------------------------

function DoorMotion.toArgs(message: Message): { [string]: Types.OneShotArg }
	local motion = message.motion
	return {
		doorId = message.doorId,
		levelId = message.levelId,
		motionId = message.motionId,
		state = message.state,
		held = message.held,
		mode = motion.mode,
		from = motion.from,
		to = motion.to,
		seconds = motion.seconds,
		ease = motion.ease,
		smashFrom = motion.smashFrom,
	}
end

local function unit(value: unknown): number?
	if type(value) == "number" and MathUtil.isFinite(value) and value >= 0 and value <= 1 then
		return value
	end
	return nil
end

-- The message in OneShot `args` that started at server time `startAt`, or nil when anything is malformed.
function DoorMotion.fromArgs(args: { [string]: any }, startAt: number): Message?
	local doorId, levelId, motionId = args.doorId, args.levelId, args.motionId
	local from, to, seconds = unit(args.from), unit(args.to), args.seconds
	local smashFrom = if args.smashFrom == nil then 0 else unit(args.smashFrom)
	if type(doorId) ~= "string" or type(levelId) ~= "string" then
		return nil
	end
	if type(motionId) ~= "number" or not MathUtil.isFinite(motionId) then
		return nil
	end
	if not (from and to and smashFrom) or not MathUtil.isFinite(startAt) then
		return nil
	end
	if type(seconds) ~= "number" or not MathUtil.isFinite(seconds) or seconds < 0 or seconds > MAX_SECONDS then
		return nil
	end
	if not (Enums.has(MODES, args.mode) and Enums.has(EASES, args.ease) and Enums.has(Enums.DoorState, args.state)) then
		return nil
	end
	return {
		doorId = doorId,
		levelId = levelId,
		motionId = motionId,
		state = args.state :: Enums.DoorState,
		held = args.held == true,
		motion = {
			mode = args.mode :: Mode,
			from = from,
			to = to,
			startAt = startAt,
			seconds = seconds,
			ease = args.ease :: Ease,
			smashFrom = smashFrom,
		},
	}
end

return table.freeze(DoorMotion)
