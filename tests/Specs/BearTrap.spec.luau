--!strict
-- Bear traps. BearTrapService's rules: the foot point and the pan zone (a jump clears it, a stride between polls is
-- swept), who may spring a trap, the look-down pry and the rescue, the Armed -> Caught -> Spent table, jaw motion
-- easing, and where the caught foot puts the root.
-- Tracking a built trap re-hosts its prompts onto their own Interactable attachments. Live runs on hand-built
-- characters over traps built through Builder.BuildProp: a foot springs a trap (35 damage, Trapped, prompts served to
-- the right people, jaws stepped shut after the cue lead), nobody else and no other trap gets the victim, the pry
-- needs the look down and leaves the jaws pried open, a teammate's rescue frees at once, a lethal snap keeps the
-- downed victim caught, death / leaving / EndRun release. BearTrapController's maths: the tilt, the pry progress and
-- its tremble, the hand jitter and target, a teammate's jolt. (Locks, teleports and prompt events need the engine:
-- CharacterService only seats and anchors characters it spawned.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)

local BearTrapBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.BearTrapBuilder)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local BearTrapService = require(ServerScriptService.Services.Mechanics.BearTrapService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local BearTrapController = require(StarterPlayer.StarterPlayerScripts.Controllers.Gameplay.BearTrapController)

type Expect = SpecRunner.Expect
type TriggerCheck = BearTrapService.TriggerCheck
type TrapState = BearTrapService.TrapState
type TrapEvent = BearTrapService.TrapEvent

local W = Attributes.World
local NAMES = BearTrapBuilder.Names
local MAX = GameConfig.MaxHealth
local BASEMENT: Enums.LayoutId = "Level0_Basement"
local HIP_HEIGHT = 2
local ROOT_SIZE = Vector3.new(2, 2, 1)
local LOOK_DOWN = math.rad(-60)

-- Rotated, off-origin floor points, far enough apart that no trigger volume reaches another.
local POINTS: { CFrame } = {
	CFrame.new(31.5, -84, 112.25) * CFrame.Angles(0, math.rad(-127), 0),
	CFrame.new(-12, -84, 40) * CFrame.Angles(0, math.rad(37), 0),
	CFrame.new(60, -84, 40) * CFrame.Angles(0, math.rad(90), 0),
	CFrame.new(-60, -84, -20) * CFrame.Angles(0, math.rad(-15), 0),
}

local ON_FOOT: { Enums.MoveState } = { "Standing", "Sprinting", "Crouching" }
local NOT_ON_FOOT: { Enums.MoveState } = {
	"VentCrawling",
	"VentScurrying",
	"DownedCrawling",
	"Treading",
	"Freestyle",
	"Underwater",
	"Hiding",
	"Trapped",
	"Grabbed",
	"Parachuting",
	"Scripted",
}
local NOT_ALIVE: { Enums.LifeState } = { "Lobby", "Downed", "Dead", "Spectating" }
local STATES: { TrapState } = { "Armed", "Caught", "Spent" }
local EVENTS: { TrapEvent } = { "Snap", "Pry", "Rescue", "Release" }

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Runs `fn` with Geometry's cooperative yielding off (specs never task.wait), restoring it afterwards.
local function quiet(fn: () -> ())
	local previous = Geometry.getYieldEvery()
	Geometry.setYieldEvery(0)
	local failure: any = nil
	xpcall(fn, function(err: any)
		failure = err
	end)
	Geometry.setYieldEvery(previous)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function near(a: Vector3, b: Vector3, epsilon: number): boolean
	return (a - b).Magnitude <= epsilon
end

local function cframeNear(a: CFrame, b: CFrame, epsilon: number): boolean
	if not near(a.Position, b.Position, epsilon) then
		return false
	end
	local ax, ay, az = a:ToOrientation()
	local bx, by, bz = b:ToOrientation()
	return math.abs(MathUtil.angleDelta(ax, bx)) <= epsilon
		and math.abs(MathUtil.angleDelta(ay, by)) <= epsilon
		and math.abs(MathUtil.angleDelta(az, bz)) <= epsilon
end

-- A trap built at POINTS[index] the way WorldService builds plan props (into a folder outside Workspace.Runtime).
local function buildTrap(index: number, folder: Folder): Model
	local plan: Types.PlannedProp = {
		kind = BearTrapBuilder.Kind,
		anchorId = "SpecTrap_" .. index,
		levelId = BASEMENT,
		cframe = POINTS[index],
		variant = 300 + index,
	}
	local built = Builder.BuildProp(plan, folder, Random.new(index))
	assert(built ~= nil and built:IsA("Model"), "the bear trap builder builds a Model")
	return built
end

local function attachment(model: Model, name: string): Attachment
	local found = PropKit.findAttachment(model, name)
	assert(found, model.Name .. " has " .. name)
	return found
end

local function promptOf(model: Model, kind: Enums.PromptKind): ProximityPrompt
	local found = PropKit.findPrompt(model, kind)
	assert(found, model.Name .. " has a " .. kind .. " prompt")
	return found
end

local function countPrompts(model: Model, kind: Enums.PromptKind): number
	local count = 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ProximityPrompt") and descendant:GetAttribute(W.PromptKind) == kind then
			count += 1
		end
	end
	return count
end

-- Where a standing character's root sits over `floor` (its feet point exactly on it).
local function standingAt(floor: Vector3): CFrame
	return CFrame.new(floor + Vector3.new(0, HIP_HEIGHT + ROOT_SIZE.Y / 2, 0))
end

-- Moves a hand-built root. Position is written too: the engine derives it from CFrame, the Lune harness does not,
-- and LifeStateService's downed gasp cue reads it.
local function place(root: BasePart, cframe: CFrame)
	root.CFrame = cframe
	root.Position = cframe.Position
end

local nextUserId = 8800

local function fakePlayer(at: CFrame): (Player, BasePart, Humanoid)
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "BearTrapSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	local model = Instance.new("Model")
	model.Name = player.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = ROOT_SIZE
	place(root, at)
	root.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = HIP_HEIGHT
	humanoid.MaxHealth = MAX
	humanoid.Health = MAX
	humanoid.Parent = model
	player.Character = model
	return player, root, humanoid
end

-- Runs `body` with `players` in a live run (stats, move states, life states and traps), always tearing it down.
local function inRun(players: { Player }, body: () -> ())
	Net.Server.setup()
	BearTrapService.Init()
	local ctx: Types.RunContext = {
		runId = "bear-trap-spec",
		seed = 1,
		difficulty = "Standard",
		participants = players,
		startedAt = 1000,
	}
	RunStatsService.BeginRun(ctx)
	PlayerStateService.BeginRun(ctx)
	LifeStateService.BeginRun(ctx)
	BearTrapService.BeginRun(ctx)
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end)
	BearTrapService.EndRun()
	LifeStateService.EndRun()
	PlayerStateService.EndRun()
	RunStatsService.EndRun()
	for _, player in players do
		BearTrapService.OnPlayerRemoving(player)
		LifeStateService.OnPlayerRemoving(player)
		PlayerStateService.OnPlayerRemoving(player)
	end
	if failure ~= nil then
		error(failure, 0)
	end
