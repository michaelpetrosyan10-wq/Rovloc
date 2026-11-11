--!strict
-- RadarRules: the radar as pure functions of plain data (docs/design/game-spec-v2.md 3.2, RadarConfig; invariant I15).
-- Charges are personal; a scan is a squad event. The Roblox server and the web host ask these questions; the website's
-- port answers them the same, checked against golden() (written to build/cache/golden.json by the export).
--
--   startCharges     the charges a run starts with
--   arrival          a sneaking stage's arrival floor: reaching one of the difficulty's ArrivalFloor stages with no
--                    charge gives one
--   battery          a battery picked up: +BatteryCharge and +BatteryTorch, each to its full; with both full it is not
--                    taken (the prompt reads "Full" and it stays)
--   refusal          why a scan is refused without cost (Hiding, Downed, Dead, Seated, Cutscene, Stage: the roof or
--                    the runway, Live: a squad scan is showing), Empty when there is no charge (the objective sheet
--                    opens), else Ok
--   scan             a scan's cost and times: one charge, the markers from the raise to RaiseSeconds + ScanSeconds
--   targets          what a scan shows for an objective state: every item still needed for the open step and every
--                    dropped one, the open step's stations not yet done, the exit once it is unlocked, the batteries
--                    within DotRange; never the Creature, never a teammate
--   batteriesPlaced  batteries a sneaking stage holds for a squad of `players`
--   guaranteedScans  the scans a run guarantees with no battery ever found (the start, then each arrival floor)
--   metres           a marker's distance in metres
--
-- Pure: no engine, no clock, no randomness; plain tables in and out.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RadarConfig = require(ReplicatedStorage.Shared.Config.RadarConfig)
local StageConfig = require(ReplicatedStorage.Shared.Config.StageConfig)

export type Item = { id: string, step: string, carried: boolean, dropped: boolean }
export type Station = { id: string, step: string, done: boolean }
export type Battery = { id: string, distance: number }
export type View = {
	openStep: string,
	items: { Item },
	stations: { Station },
	exit: { id: string, unlocked: boolean },
	batteries: { Battery },
	creature: { id: string }?, -- never shown (I15)
	teammates: { { id: string } }?, -- never shown
}
export type Target = { kind: string, id: string }
export type Asker = {
	charges: number,
	lifeState: string,
	moveState: string,
	cutscene: boolean,
	stage: string,
	squadScanLive: boolean,
}

export type GoldenRow = { name: string, fn: string, args: { any }, expect: any }

local RadarRules = {}

function RadarRules.startCharges(difficulty: string): number
	return RadarConfig.of(difficulty).StartCharges
end

function RadarRules.arrival(difficulty: string, stageId: string, charges: number): number
	local floor = RadarConfig.of(difficulty).ArrivalFloor
	if charges <= 0 and StageConfig.isSneaking(stageId) and table.find(floor, stageId) ~= nil then
		return 1
	end
	return charges
end

function RadarRules.battery(
	difficulty: string,
	charges: number,
	torch: number,
	torchMax: number
): { taken: boolean, charges: number, torch: number }
	local max = RadarConfig.of(difficulty).MaxCharges
	if charges >= max and torch >= torchMax then
		return { taken = false, charges = charges, torch = torch }
	end
	return {
		taken = true,
		charges = math.min(max, charges + RadarConfig.BatteryCharge),
		torch = math.min(torchMax, torch + RadarConfig.BatteryTorch),
	}
end

function RadarRules.refusal(asker: Asker): string
	if asker.lifeState == "Downed" then
		return "Downed"
	elseif asker.lifeState ~= "Alive" then
		return "Dead"
	elseif asker.moveState == "Hiding" then
		return "Hiding"
	elseif asker.moveState == "Seated" then
		return "Seated"
	elseif asker.cutscene then
		return "Cutscene"
	elseif table.find(RadarConfig.NoScanStages, asker.stage) ~= nil then
		return "Stage"
	elseif asker.squadScanLive then
		return "Live"
	elseif asker.charges <= 0 then
		return "Empty"
	end
	return "Ok"
end

function RadarRules.scan(
	difficulty: string,
	charges: number,
	now: number
): { charges: number, showAt: number, endsAt: number }
	local c = RadarConfig.of(difficulty)
	local showAt = now + c.RaiseSeconds
	return { charges = math.max(0, charges - 1), showAt = showAt, endsAt = showAt + c.ScanSeconds }
end

