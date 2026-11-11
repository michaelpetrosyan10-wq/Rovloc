--!strict
-- ObjectiveService: every floor's objective (ObjectiveConfig; the web build's game/objectives mirrors it). The only
-- writer of the objective props' poses after the build, of the ExitLock / station prompts' text and hold, of a
-- player's Carrying and of the ReplicatedStorage Objective* / Power* attributes.
--
-- Core rule: a floor's exit (the fire door of the stairwell the run leaves it by, LevelDirector.exitFor) stays Locked
-- until the floor's lockStep is done; a floor without a lock step (ReachExit) is open from the start and its one step
-- is done when the squad leaves it. Every exit candidate carries an ExitLock; only the
-- route's is live (the others hold jammed doors, whose own prompt says the stairwell has collapsed, and offer nothing).
-- BeginRun locks the route's exit fire door (DoorService, snapped shut), resets every lock and station to its built
-- pose and keeps the picked items (RunDirector.plan's objectives) in the world; CheckpointAirlockService runs nothing on a floor until ExitOpen says so. Completing the lock
-- step unlocks it: the lock comes off over LockOffSeconds, the bolts clunk (ObjExitClunk and the loud ObjectiveClunk
-- noise at the door: the Creature hears it), the door swings Open DoorDelay later, the tracker switches to the
-- stairwell and Unlocked fires.
--
-- Prompts (InteractionService handlers, one per PromptKind; a prompt only answers on the current, active level):
--   Pickup     a picked item in the world (its hold from ObjectiveConfig) into the actor's carry
--   Locked     "Locked — <reason>" (hold 0): a rattle or the keypad's denial, no noise
--   Unlock / FitFuse   need the item: shown (with the step's hold) while anyone in the squad carries it, and only its
--              carrier may use it (anyone else: Obj.TeammateHas); without it FitFuse reads "Find a fuse first" (hold 0:
--              a rattle and the reason)
--   Breaker    the breaker panel's working hold
-- A working hold (the unlock) emits the Normal ObjectiveWork noise at its start and once a second, with its loop at the
-- station; the breaker lever creeps with its hold.
--
-- The objectives (ObjectiveConfig.Floors, by id):
--   RestorePower  fuses into the breaker panel's slots in order (each slot's lamp turns green), then the main breaker:
--                 the lever throws, ObjBreakerThrow, the loud noise, and the basement's mains come back on
--                 (PowerOffLevel / PowerOnAt: the clients' LightingController holds them at PowerOffFactor until then
--                 and stutters them on over PowerOnSeconds).
--   MasterKeys    the master keys, then Unlock (4 s, the keys worked in the padlock).
--   ReachExit     nothing to find or unlock: the step is done when the squad leaves the floor.
--
-- Carrying (Player Carrying, ObjectiveState). Items survive being downed. A carrier who dies, is left behind, goes to
-- the lobby or leaves drops everything at their feet (the first surface under them), each item back in the world with
-- its Pickup prompt, so any teammate can take it on: a floor can never be softlocked by a lost item.
--
-- The HUD (ObjectiveTracker) reads the current floor from ReplicatedStorage: ObjectiveLevel, ObjectiveSteps and
-- ObjectiveUnlocked.
--
-- Dev command: objective [done] (the current floor's state, or complete it through its own unlock path).
-- SetClock swaps the time source; Step(now) runs one tick (the Heartbeat driver; specs drive it by hand).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local ObjectiveState = require(ReplicatedStorage.Shared.Util.ObjectiveState)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local BreakerPanelBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.BreakerPanelBuilder)
local LockBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.LockBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local DoorService = require(ServerScriptService.Services.Mechanics.DoorService)

local log = Log.new("Objective")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World
local T = ObjectiveConfig.Tuning

export type Clock = () -> number

export type ItemState = "World" | "Carried" | "Used"

type Item = {
	model: Model,
	anchorId: string,
	kind: string, -- the plan prop kind (Fuse, MasterKeys)
	state: ItemState,
	carrier: Player?,
	parent: Instance, -- its runtime folder (where it goes back to)
	home: CFrame, -- the pivot it was built at
	room: string?, -- its candidate anchor's room (nil once dropped elsewhere)
	found: boolean, -- taken once already (its find step counted)
}

type Work = {
	kind: string,
	seconds: number,
	done: number, -- kept progress (seconds) of a hold that keeps it
	since: number?, -- when the running hold began
	actor: Player?,
	keep: boolean,
	noise: boolean,
	sound: string?,
	voice: AudioService.CueHandle?,
	nextNoiseAt: number,
	at: () -> Vector3,
	onProgress: ((share: number) -> ())?,
	finished: boolean,
}

type Tween = { startAt: number, seconds: number, update: (t: number) -> (), done: (() -> ())? }

type Floor = {
	spec: ObjectiveConfig.FloorSpec,
	levelId: Enums.LevelId,
	picks: Types.ObjectivePicks?,
	progress: { [string]: number },
	unlocked: boolean,
	active: boolean,
	items: { Item },
	lock: Model?, -- the exit lock
	doors: { Model }, -- the exit fire doors it holds
	works: { [string]: Work },
	-- RestorePower
	panel: Model?,
	fitted: { [number]: Item },
	powered: boolean,
	powerOnAt: number?,
}

local ObjectiveService = {}

ObjectiveService.Name = "ObjectiveService"

local unlockedSignal: Signal.Signal<Enums.LevelId, Player?> = Signal.new()
local stepSignal: Signal.Signal<Enums.LevelId, string, number> = Signal.new()

-- (levelId, actor) when a floor's exit unlocks.
ObjectiveService.Unlocked = unlockedSignal
-- (levelId, stepId, count) whenever a step advances.
ObjectiveService.StepAdvanced = stepSignal

local DROP_STATES: { [string]: boolean } = { Dead = true, Spectating = true, Lobby = true }
local DROP_RAY = 40
local PADLOCK_TILT = math.rad(60)
local NEED_ITEM = "Obj.TeammateHas"
local LIVE_PHASES: { [string]: boolean } = { Deploying = true, InRun = true }

local serviceTrove = Trove.new()
local initialized = false
local running = false
local live = false
local run: Types.RunContext? = nil
local clock: Clock = function(): number
	return Workspace:GetServerTimeNow()
end
local realClock = clock

local floors: { [string]: Floor } = {}
local itemsByModel: { [Model]: Item } = {}
local carries: { [Player]: { order: { string }, items: { Item } } } = {}
local tweens: { Tween } = {}
local storage: Folder? = nil

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/ObjectiveFlow.spec.luau)
--------------------------------------------------------------------------------

