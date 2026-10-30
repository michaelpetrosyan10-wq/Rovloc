--!strict
-- LightingController/Volumetrics: the visible air. Part of LightingController (the only writer of level lights and
-- Lighting); everything here is client-local and capped by the render budget (SetBudget).
--
--   * Moonlight. Every boarded window above street grade can spill cool moonlight (LightingMood.Moonlight): a
--     SpotLight just outside the opening, aimed in and down along the moon. Only the nearest `windowLights` windows
--     of the levels in focus burn, and only on levels whose film lets the moon in; the nearest `windowShadows` of
--     those are shadowed, so the planks stripe the floor; an unshadowed spill (it lights its whole cone) burns at the
--     planks' open share instead, and every spill burns at its level's fixture gain (LightingMood.render), like the
--     fixtures. Spills fade in and out, and lightning surges through them.
--   * Shafts. The nearest `shafts` light sources (burning fixtures whose kind has a FixtureGlow cone, and lit
--     windows) show a visible shaft: layered camera-facing Beams with no texture (a brighter core inside a fainter
--     sheath, so the edge is soft) that fade in at the source and out toward the floor. A fixture's cone follows its
--     glow level (a stuttering tube's cone stutters with it); a window's shaft is a ray through each of its widest
--     plank gaps (found once by probing the opening with short rays) plus a broad faint glow. The level's film
--     (`shafts`) decides how much the air shows.
--   * Dust. The nearest `dust` shafts carry a slow cloud of motes (a ParticleEmitter with the built-in smoke texture,
--     tiny and lit mostly by the scene, so they glint inside the light and all but vanish outside it).
-- Choosing happens at the controller's refresh (4 Hz): by distance from the camera, with whatever is behind it
-- counted as further away. Per frame only brightness is written, and only when it moved.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local FixtureGlow = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.FixtureGlow)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local LightingMood = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingMood)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Volumetrics = {}

local Moon = LightingMood.Moonlight

local UP = Vector3.new(0, 1, 0)
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds" -- built-in engine texture
local HOLDER_NAME = "LightingVolumetrics"

local FADE_RATE = 1.6 -- per second: a shaft or spill fades fully in or out in about 0.6 s
local WRITE_EPSILON = 0.01
local BEHIND_PENALTY = 1.8 -- a source behind the camera ranks as this much further away
local SHAFT_RANGE = 90 -- studs: no shaft beyond this
local DUST_RANGE = 45 -- studs: no dust beyond this (motes are invisible further out)
local WINDOW_RANGE = 120 -- studs: no moonlight spill beyond this
local WINDOW_FLASH = 3.2 -- a lightning flash multiplies the moonlight by up to 1 + this
local FLASH_MOON = Color3.fromRGB(214, 224, 255)
local MAX_BEAM_BRIGHTNESS = 4

-- Window probing
local PROBE_STEP = 0.1 -- studs between samples up the opening
local PROBE_COLUMNS = { -0.3, 0, 0.3 } -- sample columns across the opening (share of its width)
local PROBE_INSIDE = 2.2 -- probe rays start this far inside the wall line and run out through it
local PROBE_LENGTH = 4.6
local PROBES_PER_REFRESH = 4
local MAX_BANDS = 3
local MIN_BAND = 0.08

-- Window rig placement
local LIGHT_OUTSIDE = 1.7 -- the spill's light sits this far outside the wall line
local RAY_INSIDE = 1 -- shafts start this far inside the wall line (just past the planks)
local RAY_MIN, RAY_MAX = 4, 22

-- Dust
local DUST_RATE = 5 -- motes per second at particle scale 1 and film dust 1
local DUST_WARM = Color3.fromRGB(236, 230, 214)

export type Budget = {
	windowLights: number,
	windowShadows: number,
	shafts: number,
	dust: number,
	particleScale: number,
}

export type WindowSpec = {
	id: string,
	layoutId: string,
	center: Vector3, -- world: the middle of the opening, on the wall line
	inward: Vector3, -- unit, horizontal, into the room
	tangent: Vector3, -- unit, horizontal, along the wall
	width: number,
	height: number,
	direction: Vector3, -- unit: the way the moonlight travels through it
	floorY: number, -- world Y of the floor in front of it
}

