--!strict
-- JumpscareHandler: the Creature's catch, on the server (spec §5 first-person jumpscare, §6 downed). MonsterAIService's
-- states call Catch when the Creature reaches its target; this module runs the whole moment and reports how it ended.
-- One catch at a time (IsBusy); the brain must leave the Creature's body alone while one runs.
--
-- Catch(creature, player, kind) validates first (validate, pure): nothing else is being caught, `kind` is a
-- JumpscareKind, the Creature is in the world with a root, not Hidden and not Stunned, the victim is playing
-- (LifeStateService: Alive or Downed) with a living character, holds no Jumpscare lock already, is not in a
-- cutscene, and stands within MaxReach of the Creature. A refused catch changes nothing and returns false. Then:
--   1. Lock. CharacterService.Lock(victim, "Jumpscare", "Anchor"): collision Locked, the root anchored by the server.
--   2. Face to face (facePair, pure). The victim's root turns in place to face the Creature (CharacterService.Teleport,
--      so the move is announced); the Creature's root is anchored for the moment (kinematic) and set on the line
--      between them at the kind's spacing (FaceDistance plus how far that pose carries its face ahead of its root, for
--      Hallway / Locker / Vent / Underwater), facing the victim, at its own height. It only ever closes in, unless it
--      stands closer than the kind's minimum, where it is eased back out to it.
--   3. Moments, all at startAt = now + GameConfig.OneShotLead (schedule, pure): OneShot "Jumpscare" (subject = the
--      victim's character; args kind, userId, position) for every client (CreatureController plays the Lunge,
--      JumpscareController shakes and stings everyone nearby); PrivateCue "JumpscareVictim" (args kind, face: the
--      Creature's face point after step 2) to the victim, endsAt = the end of the hold; AudioService Screech at the
--      Creature's face for everyone and JumpscareSting (2D) for the victim.
--   4. At resolveAt = startAt + LungeSeconds + HoldSeconds (CreatureConfig.Jumpscare), the outcome (outcomeFor, pure):
--      LifeStateService.Down(victim, "Creature") for an Alive victim never downed this run (DownedCount 0), else
--      LifeStateService.Execute(victim, "Creature"). Then Unlock, the Creature's root back to how it was anchored (its
--      network ownership reasserted to the server once it is free again), and Finished(victim, kind, outcome).
-- Aborts. The victim leaving (Players.PlayerRemoving, or OnPlayerRemoving), losing their character, or no longer
-- playing (a bleedout running out, EndRun sending everyone to the lobby), the match leaving Deploying / InRun
-- (RunLifecycleService.PhaseChanged, or EndRun), the Creature leaving the world, or Abort(reason): no outcome is
-- applied; the screech and sting are cut, the victim (when still here) gets a JumpscareVictim cue with aborted = true,
-- the lock and the Creature are released as above, and Finished fires with "Aborted". The listeners live only while a
-- catch runs (its own trove) and are dropped before the outcome lands, so the Down / Execute it causes never reads as
-- an abort.
--
-- Not a service: it wires itself per catch and needs no lifecycle calls (OnPlayerRemoving / EndRun are exposed and
-- idempotent for a host that wants to call them). MonsterAIService stays the only writer of the Creature's
-- attributes; this module only moves its root. SetClock swaps the time source so specs run a catch on a fake clock.
--
-- Pure rules (tests/Specs/Jumpscare.spec.luau): validate, outcomeFor, schedule, spacing, facePair, faceOffset,
-- oneShotEvent, victimCue, abortCue.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)

local log = Log.new("Jumpscare")

local C = Attributes.Creature
local J = CreatureConfig.Jumpscare
local NAMES = CreatureRigBuilder.PartNames