function RadarRules.targets(view: View): { Target }
	local out: { Target } = {}
	for _, item in view.items do
		if item.dropped or (item.step == view.openStep and not item.carried) then
			table.insert(out, { kind = "Item", id = item.id })
		end
	end
	for _, station in view.stations do
		if station.step == view.openStep and not station.done then
			table.insert(out, { kind = "Station", id = station.id })
		end
	end
	if view.exit.unlocked then
		table.insert(out, { kind = "Exit", id = view.exit.id })
	end
	for _, battery in view.batteries do
		if battery.distance <= RadarConfig.DotRange then
			table.insert(out, { kind = "Battery", id = battery.id })
		end
	end
	return out
end

function RadarRules.batteriesPlaced(difficulty: string, players: number): number
	local c = RadarConfig.of(difficulty)
	local extra = math.clamp(math.floor(players), 1, 4) - 1
	return math.min(c.BatteriesMax, c.BatteriesBase + c.BatteriesPerExtraPlayer * extra)
end

function RadarRules.guaranteedScans(difficulty: string): number
	local charges = RadarRules.startCharges(difficulty)
	local scans = 0
	for _, stageId in StageConfig.Sneaking do
		charges = RadarRules.arrival(difficulty, stageId, charges)
		scans += charges
		charges = 0
	end
	return scans
end

function RadarRules.metres(studs: number): number
	return math.floor(studs * RadarConfig.MetresPerStud + 0.5)
end

--------------------------------------------------------------------------------
-- Golden rows (every function's answers for the website's port to replay)
--------------------------------------------------------------------------------

local ROWS: { GoldenRow } = {}

local function row(name: string, fn: string, args: { any }, expect: any)
	table.insert(ROWS, { name = name, fn = fn, args = args, expect = expect })
end

