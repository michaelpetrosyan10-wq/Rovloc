--!strict
-- ParachuteService: the roof jump (spec, Level 5). The only writer of ParachutePack TakenByUserId and of every player's
-- parachute state (Player Parachute / ParachuteAt / ParachuteAuto). The rules it shares with the jumping client live in
-- Shared/Sequence/ParachuteMotion.
--
-- Packs. The crate's packs (ParachuteBuilder: ParachutePack models, each with a disabled ParachuteGrab prompt) are
-- served by an InteractionService "ParachuteGrab" handler while their TakenByUserId is unset: an Alive player on the
-- live roof who wears no pack takes one with the prompt's hold (grabCheck; one already worn is refused with
-- Hud.ParachuteHaveOne). The pack vanishes from the crate (its parts go transparent and its prompt closes),
-- TakenByUserId names the taker, the worn ParachuteBackpack rig is welded onto their UpperTorso, the buckles click
-- (PackBuckle) and they are told how to go (Hud.ParachuteTaken): state Packed. A pack goes back into the crate when its
-- wearer dies, leaves or loses their body before jumping, so the packs always cover the squad. While the roof
-- objective keeps the crate chained (SetCrateOpen(false)) no pack can be taken.
--
-- The jump, every Heartbeat while the roof is the live level, for each of the run's participants with a body (the
-- transition is advance, pure):
--   None / Packed  a root off the roof (ParachuteMotion.offRoof): with a pack, Freefall (the edge they left decides the
--                  drift); without one, Falling, executed ("Fall") past FatalDrop or on whatever it hits. Both fire Leapt.
--   Freefall       ParachutePull (Alive; a pull that reaches the server up to PullGrace before it sees the leap counts)
--                  opens the canopy. So does the ground coming up to AutoDeployClearance or FreefallMax in the air:
--                  the fair auto-deploy, a late canopy (HardDescentSpeed) and a hard landing. Down on something before
--                  any of that: landed hard.
--   Canopy         the canopy (ParachuteBuilder's ParachuteCanopy, welded over the harness), a LinearVelocity
--                  "ParachuteDescent" on the root at ParachuteMotion.canopyVelocity (the jumper's client simulates its
--                  own body; the server owns the constraint and judges the path with the "Parachute" MovementAuthority
--                  validator, ParachuteMotion.descentVerdict), the Parachuting MoveState override, CanopyDeploy for
--                  everyone but the jumper (whose client plays its own). Down over the ground under the root
--                  (ParachuteMotion.landed), or CanopyMax in the air (ForceLand): Landed.
--   Landed         the descent comes off, the canopy collapses onto the ground behind them, the override goes and
--                  the body is held for the finale camera (CharacterService.Lock "Parachute", Anchor). A Downed jumper
--                  is back on their feet: they made it out. ParachuteLanding (HardLanding after an auto-deploy) for
--                  everyone but the jumper. Landed fires.
-- ForceLand(player) is the scripted landing (the finale's fade to black): a jumper still in the air is put on the
-- ground under them and lands. ReleaseHold(player) ends a lander's hold once the finale is over for them (the Level 5
-- controller); every hold ends with the run.
--
-- Signals: Leapt(player, packed), Deployed(player, auto), Landed(player, hard).
-- Dev command: chute [give|pull|land] (the caller; no argument reports their jump).
--
-- Pure rules (tests/Specs/Parachute.spec.luau): grabCheck, advance. SetDependencies swaps every engine and
-- cross-service touch point (specs drive whole jumps on a fake clock with fake roots, ground, rigs and locks).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local ParachuteMotion = require(ReplicatedStorage.Shared.Sequence.ParachuteMotion)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local ParachuteBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.ParachuteBuilder)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local MovementAuthority = require(ServerScriptService.Services.Player.MovementAuthority)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)

local log = Log.new("Parachute")

local P = Attributes.Player
local W = Attributes.World

export type State = Enums.ParachuteState

export type Action = "None" | "Leap" | "Fall" | "Execute" | "Deploy" | "AutoDeploy" | "Land" | "LandHard" | "ForceLand"

export type AdvanceInput = {
	state: State,
	position: Vector3, -- the root now
	groundY: number?, -- the ground under it (nil: nothing within reach)
	rootHeight: number, -- its standing height over the floor
	now: number,
	since: number, -- when the state began
	pullAt: number?, -- the latest ParachutePull from this player
	alive: boolean, -- Alive (the cord needs hands)
}

