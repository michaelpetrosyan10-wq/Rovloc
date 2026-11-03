--!strict
-- AudioService: the server's only way to make a sound. It never creates Sounds; it sends an AudioCue
-- (Types.AudioCuePayload) and every client synthesizes the preset itself (AudioController -> SoundSynthesizer).
--
--   PlayAt(preset, position, options?)   3D at a fixed point, for everyone (or everyone but options.except)
--   PlayOn(preset, attach, options?)     3D following a BasePart / Attachment / Model; the cue also carries the
--                                        target's current position, so a client that cannot see the instance
--                                        still hears it in the right place
--   PlayFor(player, preset, options?)    one player only: 2D by default (heartbeat, jumpscare sting), or 3D when
--                                        options.position / options.attach are given
--   PlayForList(players, preset, ...)    the same cue (seed, start time) for a group of players
--
-- Every call returns a CueHandle { id, preset, looped, Stop(fade?), IsActive() } (nil when the cue was dropped).
-- Every cue carries a unique id; handle:Stop(fade) (or AudioService.Stop(id, fade)) sends AudioStop { id, fade } to
-- the same audience, and their clients fade that voice out (AudioController). A one-shot can be cut the same way.
--
-- Looped presets (SynthPresets.isLooped) run until something ends them, and the server keeps track of each one:
--   * options.duration (seconds): the loop fades out on its own (a server-timed unscrew channel)
--   * the handle: handle:Stop() ends it (a vent chase loop stopped when the Creature leaves the ducts)
--   * an attach target leaving the world ends it on every client
--   * a loop started during a run ends with the run (EndRun / MatchPhase leaving the run)
-- Active loops are re-sent, with their original startAt, to players who join while they play (once the joining
-- client has acknowledged the world), so a late joiner hears the same loop in sync, fast-forwarded.
--
-- Every cue is stamped startAt = GetServerTimeNow() + GameConfig.OneShotLead + (options.delay or 0), so all clients
-- start it on the same frame; late clients fast-forward or drop it (AudioController). The seed travels with the
-- cue, so every client hears the same jitter. Unknown presets and non-finite input are logged and dropped.
--
-- Lifecycle wiring is self-contained (Init connects PlayerAdded / PlayerRemoving and watches MatchPhase), so the
-- service works with only Init listed in ServerMain; EndRun / OnPlayerRemoving are also exposed as Types.Service
-- hooks and are idempotent if a caller wires them too.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local log = Log.new("Audio")

export type CueOptions = {
	volume: number?, -- voice volume multiplier (0..4)
	seed: number?, -- jitter seed (default: a fresh one per cue)
	except: Player?, -- PlayAt / PlayOn: everyone but this player (e.g. the player who made the noise)
	delay: number?, -- extra seconds before the cue starts
	duration: number?, -- looped presets: seconds until the loop fades out (omit to end it with the handle)
	position: Vector3?, -- PlayFor only: play in 3D at this point
	attach: Instance?, -- PlayFor only: play in 3D following this instance
}

export type CueHandle = {
	id: number,
	preset: string,
	looped: boolean,
	Stop: (self: CueHandle, fade: number?) -> (), -- ends the cue on every client that has it (idempotent)
	IsActive: (self: CueHandle) -> boolean, -- false once stopped, timed out, or (looped) ended with its target/run
}

-- Who a cue was sent to: everyone (optionally but one player), or an explicit list.
export type Audience = { players: { Player }?, except: Player? }

-- A looped cue the server is keeping alive (for stops and late joiners).
export type ActiveLoop = {
	cue: Types.AudioCuePayload,
	audience: Audience,
	expiresAt: number?, -- server time the timed loop has fully faded (nil = until stopped)
	runScoped: boolean, -- started during a run: ends with it
}

local CUE_REMOTE = "AudioCue"
local STOP_REMOTE = "AudioStop"
local MAX_DELAY = 30
local MIN_DURATION = 0.05
local MAX_DURATION = 600
local MAX_VOLUME = 4
local MAX_SEED = 2_147_483_646
local MAX_FADE = 10
local DEFAULT_STOP_FADE = 0.4
-- Clients fade a timed loop out over this long after its duration (AudioController.LOOP_CUE_FADE); the server
-- keeps re-sending it to joiners until that is over.
local LOOP_TAIL = 0.5
local MAX_ACTIVE_LOOPS = 128
local RUN_PHASES: { Enums.MatchPhase } = { "Countdown", "Deploying", "InRun", "RunEnded", "Results" }
local END_PHASES: { Enums.MatchPhase } = { "Resetting", "Lobby", "Booting" }

