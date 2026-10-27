-- Lune harness: loads a Rojo-built place and runs the game's ModuleScripts outside Roblox.
--
-- Engine services only exist as bare instances in Lune, so this file injects the subset of engine behaviour
-- that pure-logic modules and the procedural builders need (RunService, CollectionService, PhysicsService,
-- Players, TweenService, HttpService, Workspace queries) plus the Random / RaycastParams / OverlapParams
-- datatypes Lune lacks. Gameplay that needs the physics engine is out of scope; it is verified in Studio.
--
-- Usage from another Lune script:
--   local Harness = require("./harness")
--   local h = Harness.load("path/to/place.rbxl", { server = true })
--   local LayoutSchema = h.require("ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema")

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Harness = {}

--------------------------------------------------------------------------------
-- Fake signals (never fire on their own; harness code may :Fire them)
--------------------------------------------------------------------------------

local function newSignal()
	local handlers = {}
	local signal = {}
	function signal:Connect(fn)
		local entry = { fn = fn, connected = true }
		table.insert(handlers, entry)
		return {
			Connected = true,
			Disconnect = function(conn)
				entry.connected = false
				conn.Connected = false
			end,
		}
	end
	function signal:Once(fn)
		local conn
		conn = signal:Connect(function(...)
			conn:Disconnect()
			fn(...)
		end)
		return conn
	end
	function signal:Wait()
		return coroutine.yield()
	end
	function signal:Fire(...)
		for _, entry in table.clone(handlers) do
			if entry.connected then
				task.spawn(entry.fn, ...)
			end
		end
	end
	return signal
end

--------------------------------------------------------------------------------
-- Datatype shims
--------------------------------------------------------------------------------

-- Deterministic PCG-style generator with the Roblox Random API. Sequences differ from Roblox's own PCG32,
-- so specs assert determinism and ranges, never exact Roblox values.
local function makeRandom(seed)
	local state = math.floor(seed or os.clock() * 1e6) % 4294967296
	if state == 0 then
		state = 0x9E3779B9
	end
	local rng = {}
	local function nextU32()
		-- xorshift32
		state = bit32.bxor(state, bit32.lshift(state, 13))
		state = bit32.bxor(state, bit32.rshift(state, 17))
		state = bit32.bxor(state, bit32.lshift(state, 5))
		return state
	end
	function rng:NextNumber(min, max)
		local unit = nextU32() / 4294967296
		if min == nil then
			return unit
		end
		return min + (max - min) * unit
	end
	function rng:NextInteger(min, max)
		assert(min <= max, "NextInteger: min > max")
		return min + (nextU32() % (max - min + 1))
	end
	function rng:NextUnitVector()
		local z = rng:NextNumber(-1, 1)
		local a = rng:NextNumber(0, math.pi * 2)
		local r = math.sqrt(1 - z * z)
		return roblox.Vector3.new(r * math.cos(a), r * math.sin(a), z)
	end
	function rng:Shuffle(list)
		for i = #list, 2, -1 do
			local j = rng:NextInteger(1, i)
			list[i], list[j] = list[j], list[i]
		end
	end
	function rng:Clone()
		local copy = makeRandom(1)
		return copy
	end
	return rng
end

local RandomShim = { new = makeRandom }

local function makeParams()
	return {
		FilterType = roblox.Enum.RaycastFilterType.Exclude,
		FilterDescendantsInstances = {},
		CollisionGroup = "Default",
		IgnoreWater = false,
		RespectCanCollide = false,
		MaxParts = 0,
		AddToFilter = function(self, item)
			table.insert(self.FilterDescendantsInstances, item)
		end,
	}
end

local RaycastParamsShim = { new = makeParams }
local OverlapParamsShim = { new = makeParams }

--------------------------------------------------------------------------------
-- Place loading + engine method injection
--------------------------------------------------------------------------------

local injected = false
local current -- the active harness (methods below close over it)

