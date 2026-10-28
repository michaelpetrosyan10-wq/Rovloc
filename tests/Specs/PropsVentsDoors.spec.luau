--!strict
-- VentGrateBuilder and DoorBuilder on the real layouts. Level 1 and Level 2 are built once with BuildAuthoritative
-- (shell, vents, the static open doors) and their fixtures with BuildFixtures under a hand-made plan that locks every
-- other lockable grate; the Level 5 roof door is built from its level's anchors alone through DoorBuilder's own
-- registration. Checked: one grate per layout grate with the attachment's state, disabled Unscrew / Kick prompts,
-- rusted locked grates, the shut panel covering the 3.5 bore on the room-side face (colliding, with sight gaps), the
-- crawler's exit and entry anchors, grate poses; every ordinary door standing open outside its doorway's walking
-- lane and in front of its casing; fixture door attributes, tags, signs and budgets; leaves that never cut into the
-- wall or the casing over their swing; the gate's grille closing the whole opening when down and clearing it when
-- rolled up; smashed poses landing on the floor.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local DoorBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.DoorBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local SchoolShellBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.SchoolShellBuilder)
local VentGrateBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.VentGrateBuilder)
local VentShaftBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.VentShaftBuilder)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout

type World = {
	runtime: { [string]: Folder }, -- fixtures per level
	locked: { [string]: boolean },
}

local W = Attributes.World
local Names = Instances.Names

local LEVELS: { Enums.LayoutId } = { "Level1_Hallways", "Level2_ScienceHall" }
local SEED = 4242
local HALF_BORE = WorldConfig.VentBore / 2
local WALL_HALF = WorldConfig.WallThickness / 2
local TRIM_FRONT = WALL_HALF + 0.15 -- Geometry.doorTrims: casing faces stand this far off the wall's centre plane
local TRIM_REVEAL = 0.05 -- casings lap this far into the opening
local LANE_DEPTH = 2.5 -- the walking lane through a doorway reaches this far into each room
local EPS = 1e-3
local SIGNS: { number } = { -1, 1 }
local GRATE_BUDGET = 22
local STATIC_DOOR_BUDGET = 8
local FIXTURE_BUDGET: { [string]: number } = { Ajar = 12, RoofDoor = 12, Airlock = 30, Gate = 45 }
local FIXTURE_KINDS: { [string]: boolean } = { Ajar = true, Gate = true, Airlock = true, RoofDoor = true }

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function child(parent: Instance?, name: string): Instance
	assert(parent, "missing parent for " .. name)
	local found = parent:FindFirstChild(name)
	assert(found, string.format("%s has no %s", parent:GetFullName(), name))
	return found
end

local function partsOf(root: Instance): { BasePart }
	local out: { BasePart } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(out, descendant)
		end
	end
	return out
end