export type Band = { y0: number, y1: number } -- open run up the opening, studs above its bottom

export type ConeCandidate = {
	fixture: BasePart,
	kind: string,
	position: Vector3,
	color: Color3,
}

export type Stats = { windows: number, windowLights: number, shafts: number, dust: number }

--------------------------------------------------------------------------------
-- Pure (specs: tests/Specs/ClientLighting.spec.luau)
--------------------------------------------------------------------------------

local INWARD: { [string]: Vector3 } = {
	N = Vector3.new(0, 0, 1),
	S = Vector3.new(0, 0, -1),
	W = Vector3.new(1, 0, 0),
	E = Vector3.new(-1, 0, 0),
}

-- The way moonlight travels in through a window whose room lies along `inward`: down at the moon's pitch, leaning
-- sideways by its skew (the same turn for every wall, so the rays of one facade run parallel).
function Volumetrics.moonDirection(inward: Vector3): Vector3
	local flat = Vector3.new(inward.X, 0, inward.Z)
	if flat.Magnitude < 1e-6 then
		return -Vector3.yAxis
	end
	local tangent = UP:Cross(flat.Unit)
	local across = (flat.Unit + tangent * Moon.skew).Unit
	return (across * math.cos(Moon.pitch) - Vector3.yAxis * math.sin(Moon.pitch)).Unit
end

-- Every window of `layout` the moon can reach (boarded or glazed; not those below street grade, which look into a
-- soil-filled light well), in world space.
function Volumetrics.windowSpecs(layout: LayoutSchema.LevelLayout): { WindowSpec }
	local out: { WindowSpec } = {}
	local windows = (layout.windows or {}) :: { LayoutSchema.Window }
	if #windows == 0 then
		return out
	end
	local layoutId: string = layout.id
	local rooms = LayoutSchema.indexRooms(layout)
	local origin = WorldConfig.levelOrigin(layout.id)
	local grade = if layout.id == "Lobby"
		then -math.huge
		else WorldConfig.GroundY - WorldConfig.levelElevation(layout.id)
	for index, window in windows do
		local room = rooms[window.room]
		local inward = INWARD[window.side]
		if not room or not inward or window.sill + window.height <= grade then
			continue
		end
		local rect = room.rect
		local x, z
		if window.side == "N" then
			x, z = window.at, rect.z
		elseif window.side == "S" then
			x, z = window.at, rect.z + rect.d
		elseif window.side == "W" then
			x, z = rect.x, window.at
		else
			x, z = rect.x + rect.w, window.at
		end
		table.insert(out, {
			id = string.format("%s:%d", layout.id, index),
			layoutId = layoutId,
			center = origin + Vector3.new(x, window.sill + window.height / 2, z),
			inward = inward,
			tangent = UP:Cross(inward),
			width = window.width,
			height = window.height,
			direction = Volumetrics.moonDirection(inward),
			floorY = origin.Y,
		})
	end
	return out
end

-- The open runs of a probed opening. `open[i]` says whether the sample `(i - 0.5) * step` above the bottom saw
-- through; runs shorter than `minHeight` are dropped and only the `maxBands` tallest are kept (bottom first). Also
-- returns the open share of all the samples.
function Volumetrics.gapBands(open: { boolean }, step: number, maxBands: number, minHeight: number): ({ Band }, number)
	local bands: { Band } = {}
	local count = 0
	local runStart: number? = nil
	for i = 1, #open + 1 do
		local isOpen = open[i] == true
		if isOpen then
			count += 1
			if runStart == nil then
				runStart = i
			end
		elseif runStart ~= nil then
			local band: Band = { y0 = (runStart - 1) * step, y1 = (i - 1) * step }
			if band.y1 - band.y0 >= minHeight - 1e-9 then
				table.insert(bands, band)
			end
			runStart = nil
		end
	end
	table.sort(bands, function(a: Band, b: Band): boolean
		return a.y1 - a.y0 > b.y1 - b.y0
	end)
	while #bands > maxBands do
		table.remove(bands)
	end
	table.sort(bands, function(a: Band, b: Band): boolean
		return a.y0 < b.y0
	end)
	return bands, if #open > 0 then count / #open else 0
