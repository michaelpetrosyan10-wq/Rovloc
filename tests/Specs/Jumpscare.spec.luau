--!strict
-- Jumpscare. JumpscareHandler's rules: who may be caught (validation), the outcome rule (the first catch downs, every
-- later one executes), the moment's schedule and payloads, the face-to-face placement per kind and the face point.
-- Live catches on a fake clock, over a built Creature rig and hand-built victims: the sequence (one catch at a time;
-- the Creature anchored and set face to face; nothing lands before the hold ends, then the Down, the release and
-- Finished), later catches executing, refusals that change nothing, and the abort paths (the victim leaves, the run
-- ends, the victim dies mid-catch) applying no outcome. JumpscareController's maths: the face lock along the lunge,
-- the shake and the overlay under MotionScale / FlashScale, the hold length, and a witness's falloffs.
-- (Locks, teleports, cues and rendering need the engine: CharacterService only locks and turns characters it
-- spawned, and the harness records remotes where specs cannot read them.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)

local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)

local JumpscareHandler = require(ServerScriptService.Services.Monster.MonsterAIService.JumpscareHandler)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local JumpscareController = require(StarterPlayer.StarterPlayerScripts.Controllers.Gameplay.JumpscareController)

type Expect = SpecRunner.Expect
type CatchCheck = JumpscareHandler.CatchCheck

type Timer = { at: number, callback: () -> (), thread: thread, cancelled: boolean }

type FakeClock = {
	clock: JumpscareHandler.Clock,
	advance: (seconds: number) -> (),
	now: () -> number,
}

type Finish = { player: Player, kind: Enums.JumpscareKind, outcome: string }

type Rig = { model: Model, root: BasePart }

local C = Attributes.Creature
local J = CreatureConfig.Jumpscare
local NAMES = CreatureRigBuilder.PartNames
local MAX = GameConfig.MaxHealth
local LUNGE = J.LungeSeconds
local HOLD = J.HoldSeconds
local FACE = J.FaceDistance
local KINDS: { Enums.JumpscareKind } = { "Hallway", "Vent", "Locker", "Underwater" }
local NOT_PLAYING: { Enums.LifeState } = { "Lobby", "Dead", "Spectating" }
local VICTIM_ROOT_HEIGHT = 3 -- a standing victim's root above the floor (hip 2 + half the 2-stud root)
local CREATURE_ROOT_HEIGHT = CreatureConfig.Rig.HipHeight + CreatureConfig.Rig.RootSize.Y / 2

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- A clock whose time only moves when the spec advances it; due callbacks run in time order.
local function fakeClock(start: number): FakeClock
	local now = start
	local timers: { Timer } = {}
	local clock: JumpscareHandler.Clock = {
		now = function(): number
			return now
		end,
		delay = function(seconds: number, callback: () -> ()): thread
			local thread = coroutine.create(function() end)
			table.insert(
				timers,
				{ at = now + math.max(0, seconds), callback = callback, thread = thread, cancelled = false }
			)
			return thread
		end,
		cancel = function(thread: thread)
			for _, timer in timers do
				if timer.thread == thread then
					timer.cancelled = true
				end
			end
		end,
	}
	local function advance(seconds: number)
		local target = now + seconds
		while true do
			local nextIndex: number? = nil
			for index, timer in timers do
				if timer.cancelled or timer.at > target then
					continue
				end
				if nextIndex == nil or timer.at < timers[nextIndex].at then
					nextIndex = index
				end
			end
			if nextIndex == nil then
				break
			end
			local timer = table.remove(timers, nextIndex)
			if timer then
				now = math.max(now, timer.at)
				timer.callback()
			end
		end
		now = target
	end
	return {
		clock = clock,
		advance = advance,
		now = function(): number
			return now
		end,
	}
end

local function near(a: Vector3, b: Vector3, epsilon: number): boolean
	return (a - b).Magnitude <= epsilon
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Moves a hand-built root. Position is written too: the engine derives it from CFrame, the Lune harness does not,
-- and LifeStateService's downed gasp cue reads it.
local function place(root: BasePart, cframe: CFrame)
	root.CFrame = cframe
	root.Position = cframe.Position
end

local nextUserId = 9400

local function fakePlayer(at: CFrame): (Player, BasePart, Humanoid)
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "JumpscareSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	local model = Instance.new("Model")
	model.Name = player.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	place(root, at)
	root.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = MAX
	humanoid.Health = MAX
	humanoid.Parent = model
	player.Character = model
	return player, root, humanoid
end

