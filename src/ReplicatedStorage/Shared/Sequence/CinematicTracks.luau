--!strict
-- CinematicTracks: how a cutscene plays, as pure functions of StoryConfig's timelines and a time (docs/design/
-- game-spec-v2.md 2.3; invariant I11: the website's port, web/src/game/rules/tracks.js, replays golden()).
--
--   ease(kind, u)                    cut 0 until u reaches 1, linear u, smooth smoothstep
--   catmullRom(points, times, t)     centripetal Catmull-Rom through points at times (the ends repeated), clamped
--   quantise(time, tick)             the first tick at or after `time` (a timeline's startAt, I8)
--   length(id, cut)                  a cut's length (Full: the timeline's; Short: the sum of its segments)
--   toSource(id, cut, t)             the Full time a cut's time t shows, and its segment
--   sample(id, cut, t, binding)      everything the timeline shows at t: {shot, view, camera, actors, lights, props,
--                                    rain, fade, card, day, rigs}; binding: actor -> its bin's slot (party actors)
--   events(id, cut, t0, t1, players) the one-shot events (Sound, Shake) whose cut time is in (t0, t1]
--   lines(id, cut, t0, t1, players)  the lines starting in (t0, t1] that this many players hear, whole inside the cut
--   cast(runSeed, slots)             the seeded order of the squad's slots: P1, P2, ... (StoryCast)
--   cutFor(id, members)              "Short" when the timeline has one, every member has seen its Full cut and none
--                                    asked for Full on replays; else "Full"
--   skipOffered(id, cut, t)          the skip is offered from Skip.From seconds in until the cut's last shot
--   skipPasses(id, players, voters, unseen)  more than half voted and every member who has not seen it voted (Vote);
--                                    SeenOnly: also nobody unseen
--   skipTarget(id, cut)              where a passed vote cuts to: the start of the last shot, in the cut's time
--   words(text) / lineFits(text, rate, slot)  a line's words; whether words / (WordsPerSecond x rate) <= slot
--   climbOutAt(handOver)             the prologue's automatic climb-out
--   chuteCutAt(handOver, firstIn, allIn)  when the chute's cut falls: every Alive player in (allIn), ChuteWait after
--                                    the first, or MaxSeconds after the hand-over, whichever is first (-1 for none)
--
-- Pure: plain data in and out, no engine, clock or randomness beyond the seeded Rng stream. Vectors are {x, y, z} in
-- the timeline's origin frame; yaws in degrees.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rng = require(ReplicatedStorage.Shared.Util.Rng)
local StoryConfig = require(ReplicatedStorage.Shared.Config.StoryConfig)

type Vec = StoryConfig.Vec
type Timeline = StoryConfig.Timeline
type Segment = StoryConfig.Segment
type ActorKey = StoryConfig.ActorKey

export type GoldenRow = { name: string, fn: string, args: { any }, expect: any }
export type Member = { seenFull: boolean, wantsFull: boolean }

local EPS = 1e-9
local KNOT_MIN = 1e-4

local CinematicTracks = {}

local function timelineOf(id: string): Timeline
	local timeline = StoryConfig.Timelines[id]
	assert(timeline, "CinematicTracks: no timeline " .. id)
	return timeline
end

local function segmentsOf(timeline: Timeline, cut: string): { Segment }
	return timeline.cuts[cut] or timeline.cuts.Full
end

local function vec(x: number, y: number, z: number): Vec
	return { x = x, y = y, z = z }
end

local function lerpVec(a: Vec, b: Vec, u: number): Vec
	return vec(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u, a.z + (b.z - a.z) * u)
end

local function distance(a: Vec, b: Vec): number
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The signed shortest turn from a to b (degrees, -180 < d <= 180).
local function turn(a: number, b: number): number
	local d = (b - a) % 360
	if d > 180 then
		d -= 360
	end
	return d
end

function CinematicTracks.ease(kind: string, u: number): number
	local v = math.clamp(u, 0, 1)
	if kind == "cut" then
		return if v >= 1 then 1 else 0
	elseif kind == "smooth" then
		return v * v * (3 - 2 * v)
	end
	return v
end

-- Barry and Goldman's pyramid over four points at knots k0..k3, evaluated at s in [k1, k2].
local function pyramid(p: { Vec }, k: { number }, s: number): Vec
	local function mix(a: Vec, b: Vec, ka: number, kb: number): Vec
		local span = kb - ka
		return lerpVec(a, b, (s - ka) / span)
	end
	local a1 = mix(p[1], p[2], k[1], k[2])
	local a2 = mix(p[2], p[3], k[2], k[3])
	local a3 = mix(p[3], p[4], k[3], k[4])
	local b1 = mix(a1, a2, k[1], k[3])
	local b2 = mix(a2, a3, k[2], k[4])
	return mix(b1, b2, k[2], k[3])
end

function CinematicTracks.catmullRom(points: { Vec }, times: { number }, t: number): Vec
	local n = #points
	if n == 1 or t <= times[1] then
		return vec(points[1].x, points[1].y, points[1].z)
	elseif t >= times[n] then
		return vec(points[n].x, points[n].y, points[n].z)
	end
	local i = 1
	while i < n - 1 and t >= times[i + 1] do
		i += 1
	end
	local p1, p2 = points[i], points[i + 1]
	if distance(p1, p2) < EPS then
		return vec(p1.x, p1.y, p1.z)
	end
	local p0 = points[math.max(i - 1, 1)]
	local p3 = points[math.min(i + 2, n)]
	local k = { 0, 0, 0, 0 }
	k[2] = k[1] + math.max(math.sqrt(distance(p0, p1)), KNOT_MIN)
	k[3] = k[2] + math.max(math.sqrt(distance(p1, p2)), KNOT_MIN)
	k[4] = k[3] + math.max(math.sqrt(distance(p2, p3)), KNOT_MIN)
	local u = (t - times[i]) / (times[i + 1] - times[i])
	return pyramid({ p0, p1, p2, p3 }, k, k[2] + (k[3] - k[2]) * u)
end

function CinematicTracks.quantise(time: number, tick: number): number
	return math.ceil(time / tick - 1e-6) * tick
end

function CinematicTracks.length(id: string, cut: string): number
	local timeline = timelineOf(id)
	local total = 0
	for _, segment in segmentsOf(timeline, cut) do
		total += segment.to - segment.from
	end
	return total
end