local function corners(part: BasePart): { Vector3 }
	local cf, half = part.CFrame, part.Size / 2
	local out: { Vector3 } = {}
	for _, sx in SIGNS do
		for _, sy in SIGNS do
			for _, sz in SIGNS do
				table.insert(out, cf * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
			end
		end
	end
	return out
end

-- (u, y, a) of a world point in a wall frame: u along RightVector, y up, a out along LookVector.
local function wallLocal(frame: CFrame, point: Vector3): Vector3
	local p = frame:PointToObjectSpace(point)
	return Vector3.new(p.X, p.Y, -p.Z)
end

-- Bounds of `parts` in a wall frame.
local function extent(frame: CFrame, parts: { BasePart }): (Vector3, Vector3)
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = -lo
	for _, part in parts do
		for _, corner in corners(part) do
			local p = wallLocal(frame, corner)
			lo, hi = lo:Min(p), hi:Max(p)
		end
	end
	return lo, hi
end

local function rotationAngle(cf: CFrame): number
	local _, angle = cf:ToAxisAngle()
	angle = math.abs(angle)
	if angle > math.pi then
		angle = 2 * math.pi - angle
	end
	return angle
end

local function isIdentity(cf: CFrame?): boolean
	return cf ~= nil and cf.Position.Magnitude < EPS and rotationAngle(cf) < EPS
end

local function transformOf(model: Model, leaf: string): CFrame
	local transform = PropKit.leafTransform(model, leaf)
	assert(transform, string.format("%s has no leaf %s", model.Name, leaf))
	return transform
end

local function layoutOf(id: string): Layout
	local layout = Builder.getLayout(id)
	assert(layout, "layout " .. id)
	return layout
end

local function levelRoot(id: string): Instance
	local root = Instances.layoutRoot(id)
	assert(root, "level " .. id)
	return root
end

local function grateAttachment(id: string, grateId: string): Attachment
	local vents = child(levelRoot(id), Names.Vents)
	local found = child(child(vents, VentShaftBuilder.RootName), VentShaftBuilder.GratePrefix .. grateId)
	assert(found:IsA("Attachment"), grateId)
	return found
end

local function doorAttachment(root: Instance, doorId: string): Attachment
	local found = child(child(child(root, Names.Anchors), "AnchorRoot"), "Door_" .. doorId)
	assert(found:IsA("Attachment"), doorId)
	return found
end

local function grateModels(world: World, id: string): { Model }
	local out: { Model } = {}
	for _, item in world.runtime[id]:GetChildren() do
		if item:IsA("Model") and item:HasTag(Tags.VentGrate) then
			table.insert(out, item)
		end
	end
	return out
end

local function gratePlans(layout: Layout): { [string]: VentGrateBuilder.GratePlan }
	local out: { [string]: VentGrateBuilder.GratePlan } = {}
	for _, plan in VentGrateBuilder.plan(layout) do
		out[plan.grate.id] = plan
	end
	return out
end

local function leafParts(model: Model, leaf: string): { BasePart }
	return partsOf(child(model, leaf))
end

local function roomOf(layout: Layout, id: string): LayoutSchema.Room
	local room = LayoutSchema.indexRooms(layout)[id]
	assert(room, "room " .. id)
	return room
end

-- Whether a corner in a door's wall frame sits where only the wall and its casing are: within the casing band of
-- the wall plane, beside the clear opening.
local function inWallBand(p: Vector3, width: number): boolean
	return math.abs(p.Z) < TRIM_FRONT - EPS and math.abs(p.X) > width / 2 - TRIM_REVEAL + EPS
end

-- Whether a corner stands in a doorway's walking lane (the clear width, LANE_DEPTH into either room).
local function inLane(p: Vector3, width: number): boolean
	return math.abs(p.X) < width / 2 - TRIM_REVEAL - EPS and math.abs(p.Z) < WALL_HALF + LANE_DEPTH - EPS
end

-- Built once for the whole module: the two levels and their fixtures.
local cached: World? = nil

local function world(): World
	if cached then
		return cached
	end
	Builder.BuildAuthoritative({ layouts = LEVELS, yieldEvery = 0 })
	local holder = Instance.new("Folder")
	holder.Name = "PropsVentsDoorsSpec"
	holder.Parent = Workspace
	local locked: { [string]: boolean } = {}
	local runtime: { [string]: Folder } = {}
	for _, id in LEVELS do
		local layout = layoutOf(id)
		local flip = false
		for _, grate in (layout.vents and layout.vents.grates or {}) :: { LayoutSchema.GrateSpec } do
			if grate.lockable and not grate.criticalPath then
				flip = not flip
				if flip then
					locked[grate.id] = true
				end
			end
		end
		local folder = Instance.new("Folder")
		folder.Name = id
		folder.Parent = holder
		runtime[id] = folder
	end
	local plan: Types.SpawnPlan = {
		seed = SEED,
		difficulty = "Standard",
		props = {},
		lockedGrates = locked,
		rerolls = 0,
	}
	for _, id in LEVELS do
		Builder.BuildFixtures(id, runtime[id], plan, SEED)
	end
	local built: World = { runtime = runtime, locked = locked }
	cached = built
	return built
end

-- DoorBuilder's registered builders, captured through a stand-in registrar.
local function doorBuilders(): ({ [string]: PropKit.FixtureBuilder }, { [string]: PropKit.StaticBuilder })
	local fixtures: { [string]: PropKit.FixtureBuilder } = {}
	local statics: { [string]: PropKit.StaticBuilder } = {}
	DoorBuilder.register({
		prop = function(_kind: string, _builder: Types.PropBuilder) end,
		fixture = function(kind: string, builder: PropKit.FixtureBuilder)
			fixtures[kind] = builder
		end,
		static = function(kind: string, builder: PropKit.StaticBuilder)
			statics[kind] = builder
		end,
		rig = function(_kind: string, _builder: Types.RigBuilder) end,
		cosmetic = function(_kind: any, _builder: PropKit.CosmeticAnchorBuilder) end,
	})
	return fixtures, statics
end

local function signText(model: Model): string?
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("TextLabel") and descendant:FindFirstAncestorWhichIsA("SurfaceGui") then
			return descendant.Text
		end
	end
	return nil
end

-- Checks every leaf of a swinging fixture door over its whole swing: never into the wall or casing band, and at
-- full open out of the doorway's walking lane.
local function checkSwing(t: Expect, model: Model, frame: CFrame, width: number, leaves: { string })
	for _, openness in { 0, 0.25, 0.5, 0.75, 1 } do
		DoorBuilder.setOpen(model, openness)
		for _, leaf in leaves do
			for _, part in leafParts(model, leaf) do
				for _, corner in corners(part) do
					local p = wallLocal(frame, corner)
					t.falsy(
						inWallBand(p, width),
						string.format("%s %s cuts into the wall at %.2f", model.Name, part.Name, openness)
					)
					if openness == 1 then
						t.falsy(inLane(p, width), string.format("%s %s blocks the doorway", model.Name, part.Name))
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["vent grates: one model per layout grate, tagged, with the attachment's state"] = function(t: Expect)
		local built = world()
		local total = 0
		for _, id in LEVELS do
			local layout = layoutOf(id)
			local grates = (layout.vents and layout.vents.grates or {}) :: { LayoutSchema.GrateSpec }
			t.eq(#grateModels(built, id), #grates, id .. " grate count")
			for _, grate in grates do
				local source = grateAttachment(id, grate.id)
				local model = child(built.runtime[id], VentShaftBuilder.GratePrefix .. grate.id)
				assert(model:IsA("Model"), grate.id)
				total += 1
				t.truthy(model:HasTag(Tags.VentGrate), grate.id .. " VentGrate tag")
				t.truthy(model:HasTag(Tags.Interactable), grate.id .. " Interactable tag")
				for _, key in { W.GrateId, W.Lockable, W.CriticalPath, W.NodeId, W.FacingZoneId, W.LevelId } do
					t.eq(model:GetAttribute(key), source:GetAttribute(key), grate.id .. " " .. key)
				end
				t.eq(model:GetAttribute(W.GrateState), if built.locked[grate.id] then "Locked" else "Closed", grate.id)
				local base = model.PrimaryPart
				t.truthy(base ~= nil and base.Name == "Base", grate.id .. " Base is the PrimaryPart")
				local parts = partsOf(model)
				t.truthy(#parts <= GRATE_BUDGET, string.format("%s has %d parts", grate.id, #parts))
				for _, part in parts do
					t.truthy(part.Anchored, part:GetFullName() .. " anchored")
				end
				for _, leaf in { "Panel", "Screw1", "Screw2", "Screw3", "Screw4" } do
					t.truthy(child(model, leaf):IsA("Model"), grate.id .. " leaf " .. leaf)
					t.truthy(
						isIdentity(PropKit.leafTransform(model, leaf)),
						grate.id .. " " .. leaf .. " built at rest"
					)
				end
			end
		end
		t.eq(total, 50, "Level 1 + Level 2 grates")
	end,

	["vent grates: disabled unscrew and kick prompts in front of the panel"] = function(t: Expect)
		local built = world()
		for _, id in LEVELS do
			local plans = gratePlans(layoutOf(id))
			for _, model in grateModels(built, id) do
				local grateId = model:GetAttribute(W.GrateId) :: string
				local frame = PropKit.attachmentWorld(grateAttachment(id, grateId))
				local point = child(model.PrimaryPart, "PromptPoint")
				assert(point:IsA("Attachment"), "PromptPoint")
				local _, panelHi = extent(frame, leafParts(model, "Panel"))
				local p = wallLocal(frame, PropKit.attachmentWorld(point).Position)
				t.truthy(p.Z > panelHi.Z, grateId .. " prompt point in front of the panel")
				t.truthy(math.abs(p.X) < EPS and math.abs(p.Y) < EPS, grateId .. " prompt point centred")
				local object = Strings.get(if built.locked[grateId] then "Prompt.GrateLocked" else "Prompt.Grate")
				t.eq(plans[grateId].face, WALL_HALF, grateId .. " mounted on an ordinary wall face")

				local unscrew = PropKit.findPrompt(model, "Unscrew")
				assert(unscrew, grateId .. " Unscrew prompt")
				t.eq(unscrew.Parent, point, grateId .. " Unscrew on PromptPoint")
				t.eq(unscrew.Enabled, false)
				t.eq(unscrew.HoldDuration, GameConfig.UnscrewSeconds)
				t.eq(unscrew:GetAttribute(W.BaseHold), GameConfig.UnscrewSeconds)
				t.eq(unscrew.KeyboardKeyCode, Enum.KeyCode.E)
				t.eq(unscrew.GamepadKeyCode, Enum.KeyCode.ButtonX)
				t.eq(unscrew.ActionText, Strings.get("Prompt.Unscrew"))
				t.eq(unscrew.ObjectText, object, grateId .. " Unscrew object text")

				local kick = PropKit.findPrompt(model, "Kick")
				assert(kick, grateId .. " Kick prompt")
				t.eq(kick.Parent, point, grateId .. " Kick on PromptPoint")
				t.eq(kick.Enabled, false)
				t.eq(kick.HoldDuration, 0)
				t.eq(kick:GetAttribute(W.BaseHold), GameConfig.KickSeconds)
				t.eq(kick.KeyboardKeyCode, Enum.KeyCode.R)
				t.eq(kick.GamepadKeyCode, Enum.KeyCode.ButtonY)
				t.eq(kick.ActionText, Strings.get("Prompt.Kick"))
				t.eq(kick.ObjectText, object, grateId .. " Kick object text")
			end
		end
	end,

	["vent grates: locked grates are rusted shut"] = function(t: Expect)
		local built = world()
		local lockedCount, closedCount = 0, 0
		for _, id in LEVELS do
			for _, model in grateModels(built, id) do
				local grateId = model:GetAttribute(W.GrateId) :: string
				local panel = child(model, "Panel")
				local base = model.PrimaryPart
				assert(base, grateId)
				local dressing = 0
				for _, name in { "WeldLatch", "WeldHead", "RustStreak" } do
					if panel:FindFirstChild(name) then
						dressing += 1
					end
				end
				if built.locked[grateId] then
					lockedCount += 1
					t.eq(model:GetAttribute(W.GrateState), "Locked")
					t.eq(base.Material, Enum.Material.CorrodedMetal, grateId .. " rusted frame")
					t.eq(dressing, 3, grateId .. " weld beads and rust streak")
				else
					closedCount += 1
					t.eq(base.Material, Enum.Material.Metal, grateId .. " galvanized frame")
					t.eq(dressing, 0, grateId .. " no rust dressing")
				end
			end
		end
		t.truthy(lockedCount >= 5, "some grates locked")
		t.truthy(closedCount >= 5, "some grates closed")
	end,

	["vent grates: the shut panel covers the bore on the room-side face"] = function(t: Expect)
		local built = world()
		for _, id in LEVELS do
			for _, model in grateModels(built, id) do
				local grateId = model:GetAttribute(W.GrateId) :: string
				local frame = PropKit.attachmentWorld(grateAttachment(id, grateId))
				-- shut, screws in (whatever an earlier spec left posed)
				VentGrateBuilder.setPanel(model, 0)
				VentGrateBuilder.setScrews(model, 0)
				-- nothing reaches back into the wall or the bore
				local lo = extent(frame, partsOf(model))
				t.truthy(lo.Z >= WALL_HALF - EPS, grateId .. " mounted on the room-side face")

				-- the frame rings the opening
				for _, name in { "Base", "FrameTop", "FrameLeft", "FrameRight" } do
					local part = child(model, name)
					assert(part:IsA("BasePart"), name)
					t.truthy(part.CanCollide, grateId .. " " .. name .. " collides")
					t.eq(part.CollisionGroup, CollisionGroups.Default, grateId .. " " .. name)
				end
				local baseLo, baseHi = extent(frame, { model.PrimaryPart :: BasePart })
				t.truthy(baseHi.Y <= -HALF_BORE + EPS and baseLo.Y < -HALF_BORE, grateId .. " sill under the opening")

				-- colliding panel parts: past the opening on every side, louvres the full width, small gaps only
				local colliding: { BasePart } = {}
				local spans: { { number } } = {}
				local louvres = 0
				for _, part in leafParts(model, "Panel") do
					if not part.CanCollide then
						continue
					end
					t.eq(part.CollisionGroup, CollisionGroups.Default, grateId .. " " .. part.Name)
					table.insert(colliding, part)
					local pLo, pHi = extent(frame, { part })
					if pLo.X <= -HALF_BORE + EPS and pHi.X >= HALF_BORE - EPS then
						table.insert(spans, { pLo.Y, pHi.Y })
					end
					if string.sub(part.Name, 1, 6) == "Louvre" then
						louvres += 1
						t.truthy(
							pLo.X <= -HALF_BORE + EPS and pHi.X >= HALF_BORE - EPS,
							grateId .. " louvre spans the bore"
						)
					end
				end
				t.eq(louvres, 5, grateId .. " louvres")
				local panelLo, panelHi = extent(frame, colliding)
				t.truthy(panelLo.X < -HALF_BORE and panelHi.X > HALF_BORE, grateId .. " panel wider than the bore")
				t.truthy(panelLo.Y < -HALF_BORE and panelHi.Y > HALF_BORE, grateId .. " panel taller than the bore")
				t.truthy(panelLo.Z > WALL_HALF, grateId .. " panel in front of the frame")
				table.sort(spans, function(a: { number }, b: { number }): boolean
					return a[1] < b[1]
				end)
				local reach, widest = -HALF_BORE, 0
				for _, span in spans do
					if span[1] > reach then
						widest = math.max(widest, span[1] - reach)
					end
					reach = math.max(reach, span[2])
				end
				widest = math.max(widest, HALF_BORE - reach)
				t.truthy(
					widest < 0.6,
					string.format("%s largest gap %.2f stops a crawler and a player", grateId, widest)
				)
				t.truthy(widest > 0.2, grateId .. " louvres leave sight lines")
			end
		end
	end,

	["vent grates: exit anchor in the facing room, entry anchor in the bore"] = function(t: Expect)
		local built = world()
		for _, id in LEVELS do
			local layout = layoutOf(id)
			local origin = WorldConfig.levelOrigin(id)
			for _, model in grateModels(built, id) do
				local grateId = model:GetAttribute(W.GrateId) :: string
				local frame = PropKit.attachmentWorld(grateAttachment(id, grateId))
				local exitAnchor = child(model.PrimaryPart, "ExitAnchor")
				local entryAnchor = child(model.PrimaryPart, "EntryAnchor")
				assert(exitAnchor:IsA("Attachment") and entryAnchor:IsA("Attachment"), grateId)
				local exit = PropKit.attachmentWorld(exitAnchor)
				local room = roomOf(layout, model:GetAttribute(W.FacingZoneId) :: string)
				local here = exit.Position - origin
				t.truthy(LayoutSchema.rectContains(room.rect, here.X, here.Z, 1), grateId .. " exit inside " .. room.id)
				t.truthy(math.abs(here.Y) < EPS, grateId .. " exit at floor level")
				t.near(wallLocal(frame, exit.Position).Z, WALL_HALF + VentGrateBuilder.ExitOut, EPS, grateId .. " exit")
				t.truthy(exit.LookVector:Dot(frame.LookVector) > 0.999, grateId .. " exit faces away from the wall")

				local entry = PropKit.attachmentWorld(entryAnchor)
				local p = wallLocal(frame, entry.Position)
				t.near(p.Z, WALL_HALF - VentGrateBuilder.EntryIn, EPS, grateId .. " entry behind the opening")
				t.truthy(math.abs(p.X) < EPS and math.abs(p.Y) < EPS, grateId .. " entry at bore centre")
				t.truthy(entry.LookVector:Dot(frame.LookVector) < -0.999, grateId .. " entry faces into the duct")
			end
		end
	end,

	["vent grates: panel, screw and kick poses round-trip"] = function(t: Expect)
		local built = world()
		local id = LEVELS[1]
		local layout = layoutOf(id)
		local origin = WorldConfig.levelOrigin(id)
		for _, model in grateModels(built, id) do
			local grateId = model:GetAttribute(W.GrateId) :: string
			local frame = PropKit.attachmentWorld(grateAttachment(id, grateId))
			local room = roomOf(layout, model:GetAttribute(W.FacingZoneId) :: string)

			-- swing: a pure turn about the hinge, out into the room, never into the wall
			t.truthy(VentGrateBuilder.setPanel(model, 0.5), grateId .. " setPanel")
			t.near(rotationAngle(transformOf(model, "Panel")), VentGrateBuilder.OpenAngle / 2, 1e-3, grateId)
			t.truthy(VentGrateBuilder.setPanel(model, 1), grateId .. " setPanel")
			local open = transformOf(model, "Panel")
			t.near(rotationAngle(open), VentGrateBuilder.OpenAngle, 1e-3, grateId .. " open angle")
			t.truthy(open.Position.Magnitude < EPS, grateId .. " turns about its hinge pin")
			t.truthy(math.abs(open.UpVector.Y) > 0.9999, grateId .. " hinge axis vertical")
			local lo = extent(frame, leafParts(model, "Panel"))
			t.truthy(lo.Z >= WALL_HALF - EPS, grateId .. " open panel clear of the wall")
			VentGrateBuilder.setPanel(model, 0)
			t.truthy(isIdentity(PropKit.leafTransform(model, "Panel")), grateId .. " shut again")

			-- screws back out along the panel normal, then lie on the floor
			VentGrateBuilder.setScrews(model, 0.5)
			for i = 1, 4 do
				local screw = transformOf(model, "Screw" .. i)
				t.truthy(screw.Position.Magnitude > 0.1, grateId .. " screw backing out")
				t.truthy(math.abs(screw.Position.X) < EPS and math.abs(screw.Position.Y) < EPS, "along its axis")
			end
			t.truthy(VentGrateBuilder.setScrews(model, 1), grateId .. " setScrews")
			for i = 1, 4 do
				local parts = leafParts(model, "Screw" .. i)
				local sLo, sHi = extent(frame, parts)
				t.truthy(sLo.Z > WALL_HALF, grateId .. " screw out in the room")
				local low = math.huge
				for _, part in parts do
					for _, corner in corners(part) do
						low = math.min(low, corner.Y - origin.Y)
					end
				end
				t.truthy(low > -0.02 and low < 0.05, string.format("%s screw %d on the floor (%.3f)", grateId, i, low))
				t.truthy(sHi.Y - sLo.Y < 0.5, grateId .. " screw lying down")
			end
			VentGrateBuilder.setScrews(model, 0)
			for i = 1, 4 do
				t.truthy(isIdentity(PropKit.leafTransform(model, "Screw" .. i)), grateId .. " screw back in")
			end

			-- kicked: torn off, lying in front of the opening on the floor, inside the room
			t.truthy(VentGrateBuilder.setKicked(model, 1), grateId .. " setKicked")
			local low, high = math.huge, -math.huge
			for _, part in leafParts(model, "Panel") do
				for _, corner in corners(part) do
					local here = corner - origin
					low, high = math.min(low, here.Y), math.max(high, here.Y)
					t.truthy(wallLocal(frame, corner).Z > WALL_HALF, grateId .. " kicked panel in front of the wall")
					t.truthy(
						LayoutSchema.rectContains(room.rect, here.X, here.Z, WALL_HALF),
						grateId .. " kicked panel inside " .. room.id
					)
				end
			end
			t.truthy(low > -0.02 and low < 0.05, string.format("%s kicked panel on the floor (%.3f)", grateId, low))
			t.truthy(high < 1.2, string.format("%s kicked panel lying down (%.2f)", grateId, high))
			VentGrateBuilder.setKicked(model, 0)
			t.truthy(isIdentity(PropKit.leafTransform(model, "Panel")), grateId .. " back after the kick")
			for i = 1, 4 do
				t.truthy(isIdentity(PropKit.leafTransform(model, "Screw" .. i)), grateId .. " screws back")
			end
		end
	end,

	["doors: every ordinary door stands open outside its doorway, in front of its casing"] = function(t: Expect)
		world()
		local angles: { [number]: boolean } = {}
		local distinct, crooked, total = 0, 0, 0
		for _, id in LEVELS do
			local layout = layoutOf(id)
			local root = levelRoot(id)
			local props = child(root, Names.Props)
			for _, door in layout.doors do
				if door.kind ~= "Door" then
					continue
				end
				local source = doorAttachment(root, door.id)
				local model = child(props, "Door_" .. door.id)
				assert(model:IsA("Model"), door.id)
				total += 1
				local frame = PropKit.attachmentWorld(source)
				local width = source:GetAttribute(W.DoorWidth) :: number
				local parts = partsOf(model)
				t.truthy(#parts <= STATIC_DOOR_BUDGET, string.format("%s has %d parts", door.id, #parts))
				for _, descendant in model:GetDescendants() do
					t.falsy(descendant:IsA("ProximityPrompt"), door.id .. " has no prompt")
				end
				for _, part in parts do
					t.truthy(part.Anchored, part.Name .. " anchored")
					if part.CanCollide then
						t.eq(part.CollisionGroup, CollisionGroups.MonsterPassthrough, door.id .. " " .. part.Name)
						t.truthy(part:HasTag(Tags.MonsterPassthrough), door.id .. " " .. part.Name .. " tagged")
						t.truthy(part:FindFirstChildWhichIsA("PathfindingModifier") ~= nil, part.Name .. " modifier")
					else
						t.eq(part.CanQuery, false, door.id .. " " .. part.Name .. " detail never queried")
					end
					for _, corner in corners(part) do
						local p = wallLocal(frame, corner)
						t.falsy(inWallBand(p, width), door.id .. " " .. part.Name .. " cuts into the wall or casing")
						t.falsy(inLane(p, width), door.id .. " " .. part.Name .. " stands in the doorway")
						t.truthy(corner.Y - frame.Position.Y > -EPS, door.id .. " above the floor")
					end
				end
				-- opening angle: the leaf's hinge-to-free-edge axis against the wall, from the hinge side
				local stile = child(model, "Leaf_StileHinge")
				assert(stile:IsA("BasePart"), door.id)
				local axis = stile.CFrame.RightVector
				axis = Vector3.new(axis.X, 0, axis.Z).Unit
				local hingeSide = if wallLocal(frame, stile.CFrame.Position).X < 0 then -1 else 1
				local across = frame.RightVector * -hingeSide
				local angle = math.deg(math.acos(math.clamp(axis:Dot(across), -1, 1)))
				t.truthy(angle >= 88 and angle <= 112, string.format("%s open %.1f degrees", door.id, angle))
				local key = math.floor(angle * 2 + 0.5)
				if not angles[key] then
					angles[key] = true
					distinct += 1
				end
				if stile.CFrame.UpVector.Y < 0.999 then
					crooked += 1
				end
			end
		end
		t.eq(total, 84, "Level 1 + Level 2 ordinary doors")
		t.truthy(distinct >= 10, "seeded variety of angles")
		t.truthy(crooked >= 1 and crooked <= total / 4, string.format("a few hang crooked (%d)", crooked))
	end,

	["doors: fixture doors carry their state, tags, signs and budgets"] = function(t: Expect)
		local built = world()
		local seen: { [string]: number } = {}
		for _, id in LEVELS do
			local layout = layoutOf(id)
			local root = levelRoot(id)
			for _, door in layout.doors do
				if not FIXTURE_KINDS[door.kind] then
					continue
				end
				local source = doorAttachment(root, door.id)
				local model = child(built.runtime[id], "Door_" .. door.id)
				assert(model:IsA("Model"), door.id)
				seen[door.kind] = (seen[door.kind] or 0) + 1
				t.eq(model:GetAttribute(W.DoorId), door.id)
				t.eq(model:GetAttribute(W.DoorKind), door.kind)
				t.eq(model:GetAttribute(W.DoorState), "Open")
				t.eq(model:GetAttribute(W.LevelId), id)
				t.eq(model:GetAttribute(W.DoorWidth), source:GetAttribute(W.DoorWidth), door.id .. " width")
				t.eq(model:GetAttribute(W.DoorHeight), source:GetAttribute(W.DoorHeight), door.id .. " height")
				t.eq(model:GetAttribute(W.ScriptedId), door.scriptedId, door.id .. " ScriptedId")
				t.eq(model:HasTag(Tags.ScriptedDoor), door.scriptedId ~= nil, door.id .. " ScriptedDoor tag")
				t.eq(model:HasTag(Tags.AirlockDoor), door.kind == "Airlock", door.id .. " AirlockDoor tag")
				local parts = partsOf(model)
				t.truthy(
					#parts <= FIXTURE_BUDGET[door.kind],
					string.format("%s (%s) has %d parts", door.id, door.kind, #parts)
				)
				for _, part in parts do
					t.truthy(part.Anchored, part.Name .. " anchored")
				end
				local leaves: { string } = if door.kind == "Airlock"
					then { "LeftLeaf", "RightLeaf" }
					elseif door.kind == "Gate" then { "Grille" }
					else { "Leaf" }
				for _, leaf in leaves do
					local colliding = 0
					for _, part in leafParts(model, leaf) do
						if part.CanCollide then
							colliding += 1
							t.eq(part.CollisionGroup, CollisionGroups.Default, door.id .. " " .. part.Name .. " blocks")
						end
					end
					t.truthy(colliding > 0, door.id .. " " .. leaf .. " collides")
				end
				if door.kind == "Airlock" then
					t.eq(signText(model), Strings.get("Prop.Airlock.Sign"), door.id .. " sign")
					t.truthy(type(model:GetAttribute(W.FromLevel)) == "string", door.id .. " FromLevel")
					t.truthy(type(model:GetAttribute(W.ToLevel)) == "string", door.id .. " ToLevel")
				end
			end
		end
		t.eq(seen.Airlock, 4, "airlocks")
		t.eq(seen.Gate, 1, "hallway gate")
		t.eq(seen.Ajar, 1, "ajar classroom door")
	end,

	["doors: fire door frames and the gate's housing and rails wear hazard stripes"] = function(t: Expect)
		local built = world()
		local painted: { [string]: number } = {}
		local function expectStripes(model: Instance, name: string, faces: { Enum.NormalId })
			local part = child(model, name)
			assert(part:IsA("BasePart"), name .. " is a part")
			local seen: { [Enum.NormalId]: boolean } = {}
			for _, gui in part:GetChildren() do
				if gui:IsA("SurfaceGui") and gui.Name == "Hazard" then
					seen[gui.Face] = true
					t.eq(gui.LightInfluence, 1, name .. " stripes are lit by the scene")
					t.truthy(gui.PixelsPerStud >= 4 and gui.PixelsPerStud <= 20, name .. " low resolution")
					t.truthy(gui:FindFirstChildWhichIsA("TextLabel", true) == nil, name .. " stripes carry no text")
					local ground = gui:FindFirstChild("Hazard")
					assert(ground and ground:IsA("Frame"), name .. " has a striped ground")
					t.truthy(ground.ClipsDescendants, name .. " stripes are clipped to the face")
					local stripes = 0
					for _, stripe in ground:GetChildren() do
						if stripe:IsA("Frame") and stripe.Name == "Stripe" then
							stripes += 1
						end
					end
					t.truthy(stripes >= 2, name .. " has black bars")
				end
			end
			for _, face in faces do
				t.truthy(seen[face], string.format("%s %s face is striped", name, face.Name))
			end
			painted[name] = (painted[name] or 0) + 1
		end
		for _, id in LEVELS do
			local layout = layoutOf(id)
			for _, door in layout.doors do
				if door.kind ~= "Airlock" and door.kind ~= "Gate" then
					continue
				end
				local model = child(built.runtime[id], "Door_" .. door.id)
				assert(model:IsA("Model"), door.id .. " is a model")
				if door.kind == "Airlock" then
					for _, name in { "Base", "JambLeft", "JambRight" } do
						expectStripes(model, name, { Enum.NormalId.Front, Enum.NormalId.Back })
					end
					t.eq(signText(model), Strings.get("Prop.Airlock.Sign"), door.id .. " sign still reads")
				else
					for _, name in { "Base", "RailLeft", "RailRight" } do
						expectStripes(model, name, { Enum.NormalId.Front })
					end
				end
			end
		end
		t.eq(painted.JambLeft, 4, "every fire door frame")
		t.eq(painted.RailLeft, 1, "the hallway gate")
	end,

	["doors: swinging leaves turn about their hinges, clear of the wall, and smash onto the floor"] = function(
		t: Expect
	)
		local built = world()
		for _, id in LEVELS do
			local layout = layoutOf(id)
			local root = levelRoot(id)
			local origin = WorldConfig.levelOrigin(id)
			for _, door in layout.doors do
				if door.kind ~= "Ajar" and door.kind ~= "Airlock" then
					continue
				end
				local model = child(built.runtime[id], "Door_" .. door.id) :: Model
				local frame = PropKit.attachmentWorld(doorAttachment(root, door.id))
				local width = model:GetAttribute(W.DoorWidth) :: number
				local leaves: { string } = if door.kind == "Airlock" then { "LeftLeaf", "RightLeaf" } else { "Leaf" }
				-- built state
				local builtPose: { [string]: CFrame } = {}
				for _, leaf in leaves do
					local transform = transformOf(model, leaf)
					builtPose[leaf] = transform
					local expected = if door.kind == "Ajar" then DoorBuilder.AjarAngle else math.rad(90)
					t.near(rotationAngle(transform), expected, 1e-3, door.id .. " " .. leaf .. " built angle")
					t.truthy(transform.Position.Magnitude < EPS, door.id .. " turns about its hinge")
				end
				checkSwing(t, model, frame, width, leaves)
				t.truthy(DoorBuilder.setOpen(model, 0), door.id .. " setOpen")
				for _, leaf in leaves do
					t.truthy(isIdentity(PropKit.leafTransform(model, leaf)), door.id .. " " .. leaf .. " shut at 0")
				end
				t.truthy(DoorBuilder.setSmashed(model, 1), door.id .. " setSmashed")
				for _, leaf in leaves do
					t.falsy(isIdentity(PropKit.leafTransform(model, leaf)), door.id .. " " .. leaf .. " smashed")
					local low, high = math.huge, -math.huge
					for _, part in leafParts(model, leaf) do
						for _, corner in corners(part) do
							low, high = math.min(low, corner.Y - origin.Y), math.max(high, corner.Y - origin.Y)
						end
					end
					t.truthy(
						low > -0.05 and low < 0.1,
						string.format("%s %s rests on the floor (%.3f)", door.id, leaf, low)
					)
					if door.kind == "Ajar" then
						t.truthy(high < 1, string.format("%s thrown down flat (%.2f)", door.id, high))
					end
				end
				DoorBuilder.setSmashed(model, 0)
				for _, leaf in leaves do
					t.truthy(isIdentity(PropKit.leafTransform(model, leaf)), door.id .. " " .. leaf .. " back at 0")
					PropKit.poseLeaf(model, leaf, builtPose[leaf])
				end
			end
		end
	end,

	["gate: the grille closes the whole opening when down and rolls up clear of it"] = function(t: Expect)
		local built = world()
		local id = LEVELS[1]
		local layout = layoutOf(id)
		local root = levelRoot(id)
		local gate: LayoutSchema.Door? = nil
		for _, door in layout.doors do
			if door.kind == "Gate" then
				gate = door
			end
		end
		assert(gate, "Level 1 has its HallwayGate")
		local model = child(built.runtime[id], "Door_" .. gate.id) :: Model
		local frame = PropKit.attachmentWorld(doorAttachment(root, gate.id))
		local width = model:GetAttribute(W.DoorWidth) :: number
		local height = model:GetAttribute(W.DoorHeight) :: number
		local sections: { string } = {}
		for _, item in model:GetChildren() do
			if item:IsA("Model") and string.sub(item.Name, 1, 6) == "Grille" then
				table.insert(sections, item.Name)
			end
		end
		t.truthy(#sections >= 1 and model:FindFirstChild("Grille") ~= nil, "grille sections")
		local function grilleParts(): { BasePart }
			local out: { BasePart } = {}
			for _, name in sections do
				for _, part in leafParts(model, name) do
					table.insert(out, part)
				end
			end
			return out
		end
		local housing = model.PrimaryPart
		assert(housing, "housing")
		local _, housingHi = extent(frame, { housing })

		-- built rolled up: the whole grille above the opening, inside the housing's height
		local lo, hi = extent(frame, grilleParts())
		t.truthy(lo.Y >= height - EPS, string.format("rolled up above the opening (%.2f)", lo.Y))
		t.truthy(hi.Y <= housingHi.Y + EPS, "inside the housing")

		-- down: the collision plates close the full width from the floor to the head
		DoorBuilder.setOpen(model, 0)
		for _, name in sections do
			t.truthy(isIdentity(PropKit.leafTransform(model, name)), name .. " down at 0")
		end
		local spans: { { number } } = {}
		for _, part in grilleParts() do
			if part.Name == "Blocker" then
				t.truthy(part.CanCollide, "blocker collides")
				t.eq(part.CollisionGroup, CollisionGroups.Default, "blocker in the Default group")
				local bLo, bHi = extent(frame, { part })
				t.truthy(bLo.X <= -width / 2 + EPS and bHi.X >= width / 2 - EPS, "blocker spans the opening")
				table.insert(spans, { bLo.Y, bHi.Y })
			end
		end
		t.eq(#spans, #sections, "one blocker per section")
		table.sort(spans, function(a: { number }, b: { number }): boolean
			return a[1] < b[1]
		end)
		local reach = 0.05
		for _, span in spans do
			t.truthy(span[1] <= reach + EPS, string.format("no gap at %.2f", reach))
			reach = math.max(reach, span[2])
		end
		t.truthy(reach >= height - EPS, string.format("closed to the head (%.2f)", reach))
		local downLo = extent(frame, grilleParts())
		t.truthy(downLo.Y > -EPS, "grille above the floor")

		-- part-way and back up
		DoorBuilder.setOpen(model, 0.5)
		local bottom = extent(frame, leafParts(model, "Grille"))
		t.truthy(bottom.Y > 1 and bottom.Y < height - 1, "half rolled up")
		DoorBuilder.setOpen(model, 1)
		local upLo = extent(frame, grilleParts())
		t.truthy(upLo.Y >= height - EPS, "rolled up again")

		-- smashed: sections torn out onto the floor in front, then back
		t.truthy(DoorBuilder.setSmashed(model, 1), "setSmashed")
		local smashedLo, smashedHi = extent(frame, grilleParts())
		t.truthy(smashedLo.Y > -0.05 and smashedHi.Y < 1.5, "sections heaped on the floor")
		DoorBuilder.setSmashed(model, 0)
		for _, name in sections do
			t.truthy(isIdentity(PropKit.leafTransform(model, name)), name .. " back at 0")
		end
		DoorBuilder.setOpen(model, 1)
	end,

	["doors: the roof stair door builds from its anchors alone"] = function(t: Expect)
		local layout = layoutOf("Level5_Roof")
		local origin = WorldConfig.levelOrigin(layout.id)
		local root = SchoolShellBuilder.createRoot(layout)
		SchoolShellBuilder.buildAnchors(layout, SchoolShellBuilder.folders(root), origin)
		local folder = Instance.new("Folder")
		local fixtures = doorBuilders()
		local build = fixtures.Doors
		assert(build, "DoorBuilder registers the Doors fixture")
		local count = build({ layout = layout, levelRoot = root, parent = folder, plan = nil, random = Random.new(5) })
		t.eq(count, 1, "one fixture door on the roof")
		local door: LayoutSchema.Door? = nil
		for _, item in layout.doors do
			if item.kind == "RoofDoor" then
				door = item
			end
		end
		assert(door, "roof door in the layout")
		local model = child(folder, "Door_" .. door.id) :: Model
		local frame = PropKit.attachmentWorld(doorAttachment(root, door.id))
		local width = model:GetAttribute(W.DoorWidth) :: number
		t.eq(model:GetAttribute(W.DoorKind), "RoofDoor")
		t.eq(model:GetAttribute(W.DoorState), "Open")
		t.eq(model:GetAttribute(W.ScriptedId), "RoofStairDoor")
		t.truthy(model:HasTag(Tags.ScriptedDoor), "ScriptedDoor tag")
		t.truthy(#partsOf(model) <= FIXTURE_BUDGET.RoofDoor, "roof door budget")
		t.eq(signText(model), Strings.get("Prop.Roof.Sign"), "roof sign")
		local built = rotationAngle(transformOf(model, "Leaf"))
		t.truthy(built >= math.rad(88) and built <= math.rad(101), "built open")
		checkSwing(t, model, frame, width, { "Leaf" })
		DoorBuilder.setOpen(model, 0)
		t.truthy(isIdentity(PropKit.leafTransform(model, "Leaf")), "shut at 0")
		DoorBuilder.setSmashed(model, 1)
		local lo, hi = math.huge, -math.huge
		for _, part in leafParts(model, "Leaf") do
			for _, corner in corners(part) do
				lo, hi = math.min(lo, corner.Y - origin.Y), math.max(hi, corner.Y - origin.Y)
			end
		end
		t.truthy(lo > -0.05 and hi < 1, string.format("thrown flat onto the roof (%.2f..%.2f)", lo, hi))
		folder:Destroy()
		root:Destroy()
	end,
}