-- A read-only view of one player's jump.
export type Jump = {
	state: State,
	since: number,
	leftFrom: Vector3?, -- where the root left the roof
	leftAt: number?,
	deployedAt: number?,
	deployFrom: Vector3?,
	velocity: Vector3?, -- the canopy's
	auto: boolean, -- the canopy opened by itself
	landedAt: number?,
	landedFrom: Vector3?,
	hard: boolean, -- a hard landing
}

export type Dependencies = {
	now: () -> number,
	live: () -> boolean, -- the roof is the live level of a run in progress
	players: () -> { Player }, -- the run's participants in the server
	rootOf: (player: Player) -> BasePart?, -- a living body's root in the Workspace
	rootHeight: (player: Player) -> number,
	lifeState: (player: Player) -> Enums.LifeState,
	groundBelow: (player: Player, position: Vector3) -> number?,
	execute: (player: Player, cause: string) -> (),
	revive: (player: Player, fraction: number) -> (),
	lock: (player: Player, reason: Enums.ControlLock, mode: Enums.LockMode) -> (),
	unlock: (player: Player, reason: Enums.ControlLock) -> (),
	pushOverride: (player: Player, token: string, state: Enums.MoveState) -> (),
	popOverride: (player: Player, token: string) -> (),
	teleport: (player: Player, cframe: CFrame) -> boolean,
	attachPack: (player: Player) -> Instance?, -- the worn backpack rig, welded on
	attachCanopy: (player: Player) -> Instance?, -- the canopy rig, welded over the harness
	attachDescent: (root: BasePart, velocity: Vector3) -> Instance?, -- the LinearVelocity (and its attachment)
	collapse: (canopy: Instance, at: Vector3, facing: Vector3) -> (), -- the canopy settles behind a lander
	showPack: (pack: Model, visible: boolean) -> (),
	refresh: (host: Instance) -> (),
	playAt: (preset: string, position: Vector3, except: Player?) -> (),
	notify: (player: Player, key: string) -> (),
}

type Record = {
	player: Player,
	character: Model?,
	state: State,
	since: number,
	pack: Model?, -- the crate pack they took (nil for a dev-given pack)
	backpack: Instance?,
	canopy: Instance?,
	descent: Instance?,
	leftFrom: Vector3?,
	leftAt: number?,
	direction: Vector3?,
	deployedAt: number?,
	deployFrom: Vector3?,
	velocity: Vector3?,
	auto: boolean,
	landedAt: number?,
	landedFrom: Vector3?,
	hard: boolean,
	pullAt: number?,
	overridden: boolean,
	locked: boolean,
}

local PROMPT_KIND: Enums.PromptKind = "ParachuteGrab"
local VALIDATOR_NAME = "Parachute"
local OVERRIDE_TOKEN = "Parachute"
local OVERRIDE_STATE: Enums.MoveState = "Parachuting"
local LOCK_REASON: Enums.ControlLock = "Parachute"
local LOCK_MODE: Enums.LockMode = "Anchor"
local FALL_CAUSE = "Fall"
local HAVE_ONE_KEY = "Hud.ParachuteHaveOne"
local TAKEN_KEY = "Hud.ParachuteTaken"
local BUCKLE_PRESET = "PackBuckle"
local DEPLOY_PRESET = "CanopyDeploy"
local LANDING_PRESET = "ParachuteLanding"
local HARD_PRESET = "HardLanding"
local LANDING_REVIVE = 0.35 -- a Downed jumper is back up at this share of MaxHealth on the ground
local GROUND_REACH = 400 -- studs the ground cast reaches under a root
local DESCENT_FORCE = 2e5
local DESCENT_NAME = "ParachuteDescent"
local COLLAPSE_SECONDS = 0.9
local COLLAPSE_TIP = math.rad(96) -- the canopy tips back over the lander's head onto the ground
local COLLAPSE_DROP = 2 -- studs under the lander's root its harness point comes to rest
local LIVE_PHASES: { [string]: boolean } = { InRun = true }
local AIRBORNE: { [string]: boolean } = { Freefall = true, Canopy = true, Falling = true }

local ParachuteService = {}