local AudioService = {}

AudioService.Name = "AudioService"

local seedSource = Random.new()
local nextCueId = 0
local active: { [number]: ActiveLoop } = {}
local activeCount = 0
local serviceTrove = Trove.new()
local initialized = false

--------------------------------------------------------------------------------
-- Pure helpers (exported for specs)
--------------------------------------------------------------------------------

-- True when a cue sent to `audience` reaches `player`.
function AudioService.audienceIncludes(audience: Audience, player: Player): boolean
	local list = audience.players
	if list then
		return table.find(list, player) ~= nil
	end
	return audience.except ~= player
end

-- Server time a looped cue has fully ended on clients (nil when only a Stop ends it).
function AudioService.loopExpiry(cue: Types.AudioCuePayload): number?
	local duration = cue.duration
	if duration == nil then
		return nil
	end
	return cue.startAt + duration + LOOP_TAIL
end

-- True while an active loop should still be playing on clients at server time `now`. `inWorld` tells whether an
-- instance is still part of the world (injected, so the rule is testable without a DataModel).
function AudioService.loopIsLive(entry: ActiveLoop, now: number, inWorld: (Instance) -> boolean): boolean
	local expiresAt = entry.expiresAt
	if expiresAt and now >= expiresAt then
		return false
	end
	local attach = entry.cue.attach
	if attach and not inWorld(attach) then
		return false
	end
	return true
end

--------------------------------------------------------------------------------
-- Internals
--------------------------------------------------------------------------------

local function worldPosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Attachment") then
		return instance.WorldPosition
	end
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

local function finite(value: number?): boolean
	return value == nil or MathUtil.isFinite(value)
end

local function inWorld(instance: Instance): boolean
	return instance:IsDescendantOf(Workspace)
end

local function runActive(): boolean
	local phase = Attributes.getString(ReplicatedStorage, Attributes.Match.MatchPhase, "Booting")
	return table.find(RUN_PHASES, phase :: any) ~= nil
end

-- Builds a validated cue, or nil (with a throttled warning) when the request is unusable.
local function buildCue(
	preset: string,
	options: CueOptions?,
	position: Vector3?,
	attach: Instance?
): Types.AudioCuePayload?
	if type(preset) ~= "string" or not SynthPresets.has(preset) then
		log.warnThrottled("preset" .. tostring(preset), 30, "unknown preset %s; cue dropped", tostring(preset))
		return nil
	end
	local opts: CueOptions = options or {}
	if position and not MathUtil.isFiniteVector(position) then
		log.warnThrottled("position" .. preset, 10, "non-finite position for %s; cue dropped", preset)
		return nil
	end
	if not (finite(opts.delay) and finite(opts.volume) and finite(opts.seed) and finite(opts.duration)) then
		log.warnThrottled("options" .. preset, 10, "non-finite options for %s; cue dropped", preset)
		return nil
	end
	local duration = if opts.duration then math.clamp(opts.duration, MIN_DURATION, MAX_DURATION) else nil
	local delay = math.clamp(opts.delay or 0, 0, MAX_DELAY)
	local volume = if opts.volume then math.clamp(opts.volume, 0, MAX_VOLUME) else nil
	local seed = if opts.seed
		then math.floor(math.abs(opts.seed)) % MAX_SEED + 1
		else seedSource:NextInteger(1, MAX_SEED)
	nextCueId += 1
	return {
		id = nextCueId,
		preset = preset,
		position = position,
		attach = attach,
		startAt = Workspace:GetServerTimeNow() + GameConfig.OneShotLead + delay,
		seed = seed,
		volume = volume,
		duration = duration,
	}
end

local function send(remote: string, audience: Audience, payload: any)
	local list = audience.players
	if list then
		Net.Server.fireList(remote, list, payload)
		return
	end
	local except = audience.except
	if except then
		Net.Server.fireExcept(remote, except, payload)
	else
		Net.Server.fireAll(remote, payload)
	end
end

local function forget(id: number): ActiveLoop?
	local entry = active[id]
	if entry then
		active[id] = nil
		activeCount -= 1
	end
	return entry
