--!strict
-- The only place that knows where runtime-created instances live. Everything built at run time (the school,
-- the Creature, remotes, per-run props) is reached through these resolvers, so strict typing never guesses at
-- a dot path that the Rojo sourcemap cannot see.
--
-- Workspace also holds every player character, and CharacterService names each one after its player. A username
-- is free text ("Runtime", "School", "Lobby" and "Cosmetic" are all valid), so a plain FindFirstChild(name) could
-- hand back someone's character. Workspace roots are therefore resolved by name AND class: the first child with the
-- name that is the expected class and is not a character (a Model holding a Humanoid). WorldService creates
-- Workspace.Runtime during Init, before any character exists.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Instances = {}

Instances.Names = table.freeze({
	Remotes = "Remotes", -- ReplicatedStorage
	Lobby = "Lobby", -- Workspace
	School = "School", -- Workspace
	Stairwells = "Stairwells", -- Workspace.School
	Exterior = "Exterior", -- Workspace.School
	Cosmetic = "Cosmetic", -- Workspace (client-local)
	Runtime = "Runtime", -- Workspace
	Creature = "Creature", -- Workspace
	-- Children of every level model (Workspace.School.<LevelId> and Workspace.Lobby)
	Shell = "Shell",
	Lights = "Lights",
	Zones = "Zones",
	Vents = "Vents",
	Anchors = "Anchors",
	Triggers = "Triggers",
	Waypoints = "Waypoints",
	Props = "Props",
})

local Names = Instances.Names

-- A character-shaped Model (player characters and the Creature): never a world root.
local function isCharacterModel(instance: Instance): boolean
	return instance:IsA("Model") and instance:FindFirstChildOfClass("Humanoid") ~= nil
end

-- The first child of `parent` named `name` that IsA(`className`) and is not a character model.
local function findRoot(parent: Instance, name: string, className: string): Instance?
	local first = parent:FindFirstChild(name)
	if first == nil then
		return nil
	end
	if first:IsA(className) and not isCharacterModel(first) then
		return first
	end
	for _, child in parent:GetChildren() do
		if child.Name == name and child:IsA(className) and not isCharacterModel(child) then
			return child
		end
	end
	return nil
end

local function waitFor(parent: Instance, name: string, timeout: number?): Instance?
	local found = parent:FindFirstChild(name)
	if found then
		return found
	end
	return parent:WaitForChild(name, timeout or 30)
end

function Instances.remotesFolder(): Folder
	local folder = waitFor(ReplicatedStorage, Names.Remotes, 60)
	assert(folder and folder:IsA("Folder"), "ReplicatedStorage.Remotes is missing")
	return folder
end

function Instances.findRemotesFolder(): Folder?
	local folder = ReplicatedStorage:FindFirstChild(Names.Remotes)
	return if folder and folder:IsA("Folder") then folder else nil
end

function Instances.school(): Model?
	local school = findRoot(Workspace, Names.School, "Model")
	return if school and school:IsA("Model") then school else nil
end

function Instances.lobby(): Model?
	local lobby = findRoot(Workspace, Names.Lobby, "Model")
	return if lobby and lobby:IsA("Model") then lobby else nil
end

-- Workspace.Lobby for "Lobby", otherwise Workspace.School.<levelId>.
function Instances.layoutRoot(layoutId: string): Model?
	if layoutId == "Lobby" then
		return Instances.lobby()
	end
	local school = Instances.school()
	if not school then
		return nil
	end
	local level = school:FindFirstChild(layoutId)
	return if level and level:IsA("Model") then level else nil
end

function Instances.layoutChild(layoutId: string, childName: string): Instance?
	local root = Instances.layoutRoot(layoutId)
	return if root then root:FindFirstChild(childName) else nil
end

function Instances.stairwells(): Model?
	local school = Instances.school()
	if not school then
		return nil
	end
	local stairwells = school:FindFirstChild(Names.Stairwells)
	return if stairwells and stairwells:IsA("Model") then stairwells else nil
end

function Instances.runtime(): Folder?
	local runtime = findRoot(Workspace, Names.Runtime, "Folder")
	return if runtime and runtime:IsA("Folder") then runtime else nil
end

-- Workspace.Runtime, created when missing (server: WorldService.Init calls this before any character exists).
function Instances.ensureRuntime(): Folder
	local existing = Instances.runtime()
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = Names.Runtime
	folder.Parent = Workspace
	return folder
end

-- Workspace.Runtime.<layoutId>, created on demand (server) or awaited (client).
function Instances.runtimeLevel(layoutId: string, create: boolean): Folder?
	local runtime = if create then Instances.ensureRuntime() else Instances.runtime()
	if not runtime then
		return nil
	end
	local level = findRoot(runtime, layoutId, "Folder")
	if level and level:IsA("Folder") then
		return level
	end
	if not create then
		return nil
	end
	local folder = Instance.new("Folder")
	folder.Name = layoutId
	folder.Parent = runtime
	return folder
end

-- Client-local folder for cosmetic geometry (never replicated).
function Instances.cosmetic(): Folder
	local existing = findRoot(Workspace, Names.Cosmetic, "Folder")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = Names.Cosmetic
	folder.Parent = Workspace
	return folder
end

function Instances.creature(): Model?
	for _, tagged in CollectionService:GetTagged("Creature") do
		if tagged:IsA("Model") and tagged:IsDescendantOf(Workspace) then
			return tagged
		end
	end
	return nil
end

function Instances.creatureRoot(): BasePart?
	local creature = Instances.creature()
	if not creature then
		return nil
	end
	local root = creature:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

function Instances.characterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

function Instances.characterHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

return table.freeze(Instances)