ParachuteService.Name = "ParachuteService"
ParachuteService.ValidatorName = VALIDATOR_NAME
ParachuteService.OverrideToken = OVERRIDE_TOKEN
ParachuteService.LandingRevive = LANDING_REVIVE
ParachuteService.FallCause = FALL_CAUSE

local leapt: Signal.Signal<Player, boolean> = Signal.new()
local deployed: Signal.Signal<Player, boolean> = Signal.new()
local landed: Signal.Signal<Player, boolean> = Signal.new()

-- (player, packed) when a root leaves the roof: with a pack (Freefall) or without (Falling).
ParachuteService.Leapt = leapt
-- (player, auto) when a canopy opens: pulled, or by itself.
ParachuteService.Deployed = deployed
-- (player, hard) when a jumper is down below.
ParachuteService.Landed = landed

local serviceTrove = Trove.new()
local records: { [Player]: Record } = {}
local initialized = false
local crateOpen = true -- the roof objective keeps the crate chained until its chain is cut

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

-- Whether `state` / `lifeState` may take a pack now (`onRoof`: the roof is the live level; `free`: the pack is in the
-- crate). A refusal may carry a Strings key for the player.
function ParachuteService.grabCheck(
	state: State,
	lifeState: Enums.LifeState,
	onRoof: boolean,
	free: boolean
): (boolean, string?)
	if lifeState ~= "Alive" or not onRoof or not free then
		return false, nil
	end
	if state ~= "None" then
		return false, HAVE_ONE_KEY
	end
	return true, nil
end

-- What one jump does this step (see the header).
function ParachuteService.advance(input: AdvanceInput): Action
	local state = input.state
	local position = input.position
	local groundY = input.groundY
	local down = groundY ~= nil and ParachuteMotion.landed(position.Y, groundY, input.rootHeight)
	if state == "None" then
		return if ParachuteMotion.offRoof(position) then "Fall" else "None"
	elseif state == "Packed" then
		return if ParachuteMotion.offRoof(position) then "Leap" else "None"
	elseif state == "Falling" then
		return if down or ParachuteMotion.fatal(position.Y) then "Execute" else "None"
	elseif state == "Freefall" then
		if down then
			return "LandHard"
		end
		local pullAt = input.pullAt
		if input.alive and pullAt ~= nil and pullAt >= input.since - ParachuteMotion.PullGrace then
			return "Deploy"
		end
		if groundY ~= nil and ParachuteMotion.autoDeployDue(position.Y, groundY) then
			return "AutoDeploy"
		end
		if input.now - input.since >= ParachuteMotion.FreefallMax then
			return "AutoDeploy"
		end
		return "None"
	elseif state == "Canopy" then
		if down then
			return "Land"
		end
		if input.now - input.since >= ParachuteMotion.CanopyMax then
			return "ForceLand"
		end
		return "None"
	end
	return "None"
end

--------------------------------------------------------------------------------
-- Real dependencies
--------------------------------------------------------------------------------

local function upperTorso(player: Player): BasePart?
	local character = player.Character
	local torso = if character then character:FindFirstChild("UpperTorso") else nil
	return if torso and torso:IsA("BasePart") then torso else nil
end

-- Welds every part of a freshly built (anchored) rig to its PrimaryPart, frees it and hangs it on `torso`.
local function wear(rig: Model, torso: BasePart, character: Model): Model?
	local primary = rig.PrimaryPart
	if not primary then
		rig:Destroy()
		return nil
	end
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("BasePart") then
			if descendant ~= primary then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = primary
				weld.Part1 = descendant
				weld.Parent = descendant
			end
			descendant.Massless = true
			descendant.Anchored = false
		end
	end
	rig.Parent = character
	local mount = Instance.new("WeldConstraint")
	mount.Name = "Mount"
	mount.Part0 = torso
	mount.Part1 = primary
	mount.Parent = primary
	return rig
end

local function realAttachPack(player: Player): Instance?
	local character = player.Character
	local torso = upperTorso(player)
	if not (character and torso) then
		return nil
	end
	local holder = Instance.new("Folder")
	local rig = ParachuteBuilder.buildBackpack(holder, torso.CFrame * CFrame.new(0, 0, torso.Size.Z / 2))
	local worn = wear(rig, torso, character)
	holder:Destroy()
	return worn
end