end

local function sendStop(id: number, audience: Audience, fade: number?)
	local payload: Types.AudioStopPayload = {
		id = id,
		fade = if fade ~= nil and MathUtil.isFinite(fade) then math.clamp(fade, 0, MAX_FADE) else nil,
	}
	send(STOP_REMOTE, audience, payload)
end

-- Drops loops that have ended on their own (timed out, or their attach target left the world).
local function prune(now: number)
	for id, entry in table.clone(active) do
		if not AudioService.loopIsLive(entry, now, inWorld) then
			forget(id)
		end
	end
end

local function register(cue: Types.AudioCuePayload, audience: Audience)
	local now = Workspace:GetServerTimeNow()
	if activeCount >= MAX_ACTIVE_LOOPS then
		prune(now)
	end
	if activeCount >= MAX_ACTIVE_LOOPS then
		-- Still full: a leak upstream (loops nobody stops). The oldest loop is stopped to make room.
		local oldestId: number? = nil
		for id in active do
			if oldestId == nil or id < oldestId then
				oldestId = id
			end
		end
		if oldestId then
			local evicted = forget(oldestId)
			if evicted then
				log.warnThrottled(
					"loops",
					30,
					"%d looped cues active; stopping the oldest (%s)",
					activeCount,
					evicted.cue.preset
				)
				sendStop(oldestId, evicted.audience, DEFAULT_STOP_FADE)
			end
		end
	end
	active[cue.id] = {
		cue = cue,
		audience = audience,
		expiresAt = AudioService.loopExpiry(cue),
		runScoped = runActive(),
	}
	activeCount += 1
end

local function makeHandle(cue: Types.AudioCuePayload, audience: Audience, looped: boolean): CueHandle
	local stopped = false
	local expiresAt = if looped then AudioService.loopExpiry(cue) else nil
	local handle: CueHandle = {
		id = cue.id,
		preset = cue.preset,
		looped = looped,
		Stop = function(_self: CueHandle, fade: number?)
			if stopped then
				return
			end
			stopped = true
			forget(cue.id)
			sendStop(cue.id, audience, fade)
		end,
		IsActive = function(_self: CueHandle): boolean
			if stopped then
				return false
			end
			if looped then
				return active[cue.id] ~= nil
					and AudioService.loopIsLive(active[cue.id], Workspace:GetServerTimeNow(), inWorld)
			end
			return expiresAt == nil and Workspace:GetServerTimeNow() < cue.startAt + GameConfig.OneShotMaxLate
		end,
	}
	return handle
end

-- Sends a validated cue to its audience and returns its handle (looped cues are tracked).
local function dispatch(cue: Types.AudioCuePayload, audience: Audience): CueHandle
	local looped = SynthPresets.isLooped(cue.preset)
	if looped then
		register(cue, audience)
	end
	send(CUE_REMOTE, audience, cue)
	return makeHandle(cue, audience, looped)
end

-- Re-sends every live loop this player should hear (original startAt: the client fast-forwards into it).
local function resendTo(player: Player)
	if player.Parent ~= Players then
		return
	end
	prune(Workspace:GetServerTimeNow())
	for _, entry in active do
		if AudioService.audienceIncludes(entry.audience, player) then
			Net.Server.fire(CUE_REMOTE, player, entry.cue)
		end
	end
end

local function watchPlayer(player: Player)
	local acked = Attributes.Player.WorldAcked
	if player:GetAttribute(acked) == true then
		resendTo(player)
		return
	end
	local connection: RBXScriptConnection? = nil
	connection = player:GetAttributeChangedSignal(acked):Connect(function()
		if player:GetAttribute(acked) == true then
			local current = connection
			if current then
				current:Disconnect()
			end
			resendTo(player)
		end
	end)
	if connection then
		serviceTrove:Add(connection)
	end
end