-- A working hold's progress (0..1) at `now`: kept seconds plus the running hold.
function ObjectiveService.workProgress(seconds: number, done: number, since: number?, now: number): number
	local runningFor = if since then math.max(0, now - since) else 0
	return math.clamp((done + runningFor) / math.max(seconds, 1e-3), 0, 1)
end

-- The hold left on a kept hold (never under 0.05 s, so the prompt stays a hold).
function ObjectiveService.holdLeft(seconds: number, done: number): number
	return math.max(0.05, seconds - done)
end

-- The spot of the `index`-th item a carrier drops around `centre` (a small spiral, ObjectiveConfig DropSpread apart).
function ObjectiveService.dropOffset(index: number): Vector3
	if index <= 1 then
		return Vector3.zero
	end
	local angle = (index - 2) * 2.4
	local radius = T.DropSpread * (1 + (index - 2) * 0.25)
	return Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function now(): number
	return clock()
end

local function storageFolder(): Folder
	local folder = storage
	if folder and folder.Parent then
		return folder
	end
	local made = Instance.new("Folder")
	made.Name = "ObjectiveCarried"
	made.Parent = ServerStorage
	storage = made
	return made
end

local function attachmentWorld(model: Instance?, name: string): CFrame?
	if not model then
		return nil
	end
	local attachment = PropKit.findAttachment(model, name)
	return if attachment then PropKit.attachmentWorld(attachment) else nil
end

local function pointOf(model: Instance?, name: string): Vector3?
	local cframe = attachmentWorld(model, name)
	if cframe then
		return cframe.Position
	end
	if model and model:IsA("Model") then
		return model.WorldPivot.Position
	end
	return nil
end

local function promptsOf(model: Instance?, kind: Enums.PromptKind): { ProximityPrompt }
	local out: { ProximityPrompt } = {}
	if not model then
		return out
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ProximityPrompt") and descendant:GetAttribute(W.PromptKind) == kind then
			table.insert(out, descendant)
		end
	end
	return out
end

local function setPrompt(prompt: ProximityPrompt?, action: string, object: string?, hold: number?)
	if not prompt then
		return
	end
	if prompt.ActionText ~= action then
		prompt.ActionText = action
	end
	if object and prompt.ObjectText ~= object then
		prompt.ObjectText = object
	end
	if hold then
		prompt:SetAttribute(W.BaseHold, hold)
	end
end

local function playAt(preset: string, position: Vector3?, options: AudioService.CueOptions?): AudioService.CueHandle?
	if not position then
		return nil
	end
	return AudioService.PlayAt(preset, position, options)
end

local function noise(position: Vector3?, kind: Enums.NoiseKind, source: Player?, levelId: Enums.LevelId)
	if position then
		NoiseAndDirectorService.Emit(position, kind, { sourcePlayer = source, levelId = levelId })
	end
end

-- Tells every playing participant (the squad moves floor to floor together).
local function notifyLevel(_levelId: Enums.LevelId, key: string, ...: any)
	local args: { string } = {}
	for i = 1, select("#", ...) do
		table.insert(args, tostring((select(i, ...))))
	end
	local current = run
	local list: { Player } = if current then current.participants else {}
	for _, player in list do
		if LifeStateService.IsPlaying(player) then
			local payload: Types.NotifyPayload = { key = key, args = args }
			Net.Server.fire("Notify", player, payload)
		end
	end
end

local function notifyPlayer(player: Player, key: string, ...: any)
	local args: { string } = {}
	for i = 1, select("#", ...) do
		table.insert(args, tostring((select(i, ...))))
	end
	local payload: Types.NotifyPayload = { key = key, args = args }
	Net.Server.fire("Notify", player, payload)
end

local function addTween(seconds: number, delay: number, update: (t: number) -> (), done: (() -> ())?)
	table.insert(tweens, { startAt = now() + delay, seconds = seconds, update = update, done = done })
end

local function smooth(t: number): number
	return t * t * (3 - 2 * t)
end

local function stepOf(spec: ObjectiveConfig.FloorSpec, id: string): ObjectiveConfig.StepSpec?
	for _, step in spec.steps do
		if step.id == id then
			return step
		end
	end
	return nil
end

local function count(floor: Floor, id: string): number
	return floor.progress[id] or 0
end

local function isDone(floor: Floor, id: string): boolean
	local step = stepOf(floor.spec, id)
	return step ~= nil and count(floor, id) >= step.count
end

local function onLevel(instance: Instance, levelId: string): boolean
	return instance:GetAttribute(W.LevelId) == levelId
end