local function realAttachCanopy(player: Player): Instance?
	local character = player.Character
	local torso = upperTorso(player)
	if not (character and torso) then
		return nil
	end
	local holder = Instance.new("Folder")
	local rig = ParachuteBuilder.buildCanopy(holder, torso.CFrame * CFrame.new(0, torso.Size.Y / 2, 0))
	local worn = wear(rig, torso, character)
	holder:Destroy()
	return worn
end

local function realAttachDescent(root: BasePart, velocity: Vector3): Instance?
	local attachment = Instance.new("Attachment")
	attachment.Name = DESCENT_NAME
	local constraint = Instance.new("LinearVelocity")
	constraint.Name = DESCENT_NAME
	constraint.Attachment0 = attachment
	constraint.RelativeTo = Enum.ActuatorRelativeTo.World
	constraint.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	constraint.VectorVelocity = velocity
	constraint.ForceLimitsEnabled = true
	constraint.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	constraint.MaxForce = DESCENT_FORCE
	constraint.Parent = attachment
	attachment.Parent = root
	return attachment
end

-- Unhooks the canopy and lets it fall back over the lander's head onto the ground behind them, stepped on the
-- server for COLLAPSE_SECONDS (it is cosmetic; anchored parts replicate their poses).
local function realCollapse(canopy: Instance, at: Vector3, facing: Vector3)
	if not canopy:IsA("Model") then
		canopy:Destroy()
		return
	end
	local model = canopy :: Model
	local primary = model.PrimaryPart
	local harness = if primary then primary:FindFirstChild("Harness") else nil
	if not (primary and harness and harness:IsA("Attachment")) then
		model:Destroy()
		return
	end
	local mount = primary:FindFirstChild("Mount")
	if mount then
		mount:Destroy()
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
	model.Parent = Instances.runtimeLevel(ParachuteMotion.LevelId, true) or Workspace
	local flat = MathUtil.flat(facing)
	local forward = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local start = primary.CFrame * (harness :: Attachment).CFrame -- the harness point, world
	local rest = at - Vector3.new(0, COLLAPSE_DROP, 0) -- low enough that the tipped cells lie on the ground
	local base = CFrame.lookAt(rest, rest + forward)
	local offset = start:ToObjectSpace(primary.CFrame)
	task.spawn(function()
		local began = os.clock()
		while model.Parent ~= nil do
			local u = math.clamp((os.clock() - began) / COLLAPSE_SECONDS, 0, 1)
			local eased = 1 - (1 - u) ^ 3
			local harnessFrame = start:Lerp(base, eased) * CFrame.Angles(COLLAPSE_TIP * eased, 0, 0)
			model:PivotTo(harnessFrame * offset)
			if u >= 1 then
				return
			end
			RunService.Heartbeat:Wait()
		end
	end)
end

-- Each hidden crate pack part's own transparency, to put back when the pack returns (weak: packs go with the run).
local hiddenParts: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any

local function realShowPack(pack: Model, visible: boolean)
	for _, descendant in pack:GetDescendants() do
		if descendant:IsA("BasePart") then
			if visible then
				local original = hiddenParts[descendant]
				hiddenParts[descendant] = nil
				if original ~= nil then
					descendant.Transparency = original
				end
			else
				if hiddenParts[descendant] == nil then
					hiddenParts[descendant] = descendant.Transparency
				end
				descendant.Transparency = 1
			end
		end
	end
end

local function realGroundBelow(_player: Player, position: Vector3): number?
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
	local hit = Workspace:Raycast(position, Vector3.new(0, -GROUND_REACH, 0), SpatialQuery.worldParams(exclude))
	return if hit then hit.Position.Y else nil
end

