--!strict
-- InteractionService: server-timed ProximityPrompt interactions on Interactable hosts. The only writer of
-- ProximityPrompt.Enabled on those hosts, of the hosts' Channel* attributes and of the prompts' Audience attribute.
--
-- Hosts and handlers. Prop builders (Props/PropKit.prompt) create every prompt disabled, with PromptKind and BaseHold
-- attributes, under an instance tagged Interactable: the host (the prop model, a character, a terminal). Hosts are
-- tracked through CollectionService; a prompt belongs to its nearest Interactable ancestor. The system that owns an
-- interaction registers a Handler for its PromptKind (several may share a kind, told apart by `filter`); a prompt is
-- enabled while the first registered handler whose kind and filter match serves it, and stays disabled otherwise, so
-- no prop offers an action nobody serves. Filters are evaluated when a host is tracked (and once more a frame later,
-- after its builder finished dressing it), when prompts are added under it, on Register / unregister, and on
-- Refresh(host): owners call Refresh whenever state their filter reads changes (a grate swung open, a pack taken).
--
-- Who may use a prompt (eligible, shared by a hold's start and its completion):
--   * never a Dead or Spectating player (out of play),
--   * the player's character root within the prompt's MaxActivationDistance + RangeSlack (2) of the prompt,
--   * no wall in the way: the builders' prompts all have RequiresLineOfSight off (a prop's own parts must not hide its
--     prompt), so the world's solid geometry is tested here instead, from the player's eye and from their root
--     (characters, the Creature, lockers and the host left out, stopping ThroughSlack (1.5) short of it); a prompt is
--     refused ("Blocked") only when both lines are cut, so nothing is used through a wall,
--   * the audience: handler.audience(prompt, host) (default "All"); "Self" = only the host's OwnerUserId, "Others" =
--     everyone else. It is also written on the prompt (Audience) so clients hide prompts they cannot use; the owning
--     system writes the host's OwnerUserId (watched here),
--   * life state and canUse: without canUse only Alive players qualify; with canUse, canUse decides for every life
--     state but the two above (so it can widen: a lobby Terminal admits Lobby players). A canUse meant for Alive
--     players only checks it itself. A refusal reason that is a Strings key is sent to the player (Notify, at most
--     once every 1.5 s).
--
-- Timing. A player's hold time is handler.holdSeconds(player, prompt, host), else LoadoutService.HoldSeconds(player,
-- kind, BaseHold). The server prompt's HoldDuration stays BaseHold; each client sets its own local value.
--   PromptButtonHoldBegan  starts a channel when the player is eligible and nobody else channels the host (one actor
--                          per host; a second actor is ignored; one channel per player). The host gets ChannelActor
--                          (UserId), ChannelStartedAt (server time) and ChannelDuration; handler.onBegin runs.
--   Triggered              completes when acceptTrigger agrees: the player's own channel on that prompt has run at
--                          least duration - LatencyTolerance (0.15 s), and the player is still eligible. The channel is
--                          cleared, handler.onComplete runs, then Completed fires. Any refused trigger ends the
--                          player's channel ("Rejected"): their client considers the hold over.
--   Instant prompts        (hold 0) have no channel and complete on Triggered after the same eligibility checks.
--   PromptButtonHoldEnded  before the hold could have completed cancels ("Released"); after it, the channel waits
--                          ReleaseGrace (0.5 s) for the Triggered already in flight.
-- At ServerTickHz a channel is cancelled when its actor leaves range ("OutOfRange"), dies ("Died"), changes life
-- state ("LifeState"), or the hold overran its longest plausible length ("Timeout"). CharacterService's Died
-- ("Died") and CharacterRemoving ("Despawned"), leaving the server ("Left"), the host or prompt going away
-- ("Removed"), the prompt losing its handler ("Disabled" / "Unregistered"), a new hold by the same player
-- ("Restarted" / "Switched"), EndRun ("RunEnded") and CancelChannel(host, reason) cancel too. Every cancellation
-- clears the attributes and runs handler.onCancel(player, prompt, host, reason).
--
-- Abuse. Hold starts and triggers are each rate-limited per player (MaxEventsPerSecond, 6 per second, burst 6);
-- Net-level validation does not apply to engine prompt events, so this is their only gate.
--
-- Every handler callback runs protected: a throwing filter matches nothing, a throwing canUse refuses ("Error"), a
-- throwing holdSeconds falls back to the default, a throwing audience reads "All".

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local LoadoutService = require(ServerScriptService.Services.Player.LoadoutService)

local log = Log.new("Interaction")

local P = Attributes.Player
local W = Attributes.World