local CAUSE = "Creature"
local LOCK_REASON: Enums.ControlLock = "Jumpscare"
local LOCK_MODE: Enums.LockMode = "Anchor"
local ONESHOT_KIND: Enums.OneShotKind = "Jumpscare"
local CUE_KIND: Enums.CueKind = "JumpscareVictim"
local SCREECH_PRESET = "Screech"
local STING_PRESET = "JumpscareSting"
local STUNNED: Enums.MonsterState = "Stunned"
local DEFAULT_POSE: Enums.PoseMode = "Biped"
local MAX_REACH = 12 -- studs between the roots; a catch from further away is a bug upstream, never honoured
local CUT_FADE = 0.15 -- seconds the screech and sting fade over when a catch is aborted
local FALLBACK_FACE_LEAD = 0.6 -- studs ahead of the root the face is assumed to be when the rig has no face point
local MIN_DIRECTION = 1e-3
local LIVE_PHASES: { [string]: boolean } = { Deploying = true, InRun = true }

export type Clock = LifeStateService.Clock

export type Outcome = "Downed" | "Executed" | "Aborted"

-- When the moment plays, in server time: every client starts at startAt; the lunge ends at lungeEndsAt and the hold
-- (and the catch) at resolveAt.
export type Schedule = { startAt: number, lungeEndsAt: number, resolveAt: number }

-- Root-to-root horizontal distance the Creature is set at for a kind: `distance`, never closer than `minimum`.
export type Spacing = { distance: number, minimum: number }

-- Everything validate looks at (gathered by Catch; specs build it by hand).
export type CatchCheck = {
	busy: boolean, -- a catch is already running
	kind: string,
	creatureInWorld: boolean, -- the Creature model is in Workspace with a root part
	hidden: boolean, -- the Creature's Hidden attribute
	monsterState: string, -- the Creature's MonsterState attribute
	lifeState: Enums.LifeState, -- the victim's
	hasBody: boolean, -- the victim has a living character with a root
	caught: boolean, -- the victim already holds a Jumpscare lock
	controlLock: Enums.ControlLock, -- the victim's highest held lock
	distance: number, -- studs between the Creature's root and the victim's
}

type Sequence = {
	victim: Player,
	kind: Enums.JumpscareKind,
	creature: Model,
	creatureRoot: BasePart,
	wasAnchored: boolean,
	schedule: Schedule,
	trove: Trove.Trove,
	timer: thread?,
	screech: AudioService.CueHandle?,
	sting: AudioService.CueHandle?,
	settled: boolean,
}

local SPACING: { [string]: Spacing } = {
	-- Standing: the hunched face rides up to a stud ahead of the root.
	Hallway = { distance = J.FaceDistance + 0.8, minimum = J.FaceDistance + 0.3 },
	-- Reaching in through the ripped-open door: the door frame stands between the two roots.
	Locker = { distance = J.FaceDistance + 1.4, minimum = J.FaceDistance + 0.8 },
	-- On all fours in the bore: the head leads the body down the duct.
	Vent = { distance = J.FaceDistance + 1.2, minimum = J.FaceDistance + 0.7 },
	-- Swimming level: the head leads the long body through the water.
	Underwater = { distance = J.FaceDistance + 1.0, minimum = J.FaceDistance + 0.4 },
}

local JumpscareHandler = {}

JumpscareHandler.Cause = CAUSE
JumpscareHandler.MaxReach = MAX_REACH

local finished: Signal.Signal<Player, Enums.JumpscareKind, string> = Signal.new()

-- (victim, kind, outcome) once a catch is over: "Downed", "Executed" or "Aborted".
JumpscareHandler.Finished = finished

local realClock: Clock = {
	now = function(): number
		return Workspace:GetServerTimeNow()
	end,
	delay = function(seconds: number, callback: () -> ()): thread
		return task.delay(seconds, callback)
	end,
	cancel = function(thread: thread)
		if coroutine.status(thread) == "suspended" then
			task.cancel(thread)
		end
	end,
}

local clock: Clock = realClock
local active: Sequence? = nil
local oneShotSeq = 0

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Jumpscare.spec.luau)
--------------------------------------------------------------------------------

