--!strict
-- CharacterService: builds, spawns and removes every player character, and owns control locks.
--
-- Build (docs/ARCHITECTURE.md §3a), in this order:
--   1. HumanoidDescription from GetHumanoidDescriptionFromUserIdAsync (pcall; cached per player after the first
--      success). Studio test players (UserId <= 0) and failed fetches use a blank description.
--   2. Normalize per WorldConfig.Avatar: scales 1, body type / proportion 0, no layered clothing, no head
--      accessories (hat, hair, face, neck, eyebrow, eyelash), no animation packs.
--   3. Players:CreateHumanoidModelFromDescriptionAsync(desc, R15) (pcall; a failed avatar build retries once with
--      the blank description).
--   4. Strip Animate / Health and every other script. Humanoid: BreakJointsOnDeath=false, RequiresNeck=false, no
--      name/health display, WalkSpeed=GameConfig.WalkSpeed, JumpHeight 2.5 (UseJumpPower=false), MaxHealth=Health=
--      GameConfig.MaxHealth, AutomaticScalingEnabled=false.
--   5. A `VentCollider` ball (WorldConfig.VentColliderDiameter, massless, invisible, frictionless, CanCollide off)
--      welded to the root with a WeldConstraint. CollisionService only switches it on in Vent mode.
--   6. PivotTo(cframe), CollisionService.TrackCharacter, player.Character = model, parent to Workspace, network
--      ownership, then the previous character is removed (CharacterRemoving) and destroyed.
-- Every yield is followed by a check that the player is still here and that no newer Spawn / Despawn superseded
-- this one, so a player who leaves mid-build never gets an orphaned rig.
--
-- Locks. Lock(player, reason, mode) / Unlock(player, reason) are ref-counted per reason (a stack of modes, LIFO).
-- Locks belong to the player and follow them onto a new character. While any lock is held: collision mode Locked
-- (CollisionService), and either the root is anchored (some held lock is Anchor) or the server owns it
-- (ServerOwned). The last Unlock unanchors first, then hands ownership back with SetNetworkOwner(player). Network
-- ownership is only ever set on unanchored roots that are in Workspace. The Player attribute ControlLock is the
-- highest-priority held reason (LockPriority). EndRun and leaving release every lock.
--
-- Joining. Each player (including players already present when Start runs) gets the DevTools attribute (Studio,
-- GameConfig.DevAllowlistUserIds, or the experience owner when GameConfig.DevToolsForCreator is on), then, once
-- WorldService is ready and the client acknowledged the world (or GameConfig.ClientAckTimeout passed), a character at
-- a Lobby PlayerSpawn anchor. A character spawned before its client's ack stays anchored until the ack (at most
-- GameConfig.WorldReadyTimeout), so a slow phone never simulates its body over floors it has not received. When a run
-- ends every player is returned to the lobby. For a group-owned experience the group's owner is looked up once per
-- server (Start, in the background, retried after 1, 3 and 9 s) and cached; it gets DevTools the moment it resolves.
--
-- Server moves. Spawn and Teleport announce every move to NoiseAndDirectorService.ExpectTeleport before the rig
-- jumps (the locomotion sampler never hears it, nor reports it as suspicious) and fire Moved(player, model, cframe)
-- for later consumers (P3 MovementAuthority). Code that moves a character must go through these two.
--
-- Recovery. Twice a second every joined player who is not waiting for a first spawn, not being spawned and not
-- Despawned on purpose is checked: a character that lost its HumanoidRootPart (the engine's fall cleanup, anything
-- that destroyed it), a root below WorldConfig.GroundY - FallMargin, or no character at all is replaced. A dead
-- Humanoid fires Died and is replaced DeathRespawnDelay (3) seconds later. Replacements land on the current level's
-- entry spawn slots for run participants during a run, else in the Lobby, and a failing replacement is retried every
-- RecoveryRetrySeconds. This is Phase 1's whole death policy: CharacterService never writes LifeState.
-- P3 LifeStateService takes over with SetRecoveryHandler(handler): the handler sees every recovery first
-- (reason "Died", "OutOfBounds" or "Lost") and returns true when it handled it (Downed, Execute, elimination,
-- spectating, ...), so CharacterService neither respawns nor schedules anything; false keeps the built-in respawn.
--
-- Deploying a run is the match policy's call (DevToolsService in P1, MatchAndDataService in P8): it spawns the
-- participants at Level0 PlayerSpawn anchors through Spawn / SpawnCFrame once the run exists, so this service has no
-- BeginRun hook.
--
-- Died fires once per character when its Humanoid dies, before any recovery decision.

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local CollisionService = require(ServerScriptService.Services.Core.CollisionService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local WorldService = require(ServerScriptService.Services.Core.WorldService)

local log = Log.new("Characters")

local P = Attributes.Player

local LOCK_COLLISION_TOKEN = "ControlLock"
local JUMP_HEIGHT = 2.5
local SPAWN_HEIGHT = 3.5 -- root height above the floor used by every PlayerSpawn anchor (root + clearance)
local READY_RECHECK_SECONDS = 30
local LOBBY: Enums.LayoutId = "Lobby"
local DEATH_RESPAWN_DELAY = 3
local FALL_MARGIN = 60 -- studs below WorldConfig.GroundY that count as out of bounds
local RECOVERY_CHECK_SECONDS = 0.5
local RECOVERY_RETRY_SECONDS = 5
local GROUP_RETRY_DELAYS: { number } = { 1, 3, 9 }

-- Accessory types removed by StripHeadAccessories (anything worn on or around the head, which the first-person
-- camera sits inside).
local HEAD_ACCESSORY_TYPES: { [Enum.AccessoryType]: boolean } = {
	[Enum.AccessoryType.Hat] = true,
	[Enum.AccessoryType.Hair] = true,
	[Enum.AccessoryType.Face] = true,
	[Enum.AccessoryType.Neck] = true,
	[Enum.AccessoryType.Eyebrow] = true,
	[Enum.AccessoryType.Eyelash] = true,
}

-- Higher wins for the ControlLock attribute.
local LOCK_PRIORITY: { [string]: number } = {
	None = 0,
	Airlock = 1,
	Parachute = 2,
	Locker = 3,
	Trap = 4,
	Drag = 5,
	Jumpscare = 6,
	Cutscene = 7,
}

export type AccessoryEntry = {
	AssetId: number,
	AccessoryType: Enum.AccessoryType,
	IsLayered: boolean,
	Order: number?,
	Puffiness: number?,
}

-- Held locks: reason -> stack of modes (one entry per Lock call not yet matched by an Unlock).
export type LockTable = { [string]: { Enums.LockMode } }

export type LockSummary = {
	reason: Enums.ControlLock, -- highest-priority held reason, "None" when free
	locked: boolean, -- any lock held
	anchored: boolean, -- some held lock is Anchor
}

-- Why a joined player's character is being replaced.
export type RecoveryReason = "Died" | "OutOfBounds" | "Lost"

-- P3 LifeStateService's hook: return true when it handled the recovery itself (no built-in respawn follows). It runs
-- on the thread that noticed the problem and must not yield. `model` is nil for "Lost" with no character left.
export type RecoveryHandler = (player: Player, model: Model?, reason: RecoveryReason) -> boolean

local CharacterService = {}

CharacterService.Name = "CharacterService"
CharacterService.LockPriority = table.freeze(table.clone(LOCK_PRIORITY))
CharacterService.SpawnHeight = SPAWN_HEIGHT
CharacterService.DeathRespawnDelay = DEATH_RESPAWN_DELAY
CharacterService.FallMargin = FALL_MARGIN
CharacterService.RecoveryRetrySeconds = RECOVERY_RETRY_SECONDS
CharacterService.GroupOwnerRetryDelays = table.freeze(table.clone(GROUP_RETRY_DELAYS))

local characterSpawned: Signal.Signal<Player, Model> = Signal.new()
local characterRemoving: Signal.Signal<Player, Model> = Signal.new()
local died: Signal.Signal<Player, Model> = Signal.new()
local moved: Signal.Signal<Player, Model, CFrame> = Signal.new()

CharacterService.CharacterSpawned = characterSpawned
CharacterService.CharacterRemoving = characterRemoving
CharacterService.Died = died
-- The server placed `player`'s character at `cframe` (a Spawn or a Teleport).
CharacterService.Moved = moved

local serviceTrove = Trove.new()

local characters: { [Player]: Model } = {}
local generations: { [Player]: number } = {}
local spawning: { [Player]: number } = {} -- generation of the Spawn in flight
local descriptions: { [Player]: HumanoidDescription } = {}
local locks: { [Player]: LockTable } = {}
local joined: { [Player]: boolean } = {}
local loadingHolds: { [Player]: boolean } = {} -- spawned before their client acknowledged the world
local awaitingFirstSpawn: { [Player]: boolean } = {} -- joined, still waiting for the world / their ack
local despawned: { [Player]: boolean } = {} -- Despawn()ed on purpose: recovery leaves them alone until a Spawn
local pendingDeaths: { [Player]: number } = {} -- died; the generation a delayed respawn is waiting on
local recovering: { [Player]: boolean } = {} -- a recovery respawn is in flight
local lastRecoveryAt: { [Player]: number } = {} -- os.clock() of the last recovery attempt
local recoveryHandler: RecoveryHandler? = nil
local groupOwnerId: number? = nil -- the creator group's owner, once resolved

--------------------------------------------------------------------------------
-- Pure helpers (specs: tests/Specs/CoreServices.spec.luau)
--------------------------------------------------------------------------------

-- The accessories that survive normalization.
function CharacterService.filterAccessories(
	accessories: { AccessoryEntry },
	stripLayered: boolean,
	stripHead: boolean
): { AccessoryEntry }
	local kept: { AccessoryEntry } = {}
	for _, accessory in accessories do
		if stripLayered and accessory.IsLayered then
			continue
		end
		if stripHead and HEAD_ACCESSORY_TYPES[accessory.AccessoryType] then
			continue
		end
		table.insert(kept, accessory)
	end
	return kept
end

-- What a lock table means: the reason to show, whether the player is locked at all, and whether to anchor.
function CharacterService.summarizeLocks(held: LockTable): LockSummary
	local summary: LockSummary = { reason = "None", locked = false, anchored = false }
	for reason, modes in held do
		if #modes == 0 or not Enums.has(Enums.ControlLock, reason) then
			continue
		end
		local controlLock: Enums.ControlLock = (reason :: any) :: Enums.ControlLock
		summary.locked = true
		if LOCK_PRIORITY[controlLock] > LOCK_PRIORITY[summary.reason] then
			summary.reason = controlLock
		end
		if table.find(modes, "Anchor") then
			summary.anchored = true
		end
	end
	return summary
end

-- World CFrame of spawn slot `index` (1-based) in `layoutId`: the PlayerSpawn anchors in its entry room (on a floor
-- reached by stairs the run's entry vestibule, LevelDirector.entryFor; else the layout's entry; any PlayerSpawn
-- anchors when that room has none) in layout order, wrapping and stepping sideways by WorldConfig.SpawnSpacing per
-- wrap; else the entry room's centre; else the layout origin.
function CharacterService.SpawnCFrame(layoutId: Enums.LayoutId, index: number): CFrame
	local slot = math.max(1, math.floor(index))
	local layout = Builder.getLayout(layoutId)
	local origin = WorldConfig.levelOrigin(layoutId)
	if not layout then
		return CFrame.new(origin + Vector3.new(0, SPAWN_HEIGHT, 0))
	end
	local stair = LevelDirector.entryFor(layoutId)
	local entryRoom = if stair and stair.to == layoutId then stair.toRoom else layout.entry
	local spawns: { LayoutSchema.Anchor } = {}
	local anywhere: { LayoutSchema.Anchor } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == "PlayerSpawn" then
			table.insert(anywhere, anchor)
			if anchor.room == entryRoom then
				table.insert(spawns, anchor)
			end
		end
	end
	if #spawns == 0 then
		spawns = anywhere
	end
	if #spawns > 0 then
		local anchor = spawns[(slot - 1) % #spawns + 1]
		local wrap = (slot - 1) // #spawns
		return Builder.anchorCFrame(layoutId, anchor) * CFrame.new(wrap * WorldConfig.SpawnSpacing, 0, 0)
	end
	local rooms = LayoutSchema.indexRooms(layout)
	local entry = rooms[entryRoom]
	if entry then
		local center = LayoutSchema.rectCenter(entry.rect)
		local offset = (slot - 1) * WorldConfig.SpawnSpacing
		return CFrame.new(origin + Vector3.new(center.X + offset, SPAWN_HEIGHT, center.Y))
	end
	return CFrame.new(origin + Vector3.new(0, SPAWN_HEIGHT, 0))
end

-- Why a character with its root at `rootPosition` must be replaced: "Lost" without a character or root,
-- "OutOfBounds" below WorldConfig.GroundY - FallMargin (or at a non-finite position); nil when it is fine.
function CharacterService.recoveryReason(hasCharacter: boolean, rootPosition: Vector3?): RecoveryReason?
	if not hasCharacter or rootPosition == nil then
		return "Lost"
	end
	if not MathUtil.isFiniteVector(rootPosition) or rootPosition.Y < WorldConfig.GroundY - FALL_MARGIN then
		return "OutOfBounds"
	end
	return nil
end

-- Where a recovered player respawns: the current level for a run participant while a run is live (Deploying /
-- InRun), the Lobby otherwise (no run, a non-participant, or no valid current level).
function CharacterService.recoveryLayout(phase: string?, participant: boolean, currentLevel: string?): Enums.LayoutId
	if participant and (phase == "InRun" or phase == "Deploying") and type(currentLevel) == "string" then
		if Enums.has(Enums.LevelId, currentLevel) then
			return (currentLevel :: any) :: Enums.LayoutId
		end
	end
	return LOBBY
end

-- Calls `attempt` until it returns true: once, then once more after each of `delays` (seconds, slept with
-- `sleep`). Returns whether an attempt succeeded.
function CharacterService.withRetries(
	attempt: () -> boolean,
	delays: { number },
	sleep: (seconds: number) -> ()
): boolean
	if attempt() then
		return true
	end
	for _, seconds in delays do
		sleep(seconds)
		if attempt() then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Description
--------------------------------------------------------------------------------

local function normalizeDescription(description: HumanoidDescription)
	local avatar = WorldConfig.Avatar
	description.HeightScale = avatar.HeightScale
	description.WidthScale = avatar.WidthScale
	description.DepthScale = avatar.DepthScale
	description.HeadScale = avatar.HeadScale
	description.BodyTypeScale = avatar.BodyTypeScale
	description.ProportionScale = avatar.ProportionScale
	-- No animation packs: nothing plays engine animations (the procedural animator drives every rig).
	description.ClimbAnimation = 0
	description.FallAnimation = 0
	description.IdleAnimation = 0
	description.JumpAnimation = 0
	description.MoodAnimation = 0
	description.RunAnimation = 0
	description.SwimAnimation = 0
	description.WalkAnimation = 0

	local stripLayered = avatar.StripLayeredClothing
	local stripHead = avatar.StripHeadAccessories
	if not (stripLayered or stripHead) then
		return
	end
	local ok, err = pcall(function()
		local current = description:GetAccessories(true) :: { AccessoryEntry }
		local kept = CharacterService.filterAccessories(current, stripLayered, stripHead)
		if #kept ~= #current then
			description:SetAccessories(kept :: any, true)
		end
	end)
	if not ok then
		log.warn("accessory normalization failed (%s); stripping accessory lists", tostring(err))
	end
	if stripHead then
		description.HatAccessory = ""
		description.HairAccessory = ""
		description.FaceAccessory = ""
		description.NeckAccessory = ""
	end
	for _, child in description:GetChildren() do
		if not child:IsA("AccessoryDescription") then
			continue
		end
		if (stripLayered and child.IsLayered) or (stripHead and HEAD_ACCESSORY_TYPES[child.AccessoryType]) then
			child:Destroy()
		end
	end
end

local function blankDescription(): HumanoidDescription
	local description = Instance.new("HumanoidDescription")
	normalizeDescription(description)
	return description
end

-- A fresh, normalized description for `player` (yields on the first fetch). The caller owns (and destroys) it.
local function fetchDescription(player: Player): HumanoidDescription
	local cached = descriptions[player]
	if cached then
		return cached:Clone()
	end
	if player.UserId <= 0 then
		return blankDescription()
	end
	local ok, result = pcall(function(): HumanoidDescription
		return Players:GetHumanoidDescriptionFromUserIdAsync(player.UserId)
	end)
	if not ok or typeof(result) ~= "Instance" then
		log.warn("avatar fetch for %s failed (%s); using a blank avatar", player.Name, tostring(result))
		return blankDescription()
	end
	normalizeDescription(result)
	if player.Parent == Players then
		local previous = descriptions[player]
		if previous then
			previous:Destroy()
		end
		descriptions[player] = result:Clone()
	end
	return result
end

local function buildRig(description: HumanoidDescription, who: string): Model?
	local ok, result = pcall(function(): Model
		return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R15)
	end)
	if ok and typeof(result) == "Instance" and result:IsA("Model") then
		return result
	end
	log.warn("character build for %s failed: %s", who, tostring(result))
	return nil
end

--------------------------------------------------------------------------------
-- Rig preparation
--------------------------------------------------------------------------------

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function addVentCollider(model: Model, root: BasePart)
	local existing = model:FindFirstChild(CollisionService.VentColliderName)
	if existing then
		existing:Destroy()
	end
	local collider = Instance.new("Part")
	collider.Name = CollisionService.VentColliderName
	collider.Shape = Enum.PartType.Ball
	collider.Size = Vector3.one * WorldConfig.VentColliderDiameter
	collider.Massless = true
	collider.CanCollide = false
	collider.CanQuery = false
	collider.CanTouch = false
	collider.CastShadow = false
	collider.Transparency = 1
	collider.Material = Enum.Material.SmoothPlastic
	-- Frictionless and dead (no bounce): the ball slides along the duct instead of snagging on seams.
	collider.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0, 0, 100, 100)
	collider.CFrame = root.CFrame
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = collider
	weld.Parent = collider
	collider.Parent = model