local LATENCY_TOLERANCE = 0.15
local RANGE_SLACK = 2
local THROUGH_SLACK = 1.5 -- a wall test stops this short of the prompt (the counter under it, the wall it sits in)
local EYE_LIFT = 1.5 -- the eye line starts this far above the root
local RELEASE_GRACE = 0.5
local OVERRUN_SLACK = 2 -- seconds past the longest plausible hold before a silent channel is abandoned
local MAX_HOLD_SECONDS = 60
local MAX_EVENTS_PER_SECOND = 6
local EVENT_BURST = 6
local FEEDBACK_COOLDOWN = 1.5
local DEFAULT_AUDIENCE: Enums.Audience = "All"

export type Handler = {
	kind: Enums.PromptKind,
	filter: ((host: Instance, prompt: ProximityPrompt) -> boolean)?, -- several handlers may share a kind (Pickup)
	canUse: ((player: Player, prompt: ProximityPrompt, host: Instance) -> (boolean, string?))?,
	holdSeconds: ((player: Player, prompt: ProximityPrompt, host: Instance) -> number)?, -- default: PerkConfig.holdSeconds
	audience: ((prompt: ProximityPrompt, host: Instance) -> Enums.Audience)?, -- default "All"
	onBegin: ((player: Player, prompt: ProximityPrompt, host: Instance) -> ())?,
	onComplete: (player: Player, prompt: ProximityPrompt, host: Instance) -> (),
	onCancel: ((player: Player, prompt: ProximityPrompt, host: Instance, reason: string) -> ())?,
}

-- Everything the acceptance rules look at for one player and one prompt, gathered by the service (specs build it
-- by hand).
export type Check = {
	userId: number,
	lifeState: Enums.LifeState,
	distance: number?, -- studs from the player's character root to the prompt; nil without a living character
	maxDistance: number, -- the prompt's MaxActivationDistance
	audience: Enums.Audience,
	ownerUserId: number?, -- the host's OwnerUserId
	canUse: (() -> (boolean, string?))?, -- the handler's canUse bound to this player, prompt and host
	blocked: boolean?, -- a wall stands between the player and the prompt
	now: number, -- server time
	duration: number, -- the player's hold seconds for this prompt (0 = instant)
	-- acceptBegin: the actor channelling the host (any of its prompts). acceptTrigger: the actor channelling this
	-- prompt, and when that channel started.
	channelUserId: number?,
	channelStartedAt: number?,
}

-- One channel's state at a tick (pure input of channelCheck).
export type ChannelState = {
	now: number,
	alive: boolean, -- the actor has a living character with a root
	lifeState: Enums.LifeState,
	beganLifeState: Enums.LifeState,
	distance: number?,
	maxDistance: number,
	releasedAt: number?, -- server time the button was released after the hold could have completed
	expiresAt: number, -- server time past which a channel without a Triggered is abandoned
}

-- A token bucket (rate limiting): `tokens` as of os.clock() `at`.
export type Bucket = { tokens: number, at: number }

-- A tracked prompt (its connections live in promptTroves).
type Entry = {
	prompt: ProximityPrompt,
	host: Instance,
	handler: Handler?,
}

-- A tracked host (its connections live in hostTroves).
type HostRecord = {
	host: Instance,
	prompts: { [ProximityPrompt]: Entry },
}

type Channel = {
	player: Player,
	prompt: ProximityPrompt,
	host: Instance,
	handler: Handler,
	startedAt: number,
	duration: number,
	expiresAt: number,
	lifeState: Enums.LifeState,
	releasedAt: number?,
}

type BucketKind = "Begin" | "Trigger"

local InteractionService = {}

InteractionService.Name = "InteractionService"
InteractionService.LatencyTolerance = LATENCY_TOLERANCE
InteractionService.RangeSlack = RANGE_SLACK
InteractionService.ReleaseGrace = RELEASE_GRACE
InteractionService.MaxEventsPerSecond = MAX_EVENTS_PER_SECOND

local completed: Signal.Signal<Player, Enums.PromptKind, Instance> = Signal.new()
local channelStarted: Signal.Signal<Player, Enums.PromptKind, Instance> = Signal.new()
local channelCancelled: Signal.Signal<Player, Enums.PromptKind, Instance, string> = Signal.new()

-- (player, kind, host) after a handler's onComplete returned.
InteractionService.Completed = completed
-- (player, kind, host) when a hold starts (after onBegin).
InteractionService.ChannelStarted = channelStarted
-- (player, kind, host, reason) when a hold ends without completing (after onCancel).
InteractionService.ChannelCancelled = channelCancelled

local serviceTrove = Trove.new()
local handlers: { Handler } = {} -- registration order: the first match serves a prompt
local hosts: { [Instance]: HostRecord } = {}
local entries: { [ProximityPrompt]: Entry } = {}
local hostTroves: { [Instance]: Trove.Trove } = {}
local promptTroves: { [ProximityPrompt]: Trove.Trove } = {}
local channels: { [Instance]: Channel } = {} -- by host
local playerChannels: { [Player]: Channel } = {}
local buckets: { [Player]: { [BucketKind]: Bucket } } = {}
local lastFeedback: { [Player]: number } = {}

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Interaction.spec.luau)
--------------------------------------------------------------------------------