local function realDependencies(): Dependencies
	return {
		now = function(): number
			return Workspace:GetServerTimeNow()
		end,
		live = function(): boolean
			return LIVE_PHASES[RunLifecycleService.GetPhase()] == true
				and LevelDirector.GetCurrentLevel() == ParachuteMotion.LevelId
				and LevelDirector.IsActive()
		end,
		players = function(): { Player }
			local run = RunLifecycleService.GetRun()
			local out: { Player } = {}
			if run then
				for _, player in run.participants do
					if player.Parent == Players then
						table.insert(out, player)
					end
				end
			end
			return out
		end,
		rootOf = function(player: Player): BasePart?
			local root = Instances.characterRoot(player)
			local humanoid = Instances.characterHumanoid(player)
			if not root or not humanoid or humanoid.Health <= 0 or not root:IsDescendantOf(Workspace) then
				return nil
			end
			return root
		end,
		rootHeight = function(player: Player): number
			local root = Instances.characterRoot(player)
			local humanoid = Instances.characterHumanoid(player)
			if root and humanoid then
				return humanoid.HipHeight + root.Size.Y / 2
			end
			return ParachuteMotion.RootHeight
		end,
		lifeState = LifeStateService.GetState,
		groundBelow = realGroundBelow,
		execute = LifeStateService.Execute,
		revive = LifeStateService.Revive,
		lock = CharacterService.Lock,
		unlock = CharacterService.Unlock,
		pushOverride = PlayerStateService.PushOverride,
		popOverride = PlayerStateService.PopOverride,
		teleport = CharacterService.Teleport,
		attachPack = realAttachPack,
		attachCanopy = realAttachCanopy,
		attachDescent = realAttachDescent,
		collapse = realCollapse,
		showPack = realShowPack,
		refresh = InteractionService.Refresh,
		playAt = function(preset: string, position: Vector3, except: Player?)
			AudioService.PlayAt(preset, position, { except = except })
		end,
		notify = function(player: Player, key: string)
			local payload: Types.NotifyPayload = { key = key, args = {} }
			Net.Server.fire("Notify", player, payload)
		end,
	}
end

local deps: Dependencies = realDependencies()

--------------------------------------------------------------------------------
-- Records
--------------------------------------------------------------------------------

local function recordOf(player: Player): Record
	local record = records[player]
	if record then
		return record
	end
	local fresh: Record = {
		player = player,
		character = player.Character,
		state = "None",
		since = deps.now(),
		pack = nil,
		backpack = nil,
		canopy = nil,
		descent = nil,
		leftFrom = nil,
		leftAt = nil,
		direction = nil,
		deployedAt = nil,
		deployFrom = nil,
		velocity = nil,
		auto = false,
		landedAt = nil,
		landedFrom = nil,
		hard = false,
		pullAt = nil,
		overridden = false,
		locked = false,
	}
	records[player] = fresh
	return fresh
end

local function setState(record: Record, state: State, now: number)
	record.state = state
	record.since = now
	local player = record.player
	if state == "None" then
		player:SetAttribute(P.Parachute, nil)
		player:SetAttribute(P.ParachuteAt, nil)
		player:SetAttribute(P.ParachuteAuto, nil)
		return
	end
	Attributes.set(player, P.Parachute, state)
	Attributes.set(player, P.ParachuteAt, now)
	player:SetAttribute(P.ParachuteAuto, if record.auto then true else nil)
end

local function destroy(instance: Instance?)
	if instance then
		instance:Destroy()
	end
end

-- Puts a taken crate pack back (its wearer will not jump with it).
local function returnPack(record: Record)
	local pack = record.pack
	record.pack = nil
	if not pack or pack.Parent == nil then
		return
	end
	pack:SetAttribute(W.TakenByUserId, nil)
	deps.showPack(pack, true)
	deps.refresh(pack)
end

-- Ends `record`'s jump: rigs, descent, override and lock go; a pack still on the roof goes back to the crate.
local function reset(record: Record)
	local player = record.player
	if record.state == "Packed" or record.state == "None" then
		returnPack(record)
	end
	record.pack = nil
	destroy(record.backpack)
	destroy(record.canopy)
	destroy(record.descent)
	record.backpack, record.canopy, record.descent = nil, nil, nil
	if record.overridden then
		record.overridden = false
		deps.popOverride(player, OVERRIDE_TOKEN)
	end
	if record.locked then
		record.locked = false
		deps.unlock(player, LOCK_REASON)
	end
	record.auto = false
	record.hard = false
	record.pullAt = nil
	setState(record, "None", deps.now())
	records[player] = nil
end

local function snapshot(record: Record): Jump
	return table.freeze({
		state = record.state,
		since = record.since,
		leftFrom = record.leftFrom,
		leftAt = record.leftAt,
		deployedAt = record.deployedAt,
		deployFrom = record.deployFrom,
		velocity = record.velocity,
		auto = record.auto,
		landedAt = record.landedAt,
		landedFrom = record.landedFrom,
		hard = record.hard,
	})
end

--------------------------------------------------------------------------------
-- The jump
--------------------------------------------------------------------------------

