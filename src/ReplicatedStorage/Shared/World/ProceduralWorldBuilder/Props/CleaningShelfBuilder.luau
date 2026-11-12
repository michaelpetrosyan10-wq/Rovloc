--!strict
-- CleaningShelfBuilder: Gus Pruitt's chemical shelves (docs/design/game-spec-v2.md 4.2, 4.3; static kind
-- "CleaningShelf": once at boot, into <level>.Props). Every FlaskCandidate that no platform and no mop cart carries
-- (ExtraAnchors' niche spots over the drums, the boiler room's wall shelf) gets a steel wall shelf under it: a board
-- whose top is the spot's height, two brackets, and a gallon jug and a spray bottle of his stock at either end, clear of
-- the flask's foot. The board and brackets are seen and queried but never collide (nobody stands where they hang) and
-- are never Detail (they carry a stun flask's spot); the jugs are Detail 3.
--
-- Shelf space (the anchor's frame): origin at the flask's foot, -Z out of the wall, the wall NICHE_WALL behind it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)

type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor

local W = Attributes.World

local rgb = Color3.fromRGB

local WALL_GAP = 0.55 -- the flask's foot off the wall (ExtraAnchors' niche spots, the boiler room's shelf)
local LENGTH = 2.6
local DEPTH = 1.05
local BOARD = 0.12
local STEEL = rgb(86, 88, 90)
local JUG = rgb(176, 178, 176)
local LABEL = rgb(140, 142, 140)

local CleaningShelfBuilder = {}

-- Whether `anchor` (a FlaskCandidate) stands on a platform or a cart of `layout` (so needs no shelf of its own).
function CleaningShelfBuilder.carried(layout: Layout, anchor: Anchor): boolean
	local platforms: { LayoutSchema.Platform } = layout.platforms or {}
	for _, platform in platforms do
		if
			math.abs(platform.top - anchor.pos.Y) < 0.05
			and LayoutSchema.rectContains(platform.rect, anchor.pos.X, anchor.pos.Z, 0)
		then
			return true
		end
	end
	if anchor.ref then
		for _, other in layout.anchors do
			if other.id == anchor.ref and other.kind == "MopCart" then
				return true
			end
		end
	end
	return false
end

local function visible(part: BasePart)
	PropKit.detail(part)
	part.CanQuery = true
	part.CastShadow = true
end

local function buildShelf(model: Model, frame: CFrame)
	local back = WALL_GAP
	-- the board: from the wall face out DEPTH, its top at the flask's foot
	local board = Geometry.part(
		model,
		"Board",
		frame * CFrame.new(0, -BOARD / 2, back - DEPTH / 2),
		Vector3.new(LENGTH, BOARD, DEPTH),
		"MetalGalvanized",
		{ color = STEEL }
	)
	visible(board)
	model.PrimaryPart = board
	for i, x in { -LENGTH / 2 + 0.25, LENGTH / 2 - 0.25 } do
		local bracket = Geometry.wedge(
			model,
			"Bracket" .. i,
			frame * CFrame.new(x, -BOARD - 0.4, back - 0.4) * CFrame.Angles(0, 0, math.pi),
			Vector3.new(0.08, 0.8, 0.8),
			"MetalGalvanized",
			{ color = STEEL }
		)
		visible(bracket)
	end
	-- his stock either side of the flask: a gallon jug and a spray bottle
	local jug = Geometry.part(
		model,
		"Jug",
		frame * CFrame.new(-0.95, 0.45, back - 0.5),
		Vector3.new(0.5, 0.9, 0.42),
		"Fixture",
		{
			color = JUG,
		}
	)
	PropKit.decor(jug, 3)
	local label = Geometry.part(
		model,
		"JugLabel",
		frame * CFrame.new(-0.95, 0.42, back - 0.715),
		Vector3.new(0.36, 0.34, 0.02),
		"PaperSheet",
		{ color = LABEL }
	)
	PropKit.decor(label, 3)
	local spray = Geometry.part(
		model,
		"Spray",
		frame * CFrame.new(0.95, 0.38, back - 0.55) * CFrame.Angles(0, 0, math.rad(90)),
		Vector3.new(0.76, 0.3, 0.3),
		"Fixture",
		{ shape = Enum.PartType.Cylinder, color = JUG }
	)
	PropKit.decor(spray, 3)
	local nozzle = Geometry.part(
		model,
		"SprayHead",
		frame * CFrame.new(0.95, 0.86, back - 0.6),
		Vector3.new(0.16, 0.2, 0.3),
		"Rubber",
		{ color = rgb(46, 48, 50) }
	)
	PropKit.decor(nozzle, 3)
end

local function buildShelves(ctx: PropKit.StaticContext): number
	local layout = ctx.layout
	local built = 0
	for _, anchor in PropKit.anchorsOf(layout, "FlaskCandidate") do
		if CleaningShelfBuilder.carried(layout, anchor) then
			continue
		end
		local frame = PropKit.anchorCFrame(layout.id, anchor)
		local model = PropKit.model(ctx.parent, "CleaningShelf_" .. anchor.id, frame)
		buildShelf(model, frame)
		PropKit.setAttributes(model, { [W.AnchorId] = anchor.id, [W.LevelId] = layout.id })
		built += 1
	end
	return built
end

function CleaningShelfBuilder.register(registrar: PropKit.Registrar)
	registrar.static("CleaningShelf", buildShelves)
end

return table.freeze(CleaningShelfBuilder)