-- Whether a prompt with `audience` on a host owned by `ownerUserId` is offered to `userId`.
function InteractionService.audienceIncludes(audience: Enums.Audience, ownerUserId: number?, userId: number): boolean
	if audience == "Self" then
		return ownerUserId ~= nil and ownerUserId == userId
	elseif audience == "Others" then
		return ownerUserId ~= userId
	end
	return true
end

-- Whether a player `distance` studs away (nil: no living character) can still reach a prompt.
function InteractionService.inRange(distance: number?, maxDistance: number): boolean
	return distance ~= nil and distance == distance and distance <= maxDistance + RANGE_SLACK
end

-- The eligibility rules shared by a hold's start and its completion (see the header). canUse runs last, only when
-- everything else passed.
function InteractionService.eligible(check: Check): (boolean, string?)
	if check.lifeState == "Dead" or check.lifeState == "Spectating" then
		return false, "LifeState"
	end
	if not InteractionService.inRange(check.distance, check.maxDistance) then
		return false, "OutOfRange"
	end
	if check.blocked then
		return false, "Blocked"
	end
	if not InteractionService.audienceIncludes(check.audience, check.ownerUserId, check.userId) then
		return false, "Audience"
	end
	local canUse = check.canUse
	if canUse == nil then
		if check.lifeState ~= "Alive" then
			return false, "LifeState"
		end
		return true, nil
	end
	local allowed, reason = canUse()
	if not allowed then
		return false, reason or "Refused"
	end
	return true, nil
end

-- Whether a hold start may open a channel: a timed prompt, nobody else channelling the host, and an eligible player.
function InteractionService.acceptBegin(check: Check): (boolean, string?)
	if check.duration <= 0 then
		return false, "Instant"
	end
	local actor = check.channelUserId
	if actor ~= nil and actor ~= check.userId then
		return false, "Busy"
	end
	return InteractionService.eligible(check)
end

-- Whether a Triggered completes the interaction. Timed prompts need the player's own channel on this prompt, open for
-- at least duration - LatencyTolerance; instant prompts need none. Then the eligibility rules apply.
function InteractionService.acceptTrigger(check: Check): (boolean, string?)
	if check.duration > 0 then
		local actor = check.channelUserId
		local startedAt = check.channelStartedAt
		if actor == nil or startedAt == nil then
			return false, "NoChannel"
		end
		if actor ~= check.userId then
			return false, "NotActor"
		end
		if check.now - startedAt < check.duration - LATENCY_TOLERANCE then
			return false, "TooEarly"
		end
	end
	return InteractionService.eligible(check)
end

-- What a released button means for a channel: "Cancel" when the hold could not have completed yet, else "Await" (the
-- Triggered is in flight; the channel waits ReleaseGrace for it).
function InteractionService.releaseVerdict(now: number, startedAt: number, duration: number): "Cancel" | "Await"
	if now - startedAt < duration - LATENCY_TOLERANCE then
		return "Cancel"
	end
	return "Await"
end

-- Server time past which a channel that never heard Triggered is abandoned: the longer of the player's hold and the
-- prompt's BaseHold (a client that missed the player's perk still completes on BaseHold), plus OverrunSlack.
function InteractionService.channelExpiry(startedAt: number, duration: number, baseHold: number): number
	return startedAt + math.max(duration, baseHold) + OVERRUN_SLACK
end

-- Why a running channel must be cancelled at this tick, or nil while it may go on.
function InteractionService.channelCheck(state: ChannelState): string?
	if not state.alive then
		return "Died"
	end
	if state.lifeState ~= state.beganLifeState then
		return "LifeState"
	end
	if not InteractionService.inRange(state.distance, state.maxDistance) then
		return "OutOfRange"
	end
	local releasedAt = state.releasedAt
	if releasedAt ~= nil and state.now - releasedAt > RELEASE_GRACE then
		return "Released"
	end
	if state.now > state.expiresAt then
		return "Timeout"
	end
	return nil
end

-- Takes one token from `bucket` (nil: a full one) at os.clock() `now`. Returns whether a token was available and the
-- updated bucket.
function InteractionService.takeToken(bucket: Bucket?, now: number, burst: number, perSecond: number): (boolean, Bucket)
	local tokens = burst
	if bucket then
		tokens = math.min(burst, bucket.tokens + math.max(0, now - bucket.at) * perSecond)
	end
	if tokens < 1 then
		return false, { tokens = tokens, at = now }
	end
	return true, { tokens = tokens - 1, at = now }
end

-- The prompt's PromptKind attribute, or nil when it carries none (or an unknown one).
function InteractionService.promptKind(prompt: ProximityPrompt): Enums.PromptKind?
	local kind = prompt:GetAttribute(W.PromptKind)
	if type(kind) == "string" and Enums.has(Enums.PromptKind, kind) then
		return kind :: Enums.PromptKind
	end
	return nil