local function tagged(tag: string, levelId: string, objectiveId: string?): { Model }
	local out: { Model } = {}
	local runtime = Instances.runtime()
	for _, instance in CollectionService:GetTagged(tag) do
		if
			instance:IsA("Model")
			and onLevel(instance, levelId)
			and (objectiveId == nil or instance:GetAttribute(W.ObjectiveId) == objectiveId)
			and (runtime == nil or instance:IsDescendantOf(runtime) or instance:IsDescendantOf(Workspace))
		then
			table.insert(out, instance)
		end
	end
	table.sort(out, function(a: Model, b: Model): boolean
		return Attributes.getString(a, W.AnchorId, a.Name) < Attributes.getString(b, W.AnchorId, b.Name)
	end)
	return out
end

local function floorOfHost(host: Instance): Floor?
	local levelId = host:GetAttribute(W.LevelId)
	if type(levelId) ~= "string" then
		return nil
	end
	local floor = floors[levelId]
	if floor and floor.active and live then
		return floor
	end
	return nil
end

--------------------------------------------------------------------------------
-- Carrying
--------------------------------------------------------------------------------

local function carryOf(player: Player): { order: { string }, items: { Item } }
	local carry = carries[player]
	if not carry then
		carry = { order = {}, items = {} }
		carries[player] = carry
	end
	return carry
end

local function writeCarry(player: Player)
	local carry = carries[player]
	local counts: { [string]: number } = {}
	local order: { string } = {}
	if carry then
		for _, item in carry.items do
			counts[item.kind] = (counts[item.kind] or 0) + 1
		end
		order = carry.order
	end
	Attributes.set(player, P.Carrying, ObjectiveState.encodeCarry(order, counts))
end

local function carried(player: Player, kind: string): { Item }
	local out: { Item } = {}
	local carry = carries[player]
	if carry then
		for _, item in carry.items do
			if item.kind == kind then
				table.insert(out, item)
			end
		end
	end
	return out
end

-- Whether any playing participant carries an item of `kind`.
local function anyCarries(kind: string): boolean
	for player, carry in carries do
		if LifeStateService.IsPlaying(player) then
			for _, item in carry.items do
				if item.kind == kind then
					return true
				end
			end
		end
	end
	return false
end

local function stash(item: Item)
	item.model.Parent = storageFolder()
end

local function unstash(item: Item)
	item.model.Parent = item.parent
end

local function takeInto(player: Player, item: Item)
	item.state = "Carried"
	item.carrier = player
	stash(item)
	local carry = carryOf(player)
	table.insert(carry.items, item)
	if not table.find(carry.order, item.kind) then
		table.insert(carry.order, item.kind)
	end
	writeCarry(player)
end

-- Uses one carried item of `kind` from `player` (it stays out of the world until the caller places it). Nil when none.
local function useCarried(player: Player, kind: string): Item?
	local carry = carries[player]
	if not carry then
		return nil
	end
	for index, item in carry.items do
		if item.kind == kind then
			table.remove(carry.items, index)
			item.state = "Used"
			item.carrier = nil
			writeCarry(player)
			return item
		end
	end
	return nil
end

-- The point a carrier at `position` drops onto: the first surface under it (bodies ignored).
local function dropPoint(position: Vector3): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	local creature = Instances.creature()
	if creature then
		table.insert(exclude, creature)
	end
	params.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(position, Vector3.new(0, -DROP_RAY, 0), params)
	if hit then
		return hit.Position
	end
	return position - Vector3.new(0, 3, 0)
end

local refreshFloor: (floor: Floor) -> ()

-- Everything `player` carries goes back into the world at their feet (see the header).
local function dropAll(player: Player, at: Vector3?)
	local carry = carries[player]
	carries[player] = nil
	Attributes.set(player, P.Carrying, "")
	if not carry or #carry.items == 0 then
		return
	end
	local root = Instances.characterRoot(player)
	local position = at or (if root then root.CFrame.Position else nil)
	local floor = dropPoint(position or Vector3.zero)
	for index, item in carry.items do
		item.state = "World"
		item.carrier = nil
		local target = if position
			then CFrame.new(floor + ObjectiveService.dropOffset(index)) * item.home.Rotation
			else item.home
		PropKit.moveModel(item.model, target)
		item.room = nil
		unstash(item)
		log.info("%s dropped %s", player.Name, item.anchorId)
	end
	for _, f in floors do
		refreshFloor(f)
	end
end

--------------------------------------------------------------------------------
-- Working holds
--------------------------------------------------------------------------------

local function newWork(
	kind: string,
	seconds: number,
	at: () -> Vector3,
	options: { keep: boolean?, noise: boolean?, sound: string?, onProgress: ((number) -> ())? }
): Work
	return {
		kind = kind,
		seconds = seconds,
		done = 0,
		since = nil,
		actor = nil,
		keep = options.keep == true,
		noise = options.noise == true,
		sound = options.sound,
		voice = nil,
		nextNoiseAt = math.huge,
		at = at,
		onProgress = options.onProgress,
		finished = false,
	}
end

local function workShare(work: Work): number
	return ObjectiveService.workProgress(work.seconds, work.done, work.since, now())
end

local function beginWork(work: Work, player: Player)
	if work.finished or work.since ~= nil then
		return
	end
	local t = now()
	work.since = t
	work.actor = player
	work.nextNoiseAt = t
	local sound = work.sound
	if sound then
		work.voice = playAt(sound, work.at(), { duration = work.seconds - work.done + 1 })
	end
end

local function stopVoice(work: Work)
	local voice = work.voice
	work.voice = nil
	if voice then
		voice:Stop(0.15)
	end
end

local function cancelWork(work: Work)
	local since = work.since
	if since == nil then
		return
	end
	work.since = nil
	work.actor = nil
	work.nextNoiseAt = math.huge
	stopVoice(work)
	if work.keep then
		work.done = math.min(work.seconds - 0.05, work.done + math.max(0, now() - since))
	end
	local progress = work.onProgress
	if progress then
		progress(if work.keep then workShare(work) else 0)
	end
