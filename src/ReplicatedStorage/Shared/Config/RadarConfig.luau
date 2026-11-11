--!strict
-- RadarConfig: the numbers of the radar (docs/design/game-spec-v2.md 3.2), per difficulty, and the placement rules of
-- its batteries. RadarRules is the pure logic over them; RunDirector places the batteries (pickBatteries).
--
--   A player holds up to MaxCharges and starts a run with StartCharges. A scan costs one charge: a RaiseSeconds raise,
--   then ScanSeconds of markers. Reaching a sneaking stage in ArrivalFloor with no charge gives one. A battery gives
--   BatteryCharge and BatteryTorch of the torch (with both full it stays: "Full"). Batteries per sneaking stage:
--   BatteriesBase, BatteriesPerExtraPlayer more for each player after the first, at most BatteriesMax; Candidates
--   is how many a sneaking stage's layout offers. A scan shows batteries within DotRange as dots; the ping is heard
--   within PingRange (never a noise the Creature hears); distances read MetresPerStud. NoScanStages refuse a scan.
--   Placement (RunDirector, studs walked on the floor's walk graph): one battery EntryMin..EntryMax from the entry,
--   one within StationReach of the floor's main station, every pair at least PairSpacing apart, none in a dead end;
--   checked on PlacementSeeds seeds per stage.

export type Radar = {
	MaxCharges: number,
	StartCharges: number,
	ScanSeconds: number,
	RaiseSeconds: number,
	BatteriesBase: number,
	BatteriesPerExtraPlayer: number,
	BatteriesMax: number,
	ArrivalFloor: { string }, -- the sneaking stages where arriving with no charge gives one
}

local SNEAKING: { string } = {
	"Level0_Basement",
	"Level1_Hallways",
	"Level2_Auditorium",
	"City1_Rooftops",
	"City2_Airport",
}

local Standard: Radar = table.freeze({
	MaxCharges = 3,
	StartCharges = 1,
	ScanSeconds = 8,
	RaiseSeconds = 0.4,
	BatteriesBase = 6,
	BatteriesPerExtraPlayer = 1,
	BatteriesMax = 9,
	ArrivalFloor = table.freeze(table.clone(SNEAKING)),
})

local Nightmare: Radar = table.freeze({
	MaxCharges = 3,
	StartCharges = 1,
	ScanSeconds = 6,
	RaiseSeconds = 0.4,
	BatteriesBase = 4,
	BatteriesPerExtraPlayer = 1,
	BatteriesMax = 7,
	ArrivalFloor = table.freeze({ "Level0_Basement", "City1_Rooftops" }),
})

local RadarConfig = {}

RadarConfig.Standard = Standard
RadarConfig.Nightmare = Nightmare

RadarConfig.Candidates = 36 -- battery candidates a sneaking stage's layout offers
RadarConfig.BatteryCharge = 1
RadarConfig.BatteryTorch = 45 -- battery points, as today's pickup (GameConfig.BatteryPickupCharge)
RadarConfig.DotRange = 50 -- studs: batteries a scan shows
RadarConfig.PingRange = 30 -- studs: who hears a scan's ping
RadarConfig.MetresPerStud = 0.28
RadarConfig.LedOn = 0.2 -- a battery's LED: on this long ...
RadarConfig.LedPeriod = 2 -- ... every this long
RadarConfig.NoScanStages = table.freeze({ "Level3_Roof", "Runway" })

RadarConfig.Placement = table.freeze({
	EntryMin = 20,
	EntryMax = 60,
	StationReach = 40,
	PairSpacing = 30,
	Seeds = 16,
})

-- The numbers of `difficulty` (Standard's for anything but "Nightmare").
function RadarConfig.of(difficulty: string): Radar
	return if difficulty == "Nightmare" then Nightmare else Standard
end

-- Both difficulties and the shared numbers as plain data for the website (world.json meta.radarConfig).
function RadarConfig.exportMeta(): { [string]: any }
	local function difficulty(spec: Radar): { [string]: any }
		local row: { [string]: any } = table.clone(spec :: any)
		row.ArrivalFloor = table.clone(spec.ArrivalFloor)
		return row
	end
	return {
		Standard = difficulty(Standard),
		Nightmare = difficulty(Nightmare),
		Candidates = RadarConfig.Candidates,
		BatteryCharge = RadarConfig.BatteryCharge,
		BatteryTorch = RadarConfig.BatteryTorch,
		DotRange = RadarConfig.DotRange,
		PingRange = RadarConfig.PingRange,
		MetresPerStud = RadarConfig.MetresPerStud,
		LedOn = RadarConfig.LedOn,
		LedPeriod = RadarConfig.LedPeriod,
		NoScanStages = table.clone(RadarConfig.NoScanStages),
		Placement = table.clone(RadarConfig.Placement),
	}
end

return table.freeze(RadarConfig)
