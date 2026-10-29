--!strict
-- Props: the catalog of prop builders (Phase 2 and the floor objectives'). ProceduralWorldBuilder calls Props.registerAll once when it loads,
-- on the server and on every client, so every requirer of the builder sees the same registries. Each builder
-- module exposes register(registrar) and registers its own kinds (see PropKit for the five builder kinds).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage.Shared.Util.Log)

local PropKit = require(script.PropKit)

local AcidFlaskBuilder = require(script.AcidFlaskBuilder)
local BearTrapBuilder = require(script.BearTrapBuilder)
local BreakerPanelBuilder = require(script.BreakerPanelBuilder)
local ChemicalFlaskBuilder = require(script.ChemicalFlaskBuilder)
local DecayBuilder = require(script.DecayBuilder)
local DoorBuilder = require(script.DoorBuilder)
local FloodlightSwitchBuilder = require(script.FloodlightSwitchBuilder)
local FumeHoodBuilder = require(script.FumeHoodBuilder)
local FurnitureBuilder = require(script.FurnitureBuilder)
local GeneratorBuilder = require(script.GeneratorBuilder)
local HatchValveBuilder = require(script.HatchValveBuilder)
local LockBuilder = require(script.LockBuilder)
local LockerBuilder = require(script.LockerBuilder)
local ObjectiveItemBuilder = require(script.ObjectiveItemBuilder)
local ParachuteBuilder = require(script.ParachuteBuilder)
local PickupBuilder = require(script.PickupBuilder)
local PoolWaterBuilder = require(script.PoolWaterBuilder)
local ServicePipeBuilder = require(script.ServicePipeBuilder)
local SetDressingBuilder = require(script.SetDressingBuilder)
local SignageBuilder = require(script.SignageBuilder)
local VentGrateBuilder = require(script.VentGrateBuilder)

local log = Log.new("Props")

type Module = { register: (registrar: PropKit.Registrar) -> () }

local MODULES: { { name: string, module: Module } } = {
	{ name = "AcidFlaskBuilder", module = AcidFlaskBuilder },
	{ name = "BearTrapBuilder", module = BearTrapBuilder },
	{ name = "BreakerPanelBuilder", module = BreakerPanelBuilder },
	{ name = "ChemicalFlaskBuilder", module = ChemicalFlaskBuilder },
	{ name = "DecayBuilder", module = DecayBuilder },
	{ name = "DoorBuilder", module = DoorBuilder },
	{ name = "FloodlightSwitchBuilder", module = FloodlightSwitchBuilder },
	{ name = "FumeHoodBuilder", module = FumeHoodBuilder },
	{ name = "FurnitureBuilder", module = FurnitureBuilder },
	{ name = "GeneratorBuilder", module = GeneratorBuilder },
	{ name = "HatchValveBuilder", module = HatchValveBuilder },
	{ name = "LockBuilder", module = LockBuilder },
	{ name = "LockerBuilder", module = LockerBuilder },
	{ name = "ObjectiveItemBuilder", module = ObjectiveItemBuilder },
	{ name = "ParachuteBuilder", module = ParachuteBuilder },
	{ name = "PickupBuilder", module = PickupBuilder },
	{ name = "PoolWaterBuilder", module = PoolWaterBuilder },
	{ name = "ServicePipeBuilder", module = ServicePipeBuilder },
	{ name = "SetDressingBuilder", module = SetDressingBuilder },
	{ name = "SignageBuilder", module = SignageBuilder },
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