end

-- Turns a freshly built R15 model into a game character. Returns false when the rig is unusable.
local function prepareRig(player: Player, model: Model): boolean
	model.Name = player.Name
	-- Animate (engine animation packs) and Health (passive regen) plus anything else scripted: rigs carry no code.
	for _, descendant in model:GetDescendants() do
		if descendant.Parent ~= nil and descendant:IsA("LuaSourceContainer") then
			descendant:Destroy()
		end
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = rootOf(model)
	if not humanoid or not root then
		log.error("built rig for %s has no Humanoid or HumanoidRootPart", player.Name)
		return false
	end
	if model.PrimaryPart ~= root then
		model.PrimaryPart = root
	end
	humanoid.AutomaticScalingEnabled = false
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.WalkSpeed = GameConfig.WalkSpeed
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = JUMP_HEIGHT
	humanoid.MaxHealth = GameConfig.MaxHealth
	humanoid.Health = GameConfig.MaxHealth
	addVentCollider(model, root)
	return true
end

--------------------------------------------------------------------------------
-- Ownership + locks
--------------------------------------------------------------------------------

local function setOwner(root: BasePart, owner: Player?)
	if root.Anchored or not root:IsDescendantOf(Workspace) then
		return
	end
	local allowed, reason = root:CanSetNetworkOwnership()
	if not allowed then
		log.debug("cannot set network owner of %s: %s", root:GetFullName(), tostring(reason))
		return
	end
	local ok, err = pcall(function()
		root:SetNetworkOwner(owner)
	end)
	if not ok then
		log.warn("SetNetworkOwner on %s failed: %s", root:GetFullName(), tostring(err))
	end
