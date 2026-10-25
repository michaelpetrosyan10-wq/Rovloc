--!strict
-- The only place that knows where runtime-created instances live. Everything built at run time (the school,
-- the Creature, remotes, per-run props) is reached through these resolvers, so strict typing never guesses at
-- a dot path that the Rojo sourcemap cannot see.

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
	local school = Workspace:FindFirstChild(Names.School)
	return if school and school:IsA("Model") then school else nil
end

function Instances.lobby(): Model?
	local lobby = Workspace:FindFirstChild(Names.Lobby)
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
	local runtime = Workspace:FindFirstChild(Names.Runtime)
	return if runtime and runtime:IsA("Folder") then runtime else nil
end

-- Workspace.Runtime.<layoutId>, created on demand (server) or awaited (client).
function Instances.runtimeLevel(layoutId: string, create: boolean): Folder?
	local runtime = Instances.runtime()
	if not runtime then
		if not create then
			return nil
		end
		local folder = Instance.new("Folder")
		folder.Name = Names.Runtime
		folder.Parent = Workspace
		runtime = folder
	end
	assert(runtime, "unreachable")
	local level = runtime:FindFirstChild(layoutId)
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
	local existing = Workspace:FindFirstChild(Names.Cosmetic)
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