end

-- Whether `handler` serves `prompt` on `host`: same PromptKind, and its filter (if any) agrees.
function InteractionService.matches(handler: Handler, host: Instance, prompt: ProximityPrompt): boolean
	if InteractionService.promptKind(prompt) ~= handler.kind then
		return false
	end
	local filter = handler.filter
	if filter == nil then
		return true
	end
	local ok, result = pcall(filter, host, prompt)
	if not ok then
		log.warnThrottled(
			"filter" .. handler.kind,
			10,
			"%s filter failed on %s: %s",
			handler.kind,
			host:GetFullName(),
			tostring(result)
		)
		return false
	end
	return result == true
end

-- The first handler in `list` that serves `prompt` on `host`, and how many matched (more than one is a registration
-- overlap: the first still wins).
function InteractionService.selectHandler(
	list: { Handler },
	host: Instance,
	prompt: ProximityPrompt
): (Handler?, number)
	local chosen: Handler? = nil
	local count = 0
	for _, handler in list do
		if InteractionService.matches(handler, host, prompt) then
			count += 1
			if chosen == nil then
				chosen = handler
			end
		end
	end
	return chosen, count
end

--------------------------------------------------------------------------------
-- Instance helpers
--------------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- The nearest Interactable instance at or above `instance`.
local function hostAbove(instance: Instance?): Instance?
	local node = instance
	while node do
		if node:HasTag(Tags.Interactable) then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- The prompt's world position (its parent Attachment, BasePart or Model), the point range checks measure from.
