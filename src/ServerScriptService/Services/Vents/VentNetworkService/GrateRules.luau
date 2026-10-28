--!strict
-- GrateRules: VentNetworkService's pure grate rules (specs: tests/Specs/VentNetwork.spec.luau).
--
-- States (Enums.GrateState): Closed (screwed shut), Unscrewing (a player is holding Unscrew), Open (unscrewed, the
-- panel swung out), Kicked (torn off its hinges), Locked (rusted shut by the run plan). Open and Kicked let crawlers
-- through; the other three do not.
--
-- Player events (nextState):
--   Closed     --UnscrewBegin-->    Unscrewing
--   Unscrewing --UnscrewCancel-->   Closed
--   Unscrewing --UnscrewComplete--> Open
--   Closed     --Kick-->            Kicked
-- Nothing else applies: a locked grate refuses both prompts, an open one has nothing left to do, and nobody kicks a
-- grate someone is unscrewing.
--
-- Prompts. Both prompts are served while the grate is Closed, Unscrewing (the running hold needs its prompt) or Locked
-- (so a player gets "Rusted shut" instead of silence), and closed for good once it is Open or Kicked. Unscrew is for
-- an Alive player while the grate is Closed, or for the player already holding it while it is Unscrewing; Kick is
-- for an Alive player while it is Closed. A locked grate refuses with the Strings key Prompt.GrateLocked, which
-- InteractionService shows to the player.
--
-- Forced changes (ForceGrate: scripts, the Creature, dev commands) may set any state but Unscrewing (there is no hold
-- to drive it). Open and Kicked are both open: forcing one onto the other changes nothing.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

export type GrateEvent = "UnscrewBegin" | "UnscrewCancel" | "UnscrewComplete" | "Kick"

-- "Apply": make the change. "Same": already in that state. "AlreadyOpen": Open <-> Kicked (both open).
-- "NotForcible": Unscrewing (or an unknown state) cannot be forced.
export type ForceVerdict = "Apply" | "Same" | "AlreadyOpen" | "NotForcible"

-- Everything the Unscrew rule looks at for one player and one grate (state nil: the grate is not tracked).
export type UnscrewCheck = {
	state: Enums.GrateState?,
	lifeState: Enums.LifeState,
	channelling: boolean, -- this player is the one holding this grate's Unscrew
}

export type KickCheck = {
	state: Enums.GrateState?,
	lifeState: Enums.LifeState,
}

-- "Out" decelerates (a swinging panel, screws running in); "Linear" hands the pose function raw time (setKicked
-- shapes its own throw).
export type Ease = "Out" | "Linear"

-- A pose moving from `from` to `to` over `seconds`, `delay` seconds after it was started, `elapsed` seconds ago.
export type Motion = {
	from: number,
	to: number,
	delay: number,
	seconds: number,
	elapsed: number,
	ease: Ease,
}

local LOCKED_REASON = "Prompt.GrateLocked"
local PANEL_SECONDS = 0.6 -- an unscrewed panel swinging open (or shut again)
local KICK_SECONDS = 0.35 -- a kicked panel tearing off and landing
local SCREW_RESET_SECONDS = 0.25 -- an abandoned unscrew: the screws run back in

local TRANSITIONS: { [string]: { [string]: Enums.GrateState } } = {
	Closed = { UnscrewBegin = "Unscrewing", Kick = "Kicked" },
	Unscrewing = { UnscrewCancel = "Closed", UnscrewComplete = "Open" },
}

local SERVES: { [string]: boolean } = { Closed = true, Unscrewing = true, Locked = true }
local OPEN: { [string]: boolean } = { Open = true, Kicked = true }

local GrateRules = {}

GrateRules.LockedReason = LOCKED_REASON
GrateRules.PanelSeconds = PANEL_SECONDS
GrateRules.KickSeconds = KICK_SECONDS
GrateRules.ScrewResetSeconds = SCREW_RESET_SECONDS

-- The state a grate in `state` moves to on a player's `event`, or nil when the event does not apply.
function GrateRules.nextState(state: Enums.GrateState, event: GrateEvent): Enums.GrateState?
	local row = TRANSITIONS[state]
	return if row then row[event] else nil
end

-- Open or Kicked: a crawler can pass.
function GrateRules.isOpen(state: Enums.GrateState): boolean
	return OPEN[state] == true
end

-- Whether a grate in `state` offers its Unscrew / Kick prompts.
function GrateRules.servesPrompts(state: Enums.GrateState): boolean
	return SERVES[state] == true
end

-- Whether a player may unscrew (start, or finish their own hold), and why not.
function GrateRules.unscrewEligible(check: UnscrewCheck): (boolean, string?)
	local state = check.state
	if state == nil then
		return false, "Removed"
	end
	if state == "Locked" then
		return false, LOCKED_REASON
	end
	if check.lifeState ~= "Alive" then
		return false, "LifeState"
	end
	if state == "Closed" then
		return true, nil
	end
	if state == "Unscrewing" then
		if check.channelling then
			return true, nil
		end
		return false, "Busy"
	end
	return false, "Open"
end

-- Whether a player may kick the grate, and why not.
function GrateRules.kickEligible(check: KickCheck): (boolean, string?)
	local state = check.state
	if state == nil then
		return false, "Removed"
	end
	if state == "Locked" then
		return false, LOCKED_REASON
	end
	if check.lifeState ~= "Alive" then
		return false, "LifeState"
	end
	if state == "Closed" then
		return true, nil
	end
	if state == "Unscrewing" then
		return false, "Busy"
	end
	return false, "Open"
end

-- What forcing a grate from `from` to `to` does (see ForceVerdict).
function GrateRules.forceVerdict(from: Enums.GrateState, to: Enums.GrateState): ForceVerdict
	if to == "Unscrewing" or not Enums.has(Enums.GrateState, to) then
		return "NotForcible"
	end
	if from == to then
		return "Same"
	end
	if OPEN[from] and OPEN[to] then
		return "AlreadyOpen"
	end
	return "Apply"
end

-- How far a hold that started at `startedAt` and lasts `duration` seconds has got at `now` (0..1).
function GrateRules.unscrewProgress(now: number, startedAt: number, duration: number): number
	if not (duration > 0) then
		return 1
	end
	return math.clamp((now - startedAt) / duration, 0, 1)
end

-- A motion's value now, and whether it has finished. Before its delay it holds `from`; after it, it moves toward
-- `to` (eased out, or linearly).
function GrateRules.motionValue(motion: Motion): (number, boolean)
	local seconds = math.max(motion.seconds, 1e-3)
	local t = math.clamp((motion.elapsed - motion.delay) / seconds, 0, 1)
	local shaped = if motion.ease == "Out" then 1 - (1 - t) * (1 - t) else t
	return motion.from + (motion.to - motion.from) * shaped, motion.elapsed >= motion.delay + seconds
end

return table.freeze(GrateRules)
