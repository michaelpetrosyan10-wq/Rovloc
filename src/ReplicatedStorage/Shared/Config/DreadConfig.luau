--!strict
-- DreadConfig: the numbers of the scary-surroundings pass. The world itself tells the story (an ordinary afternoon, a
-- boy called Danny taken by what came out of the bins, the lockdown that cut the mains at 3:31 pm, no one else got out;
-- and in 1989 the same thing, the Hale brothers): never by showing it, only by what it left behind.
--
--   * Levels: the stages Props/DreadBuilder dresses with Props/DreadKit and how densely (0..1). The Auditorium and the
--     roof are about to be rebuilt; their packages call DreadKit themselves. The Back Lot (the opening's set, by day
--     and at night) is never dressed: it stays as the opening shows it.
--   * Budget: the most parts the kit adds to one floor, and the most of them that are signature parts (not Detail:
--     drawn on every tier, Potato included). Everything else is Detail 1..3.
--   * Clock: every wall clock the kit hangs reads 3:31.
--   * Writing: the lines scrawled on the walls, per stage, in the hands of scared students (marker, chalk) and of
--     Walter Hale (1989: faded paint, his initials). The lore lines are docs/design/game-spec-v2.md 2.8's; none of them
--     names a death or shows one (I12).
--   * Light: how many of a floor's already-flickering circuits the kit marks as dying (a slow failing pulse on bulbs,
--     a struggling strike on tubes), and the shape of those waveforms. Purely how the flicker looks: the baked light,
--     which lights burn and their brightness, colour and range never change (I3).
--   * Air: a touch more haze down long runs and more dust in the torch beam on the dressed floors. HazeScale is held to
--     SightLoss: the distance at which the haze reaches a given opacity shrinks by at most that share.
--   * Ambience: the building's own sounds (web/src/game/ambience.js; the presets are SynthPresets'): one bed per floor
--     and sparse distant events, each from a point far from the listener and out of sight, never closer together than
--     MinGap, rarer and quieter while the Creature is within DuckRadius or chasing. None is a NoiseKind: the Creature
--     never hears them (I1, I3). While a cutscene plays the building holds still (no event, the bed at DuckBed) and
--     stays quiet for MinGap after it; the Back Lot gets no bed and no events.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DreadConfig = {}

export type Level = { density: number, kinds: { string }? }

-- Stage id -> how densely (0..1) it is dressed, and (for a lightly touched stage) the only kinds it gets. The lobby is
-- the way in: a few things left behind and the first writing, nothing more.
local LEVELS: { [string]: Level } = {
	Level0_Basement = table.freeze({ density = 1 }) :: Level,
	Level1_Hallways = table.freeze({ density = 1 }) :: Level,
	Lobby = table.freeze({
		density = 0.5,
		kinds = table.freeze({ "Writing", "Clock", "Notice", "Backpack", "Phone", "Papers", "Shoe", "Cobweb" }),
	}) :: Level,
}
DreadConfig.Levels = table.freeze(LEVELS)

DreadConfig.Budget = table.freeze({
	Parts = 450, -- parts added to one floor, at most
	Signature = 60, -- of them not Detail (drawn on Potato), at most
})

DreadConfig.Clock = table.freeze({ Hour = 3, Minute = 31 })

-- The words a decal or a part's name may never carry (I12: the massacre is implied, never shown).
DreadConfig.Forbidden = table.freeze({
	"blood",
	"gore",
	"corpse",
	"body",
	"bodies",
	"dead",
	"kill",
	"murder",
	"guts",
	"severed",
})

export type Hand = "Marker" | "Chalk" | "Paint" | "Scratched"
export type Line = { text: string, hand: Hand, year: number }

local function line(text: string, hand: Hand, year: number?): Line
	return table.freeze({ text = text, hand = hand, year = year or 2026 })
end