function CinematicTracks.toSource(id: string, cut: string, t: number): { t: number, segment: number }
	local segments = segmentsOf(timelineOf(id), cut)
	local index = 1
	for i, segment in segments do
		if t >= segment.at - EPS then
			index = i
		end
	end
	local segment = segments[index]
	local source = math.clamp(segment.from + (t - segment.at), segment.from, segment.to)
	return { t = source, segment = index }
end

-- The segment of `cut` that keeps `source` (a Full time), or nil when the cut leaves it out.
local function segmentOf(segments: { Segment }, source: number): Segment?
	for _, segment in segments do
		if source >= segment.from - EPS and source < segment.to - EPS then
			return segment
		end
	end
	return nil
end

-- The cut time `source` plays at, or nil when the cut leaves it out.
local function toCut(segments: { Segment }, source: number): number?
	local segment = segmentOf(segments, source)
	return if segment then segment.at + (source - segment.from) else nil
end

local function heardBy(entry: { minPlayers: number?, maxPlayers: number? }, players: number): boolean
	return players >= (entry.minPlayers or 1) and players <= (entry.maxPlayers or 4)
end

-- An actor's resolved key: an absolute place (pos, yaw) or an attachment to another actor (parent, offset, yaw).
type Resolved = { t: number, pos: Vec?, yaw: number, parent: string?, offset: Vec?, cut: boolean }

local function trackOf(timeline: Timeline, actor: string): StoryConfig.Track?
	for _, track in timeline.actors do
		if track.actor == actor then
			return track
		end
	end
	return nil
end

local function resolveKeys(timeline: Timeline, track: StoryConfig.Track, binding: { [string]: number }): { Resolved }
	local out: { Resolved } = {}
	local points = timeline.points
	local bins = if points then points.Bins else nil
	local last: Resolved? = nil
	for _, k in track.keys do
		local r: Resolved
		if k.attach then
			r = {
				t = k.t,
				parent = k.attach,
				offset = k.offset or vec(0, 0, 0),
				yaw = k.yaw or 0,
				cut = k.ease == "cut" or (last ~= nil and last.parent ~= k.attach),
			}
		else
			local pos: Vec? = k.pos
			if k.bin then
				local slot = binding[track.actor]
				local bin = if bins and slot then bins[slot] else nil
				pos = if bin then bin[k.bin] else nil
				if not pos and last then
					pos = last.pos
				end
			end
			local p = pos or vec(0, 0, 0)
			local yaw = k.yaw
			if yaw == nil then
				yaw = if last then last.yaw else 0
				local from = if last then last.pos else nil
				if from and k.bin ~= "Over" and k.bin ~= "Inside" then
					local dx, dz = p.x - from.x, p.z - from.z
					if dx * dx + dz * dz > 1e-4 then
						-- the local frame's yaw that looks along (dx, dz): Roblox's, -Z forward
						yaw = math.deg(math.atan2(-dx, -dz))
					end
				end
			end
			r = {
				t = k.t,
				pos = vec(p.x, p.y, p.z),
				yaw = yaw :: number,
				cut = k.ease == "cut" or (last ~= nil and last.parent ~= nil),
			}
		end
		table.insert(out, r)
		last = r
	end
	return out
end

type Pose = { pos: Vec, yaw: number }

local actorPose: (timeline: Timeline, actor: string, t: number, binding: { [string]: number }, depth: number) -> Pose

actorPose = function(timeline: Timeline, actor: string, t: number, binding: { [string]: number }, depth: number): Pose
	local track = trackOf(timeline, actor)
	if not track or #track.keys == 0 then
		return { pos = vec(0, 0, 0), yaw = 0 }
	end
	local keys = resolveKeys(timeline, track, binding)
	-- the run of keys t falls in: from the last key at or before t back to the run's first (a cut starts a run)
	local i = 1
	for j, k in keys do
		if k.t <= t + EPS then
			i = j
		end
	end
	local first = i
	while first > 1 and not keys[first].cut do
		first -= 1
	end
	local finish = i
	while finish < #keys and not keys[finish + 1].cut do
		finish += 1
	end
	local here = keys[i]
	local nextKey = if i < finish then keys[i + 1] else nil
	local u = if nextKey and t > here.t then (t - here.t) / (nextKey.t - here.t) else 0
	local yaw = here.yaw
	if nextKey then
		yaw = here.yaw + turn(here.yaw, nextKey.yaw) * CinematicTracks.ease("smooth", u)
	end
	if here.parent then
		local offset = here.offset :: Vec
		if nextKey and nextKey.offset then
			offset = lerpVec(offset, nextKey.offset, CinematicTracks.ease("smooth", u))
		end
		local parent = if depth < 2
			then actorPose(timeline, here.parent :: string, t, binding, depth + 1)
			else { pos = vec(0, 0, 0), yaw = 0 }
		local a = math.rad(parent.yaw)
		local c, s = math.cos(a), math.sin(a)
		-- the offset in the parent's frame (x right, y up, -z ahead) turned by the parent's yaw about Y
		local pos = vec(
			parent.pos.x + c * offset.x + s * offset.z,
			parent.pos.y + offset.y,
			parent.pos.z - s * offset.x + c * offset.z
		)
		return { pos = pos, yaw = parent.yaw + yaw }
	end
	local points: { Vec } = {}
	local times: { number } = {}
	for j = first, finish do
		table.insert(points, keys[j].pos :: Vec)
		table.insert(times, keys[j].t)
	end
	return { pos = CinematicTracks.catmullRom(points, times, t), yaw = yaw }
end

local function clipAt(track: StoryConfig.Track, t: number): StoryConfig.Clip?
	local found: StoryConfig.Clip? = nil
	for _, clip in track.clips do
		if clip.t0 <= t + EPS then
			found = clip
		end
	end
	return found
end

-- The latest state event of `kind` at or before t, per key(args).
local function latest(timeline: Timeline, kind: string, t: number, keyOf: (args: any) -> string): { [string]: any }
	local out: { [string]: any } = {}
	for _, e in timeline.events do
		if e.kind == kind and e.t <= t + EPS then
			out[keyOf(e.args)] = e.args
		end
	end
	return out
end

local function cameraAt(timeline: Timeline, t: number): { eye: Vec, target: Vec, fov: number }?
	local keys = timeline.camera
	if #keys == 0 then
		return nil
	end
	local i = 1
	for j, k in keys do
		if k.t <= t + EPS then
			i = j
		end
	end
	local here = keys[i]
	local nextKey = keys[i + 1]
	if not nextKey or nextKey.ease == "cut" or nextKey.t <= here.t then
		return { eye = here.eye, target = here.target, fov = here.fov }
	end
	local u = CinematicTracks.ease(nextKey.ease, (t - here.t) / (nextKey.t - here.t))
	return {
		eye = lerpVec(here.eye, nextKey.eye, u),
		target = lerpVec(here.target, nextKey.target, u),
		fov = here.fov + (nextKey.fov - here.fov) * u,
	}