end

local function applyLockPhysics(player: Player, model: Model, summary: LockSummary)
	local root = rootOf(model)
	if root then
		if summary.anchored or loadingHolds[player] then
			if not root.Anchored then
				root.Anchored = true
			end
		else
			if root.Anchored then
				root.Anchored = false
			end
			setOwner(root, if summary.locked then nil else player)
		end
	end
	if summary.locked then
		CollisionService.PushMode(model, LOCK_COLLISION_TOKEN, "Locked")
	else
		CollisionService.PopMode(model, LOCK_COLLISION_TOKEN)
	end
end

local function refreshLocks(player: Player)
	local summary = CharacterService.summarizeLocks(locks[player] or {})
	if player.Parent == Players then
		Attributes.set(player, P.ControlLock, summary.reason)
	end
	local model = characters[player]
	if model then
		applyLockPhysics(player, model, summary)
	end
end

-- A character spawned before its client acknowledged the world (the ack timed out) is held anchored until the ack
-- arrives, or GameConfig.WorldReadyTimeout passes: the client simulates its own character and would otherwise drop
-- it through floors it has not received yet. The hold is not a control lock (ControlLock is unaffected).
local function holdUntilAcked(player: Player)
	if loadingHolds[player] or WorldService.HasAcked(player) then
		return
	end
	loadingHolds[player] = true
	task.delay(GameConfig.WorldReadyTimeout, function()
		if loadingHolds[player] then
			loadingHolds[player] = nil
			log.warn("%s never acknowledged the world; releasing their character", player.Name)
			refreshLocks(player)
		end
	end)