end

-- Rank of a source at `position` seen from `view` (lower is nearer; behind the camera counts as further).
function Volumetrics.rank(view: CFrame, position: Vector3): number
	local offset = position - view.Position
	local distance = offset.Magnitude
	if distance < 1e-3 then
		return 0
	end
	local ahead = offset:Dot(view.LookVector) / distance
	return if ahead < 0 then distance * BEHIND_PENALTY else distance
end

-- Brightness of a moonlight spill (before its fade), on a level whose film lets in `moon`, during a lightning flash
-- of `flash` (0 when the sky is quiet).
function Volumetrics.moonBrightness(shadowed: boolean, moon: number, flash: number): number
	local share = if shadowed then 1 else Moon.unshadowedShare
	return Moon.brightness * share * math.max(0, moon) * (1 + WINDOW_FLASH * MathUtil.clamp01(flash))
end

-- Brightness of a window's shafts in air that shows `shafts`, with `moon` let in and a `flash` going.
function Volumetrics.rayBrightness(shafts: number, moon: number, flash: number): number
	return math.max(0, shafts) * math.min(1, math.max(0, moon)) * (1 + WINDOW_FLASH * MathUtil.clamp01(flash))
end

-- Dust motes per second for a shaft at particle scale `scale` in air carrying `dust`.
function Volumetrics.dustRate(scale: number, dust: number): number
	return DUST_RATE * math.max(0, scale) * math.max(0, dust)
end

--------------------------------------------------------------------------------
-- Runtime state
--------------------------------------------------------------------------------

type Layer = { beam: Beam, strength: number, written: number }

type Shaft = {
	layers: { Layer },
	emitter: ParticleEmitter?,
	emitterRate: number,
	color: Color3,
	want: boolean,
	dust: boolean,
	alpha: number,
	source: number, -- the source's own brightness factor this frame (cone level, or the moon's)
	anchors: { Instance }, -- what to destroy with it
}

type WindowRig = {
	spec: WindowSpec,
	probed: boolean,
	dark: boolean, -- probed and nothing sees through it
	bands: { Band },
	light: SpotLight?,
	lightAttachment: Attachment?,
	want: boolean,
	shadowed: boolean,
	alpha: number,
	written: number,
	tinted: boolean, -- the light carries a lightning tint that must be put back
	shaft: Shaft?,
}

type ConeRig = {
	fixture: BasePart,
	shape: FixtureGlow.ConeShape,
	color: Color3,
	level: number,
	shaft: Shaft?,
}

local budget: Budget = { windowLights = 0, windowShadows = 0, shafts = 0, dust = 0, particleScale = 1 }
local holder: Part? = nil
local layoutWindows: { [string]: { WindowRig } } = {}
local cones: { [BasePart]: ConeRig } = {}
local liveShafts: { [Shaft]: boolean } = {}
local liveWindows: { [WindowRig]: boolean } = {}
local film: LightingMood.Film = LightingMood.BaseFilm
local filmDust = -1

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

local function ensureHolder(): Part
	local existing = holder
	if existing and existing.Parent ~= nil then
		return existing
	end
	if existing then
		-- someone cleared the cosmetic folder: every window rig built on the old holder went with it
		for _, rigs in layoutWindows do
			for _, rig in rigs do
				if rig.shaft then
					liveShafts[rig.shaft :: Shaft] = nil
				end
				rig.light, rig.lightAttachment, rig.shaft = nil, nil, nil
				rig.alpha, rig.written = 0, -1
				liveWindows[rig] = nil
			end
		end
	end
	local part = Instance.new("Part")
	part.Name = HOLDER_NAME
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.identity
	part.Parent = Instances.cosmetic()
	holder = part
	return part
end

local function attachmentAt(parent: BasePart, name: string, world: CFrame): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.CFrame = parent.CFrame:ToObjectSpace(world)
	attachment.Parent = parent
	return attachment