end

local function finishWork(work: Work)
	work.finished = true
	work.since = nil
	work.actor = nil
	work.nextNoiseAt = math.huge
	stopVoice(work)
	local progress = work.onProgress
	if progress then
		progress(1)
	end
end

local function stepWork(work: Work, floor: Floor, t: number)
	if work.since == nil then
		return
	end
	if work.noise and t >= work.nextNoiseAt then
		work.nextNoiseAt = t + T.WorkNoisePeriod
		noise(work.at(), T.WorkNoise, work.actor, floor.levelId)
	end
	local progress = work.onProgress
	if progress then
		progress(workShare(work))
	end
end

--------------------------------------------------------------------------------
-- Replication (the HUD)
--------------------------------------------------------------------------------

local function replicate(floor: Floor)
	if not floor.active then
		return
	end
	Attributes.set(ReplicatedStorage, M.ObjectiveLevel, floor.levelId)
	Attributes.set(ReplicatedStorage, M.ObjectiveSteps, ObjectiveState.encodeSteps(floor.spec, floor.progress))
	Attributes.set(ReplicatedStorage, M.ObjectiveUnlocked, floor.unlocked)
end

local function clearReplication()
	for _, key in
		{
			M.ObjectiveLevel,
			M.ObjectiveSteps,
			M.ObjectiveUnlocked,
			M.PowerOffLevel,
			M.PowerOnAt,
		}
	do
		ReplicatedStorage:SetAttribute(key, nil)
	end
end

--------------------------------------------------------------------------------
-- Prompt state (texts, holds, who serves what)
--------------------------------------------------------------------------------

-- How many items a floor's objective uses (0 without an item).
local function itemCount(floor: Floor): number
	local item = floor.spec.item
	return if item then item.count else 0
end

local function nextSlot(floor: Floor): number?
	for slot = 1, itemCount(floor) do
		if floor.fitted[slot] == nil then
			return slot
		end
	end
	return nil
end

local function refreshHosts(floor: Floor)
	local hosts: { [Instance]: boolean } = {}
	local function add(instance: Instance?)
		if instance and instance.Parent then
			hosts[instance] = true
		end
	end
	for _, item in floor.items do
		add(item.model)
	end
	add(floor.lock)
	add(floor.panel)
	for host in hosts do
		-- protected: one host failing to refresh never stops the floor's other prompts (or a run start)
		xpcall(InteractionService.Refresh, function(err: any)
			log.warnThrottled("refresh", 10, "prompt refresh on %s failed: %s", host:GetFullName(), tostring(err))
		end, host)
	end
end

refreshFloor = function(floor: Floor)
	local spec = floor.spec
	if floor.panel then
		local slot = nextSlot(floor)
		local have = anyCarries("Fuse")
		local fittedCount = 0
		for _ in floor.fitted do
			fittedCount += 1
		end
		for _, prompt in promptsOf(floor.panel, "FitFuse") do
			if prompt:GetAttribute(W.Slot) == slot then
				if have then
					setPrompt(
						prompt,
						Strings.get("Prompt.FitFuse"),
						Strings.get("Prompt.BreakerPanel"),
						ObjectiveConfig.hold(spec, "FitFuse")
					)
				else
					setPrompt(
						prompt,
						Strings.get("Obj.Prompt.NeedFuse", fittedCount, itemCount(floor)),
						Strings.get("Prompt.BreakerPanel"),
						0
					)
				end
			end
		end
	end
	refreshHosts(floor)
	replicate(floor)
end

