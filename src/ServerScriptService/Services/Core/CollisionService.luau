--!strict
-- CollisionService: registers the collision groups, applies the full matrix, and is the only run-time writer of
-- BasePart.CollisionGroup (docs/ARCHITECTURE.md §4a).
--
-- Matrix. Init registers every custom group from CollisionGroups.Custom and calls CollisionGroupSetCollidable for
-- every unordered pair of CollisionGroups.All (Default included), so the engine state equals the data in
-- CollisionGroups exactly, whatever the place file held before.
--
-- Character modes. Each tracked character has a mode stack keyed by token: PushMode(character, token, mode) adds or
-- replaces that token's entry, PopMode(character, token) removes it, and the highest mode wins
-- (Normal < Vent < Locked). So a jumpscare lock that ends inside a duct falls back to Vent, never to Players.
--   Normal: every body part "Players"; the VentCollider ball "NoCollide" with CanCollide off.
--   Vent:   every body part "NoCollide"; the VentCollider ball "VentCollider" with CanCollide on (the only collider).
--   Locked: every part "NoCollide" (VentCollider included, CanCollide off).
-- Parts added later (accessories, tools) get the current mode's group as they arrive. Collision groups are used
-- instead of CanCollide because the Humanoid rewrites CanCollide on its torso and head parts every step.
--
-- CharacterService hands every character it builds to TrackCharacter before parenting it (the same moment it fires
-- CharacterSpawned), so the first replicated frame already has the right groups. CollisionService does not require
-- CharacterService: CharacterService pushes the Locked mode through this API, and the reverse require would be a
-- cycle.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

local log = Log.new("Collision")

type GroupName = CollisionGroups.GroupName

type Tracked = {
	modes: { [string]: Enums.CollisionMode },
	applied: Enums.CollisionMode,
	trove: Trove.Trove,
}

local VENT_COLLIDER_NAME = "VentCollider"

-- Higher wins.
local MODE_RANK: { [string]: number } = {
	Normal = 1,
	Vent = 2,
	Locked = 3,
}

local CollisionService = {}

CollisionService.Name = "CollisionService"
CollisionService.VentColliderName = VENT_COLLIDER_NAME

local tracked: { [Model]: Tracked } = {}

--------------------------------------------------------------------------------
-- Pure helpers (specs: tests/Specs/CoreServices.spec.luau)
--------------------------------------------------------------------------------

-- The winning mode of a mode stack (token -> mode). An empty stack is Normal.
local function resolveMode(modes: { [string]: Enums.CollisionMode }): Enums.CollisionMode
	local best: Enums.CollisionMode = "Normal"
	for _, mode: Enums.CollisionMode in modes do
		if (MODE_RANK[mode] or 0) > MODE_RANK[best] then
			best = mode
		end
	end
	return best
end
CollisionService.resolveMode = resolveMode

-- The group a character part takes in `mode`, plus the CanCollide value to force (nil leaves CanCollide alone).
function CollisionService.groupFor(partName: string, mode: Enums.CollisionMode): (GroupName, boolean?)
	if partName == VENT_COLLIDER_NAME then
		if mode == "Vent" then
			return CollisionGroups.VentCollider, true
		end
		return CollisionGroups.NoCollide, false
	end
	if mode == "Normal" then
		return CollisionGroups.Players, nil
	end
	return CollisionGroups.NoCollide, nil
end

--------------------------------------------------------------------------------
-- Matrix
--------------------------------------------------------------------------------