local function take(player: Player, pack: Model?): boolean
	local record = recordOf(player)
	if record.state ~= "None" then
		return false
	end
	local now = deps.now()
	if pack then
		pack:SetAttribute(W.TakenByUserId, player.UserId)
		deps.showPack(pack, false)
		deps.refresh(pack)
		local base = pack.PrimaryPart
		deps.playAt(BUCKLE_PRESET, if base then base.CFrame.Position else pack:GetPivot().Position, nil)
	end
	record.pack = pack
	record.character = player.Character
	destroy(record.backpack)
	record.backpack = deps.attachPack(player)
	setState(record, "Packed", now)
	deps.notify(player, TAKEN_KEY)
	log.info("%s put on a parachute", player.Name)
	return true
end

local function leave(record: Record, position: Vector3, packed: boolean, now: number)
	record.leftFrom = position
	record.leftAt = now
	record.direction = ParachuteMotion.outward(position)
	record.pack = nil -- jumped with it: it never goes back to the crate
	setState(record, if packed then "Freefall" else "Falling", now)
	leapt:Fire(record.player, packed)
end

local function deploy(record: Record, root: BasePart, auto: boolean, now: number)
	local player = record.player
	local position = root.CFrame.Position
	record.auto = auto
	record.deployedAt = now
	record.deployFrom = position
	local velocity = ParachuteMotion.canopyVelocity(record.direction or ParachuteMotion.outward(position), auto)
	record.velocity = velocity
	destroy(record.descent)
	record.descent = deps.attachDescent(root, velocity)
	destroy(record.canopy)
	record.canopy = deps.attachCanopy(player)
	if not record.overridden then
		record.overridden = true
		deps.pushOverride(player, OVERRIDE_TOKEN, OVERRIDE_STATE)
	end
	setState(record, "Canopy", now)
	deps.playAt(DEPLOY_PRESET, position, player)
	deployed:Fire(player, auto)
	log.info("%s's canopy opened%s", player.Name, if auto then " by itself" else "")
end

local function land(record: Record, position: Vector3, hard: boolean, now: number)
	local player = record.player
	record.hard = hard
	record.landedAt = now
	record.landedFrom = position
	destroy(record.descent)
	record.descent = nil
	local canopy = record.canopy
	record.canopy = nil
	if canopy then
		deps.collapse(canopy, position, MathUtil.flat(-(record.direction or Vector3.new(1, 0, 0))))
	end
	if record.overridden then
		record.overridden = false
		deps.popOverride(player, OVERRIDE_TOKEN)
	end
	if not record.locked then
		record.locked = true
		deps.lock(player, LOCK_REASON, LOCK_MODE)
	end
	if deps.lifeState(player) == "Downed" then
		deps.revive(player, LANDING_REVIVE)
	end
	setState(record, "Landed", now)
	deps.playAt(if hard then HARD_PRESET else LANDING_PRESET, position, player)
	landed:Fire(player, hard)
	log.info("%s landed%s", player.Name, if hard then " hard" else "")
end

-- Puts `record` on the ground under `root` (the scripted landing).
local function setDown(record: Record, root: BasePart, now: number)
	local position = root.CFrame.Position
	local groundY = deps.groundBelow(record.player, position) or ParachuteMotion.GroundY
	local standing = Vector3.new(position.X, groundY + deps.rootHeight(record.player), position.Z)
	local facing = MathUtil.flat(-(record.direction or Vector3.new(1, 0, 0)))
	local look = if facing.Magnitude > 1e-3 then facing.Unit else Vector3.new(0, 0, -1)
	destroy(record.descent)
	record.descent = nil
	deps.teleport(record.player, CFrame.lookAt(standing, standing + look))
	land(record, standing, record.auto, now)
end

local function stepRecord(record: Record, root: BasePart, now: number)
	local player = record.player
	local position = root.CFrame.Position
	local airborne = AIRBORNE[record.state] == true
	local groundY = if airborne then deps.groundBelow(player, position) else nil
	local action = ParachuteService.advance({
		state = record.state,
		position = position,
		groundY = groundY,
		rootHeight = deps.rootHeight(player),
		now = now,
		since = record.since,
		pullAt = record.pullAt,
		alive = deps.lifeState(player) == "Alive",
	})
	if action == "Leap" then
		leave(record, position, true, now)
	elseif action == "Fall" then
		leave(record, position, false, now)
	elseif action == "Execute" then
		deps.execute(player, FALL_CAUSE)
		log.info("%s jumped without a parachute", player.Name)
	elseif action == "Deploy" then
		deploy(record, root, false, now)
	elseif action == "AutoDeploy" then
		deploy(record, root, true, now)
	elseif action == "Land" then
		land(record, position, record.auto, now)
	elseif action == "LandHard" then
		record.auto = true
		land(record, position, true, now)
	elseif action == "ForceLand" then
		setDown(record, root, now)
	end