-- Composed from CFrames (an Attachment's CFrame is relative to its part), so it reads the same outside the engine.
function InteractionService.PromptPosition(prompt: ProximityPrompt): Vector3?
	local parent = prompt.Parent
	if parent == nil then
		return nil
	end
	if parent:IsA("Attachment") then
		local part = parent.Parent
		if part and part:IsA("BasePart") then
			return (part.CFrame * parent.CFrame).Position
		end
		return nil
	elseif parent:IsA("BasePart") then
		return parent.CFrame.Position
	elseif parent:IsA("Model") then
		return parent:GetPivot().Position
	end
	return nil
end

local promptPosition = InteractionService.PromptPosition

-- `player`'s character root while the character lives.
local function livingRoot(player: Player): BasePart?
	local root = Instances.characterRoot(player)
	local humanoid = Instances.characterHumanoid(player)
	if root and humanoid and humanoid.Health > 0 then
		return root
	end
	return nil
end

-- Studs from `player`'s living character root to `prompt`, or nil without one.
local function distanceTo(player: Player, prompt: ProximityPrompt): number?
	local root = livingRoot(player)
	local position = promptPosition(prompt)
	if not root or not position then
		return nil
	end
	return (root.CFrame.Position - position).Magnitude
end

local function lifeStateOf(player: Player): Enums.LifeState
	local value = player:GetAttribute(P.LifeState)
	if type(value) == "string" and Enums.has(Enums.LifeState, value) then
		return value :: Enums.LifeState
	end
	return "Lobby"
end

local function ownerOf(host: Instance): number?
	local value = host:GetAttribute(W.OwnerUserId)
	return if type(value) == "number" then value else nil
end

local function baseHoldOf(prompt: ProximityPrompt): number
	local value = Attributes.getNumber(prompt, W.BaseHold, prompt.HoldDuration)
	return if MathUtil.isFinite(value) then math.max(0, value) else 0
end

--------------------------------------------------------------------------------
-- Handler callbacks (protected)
--------------------------------------------------------------------------------

local function audienceOf(handler: Handler, prompt: ProximityPrompt, host: Instance): Enums.Audience
	local audience = handler.audience
	if audience == nil then
		return DEFAULT_AUDIENCE
	end
	local ok, result = pcall(audience, prompt, host)
	if ok and type(result) == "string" and Enums.has(Enums.Audience, result) then
		return result :: Enums.Audience
	end
	if not ok then
		log.warnThrottled("audience" .. handler.kind, 10, "%s audience failed: %s", handler.kind, tostring(result))
	end
	return DEFAULT_AUDIENCE
end

local function holdFor(handler: Handler, player: Player, prompt: ProximityPrompt, host: Instance): number
	local base = baseHoldOf(prompt)
	local fallback = LoadoutService.HoldSeconds(player, handler.kind, base)
	local custom = handler.holdSeconds
	local seconds = fallback
	if custom then
		local ok, result = pcall(custom, player, prompt, host)
		if ok and type(result) == "number" and MathUtil.isFinite(result) then
			seconds = result
		else
			log.warnThrottled("hold" .. handler.kind, 10, "%s holdSeconds failed: %s", handler.kind, tostring(result))
		end
	end
	return math.clamp(seconds, 0, MAX_HOLD_SECONDS)
end

local function boundCanUse(
	handler: Handler,
	player: Player,
	prompt: ProximityPrompt,
	host: Instance
): (() -> (boolean, string?))?
	local canUse = handler.canUse
	if canUse == nil then
		return nil
	end
	return function(): (boolean, string?)
		local ok, allowed, reason = pcall(canUse, player, prompt, host)
		if not ok then
			log.warnThrottled("canUse" .. handler.kind, 10, "%s canUse failed: %s", handler.kind, tostring(allowed))
			return false, "Error"
		end
		return allowed == true, if type(reason) == "string" then reason else nil
	end
end

local function callBack(label: string, handler: Handler, callback: () -> ())
	xpcall(callback, function(err: any)
		log.error("%s %s failed: %s\n%s", handler.kind, label, tostring(err), debug.traceback())
	end)
end

--------------------------------------------------------------------------------
-- Channels
--------------------------------------------------------------------------------

local function writeChannel(host: Instance, channel: Channel?)
	host:SetAttribute(W.ChannelActor, if channel then channel.player.UserId else nil)
	host:SetAttribute(W.ChannelStartedAt, if channel then channel.startedAt else nil)
	host:SetAttribute(W.ChannelDuration, if channel then channel.duration else nil)
end

-- Removes `channel` from the books and clears its host attributes (no callbacks).
local function closeChannel(channel: Channel)
	if channels[channel.host] == channel then
		channels[channel.host] = nil
		writeChannel(channel.host, nil)
	end
	if playerChannels[channel.player] == channel then
		playerChannels[channel.player] = nil
	end
end

local function cancelChannel(channel: Channel, reason: string)
	if channels[channel.host] ~= channel and playerChannels[channel.player] ~= channel then
		return -- already over
	end
	closeChannel(channel)
	local handler = channel.handler
	local onCancel = handler.onCancel
	if onCancel then
		callBack("onCancel", handler, function()
			onCancel(channel.player, channel.prompt, channel.host, reason)
		end)
	end
	channelCancelled:Fire(channel.player, handler.kind, channel.host, reason)
end

local function cancelPlayer(player: Player, reason: string)
	local channel = playerChannels[player]
	if channel then
		cancelChannel(channel, reason)
	end
end

local function openChannel(entry: Entry, handler: Handler, player: Player, duration: number, now: number)
	local channel: Channel = {
		player = player,
		prompt = entry.prompt,
		host = entry.host,
		handler = handler,
		startedAt = now,
		duration = duration,
		expiresAt = InteractionService.channelExpiry(now, duration, baseHoldOf(entry.prompt)),
		lifeState = lifeStateOf(player),
		releasedAt = nil,
	}
	channels[entry.host] = channel
	playerChannels[player] = channel
	writeChannel(entry.host, channel)
	local onBegin = handler.onBegin
	if onBegin then
		callBack("onBegin", handler, function()
			onBegin(player, entry.prompt, entry.host)
		end)
	end
	if channels[entry.host] == channel then
		channelStarted:Fire(player, handler.kind, entry.host)
	end
end

--------------------------------------------------------------------------------
-- Prompt events
--------------------------------------------------------------------------------

local function admit(player: Player, kind: BucketKind): boolean
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local ok, bucket = InteractionService.takeToken(perPlayer[kind], os.clock(), EVENT_BURST, MAX_EVENTS_PER_SECOND)
	perPlayer[kind] = bucket
	if not ok then
		log.warnThrottled(
			string.format("rate:%d:%s", player.UserId, kind),
			5,
			"%s (%d): prompt %s events over %d/s dropped",
			player.Name,
			player.UserId,
			kind,
			MAX_EVENTS_PER_SECOND
		)
	end
	return ok
end

-- Tells the player why a handler refused them, when the reason is a Strings key (throttled).
local function feedback(player: Player, reason: string?)
	if reason == nil or not Strings.has(reason) or player.Parent ~= Players then
		return
	end
	local now = os.clock()
	local last = lastFeedback[player]
	if last and now - last < FEEDBACK_COOLDOWN then
		return
	end
	lastFeedback[player] = now
	local payload: Types.NotifyPayload = { key = reason, args = {} }
	Net.Server.fire("Notify", player, payload)
end

-- Whether a wall stands between `player` and `prompt` (see the header): both the eye and the root lines cut.
local function blockedFrom(player: Player, prompt: ProximityPrompt, host: Instance): boolean
	local root = livingRoot(player)
	local position = promptPosition(prompt)
	if not root or not position then
		return false
	end
	local exclude: { Instance } = { host }
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(exclude, other.Character)
		end
	end
	local creature = Instances.creature()
	if creature then
		table.insert(exclude, creature)
	end
	-- lockers are furniture against the walls: a key hanging inside an open one is reached past its door
	for _, locker in CollectionService:GetTagged(Tags.HideableLocker) do
		table.insert(exclude, locker)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	local base = root.CFrame.Position
	for _, from in { base + Vector3.new(0, EYE_LIFT, 0), base } do
		local offset = position - from
		local length = offset.Magnitude
		if length <= THROUGH_SLACK then
			return false
		end
		if Workspace:Raycast(from, offset.Unit * (length - THROUGH_SLACK), params) == nil then
			return false
		end
	end
	return true
end

local function gather(
	entry: Entry,
	handler: Handler,
	player: Player,
	now: number,
	duration: number,
	channel: Channel?
): Check
	return {
		userId = player.UserId,
		lifeState = lifeStateOf(player),
		distance = distanceTo(player, entry.prompt),
		maxDistance = entry.prompt.MaxActivationDistance,
		audience = audienceOf(handler, entry.prompt, entry.host),
		ownerUserId = ownerOf(entry.host),
		canUse = boundCanUse(handler, player, entry.prompt, entry.host),
		blocked = blockedFrom(player, entry.prompt, entry.host),
		now = now,
		duration = duration,
		channelUserId = if channel then channel.player.UserId else nil,
		channelStartedAt = if channel then channel.startedAt else nil,
	}
end

local function servedEntry(prompt: ProximityPrompt): (Entry?, Handler?)
	local entry = entries[prompt]
	if not entry or entry.prompt.Parent == nil or entry.host.Parent == nil then
		return nil, nil
	end
	return entry, entry.handler
end

local function onHoldBegan(prompt: ProximityPrompt, player: Player)
	local entry, handler = servedEntry(prompt)
	if not entry or not handler or not admit(player, "Begin") then
		return
	end
	local now = serverNow()
	local duration = holdFor(handler, player, prompt, entry.host)
	local ok, reason =
		InteractionService.acceptBegin(gather(entry, handler, player, now, duration, channels[entry.host]))
	if not ok then
		if reason ~= "Instant" then
			log.debug("%s: %s hold on %s refused (%s)", player.Name, handler.kind, entry.host:GetFullName(), reason)
			feedback(player, reason)
		end
		return
	end
	-- One channel per player and per host: a fresh start replaces the player's previous channel (a re-press here, or a
	-- hold elsewhere that never ended).
	local previous = playerChannels[player]
	if previous then
		cancelChannel(previous, if previous.host == entry.host then "Restarted" else "Switched")
	end
	openChannel(entry, handler, player, duration, now)