-- Whether a catch may start, and why not.
function JumpscareHandler.validate(check: CatchCheck): (boolean, string?)
	if check.busy then
		return false, "Busy"
	end
	if not Enums.has(Enums.JumpscareKind, check.kind) then
		return false, "Kind"
	end
	if not check.creatureInWorld then
		return false, "NoCreature"
	end
	if check.hidden then
		return false, "Hidden"
	end
	if check.monsterState == STUNNED then
		return false, "Stunned"
	end
	if not LifeStateService.isPlayingState(check.lifeState) then
		return false, "NotPlaying"
	end
	if not check.hasBody then
		return false, "NoBody"
	end
	if check.caught then
		return false, "Caught"
	end
	if check.controlLock == "Cutscene" then
		return false, "Cutscene"
	end
	if not MathUtil.isFinite(check.distance) or check.distance > MAX_REACH then
		return false, "TooFar"
	end
	return true, nil
end

-- What a catch does to a victim in `lifeState` who has gone down `downedCount` times this run: the first catch of an
-- Alive victim downs them, every later one (or one on a Downed victim) executes; nil when they are not playing.
function JumpscareHandler.outcomeFor(lifeState: Enums.LifeState, downedCount: number): Outcome?
	if lifeState == "Alive" then
		return if downedCount <= 0 then "Downed" else "Executed"
	elseif lifeState == "Downed" then
		return "Executed"
	end
	return nil
end

-- The moment's timings for a catch starting at server time `now`.
function JumpscareHandler.schedule(now: number): Schedule
	local startAt = now + GameConfig.OneShotLead
	local lungeEndsAt = startAt + J.LungeSeconds
	return { startAt = startAt, lungeEndsAt = lungeEndsAt, resolveAt = lungeEndsAt + J.HoldSeconds }
end

-- The kind's spacing (unknown kinds use Hallway's).
function JumpscareHandler.spacing(kind: string): Spacing
	return SPACING[kind] or SPACING.Hallway
end

-- The two roots face to face: the victim turned in place toward the Creature, and the Creature on the horizontal line
-- between them at the kind's spacing (clamped between its minimum and distance, so it only closes in unless it is too
-- close), at its own height, facing the victim. Both stay upright. Stacked roots use the victim's facing.
function JumpscareHandler.facePair(victim: CFrame, creature: CFrame, kind: string): (CFrame, CFrame)
	local from = victim.Position
	local offset = creature.Position - from
	if not (MathUtil.isFiniteVector(from) and MathUtil.isFiniteVector(offset)) then
		return victim, creature
	end
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local distance = flat.Magnitude
	local direction: Vector3
	if distance > MIN_DIRECTION then
		direction = flat / distance
	else
		local look = victim.LookVector
		local lookFlat = Vector3.new(look.X, 0, look.Z)
		direction = if lookFlat.Magnitude > MIN_DIRECTION then lookFlat.Unit else Vector3.new(0, 0, -1)
	end
	local spacing = JumpscareHandler.spacing(kind)
	local at = from + direction * math.clamp(distance, spacing.minimum, spacing.distance) + Vector3.new(0, offset.Y, 0)
	return CFrame.lookAt(from, from + direction), CFrame.lookAt(at, at - direction)
end

-- The Creature's face point in its root's space: from the rig's face attachment (world `faceWorld`, as the server sees
-- it), else EyeHeightAboveRoot for `poseMode`, FALLBACK_FACE_LEAD ahead, facing forward.
function JumpscareHandler.faceOffset(rootCFrame: CFrame, faceWorld: CFrame?, poseMode: string): CFrame
	if faceWorld ~= nil and MathUtil.isFiniteVector(faceWorld.Position) then
		return rootCFrame:ToObjectSpace(faceWorld)
	end
	local height = CreatureConfig.EyeHeightAboveRoot[poseMode] or CreatureConfig.EyeHeightAboveRoot[DEFAULT_POSE]
	return CFrame.new(0, height, -FALLBACK_FACE_LEAD)
