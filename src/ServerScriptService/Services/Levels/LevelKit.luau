--!strict
-- LevelKit: what the per-level controllers share. Player eyes and feet as the server sees them (root +
-- CameraConfig.EyeHeightAboveRoot for the MoveState; the floor under the root), line of sight in the Default group
-- with every character and the Creature excluded (ARCHITECTURE §4b), "can anyone see this point", the run's playing
-- participants on a level, OneShots, and a small server-time schedule the scripted beats run on.
--
-- Pure pieces (tests/Specs/Levels.spec.luau): seenBy, newSchedule, hidingSpot.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Net = require(ReplicatedStorage.Shared.Net)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Types = require(ReplicatedStorage.Shared.Types)

local PacingDirector = require(ServerScriptService.Services.Core.NoiseAndDirectorService.PacingDirector)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)

local P = Attributes.Player

export type Schedule = {
	-- Runs `fn` once the clock reaches `at` (entries due together run in the order they were added).
	At: (self: Schedule, at: number, name: string, fn: () -> ()) -> (),
	-- Runs every entry due at `now` (entries added by a running entry run too when they are already due); returns
	-- how many ran.
	Run: (self: Schedule, now: number) -> number,
	Clear: (self: Schedule) -> (),
	Pending: (self: Schedule) -> { string },
	IsEmpty: (self: Schedule) -> boolean,
}

type Entry = { at: number, order: number, name: string, fn: () -> () }

local LevelKit = {}

-- Players farther than this from a point never count as seeing it.
LevelKit.SightLimit = 250

local DEFAULT_HIP_HEIGHT = 2
local oneShotSeq = 0

--------------------------------------------------------------------------------
-- Pure helpers
--------------------------------------------------------------------------------

-- Whether any of `eyes` within `range` of `point` has a clear line to it (`lineClear(from, to)`).
function LevelKit.seenBy(
	eyes: { Vector3 },
	point: Vector3,
	lineClear: (Vector3, Vector3) -> boolean,
	range: number?
): boolean
	local limit = range or LevelKit.SightLimit
	for _, eye in eyes do
		if (eye - point).Magnitude <= limit and lineClear(eye, point) then
			return true
		end
	end
	return false
end

-- The spot among `candidates` (root positions) nearest `from` that is at least `minDistance` from every player and
-- that nobody can see (`visible`), or nil.
function LevelKit.hidingSpot(
	candidates: { Vector3 },
	players: { Vector3 },
	from: Vector3,
	minDistance: number,
	visible: (Vector3) -> boolean
): Vector3?
	return PacingDirector.repositionPoint(candidates, players, from, minDistance, math.huge, visible)
end

function LevelKit.newSchedule(): Schedule
	local entries: { Entry } = {}
	local counter = 0
	local schedule: Schedule
	schedule = {
		At = function(_self: Schedule, at: number, name: string, fn: () -> ())
			counter += 1
			table.insert(entries, { at = at, order = counter, name = name, fn = fn })
		end,
		Run = function(_self: Schedule, now: number): number
			local ran = 0
			while true do
				local best: number? = nil
				for index, entry in entries do
					if entry.at <= now then
						local current = if best then entries[best] else nil
						if
							current == nil
							or entry.at < current.at
							or (entry.at == current.at and entry.order < current.order)
						then
							best = index
						end
					end
				end
				if best == nil then
					return ran
				end
				local entry = table.remove(entries, best) :: Entry
				ran += 1
				entry.fn()
			end
		end,
		Clear = function(_self: Schedule)
			table.clear(entries)
		end,
		Pending = function(_self: Schedule): { string }
			local sorted = table.clone(entries)
			table.sort(sorted, function(a: Entry, b: Entry): boolean
				if a.at == b.at then
					return a.order < b.order
				end
				return a.at < b.at
			end)
			local names: { string } = {}
			for _, entry in sorted do
				table.insert(names, entry.name)
			end
			return names
		end,
		IsEmpty = function(_self: Schedule): boolean
			return #entries == 0
		end,
	}
	return schedule
end

--------------------------------------------------------------------------------
-- Live helpers (the controllers' default dependencies)
--------------------------------------------------------------------------------

-- The run's participants who are playing (Alive or Downed), have a body and are in the server.
function LevelKit.playingParticipants(): { Player }
	local run = RunLifecycleService.GetRun()
	local out: { Player } = {}
	if not run then
		return out
	end
	for _, player in run.participants do
		if player.Parent == Players and LifeStateService.IsPlaying(player) and Instances.characterRoot(player) then
			table.insert(out, player)
		end
	end
	return out
end

-- Those of them on `levelId` (the level ZoneService last placed them on; the squad's level when unknown).
function LevelKit.playersOn(levelId: Enums.LevelId): { Player }
	local out: { Player } = {}
	for _, player in LevelKit.playingParticipants() do
		local level = player:GetAttribute(P.LevelId)
		if level == nil or level == levelId then
			table.insert(out, player)
		end
	end
	return out
end

function LevelKit.rootOf(player: Player): Vector3?
	local root = Instances.characterRoot(player)
	return if root then root.CFrame.Position else nil
end

-- Where the server considers the player's eyes to be (it never sees client-side poses).
function LevelKit.eyeOf(player: Player): Vector3?
	local root = LevelKit.rootOf(player)
	if not root then
		return nil
	end
	local state = PlayerStateService.GetMoveState(player)
	local height = CameraConfig.EyeHeightAboveRoot[state] or CameraConfig.EyeHeightAboveRoot.Standing
	return root + Vector3.new(0, height, 0)
end

-- The floor under the player's root.
function LevelKit.feetOf(player: Player): Vector3?
	local root = Instances.characterRoot(player)
	if not root then
		return nil
	end
	local humanoid = Instances.characterHumanoid(player)
	local hip = if humanoid then humanoid.HipHeight else DEFAULT_HIP_HEIGHT
	return root.CFrame.Position - Vector3.new(0, hip + root.Size.Y / 2, 0)
end

-- Line of sight in the Default group with every character and the Creature excluded.
function LevelKit.lineClear(from: Vector3, to: Vector3): boolean
	local exclude: { Instance } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(exclude, character)
		end
	end
	local creature = Instances.creature()
	if creature then
		table.insert(exclude, creature)
	end
	return SpatialQuery.lineClear(from, to, SpatialQuery.losParams(exclude))
end

-- The eyes of every playing participant.
function LevelKit.eyes(players: { Player }, eyeOf: (Player) -> Vector3?): { Vector3 }
	local out: { Vector3 } = {}
	for _, player in players do
		local eye = eyeOf(player)
		if eye then
			table.insert(out, eye)
		end
	end
	return out
end

-- Fires a OneShot to every client (startAt = server time the moment begins).
function LevelKit.oneShot(
	kind: Enums.OneShotKind,
	startAt: number,
	args: { [string]: Types.OneShotArg },
	subject: Instance?
)
	oneShotSeq += 1
	local event: Types.OneShotEvent = {
		seq = oneShotSeq,
		kind = kind,
		subject = subject,
		startAt = startAt,
		args = args,
	}
	Net.Server.fireAll("OneShot", event)
end

-- A Notify toast for `player`.
function LevelKit.notify(player: Player, key: string)
	local payload: Types.NotifyPayload = { key = key, args = {} }
	Net.Server.fire("Notify", player, payload)
end

return table.freeze(LevelKit)