end

local function onHoldEnded(prompt: ProximityPrompt, player: Player)
	local channel = playerChannels[player]
	if not channel or channel.prompt ~= prompt then
		return
	end
	local now = serverNow()
	if InteractionService.releaseVerdict(now, channel.startedAt, channel.duration) == "Cancel" then
		cancelChannel(channel, "Released")
	else
		channel.releasedAt = channel.releasedAt or now
	end
end

local function onTriggered(prompt: ProximityPrompt, player: Player)
	local own = playerChannels[player]
	local entry, handler = servedEntry(prompt)
	if not entry or not handler then
		return
	end
	if not admit(player, "Trigger") then
		if own then
			cancelChannel(own, "Rejected")
		end
		return
	end
	local channel = if own and own.prompt == prompt then own else nil
	local duration = if channel then channel.duration else holdFor(handler, player, prompt, entry.host)
	local now = serverNow()
	local ok, reason = InteractionService.acceptTrigger(gather(entry, handler, player, now, duration, channel))
	if not ok then
		log.debug("%s: %s on %s refused (%s)", player.Name, handler.kind, entry.host:GetFullName(), reason)
		if own then
			cancelChannel(own, "Rejected")
		end
		feedback(player, reason)
		return
	end
	if channel then
		closeChannel(channel)
	elseif own then
		-- Completing another prompt means the player let go of the one they were holding.
		cancelChannel(own, "Switched")
	end
	local host = entry.host
	local finished = false
	callBack("onComplete", handler, function()
		handler.onComplete(player, prompt, host)
		finished = true
	end)
	if finished then
		completed:Fire(player, handler.kind, host)
	end
end

--------------------------------------------------------------------------------
-- Tracking
--------------------------------------------------------------------------------

local function writeAudience(entry: Entry)
	local handler = entry.handler
	Attributes.set(entry.prompt, W.Audience, if handler then audienceOf(handler, entry.prompt, entry.host) else nil)
end

-- Re-resolves the handler serving `entry` and enables or disables its prompt to match.
local function refreshEntry(entry: Entry)
	local handler, count = InteractionService.selectHandler(handlers, entry.host, entry.prompt)
	if count > 1 then
		log.warnThrottled(
			"overlap" .. entry.prompt:GetFullName(),
			30,
			"%d %s handlers match %s; the first registered serves it",
			count,
			tostring(handler and handler.kind),
			entry.prompt:GetFullName()
		)
	end
	if handler ~= entry.handler then
		local channel = channels[entry.host]
		if channel and channel.prompt == entry.prompt then
			cancelChannel(channel, "Disabled")
		end
		entry.handler = handler
	end
	local enabled = handler ~= nil
	if entry.prompt.Enabled ~= enabled then
		entry.prompt.Enabled = enabled
	end
	writeAudience(entry)
