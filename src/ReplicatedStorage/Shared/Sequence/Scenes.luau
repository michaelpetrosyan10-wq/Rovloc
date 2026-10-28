--!strict
-- Scenes: the scripted level moments as data, shared by the server (which times its authoritative beats from the
-- same constants) and the clients (LevelScenesController registers every timeline and the track kinds they use).
--
-- Floor 1, the classroom scare ("L1_ClassroomScare", seconds from the OneShot's startAt):
--   0.00  glass crunches under the subject's feet; the subject's camera stumbles (Flinch) and panic jumps.
--   0.42  the Creature's head and upper torso wrench 180 degrees round (creature track NeckSnap + its sound). The
--         server has turned the body's back to the subject a moment before, so the stare lands on them; a subject
--         with a clear line to it has their view dragged onto its face (PullWeight) and held there.
--   0.92  the hush: the ambience drops away under one heavy heartbeat (everyone near).
--   2.05  the classroom glow bursts (the spill fixture a beat later); the strobing stutter, then darkness.
--   2.15  the Creature glitches out (CreatureVanish); the server hides it at 2.43, as the bulbs die.
--   2.65  the subject's view is handed back, still on the empty corner.
--   3.55  the hallway gate lands shut (DoorService; GateSlam and its shake belong to the doors).
-- The server then moves the hidden Creature out of sight and lets it hunt 6-9 s after the slam.
-- "L1_GlassStep" is the same crunch and stumble alone, for a scare that cannot play (the Creature was busy).
--
-- Floor 0, the basement beats (positional, played 25-45 studs from a player, out of sight): a bang in the pipes, a
-- boiler surge that makes the nearby bulbs stutter, something dragging away across the ceiling, a child's whisper or
-- giggle, an object clattering to the floor.
--
-- Floor 3, the locker-room beats (positional, out of sight, from Level3_GymnasiumController): a showerhead dripping
-- onto tile, a locker door banging (or rattling) somewhere in the changing rooms, a basketball bouncing to rest far off
-- in the dark gym.
--
-- Track kinds beyond SequenceController's built-ins ("sound", "light", "callback") and CreatureController's
-- "creature" are LevelScenesController's: Tracks.* below. Pure camera maths (Flinch, PullWeight, Pulled) are specced
-- in tests/Specs/Levels.spec.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Timeline = require(ReplicatedStorage.Shared.Sequence.Timeline)

type Spec = Timeline.Spec
type Track = Timeline.Track
type Key = Timeline.Key

export type BeatKind = "PipeBang" | "BoilerSurge" | "CeilingDrag" | "ChildVoice" | "FallingObject"

export type GymBeatKind = "ShowerDrip" | "LockerBang" | "BallBounce"

export type ClassroomScare = {
	Id: string,
	SkippedId: string,
	Snap: number,
	Hush: number,
	Burst: number,
	SpillStagger: number,
	Vanish: number,
	Hide: number,
	CameraEnd: number,
	KillLights: number,
	GateLand: number,
	SkippedGateLand: number,
	Relocate: number,
	Duration: number,
	FaceLead: number,
	ReleaseMin: number,
	ReleaseMax: number,
	Flinch: number,
	HushRadius: number,
}

local Scenes = {}

-- Play args (OneShot args of the Timeline).
local ARGS = table.freeze({
	Subject = "subject", -- UserId of the player the scene is about (number)
	Feet = "feet", -- Vector3: where the glass crunched
	Head = "head", -- Vector3: the Creature's eyes
	Focus = "focus", -- boolean: the subject has a clear line to the Creature (their view is dragged onto it)
	Glow = "glow", -- Vector3: the classroom glow fixture
	Spill = "spill", -- Vector3: the doorway spill fixture
	At = "at", -- Vector3: a basement beat's source
	From = "from", -- Vector3: where a moving source starts
	To = "to", -- Vector3: where it ends
	Light1 = "light1", -- string light ids a surge flickers
	Light2 = "light2",
	Light3 = "light3",
	Light4 = "light4",
})
Scenes.Args = ARGS

-- LevelScenesController's track kinds.
local TRACKS = table.freeze({
	SubjectCamera = "sceneCamera", -- events "Flinch" (start) / "Release" (end, persists): the subject's camera
	SubjectPanic = "scenePanic", -- continuous number: the subject's panic floor
	NearSound = "nearSound", -- events: a 2D preset for listeners within HushRadius of the track's `arg` point
	MovingSound = "movingSound", -- continuous 0..1: the `target` preset travelling from args.from to args.to
	LightScale = "lightScale", -- continuous factor of the `arg` light's BaseBrightness (LightingController override)
})
Scenes.Tracks = TRACKS

local SNAP = 0.42
local BURST = 2.05
local GATE_LAND = 3.55

local CLASSROOM: ClassroomScare = table.freeze({
	Id = "L1_ClassroomScare",
	SkippedId = "L1_GlassStep",
	Snap = SNAP,
	Hush = SNAP + 0.5,
	Burst = BURST,
	SpillStagger = 0.07,
	Vanish = BURST + 0.1,
	Hide = BURST + 0.38,
	CameraEnd = BURST + 0.6,
	KillLights = BURST + 1.2,
	GateLand = GATE_LAND,
	SkippedGateLand = 1.1, -- the gate lands this soon after a crunch whose scare could not play
	Relocate = GATE_LAND + 0.4,
	Duration = GATE_LAND + 1,
	FaceLead = 0.05, -- the body turns its back to the subject this long before the snap (replication)
	ReleaseMin = 6, -- seconds after the slam before the Creature hunts
	ReleaseMax = 9,
	Flinch = 0.75, -- seconds the stumble lasts
	HushRadius = 70, -- listeners this close to the Creature hear the hush
})
Scenes.ClassroomScare = CLASSROOM

-- Every basement beat kind, in a fixed order (the director's seeded picks index into it).
local BEAT_KINDS: { BeatKind } = { "PipeBang", "BoilerSurge", "CeilingDrag", "ChildVoice", "FallingObject" }
Scenes.BeatKinds = table.freeze(table.clone(BEAT_KINDS))

-- The beat kinds as a fresh typed list.
function Scenes.beatKinds(): { BeatKind }
	return table.clone(BEAT_KINDS)
end

-- Timeline id per beat (ChildVoice picks one of two).
Scenes.BeatIds = table.freeze({
	PipeBang = { "L0_PipeBang" },
	BoilerSurge = { "L0_BoilerSurge" },
	CeilingDrag = { "L0_CeilingDrag" },
	ChildVoice = { "L0_ChildWhisper", "L0_ChildLaugh" },
	FallingObject = { "L0_FallingObject" },
} :: { [string]: { string } })

-- The falling object lands this long after its beat's startAt (the server emits its noise then).
Scenes.FallImpact = 0
-- A ceiling drag travels this far (studs) away from the listener over CeilingDragSeconds.
Scenes.CeilingDragDistance = 16
Scenes.CeilingDragSeconds = 3.6
-- How many bulbs a boiler surge can stutter.
Scenes.SurgeLights = 4

-- Every Floor 3 beat kind, in a fixed order (the director's seeded picks index into it).
local GYM_BEAT_KINDS: { GymBeatKind } = { "ShowerDrip", "LockerBang", "BallBounce" }
Scenes.GymBeatKinds = table.freeze(table.clone(GYM_BEAT_KINDS))

function Scenes.gymBeatKinds(): { GymBeatKind }
	return table.clone(GYM_BEAT_KINDS)
end

-- Timeline id per Floor 3 beat (a locker bang is a slam or a rattle).
Scenes.GymBeatIds = table.freeze({
	ShowerDrip = { "L3_ShowerDrip" },
	LockerBang = { "L3_LockerBang", "L3_LockerRattle" },
	BallBounce = { "L3_BallBounce" },
} :: { [string]: { string } })

-- The ball's bounces (seconds from the beat's start, volume): each one lower and sooner, coming to rest.
Scenes.BallBounces = table.freeze({
	{ t = 0, volume = 1.2 },
	{ t = 0.62, volume = 1.05 },
	{ t = 1.13, volume = 0.9 },
	{ t = 1.54, volume = 0.76 },
	{ t = 1.87, volume = 0.62 },
	{ t = 2.13, volume = 0.5 },
	{ t = 2.33, volume = 0.38 },
	{ t = 2.48, volume = 0.28 },
	{ t = 2.59, volume = 0.2 },
} :: { { t: number, volume: number } })

--------------------------------------------------------------------------------
-- Pure camera maths (the subject's stumble and the drag onto the Creature's face)
--------------------------------------------------------------------------------

-- The stumble offset `t` seconds into the scene (applied in eye space after the look): a hard jolt down toward the
-- feet with a lurching roll and a knee-buckle dip, settling back to nothing by CLASSROOM.Flinch. `scale` is the
-- MotionScale setting (0 = no motion at all).
function Scenes.Flinch(t: number, scale: number): CFrame
	local amount = MathUtil.clamp01(scale)
	if t <= 0 or t >= CLASSROOM.Flinch or amount <= 0 then
		return CFrame.identity
	end
	local attack = MathUtil.smoothstep(0, 0.07, t)
	local decay = math.exp(-5.5 * math.max(0, t - 0.07))
	local fade = 1 - MathUtil.smoothstep(CLASSROOM.Flinch - 0.15, CLASSROOM.Flinch, t)
	local envelope = attack * decay * fade * amount
	local pitch = -math.rad(13) * envelope
	local roll = math.rad(5) * envelope * math.cos(t * 19)
	local yaw = math.rad(1.6) * envelope * math.sin(t * 41)
	local dip = -0.3 * envelope
	return CFrame.new(0, dip, 0) * CFrame.Angles(pitch, yaw, roll)
end

-- How far the subject's view is dragged onto the Creature (0 = their own look, 1 = locked on its face): it starts
-- with the snap and holds once there; the "Release" key at CameraEnd hands the locked look back to the player.
function Scenes.PullWeight(t: number): number
	local start = CLASSROOM.Snap - 0.02
	if t <= start then
		return 0
	end
	local rise = MathUtil.clamp01((t - start) / 0.32)
	return 1 - (1 - rise) ^ 3
end

-- `eye` turned toward `target` by `weight` (position kept). A target at the eye leaves it alone.
function Scenes.Pulled(eye: CFrame, target: Vector3, weight: number): CFrame
	local w = MathUtil.clamp01(weight)
	local delta = target - eye.Position
	if w <= 0 or delta.Magnitude < 1e-3 then
		return eye
	end
	local locked = CFrame.lookAt(eye.Position, target)
	return eye:Lerp(locked, w)
end

--------------------------------------------------------------------------------
-- Timelines
--------------------------------------------------------------------------------

local function key(t: number, value: Timeline.Value, ease: Timeline.Ease?, persist: boolean?): Key
	return { t = t, value = value, ease = ease, persist = persist }
end

local function sound(arg: string, preset: string, t: number, volume: number?): Track
	return { kind = "sound", arg = arg, volume = volume, keys = { key(t, preset) } }
end

local function classroomScare(): Spec
	local c = CLASSROOM
	return {
		duration = c.Duration,
		tracks = {
			sound(ARGS.Feet, "GlassCrunch", 0, 1.7),
			{
				kind = TRACKS.SubjectCamera,
				keys = { key(0, "Flinch"), key(c.CameraEnd, "Release", nil, true) },
			},
			{
				kind = TRACKS.SubjectPanic,
				keys = {
					key(0, 0.35),
					key(c.Snap, 0.4),
					key(c.Snap + 0.15, 0.95, "OutQuad"),
					key(c.GateLand + 0.4, 0.95),
					key(c.Duration, 0.7, "InOutSine"),
				},
			},
			{ kind = "creature", keys = { key(c.Snap, "NeckSnap") } },
			sound(ARGS.Head, "NeckSnap", c.Snap, 1.3),
			{ kind = TRACKS.NearSound, arg = ARGS.Head, keys = { key(c.Hush, "ScareHush") } },
			sound(ARGS.Glow, "LightBurst", c.Burst, 1.2),
			sound(ARGS.Spill, "LightBurst", c.Burst + c.SpillStagger, 0.9),
			sound(ARGS.Head, "CreatureVanish", c.Vanish),
		},
	}
end

local function glassStep(): Spec
	return {
		duration = CLASSROOM.Flinch + 0.5,
		tracks = {
			sound(ARGS.Feet, "GlassCrunch", 0, 1.7),
			{
				kind = TRACKS.SubjectCamera,
				keys = { key(0, "Flinch"), key(CLASSROOM.Flinch, "Release", nil, true) },
			},
			{
				kind = TRACKS.SubjectPanic,
				keys = { key(0, 0.35), key(CLASSROOM.Flinch + 0.5, 0.2, "InOutSine") },
			},
		},
	}
end

-- A bulb's stutter during a boiler surge: a swell as the burner roars, dropouts, a sag, recovery. `offset` staggers
-- the bulbs so they do not blink in lockstep.
local function surgeTrack(arg: string, offset: number): Track
	local o = offset
	return {
		kind = TRACKS.LightScale,
		arg = arg,
		keys = {
			key(0, 1),
			key(0.25 + o, 1.7, "OutQuad"),
			key(0.33 + o, 0.15, "Step"),
			key(0.41 + o, 1.4, "Step"),
			key(0.62 + o, 0.05, "Step"),
			key(0.78 + o, 1.2, "OutQuad"),
			key(1.1 + o, 0.3, "InQuad"),
			key(1.18 + o, 0.9, "Step"),
			key(1.6 + o, 0.55, "InOutSine"),
			key(2.3 + o, 1, "InOutSine"),
		},
	}
end

local function beats(): { [string]: Spec }
	return {
		L0_PipeBang = { duration = 3, tracks = { sound(ARGS.At, "PipeBang", 0, 1.2) } },
		L0_BoilerSurge = {
			duration = 2.8,
			tracks = {
				sound(ARGS.At, "BoilerSurge", 0, 1.1),
				surgeTrack(ARGS.Light1, 0),
				surgeTrack(ARGS.Light2, 0.06),
				surgeTrack(ARGS.Light3, 0.11),
				surgeTrack(ARGS.Light4, 0.17),
			},
		},
		L0_CeilingDrag = {
			duration = Scenes.CeilingDragSeconds + 0.2,
			tracks = {
				{
					kind = TRACKS.MovingSound,
					target = "CeilingDrag",
					volume = 1.1,
					keys = { key(0, 0), key(Scenes.CeilingDragSeconds, 1, "InOutSine") },
				},
			},
		},
		L0_ChildWhisper = { duration = 3.6, tracks = { sound(ARGS.At, "ChildWhisper", 0, 1) } },
		L0_ChildLaugh = { duration = 2.6, tracks = { sound(ARGS.At, "ChildLaugh", 0, 1) } },
		L0_FallingObject = { duration = 2, tracks = { sound(ARGS.At, "ObjectFall", Scenes.FallImpact, 1.2) } },
	}
end

-- A showerhead's sputter of drops, the gaps uneven.
local SHOWER_DROPS: { { t: number, volume: number } } = {
	{ t = 0, volume = 1 },
	{ t = 0.58, volume = 0.75 },
	{ t = 1.02, volume = 0.9 },
	{ t = 1.66, volume = 0.65 },
	{ t = 2.08, volume = 0.85 },
	{ t = 2.86, volume = 0.6 },
	{ t = 3.3, volume = 0.8 },
	{ t = 4.15, volume = 0.55 },
}

-- Something worrying at a locker door: short shakes of the latch.
local RATTLES: { { t: number, volume: number } } = {
	{ t = 0, volume = 0.9 },
	{ t = 0.17, volume = 0.7 },
	{ t = 0.31, volume = 0.85 },
	{ t = 0.5, volume = 0.6 },
	{ t = 1.35, volume = 0.75 },
	{ t = 1.5, volume = 0.55 },
}

-- One "sound" track per hit, so every hit keeps its own volume.
local function hits(preset: string, list: { { t: number, volume: number } }): { Track }
	local tracks: { Track } = {}
	for _, hit in list do
		table.insert(tracks, sound(ARGS.At, preset, hit.t, hit.volume))
	end
	return tracks
end

local function gymBeats(): { [string]: Spec }
	local bounces = Scenes.BallBounces :: { { t: number, volume: number } }
	return {
		L3_ShowerDrip = { duration = 4.8, tracks = hits("ShowerDrip", SHOWER_DROPS) },
		L3_LockerBang = {
			duration = 2.4,
			tracks = {
				sound(ARGS.At, "LockerSlam", 0, 1.2),
				sound(ARGS.At, "LockerSlam", 0.52, 0.55),
				sound(ARGS.At, "LockerDoor", 0.86, 0.6),
			},
		},
		L3_LockerRattle = { duration = 2.2, tracks = hits("LockerDoor", RATTLES) },
		L3_BallBounce = { duration = 3.4, tracks = hits("BallBounce", bounces) },
	}
end

-- The timeline ids a Floor 3 beat of `kind` can play.
function Scenes.gymBeatIds(kind: GymBeatKind): { string }
	return Scenes.GymBeatIds[kind] or {}
end

-- Every scene timeline by id (fresh tables; callers register them).
function Scenes.timelines(): { [string]: Spec }
	local out = beats()
	for id, spec in gymBeats() do
		out[id] = spec
	end
	out[CLASSROOM.Id] = classroomScare()
	out[CLASSROOM.SkippedId] = glassStep()
	return out
end

-- The timeline ids a basement beat of `kind` can play.
function Scenes.beatIds(kind: BeatKind): { string }
	return Scenes.BeatIds[kind] or {}
end

return table.freeze(Scenes)