local function inject()
	if injected then
		return
	end
	injected = true

	roblox.implementMethod("RunService", "IsServer", function()
		return current.server
	end)
	roblox.implementMethod("RunService", "IsClient", function()
		return not current.server
	end)
	roblox.implementMethod("RunService", "IsStudio", function()
		return true
	end)
	roblox.implementMethod("RunService", "IsRunning", function()
		return true
	end)
	for _, name in { "Heartbeat", "Stepped", "PreSimulation", "PostSimulation", "PreRender", "RenderStepped", "PreAnimation" } do
		roblox.implementProperty("RunService", name, function()
			current.signals[name] = current.signals[name] or newSignal()
			return current.signals[name]
		end)
	end
	roblox.implementMethod("RunService", "BindToRenderStep", function() end)
	roblox.implementMethod("RunService", "UnbindFromRenderStep", function() end)

	roblox.implementMethod("CollectionService", "GetTagged", function(_, tag)
		local out = {}
		for _, d in current.game:GetDescendants() do
			if d:HasTag(tag) then
				table.insert(out, d)
			end
		end
		return out
	end)
	roblox.implementMethod("CollectionService", "GetInstanceAddedSignal", function(_, tag)
		current.signals["added:" .. tag] = current.signals["added:" .. tag] or newSignal()
		return current.signals["added:" .. tag]
	end)
	roblox.implementMethod("CollectionService", "GetInstanceRemovedSignal", function(_, tag)
		current.signals["removed:" .. tag] = current.signals["removed:" .. tag] or newSignal()
		return current.signals["removed:" .. tag]
	end)
	roblox.implementMethod("CollectionService", "AddTag", function(_, instance, tag)
		instance:AddTag(tag)
	end)
	roblox.implementMethod("CollectionService", "HasTag", function(_, instance, tag)
		return instance:HasTag(tag)
	end)

	roblox.implementMethod("PhysicsService", "RegisterCollisionGroup", function(_, name)
		current.groups[name] = true
	end)
	roblox.implementMethod("PhysicsService", "IsCollisionGroupRegistered", function(_, name)
		return name == "Default" or current.groups[name] == true
	end)
	roblox.implementMethod("PhysicsService", "GetRegisteredCollisionGroups", function()
		local out = { { name = "Default", mask = 0 } }
		for name in current.groups do
			table.insert(out, { name = name, mask = 0 })
		end
		return out
	end)
	roblox.implementMethod("PhysicsService", "CollisionGroupSetCollidable", function(_, a, b, value)
		current.collidable[a .. "|" .. b] = value
		current.collidable[b .. "|" .. a] = value
	end)
	roblox.implementMethod("PhysicsService", "CollisionGroupsAreCollidable", function(_, a, b)
		local value = current.collidable[a .. "|" .. b]
		if value == nil then
			return true
		end
		return value
	end)
	roblox.implementMethod("PhysicsService", "GetMaxCollisionGroups", function()
		return 32
	end)

	roblox.implementMethod("Players", "GetPlayers", function()
		return {}
	end)
	for _, name in { "PlayerAdded", "PlayerRemoving" } do
		roblox.implementProperty("Players", name, function()
			current.signals[name] = current.signals[name] or newSignal()
			return current.signals[name]
		end)
	end
	roblox.implementProperty("Players", "LocalPlayer", function()
		return nil
	end)

	roblox.implementMethod("HttpService", "GenerateGUID", function(_, braces)
		current.guid += 1
		local id = string.format("00000000-0000-4000-8000-%012d", current.guid)
		return if braces == false then id else "{" .. id .. "}"
	end)
	roblox.implementMethod("HttpService", "JSONEncode", function(_, value)
		return serde.encode("json", value)
	end)
	roblox.implementMethod("HttpService", "JSONDecode", function(_, text)
		return serde.decode("json", text)
	end)

	roblox.implementMethod("TweenService", "Create", function(_, instance, _info, goals)
		local tween = { Completed = newSignal(), PlaybackState = roblox.Enum.PlaybackState.Begin }
		function tween:Play()
			for key, value in goals do
				instance[key] = value
			end
			tween.PlaybackState = roblox.Enum.PlaybackState.Completed
			tween.Completed:Fire(roblox.Enum.PlaybackState.Completed)
		end
		function tween:Cancel() end
		function tween:Pause() end
		function tween:Destroy() end
		return tween
	end)

	-- Remotes: server/client events are harness signals; everything sent to clients is recorded in h.fired.
	for _, className in { "RemoteEvent", "UnreliableRemoteEvent" } do
		roblox.implementProperty(className, "OnServerEvent", function(self)
			local key = "server:" .. self.Name -- remote names are unique (RemoteRegistry)
			current.signals[key] = current.signals[key] or newSignal()
			return current.signals[key]
		end)
		roblox.implementProperty(className, "OnClientEvent", function(self)
			local key = "client:" .. self.Name
			current.signals[key] = current.signals[key] or newSignal()
			return current.signals[key]
		end)
		roblox.implementMethod(className, "FireClient", function(self, player, payload)
			table.insert(current.fired, { remote = self.Name, player = player, payload = payload })
		end)
		roblox.implementMethod(className, "FireAllClients", function(self, payload)
			table.insert(current.fired, { remote = self.Name, payload = payload })
		end)
	end
	roblox.implementProperty("RemoteFunction", "OnServerInvoke", function(self)
		return current.invokeHandlers[self.Name]
	end, function(self, handler)
		current.invokeHandlers[self.Name] = handler
	end)
	-- BindableEvent with Deferred signal behaviour (handlers run after the firing thread yields), matching the
	-- Workspace.SignalBehavior pin that ServerMain's place audit probes.
	roblox.implementProperty("BindableEvent", "Event", function(self)
		local key = "bindable:" .. tostring(self)
		current.signals[key] = current.signals[key] or newSignal()
		return current.signals[key]
	end)
	roblox.implementMethod("BindableEvent", "Fire", function(self, ...)
		local key = "bindable:" .. tostring(self)
		local signal = current.signals[key]
		if signal then
			local args = table.pack(...)
			task.defer(function()
				signal:Fire(table.unpack(args, 1, args.n))
			end)
		end
	end)
	roblox.implementMethod("DataModel", "BindToClose", function(_, callback)
		table.insert(current.closeHandlers, callback)
	end)

	roblox.implementMethod("Workspace", "GetServerTimeNow", function()
		return current.clock
	end)
	-- No physics in Lune: rays and overlap queries report nothing. Specs that need geometry hits use the
	-- pure-math helpers in SpatialQuery / LayoutSchema instead.
	roblox.implementMethod("Workspace", "Raycast", function()
		return nil
	end)
	roblox.implementMethod("Workspace", "GetPartBoundsInBox", function()
		return {}
	end)
	roblox.implementMethod("Workspace", "GetPartsInPart", function()
		return {}
	end)

	-- Instance helpers the builders rely on and Lune lacks.
	roblox.implementMethod("Instance", "GetAttributeChangedSignal", function(self, name)
		local key = "attr:" .. tostring(self) .. ":" .. name
		current.signals[key] = current.signals[key] or newSignal()
		return current.signals[key]
	end)
	roblox.implementMethod("Instance", "GetPropertyChangedSignal", function(self, name)
		local key = "prop:" .. tostring(self) .. ":" .. name
		current.signals[key] = current.signals[key] or newSignal()
		return current.signals[key]
	end)
	for _, name in { "ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving", "AncestryChanged", "Destroying", "AttributeChanged" } do
		roblox.implementProperty("Instance", name, function()
			return newSignal()
		end)
	end