-- Whether a prompt of `kind` on `host` answers now (the handlers' filter).
local function serves(kind: Enums.PromptKind, host: Instance, prompt: ProximityPrompt): boolean
	local floor = floorOfHost(host)
	if not floor then
		return false
	end
	if kind == "Pickup" then
		local item = if host:IsA("Model") then itemsByModel[host] else nil
		return item ~= nil and item.state == "World" and item.model.Parent ~= storage
	end
	if host == floor.lock and floor.lock ~= nil then
		if floor.unlocked then
			return false
		end
		-- the master keys open the padlock; every other lock opens by its floor's own step
		local keys = floor.spec.lockVariant == "Padlock" and floor.spec.holds.Unlock ~= nil
		if kind == "Locked" then
			return not (keys and anyCarries("MasterKeys"))
		elseif kind == "Unlock" then
			return keys and anyCarries("MasterKeys")
		end
		return false
	end
	if host == floor.panel then
		if kind == "FitFuse" then
			return prompt:GetAttribute(W.Slot) == nextSlot(floor)
		elseif kind == "Breaker" then
			return nextSlot(floor) == nil and not floor.powered
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Locks
--------------------------------------------------------------------------------

local function variantOf(model: Model): string
	return Attributes.getString(model, W.LockVariant, "Padlock")
end

local function rattle(model: Model?)
	if not model then
		return
	end
	playAt(if variantOf(model) == "Keypad" then "ObjKeypadDenied" else "ObjLockRattle", pointOf(model, "LockPrompt"))
end

-- Drops a leaf of a lock to the floor under it, tipping as it falls.
local function dropLeaf(model: Model, name: string, seconds: number, delay: number)
	local rest = PropKit.leafRest(model, name)
	if not rest then
		return
	end
	local floorY = model.WorldPivot.Position.Y
	local fall = math.max(0, rest.Position.Y - floorY - 0.12)
	local tilt = PADLOCK_TILT
	addTween(seconds, delay, function(t: number)
		if not model.Parent then
			return
		end
		local eased = if t < 0.8 then (t / 0.8) ^ 2 else 1 - 0.08 * math.sin((t - 0.8) / 0.2 * math.pi)
		local world = CFrame.new(0, -fall * eased, 0) * rest * CFrame.Angles(tilt * math.min(1, t * 1.2), 0, 0)
		PropKit.poseLeaf(model, name, rest:ToObjectSpace(world))
	end)
end

-- Takes a lock off (Padlock: the padlock springs and drops; Keypad: the accept chirp, the LED green, the bar slides
-- clear).
local function releaseLock(model: Model)
	model:SetAttribute(W.Locked, false)
	local at = pointOf(model, "LockPrompt")
	local seconds = T.LockOffSeconds
	if variantOf(model) == "Keypad" then
		playAt("ObjKeypadAccept", at)
		local led = model:FindFirstChild("Led", true)
		if led and led:IsA("BasePart") then
			led.Color = Color3.fromRGB(64, 255, 90)
		end
		addTween(seconds, 0, function(t: number)
			if model.Parent then
				LockBuilder.setBar(model, smooth(t))
			end
		end)
		return
	end
	playAt("ObjPadlockClack", at)
	if PropKit.leafRest(model, "Padlock") then
		dropLeaf(model, "Padlock", seconds * 0.7, 0)
	end
end

-- Once the door swings: the parts riding its leaves go (the dropped padlock stays where it fell).
local function detachLock(model: Model)
	if variantOf(model) == "Keypad" then
		model:Destroy()
		return
	end
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and child ~= model.PrimaryPart then
			child:Destroy()
		end
	end
end

local function unlock(floor: Floor, actor: Player?)
	if floor.unlocked then
		return
	end
	floor.unlocked = true
	local lock = floor.lock
	local doors = floor.doors
	local at: Vector3? = nil
	if doors[1] then
		at = doors[1].WorldPivot.Position + Vector3.new(0, 4, 0)
	elseif lock then
		at = pointOf(lock, "LockPrompt")
	end
	if lock then
		releaseLock(lock)
	end
	playAt("ObjExitClunk", at)
	noise(at, T.LoudNoise, actor, floor.levelId)
	addTween(0, T.DoorDelay, function(_t: number) end, function()
		if lock and lock.Parent then
			detachLock(lock)
		end
		for _, door in doors do
			if door.Parent then
				DoorService.SetState(door, "Open")
			end
		end
	end)
	notifyLevel(floor.levelId, "Obj.ExitUnlocked")
	log.info("%s: the exit is unlocked", floor.levelId)
	refreshFloor(floor)
	unlockedSignal:Fire(floor.levelId, actor)
end

local function advance(floor: Floor, id: string, actor: Player?, n: number?)
	local step = stepOf(floor.spec, id)
	if not step then
		return
	end
	floor.progress[id] = math.min(step.count, count(floor, id) + (n or 1))
	stepSignal:Fire(floor.levelId, id, floor.progress[id])
	if id == floor.spec.lockStep and isDone(floor, id) then
		unlock(floor, actor)
	end
	refreshFloor(floor)
end

--------------------------------------------------------------------------------
-- RestorePower
--------------------------------------------------------------------------------

local function seatPivot(model: Model, attachmentName: string, seat: CFrame): CFrame
	local grip = attachmentWorld(model, attachmentName)
	if not grip then
		return seat
	end
	return seat * model.WorldPivot:ToObjectSpace(grip):Inverse()
end

local function fitFuse(floor: Floor, player: Player, slot: number)
	local panel = floor.panel
	if not panel or slot ~= nextSlot(floor) then
		return
	end
	local at = pointOf(panel, "FuseSlot" .. slot .. "Prompt")
	local item = useCarried(player, "Fuse")
	if not item then
		playAt("ObjLockRattle", at, { volume = 0.5 })
		notifyPlayer(player, "Obj.NeedFuse")
		return
	end
	local seat = attachmentWorld(panel, "FuseSlot" .. slot .. "Seat")
	if seat then
		PropKit.moveModel(item.model, seatPivot(item.model, "Grip", seat))
	end
	unstash(item)
	floor.fitted[slot] = item
	BreakerPanelBuilder.setSlotLamp(panel, slot, "Green")
	playAt("ObjFuseClick", at)
	advance(floor, "FitFuses", player)
end

local function throwBreaker(floor: Floor, player: Player?)
	local panel = floor.panel
	if not panel or floor.powered then
		return
	end
	floor.powered = true
	local at = pointOf(panel, "LeverPrompt")
	addTween(0.3, 0, function(t: number)
		BreakerPanelBuilder.setLever(panel, T.LeverCreep + (1 - T.LeverCreep) * t * t)
	end)
	local lamp = panel:FindFirstChild("MainLamp", true)
	if lamp and lamp:IsA("BasePart") then
		lamp.Color = BreakerPanelBuilder.LampLit.green
		lamp.Material = Enum.Material.Neon
	end
	playAt("ObjBreakerThrow", at)
	noise(at, T.LoudNoise, player, floor.levelId)
	local onAt = now() + 0.25
	floor.powerOnAt = onAt
	Attributes.set(ReplicatedStorage, M.PowerOnAt, onAt)
	advance(floor, "ThrowBreaker", player)
end

--------------------------------------------------------------------------------
-- Handlers
--------------------------------------------------------------------------------

local function carriesOrTeammate(player: Player, kind: string): (boolean, string?)
	if #carried(player, kind) > 0 then
		return true, nil
	end
	return false, NEED_ITEM
end

local function take(floor: Floor, player: Player, host: Instance)
	local item = if host:IsA("Model") then itemsByModel[host] else nil
	if not item or item.state ~= "World" then
		return
	end
	local at = pointOf(item.model, "PromptPoint")
	takeInto(player, item)
	-- a dropped item taken on again is not found twice
	local first = not item.found
	item.found = true
	local kind = item.kind
	if kind == "Fuse" then
		playAt("ObjFuseClick", at, { volume = 0.7 })
		if first then
			advance(floor, "FindFuses", player)
		end
	elseif kind == "MasterKeys" then
		playAt("ObjKeyJingle", at)
		if first then
			advance(floor, "FindKeys", player)
		end
	end
	refreshFloor(floor)
end

-- The work of a kind, or nil.
local function workFor(floor: Floor, kind: string): Work?
	return floor.works[kind]
end

local function completeWork(floor: Floor, kind: string, player: Player)
	if kind == "Unlock" then
		if useCarried(player, "MasterKeys") then
			advance(floor, "UnlockExit", player)
		end
	elseif kind == "Breaker" then
		throwBreaker(floor, player)
	end
end

local function canUseFor(
	kind: Enums.PromptKind,
	player: Player,
	prompt: ProximityPrompt,
	host: Instance
): (boolean, string?)
	if LifeStateService.GetState(player) ~= "Alive" then
		return false, "LifeState"
	end
	if not floorOfHost(host) then
		return false, "Inactive"
	end
	local hold = prompt:GetAttribute(W.BaseHold)
	local instant = type(hold) == "number" and hold <= 0
	if kind == "Unlock" then
		return carriesOrTeammate(player, "MasterKeys")
	elseif kind == "FitFuse" and not instant then
		return carriesOrTeammate(player, "Fuse")
	end
	return true, nil
end

local function onBegin(kind: Enums.PromptKind, player: Player, _prompt: ProximityPrompt, host: Instance)
	local floor = floorOfHost(host)
	if not floor then
		return
	end
	local work = workFor(floor, kind)
	if work then
		beginWork(work, player)
	end
end

local function onCancel(
	kind: Enums.PromptKind,
	player: Player,
	_prompt: ProximityPrompt,
	host: Instance,
	_reason: string
)
	local levelId = host:GetAttribute(W.LevelId)
	local floor = if type(levelId) == "string" then floors[levelId] else nil
	if not floor then
		return
	end
	local work = workFor(floor, kind)
	if work and work.actor == player then
		cancelWork(work)
		refreshFloor(floor)
	end
end

local function onComplete(kind: Enums.PromptKind, player: Player, prompt: ProximityPrompt, host: Instance)
	local floor = floorOfHost(host)
	if not floor then
		return
	end
	if kind == "Pickup" then
		take(floor, player, host)
	elseif kind == "Locked" then
		rattle(if host:IsA("Model") then host else nil)
	elseif kind == "FitFuse" then
		local slot = prompt:GetAttribute(W.Slot)
		if type(slot) == "number" then
			fitFuse(floor, player, slot)
		end
	else
		local work = workFor(floor, kind)
		if work and not work.finished then
			finishWork(work)
			completeWork(floor, kind, player)
		end
	end
	refreshFloor(floor)
end

local HANDLED: { Enums.PromptKind } = { "Pickup", "Locked", "Unlock", "FitFuse", "Breaker" }

-- The handler serving every objective prompt of `kind` (InteractionService).
local function handlerFor(kind: Enums.PromptKind): InteractionService.Handler
	return {
		kind = kind,
		filter = function(host: Instance, prompt: ProximityPrompt): boolean
			if kind == "Pickup" and not host:HasTag(Tags.ObjectiveItem) then
				return false
			end
			return serves(kind, host, prompt)
		end,
		canUse = function(player: Player, prompt: ProximityPrompt, host: Instance): (boolean, string?)
			return canUseFor(kind, player, prompt, host)
		end,
		onBegin = function(player: Player, prompt: ProximityPrompt, host: Instance)
			onBegin(kind, player, prompt, host)
		end,
		onComplete = function(player: Player, prompt: ProximityPrompt, host: Instance)
			onComplete(kind, player, prompt, host)
		end,
		onCancel = function(player: Player, prompt: ProximityPrompt, host: Instance, reason: string)
			onCancel(kind, player, prompt, host, reason)
		end,
	}
end

ObjectiveService.Handlers = {} :: { [string]: InteractionService.Handler }
for _, kind in HANDLED do
	ObjectiveService.Handlers[kind] = handlerFor(kind :: Enums.PromptKind)
end

--------------------------------------------------------------------------------
-- Run setup
--------------------------------------------------------------------------------

local function layoutAnchor(levelId: string, id: string): LayoutSchema.Anchor?
	local layout = Builder.getLayout(levelId)
	if not layout then
		return nil
	end
	for _, anchor in layout.anchors do
		if anchor.id == id then
			return anchor
		end
	end
	return nil
end

-- The fire door(s) `lock` holds (its DoorId), else the level's exit fire doors of the stairwell `stairwellId`.
local function exitDoorsOf(levelId: Enums.LevelId, lock: Model?, stairwellId: string?): { Model }
	local out: { Model } = {}
	local doorId = if lock then lock:GetAttribute(W.DoorId) else nil
	if type(doorId) == "string" then
		local door = DoorService.Get(levelId, doorId)
		if door then
			table.insert(out, door)
			return out
		end
	end
	for _, door in DoorService.Airlocks(levelId) do
		local stairwell = door:GetAttribute(W.StairwellId)
		if
			door:GetAttribute(W.FromLevel) == levelId
			and door:GetAttribute(W.LevelId) == levelId
			and (stairwell == nil or stairwellId == nil or stairwell == stairwellId)
		then
			table.insert(out, door)
		end
	end
	return out
end

local function newFloor(spec: ObjectiveConfig.FloorSpec): Floor
	local levelId: Enums.LevelId = spec.levelId
	local plan = NoiseAndDirectorService.GetPlan()
	local picks = if plan and plan.objectives then plan.objectives[levelId] else nil
	local floor: Floor = {
		spec = spec,
		levelId = levelId,
		picks = picks,
		progress = {},
		-- a floor without a lock step is open from the start
		unlocked = spec.lockStep == nil,
		active = false,
		items = {},
		lock = nil,
		doors = {},
		works = {},
		panel = nil,
		fitted = {},
		powered = false,
		powerOnAt = nil,
	}
	-- the picked items (only the run's picks are built)
	local itemSpec = spec.item
	local models: { Model } = if itemSpec then tagged(Tags.ObjectiveItem, levelId, itemSpec.prop) else {}
	for _, model in models do
		local item: Item = {
			model = model,
			anchorId = Attributes.getString(model, W.AnchorId, model.Name),
			kind = Attributes.getString(model, W.ObjectiveId, ""),
			state = "World",
			carrier = nil,
			parent = model.Parent or (Instances.runtimeLevel(levelId, true) :: Folder),
			home = model.WorldPivot,
			room = nil,
			found = false,
		}
		local anchor = layoutAnchor(levelId, item.anchorId)
		item.room = if anchor then anchor.room else nil
		table.insert(floor.items, item)
		itemsByModel[model] = item
	end
	-- the exit's lock and doors: the route's stairwell (the other candidates' doors are jammed for the run)
	local exit = LevelDirector.exitFor(levelId)
	local exitId = if exit then exit.id else nil
	local locks: { Model } = if spec.lockVariant then tagged(Tags.ExitLock, levelId, "ExitLock") else {}
	for _, lock in locks do
		lock:SetAttribute(W.Locked, true)
		local doors = exitDoorsOf(levelId, lock, exitId)
		local stairwell = if doors[1] then doors[1]:GetAttribute(W.StairwellId) else nil
		if floor.lock == nil and (stairwell == nil or exitId == nil or stairwell == exitId) then
			floor.lock = lock
			floor.doors = doors
		end
	end
	if spec.lockVariant and floor.lock == nil then
		floor.doors = exitDoorsOf(levelId, nil, exitId)
	end
	for _, door in floor.doors do
		DoorService.SetState(door, "Locked", 0)
	end
	local function station(objectiveId: string): Model?
		return tagged(Tags.ObjectiveStation, levelId, objectiveId)[1]
	end
	if spec.id == "RestorePower" then
		local panel = station("BreakerPanel")
		floor.panel = panel
		if panel then
			BreakerPanelBuilder.setLever(panel, 0)
			floor.works.Breaker = newWork("Breaker", ObjectiveConfig.hold(spec, "Breaker"), function(): Vector3
				return pointOf(panel, "LeverPrompt") or panel.WorldPivot.Position
			end, {
				onProgress = function(share: number)
					BreakerPanelBuilder.setLever(panel, share * T.LeverCreep)
				end,
			})
		end
		Attributes.set(ReplicatedStorage, M.PowerOffLevel, levelId)
		ReplicatedStorage:SetAttribute(M.PowerOnAt, nil)
	elseif spec.id == "MasterKeys" then
		local lock = floor.lock
		if lock then
			floor.works.Unlock = newWork("Unlock", ObjectiveConfig.hold(spec, "Unlock"), function(): Vector3
				return pointOf(lock, "LockPrompt") or lock.WorldPivot.Position
			end, { noise = true, sound = "ObjKeysWork" })
		end
	end
	return floor
end

--------------------------------------------------------------------------------
-- Ticking
--------------------------------------------------------------------------------

-- One tick at server time `t` (default now): tweens, working holds, timers (the Heartbeat driver; specs call it).
function ObjectiveService.Step(at: number?)
	if not running then
		return
	end
	local t = at or now()
	local pending = tweens
	tweens = {}
	local keep: { Tween } = {}
	for _, tween in pending do
		if t < tween.startAt then
			table.insert(keep, tween)
			continue
		end
		local share = if tween.seconds > 0 then math.min(1, (t - tween.startAt) / tween.seconds) else 1
		tween.update(share)
		if share >= 1 then
			local done = tween.done
			if done then
				done()
			end
		else
			table.insert(keep, tween)
		end
	end
	for _, added in tweens do
		table.insert(keep, added)
	end
	tweens = keep
	for _, floor in floors do
		for _, work in floor.works do
			stepWork(work, floor, t)
		end
		if not floor.active then
			continue
		end
		local onAt = floor.powerOnAt
		if onAt and t >= onAt + T.PowerOnSeconds then
			floor.powerOnAt = nil
			ReplicatedStorage:SetAttribute(M.PowerOffLevel, nil)
			notifyLevel(floor.levelId, "Obj.PowerRestored")
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Whether `levelId`'s exit may be used (no objective there, no lock on it or its lock step done, or no run tracked).
function ObjectiveService.ExitOpen(levelId: string): boolean
	if not running then
		return true
	end
	local floor = floors[levelId]
	return floor == nil or floor.unlocked
end

-- The floor's step progress (a copy) and whether it is unlocked (specs, tools).
function ObjectiveService.GetFloor(levelId: string): ({ [string]: number }?, boolean)
	local floor = floors[levelId]
	if not floor then
		return nil, false
	end
	return table.clone(floor.progress), floor.unlocked
end

-- The models `player` carries, in carry order.
function ObjectiveService.GetCarried(player: Player): { Model }
	local out: { Model } = {}
	local carry = carries[player]
	local list: { Item } = if carry then carry.items else {}
	for _, item in list do
		table.insert(out, item.model)
	end
	return out
end

-- Where an item model stands in its life: World, Carried or Used (nil for a model that is no item this run).
function ObjectiveService.GetItemState(model: Model): ItemState?
	local item = itemsByModel[model]
	return if item then item.state else nil
end

-- The live exit lock of `levelId` this run (the route's), and the fire doors it holds.
function ObjectiveService.GetExit(levelId: string): (Model?, { Model })
	local floor = floors[levelId]
	if not floor then
		return nil, {}
	end
	return floor.lock, table.clone(floor.doors)
end

-- Completes `levelId`'s objective through its own unlock path (dev).
function ObjectiveService.Complete(levelId: string): boolean
	local floor = floors[levelId]
	if not floor or floor.unlocked then
		return false
	end
	for _, step in floor.spec.steps do
		floor.progress[step.id] = step.count
	end
	if floor.panel then
		floor.powered = true
		ReplicatedStorage:SetAttribute(M.PowerOffLevel, nil)
	end
	unlock(floor, nil)
	return true
end

-- Drops everything `player` carries where they are (specs; the life-state rules call it).
function ObjectiveService.Drop(player: Player)
	dropAll(player, nil)
end

function ObjectiveService.SetClock(fake: Clock?)
	clock = fake or realClock
end

--------------------------------------------------------------------------------
-- Dev command
--------------------------------------------------------------------------------

local function objectiveCommand(_player: Player, args: { string }): string?
	local level = LevelDirector.GetCurrentLevel()
	local floor = if level then floors[level] else nil
	if not (running and level and floor) then
		return "no floor objective here"
	end
	if string.lower(args[1] or "") == "done" then
		return if ObjectiveService.Complete(level) then level .. ": objective completed" else "already unlocked"
	end
	return string.format(
		"%s %s: %s%s",
		level,
		floor.spec.id,
		ObjectiveState.encodeSteps(floor.spec, floor.progress),
		if floor.unlocked then " (unlocked)" else ""
	)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function onLevelActivated(levelId: Enums.LevelId, _ctx: Types.LevelContext)
	local floor = floors[levelId]
	if not (running and floor) then
		clearReplication()
		return
	end
	floor.active = true
	refreshFloor(floor)
end

local function onLevelDeactivated(levelId: Enums.LevelId)
	local floor = floors[levelId]
	if floor then
		floor.active = false
		for _, work in floor.works do
			if work.since then
				cancelWork(work)
			end
		end
		-- a floor with nothing to do but cross it is done once the squad leaves it
		if floor.spec.item == nil and floor.spec.lockStep == nil then
			for _, step in floor.spec.steps do
				if not isDone(floor, step.id) then
					advance(floor, step.id, nil, step.count)
				end
			end
		end
		refreshHosts(floor)
	end
end

local function onLifeStateChanged(player: Player, state: Enums.LifeState, _previous: Enums.LifeState)
	if running and DROP_STATES[state] then
		dropAll(player, nil)
	end
end

local function onPhaseChanged(phase: Enums.MatchPhase)
	live = running and LIVE_PHASES[phase] == true
end

function ObjectiveService.Init()
	if initialized then
		return
	end
	initialized = true
	for _, kind in HANDLED do
		serviceTrove:Add(InteractionService.Register(ObjectiveService.Handlers[kind]))
	end
	serviceTrove:Add(LevelDirector.LevelActivated:Connect(onLevelActivated))
	serviceTrove:Add(LevelDirector.LevelDeactivated:Connect(onLevelDeactivated))
	serviceTrove:Add(LifeStateService.StateChanged:Connect(onLifeStateChanged))
	serviceTrove:Add(ReplicatedStorage:GetAttributeChangedSignal(M.MatchPhase):Connect(function()
		local phase = ReplicatedStorage:GetAttribute(M.MatchPhase)
		if type(phase) == "string" and Enums.has(Enums.MatchPhase, phase) then
			onPhaseChanged(phase :: Enums.MatchPhase)
		end
	end))
	DevToolsService.Register(
		"objective",
		"objective [done]: this floor's objective, or complete it (unlocks its exit)",
		objectiveCommand
	)
end

function ObjectiveService.Start()
	serviceTrove:Connect(RunService.Heartbeat, function()
		xpcall(ObjectiveService.Step, function(err: any)
			log.warnThrottled("step", 10, "objective step failed: %s\n%s", tostring(err), debug.traceback())
		end, nil)
	end)
end

function ObjectiveService.BeginRun(ctx: Types.RunContext)
	ObjectiveService.EndRun()
	run = ctx
	running = true
	live = true
	for _, player in ctx.participants do
		Attributes.set(player, P.Carrying, "")
	end
	for _, spec in ObjectiveConfig.Floors do
		local ok, result = pcall(newFloor, spec)
		if ok then
			floors[spec.levelId] = result
		else
			log.error("%s objective setup failed: %s", spec.levelId, tostring(result))
		end
	end
	for _, floor in floors do
		refreshHosts(floor)
	end
	local current: Enums.LevelId? = LevelDirector.GetCurrentLevel()
	local context = LevelDirector.GetContext()
	if current and floors[current] and context and LevelDirector.IsActive() then
		onLevelActivated(current :: Enums.LevelId, context)
	end
end

function ObjectiveService.EndRun()
	running = false
	live = false
	for _, floor in floors do
		for _, work in floor.works do
			stopVoice(work)
		end
	end
	for player in carries do
		if player.Parent ~= nil then
			Attributes.set(player, P.Carrying, "")
		end
	end
	table.clear(carries)
	table.clear(floors)
	table.clear(itemsByModel)
	table.clear(tweens)
	local folder = storage
	if folder then
		folder:ClearAllChildren()
	end
	clearReplication()
	run = nil
end

function ObjectiveService.OnPlayerRemoving(player: Player)
	if running then
		dropAll(player, nil)
	end
	carries[player] = nil
end

return ObjectiveService