end

-- One step at `now` (every Heartbeat; specs pass a fake clock).
function ParachuteService.Step(now: number?)
	local t = now or deps.now()
	local live = deps.live()
	local present: { [Player]: boolean } = {}
	for _, player in deps.players() do
		present[player] = true
		local record: Record? = records[player]
		local playing = LifeStateService.isPlayingState(deps.lifeState(player))
		local existing = record
		if existing and (not playing or existing.character ~= player.Character) then
			reset(existing)
			record = nil
		end
		if not (live and playing) then
			continue
		end
		local root = deps.rootOf(player)
		if not root then
			continue
		end
		if record == nil and not ParachuteMotion.offRoof(root.CFrame.Position) then
			continue -- nothing to judge for a packless player still on the roof
		end
		stepRecord(record or recordOf(player), root, t)
	end
	for player, record in table.clone(records) do
		if not present[player] then
			reset(record)
		end
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

function ParachuteService.GetState(player: Player): State
	local record = records[player]
	return if record then record.state else "None"
end

function ParachuteService.GetJump(player: Player): Jump?
	local record = records[player]
	return if record then snapshot(record) else nil
end

-- Every player with a jump in progress or done (a pack on, in the air, or down below).
function ParachuteService.Jumpers(): { Player }
	local out: { Player } = {}
	for player in records do
		table.insert(out, player)
	end
	table.sort(out, function(a: Player, b: Player): boolean
		return a.UserId < b.UserId
	end)
	return out
end

-- Takes `pack` (a crate ParachutePack) for `player` (the prompt's completion). False when they cannot.
function ParachuteService.Take(player: Player, pack: Model): boolean
	local record = records[player]
	local state: State = if record then record.state else "None"
	local ok = ParachuteService.grabCheck(
		state,
		deps.lifeState(player),
		deps.live(),
		pack.Parent ~= nil and pack:GetAttribute(W.TakenByUserId) == nil
	)
	if not ok then
		return false
	end
	return take(player, pack)
end

-- ParachutePull from `player` (Alive): remembered; the next step opens the canopy if they are in the air.
function ParachuteService.Pull(player: Player): boolean
	local record = records[player]
	if not record or (record.state ~= "Packed" and record.state ~= "Freefall") then
		return false
	end
	if deps.lifeState(player) ~= "Alive" then
		return false
	end
	record.pullAt = deps.now()
	return true
end

-- The scripted landing: a jumper in the air (Freefall or Canopy) is put on the ground under them and lands. False
-- for anyone else.
function ParachuteService.ForceLand(player: Player): boolean
	local record = records[player]
	if not record or (record.state ~= "Freefall" and record.state ~= "Canopy") then
		return false
	end
	local root = deps.rootOf(player)
	if not root then
		return false
	end
	setDown(record, root, deps.now())
	return true
end

-- Ends a lander's hold (the finale's fade is done: the view is theirs again); they stay Landed. False when `player`
-- is not held.
function ParachuteService.ReleaseHold(player: Player): boolean
	local record = records[player]
	if not record or record.state ~= "Landed" or not record.locked then
		return false
	end
	record.locked = false
	deps.unlock(player, LOCK_REASON)
	return true
end

-- Whether `player` is down below and still held for the finale camera.
function ParachuteService.IsHeld(player: Player): boolean
	local record = records[player]
	return record ~= nil and record.locked
end

-- The "Parachute" MovementAuthority validator: a canopy follows its canonical path (ParachuteMotion.descentVerdict).
function ParachuteService.DescentValidator(
	player: Player,
	root: BasePart,
	_dt: number
): (Types.MovementVerdict, Vector3?)
	local record = records[player]
	if not record or record.state ~= "Canopy" or record.character ~= player.Character then
		return "Ok", nil
	end
	local from, velocity, deployedAt = record.deployFrom, record.velocity, record.deployedAt
	if not (from and velocity and deployedAt) then
		return "Ok", nil
	end
	local position = root.CFrame.Position
	local groundY = deps.groundBelow(player, position) or ParachuteMotion.GroundY
	return ParachuteMotion.descentVerdict({
		position = position,
		from = from,
		velocity = velocity,
		elapsed = deps.now() - deployedAt,
		floorY = groundY + deps.rootHeight(player),
	})
