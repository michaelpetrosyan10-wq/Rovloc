--!strict
-- WallPhoneBuilder: the Basement's wall phone (docs/design/game-spec-v2.md 3.5, the set piece "The phone"), on every
-- WallPhone anchor (fixture kind "WallPhone": rebuilt every run into Workspace.Runtime.<level>, one entity
-- "WallPhone_<anchor>"). An old steel-cased service phone screwed to the wall: back plate, body, rotary dial, two
-- bells on top, the handset hung on its hook (leaf "Handset", so the runtime can lift it when it is answered) and its
-- coiled cord. A disabled AnswerPhone prompt (hold 0.6 s) on Attachment "PromptPoint"; Attachment "Ringer" at the
-- bells, where the ring plays from (sound only; never a noise the Creature hears). Wall-mounted: nothing collides.
--
-- Phone space (the anchor's frame): origin on the wall face at the handset's height, -Z out into the room.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)

local Geometry = require(script.Parent.Parent.Geometry)
local PropKit = require(script.Parent.PropKit)

local W = Attributes.World

local rgb = Color3.fromRGB

local ANSWER_HOLD = 0.6
local CASE = rgb(58, 64, 50) -- olive-drab hammertone steel
local PLATE = rgb(74, 72, 62)
local BLACK = rgb(30, 28, 26) -- bakelite
local BELL = rgb(122, 108, 76) -- tarnished brass
local DIAL = rgb(160, 150, 124) -- yellowed ivory

local ANSWER_PROMPT: PropKit.PromptSpec = {
	kind = "AnswerPhone",
	action = "Prompt.AnswerPhone",
	object = "Prompt.WallPhone",
	hold = ANSWER_HOLD,
}

local WallPhoneBuilder = {}

WallPhoneBuilder.AnswerHold = ANSWER_HOLD

local function block(parent: Instance, name: string, cframe: CFrame, size: Vector3, color: Color3): Part
	local part = Geometry.part(parent, name, cframe, size, "CabinetSteel", { color = color })
	PropKit.detail(part)
	return part
end

local function build(frame: CFrame, parent: Instance, name: string): Model
	local model = PropKit.model(parent, name, frame)
	local plate = block(model, "Plate", frame * CFrame.new(0, -0.2, -0.04), Vector3.new(1.0, 1.7, 0.08), PLATE)
	model.PrimaryPart = plate
	local body = block(model, "Body", frame * CFrame.new(0.12, -0.15, -0.26), Vector3.new(0.72, 1.15, 0.36), CASE)
	body.CanQuery = true
	-- the rotary dial on the body's face
	local dial = Geometry.part(
		model,
		"Dial",
		frame * CFrame.new(0.12, -0.05, -0.455) * CFrame.Angles(0, math.rad(90), 0),
		Vector3.new(0.04, 0.42, 0.42),
		"Fixture",
		{ shape = Enum.PartType.Cylinder, color = DIAL }
	)
	PropKit.detail(dial)
	-- two bells over the body
	local bells: { BasePart } = {}
	for i, x in { -0.08, 0.32 } do
		local bell = Geometry.part(
			model,
			"Bell" .. i,
			frame * CFrame.new(x, 0.62, -0.26),
			Vector3.one * 0.34,
			"Fixture",
			{ shape = Enum.PartType.Ball, color = BELL, reflectance = 0.1 }
		)
		PropKit.detail(bell)
		table.insert(bells, bell)
	end
	Geometry.attachment(bells[1], "Ringer", CFrame.new(0.2, 0, 0))
	-- the handset on its hook beside the body, its rest pivot the hook
	local hookPivot = frame * CFrame.new(-0.36, 0.3, -0.3)
	block(model, "Hook", hookPivot * CFrame.new(0, 0.02, 0), Vector3.new(0.12, 0.1, 0.22), BLACK)
	local handset = PropKit.leaf(model, "Handset", hookPivot)
	block(handset, "Grip", hookPivot * CFrame.new(0, -0.48, -0.02), Vector3.new(0.17, 0.82, 0.17), BLACK)
	block(handset, "Earpiece", hookPivot * CFrame.new(0, 0.0, -0.06), Vector3.new(0.3, 0.22, 0.3), BLACK)
	block(handset, "Mouthpiece", hookPivot * CFrame.new(0, -0.95, -0.06), Vector3.new(0.3, 0.22, 0.3), BLACK)
	-- the coiled cord, sagging from the handset's foot to the body's
	local from = hookPivot * Vector3.new(0, -1.05, 0)
	local to = frame * Vector3.new(0.0, -0.72, -0.2)
	local turns = 9
	local previous = from
	for i = 1, turns do
		local t = i / turns
		local sag = math.sin(t * math.pi) * 0.55
		local point = from + (to - from) * t - Vector3.new(0, sag, 0)
		local link = Geometry.cylinder(model, "Cord" .. i, previous, point, 0.07, "Cable")
		if link then
			PropKit.decor(link, 3)
		end
		previous = point
	end
	local host = Geometry.attachment(body, "PromptPoint", CFrame.new(0, 0, -0.4))
	PropKit.prompt(host, ANSWER_PROMPT, model)
	return model
end

local function buildPhones(ctx: PropKit.FixtureContext): number
	local built = 0
	for _, anchor in PropKit.anchorsOf(ctx.layout, "WallPhone") do
		local model = build(PropKit.anchorCFrame(ctx.layout.id, anchor), ctx.parent, "WallPhone_" .. anchor.id)
		PropKit.setAttributes(model, { [W.AnchorId] = anchor.id, [W.LevelId] = ctx.layout.id })
		built += 1
	end
	return built
end

function WallPhoneBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture("WallPhone", buildPhones)
end

return table.freeze(WallPhoneBuilder)