end

local function lookDown(player: Player, pitch: number)
	PlayerStateService.SubmitLook(player, MathUtil.quantizeAngle(0), MathUtil.quantizeAngle(pitch))
end

local function jawTransform(model: Model): CFrame
	local transform = PropKit.leafTransform(model, NAMES.JawA)
	assert(transform, "JawA has a rest pose")
	return transform
end

local function baseCheck(overrides: { [string]: any }?): TriggerCheck
	local check: TriggerCheck = {
		live = true,
		participant = true,
		lifeState = "Alive",
		caught = false,
		hasBody = true,
		controlLock = "None",
		moveState = "Standing",
		graced = false,
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

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["rules: the pan zone holds a walker's feet, not a jumper's or a neighbour's; strides are swept"] = function(
		t: Expect
	)
		quiet(function()
			local folder = Instance.new("Folder")
			local model = buildTrap(1, folder)
			local frame = model.WorldPivot
			local floor = frame.Position
			local volume = model:FindFirstChild(NAMES.TriggerVolume)
			assert(volume and volume:IsA("BasePart"), "the trap has a TriggerVolume part")
			local foot = BearTrapService.footPoint(standingAt(floor), ROOT_SIZE, HIP_HEIGHT)
			t.truthy(near(foot, floor, 1e-4), "a standing root's feet are on the floor under it")

			local zoneCFrame, zoneSize = BearTrapService.panZone(volume.CFrame, volume.Size, floor)
			local press = BearTrapService.PressHeight
			t.near(zoneSize.X, volume.Size.X, 1e-4, "the volume's footprint")
			t.near(zoneSize.Z, volume.Size.Z, 1e-4)
			local bottom = frame:PointToObjectSpace(zoneCFrame.Position).Y - zoneSize.Y / 2
			local top = bottom + zoneSize.Y
			t.near(bottom, frame:PointToObjectSpace(volume.CFrame.Position).Y - volume.Size.Y / 2, 1e-4, "its bottom")
			t.near(top, press, 1e-4, "up to PressHeight above the floor")

			local function at(x: number, y: number, z: number): Vector3
				return frame:PointToWorldSpace(Vector3.new(x, y, z))
			end
			local function springs(from: Vector3?, to: Vector3): boolean
				return BearTrapService.footSprings(zoneCFrame, zoneSize, from, to)
			end
			t.truthy(springs(nil, floor), "feet on the pan")
			t.truthy(springs(nil, at(0, 0.4, 0)), "a raised heel still counts")
			t.truthy(springs(nil, at(1, 0, 0.9)), "a foot on the jaws' edge")
			t.falsy(springs(nil, at(1.4, 0, 0)), "a step past the jaws")
			t.falsy(springs(nil, at(0, 0, -1.3)), "a step beside the jaws")
			t.truthy(BearTrapService.footInTrigger(volume.CFrame, volume.Size, at(0, 1.5, 0)), "inside the volume...")
			t.falsy(springs(nil, at(0, 1.5, 0)), "...but a foot in mid-jump presses no pan")
			t.falsy(springs(nil, at(0, 4, 0)), "feet on the floor above")
			t.falsy(springs(nil, at(0, -0.6, 0)), "feet on the floor below")
			t.falsy(springs(nil, Vector3.new(math.sqrt(-1), 0, 0)), "a non-finite foot never springs a trap")

			-- Between samples: a sprinter's stride across the jaws springs them; a jump over them or a stride beside
			-- them does not; a teleport is not a stride.
			t.truthy(springs(at(-1.9, 0, 0.2), at(1.9, 0, -0.2)), "a stride straight across")
			t.truthy(springs(at(-0.5, 0, 1.6), at(1.6, 0, -0.5)), "a stride across a corner")
			t.falsy(springs(at(-1.9, 0, 1.5), at(1.9, 0, 1.5)), "a stride alongside")
			t.falsy(springs(at(-1.9, 1.5, 0), at(1.9, 1.5, 0)), "a jump over")
			local far = BearTrapService.MaxSweepStep + 1
			t.falsy(springs(at(-far, 0, 0), at(1.5, 0, 0)), "a teleport across is not a stride")
			t.falsy(springs(at(-1.9, 0, 0), at(-1.6, 0, 0)), "a stride short of the jaws")

			local box = CFrame.new(0, 0, 0)
			local size = Vector3.new(2, 2, 2)
			t.truthy(BearTrapService.segmentInBox(box, size, Vector3.new(-3, 0, 0), Vector3.new(3, 0, 0)), "through")
			t.truthy(BearTrapService.segmentInBox(box, size, Vector3.new(0, 0, 0), Vector3.new(0, 0, 0)), "a point")
			t.falsy(BearTrapService.segmentInBox(box, size, Vector3.new(-3, 2, 0), Vector3.new(3, 2, 0)), "above")
			t.falsy(BearTrapService.segmentInBox(box, size, Vector3.new(-3, 0, 0), Vector3.new(-2, 0, 0)), "short")
			t.truthy(BearTrapService.segmentInBox(box, size, Vector3.new(2, 2, 0), Vector3.new(0, 0, 0)), "ends in")
			t.falsy(
				BearTrapService.segmentInBox(box, size, Vector3.new(math.sqrt(-1), 0, 0), Vector3.new(0, 0, 0)),
				"non-finite"
			)
			folder:Destroy()
		end)
	end,

	["rules: only Alive, free, on-foot participants who were not just moved spring a trap"] = function(t: Expect)
		t.eq(verdict(BearTrapService.canTrigger(baseCheck())), "ok")
		t.eq(verdict(BearTrapService.canTrigger(baseCheck({ live = false }))), "NoRun")
		t.eq(verdict(BearTrapService.canTrigger(baseCheck({ participant = false }))), "NotParticipant")
		for _, state: Enums.LifeState in NOT_ALIVE do
			t.eq(verdict(BearTrapService.canTrigger(baseCheck({ lifeState = state }))), "LifeState", state)
		end
		t.eq(verdict(BearTrapService.canTrigger(baseCheck({ caught = true }))), "Caught", "one trap at a time")
		t.eq(verdict(BearTrapService.canTrigger(baseCheck({ hasBody = false }))), "NoBody")
		t.eq(verdict(BearTrapService.canTrigger(baseCheck({ controlLock = "Locker" }))), "Locked")
		t.eq(verdict(BearTrapService.canTrigger(baseCheck({ graced = true }))), "Grace", "a server move")
		for _, state: Enums.MoveState in ON_FOOT do
			t.eq(verdict(BearTrapService.canTrigger(baseCheck({ moveState = state }))), "ok", state)
		end
		for _, state: Enums.MoveState in NOT_ON_FOOT do
			t.eq(verdict(BearTrapService.canTrigger(baseCheck({ moveState = state }))), "MoveState", state)
		end
	end,

	["rules: a pry needs its victim, Alive or Downed, looking down; a running pry may lift by the slack"] = function(
		t: Expect
	)
		local threshold = GameConfig.TrapLookDownPitch
		local slack = BearTrapService.LookUpSlack
		t.truthy(BearTrapService.lookingDown(math.rad(threshold)), "exactly at the threshold")
		t.truthy(BearTrapService.lookingDown(math.rad(-89)), "straight down")
		t.falsy(BearTrapService.lookingDown(math.rad(threshold + 1)), "just above it")
		t.falsy(BearTrapService.lookingDown(0), "looking ahead")
		t.truthy(BearTrapService.lookingDown(math.rad(threshold + slack - 1), true), "a running pry lifts a little")
		t.falsy(BearTrapService.lookingDown(math.rad(threshold + slack + 1), true), "past the slack it breaks")
		t.falsy(BearTrapService.lookingDown(math.sqrt(-1), true), "no look, no pry")

		local function pry(overrides: { [string]: any }, cleared: { string }?): string
			local check: BearTrapService.PryCheck = {
				userId = 1,
				victimUserId = 1,
				lifeState = "Alive",
				pitch = LOOK_DOWN,
				channelling = false,
			}
			for key, value in overrides do
				(check :: any)[key] = value
			end
			for _, key in (cleared or {}) :: { string } do
				(check :: any)[key] = nil
			end
			return verdict(BearTrapService.pryEligible(check))
		end
		t.eq(pry({}), "ok")
		t.eq(pry({ lifeState = "Downed" }), "ok", "a downed victim can still pry")
		t.eq(pry({ victimUserId = 2 }), "NotVictim")
		t.eq(pry({}, { "victimUserId" }), "Released", "nobody caught")
		t.eq(pry({ lifeState = "Dead" }), "LifeState")
		t.eq(pry({ lifeState = "Lobby" }), "LifeState")
		t.eq(pry({ pitch = 0 }), BearTrapService.LookDownHint, "the refusal is the look-down hint")
		t.eq(pry({ pitch = math.rad(threshold + slack / 2) }), BearTrapService.LookDownHint, "starting needs it all")
		t.eq(pry({ pitch = math.rad(threshold + slack / 2), channelling = true }), "ok", "continuing tolerates it")
		t.eq(BearTrapService.LookDownHint, "Hud.Trapped")
	end,

	["rules: a rescue needs another Alive player who is not caught"] = function(t: Expect)
		local function rescue(overrides: { [string]: any }, cleared: { string }?): string
			local check: BearTrapService.RescueCheck = {
				userId = 2,
				victimUserId = 1,
				lifeState = "Alive",
				rescuerCaught = false,
			}
			for key, value in overrides do
				(check :: any)[key] = value
			end
			for _, key in (cleared or {}) :: { string } do
				(check :: any)[key] = nil
			end
			return verdict(BearTrapService.rescueEligible(check))
		end
		t.eq(rescue({}), "ok")
		t.eq(rescue({ userId = 1 }), "Victim", "the victim pries; they cannot rescue themselves")
		t.eq(rescue({}, { "victimUserId" }), "Released")
		for _, state: Enums.LifeState in NOT_ALIVE do
			t.eq(rescue({ lifeState = state }), "LifeState", state)
		end
		t.eq(rescue({ rescuerCaught = true }), "Caught", "a caught teammate works on their own jaws")
	end,

	["rules: Armed -> Caught -> Spent; nothing re-arms a trap"] = function(t: Expect)
		local expected: { [string]: { [string]: string } } = {
			Armed = { Snap = "Caught", Pry = "-", Rescue = "-", Release = "-" },
			Caught = { Snap = "-", Pry = "Spent", Rescue = "Spent", Release = "Spent" },
			Spent = { Snap = "-", Pry = "-", Rescue = "-", Release = "-" },
		}
		for _, state: TrapState in STATES do
			for _, event: TrapEvent in EVENTS do
				local result = BearTrapService.nextState(state, event)
				t.eq(result or "-", expected[state][event], state .. " + " .. event)
			end
		end
	end,

	["motions: the snap slams shut after the cue lead; the pry eases to the pried angle"] = function(t: Expect)
		local lead = GameConfig.OneShotLead
		local seconds = BearTrapService.SnapSeconds
		t.truthy(seconds > 0 and seconds <= 0.1, "a snap is a few frames")
		local function snapAt(elapsed: number): (number, boolean)
			return BearTrapService.motionOpenness({
				from = 1,
				to = 0,
				delay = lead,
				seconds = seconds,
				ease = "In",
				elapsed = elapsed,
			})
		end
		local open, done = snapAt(0)
		t.eq(open, 1, "armed until the lead runs out")
		t.falsy(done)
		t.eq((snapAt(lead)), 1, "the jaws start to move at the lead")
		t.near((snapAt(lead + seconds / 2)), 0.75, 1e-6, "accelerating: a quarter of the way at half time")
		local shut, finished = snapAt(lead + seconds)
		t.near(shut, 0, 1e-9, "shut")
		t.truthy(finished)
		local last = 1
		for step = 0, 20 do
			local value = snapAt(lead + seconds * step / 20)
			t.truthy(value <= last + 1e-12, "the snap never reopens")
			last = value
		end

		local pried = BearTrapService.PriedOpenness
		t.truthy(pried > 0.2 and pried < 0.8, "pried open, far from re-armed")
		local function pryAt(elapsed: number): number
			return (
				BearTrapService.motionOpenness({
					from = 0,
					to = pried,
					delay = lead,
					seconds = BearTrapService.PryOpenSeconds,
					ease = "Out",
					elapsed = elapsed,
				})
			)
		end
		t.eq(pryAt(0), 0)
		t.near(pryAt(lead + BearTrapService.PryOpenSeconds / 2), pried * 0.875, 1e-6, "decelerating")
		t.near(pryAt(lead + BearTrapService.PryOpenSeconds + 5), pried, 1e-9, "holds the pried angle")
	end,

	["caught root: the trapped pose's right foot lands on the leg point, heading kept, upright"] = function(t: Expect)
		local offset = BearTrapService.caughtFootOffset(-0.5, 2, -3)
		t.truthy(offset.X > 0, "the right foot, whichever sign the hip pivot has")
		t.near(offset.Y, -3, 1e-9, "the sole on the floor under the root")
		t.truthy(offset.Z < 0, "ahead of the root")
		local heading = math.rad(30)
		local root = CFrame.new(10, 5, 10) * CFrame.Angles(0, heading, 0) * CFrame.Angles(math.rad(8), 0, math.rad(-4))
		local target = Vector3.new(12, 1.5, 7)
		local seated = BearTrapService.caughtRootCFrame(root, offset, target)
		t.truthy(near(seated:PointToWorldSpace(offset), target, 1e-4), "the caught foot is on the leg point")
		t.truthy(near(seated.UpVector, Vector3.new(0, 1, 0), 1e-6), "upright")
		local yaw = MathUtil.yawPitchFromVector(seated.LookVector)
		t.near(MathUtil.angleDelta(yaw, heading), 0, 1e-4, "facing where the victim faced")
		t.near(seated.Position.Y, target.Y + 3, 1e-4, "the root rides HipHeight above the trap's floor")
		local flat = BearTrapService.caughtRootCFrame(CFrame.new(0, 3, 0), offset, target)
		t.truthy(near(flat:PointToWorldSpace(offset), target, 1e-4), "works from an unrotated root")
	end,

	["tracking: prompts move to their own Interactable attachments; an armed trap serves nothing"] = function(
		t: Expect
	)
		quiet(function()
			local folder = Instance.new("Folder")
			local model = buildTrap(2, folder)
			t.truthy(BearTrapService.Track(model), "a built trap is tracked")
			t.eq(BearTrapService.GetState(model), "Armed")
			local promptPoint = attachment(model, NAMES.PromptPoint)
			local rescuePoint = attachment(model, BearTrapService.RescuePointName)
			t.truthy(promptPoint:HasTag(Tags.Interactable), "the PromptPoint hosts the pry")
			t.truthy(rescuePoint:HasTag(Tags.Interactable), "the RescuePoint hosts the rescue")
			t.eq(rescuePoint.Parent, promptPoint.Parent, "siblings on the base")
			t.truthy(cframeNear(rescuePoint.CFrame, promptPoint.CFrame, 1e-6), "in the same place")
			local pry = promptOf(model, "TrapPry")
			local rescue = promptOf(model, "TrapRescue")
			t.eq(pry.Parent, promptPoint)
			t.eq(rescue.Parent, rescuePoint)
			t.eq(countPrompts(model, "TrapPry"), 1, "one pry prompt")
			t.eq(countPrompts(model, "TrapRescue"), 1, "one rescue prompt")
			t.eq(pry:GetAttribute(W.BaseHold), GameConfig.TrapSoloPrySeconds, "the copy keeps its hold")
			t.eq(rescue:GetAttribute(W.BaseHold), GameConfig.TrapRescueSeconds)
			t.falsy(pry.Enabled, "still disabled")
			t.falsy(rescue.Enabled, "still disabled")
			local pryHandler, pryHost = InteractionService.Resolve(pry)
			local rescueHandler, rescueHost = InteractionService.Resolve(rescue)
			t.eq(pryHost, promptPoint, "InteractionService files the pry under its own host")
			t.eq(rescueHost, rescuePoint, "and the rescue under its own")
			t.eq(pryHandler, nil, "nobody to free: no pry")
			t.eq(rescueHandler, nil, "nobody to free: no rescue")
			local hostA, hostB = BearTrapService.GetHosts(model)
			t.eq(hostA, promptPoint)
			t.eq(hostB, rescuePoint)

			t.truthy(BearTrapService.Track(model), "tracking again is harmless")
			local rescuePoints = 0
			for _, descendant in model:GetDescendants() do
				if descendant.Name == BearTrapService.RescuePointName then
					rescuePoints += 1
				end
			end
			t.eq(rescuePoints, 1, "one RescuePoint")
			t.falsy(BearTrapService.Track(Instance.new("Model")), "a model that is not a trap is refused")
			folder:Destroy()
			BearTrapService.EndRun()
			t.eq(BearTrapService.GetState(model), nil, "EndRun forgets every trap")
		end)
	end,

	["live: a foot snaps the trap; only its victim, looking down, pries it open, and it stays pried"] = function(
		t: Expect
	)
		quiet(function()
			local folder = Instance.new("Folder")
			local first = buildTrap(1, folder)
			local second = buildTrap(2, folder)
			local firstFloor = first.WorldPivot.Position
			local secondFloor = second.WorldPivot.Position
			local victim, victimRoot, victimHumanoid = fakePlayer(standingAt(firstFloor))
			local teammate, teammateRoot = fakePlayer(standingAt(firstFloor + Vector3.new(6, 0, 0)))
			local freedEvents: { string } = {}
			local connection = BearTrapService.Freed:Connect(function(player: Player, _model: Model, event: string)
				table.insert(freedEvents, player.Name .. ":" .. event)
			end)
			inRun({ victim, teammate }, function()
				t.truthy(BearTrapService.Track(first))
				t.truthy(BearTrapService.Track(second))
				local open = BearTrapBuilder.JawOpenAngle
				t.truthy(cframeNear(jawTransform(first), CFrame.Angles(open, 0, 0), 1e-4), "armed before the step")

				BearTrapService.Poll()
				t.eq(BearTrapService.GetTrapOf(victim), first, "the foot sprang the trap it stands in")
				t.eq(BearTrapService.GetVictim(first), victim)
				t.eq(BearTrapService.GetState(first), "Caught")
				t.eq(BearTrapService.GetTrapOf(teammate), nil, "a teammate beside it is safe")
				t.eq(first:GetAttribute(W.Armed), false, "disarmed")
				t.eq(first:GetAttribute(W.TrappedUserId), victim.UserId)
				t.eq(PlayerStateService.GetMoveState(victim), "Trapped")
				t.eq(victimHumanoid.WalkSpeed, 0, "held in place")
				t.eq(LifeStateService.GetHealth(victim), MAX - GameConfig.TrapDamage, "35 damage")
				t.eq(LifeStateService.GetState(victim), "Alive")
				t.eq(RunStatsService.Get(victim, "TrapsTriggered"), 1)

				local pryHost, rescueHost = BearTrapService.GetHosts(first)
				assert(pryHost and rescueHost, "the trap has its hosts")
				local pry = promptOf(first, "TrapPry")
				local rescue = promptOf(first, "TrapRescue")
				t.eq(pryHost:GetAttribute(W.OwnerUserId), victim.UserId, "the pry is the victim's (Self)")
				t.eq(rescueHost:GetAttribute(W.OwnerUserId), victim.UserId, "the rescue is everyone else's")
				t.eq((InteractionService.Resolve(pry)), BearTrapService.PryHandler, "the pry is served")
				t.eq((InteractionService.Resolve(rescue)), BearTrapService.RescueHandler, "the rescue is served")

				-- The jaws wait for the cues, then slam.
				BearTrapService.StepMotions(GameConfig.OneShotLead / 2)
				t.truthy(cframeNear(jawTransform(first), CFrame.Angles(open, 0, 0), 1e-4), "still open in the lead")
				local pan = PropKit.leafTransform(first, NAMES.Pan)
				t.truthy(pan and cframeNear(pan, CFrame.Angles(-BearTrapBuilder.PanTilt, 0, 0), 1e-4), "pan down")
				BearTrapService.StepMotions(1)
				t.truthy(cframeNear(jawTransform(first), CFrame.new(), 1e-4), "snapped shut")

				-- Nobody else, and no other trap.
				place(teammateRoot, standingAt(firstFloor))
				BearTrapService.Poll()
				t.eq(BearTrapService.GetTrapOf(teammate), nil, "two players never share a trap")
				place(victimRoot, standingAt(secondFloor))
				BearTrapService.Poll()
				t.eq(BearTrapService.GetState(second), "Armed", "a caught player springs nothing else")
				t.eq(BearTrapService.GetTrapOf(victim), first)
				place(victimRoot, standingAt(firstFloor))
				place(teammateRoot, standingAt(firstFloor + Vector3.new(6, 0, 0)))

				-- The pry: the victim alone, looking down.
				local pryCanUse = BearTrapService.PryHandler.canUse
				local rescueCanUse = BearTrapService.RescueHandler.canUse
				assert(pryCanUse and rescueCanUse, "both handlers judge their players")
				t.eq(verdict(pryCanUse(victim, pry, pryHost)), "Hud.Trapped", "looking ahead")
				lookDown(victim, LOOK_DOWN)
				t.eq(verdict(pryCanUse(victim, pry, pryHost)), "ok", "looking down")
				lookDown(teammate, LOOK_DOWN)
				t.eq(verdict(pryCanUse(teammate, pry, pryHost)), "NotVictim")
				t.eq(verdict(rescueCanUse(victim, rescue, rescueHost)), "Victim")
				t.eq(verdict(rescueCanUse(teammate, rescue, rescueHost)), "ok")

				BearTrapService.PryHandler.onComplete(victim, pry, pryHost)
				t.eq(BearTrapService.GetTrapOf(victim), nil, "freed")
				t.eq(BearTrapService.GetState(first), "Spent")
				t.eq(first:GetAttribute(W.TrappedUserId), nil)
				t.eq(first:GetAttribute(W.Armed), false, "never re-armed")
				t.eq(PlayerStateService.GetMoveState(victim), "Standing", "walking again")
				t.eq(victimHumanoid.WalkSpeed, GameConfig.WalkSpeed)
				t.eq(pryHost:GetAttribute(W.OwnerUserId), nil)
				t.eq((InteractionService.Resolve(pry)), nil, "the pry closes")
				t.eq((InteractionService.Resolve(rescue)), nil, "the rescue closes")
				t.eq(verdict(pryCanUse(victim, pry, pryHost)), "Released")
				BearTrapService.StepMotions(1)
				local pried = CFrame.Angles(open * BearTrapService.PriedOpenness, 0, 0)
				t.truthy(cframeNear(jawTransform(first), pried, 1e-4), "the jaws stay pried open")

				t.falsy(BearTrapService.Snap(first, teammate), "a spent trap never snaps again")
				t.falsy(BearTrapService.Free(first, teammate), "nobody left to free")
				place(teammateRoot, standingAt(firstFloor))
				BearTrapService.Poll()
				t.eq(BearTrapService.GetTrapOf(teammate), nil, "stepping into a spent trap is safe")
			end)
			connection:Disconnect()
			t.eq(table.concat(freedEvents, ","), victim.Name .. ":Pry")
			-- Kept, not destroyed: InteractionService still files the prompt hosts this run served (it untracks a host
			-- when its tag goes, which never happens outside the DataModel), and Lune cannot read destroyed instances.
		end)
	end,

	["live: a rescue frees at once; a lethal snap keeps the downed victim; death, leaving and EndRun release"] = function(
		t: Expect
	)
		quiet(function()
			local folder = Instance.new("Folder")
			local models: { Model } = {}
			for index = 1, #POINTS do
				table.insert(models, buildTrap(index, folder))
			end
			local victim, victimRoot = fakePlayer(standingAt(models[1].WorldPivot.Position + Vector3.new(0, 0, 8)))
			local teammate, teammateRoot = fakePlayer(standingAt(models[1].WorldPivot.Position + Vector3.new(8, 0, 0)))
			local straggler, stragglerRoot =
				fakePlayer(standingAt(models[1].WorldPivot.Position + Vector3.new(-8, 0, 0)))
			inRun({ victim, teammate, straggler }, function()
				for _, model in models do
					t.truthy(BearTrapService.Track(model))
				end
				local rescueCanUse = BearTrapService.RescueHandler.canUse
				local pryCanUse = BearTrapService.PryHandler.canUse
				assert(rescueCanUse and pryCanUse, "both handlers judge their players")

				-- A teammate's rescue.
				t.truthy(BearTrapService.Snap(models[1], victim))
				local _, rescueHost = BearTrapService.GetHosts(models[1])
				assert(rescueHost, "the first trap has a rescue host")
				local rescue = promptOf(models[1], "TrapRescue")
				t.eq(verdict(rescueCanUse(teammate, rescue, rescueHost)), "ok")
				BearTrapService.RescueHandler.onComplete(teammate, rescue, rescueHost)
				t.eq(BearTrapService.GetTrapOf(victim), nil, "rescued")
				t.eq(BearTrapService.GetState(models[1]), "Spent")
				t.eq(PlayerStateService.GetMoveState(victim), "Standing")

				-- A snap that downs: still caught, still prying.
				LifeStateService.Damage(victim, LifeStateService.GetHealth(victim) - 10, "Spec")
				t.eq(LifeStateService.GetHealth(victim), 10, "too weak for another snap")
				place(victimRoot, standingAt(models[2].WorldPivot.Position))
				BearTrapService.Poll()
				t.eq(BearTrapService.GetTrapOf(victim), models[2], "the second trap took them")
				t.eq(LifeStateService.GetState(victim), "Downed", "the snap downed them")
				t.eq(BearTrapService.GetTrapOf(victim), models[2], "and they are still caught")
				t.eq(PlayerStateService.GetMoveState(victim), "Trapped", "Trapped outranks the crawl")
				local pryHost = BearTrapService.GetHosts(models[2])
				assert(pryHost, "the second trap has a pry host")
				lookDown(victim, LOOK_DOWN)
				t.eq(verdict(pryCanUse(victim, promptOf(models[2], "TrapPry"), pryHost)), "ok", "downed, still prying")
				t.eq(RunStatsService.Get(victim, "TrapsTriggered"), 2)

				-- Death releases (the jaws stay shut on the body).
				LifeStateService.Execute(victim, "Spec")
				t.eq(BearTrapService.GetTrapOf(victim), nil, "death releases the trap")
				t.eq(BearTrapService.GetState(models[2]), "Spent")
				t.eq(models[2]:GetAttribute(W.TrappedUserId), nil)
				t.truthy(PlayerStateService.GetMoveState(victim) ~= "Trapped", "the override is gone")
				BearTrapService.StepMotions(1)
				t.truthy(cframeNear(jawTransform(models[2]), CFrame.new(), 1e-4), "released jaws stay shut")
				place(victimRoot, standingAt(models[3].WorldPivot.Position))
				BearTrapService.Poll()
				t.eq(BearTrapService.GetState(models[3]), "Armed", "the dead spring nothing")
				place(victimRoot, standingAt(models[1].WorldPivot.Position + Vector3.new(0, 0, 8)))

				-- Leaving releases.
				t.truthy(BearTrapService.Snap(models[3], teammate))
				BearTrapService.OnPlayerRemoving(teammate)
				t.eq(BearTrapService.GetTrapOf(teammate), nil, "leaving releases the trap")
				t.eq(BearTrapService.GetState(models[3]), "Spent")
				t.truthy(PlayerStateService.GetMoveState(teammate) ~= "Trapped")
				place(teammateRoot, standingAt(models[4].WorldPivot.Position))
				BearTrapService.Poll()
				t.eq(BearTrapService.GetState(models[4]), "Armed", "a player who left springs nothing")

				-- A stride across the jaws between two polls springs them.
				local fourth = models[4].WorldPivot
				place(stragglerRoot, standingAt(fourth:PointToWorldSpace(Vector3.new(-1.9, 0, 0.3))))
				BearTrapService.Poll()
				t.eq(BearTrapService.GetTrapOf(straggler), nil, "short of the jaws")
				place(stragglerRoot, standingAt(fourth:PointToWorldSpace(Vector3.new(1.9, 0, -0.3))))
				BearTrapService.Poll()
				t.eq(BearTrapService.GetTrapOf(straggler), models[4], "the stride across sprang them")

				-- EndRun releases whoever is still caught and forgets every trap.
				BearTrapService.EndRun()
				t.eq(BearTrapService.GetTrapOf(straggler), nil, "EndRun frees the last victim")
				t.eq(BearTrapService.GetState(models[4]), nil, "and forgets the traps")
				t.truthy(PlayerStateService.GetMoveState(straggler) ~= "Trapped")
				BearTrapService.Poll()
				t.eq(BearTrapService.GetTrapOf(straggler), nil, "no run, no traps")
			end)
			-- Kept, not destroyed: InteractionService still files the prompt hosts this run served (it untracks a host
			-- when its tag goes, which never happens outside the DataModel), and Lune cannot read destroyed instances.
		end)
	end,

	["client: the tilt aims at the leg, never shallower than TrappedLookDown, never past the camera's floor"] = function(
		t: Expect
	)
		local eye = Vector3.new(4, 10, -2)
		t.eq(BearTrapController.tiltPitch(eye, eye - Vector3.new(0, 4.5, 0.3)), CameraConfig.Pitch.Min, "under the eye")
		t.eq(
			BearTrapController.tiltPitch(eye, eye + Vector3.new(0, -1, -20)),
			CameraConfig.Pitch.TrappedLookDown,
			"a leg far ahead still tilts the head down"
		)
		local steep = BearTrapController.tiltPitch(eye, eye + Vector3.new(0, -4, -2))
		t.near(steep, math.deg(math.atan2(-4, 2)), 1e-3, "aimed at the leg")
		t.eq(BearTrapController.tiltPitch(eye, eye), CameraConfig.Pitch.TrappedLookDown, "no offset")

		local maxPitch = BearTrapController.TrappedPitchMax
		t.truthy(maxPitch > CameraConfig.Pitch.TrappedLookDown, "the head may come back up a little")
		t.truthy(maxPitch < 0, "but never above the horizon")
		t.truthy(
			GameConfig.TrapLookDownPitch > CameraConfig.Pitch.Min and GameConfig.TrapLookDownPitch < maxPitch,
			"the pry threshold lies inside the trapped range, so it can be met and broken"
		)
	end,

	["client: the pry trembles only while it runs, building with its progress"] = function(t: Expect)
		local me = 41
		local function progress(overrides: { [string]: any }): number?
			local input: BearTrapController.PryInput = {
				myUserId = me,
				serverActor = nil,
				serverStartedAt = nil,
				serverDuration = nil,
				serverNow = 200,
				holdSince = nil,
				holdSeconds = GameConfig.TrapSoloPrySeconds,
				clock = 50,
			}
			for key, value in overrides do
				(input :: any)[key] = value
			end
			return BearTrapController.pryProgress(input)
		end
		t.eq(progress({}), nil, "not prying")
		t.near(progress({ serverActor = me, serverStartedAt = 198, serverDuration = 5 }) or -1, 0.4, 1e-9, "server")
		t.eq(progress({ serverActor = me, serverStartedAt = 190, serverDuration = 5 }), 1, "clamped")
		t.eq(progress({ serverActor = 99, serverStartedAt = 198, serverDuration = 5 }), nil, "someone else's channel")
		local grace = BearTrapController.ConfirmGrace
		t.near(progress({ holdSince = 50 - grace / 2 }) or -1, grace / 2 / GameConfig.TrapSoloPrySeconds, 1e-9)
		t.eq(progress({ holdSince = 50 - grace - 0.01 }), nil, "the server never confirmed the hold")
		t.eq(progress({ serverActor = me, serverStartedAt = 198, serverDuration = 0, holdSince = 10 }), nil)

		t.near(BearTrapController.trembleIntensity(0), 0.25, 1e-9, "never still")
		t.near(BearTrapController.trembleIntensity(1), 1, 1e-9, "full at the end")
		local last = 0
		for step = 0, 10 do
			local value = BearTrapController.trembleIntensity(step / 10)
			t.truthy(value >= last, "builds")
			last = value
		end
		t.truthy(BearTrapController.trembleAmplitude(1) > BearTrapController.trembleAmplitude(0), "harder at the end")
		t.truthy(BearTrapController.trembleAmplitude(0) > 0, "a tremble, not a stillness")
		t.truthy(BearTrapController.trembleAmplitude(1) < CameraConfig.Shake.ImpactAmplitude, "smaller than a hit")
	end,

	["client: the hands shake on the jaws over the leg; teammates feel a nearby snap"] = function(t: Expect)
		t.truthy(cframeNear(BearTrapController.handJitter(3.2, 0, 7), CFrame.new(), 1e-9), "still at zero intensity")
		for step = 0, 12 do
			local jitter = BearTrapController.handJitter(step * 0.37, 1, 7)
			t.truthy(jitter.Position.Magnitude <= 0.08, "the hands stay on the jaws")
			local tilt = math.acos(math.clamp(-jitter.LookVector.Z, -1, 1))
			local roll = math.acos(math.clamp(jitter.UpVector.Y, -1, 1))
			t.truthy(math.max(tilt, roll) <= math.rad(8), "a tremor, not a flail")
		end
		t.truthy(
			cframeNear(BearTrapController.handJitter(1.5, 0.6, 3), BearTrapController.handJitter(1.5, 0.6, 3), 1e-12),
			"deterministic"
		)
		local leg = Vector3.new(3, -84, 7)
		local yaw = math.rad(120)
		local target = BearTrapController.pryTarget(leg, yaw)
		t.truthy(target.Position.Y > leg.Y, "hands above the caught ankle")
		t.near(MathUtil.horizontalDistance(target.Position, leg), 0, 1e-6, "right over it")
		t.truthy(near(target.LookVector, MathUtil.vectorFromYawPitch(yaw, 0), 1e-6), "-Z away from the player")

		local radius = BearTrapController.NearShakeRadius
		local impact = CameraConfig.Shake.ImpactAmplitude
		t.near(BearTrapController.nearbyShake(0), impact, 1e-9, "right beside it")
		t.near(BearTrapController.nearbyShake(radius / 2), impact / 4, 1e-9, "quadratic falloff")
		t.eq(BearTrapController.nearbyShake(radius), 0, "out of reach")
		t.eq(BearTrapController.nearbyShake(math.sqrt(-1)), 0)
		t.eq(BearTrapController.nearbyShake(-1), impact, "inside the trap is still beside it")

		t.truthy(BearTrapController.shouldPresent(true, false, false), "the trap names me")
		t.truthy(BearTrapController.shouldPresent(false, true, false), "my MoveState says so")
		t.truthy(BearTrapController.shouldPresent(false, false, true), "a fresh cue")
		t.falsy(BearTrapController.shouldPresent(false, false, false), "free")
	end,
}
