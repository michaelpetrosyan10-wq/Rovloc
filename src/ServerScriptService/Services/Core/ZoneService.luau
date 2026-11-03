--!strict
-- ZoneService: 10 Hz point-in-volume tracking for every character (docs/ARCHITECTURE.md §4b). Replaces Touched.
--
-- Rooms. Every `Zone` part (one per room, built by the world builder) is indexed in a spatial hash per level
-- (LevelId attribute; the lobby is its own level). Each tick, each player's root is located: the zone it was in last
-- tick first, then the rest of that level, then every other level. The result is written to the Player attributes
-- ZoneId (room id; removed while the root is in no room, e.g. a stair shaft) and LevelId (kept at the last known
-- level when no room contains the root), and ZoneChanged fires on every change. The Creature's root is located the
-- same way (GetCreatureZone / CreatureZoneChanged); its attributes belong to MonsterAIService.
--
-- Trigger volumes. Parts tagged ScareTrigger, FloorDebris, CheckpointVolume, PoolWater or LevelExit are hashed the
-- same way. A player is inside a volume while their root, or the point under their feet, is inside its box, so thin
-- floor triggers (debris, glass) catch walkers as well as crouchers. VolumeEntered / VolumeExited fire on changes
-- (a destroyed volume counts as exited).
--
-- Pairing. Every VolumeEntered is matched by one VolumeExited, and a zone by ZoneChanged(player, nil), including for
-- a player who leaves the server while inside: OnPlayerRemoving (and, as a backstop, the next tick for anyone no
-- longer in Players) fires those exits before forgetting the player, without writing attributes on them. Consumers
-- that count occupants from the events (airlock stragglers, traps, pool grabs) never keep a phantom occupant.
--
-- The test is pure math (`CFrame:PointToObjectSpace` against Size / 2), so it works for NoCollide parts that physical
-- queries never see. The index rebuilds itself whenever tagged parts come or go.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

local log = Log.new("Zones")

local W = Attributes.World
local P = Attributes.Player

local CELL_SIZE = 24
local NO_LEVEL = "_"

local VOLUME_TAGS: { string } = {
	Tags.ScareTrigger,
	Tags.FloorDebris,
	Tags.CheckpointVolume,
	Tags.PoolWater,
	Tags.LevelExit,
}
local INDEXED_TAGS: { string } = { Tags.Zone }
for _, tag in VOLUME_TAGS do
	table.insert(INDEXED_TAGS, tag)
end

export type Entry = {
	part: BasePart,
	levelId: string,
	tag: string, -- Zone, or the volume's trigger tag
}

export type Grid = {
	cellSize: number,
	cells: { [number]: { Entry } },
	count: number,
}

export type Index = {
	zones: { [string]: Grid }, -- by level id
	volumes: { [string]: Grid },
	levels: { string }, -- sorted level ids that hold zones (deterministic search order)
	byPart: { [BasePart]: Entry },
}

type PlayerState = {
	zone: BasePart?,
	volumes: { [BasePart]: string },
}

local ZoneService = {}

ZoneService.Name = "ZoneService"
ZoneService.VolumeTags = VOLUME_TAGS

local zoneChanged: Signal.Signal<Player, BasePart?> = Signal.new()
local volumeEntered: Signal.Signal<Player, BasePart, string> = Signal.new()
local volumeExited: Signal.Signal<Player, BasePart, string> = Signal.new()
local creatureZoneChanged: Signal.Signal<BasePart?> = Signal.new()

ZoneService.ZoneChanged = zoneChanged
ZoneService.VolumeEntered = volumeEntered
ZoneService.VolumeExited = volumeExited
ZoneService.CreatureZoneChanged = creatureZoneChanged

local serviceTrove = Trove.new()

local index: Index? = nil
local dirty = true
local states: { [Player]: PlayerState } = {}
local creatureZone: BasePart? = nil