-- The Creature rig standing on `floor`, in Workspace, mid-chase (built with Geometry's cooperative yielding off).
local function buildCreature(floor: CFrame): Rig
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	local ok, built = pcall(CreatureRigBuilder.build, Workspace, floor)
	Geometry.setYieldEvery(previous)
	if not ok then
		error(built, 0)
	end
	local model = built :: Model
	model:SetAttribute(C.MonsterState, "WallChase")
	model:SetAttribute(C.Hidden, false)
	local root = model:FindFirstChild(NAMES.Root)
	assert(root and root:IsA("BasePart"), "the Creature has a HumanoidRootPart")
	return { model = model, root = root }
end

-- Runs `body` with `players` in a live run on a fake clock (stats, move states and life states), with a Creature
-- rig standing at `creatureFloor`, and always tears both down (any catch still running is aborted first).
local function inRun(players: { Player }, creatureFloor: CFrame, body: (rig: Rig, clock: FakeClock) -> ())
	Net.Server.setup()
	local clock = fakeClock(5000)
	JumpscareHandler.SetClock(clock.clock)
	LifeStateService.SetClock(clock.clock)
	local ctx: Types.RunContext = {
		runId = "jumpscare-spec",
		seed = 1,
		difficulty = "Standard",
		participants = players,
		startedAt = 5000,
	}
	RunStatsService.BeginRun(ctx)
	PlayerStateService.BeginRun(ctx)
	LifeStateService.BeginRun(ctx)
	local rig: Rig? = nil
	local failure: string? = nil
	xpcall(function()
		rig = buildCreature(creatureFloor)
		body(rig :: Rig, clock)
	end, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end)
	JumpscareHandler.Abort("SpecTeardown")
	LifeStateService.EndRun()
	PlayerStateService.EndRun()
	RunStatsService.EndRun()
	for _, player in players do
		LifeStateService.OnPlayerRemoving(player)
		PlayerStateService.OnPlayerRemoving(player)
	end
	JumpscareHandler.SetClock(nil)
	LifeStateService.SetClock(nil)
	local built = rig
	if built then
		built.model:Destroy()
	end
	if failure ~= nil then
		error(failure, 0)
	end
end

-- Records every Finished while `body` runs.
local function recordFinishes(body: (finishes: { Finish }) -> ())
	local finishes: { Finish } = {}
	local connection = JumpscareHandler.Finished:Connect(
		function(player: Player, kind: Enums.JumpscareKind, outcome: string)
			table.insert(finishes, { player = player, kind = kind, outcome = outcome })
		end
	)
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, finishes)
	connection:Disconnect()
	if failure ~= nil then
		error(failure, 0)
	end
end

local function baseCheck(overrides: { [string]: any }?): CatchCheck
	local check: CatchCheck = {
		busy = false,
		kind = "Hallway",
		creatureInWorld = true,
		hidden = false,
		monsterState = "WallChase",
		lifeState = "Alive",
		hasBody = true,
		caught = false,
		controlLock = "None",
		distance = CreatureConfig.Senses.CatchDistance,
	}
	if overrides then
		for key, value in overrides do
			(check :: any)[key] = value
		end
	end
	return check
end

local function verdict(ok: boolean, reason: string?): string
	return if ok then "ok" else tostring(reason)
end

-- The victim's standing root at floor point (x, z), facing `yawDeg`.
local function victimAt(x: number, z: number, yawDeg: number): CFrame
	return CFrame.new(x, VICTIM_ROOT_HEIGHT, z) * CFrame.Angles(0, math.rad(yawDeg), 0)
end

-- How far apart two roots stand on the floor.
local function apart(a: BasePart, b: BasePart): number
	return flat(a.CFrame.Position - b.CFrame.Position).Magnitude
end

-- Whether `cframe` looks (flat) at `target`.
local function facesToward(cframe: CFrame, target: Vector3): boolean
	local toward = flat(target - cframe.Position)
	return toward.Magnitude > 1e-6 and cframe.LookVector:Dot(toward.Unit) > 0.999
end

