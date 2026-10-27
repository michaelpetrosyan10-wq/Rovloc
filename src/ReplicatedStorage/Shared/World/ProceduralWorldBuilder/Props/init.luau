--!strict
-- Props: the catalog of Phase 2 prop builders. ProceduralWorldBuilder calls Props.registerAll once when it loads,
-- on the server and on every client, so every requirer of the builder sees the same registries. Each builder
-- module exposes register(registrar) and registers its own kinds (see PropKit for the five builder kinds).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Util.Log)

local PropKit = require(script.PropKit)

local BearTrapBuilder = require(script.BearTrapBuilder)
local ChemicalFlaskBuilder = require(script.ChemicalFlaskBuilder)
local DoorBuilder = require(script.DoorBuilder)
local FloodlightSwitchBuilder = require(script.FloodlightSwitchBuilder)
local LockerBuilder = require(script.LockerBuilder)
local ParachuteBuilder = require(script.ParachuteBuilder)
local PickupBuilder = require(script.PickupBuilder)
local PoolWaterBuilder = require(script.PoolWaterBuilder)
local SetDressingBuilder = require(script.SetDressingBuilder)
local VentGrateBuilder = require(script.VentGrateBuilder)

local log = Log.new("Props")

type Module = { register: (registrar: PropKit.Registrar) -> () }

local MODULES: { { name: string, module: Module } } = {
	{ name = "BearTrapBuilder", module = BearTrapBuilder },
	{ name = "ChemicalFlaskBuilder", module = ChemicalFlaskBuilder },
	{ name = "DoorBuilder", module = DoorBuilder },
	{ name = "FloodlightSwitchBuilder", module = FloodlightSwitchBuilder },
	{ name = "LockerBuilder", module = LockerBuilder },
	{ name = "ParachuteBuilder", module = ParachuteBuilder },
	{ name = "PickupBuilder", module = PickupBuilder },
	{ name = "PoolWaterBuilder", module = PoolWaterBuilder },
	{ name = "SetDressingBuilder", module = SetDressingBuilder },
	{ name = "VentGrateBuilder", module = VentGrateBuilder },
}

local Props = {}

-- Registers every builder's kinds. A module that fails to register is logged and skipped; the rest still load.
function Props.registerAll(registrar: PropKit.Registrar)
	for _, entry in MODULES do
		xpcall(entry.module.register, function(err: any)
			log.error("%s failed to register: %s", entry.name, tostring(err))
		end, registrar)
	end
end

return table.freeze(Props)