end

function ParachuteService.SetDependencies(fake: Dependencies?)
	deps = fake or realDependencies()
end

--------------------------------------------------------------------------------
-- Dev command
--------------------------------------------------------------------------------

local function freePack(): Model?
	for _, instance in CollectionService:GetTagged(Tags.ParachutePack) do
		if instance:IsA("Model") and instance.Parent ~= nil and instance:GetAttribute(W.TakenByUserId) == nil then
			return instance
		end
	end
	return nil
end

local function chuteCommand(player: Player, args: { string }): string?
	local action = string.lower(args[1] or "")
	if action == "give" then
		if not deps.live() then
			return "go to the roof first (level 5)"
		end
		if ParachuteService.GetState(player) ~= "None" then
			return "you already have one"
		end
		local pack = freePack()
		if pack then
			return if ParachuteService.Take(player, pack) then "pack on (from the crate)" else "you cannot take one now"
		end
		return if take(player, nil) then "pack on (none left in the crate)" else "you cannot take one now"
	elseif action == "pull" then
		return if ParachuteService.Pull(player) then "cord pulled" else "you are not falling with a pack"
	elseif action == "land" then
		return if ParachuteService.ForceLand(player) then "landed" else "you are not in the air"
	end
	local jump = ParachuteService.GetJump(player)
	return string.format(
		"parachute: %s%s. usage: chute give | pull | land",
		if jump then jump.state else "None",
		if jump and jump.auto then " (auto-deployed)" else ""
	)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- The roof objective's lock (ObjectiveService): while the crate is chained (false) no pack can be taken. Open by
-- default and again at every run end.
function ParachuteService.SetCrateOpen(open: boolean)
	if crateOpen == open then
		return
	end
	crateOpen = open
	for _, pack in CollectionService:GetTagged(Tags.ParachutePack) do
		xpcall(InteractionService.Refresh, function(err: any)
			log.warnThrottled("refresh", 10, "pack prompt refresh failed: %s", tostring(err))
		end, pack)
	end
end

function ParachuteService.IsCrateOpen(): boolean
	return crateOpen
end

function ParachuteService.Init()
	if initialized then
		return
	end
	initialized = true
	serviceTrove:Add(InteractionService.Register({
		kind = PROMPT_KIND,
		filter = function(host: Instance, _prompt: ProximityPrompt): boolean
			return crateOpen and host:HasTag(Tags.ParachutePack) and host:GetAttribute(W.TakenByUserId) == nil
		end,
		canUse = function(player: Player, _prompt: ProximityPrompt, host: Instance): (boolean, string?)
			return ParachuteService.grabCheck(
				ParachuteService.GetState(player),
				deps.lifeState(player),
				deps.live(),
				host:GetAttribute(W.TakenByUserId) == nil
			)
		end,
		onComplete = function(player: Player, _prompt: ProximityPrompt, host: Instance)
			if host:IsA("Model") then
				ParachuteService.Take(player, host)
			end
		end,
	}))
	MovementAuthority.RegisterValidator(VALIDATOR_NAME, ParachuteService.DescentValidator)
	Net.Server.on("ParachutePull", function(player: Player, _payload: any)
		ParachuteService.Pull(player)
	end)
	DevToolsService.Register("chute", "chute [give|pull|land]: your parachute on the roof", chuteCommand)
end

function ParachuteService.Start()
	serviceTrove:Connect(RunService.Heartbeat, function()
		xpcall(ParachuteService.Step, function(err: any)
			log.warnThrottled("step", 10, "parachute step failed: %s\n%s", tostring(err), debug.traceback())
		end, nil)
	end)
end

function ParachuteService.BeginRun(_ctx: Types.RunContext)
	for _, record in table.clone(records) do
		reset(record)
	end
end

function ParachuteService.EndRun()
	for _, record in table.clone(records) do
		reset(record)
	end
	crateOpen = true
end

function ParachuteService.OnPlayerRemoving(player: Player)
	local record = records[player]
	if record then
		reset(record)
	end
end

return ParachuteService
