--!strict
-- The story's data and its sampler (docs/design/game-spec-v2.md 2.3 to 2.7, 4.1; invariants I3, I8, I11, I12):
-- StoryConfig's timelines and CinematicTracks' golden rows, then the spec's numbers asserted on their own (written here
-- from the spec's text, never read back from StoryConfig): the cuts' lengths, every line in its slot and none
-- overlapping, the opening's lines at their starts, the Short cut's pieces, the skip vote matrix, the prologue's
-- timers, the Back Lot's marks and bins; all three modules pure.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BackLotBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.BackLotBuilder)
local CinematicTracks = require(ReplicatedStorage.Shared.Sequence.CinematicTracks)
local StoryConfig = require(ReplicatedStorage.Shared.Config.StoryConfig)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local RuleGolden = require(script.Parent.Parent.RuleGolden)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local EVENT_KINDS =
	{ Sound = true, Shake = true, Light = true, Prop = true, Rig = true, Rain = true, Fade = true, Card = true }

-- The rate a line is spoken at: its own, else its speaker's web rate; a party speaker's subtitle-only line at 1.
local function rateOf(line: StoryConfig.Line): number
	if line.rate then
		return line.rate
	end
	local speaker = (StoryConfig.Speakers :: any)[line.speaker]
	return if speaker then speaker.voice.web.rate else 1
end

-- The opening's lines from 2.4's table: start, slot, text.
local OPENING_LINES: { { any } } = {
	{ 4.6, 4.0, "Did you SEE Kessler's face when the frog got loose?" },
	{ 9.3, 3.4, "{P1}, back me up. Funniest thing ever." },
	{ 12.9, 1.6, "Worth the detention." },
	{ 14.8, 3.2, "Sal's? Last one there buys the pizza." },
	{ 18.0, 1.5, "{P2}, you're paying." },
	{ 21.0, 1.6, "Wait. Guys. Wait up." },
	{ 23.6, 2.6, "Ha! Look at this thing." },
	{ 26.4, 1.8, "Booo. I'm the Phantom." },
	{ 32.0, 2.0, "Get it— GET IT OFF!" },
	{ 50.1, 2.5, "I know you're close, {you}." },
	{ 54.0, 2.2, "LOCKDOWN. LOCKDOWN." },
	{ 59.2, 1.5, "{you}…" },
}