-- The lines scrawled on each stage's walls (spec 2.8's, then the story's), most important first.
local WRITING: { [string]: { Line } } = {
	Level0_Basement = table.freeze({
		line("IT CAME OUT OF THE BINS", "Marker"),
		line("IT TOOK DANNY", "Marker"),
		line("HE HEARS YOU RUN", "Paint", 1989),
		line("CRAWL →", "Paint", 1989),
		line("THE LIGHTS WENT AT 3:31", "Chalk"),
		line("IT WEARS A WHITE FACE. — W.H.", "Paint", 1989),
		line("TALLER THAN THE DOO", "Marker"),
		line("MICHAEL?", "Scratched", 1989),
		line("WHERE IS EVERYONE", "Marker"),
		line("DON'T LET IT SEE YOU", "Chalk"),
		line("HE CAN'T FIT THE CRAWLS", "Marker"),
		line("3:31", "Scratched"),
	}),
	Level1_Hallways = table.freeze({
		line("NOT DANNY", "Marker"),
		line("IT KNOWS NAMES", "Marker"),
		line("WHEN IT LOOKS AWAY — GO", "Marker"),
		line("DON'T LOOK AT HIS FACE", "Paint", 1989),
		line("IT SAID MY NAME IN HIS VOICE", "Chalk"),
		line("WE WAITED. NO ONE CAME", "Chalk"),
		line("IF YOU READ THIS DON'T", "Marker"),
		line("STAY OUT OF THE BIG HALLS", "Scratched"),
		line("IT WAS DANNY'S HOODIE", "Marker"),
		line("HE'S STILL IN HERE", "Chalk"),
		line("DON'T ANSWER IT", "Marker"),
		line("KEEP THE LIGHTS OFF", "Chalk"),
	}),
	Lobby = table.freeze({
		line("DON'T GO DOWN", "Marker"),
	}),
}
DreadConfig.Writing = table.freeze(WRITING)

-- The printed notice taped up when the lockdown began (2 lines of heading, then the body).
DreadConfig.Notice = table.freeze({
	Heading = "LOCKDOWN",
	Lines = table.freeze({
		"MAINS POWER CUT 3:31 PM",
		"STAY IN YOUR ROOM",
		"LOCK THE DOOR. LIGHTS OFF.",
		"STAFF WILL COME FOR YOU",
	}),
})

-- The child's drawing: its crayon caption.
DreadConfig.DrawingCaption = "THE TALL MAN"

DreadConfig.Light = table.freeze({
	DyingPerFloor = 4, -- already-flickering circuits marked dying on a fully dressed floor
	-- a bulb's slow failing pulse: it sags to Floor over Sag seconds, holds, then fights back up with a stutter
	Pulse = table.freeze({ Period = { 6, 13 }, Sag = 1.8, Hold = { 0.6, 2.4 }, Floor = 0.32, StutterHz = 11 }),
	-- a tube's struggling strike: steady, then bursts of rapid strikes (Hz) lasting Burst seconds
	Tube = table.freeze({ Period = { 5, 11 }, Burst = { 0.35, 1.3 }, Hz = { 9, 17 }, Low = 0.08 }),
})

DreadConfig.Air = table.freeze({
	-- multiplies the exp^2 haze coefficient on these stages: the distance to any given haze opacity shrinks by
	-- 1 - 1 / HazeScale (at most SightLoss)
	HazeScale = table.freeze({ Level0_Basement = 1.1, Level1_Hallways = 1.1 }),
	SightLoss = 0.1,
	-- more dust shows in the torch beam on these stages (the motes' brightness)
	MoteGain = table.freeze({ Level0_Basement = 1.7, Level1_Hallways = 1.5 }),
})

DreadConfig.Ambience = table.freeze({
	-- the building's bed per floor (a looped preset under the floor's drone); the director runs on these floors only
	Beds = table.freeze({
		Level0_Basement = "DreadBedBasement",
		Level1_Hallways = "DreadBedHallways",
	}),
	BedVolume = 0.85,
	-- the distant events, with their weights per stage (absent or 0: never there)
	Events = table.freeze({
		{ preset = "DreadDoorSlam", Level0_Basement = 2, Level1_Hallways = 3 },
		{ preset = "DreadMetalGroan", Level0_Basement = 3, Level1_Hallways = 1 },
		{ preset = "DreadPACrackle", Level0_Basement = 0, Level1_Hallways = 3 },
		{ preset = "DreadLockerRattle", Level0_Basement = 1, Level1_Hallways = 3 },
		{ preset = "DreadThumpAbove", Level0_Basement = 3, Level1_Hallways = 2 },
		{ preset = "DreadPhoneBuzz", Level0_Basement = 1, Level1_Hallways = 2 },
	}),
	MinGap = 25, -- seconds between two events, at least
	Gap = table.freeze({ 32, 75 }), -- seconds to the next event (uniform), when the Creature is not near
	Distance = table.freeze({ 45, 90 }), -- studs from the listener an event sounds at
	Tries = 12, -- points tried per event for one out of the listener's sight; none found: no event
	Above = 9, -- studs above the listener's floor a thump on the floor above comes from
	DuckRadius = 60, -- studs: the Creature this near (or chasing) ...
	DuckGapScale = 2.5, -- ... spaces the events this much further apart ...
	DuckVolume = 0.4, -- ... plays them this loud ...
	DuckBed = 0.5, -- ... and dips the bed to this
	EventVolume = 0.9,
})