local function angleOf(cframe: CFrame): number
	local _, angle = cframe:ToAxisAngle()
	return math.abs(angle)
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["rules: a catch needs a free handler, a playing victim with a body, and a visible Creature in reach"] = function(
		t: Expect
	)
		t.eq(verdict(JumpscareHandler.validate(baseCheck())), "ok")
		for _, kind: Enums.JumpscareKind in KINDS do
			t.eq(verdict(JumpscareHandler.validate(baseCheck({ kind = kind }))), "ok", kind)
		end
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ lifeState = "Downed" }))), "ok", "the downed are caught too")
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ busy = true }))), "Busy", "one catch at a time")
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ kind = "Elevator" }))), "Kind")
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ creatureInWorld = false }))), "NoCreature")
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ hidden = true }))), "Hidden", "a hidden Creature")
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ monsterState = "Stunned" }))), "Stunned")
		for _, state: Enums.LifeState in NOT_PLAYING do
			t.eq(verdict(JumpscareHandler.validate(baseCheck({ lifeState = state }))), "NotPlaying", state)
		end
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ hasBody = false }))), "NoBody")
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ caught = true }))), "Caught", "already caught")
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ controlLock = "Cutscene" }))), "Cutscene")
		for _, lock: Enums.ControlLock in { "Trap", "Locker", "Drag" } :: { Enums.ControlLock } do
			t.eq(
				verdict(JumpscareHandler.validate(baseCheck({ controlLock = lock }))),
				"ok",
				"caught out of a " .. lock
			)
		end
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ distance = JumpscareHandler.MaxReach }))), "ok")
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ distance = JumpscareHandler.MaxReach + 0.1 }))), "TooFar")
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ distance = math.huge }))), "TooFar", "no root to measure")
		t.eq(verdict(JumpscareHandler.validate(baseCheck({ distance = 0 / 0 }))), "TooFar", "a non-finite distance")
		t.truthy(JumpscareHandler.MaxReach > CreatureConfig.Senses.CatchDistance, "the reach covers a floor catch")
		t.truthy(JumpscareHandler.MaxReach > CreatureConfig.Senses.VentCatchDistance, "and a duct catch")
	end,

	["rules: the first catch downs; every later catch executes"] = function(t: Expect)
		t.eq(JumpscareHandler.outcomeFor("Alive", 0), "Downed", "never downed this run")
		t.eq(JumpscareHandler.outcomeFor("Alive", 1), "Executed", "revived after a down")
		t.eq(JumpscareHandler.outcomeFor("Alive", 3), "Executed")
		t.eq(JumpscareHandler.outcomeFor("Downed", 1), "Executed", "caught while crawling")
		t.eq(JumpscareHandler.outcomeFor("Downed", 0), "Executed")
		for _, state: Enums.LifeState in NOT_PLAYING do
			t.eq(JumpscareHandler.outcomeFor(state, 0), nil, state .. ": nothing to apply")
		end
		t.eq(JumpscareHandler.Cause, "Creature")
	end,

	["rules: the moment starts one OneShot lead out and ends after the lunge and the hold"] = function(t: Expect)
		local schedule = JumpscareHandler.schedule(100)
		t.near(schedule.startAt, 100 + GameConfig.OneShotLead, 1e-9, "every client starts on the same frame")
		t.near(schedule.lungeEndsAt, schedule.startAt + LUNGE, 1e-9)
		t.near(schedule.resolveAt, schedule.startAt + LUNGE + HOLD, 1e-9, "the catch resolves when the hold ends")

		local subject = Instance.new("Model")
		local event = JumpscareHandler.oneShotEvent(7, "Vent", subject, schedule, 4242, Vector3.new(1, 2, 3))
		t.eq(event.seq, 7)
		t.eq(event.kind, "Jumpscare", "OneShot kind (CreatureController plays the Lunge for it)")
		t.eq(event.subject, subject, "subject = the victim's character")
		t.eq(event.startAt, schedule.startAt)
		t.eq(event.args.kind, "Vent")
		t.eq(event.args.userId, 4242, "the victim's UserId")
		t.eq(event.args.position, Vector3.new(1, 2, 3))

		local cue = JumpscareHandler.victimCue("Locker", schedule, Vector3.new(4, 5, 6))
		t.eq(cue.kind, "JumpscareVictim")
		t.eq(cue.startAt, schedule.startAt)
		t.eq(cue.endsAt, schedule.resolveAt, "the victim cuts to black when the hold ends")
		t.eq(cue.args.kind, "Locker")
		t.eq(cue.args.face, Vector3.new(4, 5, 6), "the face to lock onto")
		t.eq(cue.args.aborted, nil)

		local abort = JumpscareHandler.abortCue("Hallway", 130)
		t.eq(abort.kind, "JumpscareVictim")
		t.eq(abort.startAt, 130)
		t.eq(abort.args.aborted, true)
		t.eq(abort.args.kind, "Hallway")
		subject:Destroy()
	end,

	["rules: face to face at each kind's spacing; the victim only turns; the Creature only closes in"] = function(
		t: Expect
	)
		for _, kind: Enums.JumpscareKind in KINDS do
			local spacing = JumpscareHandler.spacing(kind)
			t.truthy(spacing.distance > FACE, kind .. ": the face stays FaceDistance-plus away")
			t.truthy(spacing.minimum > FACE * 0.5 and spacing.minimum < spacing.distance, kind .. ": a band")
			local victim = victimAt(12, -30, 35)
			local function pair(offset: Vector3): (CFrame, CFrame)
				return JumpscareHandler.facePair(victim, CFrame.new(victim.Position + offset), kind)
			end

			-- From further out: pulled in to the spacing, along the line between them, at its own height.
			local offset = Vector3.new(3.1, 1.7, -2.6)
			local v, c = pair(offset)
			t.truthy(near(v.Position, victim.Position, 1e-6), kind .. ": the victim is never moved")
			t.truthy(facesToward(v, c.Position), kind .. ": the victim faces the Creature")
			t.truthy(facesToward(c, v.Position), kind .. ": the Creature faces the victim")
			t.near(flat(c.Position - v.Position).Magnitude, spacing.distance, 1e-4, kind .. ": at the spacing")
			t.near(c.Position.Y - v.Position.Y, 1.7, 1e-6, kind .. ": at its own height")
			t.truthy(flat(c.Position - v.Position).Unit:Dot(flat(offset).Unit) > 0.9999, kind .. ": on the line")
			t.near(v.UpVector.Y, 1, 1e-6, kind .. ": upright")
			t.near(c.UpVector.Y, 1, 1e-6, kind .. ": upright")

			-- Inside the band: only turned.
			local within = (spacing.distance + spacing.minimum) / 2
			local _, kept = pair(Vector3.new(within, 0, 0))
			t.truthy(near(kept.Position, victim.Position + Vector3.new(within, 0, 0), 1e-4), kind .. ": not moved")
			t.truthy(facesToward(kept, victim.Position), kind .. ": but turned to face")

			-- Too close: eased back out to the minimum.
			local _, eased = pair(Vector3.new(0, 0, 0.4))
			t.near(flat(eased.Position - victim.Position).Magnitude, spacing.minimum, 1e-4, kind .. ": minimum")

			-- Stacked: in front of the victim, along their facing.
			local stackedVictim, stacked = pair(Vector3.zero)
			t.truthy(
				near(stacked.Position, victim.Position + flat(victim.LookVector).Unit * spacing.minimum, 1e-4),
				kind .. ": stacked roots part along the victim's facing"
			)
			t.truthy(stackedVictim.LookVector:Dot(victim.LookVector) > 0.9999, kind .. ": keeps the victim's facing")
		end
		t.eq(JumpscareHandler.spacing("Elevator"), JumpscareHandler.spacing("Hallway"), "unknown kinds: Hallway")
		local victim = victimAt(0, 0, 0)
		local creature = CFrame.new(3, 1, 0)
		local v, c = JumpscareHandler.facePair(victim, CFrame.new(0 / 0, 0, 0), "Hallway")
		t.eq(v, victim, "a non-finite Creature leaves both alone")
		t.truthy(c.Position.X ~= c.Position.X, "(as it was)")
		local _, closer = JumpscareHandler.facePair(victim, creature * CFrame.new(40, 0, 0), "Hallway")
		t.near(flat(closer.Position).Magnitude, JumpscareHandler.spacing("Hallway").distance, 1e-4, "from afar")
	end,

	["rules: the face point comes from the rig's face attachment, else the eye height"] = function(t: Expect)
		local floor = CFrame.new(40, 0, -12) * CFrame.Angles(0, math.rad(-70), 0)
		local rig = buildCreature(floor)
		local face = rig.model:FindFirstChild(NAMES.FaceAttachment, true)
		assert(face and face:IsA("Attachment") and face.Parent and face.Parent:IsA("BasePart"), "the rig has a face")
		local faceWorld = (face.Parent :: BasePart).CFrame * face.CFrame
		local offset = JumpscareHandler.faceOffset(rig.root.CFrame, faceWorld, "Biped")
		t.near(offset.Position.Y, CreatureConfig.EyeHeightAboveRoot.Biped, 0.01, "at the eyes above the root")
		t.truthy(-offset.Position.Z >= 0 and -offset.Position.Z <= 1, "at most a stud ahead of the root")
		t.near(offset.Position.X, 0, 0.01, "centred")
		t.truthy(offset.LookVector:Dot(Vector3.new(0, 0, -1)) > 0.95, "looking where the Creature faces")
		t.truthy(near((rig.root.CFrame * offset).Position, faceWorld.Position, 1e-4), "round trip")
		rig.model:Destroy()

		local fallback = JumpscareHandler.faceOffset(CFrame.new(5, 5, 5), nil, "Quadruped")
		t.near(fallback.Position.Y, CreatureConfig.EyeHeightAboveRoot.Quadruped, 1e-6, "no face point: the eye")
		t.truthy(fallback.Position.Z < 0, "ahead of the root")
		local unknown = JumpscareHandler.faceOffset(CFrame.new(), nil, "Levitating")
		t.near(unknown.Position.Y, CreatureConfig.EyeHeightAboveRoot.Biped, 1e-6, "unknown poses: Biped")
	end,

	["live: a catch holds the moment, then downs the victim when the hold ends"] = function(t: Expect)
		local victim, victimRoot = fakePlayer(victimAt(0, 0, 90))
		local other = fakePlayer(victimAt(20, 0, 0))
		local creatureFloor = CFrame.new(3.2, 0, -2.4) * CFrame.Angles(0, math.rad(160), 0)
		inRun({ victim, other }, creatureFloor, function(rig: Rig, clock: FakeClock)
			recordFinishes(function(finishes: { Finish })
				local spacing = JumpscareHandler.spacing("Hallway")
				local caughtAt = clock.now()
				t.falsy(JumpscareHandler.IsBusy())
				t.falsy(rig.root.Anchored, "the rig starts free")
				t.truthy(JumpscareHandler.Catch(rig.model, victim, "Hallway"), "the catch starts")
				t.truthy(JumpscareHandler.IsBusy(), "busy")
				t.eq(JumpscareHandler.GetVictim(), victim)

				-- Face to face: the Creature is held kinematic at the spacing, facing the victim, at its height.
				t.truthy(rig.root.Anchored, "the Creature is anchored for the moment")
				t.near(apart(rig.root, victimRoot), spacing.distance, 1e-3, "pulled in to the Hallway spacing")
				t.near(
					rig.root.CFrame.Position.Y,
					CREATURE_ROOT_HEIGHT,
					1e-3,
					"at its own height (it stands on the same floor)"
				)
				t.truthy(facesToward(rig.root.CFrame, victimRoot.CFrame.Position), "facing the victim")

				-- One at a time.
				t.falsy(JumpscareHandler.Catch(rig.model, other, "Hallway"), "a second catch is refused")
				t.falsy(JumpscareHandler.Catch(rig.model, victim, "Vent"), "so is catching the victim again")
				t.eq(JumpscareHandler.GetVictim(), victim, "still the first victim")

				-- Nothing lands before the hold ends.
				local resolveAt = JumpscareHandler.schedule(caughtAt).resolveAt
				clock.advance(resolveAt - clock.now() - 0.01)
				t.eq(LifeStateService.GetState(victim), "Alive", "still standing through the hold")
				t.truthy(JumpscareHandler.IsBusy(), "still busy")
				t.eq(#finishes, 0, "not finished")
				t.truthy(rig.root.Anchored, "still held")

				clock.advance(0.02)
				t.eq(LifeStateService.GetState(victim), "Downed", "the first catch downs")
				t.eq(LifeStateService.GetDownedCount(victim), 1)
				t.eq(LifeStateService.GetState(other), "Alive", "nobody else")
				t.falsy(JumpscareHandler.IsBusy(), "free again")
				t.eq(JumpscareHandler.GetVictim(), nil)
				t.eq(#finishes, 1, "Finished once")
				t.eq(finishes[1].player, victim)
				t.eq(finishes[1].kind, "Hallway")
				t.eq(finishes[1].outcome, "Downed")
				t.falsy(rig.root.Anchored, "the Creature is free again")
				t.eq(rig.root:GetNetworkOwner(), nil, "and server-owned")

				clock.advance(5)
				t.eq(#finishes, 1, "nothing more fires")
				t.eq(LifeStateService.GetState(victim), "Downed")
			end)
		end)
	end,

	["live: every later catch executes, whether downed or revived"] = function(t: Expect)
		local crawler = fakePlayer(victimAt(0, 0, 0))
		local revived = fakePlayer(victimAt(30, 0, 0))
		inRun({ crawler, revived }, CFrame.new(0, 0, -3.5), function(rig: Rig, clock: FakeClock)
			recordFinishes(function(finishes: { Finish })
				local function catchAndWait(player: Player, kind: Enums.JumpscareKind): boolean
					local started = JumpscareHandler.Catch(rig.model, player, kind)
					clock.advance(GameConfig.OneShotLead + LUNGE + HOLD + 0.01)
					return started
				end
				t.truthy(catchAndWait(crawler, "Hallway"))
				t.eq(LifeStateService.GetState(crawler), "Downed", "first: downed")
				t.truthy(catchAndWait(crawler, "Hallway"), "a crawling victim can be caught")
				t.eq(LifeStateService.GetState(crawler), "Dead", "second: executed")
				t.eq(finishes[2].outcome, "Executed")
				t.falsy(JumpscareHandler.Catch(rig.model, crawler, "Hallway"), "the dead are not caught")

				-- Downed once, revived, caught: executed (DownedCount 1).
				local root = revived.Character and revived.Character:FindFirstChild("HumanoidRootPart")
				assert(root and root:IsA("BasePart"), "the revived victim has a root")
				place(root, CFrame.new(rig.root.CFrame.Position + Vector3.new(0, -1.7, 3)))
				LifeStateService.Down(revived, "Dev")
				LifeStateService.Revive(revived)
				t.eq(LifeStateService.GetState(revived), "Alive")
				t.truthy(catchAndWait(revived, "Vent"))
				t.eq(LifeStateService.GetState(revived), "Dead", "a revived victim is executed")
				t.eq(#finishes, 3)
				t.eq(finishes[3].kind, "Vent")
				t.eq(finishes[3].outcome, "Executed")
				t.falsy(JumpscareHandler.IsBusy())
			end)
		end)
	end,

	["live: refused catches change nothing"] = function(t: Expect)
		local victim, victimRoot = fakePlayer(victimAt(0, 0, 0))
		local outsider = fakePlayer(victimAt(1, 0, 1))
		local bodiless, bodilessRoot = fakePlayer(victimAt(-1, 0, 1))
		bodilessRoot:Destroy()
		inRun({ victim, bodiless }, CFrame.new(0, 0, -3.5), function(rig: Rig, clock: FakeClock)
			recordFinishes(function(finishes: { Finish })
				local before = rig.root.CFrame
				local function refused(player: Player, kind: Enums.JumpscareKind, why: string)
					t.falsy(JumpscareHandler.Catch(rig.model, player, kind), why)
					t.falsy(JumpscareHandler.IsBusy(), why .. ": not busy")
					t.falsy(rig.root.Anchored, why .. ": the Creature untouched")
					t.truthy(near(rig.root.CFrame.Position, before.Position, 1e-6), why .. ": not moved")
				end
				refused(outsider, "Hallway", "not in the run")
				refused(bodiless, "Hallway", "no character")
				refused(victim, ("Elevator" :: any) :: Enums.JumpscareKind, "unknown kind")

				rig.model:SetAttribute(C.MonsterState, "Stunned")
				refused(victim, "Hallway", "a stunned Creature catches nobody")
				rig.model:SetAttribute(C.MonsterState, "WallChase")

				rig.model:SetAttribute(C.Hidden, true)
				refused(victim, "Hallway", "a hidden Creature catches nobody")
				rig.model:SetAttribute(C.Hidden, false)

				local outside = Instance.new("Folder")
				rig.model.Parent = outside
				refused(victim, "Hallway", "a Creature out of the world catches nobody")
				rig.model.Parent = Workspace
				outside:Destroy()

				place(victimRoot, victimAt(0, 40, 0))
				refused(victim, "Hallway", "too far")
				place(victimRoot, victimAt(0, 0, 0))

				clock.advance(10)
				t.eq(#finishes, 0, "nothing finished")
				t.eq(LifeStateService.GetState(victim), "Alive")
				t.truthy(JumpscareHandler.Catch(rig.model, victim, "Hallway"), "the same catch in reach is taken")
			end)
		end)
	end,

	["abort: the victim leaving mid-catch applies nothing and frees the Creature"] = function(t: Expect)
		local victim = fakePlayer(victimAt(0, 0, 0))
		local bystander = fakePlayer(victimAt(0.5, 0, 1))
		inRun({ victim, bystander }, CFrame.new(0, 0, -3.5), function(rig: Rig, clock: FakeClock)
			recordFinishes(function(finishes: { Finish })
				t.truthy(JumpscareHandler.Catch(rig.model, victim, "Locker"))
				clock.advance(GameConfig.OneShotLead + LUNGE)
				JumpscareHandler.OnPlayerRemoving(bystander)
				t.truthy(JumpscareHandler.IsBusy(), "someone else leaving changes nothing")
				JumpscareHandler.OnPlayerRemoving(victim)
				t.falsy(JumpscareHandler.IsBusy(), "aborted at once")
				t.eq(#finishes, 1)
				t.eq(finishes[1].player, victim)
				t.eq(finishes[1].kind, "Locker")
				t.eq(finishes[1].outcome, "Aborted")
				t.falsy(rig.root.Anchored, "the Creature is free")
				JumpscareHandler.OnPlayerRemoving(victim)
				t.eq(#finishes, 1, "idempotent")

				clock.advance(HOLD + 1)
				t.eq(LifeStateService.GetState(victim), "Alive", "no outcome lands after the abort")
				t.eq(LifeStateService.GetDownedCount(victim), 0)
				t.eq(#finishes, 1)
				t.truthy(JumpscareHandler.Catch(rig.model, bystander, "Hallway"), "the next catch can start")
			end)
		end)
	end,

	["abort: the run ending or the victim dying mid-catch applies nothing"] = function(t: Expect)
		local victim = fakePlayer(victimAt(0, 0, 0))
		inRun({ victim }, CFrame.new(0, 0, -3.5), function(rig: Rig, clock: FakeClock)
			recordFinishes(function(finishes: { Finish })
				-- EndRun sends everyone to the lobby mid-catch.
				t.truthy(JumpscareHandler.Catch(rig.model, victim, "Hallway"))
				clock.advance(0.5)
				LifeStateService.EndRun()
				t.falsy(JumpscareHandler.IsBusy(), "the run ending aborts the catch")
				t.eq(finishes[1].outcome, "Aborted")
				t.falsy(rig.root.Anchored)
				clock.advance(5)
				t.eq(LifeStateService.GetState(victim), "Lobby", "nothing lands on the lobby")
				t.eq(#finishes, 1)

				-- The run's own EndRun hook (also wired to RunLifecycleService.PhaseChanged).
				local ctx: Types.RunContext = {
					runId = "jumpscare-spec-2",
					seed = 2,
					difficulty = "Standard",
					participants = { victim },
					startedAt = clock.now(),
				}
				LifeStateService.BeginRun(ctx)
				t.truthy(JumpscareHandler.Catch(rig.model, victim, "Vent"))
				JumpscareHandler.EndRun()
				t.falsy(JumpscareHandler.IsBusy())
				t.eq(finishes[2].outcome, "Aborted")
				t.eq(finishes[2].kind, "Vent")
				JumpscareHandler.EndRun()
				t.eq(#finishes, 2, "idempotent")
				clock.advance(5)
				t.eq(LifeStateService.GetState(victim), "Alive", "never downed")

				-- Killed by something else during the hold: the catch lets go instead of executing twice.
				LifeStateService.Down(victim, "Dev")
				t.truthy(JumpscareHandler.Catch(rig.model, victim, "Hallway"), "a downed victim is caught")
				clock.advance(LUNGE)
				LifeStateService.Execute(victim, "Bleedout")
				t.falsy(JumpscareHandler.IsBusy())
				t.eq(finishes[3].outcome, "Aborted")
				clock.advance(5)
				t.eq(#finishes, 3)
				t.eq(LifeStateService.GetState(victim), "Dead")

				t.falsy(JumpscareHandler.Abort("nothing running"), "Abort with nothing running")
			end)
		end)
	end,

	["camera: the face lock frames the face, lunging in from the eye to FaceDistance"] = function(t: Expect)
		local faces: { CFrame } = {
			CFrame.new(10, 7.8, -4) * CFrame.Angles(0, math.rad(200), 0),
			CFrame.new(-3, 1.2, 9) * CFrame.Angles(math.rad(-25), math.rad(40), math.rad(8)), -- pitched, rolled
			CFrame.new(0, -6, 0) * CFrame.Angles(math.rad(70), 0, 0), -- looking almost straight up
		}
		local start = 4
		for index, face in faces do
			local label = "face " .. index
			local locked = JumpscareController.faceLock(face, FACE)
			t.truthy(near(locked.Position, face.Position + face.LookVector * FACE, 1e-4), label .. ": out along it")
			t.truthy(locked.LookVector:Dot(-face.LookVector) > 0.9999, label .. ": looking straight back at it")
			t.truthy(locked.UpVector:Dot(face.UpVector) > 0.9999, label .. ": upright with the face")
			for _, progress in { 0, 0.2, 0.5, 0.8, 1 } do
				local cam = JumpscareController.faceLockCFrame(face, progress, start, 1)
				local toFace = face.Position - cam.Position
				t.truthy(cam.LookVector:Dot(toFace.Unit) > 0.9999, label .. ": the face stays centred")
			end
			local first = JumpscareController.faceLockCFrame(face, 0, start, 1)
			t.near((first.Position - face.Position).Magnitude, start, 1e-4, label .. ": the lunge starts at the eye")
			local last = JumpscareController.faceLockCFrame(face, 1, start, 1)
			t.near((last.Position - face.Position).Magnitude, FACE, 1e-4, label .. ": and ends at FaceDistance")
		end

		-- The slam: past FaceDistance at about SlamAt, never nearer than Closest, then back out to FaceDistance.
		local deepest, deepestAt = math.huge, 0
		local previous = math.huge
		local approaching = true
		for i = 0, 200 do
			local progress = i / 200
			local distance = JumpscareController.lungeDistance(JumpscareController.MaxStartDistance, progress, 1)
			if distance < deepest then
				deepest, deepestAt = distance, progress
			end
			if progress * LUNGE < JumpscareController.SlamAt - 0.01 and distance > previous + 1e-9 then
				approaching = false
			end
			previous = distance
		end
		t.truthy(approaching, "the face only comes closer until the slam")
		t.truthy(deepest < FACE - 0.1, "the face slams in past FaceDistance")
		t.truthy(deepest >= JumpscareController.Closest - 1e-9, "never nearer than Closest")
		t.near(deepestAt * LUNGE, JumpscareController.SlamAt, 0.01, "at SlamAt")
		t.near(JumpscareController.lungeDistance(4, 1, 1), FACE, 1e-9, "settled at FaceDistance")

		-- MotionScale scales the travel: none at 0 (held at FaceDistance), half at 0.5.
		for _, progress in { 0, 0.3, 0.6, 1 } do
			t.near(JumpscareController.lungeDistance(5, progress, 0), FACE, 1e-9, "MotionScale 0: still")
		end
		t.near(JumpscareController.lungeDistance(5, 0, 0.5), FACE + (5 - FACE) / 2, 1e-9, "MotionScale 0.5: half")

		-- Progress and start distance.
		t.eq(JumpscareController.lungeProgress(-1), 0)
		t.near(JumpscareController.lungeProgress(LUNGE / 2), 0.5, 1e-9)
		t.eq(JumpscareController.lungeProgress(LUNGE * 3), 1)
		t.eq(JumpscareController.lungeProgress(0 / 0), 0, "non-finite: the start")
		t.near(JumpscareController.lungeDistance(0 / 0, 0 / 0, 0 / 0), FACE, 1e-9, "non-finite inputs hold the face")
		t.eq(
			JumpscareController.startDistanceFor(Vector3.zero, Vector3.new(0, 0, 3)),
			math.clamp(3, JumpscareController.MinStartDistance, JumpscareController.MaxStartDistance)
		)
		t.eq(
			JumpscareController.startDistanceFor(Vector3.zero, Vector3.new(0, 0.2, 0)),
			JumpscareController.MinStartDistance,
			"never starts closer than the minimum"
		)
		t.eq(
			JumpscareController.startDistanceFor(Vector3.zero, Vector3.new(0, 0, 40)),
			JumpscareController.MaxStartDistance,
			"nor further than the maximum"
		)
		t.truthy(JumpscareController.MinStartDistance > FACE, "the lunge always has somewhere to go")
		local passed = JumpscareController.faceLock(CFrame.new(0 / 0, 0, 0), FACE)
		t.truthy(passed.Position.X ~= passed.Position.X, "a non-finite face is passed through as it is")
		t.eq(passed.LookVector, Vector3.new(0, 0, -1))
	end,

	["camera: the shake follows MotionScale; it peaks at the slam and stops at the cut"] = function(t: Expect)
		t.eq(JumpscareController.shakeEnvelope(-0.01), 0, "nothing before startAt")
		t.eq(JumpscareController.shakeEnvelope(LUNGE + HOLD), 0, "nothing after the cut")
		local slam = JumpscareController.shakeEnvelope(JumpscareController.SlamAt)
		t.truthy(slam > JumpscareController.shakeEnvelope(0), "the slam is the peak")
		t.truthy(slam > JumpscareController.shakeEnvelope(LUNGE + HOLD - 0.01), "decaying through the hold")
		t.truthy(JumpscareController.shakeEnvelope(LUNGE + HOLD - 0.01) > 0.3, "but sustained")
		t.eq(JumpscareController.shakeEnvelope(0 / 0), 0)

		local maxAngle = math.rad(CameraConfig.Shake.JumpscareAmplitude) * slam * 3 + 1e-6 -- |pitch| + |yaw| + |roll|
		local moved = false
		for i = 0, 60 do
			local elapsed = i * (LUNGE + HOLD) / 60
			local still = JumpscareController.shakeOffset(elapsed, 0, 11)
			t.truthy(near(still.Position, Vector3.zero, 1e-9) and angleOf(still) < 1e-9, "MotionScale 0: no shake")
			local full = JumpscareController.shakeOffset(elapsed, 1, 11)
			t.truthy(angleOf(full) <= maxAngle, "within the jumpscare amplitude")
			if angleOf(full) > math.rad(0.5) then
				moved = true
			end
			local half = JumpscareController.shakeOffset(elapsed, 0.5, 11)
			t.near(half.Position.Magnitude, full.Position.Magnitude / 2, 1e-6, "MotionScale scales it")
			t.truthy(angleOf(half) <= angleOf(full) + 1e-9, "half the motion never shakes more")
		end
		t.truthy(moved, "MotionScale 1: violent")
		t.truthy(angleOf(JumpscareController.shakeOffset(LUNGE + HOLD + 0.1, 1, 11)) < 1e-9, "still after the cut")

		-- The full camera: the face lock with the shake on top (none at MotionScale 0).
		local face = CFrame.new(2, 8, 2) * CFrame.Angles(0, math.rad(30), 0)
		for _, elapsed in { 0, 0.2, LUNGE, 1.2 } do
			local camera = JumpscareController.cameraCFrame(face, elapsed, 4, 0, 3)
			local lock = JumpscareController.faceLockCFrame(face, JumpscareController.lungeProgress(elapsed), 4, 0)
			t.truthy(near(camera.Position, lock.Position, 1e-6), "MotionScale 0: exactly the face lock")
			local shaken = JumpscareController.cameraCFrame(face, elapsed, 4, 1, 3)
			local toFace = (face.Position - shaken.Position).Unit
			t.truthy(shaken.LookVector:Dot(toFace) > math.cos(math.rad(15)), "shaken, the face stays in view")
		end
	end,

	["overlay: flashes follow FlashScale; a hard cut to black at the end, a beat, then a fade"] = function(t: Expect)
		local cutAt = LUNGE + HOLD
		local beat = JumpscareController.Beat
		local fade = JumpscareController.Fade
		local function at(elapsed: number, flashScale: number): JumpscareController.Overlay
			return JumpscareController.overlay(elapsed, flashScale, cutAt, beat)
		end
		local before = at(-0.05, 1)
		t.eq(before.flash + before.tint + before.vignette + before.black, 0, "nothing before startAt")

		t.truthy(at(0, 1).flash > 0.8, "a white flash at the snap")
		t.eq(at(0, 0).flash, 0, "FlashScale 0: no flash")
		t.near(at(0, 0.5).flash, at(0, 1).flash / 2, 1e-9, "FlashScale scales it")
		t.eq(at(0.2, 1).flash, 0, "and it is short")
		local slam = JumpscareController.SlamAt
		t.truthy(at(slam, 1).tint > 0.5, "a red flash at the slam")
		t.eq(at(slam, 0).tint, 0, "FlashScale 0: none")

		-- The vignette: on through the hold; it throbs with FlashScale, holds steady without it.
		local lowest, highest = math.huge, -math.huge
		local steadyLow, steadyHigh = math.huge, -math.huge
		for i = 0, 40 do
			local elapsed = 0.1 + i * (cutAt - 0.11) / 40
			local pulsing = at(elapsed, 1).vignette
			local steady = at(elapsed, 0).vignette
			lowest, highest = math.min(lowest, pulsing), math.max(highest, pulsing)
			steadyLow, steadyHigh = math.min(steadyLow, steady), math.max(steadyHigh, steady)
			t.eq(at(elapsed, 1).black, 0, "no black before the cut")
		end
		t.truthy(lowest > 0.2, "the vignette stays up")
		t.truthy(highest - lowest > 0.1, "and throbs")
		t.truthy(steadyHigh - steadyLow < 1e-6, "FlashScale 0: steady")

		-- The cut: black at once, held for the beat, then faded out over Fade.
		local cut = at(cutAt, 1)
		t.eq(cut.black, 1, "a hard cut to black")
		t.eq(cut.flash + cut.tint + cut.vignette, 0, "nothing over the black")
		t.eq(at(cutAt + beat, 0).black, 1, "held through the beat")
		local fading = at(cutAt + beat + fade / 2, 1).black
		t.truthy(fading > 0 and fading < 1, "fading")
		t.eq(at(cutAt + beat + fade, 1).black, 0, "gone")

		-- An aborted catch cuts early with the short beat.
		local aborted = JumpscareController.overlay(0.3, 1, 0.3, JumpscareController.AbortBeat)
		t.eq(aborted.black, 1, "an abort cuts at once")
		t.eq(JumpscareController.overlay(0.3 + JumpscareController.AbortBeat + fade, 1, 0.3, 0.2).black, 0)

		for i = 0, 50 do
			local o = at(i * 0.06 - 0.1, 1)
			for _, value in { o.flash, o.tint, o.vignette, o.black } do
				t.truthy(value >= 0 and value <= 1, "opacities stay in 0..1")
			end
		end

		-- The cut comes from the cue's endsAt.
		t.near(JumpscareController.holdLength(100, 100 + LUNGE + HOLD), LUNGE + HOLD, 1e-9)
		t.near(JumpscareController.holdLength(100, 101.2), 1.2, 1e-9)
		t.near(JumpscareController.holdLength(100, nil), LUNGE + HOLD, 1e-9, "missing: the lunge plus the hold")
		t.near(JumpscareController.holdLength(100, 99), LUNGE + HOLD, 1e-9, "before the start: the default")
		t.near(JumpscareController.holdLength(100, 500), LUNGE + HOLD, 1e-9, "absurd: the default")
	end,

	["light: the face is lit through the whole hold; only its stutter follows FlashScale"] = function(t: Expect)
		local cutAt = LUNGE + HOLD
		local hold = JumpscareController.LightHold
		local floor = hold * (1 - JumpscareController.LightStutter)
		t.eq(JumpscareController.faceLight(-0.01, 1, cutAt), 0, "dark before startAt")
		t.eq(JumpscareController.faceLight(cutAt, 1, cutAt), 0, "out with the cut")
		t.eq(JumpscareController.faceLight(0.5, 1, 0.4), 0, "out with an early (aborted) cut")
		t.truthy(JumpscareController.faceLight(0, 0, cutAt) > JumpscareController.faceLight(1.2, 0, cutAt), "a flare")
		local slam = JumpscareController.SlamAt
		t.truthy(
			JumpscareController.faceLight(slam, 0, cutAt) > JumpscareController.faceLight(slam + 0.2, 0, cutAt),
			"a second flare at the slam"
		)
		local stuttered = false
		for i = 0, 80 do
			local elapsed = i * (cutAt - 0.001) / 80
			local steady = JumpscareController.faceLight(elapsed, 0, cutAt)
			local full = JumpscareController.faceLight(elapsed, 1, cutAt)
			t.truthy(steady >= hold - 1e-9, "FlashScale 0: never below the held level")
			t.truthy(full >= floor - 1e-9 and full > 0, "FlashScale 1: stuttering, but the face stays lit")
			t.truthy(full <= steady + 1e-9, "the stutter only ever dims")
			if steady - full > 0.05 then
				stuttered = true
			end
		end
		t.truthy(stuttered, "FlashScale 1: it stutters")
		t.near(JumpscareController.faceLight(0 / 0, 1, cutAt), JumpscareController.faceLight(0, 1, cutAt), 1e-9)
	end,

	["witness: the jolt, the sting and the panic fall off with distance from the victim"] = function(t: Expect)
		local radius = JumpscareController.WitnessRadius
		local stingRadius = JumpscareController.StingRadius
		t.truthy(JumpscareController.witnessShake(0) > 0, "a jolt beside the victim")
		t.truthy(JumpscareController.witnessShake(5) > JumpscareController.witnessShake(20), "weaker further away")
		t.eq(JumpscareController.witnessShake(radius), 0, "none beyond the radius")
		t.eq(JumpscareController.witnessShake(0 / 0), 0)
		t.truthy(JumpscareController.witnessShake(0) <= CameraConfig.Shake.JumpscareAmplitude, "less than the victim's")

		t.eq(JumpscareController.witnessSting(0), JumpscareController.witnessSting(5), "full volume up close")
		t.truthy(JumpscareController.witnessSting(30) < JumpscareController.witnessSting(10), "quieter further away")
		t.truthy(JumpscareController.witnessSting(stingRadius - 1) > 0, "heard across the floor")
		t.eq(JumpscareController.witnessSting(stingRadius), 0, "not beyond it")
		t.eq(JumpscareController.witnessSting(math.huge), 0)

		t.truthy(JumpscareController.witnessPanic(0) > JumpscareController.witnessPanic(30), "panic falls off too")
		t.truthy(JumpscareController.witnessPanic(0) < 1, "a witness never panics like the victim")
		t.eq(JumpscareController.witnessPanic(radius + 1), 0)
		t.eq(JumpscareController.witnessPanic(-1), JumpscareController.witnessPanic(0), "a negative distance is 0")
	end,
}
