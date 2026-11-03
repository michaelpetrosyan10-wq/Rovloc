--!strict
-- MovementAuthority: server-side validation of client-owned character movement (docs/ARCHITECTURE.md §4c).
--
-- Who is checked. At GameConfig.ServerTickHz, every participant of the live run who is Alive or Downed and whose
-- character's root is unanchored, owned by that player (GetNetworkOwner), not in the Locked collision mode, under no
-- control lock, and not exempt (Exempt / Unexempt, per token, optionally timed, for scripted moves). Leaving any of
-- those conditions, CharacterService.Moved (every Spawn / Teleport, corrections included) and a new character all
-- reset the baseline. After a server move the checks wait until the client has taken it (the root is closer to the
-- server's position than to where it came from, and within reach of it: settled, pure) and resume from there; a
-- client that still has not taken it after SettleSeconds is judged from the server's position.
--
-- Checks. Registered validators (RegisterValidator, P4's vent rail) run first, in registration order; the first one
-- that answers Correct or Strike decides the tick. If they all answer Ok the built-in checks judge the step from the
-- last accepted position (judge, pure), in this order:
--   Teleport  horizontal displacement > allowed × dt + 6 studs                                              → Strike
--   Noclip    the path from the last accepted position is walled off for the whole capsule: the root-height ray
--             and two rays offset sideways by CapsuleRadius all hit solid geometry the player collides with
--             (SpatialQuery.worldParams: the Players group, so Default + MonsterPassthrough; characters and the
--             Creature are excluded, NoCollide volumes never register)                                       → Strike
--   Fly       airborne (Humanoid.FloorMaterial Air, on-foot mode only) for more than 0.5 s and rising faster
--             than a jump still could (jump velocity minus gravity × airborne time, plus 3 studs/s)          → Strike
--   Speed     horizontal speed over allowed, accumulated as surplus distance (floored at 0) so a lone late
--             packet never rubber-bands anyone; surplus past OverspeedTolerance studs                       → Correct
-- allowed = max(WalkSpeed now, WalkSpeed before its last change while that change is under 0.6 s old) × 1.25 + 3
-- studs/s. dt is the time since the previous sample, stretched up to MaxStallSeconds back to when the root last
-- moved, so a replication stall followed by a burst reads as the average speed it really was.
--
-- Verdicts. Ok: the sample becomes the last accepted position, and the last safe position too when it was grounded
-- and within speed. Correct: CharacterService.Teleport back to the last safe position (the validator's position when
-- one gave it) and Corrected fires. Strike: Correct plus one strike; strikes decay one per StrikeDecaySeconds, and at
-- StrikeWarnThreshold or more a warning is logged (throttled) while corrections go on. Nobody is ever kicked.
-- NoiseAndDirectorService.SuspiciousMovement (an unexplained long step the locomotion sampler saw) counts as a
-- Teleport strike for an eligible player when the step breaks the teleport rule over the seconds the sampler measured,
-- unless this service corrected them within the last second.
--
-- Pure rules (tests/Specs/MovementAuthority.spec.luau): allowedSpeed / trackWalkSpeed, effectiveInterval,
-- jumpVelocity, allowedRise, capsuleBlocked, judge, settled, decayStrikes, runValidators, isExempt.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local CollisionService = require(ServerScriptService.Services.Core.CollisionService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)

local LifeStateService = require(script.Parent.LifeStateService)
local PlayerStateService = require(script.Parent.PlayerStateService)

local log = Log.new("Movement")

-- WalkSpeed history: the current value, the one before the last change, and when it changed.
export type SpeedTrack = { current: number, previous: number, changedAt: number }

-- One step to judge (positions are root centres; seconds are os.clock time).
export type Sample = {
	from: Vector3, -- last accepted position
	to: Vector3, -- current root position
	dt: number, -- effectiveInterval seconds
	allowedSpeed: number, -- allowedSpeed(...) studs/s
	grounded: boolean,
	airborneFor: number, -- seconds airborne so far (0 when grounded)
	checkVertical: boolean, -- on-foot mode: the jump rule applies
	jumpVelocity: number,
	gravity: number,
	surplus: number, -- overspeed studs carried in from earlier samples
}

export type Judgement = {
	verdict: Types.MovementVerdict,
	reason: string?, -- "Teleport" | "Noclip" | "Fly" | "Speed" for non-Ok verdicts
	surplus: number, -- overspeed studs carried to the next sample
	clean: boolean, -- Ok and within the allowed speed (a candidate safe position when grounded)
}

-- Casts one ray from `origin` along `direction`; true when it hits solid geometry.
export type RayCaster = (origin: Vector3, direction: Vector3) -> boolean

export type ValidatorEntry = { name: string, validator: Types.MovementValidator }

type Track = {
	character: Model,
	last: Vector3, -- last accepted position
	lastAt: number,
	movedAt: number,
	safe: Vector3, -- last safe position (grounded, clean)
	airborneSince: number?,
	surplus: number,
	speed: SpeedTrack,
	settleUntil: number, -- after a server move: wait for the client to take it until then
	settleFrom: Vector3?, -- where the root was before that move (nil for a fresh character)
}

type Strikes = { count: number, at: number }

local SPEED_GRACE_SECONDS = 0.6
local SPEED_MULTIPLIER = 1.25
local SPEED_SLACK = 3 -- studs/s of latency slack
local TELEPORT_SLACK = 6 -- studs
local AIRBORNE_GRACE_SECONDS = 0.5
local VERTICAL_SLACK = 3 -- studs/s
local OVERSPEED_TOLERANCE = 2 -- surplus studs before a speed correction
local MAX_STALL_SECONDS = 1
local MOVE_EPSILON = 0.05 -- studs: smaller root changes are physics jitter
local CAPSULE_RADIUS = 0.9
local NOCLIP_MIN_STEP = 0.25 -- studs: shorter steps are never ray-checked
local STRIKE_DECAY_SECONDS = 10
local STRIKE_WARN_THRESHOLD = 6
local SETTLE_SECONDS = 1
local SUSPICION_DEDUPE_SECONDS = 1
local UP = Vector3.new(0, 1, 0)
local SIDE_FALLBACK = Vector3.new(1, 0, 0)

local MovementAuthority = {}

MovementAuthority.Name = "MovementAuthority"
MovementAuthority.SpeedGraceSeconds = SPEED_GRACE_SECONDS
MovementAuthority.SpeedMultiplier = SPEED_MULTIPLIER
MovementAuthority.SpeedSlack = SPEED_SLACK
MovementAuthority.TeleportSlack = TELEPORT_SLACK
MovementAuthority.AirborneGraceSeconds = AIRBORNE_GRACE_SECONDS
MovementAuthority.VerticalSlack = VERTICAL_SLACK
MovementAuthority.OverspeedTolerance = OVERSPEED_TOLERANCE
MovementAuthority.MaxStallSeconds = MAX_STALL_SECONDS
MovementAuthority.CapsuleRadius = CAPSULE_RADIUS
MovementAuthority.StrikeDecaySeconds = STRIKE_DECAY_SECONDS
MovementAuthority.StrikeWarnThreshold = STRIKE_WARN_THRESHOLD
MovementAuthority.SettleSeconds = SETTLE_SECONDS

local corrected: Signal.Signal<Player, string> = Signal.new()
local struck: Signal.Signal<Player, string, number> = Signal.new()

-- (player, reason) after the server moved a player back (reason: a built-in check or a validator's name).
MovementAuthority.Corrected = corrected
-- (player, reason, strikes) after a Strike verdict, with the decayed strike count including this one.
MovementAuthority.Struck = struck

local serviceTrove = Trove.new()
local validators: { ValidatorEntry } = {}
local tracks: { [Player]: Track } = {}
local exemptions: { [Player]: { [string]: number } } = {}
local strikes: { [Player]: Strikes } = {}
local lastCorrectionAt: { [Player]: number } = {}
local correctingFrom: { [Player]: Vector3 } = {} -- root position at the moment a correction teleports it
local run: Types.RunContext? = nil
local phaseLive = false
local initialized = false

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/MovementAuthority.spec.luau)
--------------------------------------------------------------------------------

function MovementAuthority.newSpeedTrack(walkSpeed: number, now: number): SpeedTrack
	return { current = walkSpeed, previous = walkSpeed, changedAt = now }
end

-- Records the WalkSpeed observed at `now` (a change keeps the old value for the grace window).
function MovementAuthority.trackWalkSpeed(track: SpeedTrack, walkSpeed: number, now: number)
	if walkSpeed ~= track.current then
		track.previous = track.current
		track.current = walkSpeed
		track.changedAt = now
	end
end

-- Allowed horizontal speed (studs/s) at `now`.
function MovementAuthority.allowedSpeed(track: SpeedTrack, now: number): number
	local base = track.current
	if now - track.changedAt < SPEED_GRACE_SECONDS then
		base = math.max(base, track.previous)
	end
	return math.max(0, base) * SPEED_MULTIPLIER + SPEED_SLACK
end

-- Seconds a step from the sample at `lastAt` to `now` is judged over: at least the sample gap, stretched back to
-- when the root last moved (`movedAt`) by at most MaxStallSeconds.
function MovementAuthority.effectiveInterval(now: number, lastAt: number, movedAt: number): number
	local gap = now - lastAt
	local still = now - math.min(movedAt, lastAt)
	return math.clamp(still, gap, math.max(gap, MAX_STALL_SECONDS))
end

-- Take-off speed (studs/s) of a Humanoid jump.
function MovementAuthority.jumpVelocity(
	useJumpPower: boolean,
	jumpPower: number,
	jumpHeight: number,
	gravity: number
): number
	if useJumpPower then
		return math.max(0, jumpPower)
	end
	return math.sqrt(2 * math.max(0, gravity) * math.max(0, jumpHeight))
end

-- Fastest rise (studs/s) still possible after `airborneFor` seconds in the air, over a sample of `dt` seconds.
function MovementAuthority.allowedRise(airborneFor: number, dt: number, jumpVelocity: number, gravity: number): number
	local ballistic = jumpVelocity - gravity * math.max(0, airborneFor - dt)
	return math.max(0, ballistic) + VERTICAL_SLACK
end

-- True when a capsule of `radius` could not travel from `from` to `to`: the centre ray and both sideways rays
-- (perpendicular to the motion; X for vertical motion) all hit.
function MovementAuthority.capsuleBlocked(from: Vector3, to: Vector3, cast: RayCaster, radius: number?): boolean
	local delta = to - from
	local length = delta.Magnitude
	if length < NOCLIP_MIN_STEP then
		return false
	end
	if not cast(from, delta) then
		return false
	end
	local side = (delta / length):Cross(UP)
	side = if side.Magnitude < 0.1 then SIDE_FALLBACK else side.Unit
	local offset = side * (radius or CAPSULE_RADIUS)
	return cast(from + offset, delta) and cast(from - offset, delta)
end

-- The built-in verdict for one step. `blocked` (nil skips the noclip check) answers whether the capsule's path is
-- walled off.
function MovementAuthority.judge(sample: Sample, blocked: ((from: Vector3, to: Vector3) -> boolean)?): Judgement
	local dt = math.max(sample.dt, 1e-3)
	local horizontal = MathUtil.horizontalDistance(sample.to, sample.from)
	local allowedStep = sample.allowedSpeed * dt
	if horizontal > allowedStep + TELEPORT_SLACK then
		return { verdict = "Strike", reason = "Teleport", surplus = 0, clean = false }
	end
	if blocked and blocked(sample.from, sample.to) then
		return { verdict = "Strike", reason = "Noclip", surplus = 0, clean = false }
	end
	if sample.checkVertical and not sample.grounded and sample.airborneFor > AIRBORNE_GRACE_SECONDS then
		local rise = (sample.to.Y - sample.from.Y) / dt
		if rise > MovementAuthority.allowedRise(sample.airborneFor, dt, sample.jumpVelocity, sample.gravity) then
			return { verdict = "Strike", reason = "Fly", surplus = 0, clean = false }
		end
	end
	local excess = horizontal - allowedStep
	local surplus = math.max(0, sample.surplus + excess)
	if surplus > OVERSPEED_TOLERANCE then
		return { verdict = "Correct", reason = "Speed", surplus = 0, clean = false }
	end
	return { verdict = "Ok", reason = nil, surplus = surplus, clean = excess <= 0 }
end

-- Whether a client has taken a server move to `target` (from `from`, nil for a fresh character): the root is within
-- `reach` + TeleportSlack studs of the target and closer to it than to where it came from.
function MovementAuthority.settled(position: Vector3, target: Vector3, from: Vector3?, reach: number): boolean
	local distance = (position - target).Magnitude
	if distance > math.max(0, reach) + TELEPORT_SLACK then
		return false
	end
	return from == nil or distance < (position - from).Magnitude
end

-- A strike count `count` after `elapsed` seconds of decay.
function MovementAuthority.decayStrikes(count: number, elapsed: number): number
	return math.max(0, count - math.max(0, elapsed) / STRIKE_DECAY_SECONDS)
end

-- Runs `list` in order: the first Correct / Strike wins (with its safe position and the validator's name). A
-- validator that throws or answers anything else counts as Ok.
function MovementAuthority.runValidators(
	list: { ValidatorEntry },
	player: Player,
	root: BasePart,
	dt: number
): (Types.MovementVerdict, Vector3?, string?)
	for _, entry in list do
		local ok, verdict, safe = pcall(entry.validator, player, root, dt)
		if not ok then
			log.warnThrottled("validator:" .. entry.name, 10, "validator %s failed: %s", entry.name, tostring(verdict))
			continue
		end
		if verdict == "Correct" or verdict == "Strike" then
			local position: Vector3? = if typeof(safe) == "Vector3" then safe :: Vector3 else nil
			return verdict, position, entry.name
		end
	end
	return "Ok", nil, nil
end

-- Whether any exemption token (token -> expiry, math.huge = until Unexempt) still holds at `now`.
function MovementAuthority.isExempt(tokens: { [string]: number }?, now: number): boolean
	if not tokens then
		return false
	end
	for _, expiresAt in tokens do
		if expiresAt > now then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Adds (or replaces, by name) a validator that runs before the built-in checks.
function MovementAuthority.RegisterValidator(name: string, validator: Types.MovementValidator)
	for _, entry in validators do
		if entry.name == name then
			entry.validator = validator
			return
		end
	end
	table.insert(validators, { name = name, validator = validator })
end

-- Registered validator names, in the order they run.
function MovementAuthority.GetValidatorNames(): { string }
	local names: { string } = {}
	for _, entry in validators do
		table.insert(names, entry.name)
	end
	return names
end

function MovementAuthority.UnregisterValidator(name: string)
	for index, entry in validators do
		if entry.name == name then
			table.remove(validators, index)
			return
		end
	end
end

-- Exempts `player` under `token` for `seconds` (nil: until Unexempt). The baseline resets when the last exemption
-- ends.
function MovementAuthority.Exempt(player: Player, token: string, seconds: number?)
	local tokens = exemptions[player]
	if not tokens then
		tokens = {}
		exemptions[player] = tokens
	end
	local duration = if seconds ~= nil and MathUtil.isFinite(seconds) then math.max(0, seconds) else math.huge
	tokens[token] = os.clock() + duration
end

function MovementAuthority.Unexempt(player: Player, token: string)
	local tokens = exemptions[player]
	if not tokens then
		return
	end
	tokens[token] = nil
	if next(tokens) == nil then
		exemptions[player] = nil
	end
end

function MovementAuthority.IsExempt(player: Player): boolean
	return MovementAuthority.isExempt(exemptions[player], os.clock())
end

-- `player`'s current (decayed) strike count.
function MovementAuthority.GetStrikes(player: Player): number
	local entry = strikes[player]
	if not entry then
		return 0
	end
	return MovementAuthority.decayStrikes(entry.count, os.clock() - entry.at)
end

--------------------------------------------------------------------------------
-- Live checks
--------------------------------------------------------------------------------

local function runIsLive(): boolean
	return run ~= nil and phaseLive
end

local function isParticipant(player: Player): boolean
	local current = run
	return current ~= nil and table.find(current.participants, player) ~= nil
end

-- The root and humanoid to check, or nil when `player` is not under client movement right now.
local function eligible(player: Player, now: number): (Model?, BasePart?, Humanoid?)
	if not isParticipant(player) or not LifeStateService.IsPlaying(player) then
		return nil, nil, nil
	end
	if MovementAuthority.isExempt(exemptions[player], now) or CharacterService.GetLock(player) ~= "None" then
		return nil, nil, nil
	end
	local character = player.Character
	local root = Instances.characterRoot(player)
	local humanoid = Instances.characterHumanoid(player)
	if not character or not root or not humanoid or humanoid.Health <= 0 or root.Anchored then
		return nil, nil, nil
	end
	if not root:IsDescendantOf(Workspace) or CollisionService.GetMode(character) == "Locked" then
		return nil, nil, nil
	end
	if root:GetNetworkOwner() ~= player then
		return nil, nil, nil
	end
	return character, root, humanoid
end

local function baseline(player: Player, character: Model, position: Vector3, walkSpeed: number, now: number)
	tracks[player] = {
		character = character,
		last = position,
		lastAt = now,
		movedAt = now,
		safe = position,
		airborneSince = nil,
		surplus = 0,
		speed = MovementAuthority.newSpeedTrack(walkSpeed, now),
		settleUntil = now,
		settleFrom = nil,
	}
end

local function addStrike(player: Player, reason: string, now: number)
	local entry = strikes[player]
	local count = (if entry then MovementAuthority.decayStrikes(entry.count, now - entry.at) else 0) + 1
	strikes[player] = { count = count, at = now }
	if count >= STRIKE_WARN_THRESHOLD then
		log.warnThrottled(
			"strikes:" .. player.UserId,
			15,
			"%s (%d) has %.1f movement strikes (latest: %s); still correcting",
			player.Name,
			player.UserId,
			count,
			reason
		)
	end
	struck:Fire(player, reason, count)
end

-- Moves `player` back to `target` (Teleport fires Moved, which re-baselines the track there).
local function correct(player: Player, root: BasePart, target: Vector3, reason: string, now: number)
	lastCorrectionAt[player] = now
	log.warnThrottled(
		"correct:" .. player.UserId,
		10,
		"correcting %s (%d): %s, back to %s",
		player.Name,
		player.UserId,
		reason,
		tostring(target)
	)
	correctingFrom[player] = root.Position
	local moved = CharacterService.Teleport(player, CFrame.new(target) * root.CFrame.Rotation)
	correctingFrom[player] = nil
	if moved then
		corrected:Fire(player, reason)
	else
		tracks[player] = nil
	end
end

local function apply(
	player: Player,
	root: BasePart,
	track: Track,
	verdict: Types.MovementVerdict,
	reason: string,
	target: Vector3?,
	now: number
)
	if verdict == "Strike" then
		addStrike(player, reason, now)
	end
	correct(player, root, target or track.safe, reason, now)
end

local function rayCaster(): RayCaster
	local exclude: { Instance } = {}
	for _, other in Players:GetPlayers() do
		local character = other.Character
		if character then
			table.insert(exclude, character)
		end
	end
	local creature = Instances.creature()
	if creature then
		table.insert(exclude, creature)
	end
	local params = SpatialQuery.worldParams(exclude)
	return function(origin: Vector3, direction: Vector3): boolean
		return Workspace:Raycast(origin, direction, params) ~= nil
	end
end

local function checkPlayer(player: Player, now: number, cast: RayCaster)
	local character, root, humanoid = eligible(player, now)
	if not character or not root or not humanoid then
		tracks[player] = nil
		return
	end
	local position = root.Position
	local track = tracks[player]
	if not track or track.character ~= character then
		baseline(player, character, position, humanoid.WalkSpeed, now)
		return
	end
	MovementAuthority.trackWalkSpeed(track.speed, humanoid.WalkSpeed, now)
	if now < track.settleUntil then
		local reach = MovementAuthority.allowedSpeed(track.speed, now) * (now - track.lastAt)
		if MovementAuthority.settled(position, track.last, track.settleFrom, reach) then
			track.settleUntil = now
			track.settleFrom = nil
			track.last = position
			track.lastAt = now
			track.movedAt = now
		end
		return
	end
	if now - track.lastAt <= 0 then
		return
	end
	local onFoot = PlayerStateService.GetMode(player) == "OnFoot"
	local grounded = not onFoot or humanoid.FloorMaterial ~= Enum.Material.Air
	if grounded then
		track.airborneSince = nil
	elseif track.airborneSince == nil then
		track.airborneSince = track.lastAt
	end
	local dt = MovementAuthority.effectiveInterval(now, track.lastAt, track.movedAt)

	local verdict: Types.MovementVerdict, target, name = MovementAuthority.runValidators(validators, player, root, dt)
	local refused = verdict ~= "Ok"
	if refused then
		apply(player, root, track, verdict, name or "Validator", target, now)
		return
	end

	local gravity = Workspace.Gravity
	local airborneSince = track.airborneSince
	local judgement = MovementAuthority.judge({
		from = track.last,
		to = position,
		dt = dt,
		allowedSpeed = MovementAuthority.allowedSpeed(track.speed, now),
		grounded = grounded,
		airborneFor = if airborneSince then now - airborneSince else 0,
		checkVertical = onFoot,
		jumpVelocity = MovementAuthority.jumpVelocity(
			humanoid.UseJumpPower,
			humanoid.JumpPower,
			humanoid.JumpHeight,
			gravity
		),
		gravity = gravity,
		surplus = track.surplus,
	}, function(from: Vector3, to: Vector3): boolean
		return MovementAuthority.capsuleBlocked(from, to, cast)
	end)
	if judgement.verdict ~= "Ok" then
		apply(player, root, track, judgement.verdict, judgement.reason or "Movement", nil, now)
		return
	end
	if (position - track.last).Magnitude > MOVE_EPSILON then
		track.movedAt = now
	end
	track.last = position
	track.lastAt = now
	track.surplus = judgement.surplus
	if judgement.clean and grounded then
		track.safe = position
	end
end

local function step()
	if not runIsLive() then
		table.clear(tracks)
		return
	end
	local current = run
	if not current then
		return
	end
	local now = os.clock()
	local cast = rayCaster()
	for _, player in current.participants do
		if player.Parent ~= Players then
			continue
		end
		xpcall(checkPlayer, function(err: any)
			log.warnThrottled(
				"check:" .. player.UserId,
				10,
				"movement check for %s failed: %s",
				player.Name,
				tostring(err)
			)
		end, player, now, cast)
	end
end

-- A server move (Spawn / Teleport / correction): the client needs a moment to take it, then checks resume from there.
local function onMoved(player: Player, model: Model, cframe: CFrame)
	local now = os.clock()
	local previous = tracks[player]
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local walkSpeed = if humanoid then humanoid.WalkSpeed else GameConfig.WalkSpeed
	baseline(player, model, cframe.Position, walkSpeed, now)
	local track = tracks[player]
	if track then
		track.settleUntil = now + SETTLE_SECONDS
		-- Where the client still has the root: the corrected position, else (other server moves) the last sample.
		track.settleFrom = correctingFrom[player]
			or (if previous and previous.character == model then previous.last else nil)
	end
end

-- The locomotion sampler saw an unexplained long step. It reports every step over its TeleportStep, even one a
-- replication stall explains, so the step is held to the same teleport rule as a sample here (over the stall-aware
-- seconds the sampler measured) before it counts.
local function onSuspicious(player: Player, suspicious: NoiseAndDirectorService.SuspiciousStep)
	local now = os.clock()
	local last = lastCorrectionAt[player]
	if last ~= nil and now - last < SUSPICION_DEDUPE_SECONDS then
		return
	end
	if not runIsLive() then
		return
	end
	local character, root = eligible(player, now)
	local track = tracks[player]
	if not character or not root or not track or track.character ~= character or now < track.settleUntil then
		return
	end
	local allowance = MovementAuthority.allowedSpeed(track.speed, now) * suspicious.seconds + TELEPORT_SLACK
	if suspicious.distance <= allowance then
		return
	end
	apply(player, root, track, "Strike", "Teleport", nil, now)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function MovementAuthority.Init()
	if initialized then
		return
	end
	initialized = true
	serviceTrove:Add(CharacterService.Moved:Connect(onMoved))
	serviceTrove:Add(CharacterService.CharacterRemoving:Connect(function(player: Player, model: Model)
		local track = tracks[player]
		if track and track.character == model then
			tracks[player] = nil
		end
	end))
	serviceTrove:Add(NoiseAndDirectorService.SuspiciousMovement:Connect(onSuspicious))
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(function(phase: Enums.MatchPhase)
		phaseLive = run ~= nil and (phase == "Deploying" or phase == "InRun")
	end))
end

function MovementAuthority.Start()
	local interval = 1 / GameConfig.ServerTickHz
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		accumulated += dt
		if accumulated < interval then
			return
		end
		accumulated = 0
		xpcall(step, function(err: any)
			log.warnThrottled("step", 10, "movement step failed: %s", tostring(err))
		end)
	end)
end

function MovementAuthority.BeginRun(ctx: Types.RunContext)
	run = ctx
	phaseLive = true
	table.clear(tracks)
	table.clear(strikes)
	table.clear(lastCorrectionAt)
	table.clear(exemptions)
end

function MovementAuthority.EndRun()
	run = nil
	phaseLive = false
	table.clear(tracks)
	table.clear(exemptions)
	table.clear(lastCorrectionAt)
end

function MovementAuthority.OnPlayerRemoving(player: Player)
	correctingFrom[player] = nil
	tracks[player] = nil
	exemptions[player] = nil
	strikes[player] = nil
	lastCorrectionAt[player] = nil
end

return MovementAuthority