--------------------------------------------------------------------------------
-- Pure helpers (specs: tests/Specs/CoreServices.spec.luau)
--------------------------------------------------------------------------------

-- Whether `point` lies inside the box `cframe` x `size` (edges inclusive).
function ZoneService.pointInBox(cframe: CFrame, size: Vector3, point: Vector3): boolean
	local localPoint = cframe:PointToObjectSpace(point)
	local half = size * 0.5
	return math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z
end

function ZoneService.cellKey(cx: number, cz: number): number
	return cx * 65536 + cz
end

function ZoneService.newGrid(cellSize: number?): Grid
	return { cellSize = cellSize or CELL_SIZE, cells = {}, count = 0 }
end

-- World-space XZ bounds of a part's (possibly rotated) box.
function ZoneService.horizontalBounds(cframe: CFrame, size: Vector3): (number, number, number, number)
	local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
	local right, up, look = cframe.RightVector, cframe.UpVector, cframe.LookVector
	local ex = math.abs(right.X) * hx + math.abs(up.X) * hy + math.abs(look.X) * hz
	local ez = math.abs(right.Z) * hx + math.abs(up.Z) * hy + math.abs(look.Z) * hz
	local center = cframe.Position
	return center.X - ex, center.Z - ez, center.X + ex, center.Z + ez
end

function ZoneService.gridInsert(grid: Grid, entry: Entry)
	local minX, minZ, maxX, maxZ = ZoneService.horizontalBounds(entry.part.CFrame, entry.part.Size)
	local size = grid.cellSize
	for cx = math.floor(minX / size), math.floor(maxX / size) do
		for cz = math.floor(minZ / size), math.floor(maxZ / size) do
			local key = ZoneService.cellKey(cx, cz)
			local cell = grid.cells[key]
			if not cell then
				cell = {}
				grid.cells[key] = cell
			end
			table.insert(cell, entry)
		end
	end
	grid.count += 1
end

-- Entries of the cell holding (x, z).
function ZoneService.gridCell(grid: Grid, x: number, z: number): { Entry }?
	local size = grid.cellSize
	return grid.cells[ZoneService.cellKey(math.floor(x / size), math.floor(z / size))]
end

local function entryContains(entry: Entry, point: Vector3): boolean
	local part = entry.part
	return ZoneService.pointInBox(part.CFrame, part.Size, point)
end

local function firstIn(grid: Grid?, point: Vector3): BasePart?
	if not grid then
		return nil
	end
	local cell = ZoneService.gridCell(grid, point.X, point.Z)
	if not cell then
		return nil
	end
	for _, entry in cell do
		if entryContains(entry, point) then
			return entry.part
		end
	end
	return nil
end