end

local function fadeAt(timeline: Timeline, t: number): number
	local level = 0
	for _, e in timeline.events do
		if e.kind == "Fade" and e.t <= t + EPS then
			local seconds = e.args.seconds
			local u = if seconds > 0 then math.clamp((t - e.t) / seconds, 0, 1) else 1
			level = level + (e.args.to - level) * u
		end
	end
	return level
end

local function dayAt(timeline: Timeline, t: number): { amount: number, tint: Vec }
	local keys = timeline.day
	if not keys or #keys == 0 then
		return { amount = 0, tint = vec(1, 1, 1) }
	end
	local i = 1
	for j, k in keys do
		if k.t <= t + EPS then
			i = j
		end
	end
	local here = keys[i]
	local nextKey = keys[i + 1]
	if not nextKey or t <= here.t then
		return { amount = here.amount, tint = vec(here.tint.x, here.tint.y, here.tint.z) }
	end
	local u = (t - here.t) / (nextKey.t - here.t)
	return {
		amount = here.amount + (nextKey.amount - here.amount) * u,
		tint = lerpVec(here.tint, nextKey.tint, u),
	}
end

function CinematicTracks.sample(id: string, cut: string, t: number, binding: { [string]: number }): { [string]: any }
	local timeline = timelineOf(id)
	local source = CinematicTracks.toSource(id, cut, t).t
	local shot = timeline.shots[1]
	for _, s in timeline.shots do
		if s.t0 <= source + EPS then
			shot = s
		end
	end
	local rigs: { [string]: string } = {}
	for _, e in timeline.events do
		if e.kind == "Rig" and e.t <= source + EPS then
			rigs[e.args.actor] = e.args.into
		end
	end
	local actors: { [string]: any } = {}
	for _, track in timeline.actors do
		local pose = actorPose(timeline, track.actor, source, binding, 0)
		local clip = clipAt(track, source)
		local name = if clip then clip.name else "Hidden"
		local swapped = rigs[track.actor] ~= nil and rigs[track.actor] ~= track.actor
		local bound = track.kind ~= "Party" or binding[track.actor] ~= nil
		actors[track.actor] = {
			pos = pose.pos,
			yaw = pose.yaw,
			clip = name,
			clipTime = if clip then source - clip.t0 else 0,
			rate = if clip and clip.slow then 1 / clip.slow else 1,
			visible = name ~= "Hidden" and not swapped and bound,
		}
	end
	local card: { [string]: any }? = nil
	for _, e in timeline.events do
		if e.kind == "Card" and e.t <= source + EPS and source < e.t + e.args.seconds then
			card = { text = e.args.text, age = source - e.t, seconds = e.args.seconds }
		end
	end
	local lights = {}
	for group, args in
		latest(timeline, "Light", source, function(a: any): string
			return a.group
		end)
	do
		lights[group] = args.mode
	end
	local props = {}
	for key, args in
		latest(timeline, "Prop", source, function(a: any): string
			return if a.actor then a.id .. ":" .. a.actor else a.id
		end)
	do
		props[key] = args.state
	end
	local rain = false
	for _, args in
		latest(timeline, "Rain", source, function(): string
			return "rain"
		end)
	do
		rain = args.on
	end
	return {
		shot = shot.id,
		view = shot.view,
		source = source,
		camera = cameraAt(timeline, source),
		actors = actors,
		lights = lights,
		props = props,
		rain = rain,
		fade = fadeAt(timeline, source),
		card = card,
		day = dayAt(timeline, source),
		rigs = rigs,
	}
end

function CinematicTracks.events(id: string, cut: string, t0: number, t1: number, players: number): { { [string]: any } }
	local timeline = timelineOf(id)
	local segments = segmentsOf(timeline, cut)
	local out = {}
	for index, e in timeline.events do
		if (e.kind == "Sound" or e.kind == "Shake") and heardBy(e, players) then
			local at = toCut(segments, e.t)
			if at and at > t0 + EPS and at <= t1 + EPS then
				table.insert(out, { index = index, at = at, t = e.t, kind = e.kind, args = e.args })
			end
		end
	end
	table.sort(out, function(a, b): boolean
		return if a.at == b.at then a.index < b.index else a.at < b.at
	end)
	return out
end

function CinematicTracks.lines(id: string, cut: string, t0: number, t1: number, players: number): { { [string]: any } }
	local timeline = timelineOf(id)
	local segments = segmentsOf(timeline, cut)
	local out = {}
	for _, line in timeline.lines do
		local segment = if heardBy(line, players) then segmentOf(segments, line.t) else nil
		-- the whole slot inside the segment the line starts in
		if segment and line.t + line.slot <= segment.to + EPS then
			local at = segment.at + (line.t - segment.from)
			if at > t0 + EPS and at <= t1 + EPS then
				table.insert(out, { id = line.id, at = at, slot = line.slot })
			end
		end
	end
	table.sort(out, function(a, b): boolean
		return a.at < b.at
	end)
	return out
end

function CinematicTracks.cast(runSeed: number, slots: { number }): { number }
	local order = table.clone(slots)
	table.sort(order)
	local random = Rng.seeded(runSeed, "StoryCast")
	for i = #order, 2, -1 do
		local j = random:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	return order
end

function CinematicTracks.cutFor(id: string, members: { Member }): string
	local timeline = timelineOf(id)
	if not timeline.cuts.Short or #members == 0 then
		return "Full"
	end
	for _, m in members do
		if not m.seenFull or m.wantsFull then
			return "Full"
		end
	end
	return "Short"
end

function CinematicTracks.skipOffered(id: string, cut: string, t: number): boolean
	return t >= StoryConfig.Skip.From - EPS and t < CinematicTracks.skipTarget(id, cut) - EPS
end

function CinematicTracks.skipPasses(id: string, players: number, voters: { string }, unseen: { string }): boolean
	local timeline = timelineOf(id)
	if players <= 0 or #voters * 2 <= players then
		return false
	end
	if timeline.skip == "SeenOnly" and #unseen > 0 then
		return false
	end
	local voted: { [string]: boolean } = {}
	for _, v in voters do
		voted[v] = true
	end
	for _, member in unseen do
		if not voted[member] then
			return false
		end
	end
	return true