local function registerGroups(): boolean
	local all = true
	local limit = PhysicsService:GetMaxCollisionGroups()
	if #CollisionGroups.All > limit then
		log.error("%d collision groups exceed the engine limit of %d", #CollisionGroups.All, limit)
	end
	for _, name: GroupName in CollisionGroups.Custom do
		if PhysicsService:IsCollisionGroupRegistered(name) then
			continue
		end
		local ok, err = pcall(function()
			PhysicsService:RegisterCollisionGroup(name)
		end)
		if not ok then
			all = false
			log.error("could not register collision group %s: %s", name, tostring(err))
		end
	end
	return all
end

local function applyMatrix()
	local groups = CollisionGroups.All
	for i = 1, #groups do
		for j = i, #groups do
			local a: GroupName, b: GroupName = groups[i], groups[j]
			local collidable = CollisionGroups.collides(a, b)
			local ok, err = pcall(function()
				PhysicsService:CollisionGroupSetCollidable(a, b, collidable)
			end)
			if not ok then
				log.error("CollisionGroupSetCollidable(%s, %s) failed: %s", a, b, tostring(err))
			end
		end
	end
end

-- Pairs whose engine state differs from CollisionGroups (empty when the matrix is fully applied).
function CollisionService.VerifyMatrix(): { string }
	local mismatches: { string } = {}
	for _, name: GroupName in CollisionGroups.Custom do
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			table.insert(mismatches, name .. " is not registered")
		end
	end
	local groups = CollisionGroups.All
	for i = 1, #groups do
		for j = i, #groups do
			local a: GroupName, b: GroupName = groups[i], groups[j]
			local ok, actual = pcall(function(): boolean
				return PhysicsService:CollisionGroupsAreCollidable(a, b)
			end)
			local expected = CollisionGroups.collides(a, b)
			if not ok then
				table.insert(mismatches, string.format("%s/%s could not be read", a, b))
			elseif actual ~= expected then
				table.insert(
					mismatches,
					string.format("%s/%s is %s, expected %s", a, b, tostring(actual), tostring(expected))
				)
			end
		end
	end
	return mismatches
end

--------------------------------------------------------------------------------
-- Part groups
--------------------------------------------------------------------------------

local function setPartGroup(part: BasePart, group: string)
	if part.CollisionGroup ~= group then
		part.CollisionGroup = group
	end
end

local function applyPart(part: BasePart, mode: Enums.CollisionMode)
	local group, canCollide = CollisionService.groupFor(part.Name, mode)
	setPartGroup(part, group)
	if canCollide ~= nil and part.CanCollide ~= canCollide then
		part.CanCollide = canCollide
	end
end

local function applyMode(character: Model, mode: Enums.CollisionMode)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			applyPart(descendant, mode)
		end
	end
end

-- Sets `group` on `root` (when it is a part) and on every BasePart under it.
function CollisionService.ApplyGroup(root: Instance, group: GroupName)
	if root:IsA("BasePart") then
		setPartGroup(root, group)
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			setPartGroup(descendant, group)
		end
	end
end

--------------------------------------------------------------------------------
-- Character tracking + mode stacks
--------------------------------------------------------------------------------

local function refresh(character: Model, entry: Tracked)
	local mode: Enums.CollisionMode = resolveMode(entry.modes)
	entry.applied = mode
	applyMode(character, mode)
end

local function untrack(character: Model)
	local entry = tracked[character]
	if not entry then
		return
	end
	tracked[character] = nil
	entry.trove:Clean()
end

local function track(character: Model): Tracked
	local existing = tracked[character]
	if existing then
		return existing
	end
	local entry: Tracked = { modes = {}, applied = "Normal", trove = Trove.new() }
	tracked[character] = entry
	-- Deferred signals: these handlers run after the part arrived, so they read the mode fresh.
	entry.trove:Connect(character.DescendantAdded, function(descendant: Instance)
		local current = tracked[character]
		if current and descendant:IsA("BasePart") and descendant:IsDescendantOf(character) then
			applyPart(descendant, current.applied)
		end
	end)
	entry.trove:Connect(character.Destroying, function()
		untrack(character)
	end)
	return entry
end

-- Starts managing `character` in Normal mode (idempotent). CharacterService calls it for every character it builds.
function CollisionService.TrackCharacter(character: Model)
	local entry = track(character)
	refresh(character, entry)
end

-- Stops managing `character` (its parts keep their current groups). Called when a character is removed.
function CollisionService.UntrackCharacter(character: Model)
	untrack(character)
end

function CollisionService.IsTracked(character: Model): boolean
	return tracked[character] ~= nil
end

-- Adds (or replaces) `token`'s mode on `character`'s stack; the highest mode on the stack is applied.
function CollisionService.PushMode(character: Model, token: string, mode: Enums.CollisionMode)
	if not Enums.has(Enums.CollisionMode, mode) then
		log.warn("PushMode(%s, %s): unknown mode %s", character.Name, token, tostring(mode))
		return
	end
	local entry = track(character)
	if entry.modes[token] == mode then
		return
	end
	entry.modes[token] = mode
	refresh(character, entry)
end

-- Removes `token` from `character`'s stack (no-op when absent) and re-applies the winning mode.
function CollisionService.PopMode(character: Model, token: string)
	local entry = tracked[character]
	if not entry or entry.modes[token] == nil then
		return
	end
	entry.modes[token] = nil
	refresh(character, entry)
end

-- The mode currently applied to `character` (Normal when untracked).
function CollisionService.GetMode(character: Model): Enums.CollisionMode
	local entry = tracked[character]
	if not entry then
		return "Normal"
	end
	return entry.applied
end

-- Whether `token` currently has an entry on `character`'s stack.
function CollisionService.HasMode(character: Model, token: string): boolean
	local entry = tracked[character]
	return entry ~= nil and entry.modes[token] ~= nil
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function CollisionService.Init()
	registerGroups()
	applyMatrix()
	local mismatches = CollisionService.VerifyMatrix()
	if #mismatches > 0 then
		for _, mismatch in mismatches do
			log.error("collision matrix: %s", mismatch)
		end
	else
		log.info("collision matrix applied (%d groups)", #CollisionGroups.All)
	end
end

return CollisionService
