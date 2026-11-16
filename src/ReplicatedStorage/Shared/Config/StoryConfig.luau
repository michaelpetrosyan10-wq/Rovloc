--!strict
-- StoryConfig: every cutscene of the game as data (docs/design/game-spec-v2.md 2.3 to 2.7), the prologue's timers
-- (4.1), the speakers and the name rules (3.4). CinematicTracks samples the timelines; NameSanitizer reads Names. Both
-- platforms play the same data: the website through world.json meta.storyConfig (exportMeta), the Roblox port the
-- same table.
--
-- A timeline is one cutscene, its times in seconds from its start:
--   origin      the CutsceneMark its positions are relative to: every pos, eye and target is in that mark's frame
--               (CFrame:PointToObjectSpace of the world point), every yaw in degrees about Y from the mark's own
--               (Roblox's: 0 looks along the mark's -Z). A timeline still to be staged (staged = false: its camera and
--               actor tracks are a later package's) may name none yet.
--   cuts        Full: one segment {at = 0, from = 0, to = length}. Short (the opening and the twist): segments of the
--               Full time {at, from, to} played back to back at `at`, one second for one second.
--   shots       {id, t0, t1, view}: view Cinematic (the camera track) or Own (each page's own first-person eye; the
--               Cutscene lock still holds).
--   camera      keys {t, eye, target, fov, ease}: ease cut (hold the previous key until this one), linear or smooth
--               (smoothstep) from the previous key.
--   actors      {actor, kind, keys, clips}. Kinds: Cast (an avatar in its CastConfig costume), Party (P1..P4: the
--               squad's own avatars in the seeded cast order), Crawler (the mask crawler: Folded, Held, Unfold, Wrap),
--               Monster (the Creature rig: Unfold, Stare, Walk, Idle, ReachIn, Hunch: hunched over a bin's gap),
--               Prop (a small set piece). Keys {t, pos, yaw} interpolate as centripetal Catmull-Rom (yaw on the
--               shortest arc, smoothstep); a key may instead name `bin` (a point of the bin the actor is bound to:
--               Path1..Path3, Over, Inside) or `attach` (another actor: pos = its pos + its yaw-turned `offset`, yaw =
--               its yaw + yaw); ease = "cut" jumps to the key at its time. Clips {t0, name, slow?}: the clip playing
--               from t0 (Hidden draws nothing), `slow` times slower than its own pace.
-- Every number is plain data as the website reads it (the export keeps six decimals): the positions and yaws worked
-- out below are rounded to six decimals here, so both platforms sample the very same numbers.
--   events      {t, kind, args}. States, the latest at or before t holding: Light {group, mode = Off | On | Flicker
--               (the group's own) | Stutter}, Prop {id, state, actor?}, Rig {actor, into} (the actor is drawn by
--               `into`'s rig from t), Rain {on}. Ranges: Fade {to, seconds} (black eased to `to`), Card {text,
--               seconds}. One-shots (fired when the clock crosses t): Sound {preset, pos?, actor?, volume?, seconds?: a
--               looped preset's length}, Shake
--               {amplitude, seconds}. An event may carry minPlayers / maxPlayers.
--   lines       {id, t, slot, speaker, channel, text, twin?, rate?, style?, minPlayers?, maxPlayers?}: a spoken line
--               starting at t, never longer than `slot`, at most Speech.MaxWords words, words / (WordsPerSecond x
--               rate) <= slot (rate: the line's own, else its speaker's web rate). Name slots {P1}..{P4} (the cast
--               order), {you} (each page's own player), {shooter}; `twin` is the nameless line used when a name is
--               missing, filtered or "The monster says names" is Off. Channels: Head (at the speaker), Ear (a whisper
--               at each listener), PA (the school's speakers, band-passed), Subtitle (written, never spoken).
--   day         keys {t, amount, tint} for dayAmount (5.3: dayAmount x tint x (ambient + sun x max(N.L, 0)) added to
--               every material), linear between keys; nil keeps the night.
--   points      Bins[slot] = {Path1, Path2, Path3, Over, Inside} (origin frame): where a party actor bound to that bin
--               runs and dives (2.4's S11: each avatar dives into its slot's bin).
--   skip        Vote (2.3: more than half voted and every first-timer among them) or SeenOnly (2.6: only once every
--               member has seen it).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CastConfig = require(ReplicatedStorage.Shared.Config.CastConfig)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

export type Vec = { x: number, y: number, z: number }
export type CameraKey = { t: number, eye: Vec, target: Vec, fov: number, ease: string }
export type ActorKey = {
	t: number,
	pos: Vec?,
	yaw: number?,
	bin: string?,
	attach: string?,
	offset: Vec?,
	ease: string?,
}
export type Clip = { t0: number, name: string, slow: number? }
export type Track = { actor: string, kind: string, keys: { ActorKey }, clips: { Clip } }
export type Event = { t: number, kind: string, args: { [string]: any }, minPlayers: number?, maxPlayers: number? }
export type Line = {
	id: string,
	t: number,
	slot: number,
	speaker: string,
	channel: string,
	text: string,
	twin: string?,
	rate: number?,
	style: string?,
	minPlayers: number?,
	maxPlayers: number?,
}
export type Shot = { id: string, t0: number, t1: number, view: string }
export type Segment = { at: number, from: number, to: number }
export type DayKey = { t: number, amount: number, tint: Vec }
export type Timeline = {
	id: string,
	set: string,
	origin: string?,
	length: number,
	staged: boolean,
	skip: string,
	cuts: { [string]: { Segment } },
	shots: { Shot },
	camera: { CameraKey },
	actors: { Track },
	events: { Event },
	lines: { Line },
	day: { DayKey }?,
	points: { [string]: any }?,
}

local function freezeDeep<T>(value: T): T
	if type(value) == "table" and not table.isfrozen(value :: any) then
		for _, child in value :: any do
			freezeDeep(child)
		end
		table.freeze(value :: any)
	end
	return value
end

local StoryConfig = {}

-- The fixed tick every timeline's start is quantised to (I8): 1 / TickRate seconds.
StoryConfig.TickRate = 30

-- The letterbox bars' share of the screen's height, each.
StoryConfig.Letterbox = 0.12

-- The skip vote (2.3): hold Skip this long; offered from From seconds in; a pass fades to the last shot over Fade.
StoryConfig.Skip = freezeDeep({ Hold = 1.0, From = 5.0, Fade = 0.6 })

-- Spoken lines (2.3): at most MaxWords words, words / (WordsPerSecond x rate) within the slot.
StoryConfig.Speech = freezeDeep({ WordsPerSecond = 2.6, MaxWords = 12 })

-- The prologue (4.1): push the lid (hold LidHold) for a ClimbOut-second climb-out, by itself AutoClimbOut seconds
-- after the hand-over (8: the player has sat in the bin since the lids shut, a quarter of a minute before it); "Climb
-- in" (hold ClimbHold) at the hatch; the ChuteCut-second cut when every Alive player is in, ChuteWait seconds after the
-- first, or MaxSeconds after the hand-over.
StoryConfig.Prologue = freezeDeep({
	LidHold = 0.6,
	ClimbOut = 1.2,
	AutoClimbOut = 8,
	ClimbHold = 0.6,
	ChuteWait = 30,
	ChuteCut = 1.6,
	MaxSeconds = 50,
})

-- Names (3.4): the first token after splitting CamelCase, underscores, digits and spaces; letters, ' and - only;
-- Min..Max characters; a token or the whole input (separators dropped, leetspeak normalised by Leet) that is Blocked,
-- or that holds one of the Stems, gives the nameless twin. Lower case throughout.
StoryConfig.Names = freezeDeep({
	Min = 2,
	Max = 12,
	Leet = {
		["0"] = "o",
		["1"] = "i",
		["3"] = "e",
		["4"] = "a",
		["5"] = "s",
		["7"] = "t",
		["8"] = "b",
		["@"] = "a",
		["$"] = "s",
		["!"] = "i",
		["|"] = "l",
	},
	Blocked = {
		"anal",
		"anus",
		"arse",
		"ass",
		"bitch",
		"boob",
		"butt",
		"cock",
		"coon",
		"crap",
		"dick",
		"dildo",
		"dyke",
		"fag",
		"gook",
		"hitler",
		"homo",
		"jizz",
		"kike",
		"nazi",
		"penis",
		"piss",
		"porn",
		"pussy",
		"rape",
		"retard",
		"semen",
		"sex",
		"slut",
		"spic",
		"tit",
		"tits",
		"twat",
		"vagina",
		"wank",
		"whore",
	},
	Stems = {
		"asshole",
		"bastard",
		"bollock",
		"cunt",
		"faggot",
		"fuck",
		"motherf",
		"nigga",
		"nigger",
		"shit",
	},
})

-- Who speaks: the subtitle's label (struck through for the monster wearing its host's name), and the voice (CastConfig's
-- actors and monsters; the PA's own here).
StoryConfig.Speakers = freezeDeep({
	Danny = { label = "DANNY", struck = false, voice = CastConfig.Actors.Danny.voice },
	TallMan = { label = "DANNY", struck = true, voice = CastConfig.Monsters.TallMan.voice },
	Gus = { label = "GUS", struck = false, voice = CastConfig.Actors.Gus.voice },
	TallJanitor = { label = "GUS", struck = true, voice = CastConfig.Monsters.TallJanitor.voice },
	PA = {
		label = "PA",
		struck = false,
		voice = { web = { pitch = 0.85, rate = 0.95 }, roblox = { pitch = 0.9, speed = 0.95 } },
	},
})

--------------------------------------------------------------------------------
-- The Back Lot's frame
--------------------------------------------------------------------------------

local LOT = WorldConfig.Sets.BackLot.origin
local LOT_YAW = 180 -- BL_Mark_Origin's yaw (BackLotBuilder.Set.marks; StoryConfig.spec checks it)
local GROUND = WorldConfig.GroundY
local WALK = GROUND -- the asphalt
local KERB = GROUND + 0.35 -- the sidewalk ring along the facade (z < 300)

-- The Back Lot set: the origin mark, and the opening's daylight (5.3: overcast, unshadowed; linear RGB).
StoryConfig.Sets = freezeDeep({
	BackLot = {
		origin = "BL_Mark_Origin",
		originYaw = LOT_YAW,
		day = {
			ambient = { x = 0.34, y = 0.35, z = 0.37 },
			sun = { x = 0.42, y = 0.42, z = 0.43 },
			sunDirection = { x = -0.36, y = 0.86, z = -0.36 },
		},
	},
})

-- Six decimals (the export's own rounding).
local function r6(x: number): number
	return math.floor(x * 1000000 + 0.5) / 1000000
end

-- A world point on the lot in BL_Mark_Origin's frame (the mark turned LOT_YAW about Y).
local function at(x: number, y: number, z: number): Vec
	local a = math.rad(LOT_YAW)
	local dx, dy, dz = x - LOT.X, y - LOT.Y, z - LOT.Z
	local c, s = math.cos(a), math.sin(a)
	-- PointToObjectSpace of a frame turned `a` about Y: the inverse rotation
	return { x = r6(c * dx - s * dz), y = r6(dy), z = r6(s * dx + c * dz) }
end

-- The world yaw (degrees) that looks from (x0, z0) to (x1, z1), in the origin's frame.
local function facing(x0: number, z0: number, x1: number, z1: number): number
	local yaw = math.deg(math.atan2(-(x1 - x0), -(z1 - z0))) - LOT_YAW
	while yaw > 180 do
		yaw -= 360
	end
	while yaw <= -180 do
		yaw += 360
	end
	return r6(yaw)
end

local function cam(t: number, eye: { number }, target: { number }, fov: number, ease: string): CameraKey
	return {
		t = t,
		eye = at(eye[1], eye[2], eye[3]),
		target = at(target[1], target[2], target[3]),
		fov = fov,
		ease = ease,
	}
end

local function key(t: number, x: number, y: number, z: number, yaw: number, ease: string?): ActorKey
	return { t = t, pos = at(x, y, z), yaw = yaw, ease = ease }
end

local function sound(t: number, preset: string, pos: { number }?, volume: number?, seconds: number?): Event
	local args: { [string]: any } = { preset = preset, volume = volume or 1, seconds = seconds }
	if pos then
		args.pos = at(pos[1], pos[2], pos[3])
	end
	return { t = t, kind = "Sound", args = args }
end

--------------------------------------------------------------------------------
-- The opening (2.4)
--------------------------------------------------------------------------------

-- Where the scene's people stand (world x, z)
local DOORS = { 60, 289.6 }
local DANNY = { 15, 319 } -- BL_Mark_Danny: the crate is in front of him, Dumpster A beyond
local CRATE = { 11.2, 19.6, 320.6 } -- the mask lying on the crate's straw
local SPOT = { 13.6, 320.6 } -- where Danny staggers into the dumpster; where the Tall Man stands up
local PARTY_AT = { 24.5, 324.2 } -- the middle of the party watching him
local DOOR_X, DOOR_Z = 60, 290.6 -- the staff doors from the lot

-- The lead's walk out of the staff doors to the gate, then back toward Danny (t, x, z)
local LEAD = {
	{ 4.2, 59.5, 290.8 },
	{ 9.0, 46.0, 305.0 },
	{ 14.5, 31.0, 313.5 },
	{ 17.5, 27.5, 321.5 },
	{ 20.0, 27.5, 331.5 },
	{ 21.2, 27.5, 334.0 },
}
-- Each party actor's place in the walking group (x, z off the lead) and where it stands to watch Danny (x, z)
local FORMATION = {
	P1 = { dx = 0, dz = 0, stand = { 23.0, 323.2 } },
	P2 = { dx = 2.2, dz = -1.3, stand = { 25.6, 321.8 } },
	P3 = { dx = -1.9, dz = -2.5, stand = { 22.4, 326.4 } },
	P4 = { dx = 1.2, dz = -3.8, stand = { 26.8, 325.4 } },
}

local function groundAt(z: number): number
	return if z < 300 then KERB else WALK
end

local function partyTrack(name: string, index: number): Track
	local f = FORMATION[name]
	local keys: { ActorKey } = {}
	local lead = LEAD[1]
	local x0, z0 = lead[2] + f.dx, lead[3] + f.dz
	table.insert(keys, key(4.0, x0, groundAt(z0), z0, facing(x0, z0, 46 + f.dx, 305 + f.dz), "cut"))
	for i, p in LEAD do
		local x, z = p[2] + f.dx, p[3] + f.dz
		local nxt = LEAD[math.min(i + 1, #LEAD)]
		local yaw = if i < #LEAD then facing(x, z, nxt[2] + f.dx, nxt[3] + f.dz) else facing(x, z, x, z + 1)
		table.insert(keys, key(p[1] + (index - 1) * 0.12, x, groundAt(z), z, yaw))
	end
	-- Danny calls; they turn and walk back to watch him
	local last = LEAD[#LEAD]
	local lx, lz = last[2] + f.dx, last[3] + f.dz
	table.insert(keys, key(22.0, lx, WALK, lz, facing(lx, lz, DANNY[1], DANNY[2])))
	local sx, sz = f.stand[1], f.stand[2]
	table.insert(keys, key(25.4 + index * 0.2, sx, WALK, sz, facing(sx, sz, DANNY[1], DANNY[2])))
	table.insert(keys, key(34.2, sx, WALK, sz, facing(sx, sz, SPOT[1], SPOT[2])))
	-- S9: they recoil a step and a half from him
	local ax, az = sx - SPOT[1], sz - SPOT[2]
	local d = math.sqrt(ax * ax + az * az)
	local rx, rz = sx + ax / d * 1.6, sz + az / d * 1.6
	table.insert(keys, key(35.0, rx, WALK, rz, facing(rx, rz, SPOT[1], SPOT[2])))
	table.insert(keys, key(43.0, rx, WALK, rz, facing(rx, rz, SPOT[1], SPOT[2])))
	-- S11: each runs for its own bin and dives in
	local stagger = (index - 1) * 0.15
	table.insert(keys, { t = 44.0 + stagger, bin = "Path1" })
	table.insert(keys, { t = 44.8 + stagger, bin = "Path2" })
	table.insert(keys, { t = 45.6 + stagger, bin = "Path3" })
	table.insert(keys, { t = 46.0 + stagger, bin = "Over" })
	table.insert(keys, { t = 46.35 + stagger, bin = "Inside" })
	local clips: { Clip } = {
		{ t0 = 0, name = "Hidden" },
		{ t0 = 4.2 + (index - 1) * 0.25, name = "Walk" },
		{ t0 = 21.2, name = "Idle" },
		{ t0 = 22.0, name = "Walk" },
		{ t0 = 25.4 + index * 0.2, name = "Idle" },
		{ t0 = 34.15, name = "Stagger" },
		{ t0 = 35.4, name = "Idle" },
		{ t0 = 43.0 + stagger, name = "Run" },
		{ t0 = 45.9 + stagger, name = "Crouch" },
		{ t0 = 46.45 + stagger, name = "Hidden" },
	}
	return { actor = name, kind = "Party", keys = keys, clips = clips }
end

-- The bins, by squad slot (BackLotBuilder.Set.bins: Dumpster A, the skip, the wheelie bin, Dumpster B): each actor's
-- run from the party's place to the bin's front, the jump over its rim and the floor inside.
local function bin(path: { { number } }, inside: { number }): { [string]: Vec }
	return {
		Path1 = at(path[1][1], WALK, path[1][2]),
		Path2 = at(path[2][1], WALK, path[2][2]),
		Path3 = at(path[3][1], WALK, path[3][2]),
		Over = at(inside[1], WALK + 3.6, inside[2]),
		Inside = at(inside[1], WALK + 0.5, inside[2]),
	}
end

local BINS = {
	bin({ { 19.0, 327.0 }, { 12.0, 327.4 }, { 5.2, 325.6 } }, { 9.4, 324.0 }),
	bin({ { 29.5, 323.0 }, { 32.5, 323.6 }, { 34.0, 324.5 } }, { 34.0, 328.0 }),
	bin({ { 34.0, 322.0 }, { 42.0, 322.6 }, { 48.0, 323.4 } }, { 48.0, 326.0 }),
	bin({ { 23.5, 325.2 }, { 22.8, 326.0 }, { 22.2, 326.8 } }, { 22.0, 330.0 }),
}

local dannyKeys: { ActorKey } = {
	key(4.0, 57.5, KERB, 292.6, facing(57.5, 292.6, DOORS[1], DOORS[2]), "cut"),
	key(9.0, 43.6, WALK, 307.0, facing(43.6, 307.0, 46.0, 305.0)),
	key(14.5, 28.4, WALK, 315.4, facing(28.4, 315.4, 31.0, 313.5)),
	key(17.0, 26.8, WALK, 319.6, facing(26.8, 319.6, 27.5, 321.5)),
	key(18.4, 25.6, WALK, 321.0, facing(25.6, 321.0, 29.0, 324.0)),
	key(19.6, 20.0, WALK, 319.6, facing(20.0, 319.6, DANNY[1], DANNY[2])),
	key(20.6, DANNY[1], WALK, DANNY[2], facing(DANNY[1], DANNY[2], CRATE[1], CRATE[3])),
	key(21.0, DANNY[1], WALK, DANNY[2], facing(DANNY[1], DANNY[2], 27.5, 334.0)),
	key(22.6, DANNY[1], WALK, DANNY[2], facing(DANNY[1], DANNY[2], 27.5, 334.0)),
	key(23.3, DANNY[1], WALK, DANNY[2], facing(DANNY[1], DANNY[2], CRATE[1], CRATE[3])),
	key(25.6, DANNY[1], WALK, DANNY[2], facing(DANNY[1], DANNY[2], CRATE[1], CRATE[3])),
	key(26.3, DANNY[1], WALK, DANNY[2], facing(DANNY[1], DANNY[2], PARTY_AT[1], PARTY_AT[2])),
	key(31.5, DANNY[1], WALK, DANNY[2], facing(DANNY[1], DANNY[2], PARTY_AT[1], PARTY_AT[2])),
	key(32.4, 14.3, WALK, 319.8, facing(14.3, 319.8, 20.0, 316.0)),
	key(33.4, SPOT[1], WALK, SPOT[2], facing(SPOT[1], SPOT[2], PARTY_AT[1], PARTY_AT[2])),
	key(36.0, SPOT[1], WALK, SPOT[2], facing(SPOT[1], SPOT[2], PARTY_AT[1], PARTY_AT[2])),
	key(38.2, SPOT[1], WALK + 0.8, SPOT[2], r6(facing(SPOT[1], SPOT[2], PARTY_AT[1], PARTY_AT[2]) + 12)),
}

local crawlerKeys: { ActorKey } = {
	key(0, CRATE[1], CRATE[2], CRATE[3], facing(CRATE[1], CRATE[3], DANNY[1], DANNY[2])),
	key(24.1, CRATE[1], CRATE[2], CRATE[3], facing(CRATE[1], CRATE[3], DANNY[1], DANNY[2])),
	{ t = 24.4, attach = "Danny", offset = { x = 0.1, y = 3.9, z = -1.0 }, yaw = 180, ease = "cut" },
	{ t = 25.0, attach = "Danny", offset = { x = 0, y = 4.9, z = -1.25 }, yaw = 180 },
	{ t = 26.2, attach = "Danny", offset = { x = 0, y = 4.9, z = -1.25 }, yaw = 180 },
	{ t = 26.6, attach = "Danny", offset = { x = 0, y = 4.95, z = -0.95 }, yaw = 0 },
	{ t = 31.5, attach = "Danny", offset = { x = 0, y = 4.95, z = -0.95 }, yaw = 0 },
	{ t = 31.75, attach = "Danny", offset = { x = 0, y = 5.0, z = -0.5 }, yaw = 0 },
	{ t = 38.6, attach = "Danny", offset = { x = 0, y = 5.0, z = -0.5 }, yaw = 0 },
}

local tallManKeys: { ActorKey } = {
	key(0, SPOT[1], WALK, SPOT[2], facing(SPOT[1], SPOT[2], PARTY_AT[1], PARTY_AT[2])),
	key(44.6, SPOT[1], WALK, SPOT[2], facing(SPOT[1], SPOT[2], PARTY_AT[1], PARTY_AT[2])),
	key(45.2, 15.4, WALK, 319.8, facing(15.4, 319.8, 24.0, 318.6)),
	-- after them along the bins' fronts; the lids are shut: it turns back to the first one
	key(46.6, 21.0, WALK, 318.8, facing(21.0, 318.8, 26.0, 318.8)),
	key(47.0, 21.0, WALK, 318.8, facing(21.0, 318.8, 12.0, 318.8)),
	key(48.5, 12.4, WALK, 319.0, facing(12.4, 319.0, 10.0, 319.4)),
	key(49.0, 10.0, WALK, 319.6, facing(10.0, 319.6, 10.0, 324.0)),
	key(49.9, 10.0, WALK, 319.6, facing(10.0, 319.6, 10.0, 324.0)),
	key(50.4, 10.0, WALK, 320.0, facing(10.0, 320.0, 10.0, 324.0)),
	key(52.35, 10.0, WALK, 320.0, facing(10.0, 320.0, 10.0, 324.0)),
	-- a scream inside the school: it turns and lopes for the staff doors; the cut in time to 3:31 PM (S14, 53.8)
	-- takes it mid-stride (by then it is long inside)
	key(52.55, 10.0, WALK, 320.0, facing(10.0, 320.0, DOOR_X, DOOR_Z)),
	key(52.75, 10.6, WALK, 319.4, facing(10.6, 319.4, 30.0, 304.0)),
	key(53.8, 25.2, WALK, 307.8, facing(25.2, 307.8, 30.0, 304.0)),
}

local sneakerKeys: { ActorKey } = {
	key(0, SPOT[1], WALK + 0.8, SPOT[2], facing(SPOT[1], SPOT[2], PARTY_AT[1], PARTY_AT[2])),
	key(38.6, SPOT[1], WALK + 0.8, SPOT[2], facing(SPOT[1], SPOT[2], PARTY_AT[1], PARTY_AT[2])),
	key(38.95, SPOT[1], WALK, SPOT[2], r6(facing(SPOT[1], SPOT[2], PARTY_AT[1], PARTY_AT[2]) + 20)),
}

local openingActors: { Track } = {
	{
		actor = "Danny",
		kind = "Cast",
		keys = dannyKeys,
		clips = {
			{ t0 = 0, name = "Hidden" },
			{ t0 = 4.2, name = "Walk" },
			{ t0 = 20.6, name = "Idle" },
			{ t0 = 21.0, name = "Point" },
			{ t0 = 22.6, name = "Idle" },
			{ t0 = 23.3, name = "Reach" },
			{ t0 = 24.4, name = "HoldUp" },
			{ t0 = 26.3, name = "HandsToFace" },
			{ t0 = 31.6, name = "Stagger" },
			{ t0 = 35.8, name = "Lifted" },
		},
	},
	partyTrack("P1", 1),
	partyTrack("P2", 2),
	partyTrack("P3", 3),
	partyTrack("P4", 4),
	{
		actor = "Crawler",
		kind = "Crawler",
		keys = crawlerKeys,
		clips = {
			{ t0 = 0, name = "Hidden" },
			{ t0 = 19.5, name = "Folded" },
			{ t0 = 24.4, name = "Held" },
			{ t0 = 28.6, name = "Unfold" },
			{ t0 = 31.75, name = "Wrap" },
			{ t0 = 38.6, name = "Hidden" },
		},
	},
	{
		actor = "TallMan",
		kind = "Monster",
		keys = tallManKeys,
		clips = {
			{ t0 = 0, name = "Hidden" },
			{ t0 = 38.6, name = "Unfold", slow = 3.25 },
			{ t0 = 41.4, name = "Stare" },
			{ t0 = 44.6, name = "Walk" },
			{ t0 = 49.0, name = "Idle" },
			{ t0 = 49.1, name = "ReachIn" },
			{ t0 = 50.0, name = "Hunch" },
			{ t0 = 52.4, name = "Stare" },
			{ t0 = 52.6, name = "Walk" },
			{ t0 = 53.8, name = "Hidden" },
		},
	},
	{
		actor = "Sneakers",
		kind = "Prop",
		keys = sneakerKeys,
		clips = { { t0 = 0, name = "Hidden" }, { t0 = 38.6, name = "Sneakers" } },
	},
}

-- The camera, shot by shot (world eye and target; the origin frame is worked out by `at`)
local openingCamera: { CameraKey } = {
	-- S1: crane down from over the roof (the bell tower's quarter) to the lot
	cam(0.0, { 40, 150, 240 }, { 22, 118, 104 }, 50, "cut"),
	cam(1.6, { 42, 112, 262 }, { 30, 70, 196 }, 52, "smooth"),
	cam(4.0, { 50, 30, 324 }, { 58, 22, 292 }, 55, "smooth"),
	-- S2: the staff doors bang open; the party walks toward the lens
	cam(4.0, { 47, 22.6, 309 }, { 58.5, 21.6, 292 }, 55, "cut"),
	cam(9.0, { 41.5, 22.6, 313 }, { 47, 21.2, 304.5 }, 55, "linear"),
	-- S3: Danny and P1, tracked from ahead and to the side
	cam(9.0, { 39.5, 22.8, 312.4 }, { 45.2, 21.8, 306.2 }, 46, "cut"),
	cam(14.5, { 25.6, 22.8, 320.2 }, { 30.4, 21.8, 314.4 }, 46, "linear"),
	-- S4: past the dumpsters toward the gate
	cam(14.5, { 31.5, 26, 346 }, { 27, 20.5, 322 }, 54, "cut"),
	cam(19.5, { 30.5, 25, 344.5 }, { 26.5, 20.5, 329 }, 54, "linear"),
	-- S5: close on Dumpster A from its front (the lid's gap, the DISCARD boxes, the crate and the pale shape on its straw),
	-- clear of Danny's walk back to it (he is off: "Wait. Guys.")
	cam(19.5, { 8.4, 22.2, 312.8 }, { 8.9, 20.8, 322.0 }, 46, "cut"),
	cam(23.0, { 8.8, 22.0, 314.0 }, { 10.0, 20.6, 321.6 }, 44, "linear"),
	-- S6: Danny lifts the face out (his profile), then turns it on the party and holds it up to his own (his front)
	cam(23.0, { 10.8, 23.0, 313.2 }, { 14.0, 21.4, 320.0 }, 54, "cut"),
	cam(25.2, { 17.4, 22.8, 313.2 }, { 14.6, 22.0, 319.6 }, 46, "smooth"),
	cam(26.8, { 20.4, 22.7, 322.6 }, { 14.8, 22.4, 319.2 }, 42, "smooth"),
	cam(28.5, { 19.8, 22.7, 322.2 }, { 14.8, 22.6, 319.2 }, 40, "linear"),
	-- S7: the insert the party never sees
	cam(28.5, { 16.9, 22.4, 320.2 }, { 15.7, 23.0, 319.4 }, 34, "cut"),
	cam(31.5, { 16.6, 22.5, 320.0 }, { 15.7, 23.0, 319.4 }, 30, "linear"),
	-- S8: the latch
	cam(31.5, { 21.4, 22.8, 322.8 }, { 14.6, 22.0, 319.8 }, 48, "cut"),
	cam(34.0, { 21.0, 22.8, 322.4 }, { 14.0, 21.6, 320.4 }, 48, "linear"),
	-- S9: wide; the party recoils, the lamp flickers, the swap in the dark
	cam(34.0, { 30.5, 27.5, 337.5 }, { 16.5, 21.0, 321.0 }, 52, "cut"),
	cam(39.0, { 29.8, 27.0, 336.6 }, { 15.8, 21.2, 321.0 }, 50, "linear"),
	-- S10: low, as it unfolds to its height where Danny stood
	cam(39.0, { 18.6, 18.9, 316.4 }, { 13.6, 25.5, 320.6 }, 62, "cut"),
	cam(43.0, { 18.2, 18.8, 316.0 }, { 13.6, 27.5, 320.6 }, 62, "linear"),
	-- S11: the party runs for the bins (from the west, clear of the lamp's pole)
	cam(43.0, { 17.0, 31.0, 308.0 }, { 25.0, 18.0, 327.0 }, 62, "cut"),
	cam(47.5, { 17.6, 30.4, 308.6 }, { 25.0, 18.0, 327.0 }, 62, "linear"),
	-- S12: inside Dumpster A, the eye at the lid's gap: its legs pass; it stops; the mask comes down to the gap
	cam(47.5, { 10.0, 22.55, 322.6 }, { 10.6, 23.6, 315.0 }, 74, "cut"),
	cam(49.9, { 10.0, 22.55, 322.6 }, { 10.4, 23.8, 315.0 }, 74, "linear"),
	cam(50.8, { 10.0, 22.5, 322.7 }, { 10.2, 23.2, 316.0 }, 70, "smooth"),
	cam(52.6, { 10.0, 22.5, 322.7 }, { 10.2, 23.3, 316.0 }, 70, "linear"),
	-- S13: through the gap, after it as it lopes for the staff doors
	cam(52.6, { 10.0, 22.55, 322.6 }, { 16.0, 23.8, 314.0 }, 68, "cut"),
	cam(53.8, { 10.0, 22.55, 322.6 }, { 30.0, 25.0, 302.0 }, 66, "smooth"),
	-- S14: 3:31 PM, the lockdown, and S15, night falling, from the same place
	cam(53.8, { 10.0, 22.55, 322.6 }, { 30.0, 25.0, 302.0 }, 66, "cut"),
	cam(59.0, { 10.0, 22.55, 322.6 }, { 31.0, 25.4, 302.0 }, 66, "linear"),
}

local openingEvents: { Event } = {
	-- the lot by day: the lamp and the strobe off, the shutter up, the school's windows lit
	{ t = 0, kind = "Light", args = { group = "Scripted:BL_Lamp", mode = "Off" } },
	{ t = 0, kind = "Light", args = { group = "Scripted:BL_Strobe", mode = "Off" } },
	{ t = 0, kind = "Prop", args = { id = "Shutter", state = "Up" } },
	{ t = 0, kind = "Prop", args = { id = "Windows1", state = "Lit" } },
	{ t = 0, kind = "Prop", args = { id = "Windows2", state = "Lit" } },
	{ t = 0, kind = "Rain", args = { on = false } },
	-- S1
	sound(0.0, "SchoolBell", nil, 0.9),
	{ t = 0.4, kind = "Card", args = { text = "ROVLOC HIGH · FRIDAY · 3:12 PM", seconds = 3.3 } },
	-- S2
	sound(4.0, "DoorBang", { 60, 21, 290 }),
	-- S5: faint clicking from the crate
	sound(19.7, "CrawlerClick", CRATE, 0.5),
	sound(20.5, "CrawlerClick", CRATE, 0.45),
	sound(21.9, "CrawlerClick", CRATE, 0.5),
	sound(22.6, "CrawlerClick", CRATE, 0.4),
	-- S7 / S8
	sound(28.7, "MusicBoxTick", { 15.6, 23, 319.4 }),
	sound(29.6, "CrawlerClick", { 15.6, 23, 319.4 }, 0.6),
	sound(30.5, "CrawlerClick", { 15.6, 23, 319.4 }, 0.7),
	sound(31.55, "MaskCrack", { 15.4, 23, 319.6 }),
	{ t = 31.6, kind = "Shake", args = { amplitude = 0.6, seconds = 0.4 } },
	-- S9: the lamp flickers, cracking and a wet breath; at 38.6 the lamp dies for 0.4 s and the rigs swap
	{ t = 34.0, kind = "Light", args = { group = "Scripted:BL_Lamp", mode = "Stutter" } },
	sound(34.3, "MaskCrack", { 13.6, 23, 320.6 }, 0.7),
	sound(35.4, "MaskCrack", { 13.6, 23, 320.6 }, 0.8),
	sound(36.6, "WetBreath", { 13.6, 23, 320.6 }),
	sound(37.6, "MaskCrack", { 13.6, 23, 320.6 }, 0.9),
	{ t = 38.6, kind = "Light", args = { group = "Scripted:BL_Lamp", mode = "Off" } },
	{ t = 38.6, kind = "Rig", args = { actor = "Danny", into = "TallMan" } },
	{ t = 39.0, kind = "Light", args = { group = "Scripted:BL_Lamp", mode = "On" } },
	-- S10: 0.8 s of silence, then the Screech
	sound(39.8, "Screech", { 13.6, 28, 320.6 }),
	{ t = 39.85, kind = "Shake", args = { amplitude = 1.2, seconds = 0.8 } },
	-- S11: lids, breathing
	sound(43.2, "BreathingPanic", nil, 0.7, 4.2),
	{ t = 45.95, kind = "Prop", args = { id = "Lid", actor = "P1", state = "Open" } },
	{ t = 46.1, kind = "Prop", args = { id = "Lid", actor = "P2", state = "Open" } },
	{ t = 46.25, kind = "Prop", args = { id = "Lid", actor = "P3", state = "Open" } },
	{ t = 46.4, kind = "Prop", args = { id = "Lid", actor = "P4", state = "Open" } },
	{ t = 46.5, kind = "Prop", args = { id = "Lid", actor = "P1", state = "Shut" } },
	{ t = 46.65, kind = "Prop", args = { id = "Lid", actor = "P2", state = "Shut" } },
	{ t = 46.8, kind = "Prop", args = { id = "Lid", actor = "P3", state = "Shut" } },
	{ t = 46.95, kind = "Prop", args = { id = "Lid", actor = "P4", state = "Shut" } },
	{ t = 46.5, kind = "Sound", args = { preset = "LidSlam", actor = "P1", volume = 1 } },
	{ t = 46.65, kind = "Sound", args = { preset = "LidSlam", actor = "P2", volume = 1 } },
	{ t = 46.8, kind = "Sound", args = { preset = "LidSlam", actor = "P3", volume = 1 } },
	{ t = 46.95, kind = "Sound", args = { preset = "LidSlam", actor = "P4", volume = 1 } },
	-- S12: inside a bin
	sound(47.7, "Breathing", nil, 0.8, 5.4),
	sound(49.1, "NailsOnMetal", { 10, 22.6, 322.2 }),
	sound(52.2, "DistantScream", { 40, 40, 270 }, 0.8),
	-- S13: it goes for the school
	sound(52.9, "FireBell", { 40, 30, 286 }, 0.7),
	-- S14: 3:31 PM, the lockdown: the school goes dark floor by floor, the shutters crash down
	{ t = 53.8, kind = "Card", args = { text = "3:31 PM", seconds = 1.7 } },
	sound(54.3, "GlassBreak", { 30, 40, 287 }, 0.7),
	{ t = 54.8, kind = "Prop", args = { id = "Windows2", state = "Dark" } },
	sound(54.9, "DistantScream", { 52, 42, 280 }, 0.6),
	{ t = 55.3, kind = "Prop", args = { id = "Windows1", state = "Dark" } },
	sound(55.4, "DistantScream", { 20, 24, 280 }, 0.5),
	{ t = 55.7, kind = "Prop", args = { id = "Shutter", state = "Down" } },
	sound(55.9, "ShutterSlam", { 60, 22, 289.4 }),
	{ t = 55.9, kind = "Light", args = { group = "Scripted:BL_Strobe", mode = "Flicker" } },
	-- S15: night falls; rain from 9:03; the bell tolls twelve as it does
	{ t = 56.5, kind = "Card", args = { text = "5:47 PM", seconds = 0.8 } },
	{ t = 57.35, kind = "Card", args = { text = "9:03 PM", seconds = 0.8 } },
	{ t = 57.35, kind = "Rain", args = { on = true } },
	sound(57.35, "RainOnLid", nil, 0.8, 3.65),
	{ t = 58.2, kind = "Card", args = { text = "11:52 PM", seconds = 0.8 } },
	-- S16: black as the view becomes each page's own; into first person inside your bin
	{ t = 58.75, kind = "Fade", args = { to = 1, seconds = 0.25 } },
	{ t = 60.2, kind = "Fade", args = { to = 0, seconds = 0.8 } },
}
for i = 0, 11 do
	table.insert(openingEvents, sound(57.4 + i * 0.3, "BellToll", nil, 0.8))
end
table.sort(openingEvents, function(a: Event, b: Event): boolean
	return a.t < b.t
end)

local openingLines: { Line } = {
	{
		id = "Opening.Frog",
		t = 4.6,
		slot = 4.0,
		speaker = "Danny",
		channel = "Head",
		text = "Did you SEE Kessler's face when the frog got loose?",
	},
	{
		id = "Opening.BackMeUp",
		t = 9.3,
		slot = 3.4,
		speaker = "Danny",
		channel = "Head",
		text = "{P1}, back me up. Funniest thing ever.",
		twin = "Back me up, guys. Funniest thing ever.",
	},
	{
		id = "Opening.Detention",
		t = 12.9,
		slot = 1.6,
		speaker = "Danny",
		channel = "Head",
		text = "Worth the detention.",
	},
	{
		id = "Opening.Pizza",
		t = 14.8,
		slot = 3.2,
		speaker = "Danny",
		channel = "Head",
		text = "Sal's? Last one there buys the pizza.",
	},
	{
		id = "Opening.Paying",
		t = 18.0,
		slot = 1.5,
		speaker = "Danny",
		channel = "Head",
		text = "{P2}, you're paying.",
		twin = "And you're paying.",
		minPlayers = 2,
	},
	{ id = "Opening.WaitUp", t = 21.0, slot = 1.6, speaker = "Danny", channel = "Head", text = "Wait. Guys. Wait up." },
	{
		id = "Opening.LookAtThis",
		t = 23.6,
		slot = 2.6,
		speaker = "Danny",
		channel = "Head",
		text = "Ha! Look at this thing.",
	},
	{
		id = "Opening.Phantom",
		t = 26.4,
		slot = 1.8,
		speaker = "Danny",
		channel = "Head",
		text = "Booo. I'm the Phantom.",
	},
	{
		id = "Opening.GetItOff",
		t = 32.0,
		slot = 2.0,
		speaker = "Danny",
		channel = "Head",
		text = "Get it— GET IT OFF!",
		style = "Muffled",
	},
	{
		id = "Opening.Close",
		t = 50.1,
		slot = 2.5,
		speaker = "TallMan",
		channel = "Ear",
		text = "I know you're close, {you}.",
		twin = "I know you're close.",
	},
	{ id = "Opening.Lockdown", t = 54.0, slot = 2.2, speaker = "PA", channel = "PA", text = "LOCKDOWN. LOCKDOWN." },
	{
		id = "Opening.You",
		t = 59.2,
		slot = 1.5,
		speaker = "TallMan",
		channel = "Ear",
		text = "{you}…",
		twin = "Still here…",
	},
}

local Opening: Timeline = {
	id = "Opening",
	set = "BackLot",
	origin = "BL_Mark_Origin",
	length = 61.0,
	staged = true,
	skip = "Vote",
	cuts = {
		Full = { { at = 0, from = 0, to = 61.0 } },
		-- S1 (0-3), S6 from "Booo." (3-6.5), S8 (6.5-9), S9 and S10 (9-15.5), S11 (15.5-18.5), S14: the lockdown
		-- (18.5-21.2), S15 from its last card ("11:52 PM", so no other card shows at the seam) and S16 (21.2-24)
		Short = {
			{ at = 0, from = 0, to = 3.0 },
			{ at = 3.0, from = 26.4, to = 29.9 },
			{ at = 6.5, from = 31.5, to = 34.0 },
			{ at = 9.0, from = 36.5, to = 43.0 },
			{ at = 15.5, from = 44.5, to = 47.5 },
			{ at = 18.5, from = 53.8, to = 56.5 },
			{ at = 21.2, from = 58.2, to = 61.0 },
		},
	},
	shots = {
		{ id = "S1", t0 = 0.0, t1 = 4.0, view = "Cinematic" },
		{ id = "S2", t0 = 4.0, t1 = 9.0, view = "Cinematic" },
		{ id = "S3", t0 = 9.0, t1 = 14.5, view = "Cinematic" },
		{ id = "S4", t0 = 14.5, t1 = 19.5, view = "Cinematic" },
		{ id = "S5", t0 = 19.5, t1 = 23.0, view = "Cinematic" },
		{ id = "S6", t0 = 23.0, t1 = 28.5, view = "Cinematic" },
		{ id = "S7", t0 = 28.5, t1 = 31.5, view = "Cinematic" },
		{ id = "S8", t0 = 31.5, t1 = 34.0, view = "Cinematic" },
		{ id = "S9", t0 = 34.0, t1 = 39.0, view = "Cinematic" },
		{ id = "S10", t0 = 39.0, t1 = 43.0, view = "Cinematic" },
		{ id = "S11", t0 = 43.0, t1 = 47.5, view = "Cinematic" },
		{ id = "S12", t0 = 47.5, t1 = 52.6, view = "Cinematic" },
		{ id = "S13", t0 = 52.6, t1 = 53.8, view = "Cinematic" },
		{ id = "S14", t0 = 53.8, t1 = 56.4, view = "Cinematic" },
		{ id = "S15", t0 = 56.4, t1 = 59.0, view = "Cinematic" },
		{ id = "S16", t0 = 59.0, t1 = 61.0, view = "Own" },
	},
	camera = openingCamera,
	actors = openingActors,
	events = openingEvents,
	lines = openingLines,
	-- S1 to S13 by overcast day (5.2: dayAmount 0.65); S14 is seventeen minutes on (a cut in the light too); S15's time-lapse
	-- orange, deep blue, the night
	day = {
		{ t = 0, amount = 0.65, tint = { x = 1, y = 1, z = 1 } },
		{ t = 53.8, amount = 0.65, tint = { x = 1, y = 1, z = 1 } },
		{ t = 53.8, amount = 0.6, tint = { x = 1, y = 0.93, z = 0.84 } },
		{ t = 56.4, amount = 0.58, tint = { x = 1, y = 0.9, z = 0.8 } },
		{ t = 57.2, amount = 0.42, tint = { x = 1, y = 0.62, z = 0.38 } },
		{ t = 58.1, amount = 0.16, tint = { x = 0.42, y = 0.52, z = 0.9 } },
		{ t = 59.0, amount = 0, tint = { x = 0.42, y = 0.52, z = 0.9 } },
	},
	points = { Bins = BINS },
}

--------------------------------------------------------------------------------
-- The endings and the twist (2.5, 2.6) and Sunrise (2.7): shots, lines, cards and set events; their camera and actor
-- tracks are staged by the packages that build their sets (§4.6, the Bahamas).
--------------------------------------------------------------------------------

local OneBullet: Timeline = {
	id = "OneBullet",
	set = "Level3_Roof",
	length = 23.0,
	staged = false,
	skip = "Vote",
	cuts = { Full = { { at = 0, from = 0, to = 23.0 } } },
	shots = {
		{ id = "A1", t0 = 0.0, t1 = 1.6, view = "Cinematic" },
		{ id = "A2", t0 = 1.6, t1 = 4.0, view = "Cinematic" },
		{ id = "A3", t0 = 4.0, t1 = 7.0, view = "Cinematic" },
		{ id = "A4", t0 = 7.0, t1 = 20.0, view = "Cinematic" },
		{ id = "A5", t0 = 20.0, t1 = 23.0, view = "Cinematic" },
	},
	camera = {},
	actors = {},
	events = {
		{ t = 0.0, kind = "Sound", args = { preset = "RevolverShot", volume = 1 } },
		{ t = 0.0, kind = "Rig", args = { actor = "TallMan", into = "TallMan" } },
		{ t = 0.05, kind = "Sound", args = { preset = "BellToll", volume = 0.5 } },
		{ t = 2.4, kind = "Prop", args = { id = "MaskHalves", state = "Dropped" } },
		{ t = 2.9, kind = "Sound", args = { preset = "MaskClatter", volume = 1 } },
		{ t = 4.0, kind = "Rig", args = { actor = "TallMan", into = "Danny" } },
		{ t = 19.5, kind = "Prop", args = { id = "DannyEyes", state = "Closed" } },
		{ t = 20.0, kind = "Prop", args = { id = "Beanie", state = "Taken" } },
		{ t = 20.0, kind = "Rain", args = { on = false } },
	},
	lines = {
		{
			id = "OneBullet.Hey",
			t = 7.5,
			slot = 2.4,
			speaker = "Danny",
			channel = "Head",
			text = "{shooter}…? Hey.",
			twin = "…Hey? Hey.",
			rate = 0.85,
			style = "Weak",
		},
		{
			id = "OneBullet.DidntMean",
			t = 10.2,
			slot = 2.8,
			speaker = "Danny",
			channel = "Head",
			text = "I didn't mean any of it.",
			rate = 0.85,
			style = "Weak",
		},
		{
			id = "OneBullet.Mom",
			t = 13.3,
			slot = 3.8,
			speaker = "Danny",
			channel = "Head",
			text = "Tell my mom I'm sorry I was late.",
			rate = 0.85,
			style = "Weak",
		},
		{
			id = "OneBullet.WaitUp",
			t = 17.4,
			slot = 2.0,
			speaker = "Danny",
			channel = "Head",
			text = "…wait up, you guys.",
			rate = 0.85,
			style = "Weak",
		},
	},
}

-- The twist runs from T + 23.0 (its t 0); control returns at its end (C = T + 44.0, or T + 31.0 after the Short cut).
local Twist: Timeline = {
	id = "Twist",
	set = "Level3_Roof",
	length = 21.0,
	staged = false,
	skip = "Vote",
	cuts = {
		Full = { { at = 0, from = 0, to = 21.0 } },
		-- J2 (2.0), J4 (2.5), J5 (2.5), J6 (1.0)
		Short = {
			{ at = 0, from = 3.0, to = 5.0 },
			{ at = 2.0, from = 13.0, to = 15.5 },
			{ at = 4.5, from = 16.5, to = 19.0 },
			{ at = 7.0, from = 19.0, to = 20.0 },
		},
	},
	shots = {
		{ id = "J1", t0 = 0.0, t1 = 3.0, view = "Cinematic" },
		{ id = "J2", t0 = 3.0, t1 = 9.0, view = "Cinematic" },
		{ id = "J3", t0 = 9.0, t1 = 13.0, view = "Cinematic" },
		{ id = "J4", t0 = 13.0, t1 = 16.5, view = "Cinematic" },
		{ id = "J5", t0 = 16.5, t1 = 19.0, view = "Cinematic" },
		{ id = "J6", t0 = 19.0, t1 = 21.0, view = "Cinematic" },
	},
	camera = {},
	actors = {},
	events = {
		{ t = 0.2, kind = "Sound", args = { preset = "KeyJingle", volume = 1 } },
		{ t = 1.6, kind = "Prop", args = { id = "Hatch", state = "Unbolted" } },
		{ t = 3.0, kind = "Prop", args = { id = "Hatch", state = "Open" } },
		{ t = 9.6, kind = "Prop", args = { id = "Torch", state = "Down" } },
		{ t = 13.2, kind = "Sound", args = { preset = "CrawlerClick", volume = 0.8 } },
		{ t = 14.8, kind = "Sound", args = { preset = "MusicBoxTick", volume = 1 } },
		{ t = 15.6, kind = "Prop", args = { id = "MaskHalves", state = "Joined" } },
		{ t = 16.75, kind = "Prop", args = { id = "Mask", state = "OnGus" } },
		{ t = 19.0, kind = "Sound", args = { preset = "Thunder", volume = 1 } },
	},
	lines = {
		{
			id = "Twist.Bell",
			t = 3.6,
			slot = 2.6,
			speaker = "Gus",
			channel = "Head",
			text = "Who's ringing my bell at midnight?",
		},
		{
			id = "Twist.UpHere",
			t = 6.3,
			slot = 2.6,
			speaker = "Gus",
			channel = "Head",
			text = "You kids can't be up here.",
		},
		{
			id = "Twist.Reyes",
			t = 9.3,
			slot = 3.2,
			speaker = "Gus",
			channel = "Head",
			text = "Is that the Reyes boy? Oh no.",
		},
		{
			id = "Twist.GetItOff",
			t = 17.0,
			slot = 2.0,
			speaker = "Gus",
			channel = "Head",
			text = "Get it— GET IT OFF—",
			rate = 1.0,
			style = "Muffled",
		},
	},
}

local Fall: Timeline = {
	id = "Fall",
	set = "Level3_Roof",
	length = 20.0,
	staged = false,
	skip = "SeenOnly",
	cuts = { Full = { { at = 0, from = 0, to = 20.0 } } },
	shots = {
		{ id = "B1", t0 = 0.0, t1 = 1.6, view = "Own" },
		{ id = "B2", t0 = 1.6, t1 = 2.0, view = "Own" },
		{ id = "B3", t0 = 2.0, t1 = 6.0, view = "Cinematic" },
		{ id = "B4", t0 = 6.0, t1 = 8.5, view = "Cinematic" },
		{ id = "B5", t0 = 8.5, t1 = 10.0, view = "Own" },
		{ id = "B6", t0 = 10.0, t1 = 16.0, view = "Own" },
		{ id = "B7", t0 = 16.0, t1 = 20.0, view = "Own" },
	},
	camera = {},
	actors = {},
	events = {
		{ t = 1.6, kind = "Fade", args = { to = 1, seconds = 0 } },
		{ t = 2.0, kind = "Fade", args = { to = 0, seconds = 0.2 } },
		{ t = 8.5, kind = "Fade", args = { to = 1, seconds = 0 } },
		{ t = 10.2, kind = "Sound", args = { preset = "BellToll", volume = 1 }, minPlayers = 2 },
		{ t = 13.0, kind = "Sound", args = { preset = "LidCreak", volume = 0.8 }, maxPlayers = 1 },
		{ t = 16.0, kind = "Card", args = { text = "THE FALL", seconds = 4.0 } },
	},
	lines = {
		{
			id = "Fall.BestFriend",
			t = 2.4,
			slot = 3.4,
			speaker = "TallMan",
			channel = "Head",
			text = "You were always my best friend, {you}.",
			twin = "You were always my best friend.",
			style = "Doubled",
		},
		{
			id = "Fall.YourTurn",
			t = 11.5,
			slot = 1.5,
			speaker = "TallMan",
			channel = "Ear",
			text = "Your turn.",
			minPlayers = 2,
		},
		{
			id = "Fall.You",
			t = 11.0,
			slot = 1.5,
			speaker = "TallMan",
			channel = "Ear",
			text = "{you}…",
			twin = "Still here…",
			maxPlayers = 1,
		},
	},
}

local Sunrise: Timeline = {
	id = "Sunrise",
	set = "Bahamas",
	length = 44.0,
	staged = false,
	skip = "Vote",
	cuts = { Full = { { at = 0, from = 0, to = 44.0 } } },
	shots = {
		{ id = "H1", t0 = 0, t1 = 4, view = "Cinematic" },
		{ id = "H2", t0 = 4, t1 = 9, view = "Cinematic" },
		{ id = "H3", t0 = 9, t1 = 15, view = "Cinematic" },
		{ id = "H4", t0 = 15, t1 = 22, view = "Cinematic" },
		{ id = "H5", t0 = 22, t1 = 29, view = "Cinematic" },
		{ id = "H6", t0 = 29, t1 = 38, view = "Cinematic" },
		{ id = "H7", t0 = 38, t1 = 44, view = "Cinematic" },
	},
	camera = {},
	actors = {},
	events = {
		{ t = 0.0, kind = "Sound", args = { preset = "EngineLoop", volume = 1 } },
		{ t = 4.5, kind = "Rain", args = { on = false } },
		{ t = 9.0, kind = "Sound", args = { preset = "SunriseChord", volume = 1 } },
		{ t = 15.4, kind = "Card", args = { text = "THE BAHAMAS · 6:41 AM", seconds = 4.0 } },
		{ t = 15.6, kind = "Sound", args = { preset = "Gulls", volume = 1 } },
		{ t = 25.4, kind = "Sound", args = { preset = "TyreChirp", volume = 1 } },
		{ t = 29.0, kind = "Sound", args = { preset = "Surf", volume = 1 } },
		{ t = 34.5, kind = "Prop", args = { id = "Beanie", state = "OnPost" } },
		{ t = 38.0, kind = "Sound", args = { preset = "SunriseChord", volume = 1 } },
		{ t = 38.6, kind = "Card", args = { text = "ROVLOC", seconds = 2.4 } },
		{ t = 41.0, kind = "Card", args = { text = "SUNRISE", seconds = 3.0 } },
	},
	lines = {
		{
			id = "Sunrise.Sals",
			t = 33.0,
			slot = 3.0,
			speaker = "P2",
			channel = "Subtitle",
			text = "…Sal's is gonna be closed, huh.",
			minPlayers = 2,
		},
	},
	-- H3: the horizon violet, pink, gold (dayAmount 0 -> 1)
	day = {
		{ t = 0, amount = 0, tint = { x = 0.5, y = 0.42, z = 0.82 } },
		{ t = 9.0, amount = 0, tint = { x = 0.5, y = 0.42, z = 0.82 } },
		{ t = 11.0, amount = 0.3, tint = { x = 0.62, y = 0.4, z = 0.78 } },
		{ t = 13.0, amount = 0.65, tint = { x = 1, y = 0.62, z = 0.66 } },
		{ t = 15.0, amount = 1, tint = { x = 1, y = 0.86, z = 0.6 } },
	},
}

StoryConfig.Order = table.freeze({ "Opening", "OneBullet", "Twist", "Fall", "Sunrise" })

StoryConfig.Timelines = freezeDeep({
	Opening = Opening,
	OneBullet = OneBullet,
	Twist = Twist,
	Fall = Fall,
	Sunrise = Sunrise,
} :: { [string]: Timeline })

-- The timeline `id` (nil for an unknown id).
function StoryConfig.timeline(id: string): Timeline?
	return StoryConfig.Timelines[id]
end

-- The story as plain data for the website (world.json meta.storyConfig).
function StoryConfig.exportMeta(): { [string]: any }
	local function plain(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local out: { [any]: any } = {}
		for k, item in value do
			out[k] = plain(item)
		end
		return out
	end
	return {
		TickRate = StoryConfig.TickRate,
		Letterbox = StoryConfig.Letterbox,
		Skip = plain(StoryConfig.Skip),
		Speech = plain(StoryConfig.Speech),
		Prologue = plain(StoryConfig.Prologue),
		Names = plain(StoryConfig.Names),
		Speakers = plain(StoryConfig.Speakers),
		Sets = plain(StoryConfig.Sets),
		Order = plain(StoryConfig.Order),
		Timelines = plain(StoryConfig.Timelines),
	}
end

return table.freeze(StoryConfig)