local function stopRunLoops()
	for id, entry in table.clone(active) do
		if entry.runScoped then
			forget(id)
			sendStop(id, entry.audience, DEFAULT_STOP_FADE)
		end
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function AudioService.Init()
	-- Catch broken recipe data early in Studio (pure check, never yields).
	if RunService:IsStudio() then
		for _, problem in SynthPresets.validate() do
			log.warn("preset data: %s", problem)
		end
	end
	if initialized then
		return
	end
	initialized = true
	serviceTrove:Connect(Players.PlayerAdded, watchPlayer)
	serviceTrove:Connect(Players.PlayerRemoving, AudioService.OnPlayerRemoving)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	serviceTrove:Connect(ReplicatedStorage:GetAttributeChangedSignal(Attributes.Match.MatchPhase), function()
		local phase = Attributes.getString(ReplicatedStorage, Attributes.Match.MatchPhase, "")
		if table.find(END_PHASES, phase :: any) ~= nil then
			stopRunLoops()
		end
	end)
end

-- Ends every loop that was started during the run (idempotent; also triggered by MatchPhase leaving the run).
function AudioService.EndRun()
	stopRunLoops()
end

-- Forgets the player in list audiences; loops that only they could hear are dropped.
function AudioService.OnPlayerRemoving(player: Player)
	for id, entry in table.clone(active) do
		local list = entry.audience.players
		if list then
			local index = table.find(list, player)
			if index then
				table.remove(list, index)
			end
			if #list == 0 then
				forget(id)
			end
		elseif entry.audience.except == player then
			entry.audience.except = nil
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- 3D cue at a fixed world position for every client (except options.except).
function AudioService.PlayAt(preset: string, position: Vector3, options: CueOptions?): CueHandle?
	if typeof(position) ~= "Vector3" then
		log.warnThrottled("at" .. tostring(preset), 10, "PlayAt(%s) needs a Vector3 position", tostring(preset))
		return nil
	end
	local cue = buildCue(preset, options, position, nil)
	if not cue then
		return nil
	end
	return dispatch(cue, { except = if options then options.except else nil })
end

-- 3D cue following `attach` (BasePart, Attachment or Model) for every client (except options.except).
function AudioService.PlayOn(preset: string, attach: Instance, options: CueOptions?): CueHandle?
	if typeof(attach) ~= "Instance" then
		log.warnThrottled("on" .. tostring(preset), 10, "PlayOn(%s) needs an Instance", tostring(preset))
		return nil
	end
	local position = worldPosition(attach)
	if position == nil then
		log.warnThrottled(
			"onType" .. preset,
			10,
			"PlayOn(%s): %s is not a BasePart, Attachment or Model",
			preset,
			attach.ClassName
		)
		return nil
	end
	local cue = buildCue(preset, options, position, attach)
	if not cue then
		return nil
	end
	return dispatch(cue, { except = if options then options.except else nil })
end

-- Cue for one player: 2D, or 3D when options.position / options.attach are given.
function AudioService.PlayFor(player: Player, preset: string, options: CueOptions?): CueHandle?
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return nil
	end
	local attach = if options then options.attach else nil
	local position = if options then options.position else nil
	if attach then
		if typeof(attach) ~= "Instance" then
			attach = nil
		else
			position = position or worldPosition(attach)
		end
	end
	local cue = buildCue(preset, options, position, attach)
	if not cue then
		return nil
	end
	return dispatch(cue, { players = { player } })
end

-- PlayFor every player in `players` with one shared cue (same id, seed and start time for all of them).
function AudioService.PlayForList(players: { Player }, preset: string, options: CueOptions?): CueHandle?
	local attach = if options then options.attach else nil
	local position = if options then options.position else nil
	if attach and typeof(attach) == "Instance" then
		position = position or worldPosition(attach)
	end
	local cue = buildCue(preset, options, position, attach)
	if not cue then
		return nil
	end
	return dispatch(cue, { players = table.clone(players) })
end

-- Stops a cue by id (as handle:Stop does). A looped cue the server is tracking goes to its audience; an unknown or
-- one-shot id is sent to everyone (clients ignore ids they do not have).
function AudioService.Stop(id: number, fade: number?)
	if type(id) ~= "number" or not MathUtil.isFinite(id) then
		return
	end
	local entry = forget(id)
	sendStop(id, if entry then entry.audience else {}, fade)
end

-- Stops every looped cue the server is tracking.
function AudioService.StopAll(fade: number?)
	for id, entry in table.clone(active) do
		forget(id)
		sendStop(id, entry.audience, fade)
	end
end

-- Looped cues still alive (diagnostics, dev overlays and specs).
function AudioService.ActiveLoopCount(): number
	prune(Workspace:GetServerTimeNow())
	return activeCount
end

return table.freeze(AudioService)