end

local function onWorldAcked(player: Player)
	if loadingHolds[player] then
		loadingHolds[player] = nil
		refreshLocks(player)
	end
end

-- Takes one `reason` lock on `player` in `mode` (Anchor: root anchored; ServerOwned: server network owner).
function CharacterService.Lock(player: Player, reason: Enums.ControlLock, mode: Enums.LockMode)
	if reason == "None" or not Enums.has(Enums.ControlLock, reason) then
		log.warn("Lock(%s): invalid reason %s", player.Name, tostring(reason))
		return
	end
	if not Enums.has(Enums.LockMode, mode) then
		log.warn("Lock(%s, %s): invalid mode %s", player.Name, reason, tostring(mode))
		return
	end
	if player.Parent ~= Players then
		return
	end
	local held = locks[player]
	if not held then
		held = {}
		locks[player] = held
	end
	local stack = held[reason]
	if not stack then
		stack = {}
		held[reason] = stack
	end
	table.insert(stack, mode)
	refreshLocks(player)
end

-- Releases the most recent `reason` lock on `player` (no-op when none is held).
function CharacterService.Unlock(player: Player, reason: Enums.ControlLock)
	local held = locks[player]
	local stack = held and held[reason]
	if not held or not stack or #stack == 0 then
		return
	end
	table.remove(stack)
	if #stack == 0 then
		held[reason] = nil
	end
	if next(held) == nil then
		locks[player] = nil
	end
	refreshLocks(player)
