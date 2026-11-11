--!strict
-- Props: the catalog of prop builders. ProceduralWorldBuilder calls Props.registerAll once when it loads, on the server
-- and on every client, so every requirer of the builder sees the same registries. Each builder module exposes
-- register(registrar) and registers its own kinds (see PropKit for the five builder kinds).
--
-- The catalog is this folder: every child ModuleScript that returns a table with a `register` function is a builder,
-- registered in the order of its name (a fixed, sorted order, the same on Roblox and under the Lune harness). The kit
-- modules (PropKit, ObjectiveKit, WallPlanner) have no `register` and are skipped. Adding a prop builder means adding
-- its own file here and nothing else.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Util.Log)

local PropKit = require(script.PropKit)

local log = Log.new("Props")

type Module = { register: (registrar: PropKit.Registrar) -> () }

local Props = {}

-- The builder modules of this folder, sorted by name: { name, module } for every child whose module registers kinds.
function Props.modules(): { { name: string, module: Module } }
	local children: { ModuleScript } = {}
	for _, child in script:GetChildren() do
		if child:IsA("ModuleScript") then
			table.insert(children, child)
		end
	end
	table.sort(children, function(a: ModuleScript, b: ModuleScript): boolean
		return a.Name < b.Name
	end)
	local out: { { name: string, module: Module } } = {}
	for _, child in children do
		local ok, loaded = pcall(require, child)
		if not ok then
			log.error("%s failed to load: %s", child.Name, tostring(loaded))
		elseif type(loaded) == "table" and type((loaded :: any).register) == "function" then
			table.insert(out, { name = child.Name, module = (loaded :: any) :: Module })
		end
	end
	return out
end

-- Registers every builder's kinds. A module that fails to load or register is logged and skipped; the rest still load.
function Props.registerAll(registrar: PropKit.Registrar)
	for _, entry in Props.modules() do
		xpcall(entry.module.register, function(err: any)
			log.error("%s failed to register: %s", entry.name, tostring(err))
		end, registrar)
	end
end

return table.freeze(Props)