end

-- OneShot "Jumpscare" for every client.
function JumpscareHandler.oneShotEvent(
	seq: number,
	kind: Enums.JumpscareKind,
	subject: Instance?,
	schedule: Schedule,
	victimUserId: number,
	position: Vector3
): Types.OneShotEvent
	return {
		seq = seq,
		kind = ONESHOT_KIND,
		subject = subject,
		startAt = schedule.startAt,
		args = { kind = kind, userId = victimUserId, position = position },
	}
end

-- PrivateCue "JumpscareVictim" for the victim: the face to lock onto and the hold's end.
function JumpscareHandler.victimCue(
	kind: Enums.JumpscareKind,
	schedule: Schedule,
	face: Vector3
): Types.PrivateCuePayload
	return {
		kind = CUE_KIND,
		startAt = schedule.startAt,
		endsAt = schedule.resolveAt,
		args = { kind = kind, face = face },
	}
end

-- PrivateCue "JumpscareVictim" telling the victim the catch was called off at server time `now`.
function JumpscareHandler.abortCue(kind: Enums.JumpscareKind, now: number): Types.PrivateCuePayload
	return {
		kind = CUE_KIND,
		startAt = now,
		endsAt = now,
		args = { kind = kind, aborted = true },
	}
end

--------------------------------------------------------------------------------
-- Instance helpers
--------------------------------------------------------------------------------

local function creatureRootOf(creature: Model): BasePart?
	local root = creature:FindFirstChild(NAMES.Root)
	if root and root:IsA("BasePart") then
		return root
	end
	local primary = creature.PrimaryPart
	return if primary then primary else nil
end

local function livingRoot(player: Player): BasePart?
	local root = Instances.characterRoot(player)
	local humanoid = Instances.characterHumanoid(player)
	if root and humanoid and humanoid.Health > 0 then
		return root
	end
	return nil
end

-- The face point the rig carries (FaceFrontAttachment on the Head), in world space as the server sees it.
local function faceWorldOf(creature: Model): CFrame?
	local face = creature:FindFirstChild(NAMES.FaceAttachment, true)
	if face and face:IsA("Attachment") then
		return PropKit.attachmentWorld(face)
	end
	return nil
end

-- Puts the Creature's server ownership back after its anchor changed (ARCHITECTURE §4c).
local function reassertOwnership(root: BasePart)
	if root.Anchored or not root:IsDescendantOf(Workspace) then
		return
	end
	local allowed = root:CanSetNetworkOwnership()
	if not allowed then
		return
	end
	local ok, err = pcall(function()
		root:SetNetworkOwner(nil)
	end)
	if not ok then
		log.warnThrottled("owner", 30, "could not reassert the Creature's network owner: %s", tostring(err))
	end
end

local function releaseCreature(sequence: Sequence)
	local root = sequence.creatureRoot
	if root.Parent == nil then
		return
	end
	if root.Anchored ~= sequence.wasAnchored then
		root.Anchored = sequence.wasAnchored
	end
	reassertOwnership(root)
end

local function cutCues(sequence: Sequence)
	for _, handle in { sequence.screech, sequence.sting } do
		if handle then
			handle:Stop(CUT_FADE)
		end
	end
	sequence.screech = nil
	sequence.sting = nil
end

--------------------------------------------------------------------------------
-- The catch
--------------------------------------------------------------------------------