end

-- Releases every lock on `player`.
function CharacterService.ReleaseLocks(player: Player)
	if locks[player] == nil then
		return
	end
	locks[player] = nil
	refreshLocks(player)
end

-- The highest-priority lock reason held on `player` ("None" when free).
function CharacterService.GetLock(player: Player): Enums.ControlLock
	return CharacterService.summarizeLocks(locks[player] or {}).reason
end

-- How many `reason` locks are held on `player` (or how many locks in total when `reason` is nil).
function CharacterService.LockCount(player: Player, reason: Enums.ControlLock?): number
	local held = locks[player]
	if not held then
		return 0
	end
	if reason then
		local stack = held[reason]
		return if stack then #stack else 0
	end
	local total = 0
	for _, stack in held do
		total += #stack
	end
	return total
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

local function bump(player: Player): number
	local generation = (generations[player] or 0) + 1
	generations[player] = generation
	return generation
end

local function removeCharacter(player: Player, model: Model)
	characterRemoving:Fire(player, model)
	CollisionService.UntrackCharacter(model)
	if player.Character == model then
		player.Character = nil
	end
	model:Destroy()
end

local function watchCharacter(player: Player, model: Model, humanoid: Humanoid)
	-- Deferred signals: both handlers run after the fact and re-check which character is current.
	humanoid.Died:Once(function()
		died:Fire(player, model)
	end)
	model.Destroying:Once(function()
		if characters[player] == model then
			characters[player] = nil
			characterRemoving:Fire(player, model)
			CollisionService.UntrackCharacter(model)
		end
	end)