-- The SynthPresets the ambience plays (the beds, then the events), each once.
function DreadConfig.presetNames(): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function addName(name: string)
		if not seen[name] then
			seen[name] = true
			table.insert(out, name)
		end
	end
	for _, stage in { "Level0_Basement", "Level1_Hallways" } do
		local bed = DreadConfig.Ambience.Beds[stage]
		if bed then
			addName(bed)
		end
	end
	for _, event in DreadConfig.Ambience.Events do
		addName(event.preset)
	end
	return out
end

-- Every number above as plain data for the website (world.json meta.dreadConfig), and the ambience's recipes.
function DreadConfig.exportMeta(): { [string]: any }
	local function copyLines(list: { Line }): { any }
		local out = {}
		for _, entry in list do
			table.insert(out, { text = entry.text, hand = entry.hand, year = entry.year })
		end
		return out
	end
	local writing: { [string]: any } = {}
	for stage, list in DreadConfig.Writing do
		writing[stage] = copyLines(list)
	end
	local events = {}
	for _, event in DreadConfig.Ambience.Events do
		table.insert(events, table.clone(event))
	end
	local ambience: { [string]: any } = table.clone(DreadConfig.Ambience) :: any
	ambience.Beds = table.clone(DreadConfig.Ambience.Beds)
	ambience.Events = events
	ambience.Gap = table.clone(DreadConfig.Ambience.Gap)
	ambience.Distance = table.clone(DreadConfig.Ambience.Distance)
	local light: { [string]: any } = {
		DyingPerFloor = DreadConfig.Light.DyingPerFloor,
		Pulse = table.clone(DreadConfig.Light.Pulse),
		Tube = table.clone(DreadConfig.Light.Tube),
	}
	for _, key in { "Period", "Hold" } do
		light.Pulse[key] = table.clone((DreadConfig.Light.Pulse :: any)[key])
	end
	for _, key in { "Period", "Burst", "Hz" } do
		light.Tube[key] = table.clone((DreadConfig.Light.Tube :: any)[key])
	end
	-- the ambience's recipes, value for value from SynthPresets (the website registers them from here), with their
	-- captions' text
	local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
	local Strings = require(ReplicatedStorage.Shared.Strings)
	local presets: { [string]: any } = {}
	for _, name in DreadConfig.presetNames() do
		local preset: { [string]: any } = table.clone(assert(SynthPresets.get(name), name) :: any)
		if preset.caption then
			preset.captionText = Strings.get(preset.caption)
		end
		presets[name] = preset
	end
	ambience.Presets = presets
	local levels: { [string]: any } = {}
	for stage, level in DreadConfig.Levels do
		levels[stage] = { density = level.density, kinds = if level.kinds then table.clone(level.kinds) else nil }
	end
	return {
		Levels = levels,
		Budget = table.clone(DreadConfig.Budget),
		Clock = table.clone(DreadConfig.Clock),
		Forbidden = table.clone(DreadConfig.Forbidden),
		Writing = writing,
		Notice = { Heading = DreadConfig.Notice.Heading, Lines = table.clone(DreadConfig.Notice.Lines) },
		DrawingCaption = DreadConfig.DrawingCaption,
		Light = light,
		Air = {
			HazeScale = table.clone(DreadConfig.Air.HazeScale),
			SightLoss = DreadConfig.Air.SightLoss,
			MoteGain = table.clone(DreadConfig.Air.MoteGain),
		},
		Ambience = ambience,
	}
end

return table.freeze(DreadConfig)