end

local function newLayer(
	parent: Attachment,
	a1: Attachment,
	width0: number,
	width1: number,
	opacity: number,
	color: Color3
): Beam
	local beam = Instance.new("Beam")
	beam.Name = "Shaft"
	beam.Attachment0 = parent
	beam.Attachment1 = a1
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Width0 = width0
	beam.Width1 = width1
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Brightness = 0
	beam.Color = ColorSequence.new(color)
	-- transparent at the source, the densest stretch just past it, thinning out toward the far end
	local thick = 1 - opacity
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.12, thick),
		NumberSequenceKeypoint.new(0.5, thick + (1 - thick) * 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.Enabled = false
	beam.Parent = parent
	return beam
end

local function newEmitter(parent: Attachment, color: Color3): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Dust"
	emitter.Texture = SMOKE_TEXTURE
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(6, 10)
	emitter.Speed = NumberRange.new(0.12, 0.4)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, -0.03, 0)
	emitter.Drag = 0.35
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-25, 25)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 0.085),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, 0.3),
		NumberSequenceKeypoint.new(0.85, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Color = ColorSequence.new(color:Lerp(DUST_WARM, 0.6))
	emitter.LightInfluence = 0.9
	emitter.LightEmission = 0.3
	emitter.Brightness = 1.6
	emitter.Parent = parent
	return emitter
end

-- Shaft from `from` along `direction` for `length` studs: an inner core and a fainter, wider sheath.
type LayerSpec = { offset: Vector3, width0: number, width1: number, opacity: number, strength: number }

local function buildShaft(
	parent: BasePart,
	name: string,
	direction: Vector3,
	length: number,
	color: Color3,
	layers: { LayerSpec },
	dustAt: Vector3
): Shaft
	local shaft: Shaft = {
		layers = {},
		emitter = nil,
		emitterRate = -1,
		color = color,
		want = false,
		dust = false,
		alpha = 0,
		source = 0,
		anchors = {},
	}
	for index, spec in layers do
		local a0 = attachmentAt(parent, string.format("%s_%d_0", name, index), CFrame.new(spec.offset))
		local a1 =
			attachmentAt(parent, string.format("%s_%d_1", name, index), CFrame.new(spec.offset + direction * length))
		local beam = newLayer(a0, a1, spec.width0, spec.width1, spec.opacity, color)
		table.insert(shaft.layers, { beam = beam, strength = spec.strength, written = -1 })
		table.insert(shaft.anchors, a0)
		table.insert(shaft.anchors, a1)
	end
	local dustAttachment = attachmentAt(parent, name .. "_Dust", CFrame.new(dustAt))
	shaft.emitter = newEmitter(dustAttachment, color)
	table.insert(shaft.anchors, dustAttachment)
	return shaft
end

local function destroyShaft(shaft: Shaft)
	liveShafts[shaft] = nil
	for _, anchor in shaft.anchors do
		anchor:Destroy()
	end
	table.clear(shaft.anchors)
	table.clear(shaft.layers)
	shaft.emitter = nil
end

local function worldParams(): RaycastParams?
	local include: { Instance } = {}
	local school = Instances.school()
	if school then
		table.insert(include, school)
	end
	local lobby = Instances.lobby()
	if lobby then
		table.insert(include, lobby)
	end
	if #include == 0 then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = include
	params.IgnoreWater = true
	return params
end

-- How far a shaft from `from` along `direction` runs before it meets something (nil: nothing within `limit`).
local function reach(from: Vector3, direction: Vector3, limit: number, params: RaycastParams): number?
	local hit = Workspace:Raycast(from, direction * limit, params)
	return if hit then hit.Distance else nil
end

-- Windows: probe the opening once (its planks belong to the shell builder, so what lets light through is measured,
-- not assumed).
local function probe(rig: WindowRig): boolean
	local root = Instances.layoutRoot(rig.spec.layoutId)
	if not root then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { root }
	params.IgnoreWater = true
	local spec = rig.spec
	local samples = math.max(1, math.floor(spec.height / PROBE_STEP))
	local bottom = spec.center - Vector3.yAxis * (spec.height / 2)
	local open: { boolean } = {}
	local seen = 0
	for i = 1, samples do
		local y = (i - 0.5) * PROBE_STEP
		local rowOpen = false
		for _, column in PROBE_COLUMNS do
			local at = bottom + Vector3.yAxis * y + spec.tangent * (column * spec.width)
			local start = at + spec.inward * PROBE_INSIDE
			if not Workspace:Raycast(start, -spec.inward * PROBE_LENGTH, params) then
				rowOpen = true
				seen += 1
			end
		end
		open[i] = rowOpen
	end
	local bands, rowShare = Volumetrics.gapBands(open, PROBE_STEP, MAX_BANDS, MIN_BAND)
	rig.probed = true
	rig.bands = bands
	rig.dark = seen == 0 or rowShare <= 0
	return true
end

local function buildWindowLight(rig: WindowRig)
	local parent = ensureHolder()
	local spec = rig.spec
	local at = spec.center - spec.inward * LIGHT_OUTSIDE
	local attachment = attachmentAt(parent, "Moon_" .. spec.id, CFrame.lookAt(at, at + spec.direction))
	local light = Instance.new("SpotLight")
	light.Name = "Moonlight"
	light.Face = Enum.NormalId.Front
	light.Angle = Moon.angle
	light.Range = Moon.range
	light.Color = Moon.color
	light.Brightness = 0
	light.Shadows = false
	light.Enabled = false
	light.Parent = attachment
	rig.light = light
	rig.lightAttachment = attachment
	rig.written = -1
end

local function buildWindowShaft(rig: WindowRig): Shaft
	local parent = ensureHolder()
	local spec = rig.spec
	local start = spec.center + spec.inward * RAY_INSIDE
	local drop = -spec.direction.Y
	local function lengthFrom(y: number): number
		if drop <= 1e-3 then
			return RAY_MAX
		end
		return math.clamp((y - spec.floorY) / drop, RAY_MIN, RAY_MAX)
	end
	local bottom = -spec.height / 2
	local layers: { LayerSpec } = {}
	for _, band in rig.bands do
		local mid = bottom + (band.y0 + band.y1) / 2
		local thick = band.y1 - band.y0
		local width0 = thick * 1.3 + 0.12
		table.insert(layers, {
			offset = start + Vector3.yAxis * mid,
			width0 = width0,
			width1 = width0 * 2.4,
			opacity = 0.1,
			strength = 0.9,
		})
	end
	table.insert(layers, {
		offset = start,
		width0 = spec.width * 0.7,
		width1 = spec.width * 1.15,
		opacity = 0.032,
		strength = 1,
	})
	local length = lengthFrom(start.Y)
	local shaft = buildShaft(
		parent,
		"Ray_" .. spec.id,
		spec.direction,
		length,
		Moon.color,
		layers,
		start + spec.direction * (length * 0.45)
	)
	-- every layer's own length: rays from higher gaps travel further before they reach the floor
	for index, layer in shaft.layers do
		local layerSpec = layers[index]
		local a1 = layer.beam.Attachment1
		if a1 then
			local own = lengthFrom(layerSpec.offset.Y)
			a1.CFrame = parent.CFrame:ToObjectSpace(CFrame.new(layerSpec.offset + spec.direction * own))
		end
	end
	return shaft
end

local function coneGeometry(rig: ConeRig): (Vector3, Vector3)
	local fixture = rig.fixture
	local cframe = fixture.CFrame
	if rig.shape.aimed then
		return cframe.Position + cframe.LookVector * (fixture.Size.Z / 2 + 0.3), cframe.LookVector
	end
	return cframe.Position - Vector3.yAxis * (fixture.Size.Y / 2 + 0.15), -Vector3.yAxis
end

local function buildCone(rig: ConeRig): Shaft?
	local params = worldParams()
	if not params then
		return nil
	end
	local from, direction = coneGeometry(rig)
	local shape = rig.shape
	local length = reach(from, direction, shape.length, params) or shape.length
	length = math.max(2.5, length)
	local fixture = rig.fixture
	local base = fixture.CFrame
	local function here(world: Vector3): Vector3
		return base:PointToObjectSpace(world)
	end
	local localDirection = base:VectorToObjectSpace(direction)
	local layers: { LayerSpec } = {
		{ offset = here(from), width0 = shape.width0, width1 = shape.width1, opacity = 0.045, strength = 1 },
		{
			offset = here(from),
			width0 = shape.width0 * 0.45,
			width1 = shape.width1 * 0.55,
			opacity = 0.07,
			strength = 1,
		},
	}
	-- the cone's attachments live on the fixture, in its own space
	local shaft: Shaft = {
		layers = {},
		emitter = nil,
		emitterRate = -1,
		color = rig.color,
		want = false,
		dust = false,
		alpha = 0,
		source = 0,
		anchors = {},
	}
	for index, spec in layers do
		local a0 = Instance.new("Attachment")
		a0.Name = string.format("Haze_%d_0", index)
		a0.Position = spec.offset
		a0.Parent = fixture
		local a1 = Instance.new("Attachment")
		a1.Name = string.format("Haze_%d_1", index)
		a1.Position = spec.offset + localDirection * length
		a1.Parent = fixture
		local beam = newLayer(a0, a1, spec.width0, spec.width1, spec.opacity, rig.color)
		table.insert(shaft.layers, { beam = beam, strength = spec.strength, written = -1 })
		table.insert(shaft.anchors, a0)
		table.insert(shaft.anchors, a1)
	end
	local dust = Instance.new("Attachment")
	dust.Name = "Haze_Dust"
	dust.Position = here(from + direction * (length * 0.5))
	dust.Parent = fixture
	shaft.emitter = newEmitter(dust, rig.color)
	table.insert(shaft.anchors, dust)
	return shaft
end

--------------------------------------------------------------------------------
-- Choosing
--------------------------------------------------------------------------------

type Candidate = { rank: number, window: WindowRig?, cone: ConeRig? }

local function windowsOf(layoutId: string): { WindowRig }
	local rigs = layoutWindows[layoutId]
	if rigs then
		return rigs
	end
	local list: { WindowRig } = {}
	local layout = Builder.getLayout(layoutId)
	if layout then
		for _, spec in Volumetrics.windowSpecs(layout) do
			table.insert(list, {
				spec = spec,
				probed = false,
				dark = false,
				bands = {},
				light = nil,
				lightAttachment = nil,
				want = false,
				shadowed = false,
				alpha = 0,
				written = -1,
				tinted = false,
				shaft = nil,
			})
		end
	end
	layoutWindows[layoutId] = list
	return list
end

local function setShaftWant(shaft: Shaft?, want: boolean, dust: boolean)
	if not shaft then
		return
	end
	shaft.want = want
	shaft.dust = want and dust
	if want or shaft.alpha > 0 then
		liveShafts[shaft] = true
	end
end

-- Picks this refresh's spills, shafts and dust. `view` is the camera; `focus` the layouts whose windows may burn;
-- `candidates` the burning fixtures in the light budget.
function Volumetrics.Refresh(view: CFrame, focus: { [string]: boolean }, candidates: { ConeCandidate })
	-- moonlight spills
	local windowList: { Candidate } = {}
	for layoutId in focus do
		if LightingMood.film(layoutId).moon <= 0 then
			continue
		end
		for _, rig in windowsOf(layoutId) do
			if not rig.dark then
				local rank = Volumetrics.rank(view, rig.spec.center)
				if rank <= WINDOW_RANGE then
					table.insert(windowList, { rank = rank, window = rig, cone = nil })
				end
			end
		end
	end
	table.sort(windowList, function(a: Candidate, b: Candidate): boolean
		return a.rank < b.rank
	end)
	local wantedWindows: { [WindowRig]: boolean } = {}
	local probes = 0
	local lit = 0
	for _, candidate in windowList do
		if lit >= budget.windowLights then
			break
		end
		local rig = candidate.window :: WindowRig
		if not rig.probed then
			if probes >= PROBES_PER_REFRESH then
				continue
			end
			probes += 1
			if not probe(rig) or rig.dark then
				continue
			end
		end
		lit += 1
		wantedWindows[rig] = true
		rig.shadowed = lit <= budget.windowShadows
		if not rig.light then
			buildWindowLight(rig)
		end
		local light = rig.light
		if light and light.Shadows ~= rig.shadowed then
			light.Shadows = rig.shadowed
			rig.written = -1
		end
	end
	for _, rigs in layoutWindows do
		for _, rig in rigs do
			local want = wantedWindows[rig] == true
			rig.want = want
			if want or rig.alpha > 0 then
				liveWindows[rig] = true
			end
		end
	end

	-- shafts and dust: lit windows and burning fixtures, nearest first
	local sources: { Candidate } = {}
	for rig in wantedWindows do
		local rank = Volumetrics.rank(view, rig.spec.center)
		if rank <= SHAFT_RANGE then
			table.insert(sources, { rank = rank, window = rig, cone = nil })
		end
	end
	local seenCones: { [ConeRig]: boolean } = {}
	for _, candidate in candidates do
		local shape = FixtureGlow.cone(candidate.kind)
		if not shape then
			continue
		end
		local rank = Volumetrics.rank(view, candidate.position)
		if rank > SHAFT_RANGE then
			continue
		end
		local rig = cones[candidate.fixture]
		if not rig then
			rig = {
				fixture = candidate.fixture,
				shape = shape,
				color = candidate.color,
				level = 0,
				shaft = nil,
			}
			cones[candidate.fixture] = rig
		end
		local cone = rig :: ConeRig
		seenCones[cone] = true
		table.insert(sources, { rank = rank, window = nil, cone = cone })
	end
	table.sort(sources, function(a: Candidate, b: Candidate): boolean
		return a.rank < b.rank
	end)
	local chosen: { [Shaft]: boolean } = {}
	local shafts, dusty = 0, 0
	for _, source in sources do
		if shafts >= budget.shafts then
			break
		end
		local shaft: Shaft? = nil
		local window, cone = source.window, source.cone
		if window then
			if not window.shaft then
				window.shaft = buildWindowShaft(window)
			end
			shaft = window.shaft
		elseif cone then
			if not cone.shaft then
				cone.shaft = buildCone(cone)
				if not cone.shaft then
					continue -- no world to measure against yet; try again next refresh
				end
			end
			shaft = cone.shaft
		end
		if shaft then
			shafts += 1
			local dust = dusty < budget.dust and source.rank <= DUST_RANGE
			if dust then
				dusty += 1
			end
			chosen[shaft] = true
			setShaftWant(shaft, true, dust)
		end
	end
	for _, rigs in layoutWindows do
		for _, rig in rigs do
			local shaft = rig.shaft
			if shaft and not chosen[shaft] then
				setShaftWant(shaft, false, false)
			end
		end
	end
	for _, rig in cones do
		local shaft = rig.shaft
		if shaft and not chosen[shaft] then
			setShaftWant(shaft, false, false)
		end
		if not seenCones[rig] and not shaft then
			cones[rig.fixture] = nil -- never drawn and out of the budget: nothing to keep
		end
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function writeShaft(shaft: Shaft, brightness: number)
	local on = brightness > WRITE_EPSILON
	for _, layer in shaft.layers do
		local value = math.min(MAX_BEAM_BRIGHTNESS, brightness * layer.strength)
		if on ~= layer.beam.Enabled then
			layer.beam.Enabled = on
		end
		if on and math.abs(value - layer.written) > WRITE_EPSILON then
			layer.beam.Brightness = value
			layer.written = value
		end
	end
	local emitter = shaft.emitter
	if emitter then
		local dusting = shaft.dust and on
		if emitter.Enabled ~= dusting then
			emitter.Enabled = dusting
		end
		if dusting then
			local rate = Volumetrics.dustRate(budget.particleScale, film.dust)
			if math.abs(rate - shaft.emitterRate) > 0.05 then
				emitter.Rate = rate
				shaft.emitterRate = rate
			end
		end
	end
end

-- Fades and brightens everything chosen at the last refresh. `grade` is the film on screen; `flash` the lightning
-- envelope this frame (0..1, before the indoor damping: a window sees the sky itself).
function Volumetrics.Step(dt: number, grade: LightingMood.Film, flash: number)
	film = grade
	if grade.dust ~= filmDust then
		filmDust = grade.dust
		for shaft in liveShafts do
			shaft.emitterRate = -1
		end
	end
	local fade = FADE_RATE * math.max(0, dt)
	local flashColor = Moon.color:Lerp(FLASH_MOON, MathUtil.clamp01(flash))

	for rig in liveWindows do
		rig.alpha = MathUtil.approach(rig.alpha, if rig.want then 1 else 0, fade)
		local light = rig.light
		local moon = LightingMood.film(rig.spec.layoutId).moon
		-- the spill is one of the level's lights to the parity fit (LightingMood.render): it burns at the same gain
		local gain = LightingMood.render(rig.spec.layoutId).fixtureGain
		local brightness = rig.alpha * gain * Volumetrics.moonBrightness(rig.shadowed, moon, flash)
		if light then
			local on = brightness > WRITE_EPSILON
			if light.Enabled ~= on then
				light.Enabled = on
			end
			if on and math.abs(brightness - rig.written) > WRITE_EPSILON then
				light.Brightness = brightness
				rig.written = brightness
			end
			if flash > 0 then
				light.Color = flashColor
				rig.tinted = true
			elseif rig.tinted then
				light.Color = Moon.color
				rig.tinted = false
			end
		end
		local shaft = rig.shaft
		if shaft then
			shaft.source = rig.alpha * Volumetrics.rayBrightness(grade.shafts, moon, flash)
		end
		if not rig.want and rig.alpha <= 0 then
			liveWindows[rig] = nil
		end
	end

	for _, rig in cones do
		local shaft = rig.shaft
		if shaft then
			shaft.source = FixtureGlow.coneBrightness(rig.shape, rig.level, grade.shafts)
		end
	end

	for shaft in liveShafts do
		shaft.alpha = MathUtil.approach(shaft.alpha, if shaft.want then 1 else 0, fade)
		writeShaft(shaft, shaft.alpha * shaft.source)
		if not shaft.want and shaft.alpha <= 0 then
			liveShafts[shaft] = nil
		end
	end
end

--------------------------------------------------------------------------------
-- Public (LightingController)
--------------------------------------------------------------------------------

function Volumetrics.SetBudget(value: Budget)
	budget = {
		windowLights = math.max(0, math.floor(value.windowLights)),
		windowShadows = math.max(0, math.floor(value.windowShadows)),
		shafts = math.max(0, math.floor(value.shafts)),
		dust = math.max(0, math.floor(value.dust)),
		particleScale = math.clamp(value.particleScale, 0, 1),
	}
	for shaft in liveShafts do
		shaft.emitterRate = -1
	end
end

-- A fixture's glow level this frame (its cone, if it has one, follows it).
function Volumetrics.ConeLevel(fixture: BasePart, level: number)
	local rig = cones[fixture]
	if rig then
		rig.level = level
	end
end

-- A fixture left the registry: its cone goes with it.
function Volumetrics.Forget(fixture: BasePart)
	local rig = cones[fixture]
	if not rig then
		return
	end
	cones[fixture] = nil
	local shaft = rig.shaft
	if shaft then
		destroyShaft(shaft)
	end
end

function Volumetrics.GetStats(): Stats
	local windows, spills, shafts, dust = 0, 0, 0, 0
	for _, rigs in layoutWindows do
		windows += #rigs
		for _, rig in rigs do
			if rig.light and rig.light.Enabled then
				spills += 1
			end
		end
	end
	for shaft in liveShafts do
		if shaft.want then
			shafts += 1
			if shaft.dust then
				dust += 1
			end
		end
	end
	return { windows = windows, windowLights = spills, shafts = shafts, dust = dust }
end

return table.freeze(Volumetrics)