end

-- A snapshot of `record`'s entries (callbacks run while iterating may add or drop prompts).
local function entriesOf(record: HostRecord): { Entry }
	local list: { Entry } = {}
	for _, entry in record.prompts do
		table.insert(list, entry)
	end
	return list
end

local function refreshRecord(record: HostRecord)
	for _, entry in entriesOf(record) do
		if record.prompts[entry.prompt] == entry then
			refreshEntry(entry)
		end
	end
end

local function adoptPrompt(record: HostRecord, prompt: ProximityPrompt)
	if entries[prompt] or hostAbove(prompt.Parent) ~= record.host then
		return -- already tracked, or it belongs to a nested host
	end
	local hostTrove = hostTroves[record.host]
	if not hostTrove then
		return
	end
	local trove = hostTrove:Extend()
	local entry: Entry = { prompt = prompt, host = record.host, handler = nil }
	entries[prompt] = entry
	record.prompts[prompt] = entry
	promptTroves[prompt] = trove
	trove:Connect(prompt.PromptButtonHoldBegan, function(player: Player)
		onHoldBegan(prompt, player)
	end)
	trove:Connect(prompt.PromptButtonHoldEnded, function(player: Player)
		onHoldEnded(prompt, player)
	end)
	trove:Connect(prompt.Triggered, function(player: Player)
		onTriggered(prompt, player)
	end)
	trove:Add(function()
		if entries[prompt] == entry then
			entries[prompt] = nil
		end
		if promptTroves[prompt] == trove then
			promptTroves[prompt] = nil
		end
		record.prompts[prompt] = nil
	end)
	refreshEntry(entry)
end

local function dropPrompt(record: HostRecord, prompt: ProximityPrompt)
	local entry = record.prompts[prompt]
	if not entry then
		return
	end
	local channel = channels[record.host]
	if channel and channel.prompt == prompt then
		cancelChannel(channel, "Removed")
	end
	local hostTrove = hostTroves[record.host]
	local trove = promptTroves[prompt]
	if hostTrove and trove then
		hostTrove:Remove(trove)
	end
end

local function track(host: Instance)
	if hosts[host] then
		return
	end
	local record: HostRecord = { host = host, prompts = {} }
	local trove = serviceTrove:Extend()
	hosts[host] = record
	hostTroves[host] = trove
	for _, descendant in host:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			adoptPrompt(record, descendant)
		end
	end
	trove:Connect(host.DescendantAdded, function(descendant: Instance)
		if descendant:IsA("ProximityPrompt") then
			adoptPrompt(record, descendant)
		end
	end)
	trove:Connect(host.DescendantRemoving, function(descendant: Instance)
		if descendant:IsA("ProximityPrompt") then
			dropPrompt(record, descendant)
		end
	end)
	trove:Connect(host:GetAttributeChangedSignal(W.OwnerUserId), function()
		for _, entry in entriesOf(record) do
			writeAudience(entry)
		end
	end)
	-- Builders tag a host before they finish dressing it (tags and attributes a filter reads may follow in the same
	-- frame): look again once they are done.
	trove:Add(task.defer(function()
		if hosts[host] == record then
			refreshRecord(record)
		end
	end))
end

local function untrack(host: Instance)
	local record = hosts[host]
	if not record then
		return
	end
	hosts[host] = nil
	local channel = channels[host]
	if channel then
		cancelChannel(channel, "Removed")
	end
	local trove = hostTroves[host]
	hostTroves[host] = nil
	if trove then
		serviceTrove:Remove(trove)
	end
end

local function refreshKind(kind: Enums.PromptKind)
	local records: { HostRecord } = {}
	for _, record in hosts do
		table.insert(records, record)
	end
	for _, record in records do
		for _, entry in entriesOf(record) do
			if InteractionService.promptKind(entry.prompt) == kind and record.prompts[entry.prompt] == entry then
				refreshEntry(entry)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Serves every prompt of handler.kind its filter accepts (enabling them). Returns the unregister function, which
-- disables the prompts it served (cancelling their channels, "Unregistered") and may be called more than once.
function InteractionService.Register(handler: Handler): () -> ()
	assert(Enums.has(Enums.PromptKind, handler.kind), "InteractionService.Register: unknown PromptKind")
	assert(type(handler.onComplete) == "function", "InteractionService.Register: onComplete is required")
	table.insert(handlers, handler)
	refreshKind(handler.kind)
	local registered = true
	return function()
		if not registered then
			return
		end
		registered = false
		local index = table.find(handlers, handler)
		if index then
			table.remove(handlers, index)
		end
		for host, channel in table.clone(channels) do
			if channel.handler == handler and channels[host] == channel then
				cancelChannel(channel, "Unregistered")
			end
		end
		refreshKind(handler.kind)
	end
end