end

function Harness.load(placePath, options)
	inject()
	options = options or {}
	local game = roblox.deserializePlace(fs.readFile(placePath))
	-- An unpublished place: no creator. Set as real values (implementProperty cannot override reflected members).
	game.CreatorId = 0
	game.CreatorType = roblox.Enum.CreatorType.User
	local h = {
		game = game,
		server = options.server ~= false,
		signals = {},
		groups = {},
		collidable = {},
		guid = 0,
		clock = 1000,
		cache = {},
		warnings = {},
		fired = {}, -- { remote, player?, payload } for every FireClient / FireAllClients
		invokeHandlers = {},
		closeHandlers = {},
	}
	current = h

	local workspace = game:GetService("Workspace")
	local env -- shared global environment for every module

	local function requireModule(module)
		if type(module) == "string" then
			error("string requires are not used in this codebase: " .. module)
		end
		assert(typeof(module) == "Instance" and module.ClassName == "ModuleScript", "require expects a ModuleScript")
		local cached = h.cache[module]
		if cached ~= nil then
			if cached == h.cache then
				error("cyclic require of " .. module:GetFullName())
			end
			return cached
		end
		h.cache[module] = h.cache -- loading sentinel
		-- luau.load only sees the environment table's own keys, so copy the globals in.
		local moduleEnv = table.clone(env)
		moduleEnv.script = module
		local chunk = luau.load(module.Source, { debugName = module:GetFullName(), environment = moduleEnv })
		local result = chunk()
		h.cache[module] = if result == nil then true else result
		return result
	end

	env = {
		game = game,
		workspace = workspace,
		Workspace = workspace,
		require = requireModule,
		Random = RandomShim,
		RaycastParams = RaycastParamsShim,
		OverlapParams = OverlapParamsShim,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		Vector3int16 = roblox.Vector3int16,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		BrickColor = roblox.BrickColor,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
		Instance = roblox.Instance,
		NumberRange = roblox.NumberRange,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		ColorSequence = roblox.ColorSequence,
		ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
		PhysicalProperties = roblox.PhysicalProperties,
		Font = roblox.Font,
		Rect = roblox.Rect,
		Ray = roblox.Ray,
		Region3 = roblox.Region3,
		Faces = roblox.Faces,
		Axes = roblox.Axes,
		TweenInfo = { new = function(...) return { ... } end },
		task = task,
		typeof = typeof,
		warn = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			table.insert(h.warnings, table.concat(parts, " "))
		end,
		print = print,
	}
	for _, name in { "math", "table", "string", "coroutine", "bit32", "utf8", "os", "debug", "buffer", "vector", "pairs", "ipairs", "next", "select", "type", "tostring", "tonumber", "pcall", "xpcall", "error", "assert", "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "rawlen", "unpack", "newproxy", "gcinfo" } do
		if env[name] == nil then
			env[name] = (_G :: any)[name]
		end
	end

	function h.path(path)
		local node = game
		for segment in string.gmatch(path, "[^%.]+") do
			local nextNode
			if node == game then
				nextNode = game:GetService(segment)
			else
				nextNode = node:FindFirstChild(segment)
			end
			assert(nextNode, "no instance at " .. path .. " (missing " .. segment .. ")")
			node = nextNode
		end
		return node
	end

	function h.require(path)
		return requireModule(h.path(path))
	end

	-- The instance-based require the game code itself uses (for runners that walk folders).
	h.requireInstance = requireModule

	-- Runs a Script / LocalScript (e.g. ServerMain) with the same environment modules get.
	function h.runScript(path)
		local instance = h.path(path)
		assert(instance:IsA("BaseScript"), path .. " is not a script")
		local scriptEnv = table.clone(env)
		scriptEnv.script = instance
		local chunk = luau.load(instance.Source, { debugName = instance:GetFullName(), environment = scriptEnv })
		chunk()
	end

	-- Fires the harness signal behind instance:GetAttributeChangedSignal(name) (the harness never fires signals on
	-- its own; Roblox would run these handlers after the attribute write).
	function h.fireAttributeChanged(instance, name)
		local signal = h.signals["attr:" .. tostring(instance) .. ":" .. name]
		if signal then
			signal:Fire()
		end
	end

	function h.advance(seconds)
		h.clock += seconds
	end

	return h
end

-- Summaries used by the CLI and specs.
function Harness.countDescendants(root, predicate)
	local count = 0
	for _, d in root:GetDescendants() do
		if predicate == nil or predicate(d) then
			count += 1
		end
	end
	return count
end

return Harness