return {
	["golden rows: every function answers its rows, plain data"] = function(t: Expect)
		local rows = RuleGolden.check(t, CinematicTracks, "CinematicTracks")
		t.truthy(#rows >= 12, "at least twelve rows")
	end,

	["pure: no engine, clock or randomness in the sampler or the story's data"] = function(t: Expect)
		RuleGolden.checkPure(t, ReplicatedStorage.Shared.Sequence.CinematicTracks)
		RuleGolden.checkPure(t, ReplicatedStorage.Shared.Config.StoryConfig)
	end,

	["the spec's lengths: the opening 61.0 [Short 24.0], the twist 21.0 [Short 8.0], 23.0, 20.0, 44.0"] = function(
		t: Expect
	)
		t.near(CinematicTracks.length("Opening", "Full"), 61.0, 1e-9)
		t.near(CinematicTracks.length("Opening", "Short"), 24.0, 1e-9)
		t.near(CinematicTracks.length("Twist", "Full"), 21.0, 1e-9)
		t.near(CinematicTracks.length("Twist", "Short"), 8.0, 1e-9)
		t.near(CinematicTracks.length("OneBullet", "Full"), 23.0, 1e-9)
		t.near(CinematicTracks.length("Fall", "Full"), 20.0, 1e-9)
		t.near(CinematicTracks.length("Sunrise", "Full"), 44.0, 1e-9)
		-- C = T + 44.0 after the Full twist, T + 31.0 after the Short one (A1..A5 then the twist)
		t.near(CinematicTracks.length("OneBullet", "Full") + CinematicTracks.length("Twist", "Full"), 44.0, 1e-9)
		t.near(CinematicTracks.length("OneBullet", "Full") + CinematicTracks.length("Twist", "Short"), 31.0, 1e-9)
	end,

	["the opening's Short cut: S1 0-3, Booo 3-6.5, S8 6.5-9, S9 and S10 9-15.5, S11, the lockdown, midnight"] = function(
		t: Expect
	)
		local short = StoryConfig.Timelines.Opening.cuts.Short
		local ats = { 0, 3.0, 6.5, 9.0, 15.5, 18.5, 21.2 }
		t.eq(#short, #ats, "seven pieces")
		for i, at in ats do
			t.near(short[i].at, at, 1e-9, "piece " .. i)
		end
		-- each piece starts in its shot: S1, S6 at "Booo.", S8, S9, S11, S14 (the lockdown), S15's last card into S16
		t.near(short[1].from, 0, 1e-9)
		t.near(short[2].from, 26.4, 1e-9, "from Booo.")
		t.near(short[3].from, 31.5, 1e-9)
		t.truthy(short[4].from >= 34.0 and short[4].to == 43.0, "S9 and S10")
		t.truthy(short[5].from >= 43.0 and short[5].to <= 47.5, "S11")
		t.truthy(short[6].from == 53.8 and short[6].to == 56.5, "S14, whole, to the 5:47 card's start")
		t.truthy(short[7].from == 58.2 and short[7].to == 61.0, "from the 11:52 card's start through S16")
		-- a seam never shows a card's tail: each piece starts where no card is up, or at a card's own start
		for i, piece in short do
			local up = CinematicTracks.sample("Opening", "Full", piece.from, { P1 = 1 }).card
			t.truthy(up == nil or math.abs(up.age) < 1e-9, "piece " .. i .. " opens on a card's tail")
		end
		-- the Short cut keeps "Booo.", the latch's scream, the lockdown and the last whisper
		local kept: { [string]: boolean } = {}
		for _, line in CinematicTracks.lines("Opening", "Short", -1, 24, 1) do
			kept[line.id] = true
		end
		t.truthy(kept["Opening.Phantom"] and kept["Opening.GetItOff"], "Booo. and the latch")
		t.truthy(kept["Opening.Lockdown"] and kept["Opening.You"], "the lockdown and the last line")
	end,

	["the opening's tail: the lids shut by 47, the hand-over 14 s on, something on screen at least every 3 s"] = function(
		t: Expect
	)
		local opening = StoryConfig.Timelines.Opening
		local lidsShut = 0
		for _, e in opening.events do
			if e.kind == "Prop" and e.args.id == "Lid" and e.args.state == "Shut" then
				lidsShut = math.max(lidsShut, e.t)
			end
		end
		t.truthy(lidsShut > 46 and lidsShut < 47, "the last lid shuts at " .. lidsShut)
		t.truthy(opening.length - lidsShut <= 14.5, "from the lids to the hand-over")
		-- what changes the picture from the lids on: a shot's start, an actor's clip, a prop, a light, the rain, a
		-- card, a fade, a subtitle; never 3 s without one
		local beats: { number } = { lidsShut, opening.length }
		for _, shot in opening.shots do
			table.insert(beats, shot.t0)
		end
		for _, track in opening.actors do
			for _, clip in track.clips do
				table.insert(beats, clip.t0)
			end
		end
		for _, e in opening.events do
			if e.kind ~= "Sound" and e.kind ~= "Shake" then
				table.insert(beats, e.t)
			end
		end
		for _, line in opening.lines do
			table.insert(beats, line.t)
		end
		table.sort(beats)
		local last = lidsShut
		for _, at in beats do
			if at >= lidsShut then
				t.truthy(at - last <= 3.0 + 1e-9, string.format("nothing from %.2f to %.2f", last, at))
				last = at
			end
		end
	end,

	["the opening's lines: each at its start in its slot, as 2.4's table writes it"] = function(t: Expect)
		local lines = StoryConfig.Timelines.Opening.lines
		for _, want in OPENING_LINES do
			local found = false
			for _, line in lines do
				if math.abs(line.t - want[1]) < 1e-9 then
					found = true
					t.near(line.slot, want[2], 1e-9, line.id .. " slot")
					t.eq(line.text, want[3], line.id)
				end
			end
			t.truthy(found, "a line at " .. want[1])
		end
	end,

	["every line fits its slot (words / (2.6 x rate)), at most 12 words, a twin for every name slot"] = function(
		t: Expect
	)
		for id, timeline in StoryConfig.Timelines do
			for _, line in timeline.lines do
				local words = CinematicTracks.words(line.text)
				t.truthy(words <= 12, line.id .. ": at most 12 words")
				t.truthy(words / (2.6 * rateOf(line)) <= line.slot + 1e-9, line.id .. ": fits its slot")
				t.truthy(CinematicTracks.lineFits(line.text, rateOf(line), line.slot), line.id .. ": lineFits")
				local named = string.find(line.text, "{", 1, true) ~= nil
				if named and not (line.minPlayers and string.find(line.text, "{P", 1, true)) then
					t.truthy(line.twin ~= nil, line.id .. ": a nameless twin")
				end
				if line.twin then
					local twinWords = CinematicTracks.words(line.twin)
					t.truthy(twinWords / (2.6 * rateOf(line)) <= line.slot + 1e-9, line.id .. ": the twin fits")
				end
				t.truthy(
					line.t >= 0 and line.t + line.slot <= timeline.length + 1e-9,
					id .. "/" .. line.id .. " inside"
				)
			end
		end
	end,

	["no two lines overlap, for every squad size"] = function(t: Expect)
		for id, timeline in StoryConfig.Timelines do
			for players = 1, 4 do
				local heard = CinematicTracks.lines(id, "Full", -1, timeline.length, players)
				for i = 2, #heard do
					t.truthy(
						heard[i].at >= heard[i - 1].at + heard[i - 1].slot - 1e-9,
						string.format("%s, %d players: %s after %s", id, players, heard[i].id, heard[i - 1].id)
					)
				end
			end
		end
	end,

	["solo skips the lines that need P2"] = function(t: Expect)
		local solo, duo = {}, {}
		for _, line in CinematicTracks.lines("Opening", "Full", -1, 61, 1) do
			solo[line.id] = true
		end
		for _, line in CinematicTracks.lines("Opening", "Full", -1, 61, 2) do
			duo[line.id] = true
		end
		t.truthy(not solo["Opening.Paying"] and duo["Opening.Paying"], "{P2}, you're paying.")
	end,

	["the skip vote: hold 1.0 s from 5 s in; more than half and every first-timer; Fall only once all have seen it"] = function(
		t: Expect
	)
		t.near(StoryConfig.Skip.Hold, 1.0, 1e-9)
		t.near(StoryConfig.Skip.Fade, 0.6, 1e-9)
		t.falsy(CinematicTracks.skipOffered("Opening", "Full", 4.99))
		t.truthy(CinematicTracks.skipOffered("Opening", "Full", 5.0))
		-- the matrix: votes / players
		local matrix: { { any } } = { { 1, 1, true }, { 1, 2, false }, { 2, 3, true }, { 2, 4, false }, { 3, 4, true } }
		local ids = { "a", "b", "c", "d" }
		for _, case in matrix do
			local voters = table.move(ids, 1, case[1], 1, {})
			t.eq(CinematicTracks.skipPasses("Opening", case[2], voters, {}), case[3], case[1] .. "/" .. case[2])
			-- a first-timer who has not voted holds it
			local outsider = ids[case[2]]
			local voted = table.find(voters, outsider) ~= nil
			t.eq(
				CinematicTracks.skipPasses("Opening", case[2], voters, { outsider }),
				case[3] and voted,
				case[1] .. "/" .. case[2] .. " with a first-timer"
			)
		end
		t.falsy(CinematicTracks.skipOffered("Opening", "Full", 59.0), "never in the last shot")
		t.near(CinematicTracks.skipTarget("Opening", "Full"), 59.0, 1e-9, "Full: to S16")
		t.near(CinematicTracks.skipTarget("Opening", "Short"), 22.0, 1e-9, "Short: to S16")
		t.falsy(CinematicTracks.skipPasses("Fall", 2, { "a", "b" }, { "b" }), "the fall: not before all have seen it")
	end,

	["Full or Short: Short once every member has seen it and nobody wants Full"] = function(t: Expect)
		local seen = { seenFull = true, wantsFull = false }
		t.eq(CinematicTracks.cutFor("Opening", { seen, seen }), "Short")
		t.eq(CinematicTracks.cutFor("Opening", { seen, { seenFull = false, wantsFull = false } }), "Full")
		t.eq(CinematicTracks.cutFor("Opening", { seen, { seenFull = true, wantsFull = true } }), "Full")
		t.eq(CinematicTracks.cutFor("Twist", { seen }), "Short")
		t.eq(CinematicTracks.cutFor("Fall", { seen }), "Full", "no Short cut")
	end,

	["the prologue's timers: a 0.6 s lid, 1.2 s out, by itself at 8 s; the chute's 30 s, a 1.6 s cut; 50 s at most"] = function(
		t: Expect
	)
		local p = StoryConfig.Prologue
		t.near(p.LidHold, 0.6, 1e-9)
		t.near(p.ClimbOut, 1.2, 1e-9)
		t.near(p.ClimbHold, 0.6, 1e-9)
		t.near(p.ChuteCut, 1.6, 1e-9)
		t.near(p.AutoClimbOut, 8, 1e-9)
		t.near(CinematicTracks.climbOutAt(61), 69, 1e-9)
		t.near(CinematicTracks.chuteCutAt(61, 73, -1), 103, 1e-9, "30 s after the first")
		t.near(CinematicTracks.chuteCutAt(61, 73, 78), 78, 1e-9, "everyone in")
		t.near(CinematicTracks.chuteCutAt(61, -1, -1), 111, 1e-9, "at most 50 s")
		t.eq(p.LidHold, BackLotBuilder.LidHold, "the lid's prompt holds as long")
		t.eq(p.ClimbHold, BackLotBuilder.ClimbHold, "the hatch's prompt holds as long")
	end,

	["the Back Lot's frame: the origin mark, and a bin per slot where the builder puts it"] = function(t: Expect)
		local set = StoryConfig.Sets.BackLot
		local origin = nil
		for _, mark in BackLotBuilder.Set.marks do
			if mark.id == set.origin then
				origin = mark
			end
		end
		t.truthy(origin ~= nil, "the origin mark is built")
		if origin then
			t.near(origin.yaw, set.originYaw, 1e-9, "its yaw")
			t.near((origin.pos - WorldConfig.Sets.BackLot.origin).Magnitude, 0, 1e-6, "its place")
		end
		local opening = StoryConfig.Timelines.Opening
		t.eq(opening.origin, set.origin)
		local bins = (opening.points :: any).Bins
		for _, b in BackLotBuilder.Set.bins do
			local inside = bins[b.slot].Inside
			-- the origin frame: x and z mirrored about the mark (yaw 180)
			local world = origin and origin.pos or WorldConfig.Sets.BackLot.origin
			t.near(world.X - inside.x, b.x, 0.8, "bin " .. b.slot .. " x")
			t.near(world.Z - inside.z, b.z, 0.8, "bin " .. b.slot .. " z")
		end
	end,

	["I3 and I12: a cutscene only shows and sounds; no blood or gore anywhere in the story"] = function(t: Expect)
		for id, timeline in StoryConfig.Timelines do
			for _, e in timeline.events do
				t.truthy(EVENT_KINDS[e.kind] == true, id .. ": event " .. e.kind)
				local text = string.lower(tostring(e.args.preset or "") .. tostring(e.args.id or ""))
				t.falsy(string.find(text, "blood", 1, true) or string.find(text, "gore", 1, true), id .. " " .. text)
			end
			for _, line in timeline.lines do
				t.falsy(string.find(string.lower(line.text), "blood", 1, true), line.id)
			end
		end
	end,

	["a staged timeline has an origin, a camera and actors; every shot has a view"] = function(t: Expect)
		for id, timeline in StoryConfig.Timelines do
			if timeline.staged then
				t.truthy(timeline.origin ~= nil and #timeline.camera > 0 and #timeline.actors > 0, id)
			end
			for _, shot in timeline.shots do
				t.truthy(shot.view == "Cinematic" or shot.view == "Own", id .. " " .. shot.id)
			end
			t.near(timeline.shots[#timeline.shots].t1, timeline.length, 1e-9, id .. ": the shots fill it")
		end
	end,

	["I8: a timeline's start is on a tick; a sample is a function of the tick alone"] = function(t: Expect)
		local tick = 1 / StoryConfig.TickRate
		local start = CinematicTracks.quantise(12.3456, tick)
		t.truthy(start >= 12.3456 and start - 12.3456 < tick, "the next tick")
		t.near(start / tick, math.round(start / tick), 1e-6, "a whole tick")
		-- the same tick gives the same pose, however many frames led there
		local binding = { P1 = 1, P2 = 2 }
		local a = CinematicTracks.sample("Opening", "Full", 1350 * tick, binding)
		local b = CinematicTracks.sample("Opening", "Full", 1350 * tick, binding)
		local same, where = RuleGolden.same(a, b)
		t.truthy(same, where)
	end,
}