-- Ends `sequence` with `outcome`: listeners off first, then the outcome, the release and the signal.
local function settle(sequence: Sequence, outcome: Outcome, reason: string?)
	if active ~= sequence or sequence.settled then
		return
	end
	sequence.settled = true
	sequence.trove:Destroy()
	local timer = sequence.timer
	sequence.timer = nil
	if timer then
		clock.cancel(timer)
	end
	local victim = sequence.victim
	if outcome == "Downed" then
		LifeStateService.Down(victim, CAUSE)
	elseif outcome == "Executed" then
		LifeStateService.Execute(victim, CAUSE)
	else
		cutCues(sequence)
		if victim.Parent == Players then
			Net.Server.fire("PrivateCue", victim, JumpscareHandler.abortCue(sequence.kind, clock.now()))
		end
	end
	CharacterService.Unlock(victim, LOCK_REASON)
	releaseCreature(sequence)
	active = nil
	if outcome == "Aborted" then
		log.info("catch of %s (%s) aborted: %s", victim.Name, sequence.kind, reason or "requested")
	else
		log.info("%s caught (%s): %s", victim.Name, sequence.kind, outcome)
	end
	finished:Fire(victim, sequence.kind, outcome)
end

local function abortSequence(sequence: Sequence, reason: string)
	settle(sequence, "Aborted", reason)
end

local function resolve(sequence: Sequence)
	if active ~= sequence or sequence.settled then
		return
	end
	local victim = sequence.victim
	local outcome: Outcome? =
		JumpscareHandler.outcomeFor(LifeStateService.GetState(victim), LifeStateService.GetDownedCount(victim))
	if outcome == nil then
		abortSequence(sequence, "NotPlaying")
		return
	end
	-- A cast, not the refined local: refining the union against nil widens it to string.
	settle(sequence, outcome :: Outcome, nil)
end

-- The abort listeners, for as long as `sequence` runs.
local function watch(sequence: Sequence)
	local trove = sequence.trove
	local victim = sequence.victim
	local creature = sequence.creature
	trove:Connect(Players.PlayerRemoving, function(player: Player)
		if player == victim then
			abortSequence(sequence, "Left")
		end
	end)
	trove:Add(CharacterService.CharacterRemoving:Connect(function(player: Player, _model: Model)
		if player == victim then
			abortSequence(sequence, "Character")
		end
	end))
	trove:Add(
		LifeStateService.StateChanged:Connect(
			function(player: Player, state: Enums.LifeState, _previous: Enums.LifeState)
				if player == victim and not LifeStateService.isPlayingState(state) then
					abortSequence(sequence, "LifeState")
				end
			end
		)
	)
	trove:Add(RunLifecycleService.PhaseChanged:Connect(function(phase: Enums.MatchPhase)
		if not LIVE_PHASES[phase] then
			abortSequence(sequence, "RunEnded")
		end
	end))
	trove:Connect(creature.AncestryChanged, function()
		if not creature:IsDescendantOf(Workspace) then
			abortSequence(sequence, "Creature")
		end
	end)
end

local function begin(
	creature: Model,
	creatureRoot: BasePart,
	victim: Player,
	victimRoot: BasePart,
	kind: Enums.JumpscareKind
)
	local now = clock.now()
	local schedule = JumpscareHandler.schedule(now)
	local sequence: Sequence = {
		victim = victim,
		kind = kind,
		creature = creature,
		creatureRoot = creatureRoot,
		wasAnchored = creatureRoot.Anchored,
		schedule = schedule,
		trove = Trove.new(),
		timer = nil,
		screech = nil,
		sting = nil,
		settled = false,
	}
	active = sequence

	-- 1. The victim is held by the server.
	CharacterService.Lock(victim, LOCK_REASON, LOCK_MODE)

	-- 2. Face to face.
	local poseMode = Attributes.getString(creature, C.PoseMode, DEFAULT_POSE)
	local faceInRoot = JumpscareHandler.faceOffset(creatureRoot.CFrame, faceWorldOf(creature), poseMode)
	local victimTarget, creatureTarget = JumpscareHandler.facePair(victimRoot.CFrame, creatureRoot.CFrame, kind)
	if not CharacterService.Teleport(victim, victimTarget) then
		log.debug("%s has no managed character to turn; held as they stand", victim.Name)
	end
	if not creatureRoot.Anchored then
		creatureRoot.Anchored = true
	end
	creatureRoot.CFrame = creatureTarget
	local face = (creatureTarget * faceInRoot).Position

	-- 3. The moment, for everyone and for the victim.
	oneShotSeq += 1
	Net.Server.fireAll(
		"OneShot",
		JumpscareHandler.oneShotEvent(
			oneShotSeq,
			kind,
			victim.Character,
			schedule,
			victim.UserId,
			victimTarget.Position
		)
	)
	if victim.Parent == Players then
		Net.Server.fire("PrivateCue", victim, JumpscareHandler.victimCue(kind, schedule, face))
	end
	sequence.screech = AudioService.PlayAt(SCREECH_PRESET, face)
	sequence.sting = AudioService.PlayFor(victim, STING_PRESET)

	-- 4. The outcome when the hold ends, unless something calls it off first.
	watch(sequence)
	sequence.timer = clock.delay(schedule.resolveAt - now, function()
		sequence.timer = nil
		resolve(sequence)
	end)
	log.debug("%s caught by the Creature (%s); resolves at %.2f", victim.Name, kind, schedule.resolveAt)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Starts the catch of `player` by `creature` (see the header). False, with nothing changed, when it is refused.