end

-- The body of Spawn: build, prepare and swap in, giving up as soon as `generation` is superseded.
local function buildAndSwap(player: Player, cframe: CFrame, generation: number): Model?
	local function superseded(): boolean
		return player.Parent ~= Players or generations[player] ~= generation
	end

	local description = fetchDescription(player)
	if superseded() then
		description:Destroy()
		return nil
	end
	local model = buildRig(description, player.Name)
	description:Destroy()
	if not model and not superseded() then
		local blank = blankDescription()
		model = buildRig(blank, player.Name .. " (blank avatar)")
		blank:Destroy()
	end
	if superseded() then
		if model then
			model:Destroy()
		end
		return nil
	end
	if not model then
		log.error("could not build a character for %s", player.Name)
		return nil
	end
	if not prepareRig(player, model) then
		model:Destroy()
		return nil
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	assert(humanoid, "prepareRig guarantees a Humanoid")

	NoiseAndDirectorService.ExpectTeleport(player)
	model:PivotTo(cframe)
	CollisionService.TrackCharacter(model)
	local previous = characters[player]
	characters[player] = model
	watchCharacter(player, model, humanoid)
	holdUntilAcked(player)
	-- Held locks follow the player: anchor + Locked collision before the model replicates, ownership once it is
	-- in Workspace (SetNetworkOwner needs that).
	local summary = CharacterService.summarizeLocks(locks[player] or {})
	applyLockPhysics(player, model, summary)

	player.Character = model
	model.Parent = Workspace
	applyLockPhysics(player, model, summary)

	if previous and previous ~= model then
		removeCharacter(player, previous)
	end
	moved:Fire(player, model, cframe)
	characterSpawned:Fire(player, model)
	return model
end

-- Builds a new character for `player` at `cframe` (the root lands there) and swaps it in. Yields. Returns the
-- model, or nil when the player left, a newer Spawn / Despawn superseded this one, or the build failed.
function CharacterService.Spawn(player: Player, cframe: CFrame): Model?
	if player.Parent ~= Players then
		return nil
	end
	local generation = bump(player)
	spawning[player] = generation
	despawned[player] = nil
	pendingDeaths[player] = nil
	local model = buildAndSwap(player, cframe, generation)
	if spawning[player] == generation then
		spawning[player] = nil
	end
	return model
end

-- Whether a Spawn for `player` is still building their rig.
function CharacterService.IsSpawning(player: Player): boolean
	return spawning[player] ~= nil
end

-- Spawns `player` at a Lobby PlayerSpawn anchor. Yields.
function CharacterService.SpawnInLobby(player: Player): Model?
	local slot = table.find(Players:GetPlayers(), player) or 1
	return CharacterService.Spawn(player, CharacterService.SpawnCFrame(LOBBY, slot))
end

-- Removes `player`'s character (and cancels any Spawn still in flight).
function CharacterService.Despawn(player: Player)
	bump(player)
	despawned[player] = true
	pendingDeaths[player] = nil
	local model = characters[player]
	characters[player] = nil
	if model then
		removeCharacter(player, model)
	end
end