end

function CinematicTracks.skipTarget(id: string, cut: string): number
	local timeline = timelineOf(id)
	local last = timeline.shots[#timeline.shots]
	local segments = segmentsOf(timeline, cut)
	local best = CinematicTracks.length(id, cut)
	-- the cut time of the last shot's start, or of its earliest moment the cut keeps
	for _, segment in segments do
		local from = math.max(segment.from, last.t0)
		if from < segment.to - EPS then
			best = math.min(best, segment.at + (from - segment.from))
		end
	end
	return best
end

function CinematicTracks.words(text: string): number
	local count = 0
	for _ in string.gmatch(text, "%S+") do
		count += 1
	end
	return count
end

function CinematicTracks.lineFits(text: string, rate: number, slot: number): boolean
	local words = CinematicTracks.words(text)
	return words <= StoryConfig.Speech.MaxWords and words / (StoryConfig.Speech.WordsPerSecond * rate) <= slot + EPS
end

function CinematicTracks.climbOutAt(handOver: number): number
	return handOver + StoryConfig.Prologue.AutoClimbOut
end

function CinematicTracks.chuteCutAt(handOver: number, firstIn: number, allIn: number): number
	local p = StoryConfig.Prologue
	local due = handOver + p.MaxSeconds
	if firstIn >= 0 then
		due = math.min(due, firstIn + p.ChuteWait)
	end
	if allIn >= 0 then
		due = math.min(due, allIn)
	end
	return due
end

-- The golden rows (the export writes them for the website's port): what each function returns for its args, pinned in
-- EXPECT below. Numbers compare to 1e-9.
local EXPECT: { [string]: any } = {
	["ease: cut before the key"] = 0,
	["ease: cut at the key"] = 1,
	["ease: linear"] = 0.25,
	["ease: smooth"] = 0.15625,
	["ease: clamped"] = 1,
	["catmullRom: before the first key"] = {
		x = 0,
		y = 0,
		z = 0,
	},
	["catmullRom: on a key"] = {
		x = 10,
		y = 0,
		z = 0,
	},
	["catmullRom: between keys"] = {
		x = 11.240867513344462,
		y = -0.12317350266889214,
		z = 4.9969359063337446,
	},
	["catmullRom: the last span"] = {
		x = 1.3293180693745912,
		y = 1.7341363861250818,
		z = 10.237844749194984,
	},
	["catmullRom: a held key"] = {
		x = 1,
		y = 2,
		z = 3,
	},
	["catmullRom: past the end"] = {
		x = 0,
		y = 2,
		z = 10,
	},
	["quantise: between ticks"] = 10.033333333333333,
	["quantise: on a tick"] = 2,
	["length: the opening, Full"] = 78,
	["length: the opening, Short"] = 26,
	["length: the twist, Short"] = 8,
	["length: Sunrise has no Short"] = 44,
	["toSource: Full"] = {
		segment = 1,
		t = 40,
	},
	["toSource: Short, S6 from Booo"] = {
		segment = 2,
		t = 26.899999999999999,
	},
	["toSource: Short, the last segment"] = {
		segment = 7,
		t = 77,
	},
	["sample: the opening at S3, solo"] = {
		actors = {
			Crawler = {
				clip = "Hidden",
				clipTime = 11.25,
				pos = {
					x = -11.199999999999999,
					y = 1.6000000000000001,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = false,
				yaw = 112.833654,
			},
			Danny = {
				clip = "Walk",
				clipTime = 7.0499999999999998,
				pos = {
					x = -36.746861238648314,
					y = -0.022457323016964875,
					z = -20.791113650615866,
				},
				rate = 1,
				visible = true,
				yaw = 128.47376814800901,
			},
			P1 = {
				clip = "Walk",
				clipTime = 7.0499999999999998,
				pos = {
					x = -39.442737796960955,
					y = -0.022696971444285497,
					z = -18.652093704005786,
				},
				rate = 1,
				visible = true,
				yaw = -47.012477023290757,
			},
			P2 = {
				clip = "Walk",
				clipTime = 6.7999999999999998,
				pos = {
					x = -42.014098150421432,
					y = -0.02310245198856082,
					z = -17.183793482723747,
				},
				rate = 1,
				visible = false,
				yaw = -48.167705941535445,
			},
			P3 = {
				clip = "Walk",
				clipTime = 6.5499999999999998,
				pos = {
					x = -38.285463223977203,
					y = -0.023381134625997373,
					z = -15.813878594604773,
				},
				rate = 1,
				visible = false,
				yaw = -49.299217257915437,
			},
			P4 = {
				clip = "Walk",
				clipTime = 6.2999999999999998,
				pos = {
					x = -41.756395466025602,
					y = -0.023523117567774803,
					z = -14.342103884640165,
				},
				rate = 1,
				visible = false,
				yaw = -50.402420468843992,
			},
			Sneakers = {
				clip = "Hidden",
				clipTime = 11.25,
				pos = {
					x = -13.6,
					y = 0.80000000000000004,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = false,
				yaw = 71.722890000000007,
			},
			TallMan = {
				clip = "Hidden",
				clipTime = 11.25,
				pos = {
					x = -13.6,
					y = 0,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = false,
				yaw = 71.722890000000007,
			},
		},
		camera = {
			eye = {
				x = -33.813636363636363,
				y = 4.7999999999999998,
				z = -25.59090909090909,
			},
			fov = 46,
			target = {
				x = -39.145454545454548,
				y = 3.7999999999999998,
				z = -19.554545454545455,
			},
		},
		day = {
			amount = 0.65000000000000002,
			tint = {
				x = 1,
				y = 1,
				z = 1,
			},
		},
		fade = 0,
		lights = {
			["Scripted:BL_Lamp"] = "Off",
			["Scripted:BL_Strobe"] = "Off",
		},
		props = {
			Shutter = "Up",
			Windows1 = "Lit",
			Windows2 = "Lit",
		},
		rain = false,
		rigs = {},
		shot = "S3",
		source = 11.25,
		view = "Cinematic",
	},
	["sample: the latch, four players"] = {
		actors = {
			Crawler = {
				clip = "Unfold",
				clipTime = 3,
				pos = {
					x = -15.691757867218602,
					y = 4.9676000000000009,
					z = -29.372558773935737,
				},
				rate = 1,
				visible = true,
				yaw = 63.444498331961654,
			},
			Danny = {
				clip = "Stagger",
				clipTime = 0,
				pos = {
					x = -14.983670308964452,
					y = 0,
					z = -29.018662504040627,
				},
				rate = 1,
				visible = true,
				yaw = 63.444498331961654,
			},
			P1 = {
				clip = "Idle",
				clipTime = 6.0000000000000036,
				pos = {
					x = -23,
					y = 0,
					z = -33.200000000000003,
				},
				rate = 1,
				visible = true,
				yaw = -108.14062113161106,
			},
			P2 = {
				clip = "Idle",
				clipTime = 5.8000000000000043,
				pos = {
					x = -25.600000000000001,
					y = 0,
					z = -31.800000000000001,
				},
				rate = 1,
				visible = true,
				yaw = -97.78321280482669,
			},
			P3 = {
				clip = "Idle",
				clipTime = 5.6000000000000014,
				pos = {
					x = -22.399999999999999,
					y = 0,
					z = -36.399999999999999,
				},
				rate = 1,
				visible = true,
				yaw = -126.15032955691299,
			},
			P4 = {
				clip = "Idle",
				clipTime = 5.4000000000000021,
				pos = {
					x = -26.800000000000001,
					y = 0,
					z = -35.399999999999999,
				},
				rate = 1,
				visible = true,
				yaw = -112.09075648346875,
			},
			Sneakers = {
				clip = "Hidden",
				clipTime = 31.600000000000001,
				pos = {
					x = -13.6,
					y = 0.80000000000000004,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = false,
				yaw = 71.722890000000007,
			},
			TallMan = {
				clip = "Hidden",
				clipTime = 31.600000000000001,
				pos = {
					x = -13.6,
					y = 0,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = false,
				yaw = 71.722890000000007,
			},
		},
		camera = {
			eye = {
				x = -21.383999999999997,
				y = 4.7999999999999998,
				z = -32.783999999999999,
			},
			fov = 48,
			target = {
				x = -14.575999999999999,
				y = 3.984,
				z = -29.824000000000002,
			},
		},
		day = {
			amount = 0.65000000000000002,
			tint = {
				x = 1,
				y = 1,
				z = 1,
			},
		},
		fade = 0,
		lights = {
			["Scripted:BL_Lamp"] = "Off",
			["Scripted:BL_Strobe"] = "Off",
		},
		props = {
			Shutter = "Up",
			Windows1 = "Lit",
			Windows2 = "Lit",
		},
		rain = false,
		rigs = {},
		shot = "S8",
		source = 31.600000000000001,
		view = "Cinematic",
	},
	["sample: the swap in the dark"] = {
		actors = {
			Crawler = {
				clip = "Hidden",
				clipTime = 0.10000000000000142,
				pos = {
					x = -14.097002357817217,
					y = 5.7999999999999998,
					z = -30.654668604556239,
				},
				rate = 1,
				visible = false,
				yaw = 83.722890000000007,
			},
			Danny = {
				clip = "Lifted",
				clipTime = 2.9000000000000057,
				pos = {
					x = -13.6,
					y = 0.80000000000000004,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = false,
				yaw = 83.722890000000007,
			},
			P1 = {
				clip = "Idle",
				clipTime = 3.3000000000000043,
				pos = {
					x = -24.542097999999999,
					y = 0,
					z = -33.626537999999996,
				},
				rate = 1,
				visible = true,
				yaw = -105.461218,
			},
			P2 = {
				clip = "Idle",
				clipTime = 3.3000000000000043,
				pos = {
					x = -27.192060000000001,
					y = 0,
					z = -31.959205999999998,
				},
				rate = 1,
				visible = true,
				yaw = -95.710593000000003,
			},
			P3 = {
				clip = "Idle",
				clipTime = 3.3000000000000043,
				pos = {
					x = -23.735932999999999,
					y = 0,
					z = -37.280501000000001,
				},
				rate = 1,
				visible = true,
				yaw = -123.388514,
			},
			P4 = {
				clip = "Idle",
				clipTime = 3.3000000000000043,
				pos = {
					x = -28.303668999999999,
					y = 0,
					z = -35.946789000000003,
				},
				rate = 1,
				visible = true,
				yaw = -109.983107,
			},
			Sneakers = {
				clip = "Sneakers",
				clipTime = 0.10000000000000142,
				pos = {
					x = -13.6,
					y = 0.64139159480580898,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = true,
				yaw = 75.687904577259559,
			},
			TallMan = {
				clip = "Unfold",
				clipTime = 0.10000000000000142,
				pos = {
					x = -13.6,
					y = 0,
					z = -30.600000000000001,
				},
				rate = 0.30769230769230771,
				visible = true,
				yaw = 71.722890000000007,
			},
		},
		camera = {
			eye = {
				x = -29.841999999999999,
				y = 9.0299999999999994,
				z = -46.654000000000003,
			},
			fov = 50.119999999999997,
			target = {
				x = -15.842000000000001,
				y = 3.1880000000000002,
				z = -31,
			},
		},
		day = {
			amount = 0.65000000000000002,
			tint = {
				x = 1,
				y = 1,
				z = 1,
			},
		},
		fade = 0,
		lights = {
			["Scripted:BL_Lamp"] = "Off",
			["Scripted:BL_Strobe"] = "Off",
		},
		props = {
			Shutter = "Up",
			Windows1 = "Lit",
			Windows2 = "Lit",
		},
		rain = false,
		rigs = {
			Danny = "TallMan",
		},
		shot = "S9",
		source = 38.700000000000003,
		view = "Cinematic",
	},
	["sample: the dive, four players"] = {
		actors = {
			Crawler = {
				clip = "Hidden",
				clipTime = 7.6000000000000014,
				pos = {
					x = -14.097002357817217,
					y = 5.7999999999999998,
					z = -30.654668604556239,
				},
				rate = 1,
				visible = false,
				yaw = 83.722890000000007,
			},
			Danny = {
				clip = "Lifted",
				clipTime = 10.400000000000006,
				pos = {
					x = -13.6,
					y = 0.80000000000000004,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = false,
				yaw = 83.722890000000007,
			},
			P1 = {
				clip = "Crouch",
				clipTime = 0.30000000000000426,
				pos = {
					x = -48,
					y = 1.6865821438039319,
					z = -36.103784402487975,
				},
				rate = 1,
				visible = true,
				yaw = 82.40535663140858,
			},
			P2 = {
				clip = "Crouch",
				clipTime = 0.15000000000000568,
				pos = {
					x = -9.5368782594597814,
					y = 3.3579382266572662,
					z = -33.947855901158178,
				},
				rate = 1,
				visible = true,
				yaw = -104.82647997035565,
			},
			P3 = {
				clip = "Crouch",
				clipTime = 7.1054273576010019e-15,
				pos = {
					x = -21.998404647721628,
					y = 3.1667064920964263,
					z = -39.403245968665864,
				},
				rate = 1,
				visible = true,
				yaw = -36.869897645844183,
			},
			P4 = {
				clip = "Run",
				clipTime = 2.75,
				pos = {
					x = -34.234088234066412,
					y = 1.3897486447315686,
					z = -35.802815680043601,
				},
				rate = 1,
				visible = true,
				yaw = 59.036243467926518,
			},
			Sneakers = {
				clip = "Sneakers",
				clipTime = 7.6000000000000014,
				pos = {
					x = -13.6,
					y = 0,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = true,
				yaw = 91.722890000000007,
			},
			TallMan = {
				clip = "Walk",
				clipTime = 1.6000000000000014,
				pos = {
					x = -20.366781756969015,
					y = 0,
					z = -29.009390115076467,
				},
				rate = 1,
				visible = true,
				yaw = 93.971736000000007,
			},
		},
		camera = {
			eye = {
				x = -17.426666666666669,
				y = 12.573333333333334,
				z = -18.426666666666669,
			},
			fov = 62,
			target = {
				x = -25,
				y = 0,
				z = -37,
			},
		},
		day = {
			amount = 0.65000000000000002,
			tint = {
				x = 1,
				y = 1,
				z = 1,
			},
		},
		fade = 0,
		lights = {
			["Scripted:BL_Lamp"] = "On",
			["Scripted:BL_Strobe"] = "Off",
		},
		props = {
			["Lid:P1"] = "Open",
			["Lid:P2"] = "Open",
			Shutter = "Up",
			Windows1 = "Lit",
			Windows2 = "Lit",
		},
		rain = false,
		rigs = {
			Danny = "TallMan",
		},
		shot = "S11",
		source = 46.200000000000003,
		view = "Cinematic",
	},
	["sample: the time-lapse"] = {
		actors = {
			Crawler = {
				clip = "Hidden",
				clipTime = 30.899999999999999,
				pos = {
					x = -14.097002357817217,
					y = 5.7999999999999998,
					z = -30.654668604556239,
				},
				rate = 1,
				visible = false,
				yaw = 83.722890000000007,
			},
			Danny = {
				clip = "Lifted",
				clipTime = 33.700000000000003,
				pos = {
					x = -13.6,
					y = 0.80000000000000004,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = false,
				yaw = 83.722890000000007,
			},
			P1 = {
				clip = "Hidden",
				clipTime = 23.049999999999997,
				pos = {
					x = -9.4000000000000004,
					y = 0.5,
					z = -34,
				},
				rate = 1,
				visible = false,
				yaw = -104.82647997035565,
			},
			P2 = {
				clip = "Hidden",
				clipTime = 22.899999999999999,
				pos = {
					x = -27.192060000000001,
					y = 0,
					z = -31.959205999999998,
				},
				rate = 1,
				visible = false,
				yaw = -95.710593000000003,
			},
			P3 = {
				clip = "Hidden",
				clipTime = 22.75,
				pos = {
					x = -23.735932999999999,
					y = 0,
					z = -37.280501000000001,
				},
				rate = 1,
				visible = false,
				yaw = -123.388514,
			},
			P4 = {
				clip = "Hidden",
				clipTime = 22.599999999999994,
				pos = {
					x = -28.303668999999999,
					y = 0,
					z = -35.946789000000003,
				},
				rate = 1,
				visible = false,
				yaw = -109.983107,
			},
			Sneakers = {
				clip = "Sneakers",
				clipTime = 30.899999999999999,
				pos = {
					x = -13.6,
					y = 0,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = true,
				yaw = 91.722890000000007,
			},
			TallMan = {
				clip = "Hidden",
				clipTime = 8,
				pos = {
					x = -60,
					y = 0.34999999999999998,
					z = -0.59999999999999998,
				},
				rate = 1,
				visible = false,
				yaw = 114.06872300000001,
			},
		},
		camera = {
			eye = {
				x = -10,
				y = 4.5499999999999998,
				z = -32.600000000000001,
			},
			fov = 66,
			target = {
				x = -30.766666666666666,
				y = 7.3066666666666666,
				z = -12,
			},
		},
		card = {
			age = 0.29999999999999716,
			seconds = 1.8,
			text = "9:03 PM",
		},
		day = {
			amount = 0.315,
			tint = {
				x = 0.70999999999999996,
				y = 0.59000000000000008,
				z = 0.66000000000000003,
			},
		},
		fade = 0,
		lights = {
			["Scripted:BL_Lamp"] = "On",
			["Scripted:BL_Strobe"] = "Flicker",
		},
		props = {
			["Lid:P1"] = "Shut",
			["Lid:P2"] = "Shut",
			["Lid:P3"] = "Shut",
			["Lid:P4"] = "Shut",
			Shutter = "Down",
			Windows1 = "Dark",
			Windows2 = "Dark",
		},
		rain = false,
		rigs = {
			Danny = "TallMan",
		},
		shot = "S14",
		source = 69.5,
		view = "Cinematic",
	},
	["sample: Short, S13's windows"] = {
		actors = {
			Crawler = {
				clip = "Hidden",
				clipTime = 23.899999999999999,
				pos = {
					x = -14.097002357817217,
					y = 5.7999999999999998,
					z = -30.654668604556239,
				},
				rate = 1,
				visible = false,
				yaw = 83.722890000000007,
			},
			Danny = {
				clip = "Lifted",
				clipTime = 26.700000000000003,
				pos = {
					x = -13.6,
					y = 0.80000000000000004,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = false,
				yaw = 83.722890000000007,
			},
			P1 = {
				clip = "Hidden",
				clipTime = 16.049999999999997,
				pos = {
					x = -9.4000000000000004,
					y = 0.5,
					z = -34,
				},
				rate = 1,
				visible = false,
				yaw = -104.82647997035565,
			},
			P2 = {
				clip = "Hidden",
				clipTime = 15.899999999999999,
				pos = {
					x = -27.192060000000001,
					y = 0,
					z = -31.959205999999998,
				},
				rate = 1,
				visible = false,
				yaw = -95.710593000000003,
			},
			P3 = {
				clip = "Hidden",
				clipTime = 15.75,
				pos = {
					x = -23.735932999999999,
					y = 0,
					z = -37.280501000000001,
				},
				rate = 1,
				visible = false,
				yaw = -123.388514,
			},
			P4 = {
				clip = "Hidden",
				clipTime = 15.599999999999994,
				pos = {
					x = -28.303668999999999,
					y = 0,
					z = -35.946789000000003,
				},
				rate = 1,
				visible = false,
				yaw = -109.983107,
			},
			Sneakers = {
				clip = "Sneakers",
				clipTime = 23.899999999999999,
				pos = {
					x = -13.6,
					y = 0,
					z = -30.600000000000001,
				},
				rate = 1,
				visible = true,
				yaw = 91.722890000000007,
			},
			TallMan = {
				clip = "Hidden",
				clipTime = 1,
				pos = {
					x = -60,
					y = 0.34999999999999998,
					z = -0.59999999999999998,
				},
				rate = 1,
				visible = false,
				yaw = 114.06872300000001,
			},
		},
		camera = {
			eye = {
				x = -10,
				y = 4.5499999999999998,
				z = -32.600000000000001,
			},
			fov = 66,
			target = {
				x = -30.300000000000001,
				y = 7.1200000000000001,
				z = -12,
			},
		},
		day = {
			amount = 0.65000000000000002,
			tint = {
				x = 1,
				y = 1,
				z = 1,
			},
		},
		fade = 0,
		lights = {
			["Scripted:BL_Lamp"] = "On",
			["Scripted:BL_Strobe"] = "Off",
		},
		props = {
			["Lid:P1"] = "Shut",
			["Lid:P2"] = "Shut",
			["Lid:P3"] = "Shut",
			["Lid:P4"] = "Shut",
			Shutter = "Up",
			Windows1 = "Lit",
			Windows2 = "Dark",
		},
		rain = false,
		rigs = {
			Danny = "TallMan",
		},
		shot = "S13",
		source = 62.5,
		view = "Cinematic",
	},
	["events: the opening's first seconds"] = {
		{
			args = {
				preset = "SchoolBell",
				volume = 0.90000000000000002,
			},
			at = 0,
			index = 3,
			kind = "Sound",
			t = 0,
		},
		{
			args = {
				pos = {
					x = -60,
					y = 3,
					z = 0,
				},
				preset = "DoorBang",
				volume = 1,
			},
			at = 4,
			index = 9,
			kind = "Sound",
			t = 4,
		},
	},
	["events: the lids, two players"] = {
		{
			args = {
				actor = "P1",
				preset = "LidSlam",
				volume = 1,
			},
			at = 46.5,
			index = 35,
			kind = "Sound",
			t = 46.5,
		},
		{
			args = {
				actor = "P2",
				preset = "LidSlam",
				volume = 1,
			},
			at = 46.649999999999999,
			index = 37,
			kind = "Sound",
			t = 46.649999999999999,
		},
	},
	["events: the Short cut's S8"] = {
		{
			args = {
				pos = {
					x = -15.4,
					y = 5,
					z = -29.600000000000001,
				},
				preset = "MaskCrack",
				volume = 1,
			},
			at = 6.5500000000000007,
			index = 17,
			kind = "Sound",
			t = 31.550000000000001,
		},
		{
			args = {
				amplitude = 0.59999999999999998,
				seconds = 0.40000000000000002,
			},
			at = 6.6000000000000014,
			index = 18,
			kind = "Shake",
			t = 31.600000000000001,
		} :: any, -- (a Shake's args beside a Sound's: the list holds both shapes)
	},
	["events: the fall's toll, co-op only"] = {
		{
			args = {
				preset = "LidCreak",
				volume = 0.80000000000000004,
			},
			at = 13,
			index = 5,
			kind = "Sound",
			t = 13,
		},
	},
	["lines: solo skips P2's line"] = {
		{
			at = 14.800000000000001,
			id = "Opening.Pizza",
			slot = 3.2000000000000002,
		},
		{
			at = 21,
			id = "Opening.WaitUp",
			slot = 1.6000000000000001,
		},
	},
	["lines: two players hear it"] = {
		{
			at = 14.800000000000001,
			id = "Opening.Pizza",
			slot = 3.2000000000000002,
		},
		{
			at = 18,
			id = "Opening.Paying",
			slot = 1.5,
		},
		{
			at = 21,
			id = "Opening.WaitUp",
			slot = 1.6000000000000001,
		},
	},
	["lines: the Short cut"] = {
		{
			at = 3,
			id = "Opening.Phantom",
			slot = 1.8,
		},
		{
			at = 7,
			id = "Opening.GetItOff",
			slot = 2,
		},
		{
			at = 19,
			id = "Opening.Lockdown",
			slot = 2.2000000000000002,
		},
		{
			at = 22.5,
			id = "Opening.You",
			slot = 1.5,
		},
	},
	["lines: the fall, solo"] = {
		{
			at = 11,
			id = "Fall.You",
			slot = 1.5,
		},
	},
	["cast: four slots"] = {
		2,
		1,
		0,
		3,
	},
	["cast: two slots"] = {
		2,
		0,
	},
	["cast: alone"] = {
		0,
	},
	["cutFor: a first-timer"] = "Full",
	["cutFor: everyone has seen it"] = "Short",
	["cutFor: someone wants Full"] = "Full",
	["cutFor: no Short cut"] = "Full",
	["skipOffered: before 5 s"] = false,
	["skipOffered: from 5 s"] = true,
	["skipOffered: in the last shot"] = false,
	["skipPasses: alone"] = true,
	["skipPasses: one of two"] = false,
	["skipPasses: two of three"] = true,
	["skipPasses: two of four"] = false,
	["skipPasses: three of four"] = true,
	["skipPasses: a first-timer who did not vote"] = false,
	["skipPasses: a first-timer who voted"] = true,
	["skipPasses: the fall, someone unseen"] = false,
	["skipTarget: Full"] = 73,
	["skipTarget: Short"] = 22.5,
	["words: a name slot is a word"] = 7,
	["lineFits: the frog line"] = true,
	["lineFits: too long for its slot"] = false,
	["climbOutAt"] = 98,
	["chuteCutAt: nobody in"] = 128,
	["chuteCutAt: 30 s after the first"] = 120,
	["chuteCutAt: everyone in"] = 101,
	["chuteCutAt: the prologue's limit"] = 128,
}

function CinematicTracks.golden(): { GoldenRow }
	local rows: { GoldenRow } = {}
	local function row(name: string, fn: string, args: { any })
		table.insert(rows, { name = name, fn = fn, args = args, expect = EXPECT[name] })
	end
	local solo = { P1 = 1 }
	local four = { P1 = 3, P2 = 1, P3 = 4, P4 = 2 }
	row("ease: cut before the key", "ease", { "cut", 0.99 })
	row("ease: cut at the key", "ease", { "cut", 1 })
	row("ease: linear", "ease", { "linear", 0.25 })
	row("ease: smooth", "ease", { "smooth", 0.25 })
	row("ease: clamped", "ease", { "smooth", 1.5 })
	local square = { vec(0, 0, 0), vec(10, 0, 0), vec(10, 0, 10), vec(0, 2, 10) }
	row("catmullRom: before the first key", "catmullRom", { square, { 0, 1, 2, 3 }, -1 })
	row("catmullRom: on a key", "catmullRom", { square, { 0, 1, 2, 3 }, 1 })
	row("catmullRom: between keys", "catmullRom", { square, { 0, 1, 2, 3 }, 1.5 })
	row("catmullRom: the last span", "catmullRom", { square, { 0, 1, 2, 3 }, 2.75 })
	row("catmullRom: a held key", "catmullRom", { { vec(1, 2, 3), vec(1, 2, 3), vec(4, 2, 3) }, { 0, 1, 2 }, 0.5 })
	row("catmullRom: past the end", "catmullRom", { square, { 0, 1, 2, 3 }, 9 })
	row("quantise: between ticks", "quantise", { 10.01, 1 / 30 })
	row("quantise: on a tick", "quantise", { 2, 1 / 30 })
	row("length: the opening, Full", "length", { "Opening", "Full" })
	row("length: the opening, Short", "length", { "Opening", "Short" })
	row("length: the twist, Short", "length", { "Twist", "Short" })
	row("length: Sunrise has no Short", "length", { "Sunrise", "Short" })
	row("toSource: Full", "toSource", { "Opening", "Full", 40 })
	row("toSource: Short, S6 from Booo", "toSource", { "Opening", "Short", 3.5 })
	row("toSource: Short, the last segment", "toSource", { "Opening", "Short", 25 })
	row("sample: the opening at S3, solo", "sample", { "Opening", "Full", 11.25, solo })
	row("sample: the latch, four players", "sample", { "Opening", "Full", 31.6, four })
	row("sample: the swap in the dark", "sample", { "Opening", "Full", 38.7, four })
	row("sample: the dive, four players", "sample", { "Opening", "Full", 46.2, four })
	row("sample: the time-lapse", "sample", { "Opening", "Full", 69.5, solo })
	row("sample: Short, S13's windows", "sample", { "Opening", "Short", 20.0, solo })
	row("events: the opening's first seconds", "events", { "Opening", "Full", -1, 4.5, 1 })
	row("events: the lids, two players", "events", { "Opening", "Full", 46.4, 46.7, 2 })
	row("events: the Short cut's S8", "events", { "Opening", "Short", 6.4, 9.0, 1 })
	row("events: the fall's toll, co-op only", "events", { "Fall", "Full", 10, 14, 1 })
	row("lines: solo skips P2's line", "lines", { "Opening", "Full", 14, 22, 1 })
	row("lines: two players hear it", "lines", { "Opening", "Full", 14, 22, 2 })
	row("lines: the Short cut", "lines", { "Opening", "Short", -1, 26, 1 })
	row("lines: the fall, solo", "lines", { "Fall", "Full", 10, 12, 1 })
	row("cast: four slots", "cast", { 1029, { 0, 1, 2, 3 } })
	row("cast: two slots", "cast", { 4242, { 2, 0 } })
	row("cast: alone", "cast", { 7, { 0 } })
	row(
		"cutFor: a first-timer",
		"cutFor",
		{ "Opening", { { seenFull = true, wantsFull = false }, {
			seenFull = false,
			wantsFull = false,
		} } }
	)
	row(
		"cutFor: everyone has seen it",
		"cutFor",
		{ "Opening", { { seenFull = true, wantsFull = false }, {
			seenFull = true,
			wantsFull = false,
		} } }
	)
	row("cutFor: someone wants Full", "cutFor", { "Opening", { { seenFull = true, wantsFull = true } } })
	row("cutFor: no Short cut", "cutFor", { "Fall", { { seenFull = true, wantsFull = false } } })
	row("skipOffered: before 5 s", "skipOffered", { "Opening", "Full", 4.9 })
	row("skipOffered: from 5 s", "skipOffered", { "Opening", "Full", 5 })
	row("skipOffered: in the last shot", "skipOffered", { "Opening", "Full", 74 })
	row("skipPasses: alone", "skipPasses", { "Opening", 1, { "a" }, {} })
	row("skipPasses: one of two", "skipPasses", { "Opening", 2, { "a" }, {} })
	row("skipPasses: two of three", "skipPasses", { "Opening", 3, { "a", "b" }, {} })
	row("skipPasses: two of four", "skipPasses", { "Opening", 4, { "a", "b" }, {} })
	row("skipPasses: three of four", "skipPasses", { "Opening", 4, { "a", "b", "c" }, {} })
	row("skipPasses: a first-timer who did not vote", "skipPasses", { "Opening", 4, { "a", "b", "c" }, { "d" } })
	row("skipPasses: a first-timer who voted", "skipPasses", { "Opening", 3, { "a", "b" }, { "b" } })
	row("skipPasses: the fall, someone unseen", "skipPasses", { "Fall", 2, { "a", "b" }, { "b" } })
	row("skipTarget: Full", "skipTarget", { "Opening", "Full" })
	row("skipTarget: Short", "skipTarget", { "Opening", "Short" })
	row("words: a name slot is a word", "words", { "{P1}, back me up. Funniest thing ever." })
	row("lineFits: the frog line", "lineFits", { "Did you SEE Kessler's face when the frog got loose?", 1.05, 4.0 })
	row("lineFits: too long for its slot", "lineFits", { "Get it— GET IT OFF—", 0.9, 2.0 })
	row("climbOutAt", "climbOutAt", { 78 })
	row("chuteCutAt: nobody in", "chuteCutAt", { 78, -1, -1 })
	row("chuteCutAt: 30 s after the first", "chuteCutAt", { 78, 90, -1 })
	row("chuteCutAt: everyone in", "chuteCutAt", { 78, 90, 101 })
	row("chuteCutAt: the prologue's limit", "chuteCutAt", { 78, 105, -1 })
	return rows
end

return table.freeze(CinematicTracks)