-- Builds an index from zone parts and trigger-volume parts (each volume's tag is the first VOLUME_TAGS tag it has).
function ZoneService.buildIndex(zoneParts: { BasePart }, volumeParts: { BasePart }): Index
	local built: Index = { zones = {}, volumes = {}, levels = {}, byPart = {} }
	local function levelOf(part: BasePart): string
		local levelId = part:GetAttribute(W.LevelId)
		return if type(levelId) == "string" and levelId ~= "" then levelId else NO_LEVEL
	end
	for _, part in zoneParts do
		if built.byPart[part] then
			continue
		end
		local entry: Entry = { part = part, levelId = levelOf(part), tag = Tags.Zone }
		local grid = built.zones[entry.levelId]
		if not grid then
			grid = ZoneService.newGrid()
			built.zones[entry.levelId] = grid
			table.insert(built.levels, entry.levelId)
		end
		ZoneService.gridInsert(grid, entry)
		built.byPart[part] = entry
	end
	table.sort(built.levels)
	for _, part in volumeParts do
		if built.byPart[part] then
			continue
		end
		local tag: string? = nil
		for _, candidate in VOLUME_TAGS do
			if part:HasTag(candidate) then
				tag = candidate
				break
			end
		end
		if not tag then
			continue
		end
		local entry: Entry = { part = part, levelId = levelOf(part), tag = tag }
		local grid = built.volumes[entry.levelId]
		if not grid then
			grid = ZoneService.newGrid()
			built.volumes[entry.levelId] = grid
		end
		ZoneService.gridInsert(grid, entry)
		built.byPart[part] = entry
	end
	return built
end

-- The zone containing `point`: `last` first (when still indexed), then `hintLevel`'s zones, then every other level.
function ZoneService.locate(built: Index, point: Vector3, last: BasePart?, hintLevel: string?): BasePart?
	local searchedLevel: string? = nil
	if last then
		local entry = built.byPart[last]
		if entry and entry.tag == Tags.Zone then
			if entryContains(entry, point) then
				return last
			end
			searchedLevel = entry.levelId
		end
	end
	searchedLevel = searchedLevel or hintLevel
	if searchedLevel then
		local hit = firstIn(built.zones[searchedLevel], point)
		if hit then
			return hit
		end
	end
	for _, levelId in built.levels do
		if levelId ~= searchedLevel then
			local hit = firstIn(built.zones[levelId], point)
			if hit then
				return hit
			end
		end
	end
	return nil
end

-- Every volume containing any of `points`, mapped to its tag.
function ZoneService.volumesAt(built: Index, points: { Vector3 }): { [BasePart]: string }
	local inside: { [BasePart]: string } = {}
	for _, grid in built.volumes do
		for _, point in points do
			local cell = ZoneService.gridCell(grid, point.X, point.Z)
			if not cell then
				continue
			end
			for _, entry in cell do
				if inside[entry.part] == nil and entryContains(entry, point) then
					inside[entry.part] = entry.tag
				end
			end
		end
	end
	return inside
end

--------------------------------------------------------------------------------
-- Live index
--------------------------------------------------------------------------------

local function collectParts(tag: string, into: { BasePart })
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(Workspace) then
			table.insert(into, instance)
		end
	end
end

local function liveIndex(): Index
	local built = index
	if built and not dirty then
		return built
	end
	local zoneParts: { BasePart } = {}
	collectParts(Tags.Zone, zoneParts)
	local volumeParts: { BasePart } = {}
	for _, tag in VOLUME_TAGS do
		collectParts(tag, volumeParts)
	end
	local fresh = ZoneService.buildIndex(zoneParts, volumeParts)
	index = fresh
	dirty = false
	log.debug("indexed %d zones and %d volumes", #zoneParts, #volumeParts)
	return fresh
end

local function markDirty()
	dirty = true
end

--------------------------------------------------------------------------------
-- Tracking
--------------------------------------------------------------------------------

local function stateFor(player: Player): PlayerState
	local state = states[player]
	if not state then
		state = { zone = nil, volumes = {} }
		states[player] = state
	end
	return state
end

local function setZone(player: Player, state: PlayerState, zone: BasePart?)
	if state.zone == zone then
		return
	end
	state.zone = zone
	if zone then
		local zoneId = zone:GetAttribute(W.ZoneId)
		Attributes.set(player, P.ZoneId, if type(zoneId) == "string" then zoneId else zone.Name)
		local levelId = zone:GetAttribute(W.LevelId)
		if type(levelId) == "string" then
			Attributes.set(player, P.LevelId, levelId)
		end
	else
		Attributes.set(player, P.ZoneId, nil)
	end
	zoneChanged:Fire(player, zone)
end

local function setVolumes(player: Player, state: PlayerState, inside: { [BasePart]: string })
	local previous = state.volumes
	state.volumes = inside
	for volume, tag in previous do
		if inside[volume] == nil then
			volumeExited:Fire(player, volume, tag)
		end
	end
	for volume, tag in inside do
		if previous[volume] == nil then
			volumeEntered:Fire(player, volume, tag)
		end
	end
end

local function feetPoint(player: Player, root: BasePart): Vector3
	local humanoid = Instances.characterHumanoid(player)
	local hipHeight = if humanoid then humanoid.HipHeight else 2
	return root.Position - Vector3.new(0, hipHeight + root.Size.Y * 0.5, 0)
end

-- Forgets `player`, first firing VolumeExited for every volume they were in and ZoneChanged(player, nil) when they
-- were in a zone. Attributes are left alone (the player is leaving).
local function releasePlayer(player: Player)
	local state = states[player]
	if not state then
		return
	end
	states[player] = nil
	for volume, tag in state.volumes do
		volumeExited:Fire(player, volume, tag)
	end
	if state.zone then
		state.zone = nil
		zoneChanged:Fire(player, nil)
	end
end

local function updatePlayer(built: Index, player: Player)
	local state = stateFor(player)
	local root = Instances.characterRoot(player)
	if not (root and root:IsDescendantOf(Workspace)) then
		setZone(player, state, nil)
		setVolumes(player, state, {})
		return
	end
	local position = root.Position
	local hint = player:GetAttribute(P.LevelId)
	local zone = ZoneService.locate(built, position, state.zone, if type(hint) == "string" then hint else nil)
	setZone(player, state, zone)
	setVolumes(player, state, ZoneService.volumesAt(built, { position, feetPoint(player, root) }))
end

local function updateCreature(built: Index)
	local root = Instances.creatureRoot()
	local zone: BasePart? = nil
	if root then
		local hint = root.Parent and root.Parent:GetAttribute(Attributes.Creature.LevelId)
		zone = ZoneService.locate(built, root.Position, creatureZone, if type(hint) == "string" then hint else nil)
	end
	if zone ~= creatureZone then
		creatureZone = zone
		creatureZoneChanged:Fire(zone)
	end
end

local function step()
	local built = liveIndex()
	for _, player in Players:GetPlayers() do
		updatePlayer(built, player)
	end
	for player in table.clone(states) do
		if player.Parent ~= Players then
			releasePlayer(player)
		end
	end
	updateCreature(built)
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

function ZoneService.GetPlayerZone(player: Player): BasePart?
	local state = states[player]
	return if state then state.zone else nil
end

-- The zone containing `position` (searching every level), or nil.
function ZoneService.GetZoneAt(position: Vector3): BasePart?
	return ZoneService.locate(liveIndex(), position, nil, nil)
end

-- Players whose root (or feet) was inside `volume` at the last tick.
function ZoneService.GetPlayersInVolume(volume: BasePart): { Player }
	local out: { Player } = {}
	for player, state in states do
		if state.volumes[volume] ~= nil and player.Parent == Players then
			table.insert(out, player)
		end
	end
	return out
end

-- Volumes `player` was inside at the last tick, mapped to their tags.
function ZoneService.GetPlayerVolumes(player: Player): { [BasePart]: string }
	local state = states[player]
	return if state then table.clone(state.volumes) else {}
end

function ZoneService.GetCreatureZone(): BasePart?
	return creatureZone
end

-- Re-locates `player` now instead of at the next tick (after a server teleport, or in specs), firing the usual
-- ZoneChanged / VolumeEntered / VolumeExited.
function ZoneService.UpdatePlayer(player: Player)
	updatePlayer(liveIndex(), player)
end

-- Rebuilds the zone / volume index on the next lookup. Tag signals do this on their own; call it after tagging or
-- moving volumes that must count within the same frame.
function ZoneService.Refresh()
	markDirty()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ZoneService.Init()
	for _, tag in INDEXED_TAGS do
		serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(tag), markDirty)
		serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(tag), markDirty)
	end
end

function ZoneService.Start()
	local interval = 1 / GameConfig.ServerTickHz
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		accumulated += dt
		if accumulated < interval then
			return
		end
		accumulated = 0
		xpcall(step, function(err: any)
			log.warnThrottled("step", 10, "zone step failed: %s", tostring(err))
		end)
	end)
end

function ZoneService.OnPlayerRemoving(player: Player)
	releasePlayer(player)
end

return ZoneService