row('startCharges 1 "Standard"', "startCharges", { "Standard" }, 1)
row('startCharges 2 "Nightmare"', "startCharges", { "Nightmare" }, 1)
row('startCharges 3 ""', "startCharges", { "" }, 1)
row('startCharges 4 "Easy"', "startCharges", { "Easy" }, 1)
row('startCharges 5 "standard"', "startCharges", { "standard" }, 1)
row('startCharges 6 "NIGHTMARE"', "startCharges", { "NIGHTMARE" }, 1)
row('startCharges 7 "Standard"', "startCharges", { "Standard" }, 1)
row('startCharges 8 "Nightmare"', "startCharges", { "Nightmare" }, 1)
row('startCharges 9 "x"', "startCharges", { "x" }, 1)
row('startCharges 10 "Nightmare"', "startCharges", { "Nightmare" }, 1)
row('startCharges 11 "Standard"', "startCharges", { "Standard" }, 1)
row('startCharges 12 "?"', "startCharges", { "?" }, 1)
row("arrival Standard Level0_Basement empty", "arrival", { "Standard", "Level0_Basement", 0 }, 1)
row("arrival Standard Level1_Hallways empty", "arrival", { "Standard", "Level1_Hallways", 0 }, 1)
row("arrival Standard Level2_Auditorium empty", "arrival", { "Standard", "Level2_Auditorium", 0 }, 1)
row("arrival Standard City1_Rooftops empty", "arrival", { "Standard", "City1_Rooftops", 0 }, 1)
row("arrival Standard City2_Airport empty", "arrival", { "Standard", "City2_Airport", 0 }, 1)
row("arrival Standard Level3_Roof empty", "arrival", { "Standard", "Level3_Roof", 0 }, 0)
row("arrival Standard BackLot empty", "arrival", { "Standard", "BackLot", 0 }, 0)
row("arrival Standard Level1_Hallways with 2", "arrival", { "Standard", "Level1_Hallways", 2 }, 2)
row("arrival Standard Level0_Basement with 1", "arrival", { "Standard", "Level0_Basement", 1 }, 1)
row("arrival Nightmare Level0_Basement empty", "arrival", { "Nightmare", "Level0_Basement", 0 }, 1)
row("arrival Nightmare Level1_Hallways empty", "arrival", { "Nightmare", "Level1_Hallways", 0 }, 0)
row("arrival Nightmare Level2_Auditorium empty", "arrival", { "Nightmare", "Level2_Auditorium", 0 }, 0)
row("arrival Nightmare City1_Rooftops empty", "arrival", { "Nightmare", "City1_Rooftops", 0 }, 1)
row("arrival Nightmare City2_Airport empty", "arrival", { "Nightmare", "City2_Airport", 0 }, 0)
row("arrival Nightmare Level3_Roof empty", "arrival", { "Nightmare", "Level3_Roof", 0 }, 0)
row("arrival Nightmare BackLot empty", "arrival", { "Nightmare", "BackLot", 0 }, 0)
row("arrival Nightmare Level1_Hallways with 2", "arrival", { "Nightmare", "Level1_Hallways", 2 }, 2)
row("arrival Nightmare Level0_Basement with 1", "arrival", { "Nightmare", "Level0_Basement", 1 }, 1)
row(
	"battery Standard charges 0 torch 10 of 100",
	"battery",
	{ "Standard", 0, 10, 100 },
	{ charges = 1, taken = true, torch = 55 }
)
row(
	"battery Standard charges 2 torch 100 of 100",
	"battery",
	{ "Standard", 2, 100, 100 },
	{ charges = 3, taken = true, torch = 100 }
)
row(
	"battery Standard charges 3 torch 60 of 100",
	"battery",
	{ "Standard", 3, 60, 100 },
	{ charges = 3, taken = true, torch = 100 }
)
row(
	"battery Standard charges 3 torch 100 of 100",
	"battery",
	{ "Standard", 3, 100, 100 },
	{ charges = 3, taken = false, torch = 100 }
)
row(
	"battery Standard charges 3 torch 100 of 150",
	"battery",
	{ "Standard", 3, 100, 150 },
	{ charges = 3, taken = true, torch = 145 }
)
row(
	"battery Standard charges 1 torch 90 of 100",
	"battery",
	{ "Standard", 1, 90, 100 },
	{ charges = 2, taken = true, torch = 100 }
)
row(
	"battery Standard charges 3 torch 150 of 150",
	"battery",
	{ "Standard", 3, 150, 150 },
	{ charges = 3, taken = false, torch = 150 }
)
row(
	"battery Nightmare charges 0 torch 10 of 100",
	"battery",
	{ "Nightmare", 0, 10, 100 },
	{ charges = 1, taken = true, torch = 55 }
)
row(
	"battery Nightmare charges 2 torch 100 of 100",
	"battery",
	{ "Nightmare", 2, 100, 100 },
	{ charges = 3, taken = true, torch = 100 }
)
row(
	"battery Nightmare charges 3 torch 60 of 100",
	"battery",
	{ "Nightmare", 3, 60, 100 },
	{ charges = 3, taken = true, torch = 100 }
)
row(
	"battery Nightmare charges 3 torch 100 of 100",
	"battery",
	{ "Nightmare", 3, 100, 100 },
	{ charges = 3, taken = false, torch = 100 }
)
row(
	"battery Nightmare charges 3 torch 100 of 150",
	"battery",
	{ "Nightmare", 3, 100, 150 },
	{ charges = 3, taken = true, torch = 145 }
)
row(
	"battery Nightmare charges 1 torch 90 of 100",
	"battery",
	{ "Nightmare", 1, 90, 100 },
	{ charges = 2, taken = true, torch = 100 }
)
row(
	"battery Nightmare charges 3 torch 150 of 150",
	"battery",
	{ "Nightmare", 3, 150, 150 },
	{ charges = 3, taken = false, torch = 150 }
)
row("refusal ok on foot", "refusal", {
	{
		charges = 1,
		cutscene = false,
		lifeState = "Alive",
		moveState = "Standing",
		squadScanLive = false,
		stage = "Level0_Basement",
	},
}, "Ok")
row("refusal ok sprinting in the city", "refusal", {
	{
		charges = 3,
		cutscene = false,
		lifeState = "Alive",
		moveState = "Sprinting",
		squadScanLive = false,
		stage = "City1_Rooftops",
	},
}, "Ok")
row("refusal empty opens the sheet", "refusal", {
	{
		charges = 0,
		cutscene = false,
		lifeState = "Alive",
		moveState = "Standing",
		squadScanLive = false,
		stage = "Level1_Hallways",
	},
}, "Empty")
row("refusal hiding", "refusal", {
	{
		charges = 2,
		cutscene = false,
		lifeState = "Alive",
		moveState = "Hiding",
		squadScanLive = false,
		stage = "Level0_Basement",
	},
}, "Hiding")
row("refusal hiding with no charge is refused, not empty", "refusal", {
	{
		charges = 0,
		cutscene = false,
		lifeState = "Alive",
		moveState = "Hiding",
		squadScanLive = false,
		stage = "Level0_Basement",
	},
}, "Hiding")
row("refusal downed", "refusal", {
	{
		charges = 2,
		cutscene = false,
		lifeState = "Downed",
		moveState = "DownedCrawling",
		squadScanLive = false,
		stage = "Level1_Hallways",
	},
}, "Downed")
row("refusal dead", "refusal", {
	{
		charges = 2,
		cutscene = false,
		lifeState = "Dead",
		moveState = "Standing",
		squadScanLive = false,
		stage = "Level1_Hallways",
	},
}, "Dead")
row("refusal spectating", "refusal", {
	{
		charges = 1,
		cutscene = false,
		lifeState = "Spectating",
		moveState = "Standing",
		squadScanLive = false,
		stage = "Level2_Auditorium",
	},
}, "Dead")
row("refusal seated", "refusal", {
	{
		charges = 2,
		cutscene = false,
		lifeState = "Alive",
		moveState = "Seated",
		squadScanLive = false,
		stage = "City2_Airport",
	},
}, "Seated")
row("refusal in a cutscene", "refusal", {
	{
		charges = 2,
		cutscene = true,
		lifeState = "Alive",
		moveState = "Standing",
		squadScanLive = false,
		stage = "Level0_Basement",
	},
}, "Cutscene")
row("refusal on the roof", "refusal", {
	{
		charges = 2,
		cutscene = false,
		lifeState = "Alive",
		moveState = "Standing",
		squadScanLive = false,
		stage = "Level3_Roof",
	},
}, "Stage")
row("refusal on the runway", "refusal", {
	{
		charges = 2,
		cutscene = false,
		lifeState = "Alive",
		moveState = "Standing",
		squadScanLive = false,
		stage = "Runway",
	},
}, "Stage")
row("refusal a squad scan is live", "refusal", {
	{
		charges = 2,
		cutscene = false,
		lifeState = "Alive",
		moveState = "Crouching",
		squadScanLive = true,
		stage = "City2_Airport",
	},
}, "Live")
row("refusal in a vent", "refusal", {
	{
		charges = 1,
		cutscene = false,
		lifeState = "Alive",
		moveState = "VentCrawling",
		squadScanLive = false,
		stage = "Level0_Basement",
	},
}, "Ok")
row("scan Standard charges 1 at 0", "scan", { "Standard", 1, 0 }, { charges = 0, endsAt = 8.4, showAt = 0.4 })
row("scan Standard charges 3 at 12.5", "scan", { "Standard", 3, 12.5 }, { charges = 2, endsAt = 20.9, showAt = 12.9 })
row("scan Standard charges 2 at 100", "scan", { "Standard", 2, 100 }, { charges = 1, endsAt = 108.4, showAt = 100.4 })
row(
	"scan Standard charges 1 at 3.3",
	"scan",
	{ "Standard", 1, 3.3 },
	{ charges = 0, endsAt = 11.7, showAt = 3.6999999999999997 }
)
row("scan Standard charges 3 at 0.1", "scan", { "Standard", 3, 0.1 }, { charges = 2, endsAt = 8.5, showAt = 0.5 })
row("scan Standard charges 2 at 61", "scan", { "Standard", 2, 61 }, { charges = 1, endsAt = 69.4, showAt = 61.4 })
row("scan Nightmare charges 1 at 0", "scan", { "Nightmare", 1, 0 }, { charges = 0, endsAt = 6.4, showAt = 0.4 })
row("scan Nightmare charges 3 at 12.5", "scan", { "Nightmare", 3, 12.5 }, { charges = 2, endsAt = 18.9, showAt = 12.9 })
row("scan Nightmare charges 2 at 100", "scan", { "Nightmare", 2, 100 }, { charges = 1, endsAt = 106.4, showAt = 100.4 })
row(
	"scan Nightmare charges 1 at 3.3",
	"scan",
	{ "Nightmare", 1, 3.3 },
	{ charges = 0, endsAt = 9.7, showAt = 3.6999999999999997 }
)
row("scan Nightmare charges 3 at 0.1", "scan", { "Nightmare", 3, 0.1 }, { charges = 2, endsAt = 6.5, showAt = 0.5 })
row("scan Nightmare charges 2 at 61", "scan", { "Nightmare", 2, 61 }, { charges = 1, endsAt = 67.4, showAt = 61.4 })
row("targets fuses: the two still needed", "targets", {
	{
		batteries = {},
		exit = { id = "Exit", unlocked = false },
		items = {
			{ carried = false, dropped = false, id = "F1", step = "FindFuses" },
			{ carried = true, dropped = false, id = "F2", step = "FindFuses" },
			{ carried = false, dropped = false, id = "F3", step = "FindFuses" },
		},
		openStep = "FindFuses",
		stations = { { done = false, id = "Panel", step = "FitFuses" } },
	},
}, { { id = "F1", kind = "Item" }, { id = "F3", kind = "Item" } })
row("targets fit fuses: the panel", "targets", {
	{
		batteries = {},
		exit = { id = "Exit", unlocked = false },
		items = { { carried = true, dropped = false, id = "F1", step = "FindFuses" } },
		openStep = "FitFuses",
		stations = { { done = false, id = "Panel", step = "FitFuses" } },
	},
}, { { id = "Panel", kind = "Station" } })
row("targets a dropped fuse shows at any step", "targets", {
	{
		batteries = {},
		exit = { id = "Exit", unlocked = false },
		items = { { carried = false, dropped = true, id = "F2", step = "FindFuses" } },
		openStep = "FitFuses",
		stations = { { done = false, id = "Panel", step = "FitFuses" } },
	},
}, { { id = "F2", kind = "Item" }, { id = "Panel", kind = "Station" } })
row("targets the breaker done: nothing", "targets", {
	{
		batteries = {},
		exit = { id = "Exit", unlocked = false },
		items = {},
		openStep = "ThrowBreaker",
		stations = { { done = true, id = "Panel", step = "ThrowBreaker" } },
	},
}, {})
row(
	"targets the exit once unlocked",
	"targets",
	{ { batteries = {}, exit = { id = "Exit", unlocked = true }, items = {}, openStep = "ReachExit", stations = {} } },
	{ { id = "Exit", kind = "Exit" } }
)
row(
	"targets the exit stays hidden while locked",
	"targets",
	{ { batteries = {}, exit = { id = "Exit", unlocked = false }, items = {}, openStep = "UnlockExit", stations = {} } },
	{}
)
row("targets batteries within 50", "targets", {
	{
		batteries = {
			{ distance = 49.9, id = "B1" },
			{ distance = 50, id = "B2" },
			{ distance = 50.1, id = "B3" },
			{ distance = 120, id = "B4" },
		},
		exit = { id = "Exit", unlocked = false },
		items = { { carried = false, dropped = false, id = "Keys", step = "FindKeys" } },
		openStep = "FindKeys",
		stations = {},
	},
}, { { id = "Keys", kind = "Item" }, { id = "B1", kind = "Battery" }, { id = "B2", kind = "Battery" } })
row("targets feeders: the open ones", "targets", {
	{
		batteries = {},
		exit = { id = "Exit", unlocked = false },
		items = {},
		openStep = "CloseFeeders",
		stations = {
			{ done = true, id = "F1", step = "CloseFeeders" },
			{ done = false, id = "F4", step = "CloseFeeders" },
			{ done = false, id = "F6", step = "CloseFeeders" },
		},
	},
}, { { id = "F4", kind = "Station" }, { id = "F6", kind = "Station" } })
row("targets never the monster or a teammate", "targets", {
	{
		batteries = { { distance = 10, id = "B1" } },
		creature = { id = "Creature" },
		exit = { id = "Exit", unlocked = false },
		items = { { carried = false, dropped = false, id = "C1", step = "FindFuel" } },
		openStep = "FindFuel",
		stations = {},
		teammates = { { id = "P2" }, { id = "P3" } },
	},
}, { { id = "C1", kind = "Item" }, { id = "B1", kind = "Battery" } })
row("targets the wing with two cans carried", "targets", {
	{
		batteries = {},
		exit = { id = "Exit", unlocked = false },
		items = {
			{ carried = true, dropped = false, id = "C1", step = "FindFuel" },
			{ carried = true, dropped = false, id = "C2", step = "FindFuel" },
		},
		openStep = "FuelPlane",
		stations = {
			{ done = false, id = "Wing", step = "FuelPlane" },
			{ done = false, id = "Switch", step = "OpenHangar" },
		},
	},
}, { { id = "Wing", kind = "Station" } })
row("targets the hangar switch", "targets", {
	{
		batteries = { { distance = 0, id = "B9" } },
		exit = { id = "Exit", unlocked = false },
		items = {},
		openStep = "OpenHangar",
		stations = {
			{ done = true, id = "Wing", step = "FuelPlane" },
			{ done = false, id = "Switch", step = "OpenHangar" },
		},
	},
}, { { id = "Switch", kind = "Station" }, { id = "B9", kind = "Battery" } })
row("targets the cabin and the open exit", "targets", {
	{
		batteries = {},
		exit = { id = "Exit", unlocked = true },
		items = {},
		openStep = "Board",
		stations = { { done = false, id = "Cabin", step = "Board" } },
	},
}, { { id = "Cabin", kind = "Station" }, { id = "Exit", kind = "Exit" } })
row(
	"targets nothing at all",
	"targets",
	{ { batteries = {}, exit = { id = "Exit", unlocked = false }, items = {}, openStep = "FindFuses", stations = {} } },
	{}
)
row("batteriesPlaced Standard 1 players", "batteriesPlaced", { "Standard", 1 }, 6)
row("batteriesPlaced Standard 2 players", "batteriesPlaced", { "Standard", 2 }, 7)
row("batteriesPlaced Standard 3 players", "batteriesPlaced", { "Standard", 3 }, 8)
row("batteriesPlaced Standard 4 players", "batteriesPlaced", { "Standard", 4 }, 9)
row("batteriesPlaced Standard 0 players", "batteriesPlaced", { "Standard", 0 }, 6)
row("batteriesPlaced Standard 6 players", "batteriesPlaced", { "Standard", 6 }, 9)
row("batteriesPlaced Standard 2.5 players", "batteriesPlaced", { "Standard", 2.5 }, 7)
row("batteriesPlaced Nightmare 1 players", "batteriesPlaced", { "Nightmare", 1 }, 4)
row("batteriesPlaced Nightmare 2 players", "batteriesPlaced", { "Nightmare", 2 }, 5)
row("batteriesPlaced Nightmare 3 players", "batteriesPlaced", { "Nightmare", 3 }, 6)
row("batteriesPlaced Nightmare 4 players", "batteriesPlaced", { "Nightmare", 4 }, 7)
row("batteriesPlaced Nightmare 0 players", "batteriesPlaced", { "Nightmare", 0 }, 4)
row("batteriesPlaced Nightmare 6 players", "batteriesPlaced", { "Nightmare", 6 }, 7)
row("batteriesPlaced Nightmare 2.5 players", "batteriesPlaced", { "Nightmare", 2.5 }, 5)
row('guaranteedScans 1 "Standard"', "guaranteedScans", { "Standard" }, 5)
row('guaranteedScans 2 "Nightmare"', "guaranteedScans", { "Nightmare" }, 2)
row('guaranteedScans 3 ""', "guaranteedScans", { "" }, 5)
row('guaranteedScans 4 "Easy"', "guaranteedScans", { "Easy" }, 5)
row('guaranteedScans 5 "standard"', "guaranteedScans", { "standard" }, 5)
row('guaranteedScans 6 "NIGHTMARE"', "guaranteedScans", { "NIGHTMARE" }, 5)
row('guaranteedScans 7 "Standard"', "guaranteedScans", { "Standard" }, 5)
row('guaranteedScans 8 "Nightmare"', "guaranteedScans", { "Nightmare" }, 2)
row('guaranteedScans 9 "x"', "guaranteedScans", { "x" }, 5)
row('guaranteedScans 10 "Nightmare"', "guaranteedScans", { "Nightmare" }, 2)
row('guaranteedScans 11 "Standard"', "guaranteedScans", { "Standard" }, 5)
row('guaranteedScans 12 "?"', "guaranteedScans", { "?" }, 5)
row("metres 0", "metres", { 0 }, 0)
row("metres 1", "metres", { 1 }, 0)
row("metres 1.79", "metres", { 1.79 }, 1)
row("metres 1.8", "metres", { 1.8 }, 1)
row("metres 10", "metres", { 10 }, 3)
row("metres 35.7", "metres", { 35.7 }, 10)
row("metres 50", "metres", { 50 }, 14)
row("metres 100", "metres", { 100 }, 28)
row("metres 178.5", "metres", { 178.5 }, 50)
row("metres 400", "metres", { 400 }, 112)
row("metres 3.57", "metres", { 3.57 }, 1)
row("metres 0.5", "metres", { 0.5 }, 0)

-- The golden rows: { name, fn, args, expect } with expect what RadarRules[fn](table.unpack(args)) returns.
function RadarRules.golden(): { GoldenRow }
	return ROWS
end

return table.freeze(RadarRules)