-- Cancels the channel on `host` (if any) with `reason`.
function InteractionService.CancelChannel(host: Instance, reason: string)
	local channel = channels[host]
	if channel then
		cancelChannel(channel, reason)
	end
end

-- The channel on `host`: actor, startedAt (server time), duration; (nil, 0, 0) when nobody is channelling it.
function InteractionService.GetChannel(host: Instance): (Player?, number, number)
	local channel = channels[host]
	if not channel then
		return nil, 0, 0
	end
	return channel.player, channel.startedAt, channel.duration
end

-- The host and prompt `player` is channelling, if any.
function InteractionService.GetPlayerChannel(player: Player): (Instance?, ProximityPrompt?)
	local channel = playerChannels[player]
	if not channel then
		return nil, nil
	end
	return channel.host, channel.prompt
end

-- Re-evaluates every prompt on `host` against the registered handlers (call after changing state a filter reads).
-- Starts tracking `host` when it is Interactable but not tracked yet.
function InteractionService.Refresh(host: Instance)
	local record = hosts[host]
	if record then
		refreshRecord(record)
	elseif host:HasTag(Tags.Interactable) then
		track(host)
	end
end

-- The handler that serves `prompt` and its host, resolved against the current registrations (tracked or not).
function InteractionService.Resolve(prompt: ProximityPrompt): (Handler?, Instance?)
	local host = hostAbove(prompt.Parent)
	if not host then
		return nil, nil
	end
	local handler = InteractionService.selectHandler(handlers, host, prompt)
	return handler, host
end

--------------------------------------------------------------------------------
-- Ticks + dev
--------------------------------------------------------------------------------

local function tick()
	local now = serverNow()
	for _, channel in table.clone(channels) do
		if channels[channel.host] ~= channel then
			continue
		end
		local player = channel.player
		if player.Parent ~= Players then
			cancelChannel(channel, "Left")
			continue
		end
		if channel.host.Parent == nil or not channel.prompt:IsDescendantOf(channel.host) then
			cancelChannel(channel, "Removed")
			continue
		end
		local reason = InteractionService.channelCheck({
			now = now,
			alive = livingRoot(player) ~= nil,
			lifeState = lifeStateOf(player),
			beganLifeState = channel.lifeState,
			distance = distanceTo(player, channel.prompt),
			maxDistance = channel.prompt.MaxActivationDistance,
			releasedAt = channel.releasedAt,
			expiresAt = channel.expiresAt,
		})
		if reason then
			cancelChannel(channel, reason)
		end
	end
end

local function promptsCommand(): string?
	local hostCount, promptCount, enabledCount, channelCount = 0, 0, 0, 0
	local byKind: { [string]: { served: number, total: number } } = {}
	for _, record in hosts do
		hostCount += 1
		for _, entry in record.prompts do
			promptCount += 1
			local kind = InteractionService.promptKind(entry.prompt) or "?"
			local counts = byKind[kind] or { served = 0, total = 0 }
			byKind[kind] = counts
			counts.total += 1
			if entry.handler then
				enabledCount += 1
				counts.served += 1
			end
		end
	end
	for _ in channels do
		channelCount += 1
	end
	local kinds: { string } = {}
	for kind, counts in byKind do
		table.insert(kinds, string.format("%s %d/%d", kind, counts.served, counts.total))
	end
	table.sort(kinds)
	return string.format(
		"%d hosts, %d prompts (%d served), %d channels, %d handlers | %s",
		hostCount,
		promptCount,
		enabledCount,
		channelCount,
		#handlers,
		if #kinds > 0 then table.concat(kinds, ", ") else "no prompts"
	)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function InteractionService.Init()
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.Interactable), track)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.Interactable), untrack)
	for _, host in CollectionService:GetTagged(Tags.Interactable) do
		track(host)
	end
	serviceTrove:Add(CharacterService.Died:Connect(function(player: Player)
		cancelPlayer(player, "Died")
	end))
	serviceTrove:Add(CharacterService.CharacterRemoving:Connect(function(player: Player)
		cancelPlayer(player, "Despawned")
	end))
	DevToolsService.Register(
		"prompts",
		"prompts: interactable hosts, prompts served per kind, channels in progress",
		promptsCommand,
		true
	)
end

function InteractionService.Start()
	local interval = 1 / GameConfig.ServerTickHz
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		accumulated += dt
		if accumulated < interval then
			return
		end
		accumulated = 0
		if next(channels) == nil then
			return
		end
		xpcall(tick, function(err: any)
			log.warnThrottled("tick", 10, "channel tick failed: %s", tostring(err))
		end)
	end)
end

function InteractionService.EndRun()
	for _, channel in table.clone(channels) do
		cancelChannel(channel, "RunEnded")
	end
	table.clear(buckets)
end

function InteractionService.OnPlayerRemoving(player: Player)
	cancelPlayer(player, "Left")
	buckets[player] = nil
	lastFeedback[player] = nil
end

return InteractionService