function JumpscareHandler.Catch(creature: Model, player: Player, kind: Enums.JumpscareKind): boolean
	local creatureRoot = if typeof(creature) == "Instance" and creature:IsA("Model")
		then creatureRootOf(creature)
		else nil
	local victimRoot = if typeof(player) == "Instance" and player:IsA("Player") then livingRoot(player) else nil
	local distance = if creatureRoot and victimRoot
		then (creatureRoot.CFrame.Position - victimRoot.CFrame.Position).Magnitude
		else math.huge
	local ok, reason = JumpscareHandler.validate({
		busy = active ~= nil,
		kind = kind,
		creatureInWorld = creatureRoot ~= nil and creature:IsDescendantOf(Workspace),
		hidden = creatureRoot ~= nil and Attributes.getBool(creature, C.Hidden, false),
		monsterState = if creatureRoot then Attributes.getString(creature, C.MonsterState, "") else "",
		lifeState = if victimRoot then LifeStateService.GetState(player) else "Lobby",
		hasBody = victimRoot ~= nil,
		caught = victimRoot ~= nil and CharacterService.LockCount(player, LOCK_REASON) > 0,
		controlLock = if victimRoot then CharacterService.GetLock(player) else "None",
		distance = distance,
	})
	if not ok or not (creatureRoot and victimRoot) then
		log.debug("catch of %s refused: %s", tostring(player), tostring(reason))
		return false
	end
	begin(creature, creatureRoot, player, victimRoot, kind)
	return true
end

-- Whether a catch is running.
function JumpscareHandler.IsBusy(): boolean
	return active ~= nil
end

-- The player being caught right now, if any.
function JumpscareHandler.GetVictim(): Player?
	local sequence = active
	return if sequence then sequence.victim else nil
end

-- Calls off the running catch (no outcome; Finished fires "Aborted"). False when nothing is running.
function JumpscareHandler.Abort(reason: string?): boolean
	local sequence = active
	if not sequence then
		return false
	end
	abortSequence(sequence, reason or "Requested")
	return true
end

-- Aborts the catch of a leaving victim (also done on Players.PlayerRemoving; idempotent).
function JumpscareHandler.OnPlayerRemoving(player: Player)
	local sequence = active
	if sequence and sequence.victim == player then
		abortSequence(sequence, "Left")
	end
end

-- Aborts any catch when the run ends (also done on RunLifecycleService.PhaseChanged; idempotent).
function JumpscareHandler.EndRun()
	local sequence = active
	if sequence then
		abortSequence(sequence, "RunEnded")
	end
end

-- Replaces the time source (specs pass a fake clock; nil restores server time + task.delay).
function JumpscareHandler.SetClock(fake: Clock?)
	clock = fake or realClock
end

return table.freeze(JumpscareHandler)