-- Moves `player`'s current character so its root lands at `cframe`. Returns false (and moves nothing) when there
-- is no living character with a root to move; callers spawn a fresh one instead.
function CharacterService.Teleport(player: Player, cframe: CFrame): boolean
	local model = characters[player]
	if not model or not model:IsDescendantOf(Workspace) then
		return false
	end
	local root = rootOf(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return false
	end
	NoiseAndDirectorService.ExpectTeleport(player)
	model:PivotTo(cframe)
	if not root.Anchored then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	moved:Fire(player, model, cframe)
	return true
end

function CharacterService.GetCharacter(player: Player): Model?
	local model = characters[player]
	if model and model.Parent then
		return model
	end
	return nil
end

--------------------------------------------------------------------------------
-- Recovery (Phase 1 death / out-of-bounds policy; P3 LifeStateService hooks in)
--------------------------------------------------------------------------------

-- Hands every recovery decision to `handler` first (nil restores the built-in respawns). P3 LifeStateService calls
-- this in its Init.
function CharacterService.SetRecoveryHandler(handler: RecoveryHandler?)
	recoveryHandler = handler
end

-- True when the registered handler took over this recovery.
local function handledElsewhere(player: Player, model: Model?, reason: RecoveryReason): boolean
	local handler = recoveryHandler
	if not handler then
		return false
	end
	local ok, handled = xpcall(handler, function(err: any)
		log.error("recovery handler failed for %s (%s): %s", player.Name, reason, tostring(err))
	end, player, model, reason)
	return ok and handled == true
end

-- The layout and spawn slot a recovered `player` respawns at.
local function recoverySpot(player: Player): (Enums.LayoutId, number)
	local run = RunLifecycleService.GetRun()
	local slot: number? = if run then table.find(run.participants, player) else nil
	if slot == nil then
		return LOBBY, table.find(Players:GetPlayers(), player) or 1
	end
	local current = ReplicatedStorage:GetAttribute(Attributes.Match.CurrentLevel)
	local layoutId: Enums.LayoutId = CharacterService.recoveryLayout(
		RunLifecycleService.GetPhase(),
		true,
		if type(current) == "string" then current else nil
	)
	return layoutId, slot
end

local function respawn(player: Player, reason: RecoveryReason)
	if recovering[player] or player.Parent ~= Players then
		return
	end
	recovering[player] = true
	local layoutId: Enums.LayoutId, slot: number = recoverySpot(player)
	log.info("%s: %s; respawning in %s", player.Name, reason, layoutId)
	xpcall(function()
		CharacterService.Spawn(player, CharacterService.SpawnCFrame(layoutId, slot))
	end, function(err: any)
		log.error("recovery spawn for %s failed: %s", player.Name, tostring(err))
	end)
	recovering[player] = nil
end

local function onDied(player: Player, model: Model)
	if not joined[player] or characters[player] ~= model then
		return
	end
	if handledElsewhere(player, model, "Died") then
		return
	end
	local generation = generations[player] or 0
	pendingDeaths[player] = generation
	task.delay(DEATH_RESPAWN_DELAY, function()
		if pendingDeaths[player] ~= generation then
			return -- a Spawn / Despawn superseded the death, or the player left
		end
		pendingDeaths[player] = nil
		if player.Parent == Players and joined[player] and (generations[player] or 0) == generation then
			respawn(player, "Died")
		end
	end)
end

-- Why `player` needs a new character right now (nil when fine or when someone else is handling them).
local function needsRecovery(player: Player): (RecoveryReason?, Model?)
	if
		not joined[player]
		or awaitingFirstSpawn[player]
		or spawning[player]
		or recovering[player]
		or despawned[player]
		or pendingDeaths[player] ~= nil
	then
		return nil, nil
	end
	local model: Model? = characters[player]
	local root: BasePart? = nil
	if model then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health <= 0 then
			return nil, model -- the Died path owns dead characters
		end
		if model:IsDescendantOf(Workspace) then
			root = rootOf(model)
		end
	end
	local reason: RecoveryReason? = CharacterService.recoveryReason(model ~= nil, if root then root.Position else nil)
	return reason, model
end

local function checkRecovery()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local found: RecoveryReason?, model: Model? = needsRecovery(player)
		if found == nil then
			continue
		end
		local reason: RecoveryReason = found
		local last = lastRecoveryAt[player]
		if last ~= nil and now - last < RECOVERY_RETRY_SECONDS then
			continue
		end
		lastRecoveryAt[player] = now
		if handledElsewhere(player, model, reason) then
			continue
		end
		task.spawn(respawn, player, reason)
	end
end

--------------------------------------------------------------------------------
-- Joining
--------------------------------------------------------------------------------

-- Dev access known without a web call: Studio, the allowlist, the user who created this experience, or the owner
-- of the creator group once Start has resolved it.
local function isDevUser(player: Player): boolean
	if RunService:IsStudio() or table.find(GameConfig.DevAllowlistUserIds, player.UserId) ~= nil then
		return true
	end
	if not GameConfig.DevToolsForCreator or game.CreatorId <= 0 then
		return false
	end
	if game.CreatorType == Enum.CreatorType.User then
		return player.UserId == game.CreatorId
	end
	return groupOwnerId ~= nil and player.UserId == groupOwnerId
end

-- A group-owned experience: the group's owner gets dev access too. GetGroupInfoAsync is a web call (yields, may fail),
-- and the answer is the same for the whole server, so it runs once, in the background, with retries, and is cached.
local function resolveGroupOwner()
	if not GameConfig.DevToolsForCreator or game.CreatorId <= 0 or game.CreatorType ~= Enum.CreatorType.Group then
		return
	end
	local groupId = game.CreatorId
	local resolved = CharacterService.withRetries(
		function(): boolean
			local ok, ownerId = pcall(function(): number?
				local groupInfo = GroupService:GetGroupInfoAsync(groupId)
				local owner = if type(groupInfo) == "table" then groupInfo.Owner else nil
				local id = if type(owner) == "table" then owner.Id else nil
				return if type(id) == "number" then id else nil
			end)
			if not ok then
				log.warn("group %d owner lookup failed: %s", groupId, tostring(ownerId))
				return false
			end
			groupOwnerId = ownerId
			return true
		end,
		GROUP_RETRY_DELAYS,
		function(seconds: number)
			task.wait(seconds)
		end
	)
	if not resolved then
		log.warn("group %d owner never resolved; the group owner has no dev tools on this server", groupId)
		return
	end
	for _, player in Players:GetPlayers() do
		if joined[player] and isDevUser(player) then
			player:SetAttribute(P.DevTools, true)
		end
	end
end

local function firstSpawn(player: Player)
	local startGeneration = generations[player] or 0
	while not WorldService.WaitUntilReady(READY_RECHECK_SECONDS) do
		if player.Parent ~= Players then
			return
		end
		log.warnThrottled("boot", 30, "still waiting for the world before spawning players")
	end
	if not WorldService.WaitForAck(player, GameConfig.ClientAckTimeout) then
		if player.Parent ~= Players then
			return
		end
		log.warn(
			"%s did not acknowledge the world within %ds; spawning anyway",
			player.Name,
			GameConfig.ClientAckTimeout
		)
	end
	-- Someone else (a dev run, a later phase) already spawned or is spawning this player.
	if player.Parent ~= Players or characters[player] or (generations[player] or 0) ~= startGeneration then
		return
	end
	CharacterService.SpawnInLobby(player)
end

local function initialSpawn(player: Player)
	awaitingFirstSpawn[player] = true
	firstSpawn(player)
	awaitingFirstSpawn[player] = nil
end
local function onPlayerAdded(player: Player)
	if joined[player] then
		return
	end
	joined[player] = true
	player:SetAttribute(P.DevTools, isDevUser(player))
	Attributes.set(player, P.ControlLock, "None")
	task.spawn(initialSpawn, player)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function CharacterService.Init()
	serviceTrove:Connect(Players.PlayerAdded, onPlayerAdded)
	serviceTrove:Add(WorldService.WorldAcked:Connect(onWorldAcked))
	serviceTrove:Add(died:Connect(onDied))
end

function CharacterService.Start()
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	task.spawn(resolveGroupOwner)
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		accumulated += dt
		if accumulated < RECOVERY_CHECK_SECONDS then
			return
		end
		accumulated = 0
		xpcall(checkRecovery, function(err: any)
			log.warnThrottled("recovery", 10, "recovery check failed: %s", tostring(err))
		end)
	end)
end

function CharacterService.EndRun()
	for player in table.clone(locks) do
		CharacterService.ReleaseLocks(player)
	end
	-- Everyone back to the lobby (players still waiting for their first spawn get there on their own).
	for _, player in Players:GetPlayers() do
		if joined[player] and not awaitingFirstSpawn[player] then
			task.spawn(CharacterService.SpawnInLobby, player)
		end
	end
end

function CharacterService.OnPlayerRemoving(player: Player)
	bump(player)
	locks[player] = nil
	local model = characters[player]
	characters[player] = nil
	if model then
		removeCharacter(player, model)
	end
	local description = descriptions[player]
	descriptions[player] = nil
	if description then
		description:Destroy()
	end
	joined[player] = nil
	generations[player] = nil
	spawning[player] = nil
	loadingHolds[player] = nil
	awaitingFirstSpawn[player] = nil
	despawned[player] = nil
	pendingDeaths[player] = nil
	recovering[player] = nil
	lastRecoveryAt[player] = nil
end

return CharacterService
