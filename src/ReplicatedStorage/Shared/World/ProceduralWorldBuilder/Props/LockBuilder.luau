--!strict
-- LockBuilder: what keeps each floor's exit shut until its objective is done, and the Floor 3 equipment store's lock.
-- Fixture kinds, rebuilt at every run start into Workspace.Runtime.<level> (everything locked):
--
--   "ExitLock"   (ExitLocks folder, one per ExitLock anchor: the floor point on the exit airlock door's face on the
--                floor side, facing out of the door). The lock sits on the door's shut leaves (DoorBuilder's plan for
--                that door says which face of the opening they close on), in ObjectiveConfig's variant for the floor:
--                  Padlock  a steel hasp across the leaves' meeting stiles and a heavy padlock (leaf "Padlock");
--                  Chain    a chain wound round both leaves' push bars (or welded staples where the bars face the
--                           other way), its ends joined by a padlock (leaves "Chain" and "Padlock"); "ChainCentre"
--                           is the point a thrown acid flask must land within 3 studs of;
--                  Keypad   a steel bar dropped into brackets across both leaves (leaf "Bar", sliding clear along X
--                           when released) and an electric lock's keypad on the leaf above it, whose dead screen
--                           names the fault (Prop.Keypad.<level>) and whose LED stays red.
--                Padlock and Chain hang a red "LOCKED" placard on the leaves.
--   "StoreLock"  (StoreLocks folder, one per StoreLock anchor): the Padlock variant on a single door's latch edge (the
--                Level 3 equipment store's steel door).
--   "CrateChain" (CrateChains folder, one per CrateChain anchor, at the parachute crate's anchor): a chain threaded
--                through the crate's packs across its open top, its ends wrapped down round eye-bolts on both end walls
--                and joined by a padlock at the front end (leaves "Chain" and "Padlock").
--
-- Prompts (disabled), all on Attachment "LockPrompt": Locked (hold 0, ActionText the floor's lockReason, e.g.
-- "Locked — no power"; Step = the floor's lockStep) on every lock; Unlock (the master keys, Step UnlockExit, 4 s) on
-- the Level 1 exit lock; Pour (the acid, Step BurnChain, 2 s) on the Level 2 exit lock; Unlock (the coach's key, Step
-- UnlockStore, 2 s) on the store lock; CutChain (Step CutChain, 4 s) on the crate chain. Attributes Floor, Step,
-- ObjectiveId (ExitLock | StoreLock | CrateChain), LockVariant, Locked = true, AnchorId, LevelId, ZoneId and DoorId
-- (the door it holds). Tags: ExitLock on exit locks and the crate chain, ObjectiveStation on the store lock and the
-- crate chain, Interactable. Every part is a hand-scale detail: nothing narrows the doorway's clear width.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local DoorBuilder = require(script.Parent.DoorBuilder)
local Geometry = require(script.Parent.Parent.Geometry)
local ObjectiveKit = require(script.Parent.ObjectiveKit)
local ParachuteBuilder = require(script.Parent.ParachuteBuilder)
local PropKit = require(script.Parent.PropKit)

local W = Attributes.World

type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor
type PartOptions = Geometry.PartOptions

local WALL_HALF = WorldConfig.WallThickness / 2
local LEAF_THICKNESS = 0.24
local PUSH_BAR_NEAR, PUSH_BAR_FAR = 0.1, 0.28 -- DoorBuilder: the bar stands this far off a leaf's back face
local PUSH_BAR_Y = 3.6
local PUSH_BAR_END = 0.315 -- from the meeting edge (DoorBuilder: PUSH_BAR_END with the hinge pins outside)

local LockBuilder = {}

LockBuilder.Budgets = table.freeze({ Padlock = 12, Chain = 30, Keypad = 12, CrateChain = 32 } :: { [string]: number })
LockBuilder.Folders = table.freeze({ ExitLock = "ExitLocks", StoreLock = "StoreLocks", CrateChain = "CrateChains" })

local CHAIN: PartOptions = { material = Enum.Material.CorrodedMetal, color = Color3.fromRGB(78, 70, 62) }
local PLACARD = Color3.fromRGB(124, 26, 22)

local function detail(part: BasePart?)
	if part then
		PropKit.detail(part)
	end
end

local function box(parent: Instance, name: string, frame: CFrame, a: Vector3, b: Vector3, options: PartOptions): Part
	local lo, hi = a:Min(b), a:Max(b)
	local part = Geometry.part(parent, name, frame * CFrame.new((lo + hi) / 2), hi - lo, nil, options)
	PropKit.detail(part)
	return part
end

local function placard(parent: Instance, frame: CFrame, x: number, y: number, z: number)
	local plate =
		box(parent, "Placard", frame, Vector3.new(x - 0.75, y - 0.3, z - 0.02), Vector3.new(x + 0.75, y + 0.3, z), {
			material = Enum.Material.SmoothPlastic,
			color = PLACARD,
		})
	ObjectiveKit.text(
		plate,
		"Locked",
		Strings.get("Prop.Lock.Locked"),
		ObjectiveKit.PlacardText,
		Enum.Font.Oswald,
		Enum.NormalId.Front,
		120
	)
end

--------------------------------------------------------------------------------
-- Door geometry
--------------------------------------------------------------------------------

-- Lock space: origin at the opening's centre on the wall's centre plane at floor level; -Z toward the floor side (the
-- way the squad comes), +Y up, +X the viewer's left.
export type DoorFace = {
	frame: CFrame, -- lock space (world)
	faceZ: number, -- lock-space Z of the shut leaves' floor-side face
	barZ: { number }?, -- [near, far] Z of the push bars when they face the floor side
	width: number, -- clear opening width
	double: boolean,
	latchX: number, -- lock-space X of the free (latch) edge of a single leaf; 0 for a double door
	doorId: string,
}

-- The fixture door whose opening holds `anchor` and the face its shut leaves present to the anchor's room.
function LockBuilder.doorFace(layout: Layout, anchor: Anchor): DoorFace?
	local origin = WorldConfig.levelOrigin(layout.id)
	local lockFrame = CFrame.new(origin + anchor.pos)
		* CFrame.Angles(0, math.rad(anchor.yaw or 0), 0)
		* CFrame.new(0, 0, WALL_HALF)
	for _, plan in DoorBuilder.planFixtures(layout) do
		local site = plan.site
		local centre = origin + site.frame.Position
		local offset = lockFrame:PointToObjectSpace(centre)
		if math.abs(offset.X) > 0.5 or math.abs(offset.Z) > 0.5 or #plan.leaves == 0 then
			continue
		end
		local leaf = plan.leaves[1]
		local swingRoom = if leaf.swing > 0 then site.rooms[2] else site.rooms[1]
		local towardFloor = swingRoom.id == anchor.room
		-- The shut leaves stand on their swing side: their back face at LeafBack, their front face a leaf further out
		local faceZ = if towardFloor then -(DoorBuilder.LeafBack + LEAF_THICKNESS) else DoorBuilder.LeafBack
		local barZ: { number }? = if leaf.style == "Fire" and not towardFloor
			then { DoorBuilder.LeafBack - PUSH_BAR_FAR, DoorBuilder.LeafBack - PUSH_BAR_NEAR }
			else nil
		local swingFrame = if leaf.swing > 0 then site.frame else site.frame * CFrame.Angles(0, math.pi, 0)
		local pin = lockFrame:PointToObjectSpace(origin + swingFrame * Vector3.new(leaf.hingeU, 0, -leaf.front))
		local latch = if #plan.leaves > 1 then 0 else -math.sign(pin.X) * (site.width / 2 - 0.45)
		return {
			frame = lockFrame,
			faceZ = faceZ,
			barZ = barZ,
			width = site.width,
			double = #plan.leaves > 1,
			latchX = latch,
			doorId = site.door.id,
		}
	end
	return nil
end

--------------------------------------------------------------------------------
-- Variants (lock space)
--------------------------------------------------------------------------------

local HASP_Y = 4.5

local function buildPadlockVariant(model: Model, face: DoorFace)
	local f, z = face.frame, face.faceZ
	local x = face.latchX
	local steel: PartOptions = { material = Enum.Material.Metal, color = ObjectiveKit.Steel }
	box(
		model,
		"HaspLeft",
		f,
		Vector3.new(x + 0.06, HASP_Y - 0.14, z - 0.05),
		Vector3.new(x + 0.62, HASP_Y + 0.14, z),
		steel
	)
	box(
		model,
		"HaspRight",
		f,
		Vector3.new(x - 0.62, HASP_Y - 0.14, z - 0.05),
		Vector3.new(x - 0.06, HASP_Y + 0.14, z),
		steel
	)
	box(
		model,
		"Staple",
		f,
		Vector3.new(x - 0.05, HASP_Y - 0.12, z - 0.24),
		Vector3.new(x + 0.05, HASP_Y + 0.12, z - 0.05),
		steel
	)
	local leaf = PropKit.leaf(model, "Padlock", f * CFrame.new(x, HASP_Y, z - 0.18))
	ObjectiveKit.padlock(leaf, "Padlock", f * CFrame.new(x, HASP_Y + 0.05, z - 0.18), 1.3, Color3.fromRGB(108, 94, 60))
	placard(model, f, x, HASP_Y + 1.1, z)
end

local function buildChainVariant(model: Model, face: DoorFace)
	local f, z = face.frame, face.faceZ
	local front = z - 0.4
	local back: number
	local bars = face.barZ
	if bars then
		back = (bars[2] + z) / 2 -- between the bar and the leaf
	else
		-- No push bars on this face: two staples welded to the leaves carry the chain
		back = z - 0.08
		for i, x in { -0.55, 0.55 } do
			box(
				model,
				"Staple" .. i,
				f,
				Vector3.new(x - 0.06, PUSH_BAR_Y - 0.3, z - 0.22),
				Vector3.new(x + 0.06, PUSH_BAR_Y + 0.3, z),
				{
					material = Enum.Material.Metal,
					color = ObjectiveKit.Steel,
				}
			)
		end
	end
	local leaf = PropKit.leaf(model, "Chain", f * CFrame.new(0, PUSH_BAR_Y, front))
	local y0, y1 = PUSH_BAR_Y - 0.35, PUSH_BAR_Y + 0.35
	local xl, xr = PUSH_BAR_END + 0.25, -(PUSH_BAR_END + 0.25)
	local points: { Vector3 } = {
		f * Vector3.new(0.05, PUSH_BAR_Y - 0.75, front),
		f * Vector3.new(xl, y0, front),
		f * Vector3.new(xl, y1, front),
		f * Vector3.new(xl, y1, back),
		f * Vector3.new(xl, y0, back),
		f * Vector3.new(xr, y0, back),
		f * Vector3.new(xr, y1, back),
		f * Vector3.new(xr, y1, front),
		f * Vector3.new(xr, y0, front),
		f * Vector3.new(-0.05, PUSH_BAR_Y - 0.75, front),
	}
	ObjectiveKit.chain(leaf, "Link", points, 0.34, 0.2, 0.06, CHAIN, 22)
	local lock = PropKit.leaf(model, "Padlock", f * CFrame.new(0, PUSH_BAR_Y - 0.8, front))
	ObjectiveKit.padlock(lock, "Padlock", f * CFrame.new(0, PUSH_BAR_Y - 0.72, front), 1.1, Color3.fromRGB(110, 96, 62))
	placard(model, f, 0, PUSH_BAR_Y + 1.6, z)
	local base = model.PrimaryPart
	if base then
		Geometry.attachment(base, "ChainCentre", base.CFrame:ToObjectSpace(f * CFrame.new(0, PUSH_BAR_Y, front)))
	end
end

local function buildKeypadVariant(model: Model, face: DoorFace, levelId: string)
	local f, z = face.frame, face.faceZ
	local steel: PartOptions = { material = Enum.Material.Metal, color = Color3.fromRGB(70, 72, 72) }
	-- The bar across the leaves, in a bracket on each side of the meeting edge
	local barY = 4.6
	for i, x in { 1.2, -1.2 } do
		box(
			model,
			"Bracket" .. i,
			f,
			Vector3.new(x - 0.12, barY - 0.2, z - 0.32),
			Vector3.new(x + 0.12, barY + 0.2, z),
			steel
		)
	end
	local bar = PropKit.leaf(model, "Bar", f * CFrame.new(0, barY, z - 0.17))
	box(bar, "LockBar", f, Vector3.new(-1.7, barY - 0.1, z - 0.27), Vector3.new(1.7, barY + 0.1, z - 0.07), {
		material = Enum.Material.Metal,
		color = Color3.fromRGB(120, 112, 42),
	})
	-- The electric lock's keypad on the viewer's right leaf, above the bar, its cable up the leaf to the head
	local kx = -2.6
	local wz = z
	box(model, "KeypadBox", f, Vector3.new(kx - 0.45, 5.1, wz - 0.24), Vector3.new(kx + 0.45, 6.5, wz), {
		material = Enum.Material.Metal,
		color = Color3.fromRGB(46, 48, 48),
	})
	local screen =
		box(model, "Screen", f, Vector3.new(kx - 0.36, 6.0, wz - 0.26), Vector3.new(kx + 0.36, 6.38, wz - 0.24), {
			material = Enum.Material.SmoothPlastic,
			color = Color3.fromRGB(14, 18, 16),
		})
	local key = "Prop.Keypad." .. levelId
	ObjectiveKit.text(
		screen,
		"Fault",
		Strings.get(if Strings.has(key) then key else "Prop.Keypad.Locked"),
		Color3.fromRGB(214, 50, 36),
		Enum.Font.Arcade,
		Enum.NormalId.Front,
		200,
		0
	)
	local keys = box(model, "Keys", f, Vector3.new(kx - 0.3, 5.2, wz - 0.26), Vector3.new(kx + 0.3, 5.92, wz - 0.24), {
		material = Enum.Material.SmoothPlastic,
		color = Color3.fromRGB(70, 72, 70),
	})
	ObjectiveKit.text(
		keys,
		"Keys",
		"1 2 3\n4 5 6\n7 8 9\n* 0 #",
		Color3.fromRGB(22, 22, 22),
		Enum.Font.Code,
		Enum.NormalId.Front,
		200
	)
	detail(
		Geometry.cylinder(
			model,
			"Led",
			f * Vector3.new(kx + 0.32, 6.47, wz - 0.24),
			f * Vector3.new(kx + 0.32, 6.47, wz - 0.3),
			0.09,
			nil,
			{
				material = Enum.Material.Neon,
				color = Color3.fromRGB(226, 40, 30),
			}
		)
	)
	detail(
		Geometry.cylinder(
			model,
			"Cable",
			f * Vector3.new(kx + 0.3, 6.5, wz - 0.06),
			f * Vector3.new(kx + 0.3, 9.4, wz - 0.06),
			0.1,
			"Conduit"
		)
	)
end

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

local function newRoot(parent: Instance, anchor: Anchor, face: DoorFace): (Model, Part)
	local model = PropKit.model(parent, anchor.id, face.frame)
	-- An invisible root at the lock's centre carries the attachments (the leaves record their rest on it)
	local base = Geometry.part(
		model,
		"Base",
		face.frame * CFrame.new(face.latchX, 3.6, face.faceZ - 0.3),
		Vector3.new(0.4, 0.4, 0.2),
		nil,
		{
			transparency = 1,
		}
	)
	PropKit.detail(base)
	model.PrimaryPart = base
	return model, base
end

local function lockPrompts(
	model: Model,
	base: BasePart,
	face: DoorFace,
	spec: ObjectiveConfig.FloorSpec,
	store: boolean
)
	local host = Geometry.attachment(
		base,
		"LockPrompt",
		base.CFrame:ToObjectSpace(face.frame * CFrame.new(face.latchX, 3.6, face.faceZ - 1.4))
	)
	if store then
		ObjectiveKit.prompt(
			host,
			spec,
			"Locked",
			ObjectiveConfig.StoreLockReason,
			"Prompt.StoreDoor",
			ObjectiveConfig.StoreLockStep,
			model,
			nil,
			0
		)
		ObjectiveKit.prompt(
			host,
			spec,
			"Unlock",
			"Prompt.Unlock",
			"Prompt.StoreDoor",
			ObjectiveConfig.StoreLockStep,
			model
		)
		return
	end
	ObjectiveKit.prompt(host, spec, "Locked", spec.lockReason, "Prompt.ExitDoor", spec.lockStep, model, nil, 0)
	if spec.holds.Unlock and spec.lockVariant == "Padlock" then
		ObjectiveKit.prompt(host, spec, "Unlock", "Prompt.Unlock", "Prompt.ExitDoor", spec.lockStep, model)
	end
	if spec.holds.Pour then
		ObjectiveKit.prompt(host, spec, "Pour", "Prompt.Pour", "Prompt.ChainedDoor", spec.lockStep, model)
	end
end

local function buildDoorLocks(ctx: PropKit.FixtureContext, kind: "ExitLock" | "StoreLock"): number
	local folderName = LockBuilder.Folders[kind]
	local stale = ctx.parent:FindFirstChild(folderName)
	if stale then
		stale:Destroy()
	end
	local spec = ObjectiveConfig.forLevel(ctx.layout.id)
	local anchors = PropKit.anchorsOf(ctx.layout, kind)
	if #anchors == 0 or not spec then
		return 0
	end
	local folder = Geometry.folder(ctx.parent, folderName)
	local built = 0
	for _, anchor in anchors do
		local face = LockBuilder.doorFace(ctx.layout, anchor)
		if not face then
			continue
		end
		local store = kind == "StoreLock"
		local variant: ObjectiveConfig.LockVariant = if store then "Padlock" else spec.lockVariant or "Padlock"
		local model, base = newRoot(folder, anchor, face)
		if variant == "Padlock" then
			buildPadlockVariant(model, face)
		elseif variant == "Chain" then
			buildChainVariant(model, face)
		else
			buildKeypadVariant(model, face, ctx.layout.id)
		end
		lockPrompts(model, base, face, spec, store)
		PropKit.setAttributes(model, {
			[W.AnchorId] = anchor.id,
			[W.ZoneId] = anchor.room,
			[W.DoorId] = face.doorId,
			[W.LockVariant] = variant,
			[W.Locked] = true,
		})
		if store then
			ObjectiveKit.mark(model, Tags.ObjectiveStation, spec, ObjectiveConfig.StoreLockStep, "StoreLock")
		else
			ObjectiveKit.mark(model, Tags.ExitLock, spec, spec.lockStep, "ExitLock")
		end
		built += 1
	end
	return built
end

-- The crate chain (crate space: X along the crate, Y up from the deck, -Z out of its front).
local function buildCrateChain(parent: Instance, anchor: Anchor, frame: CFrame, spec: ObjectiveConfig.FloorSpec): Model
	local halfL, _halfD, rim, wall = ParachuteBuilder.crateExtents(GameConfig.ParachutePackCount)
	local model = PropKit.model(parent, anchor.id, frame)
	local base =
		Geometry.part(model, "Base", frame * CFrame.new(halfL + 0.2, 0.95, -0.2), Vector3.new(0.4, 0.4, 0.2), nil, {
			transparency = 1,
		})
	PropKit.detail(base)
	model.PrimaryPart = base
	local steel: PartOptions = { material = Enum.Material.Metal, color = ObjectiveKit.Steel }
	for i, x in { -halfL - 0.05, halfL + 0.05 } do
		box(model, "EyePlate" .. i, frame, Vector3.new(x - 0.04, 0.75, -0.35), Vector3.new(x + 0.04, 1.15, 0.05), steel)
	end
	local chain = PropKit.leaf(model, "Chain", frame * CFrame.new(0, rim + 0.06, -0.15))
	local top = rim + 0.08
	local points: { Vector3 } = {
		frame * Vector3.new(-halfL - 0.12, 0.95, -0.15),
		frame * Vector3.new(-halfL - 0.12, top, -0.15),
		frame * Vector3.new(-halfL + wall, top, -0.15),
		frame * Vector3.new(0, rim - 0.15, -0.15),
		frame * Vector3.new(halfL - wall, top, -0.15),
		frame * Vector3.new(halfL + 0.12, top, -0.15),
		frame * Vector3.new(halfL + 0.12, 1.05, -0.15),
	}
	ObjectiveKit.chain(chain, "Link", points, 0.5, 0.26, 0.08, CHAIN, 24)
	local lock = PropKit.leaf(model, "Padlock", frame * CFrame.new(halfL + 0.2, 0.95, -0.2))
	ObjectiveKit.padlock(
		lock,
		"Padlock",
		frame * CFrame.new(halfL + 0.22, 1.0, -0.25),
		1.2,
		Color3.fromRGB(110, 96, 62)
	)
	Geometry.attachment(base, "ChainCentre", base.CFrame:ToObjectSpace(frame * CFrame.new(0, rim, -0.15)))
	local host =
		Geometry.attachment(base, "LockPrompt", base.CFrame:ToObjectSpace(frame * CFrame.new(halfL + 0.6, 1.4, -1.2)))
	ObjectiveKit.prompt(host, spec, "Locked", spec.lockReason, "Prompt.CrateChain", spec.lockStep, model, nil, 0)
	ObjectiveKit.prompt(host, spec, "CutChain", "Prompt.CutChain", "Prompt.CrateChain", spec.lockStep, model)
	PropKit.setAttributes(model, {
		[W.AnchorId] = anchor.id,
		[W.ZoneId] = anchor.room,
		[W.LockVariant] = "Chain",
		[W.Locked] = true,
	})
	ObjectiveKit.mark(model, Tags.ExitLock, spec, spec.lockStep, "CrateChain")
	model:AddTag(Tags.ObjectiveStation)
	return model
end

local function buildCrateChains(ctx: PropKit.FixtureContext): number
	local folderName = LockBuilder.Folders.CrateChain
	local stale = ctx.parent:FindFirstChild(folderName)
	if stale then
		stale:Destroy()
	end
	local spec = ObjectiveConfig.forLevel(ctx.layout.id)
	local anchors = PropKit.anchorsOf(ctx.layout, "CrateChain")
	if #anchors == 0 or not spec then
		return 0
	end
	local folder = Geometry.folder(ctx.parent, folderName)
	for _, anchor in anchors do
		buildCrateChain(folder, anchor, PropKit.anchorCFrame(ctx.layout.id, anchor), spec)
	end
	return #anchors
end

-- The chain 0 (on) .. 1 (cut: dropped off its staples / the crate, out of sight under the door or into the crate).
function LockBuilder.setChain(model: Model, dropped: number): boolean
	return PropKit.poseLeaf(model, "Chain", CFrame.new(0, -math.clamp(dropped, 0, 1) * 2, 0))
end

-- The keypad variant's bar 0 (across the leaves) .. 1 (slid clear).
function LockBuilder.setBar(model: Model, released: number): boolean
	return PropKit.poseLeaf(model, "Bar", CFrame.new(math.clamp(released, 0, 1) * 3.2, 0, 0))
end

function LockBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture("ExitLock", function(ctx: PropKit.FixtureContext): number
		return buildDoorLocks(ctx, "ExitLock")
	end)
	registrar.fixture("StoreLock", function(ctx: PropKit.FixtureContext): number
		return buildDoorLocks(ctx, "StoreLock")
	end)
	registrar.fixture("CrateChain", buildCrateChains)
end

return table.freeze(LockBuilder)
