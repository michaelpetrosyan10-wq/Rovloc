--!strict
-- Network transport. The server creates every remote listed in RemoteRegistry under ReplicatedStorage.Remotes.
-- Every client-to-server message goes through the same gate before a handler sees it:
--   rate limit (token bucket per player per remote) -> match-phase gate -> life-state gate -> payload validator.
-- Rejected messages are dropped and scored. Handlers run in protected calls, so a throwing handler never breaks the
-- remote for other players.
--
-- Abuse. Each player has one violation score that decays at Net.Server.ViolationDecayPerSecond. A rate-limited or
-- malformed message adds its weight (ViolationWeights); phase and life-state rejections weigh nothing, because honest
-- clients race match transitions and every such message already passed the rate limit. A score above
-- Net.Server.KickThreshold kicks the player with Strings "Net.Kicked" and fires Net.Server.Abuse first. An honest
-- client never gets near it (the buckets' bursts absorb jitter and stalls); a flood far above a remote's rate is
-- kicked within seconds. Rejection logs are throttled per player, remote and reason.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local RemoteRegistry = require(ReplicatedStorage.Shared.Net.RemoteRegistry)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Strings = require(ReplicatedStorage.Shared.Strings)

local log = Log.new("Net")

export type ServerHandler = (player: Player, payload: any) -> ()
export type ServerInvokeHandler = (player: Player, payload: any) -> any
export type ClientHandler = (payload: any) -> ()

type Bucket = { tokens: number, updatedAt: number }

-- Why a message was dropped.
export type RejectReason = "rate" | "phase" | "lifeState" | "payload"

-- A player's decaying violation score (`score` as of os.clock() `at`).
type Strikes = { score: number, at: number }

local VIOLATION_DECAY_PER_SECOND = 5
local KICK_THRESHOLD = 100
local VIOLATION_WEIGHTS: { [RejectReason]: number } = {
	rate = 1,
	payload = 1,
	phase = 0,
	lifeState = 0,
}

local Net = {}

local remotes: { [string]: Instance } = {}
local serverHandlers: { [string]: ServerHandler } = {}
local serverInvokeHandlers: { [string]: ServerInvokeHandler } = {}
local buckets: { [Player]: { [string]: Bucket } } = {}
local violations: { [Player]: Strikes } = {}
local kicked: { [Player]: boolean } = {}
local abuse: Signal.Signal<Player, number> = Signal.new()
local serverReady = false
local clientReady = false

local function spec(name: string): RemoteRegistry.RemoteSpec
	local found = RemoteRegistry.get(name)
	assert(found, "unknown remote " .. name)
	return found
end

local function className(kind: string): string
	if kind == "Unreliable" then
		return "UnreliableRemoteEvent"
	elseif kind == "Function" then
		return "RemoteFunction"
	end
	return "RemoteEvent"
end

local function takeToken(player: Player, remoteSpec: RemoteRegistry.RemoteSpec): boolean
	local rate = remoteSpec.rate
	if not rate then
		return true
	end
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local now = os.clock()
	local bucket = perPlayer[remoteSpec.name]
	if not bucket then
		bucket = { tokens = rate.burst, updatedAt = now }
		perPlayer[remoteSpec.name] = bucket
	end
	bucket.tokens = math.min(rate.burst, bucket.tokens + (now - bucket.updatedAt) * rate.perSecond)
	bucket.updatedAt = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- `score` (as of `elapsed` seconds ago) after decaying and adding `weight` (pure; specs drive it with fake time).
local function violationScore(score: number, elapsed: number, weight: number): number
	return math.max(0, score - VIOLATION_DECAY_PER_SECOND * math.max(0, elapsed)) + weight
end

local function kick(player: Player, score: number)
	if kicked[player] then
		return
	end
	kicked[player] = true
	log.warn("kicking %s (%d): violation score %.0f over %d", player.Name, player.UserId, score, KICK_THRESHOLD)
	abuse:Fire(player, score)
	local ok, err = pcall(function()
		player:Kick(Strings.get("Net.Kicked"))
	end)
	if not ok then
		log.warn("could not kick %s: %s", player.Name, tostring(err))
	end
end

local function reject(player: Player, remoteName: string, reason: RejectReason)
	log.warnThrottled(
		string.format("%d:%s:%s", player.UserId, remoteName, reason),
		5,
		"dropped %s from %s (%d) (%s)",
		remoteName,
		player.Name,
		player.UserId,
		reason
	)
	local weight = VIOLATION_WEIGHTS[reason]
	if weight <= 0 then
		return
	end
	local now = os.clock()
	local strikes = violations[player]
	local score = if strikes then violationScore(strikes.score, now - strikes.at, weight) else weight
	violations[player] = { score = score, at = now }
	if score > KICK_THRESHOLD then
		kick(player, score)
	end
end

local function admit(player: Player, remoteSpec: RemoteRegistry.RemoteSpec, payload: unknown): boolean
	if not takeToken(player, remoteSpec) then
		reject(player, remoteSpec.name, "rate")
		return false
	end
	local phases = remoteSpec.phases
	if phases then
		local phase = ReplicatedStorage:GetAttribute(Attributes.Match.MatchPhase)
		if type(phase) ~= "string" or table.find(phases, phase :: any) == nil then
			reject(player, remoteSpec.name, "phase")
			return false
		end
	end
	local lifeStates = remoteSpec.lifeStates
	if lifeStates then
		local lifeState = player:GetAttribute(Attributes.Player.LifeState)
		if type(lifeState) ~= "string" or table.find(lifeStates, lifeState :: any) == nil then
			reject(player, remoteSpec.name, "lifeState")
			return false
		end
	end
	local validate = remoteSpec.validate
	if validate and not validate(payload) then
		reject(player, remoteSpec.name, "payload")
		return false
	end
	return true
end

--------------------------------------------------------------------------------
-- Server
--------------------------------------------------------------------------------

Net.Server = {}

-- Creates ReplicatedStorage.Remotes and every remote. ServerMain calls this before any service Init.
function Net.Server.setup()
	assert(RunService:IsServer(), "Net.Server.setup is server-only")
	if serverReady then
		return
	end
	serverReady = true

	local existing = Instances.findRemotesFolder()
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = Instances.Names.Remotes

	for _, remoteSpec in RemoteRegistry.List do
		local remote = Instance.new(className(remoteSpec.kind))
		remote.Name = remoteSpec.name
		remote.Parent = folder
		remotes[remoteSpec.name] = remote

		if remoteSpec.direction ~= "ToServer" then
			continue
		end
		if remote:IsA("RemoteFunction") then
			remote.OnServerInvoke = function(player: Player, payload: unknown): any
				if not admit(player, remoteSpec, payload) then
					return nil
				end
				local handler = serverInvokeHandlers[remoteSpec.name]
				if not handler then
					return nil
				end
				local ok, result = pcall(handler, player, payload)
				if not ok then
					log.error("invoke handler %s failed: %s", remoteSpec.name, tostring(result))
					return nil
				end
				return result
			end
		else
			-- RemoteEvent and UnreliableRemoteEvent share the same OnServerEvent shape.
			local event = (remote :: any).OnServerEvent :: RBXScriptSignal
			event:Connect(function(player: Player, payload: unknown)
				if not admit(player, remoteSpec, payload) then
					return
				end
				local handler = serverHandlers[remoteSpec.name]
				if handler then
					xpcall(handler, function(err: any)
						log.error("handler %s failed: %s", remoteSpec.name, tostring(err))
					end, player, payload)
				end
			end)
		end
	end

	folder.Parent = ReplicatedStorage

	Players.PlayerRemoving:Connect(function(player: Player)
		buckets[player] = nil
		violations[player] = nil
		kicked[player] = nil
	end)
end

-- One handler per client-to-server event. Registering twice replaces the previous handler.
function Net.Server.on(name: string, handler: ServerHandler)
	local remoteSpec = spec(name)
	assert(remoteSpec.direction == "ToServer" and remoteSpec.kind ~= "Function", name .. " is not a client event")
	serverHandlers[name] = handler
end

function Net.Server.onInvoke(name: string, handler: ServerInvokeHandler)
	local remoteSpec = spec(name)
	assert(remoteSpec.kind == "Function" and remoteSpec.direction == "ToServer", name .. " is not a client function")
	serverInvokeHandlers[name] = handler
end

local function serverRemote(name: string): Instance
	local remoteSpec = spec(name)
	assert(remoteSpec.direction == "ToClient", name .. " is not a server-to-client remote")
	local remote = remotes[name]
	assert(remote, "Net.Server.setup() has not run")
	return remote
end

-- RemoteEvent and UnreliableRemoteEvent expose identical Fire* methods; both are created by setup().
function Net.Server.fire(name: string, player: Player, payload: any)
	(serverRemote(name) :: any):FireClient(player, payload)
end

function Net.Server.fireAll(name: string, payload: any)
	(serverRemote(name) :: any):FireAllClients(payload)
end

function Net.Server.fireList(name: string, players: { Player }, payload: any)
	for _, player in players do
		if player.Parent == Players then
			Net.Server.fire(name, player, payload)
		end
	end
end

function Net.Server.fireExcept(name: string, except: Player, payload: any)
	for _, player in Players:GetPlayers() do
		if player ~= except then
			Net.Server.fire(name, player, payload)
		end
	end
end

Net.Server.ViolationDecayPerSecond = VIOLATION_DECAY_PER_SECOND
Net.Server.KickThreshold = KICK_THRESHOLD
Net.Server.ViolationWeights = table.freeze(table.clone(VIOLATION_WEIGHTS))
Net.Server.violationScore = violationScore

-- Fires (player, score) just before a player is kicked for flooding or malformed traffic (P3 MovementAuthority /
-- P8 telemetry may record it).
Net.Server.Abuse = abuse

-- `player`'s current (decayed) violation score.
function Net.Server.violations(player: Player): number
	local strikes = violations[player]
	if not strikes then
		return 0
	end
	return violationScore(strikes.score, os.clock() - strikes.at, 0)
end

--------------------------------------------------------------------------------
-- Client
--------------------------------------------------------------------------------

Net.Client = {}

-- Waits for the server's remotes. ClientMain calls this before any controller Init.
function Net.Client.setup()
	assert(RunService:IsClient(), "Net.Client.setup is client-only")
	if clientReady then
		return
	end
	local folder = Instances.remotesFolder()
	for _, remoteSpec in RemoteRegistry.List do
		local remote = folder:WaitForChild(remoteSpec.name, 30)
		if remote then
			remotes[remoteSpec.name] = remote
		else
			log.error("remote %s never replicated", remoteSpec.name)
		end
	end
	clientReady = true
end

local function clientRemote(name: string): Instance?
	local remote = remotes[name]
	if not remote then
		log.warnThrottled(name, 10, "remote %s used before Net.Client.setup()", name)
	end
	return remote
end

function Net.Client.fire(name: string, payload: any)
	local remoteSpec = spec(name)
	assert(remoteSpec.direction == "ToServer" and remoteSpec.kind ~= "Function", name .. " is not a client event")
	local remote = clientRemote(name)
	if not remote then
		return
	end
	(remote :: any):FireServer(payload)
end

function Net.Client.invoke(name: string, payload: any): (boolean, any)
	local remoteSpec = spec(name)
	assert(remoteSpec.kind == "Function", name .. " is not a function remote")
	local remote = clientRemote(name)
	if not remote or not remote:IsA("RemoteFunction") then
		return false, nil
	end
	return pcall(function()
		return remote:InvokeServer(payload)
	end)
end

function Net.Client.on(name: string, handler: ClientHandler): RBXScriptConnection?
	local remoteSpec = spec(name)
	assert(remoteSpec.direction == "ToClient", name .. " is not a server-to-client remote")
	local remote = clientRemote(name)
	if not remote then
		return nil
	end
	local function safe(payload: any)
		xpcall(handler, function(err: any)
			log.error("client handler %s failed: %s", name, tostring(err))
		end, payload)
	end
	local event = (remote :: any).OnClientEvent :: RBXScriptSignal
	return event:Connect(safe)
end

return Net
