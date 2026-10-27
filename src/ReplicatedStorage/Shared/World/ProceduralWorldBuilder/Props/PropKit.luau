--!strict
-- PropKit: the shared vocabulary of every prop builder (Props/*, CreatureRigBuilder).
--
-- Builder kinds (registered through Props/init.luau, which ProceduralWorldBuilder loads):
--   * Plan props (RegisterProp): one instance per RunDirector PlannedProp (BearTrap, ChemicalFlask, Battery), built
--     into Workspace.Runtime.<level> at Deploying.
--   * Fixtures (RegisterFixture): stateful, interactive set pieces taken from layout data (vent grates, airlock fire
--     doors, the hallway gate, the roof stairwell door, the ajar classroom door, hideable lockers, the parachute
--     crate, the floodlight switch). Rebuilt into Workspace.Runtime.<level> at every Deploying, so a new run always
--     starts from fresh state with nothing to reset by hand.
--   * Statics (RegisterStatic): non-interactive server geometry built once at boot into <level>.Props (open
--     classroom doors, lab counters, smashed lockers, drip pipes, debris over FloorDebris triggers, the pool's
--     collapsed walkways).
--   * Cosmetic anchors (RegisterCosmeticAnchor): client-local dressing per layout anchor (posed corpses, clutter,
--     drip particles). Never replicated, never collided.
--   * Rigs (RegisterRig): models built on demand by kind (the Creature, held / thrown flask visuals, parachute
--     canopy and worn pack).
--
-- Moving parts. A prop's hinged or sliding piece is a "leaf": a sub-Model whose WorldPivot is its hinge (or slide
-- origin) in the rest pose, with an Attachment "<leaf>Rest" on the prop's PrimaryPart recording that rest pivot.
-- PropKit.poseLeaf(prop, leaf, transform) moves the leaf to rest * transform by rewriting part CFrames (anchored
-- parts, server-authoritative; later phases tween the transform). Nothing here needs Model:PivotTo, so poses are
-- pure CFrame maths that behave the same in Roblox and in the Lune harness.
--
-- Prompts. Builders create every ProximityPrompt a prop will ever need, Enabled = false, with the PromptKind and
-- BaseHold attributes set, on a host tagged Interactable. The system that owns the interaction (P3 InteractionService
-- and the mechanics built on it) enables the prompts it handles, so a prop never offers an action nobody serves.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Geometry = require(script.Parent.Parent.Geometry)

local W = Attributes.World

type Layout = LayoutSchema.LevelLayout

export type FixtureContext = {
	layout: Layout,
	levelRoot: Model?, -- Workspace.School.<levelId> (anchors, grate attachments); nil when that level was not built
	parent: Instance, -- Workspace.Runtime.<levelId>
	plan: Types.SpawnPlan?, -- the run's plan (lockedGrates); nil when the director produced none
	random: Random, -- seeded per run, level and fixture kind
}

-- Builds every fixture of one kind for one level. Returns how many it built.
export type FixtureBuilder = (ctx: FixtureContext) -> number

export type StaticContext = {
	layout: Layout,
	root: Model, -- the level model
	parent: Folder, -- <level>.Props
	random: Random, -- seeded per layout and static kind (the same on every server)
}

-- Builds one kind of static geometry for one level. Returns how many pieces it built.
export type StaticBuilder = (ctx: StaticContext) -> number

export type CosmeticAnchorBuilder = (
	anchor: LayoutSchema.Anchor,
	cframe: CFrame,
	parent: Instance,
	random: Random
) -> ()

export type Registrar = {
	prop: (kind: string, builder: Types.PropBuilder) -> (),
	fixture: (kind: string, builder: FixtureBuilder) -> (),
	static: (kind: string, builder: StaticBuilder) -> (),
	rig: (kind: string, builder: Types.RigBuilder) -> (),
	cosmetic: (kind: Enums.AnchorKind, builder: CosmeticAnchorBuilder) -> (),
}

export type PromptSpec = {
	kind: Enums.PromptKind,
	action: string, -- Strings key for ActionText
	object: string, -- Strings key for ObjectText
	hold: number, -- seconds (also written as BaseHold; perks and difficulty scale it at run time)
	distance: number?, -- MaxActivationDistance, default 7
	key: Enum.KeyCode?, -- default E
	gamepad: Enum.KeyCode?, -- default ButtonX
	offset: Vector2?, -- UIOffset in pixels
}

local DEFAULT_PROMPT_DISTANCE = 7

local PropKit = {}

--------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------

-- World CFrame of a layout anchor: level origin + local position, yaw about +Y.
function PropKit.anchorCFrame(layoutId: string, anchor: LayoutSchema.Anchor): CFrame
	return CFrame.new(WorldConfig.levelOrigin(layoutId) + anchor.pos) * CFrame.Angles(0, math.rad(anchor.yaw or 0), 0)
end

-- Anchors of `kind` in layout order.
function PropKit.anchorsOf(layout: Layout, kind: Enums.AnchorKind): { LayoutSchema.Anchor }
	local out: { LayoutSchema.Anchor } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == kind then
			table.insert(out, anchor)
		end
	end
	return out
end

-- World CFrame of an attachment, composed from its parent part (WorldCFrame is not maintained outside the engine).
function PropKit.attachmentWorld(attachment: Attachment): CFrame
	local parent = attachment.Parent
	if parent and parent:IsA("BasePart") then
		return parent.CFrame * attachment.CFrame
	end
	return attachment.CFrame
end

-- The first Attachment named `name` under `root` (searched breadth-first through its folders and parts).
function PropKit.findAttachment(root: Instance, name: string): Attachment?
	for _, descendant in root:GetDescendants() do
		if descendant.Name == name and descendant:IsA("Attachment") then
			return descendant
		end
	end
	return nil
end

-- Every Attachment under `root` whose name starts with `prefix`, keyed by name.
function PropKit.attachmentsWithPrefix(root: Instance, prefix: string): { [string]: Attachment }
	local out: { [string]: Attachment } = {}
	local length = #prefix
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Attachment") and string.sub(descendant.Name, 1, length) == prefix then
			out[descendant.Name] = descendant
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Models and leaves
--------------------------------------------------------------------------------

-- An empty prop Model pivoting at `pivot`. Set PrimaryPart (the "Base" part leaves record their rest on) once built.
function PropKit.model(parent: Instance, name: string, pivot: CFrame): Model
	local model = Instance.new("Model")
	model.Name = name
	model.WorldPivot = pivot
	model.Parent = parent
	return model
end

-- A moving leaf of `prop`: a sub-Model pivoting at `restPivot` (the hinge axis or slide origin in the rest pose).
-- Requires prop.PrimaryPart (the rest Attachment lives on it). Build the leaf's parts into the returned Model.
function PropKit.leaf(prop: Model, name: string, restPivot: CFrame): Model
	local base = prop.PrimaryPart
	assert(base, "PropKit.leaf needs the prop's PrimaryPart first")
	local leaf = Instance.new("Model")
	leaf.Name = name
	leaf.WorldPivot = restPivot
	leaf.Parent = prop
	Geometry.attachment(base, name .. "Rest", base.CFrame:ToObjectSpace(restPivot))
	return leaf
end

-- The rest pivot of `prop`'s leaf `name`, or nil when the prop has no such leaf.
function PropKit.leafRest(prop: Model, name: string): CFrame?
	local base = prop.PrimaryPart
	if not base then
		return nil
	end
	local rest = base:FindFirstChild(name .. "Rest")
	if not (rest and rest:IsA("Attachment")) then
		return nil
	end
	return base.CFrame * rest.CFrame
end

-- Moves every part of `model` rigidly so its pivot lands on `target` (PivotTo without the engine).
function PropKit.moveModel(model: Model, target: CFrame)
	local current = model.WorldPivot
	local delta = target * current:Inverse()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CFrame = delta * descendant.CFrame
		end
	end
	model.WorldPivot = target
end

-- Poses leaf `name` of `prop` at rest * `transform` (e.g. CFrame.Angles(0, angle, 0) for a door about its hinge,
-- CFrame.new(0, rise, 0) for a rolling gate). Returns false when the leaf or its rest is missing.
function PropKit.poseLeaf(prop: Model, name: string, transform: CFrame): boolean
	local leaf = prop:FindFirstChild(name)
	local rest = PropKit.leafRest(prop, name)
	if not (leaf and leaf:IsA("Model") and rest) then
		return false
	end
	PropKit.moveModel(leaf, rest * transform)
	return true
end

-- The leaf's current transform relative to its rest pivot (identity at rest), or nil when missing.
function PropKit.leafTransform(prop: Model, name: string): CFrame?
	local leaf = prop:FindFirstChild(name)
	local rest = PropKit.leafRest(prop, name)
	if not (leaf and leaf:IsA("Model") and rest) then
		return nil
	end
	return rest:ToObjectSpace(leaf.WorldPivot)
end

--------------------------------------------------------------------------------
-- Interaction
--------------------------------------------------------------------------------

-- A disabled ProximityPrompt on `host` (a BasePart or Attachment), and the Interactable tag on `tagged` (the part or
-- model the interaction belongs to; default `host`).
function PropKit.prompt(host: Instance, spec: PromptSpec, tagged: Instance?): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = spec.kind
	prompt.Enabled = false
	prompt.ActionText = Strings.get(spec.action)
	prompt.ObjectText = Strings.get(spec.object)
	prompt.HoldDuration = math.max(0, spec.hold)
	prompt.MaxActivationDistance = spec.distance or DEFAULT_PROMPT_DISTANCE
	prompt.KeyboardKeyCode = spec.key or Enum.KeyCode.E
	prompt.GamepadKeyCode = spec.gamepad or Enum.KeyCode.ButtonX
	prompt.RequiresLineOfSight = false
	prompt.ClickablePrompt = true
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Style = Enum.ProximityPromptStyle.Default
	if spec.offset then
		prompt.UIOffset = spec.offset
	end
	prompt:SetAttribute(W.PromptKind, spec.kind)
	prompt:SetAttribute(W.BaseHold, spec.hold)
	prompt.Parent = host
	local target = tagged or host
	target:AddTag(Tags.Interactable)
	return prompt
end

-- The prompt of `kind` under `root`, or nil.
function PropKit.findPrompt(root: Instance, kind: Enums.PromptKind): ProximityPrompt?
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("ProximityPrompt") and descendant:GetAttribute(W.PromptKind) == kind then
			return descendant
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Part presets
--------------------------------------------------------------------------------

-- Small hand-scale detail on a prop (screws, labels, rivets): visible, never collides, never queried, no shadow.
function PropKit.detail(part: BasePart)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
end

-- Applies Geometry.makePassthrough to every BasePart under `root` that still collides (the Creature walks through).
function PropKit.passthroughAll(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.CanCollide then
			Geometry.makePassthrough(descendant)
		end
	end
end

-- Applies Geometry.makeCosmetic to every BasePart under `root`.
function PropKit.cosmeticAll(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			Geometry.makeCosmetic(descendant)
		end
	end
end

-- Writes `attributes` onto `instance` (attribute keys from Attributes.* only).
function PropKit.setAttributes(instance: Instance, attributes: { [string]: any })
	for key, value in attributes do
		instance:SetAttribute(key, value)
	end
end

return table.freeze(PropKit)
