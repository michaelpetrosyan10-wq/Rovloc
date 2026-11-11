--!strict
-- LockBuilder: what keeps each floor's exit shut until its objective is done.
-- Fixture kind, rebuilt at every run start into Workspace.Runtime.<level> (everything locked):
--
--   "ExitLock"   (ExitLocks folder, one per ExitLock anchor: the floor point on the exit airlock door's face on the
--                floor side, facing out of the door). The lock sits on the door's shut leaves (DoorBuilder's plan for
--                that door says which face of the opening they close on), in ObjectiveConfig's variant for the floor:
--                  Padlock  a steel hasp across the leaves' meeting stiles and a heavy padlock (leaf "Padlock");
--                  Keypad   a steel bar dropped into brackets across both leaves (leaf "Bar", sliding clear along X
--                           when released) and an electric lock's keypad on the leaf above it, whose dead screen
--                           names the fault (Prop.Keypad.<level>) and whose LED stays red.
--                Padlock hangs a red "LOCKED" placard on the leaves. A floor without a lock (ObjectiveConfig: no
--                lockStep) gets none.
--
-- Prompts (disabled), all on Attachment "LockPrompt": Locked (hold 0, ActionText the floor's lockReason, e.g.
-- "Locked — no power"; Step = the floor's lockStep) on every lock; Unlock (the master keys, Step UnlockExit, 4 s) on
-- the Level 1 exit lock. Attributes Floor, Step, ObjectiveId (ExitLock), LockVariant, Locked = true, AnchorId,
-- LevelId, ZoneId and DoorId (the door it holds). Tags: ExitLock, Interactable. Every part is a hand-scale detail:
-- nothing narrows the doorway's clear width.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local DoorBuilder = require(script.Parent.DoorBuilder)
local Geometry = require(script.Parent.Parent.Geometry)
local ObjectiveKit = require(script.Parent.ObjectiveKit)
local PropKit = require(script.Parent.PropKit)

local W = Attributes.World

type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor
type PartOptions = Geometry.PartOptions

local WALL_HALF = WorldConfig.WallThickness / 2
local LEAF_THICKNESS = 0.24

local LockBuilder = {}

LockBuilder.Budgets = table.freeze({ Padlock = 12, Keypad = 12 } :: { [string]: number })
LockBuilder.Folders = table.freeze({ ExitLock = "ExitLocks" })

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
		local swingFrame = if leaf.swing > 0 then site.frame else site.frame * CFrame.Angles(0, math.pi, 0)
		local pin = lockFrame:PointToObjectSpace(origin + swingFrame * Vector3.new(leaf.hingeU, 0, -leaf.front))
		local latch = if #plan.leaves > 1 then 0 else -math.sign(pin.X) * (site.width / 2 - 0.45)
		return {
			frame = lockFrame,
			faceZ = faceZ,
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
	lockStep: string,
	lockReason: string
)
	local host = Geometry.attachment(
		base,
		"LockPrompt",
		base.CFrame:ToObjectSpace(face.frame * CFrame.new(face.latchX, 3.6, face.faceZ - 1.4))
	)
	ObjectiveKit.prompt(host, spec, "Locked", lockReason, "Prompt.ExitDoor", lockStep, model, nil, 0)
	if spec.holds.Unlock and spec.lockVariant == "Padlock" then
		ObjectiveKit.prompt(host, spec, "Unlock", "Prompt.Unlock", "Prompt.ExitDoor", lockStep, model)
	end
end

local function buildExitLocks(ctx: PropKit.FixtureContext): number
	local folderName = LockBuilder.Folders.ExitLock
	local stale = ctx.parent:FindFirstChild(folderName)
	if stale then
		stale:Destroy()
	end
	local spec = ObjectiveConfig.forLevel(ctx.layout.id)
	local anchors = PropKit.anchorsOf(ctx.layout, "ExitLock")
	local lockStep = if spec then spec.lockStep else nil
	local lockReason = if spec then spec.lockReason else nil
	if #anchors == 0 or not spec or not lockStep or not lockReason then
		return 0
	end
	local folder = Geometry.folder(ctx.parent, folderName)
	local built = 0
	for _, anchor in anchors do
		local face = LockBuilder.doorFace(ctx.layout, anchor)
		if not face then
			continue
		end
		local variant: ObjectiveConfig.LockVariant = spec.lockVariant or "Padlock"
		local model, base = newRoot(folder, anchor, face)
		if variant == "Padlock" then
			buildPadlockVariant(model, face)
		else
			buildKeypadVariant(model, face, ctx.layout.id)
		end
		lockPrompts(model, base, face, spec, lockStep, lockReason)
		PropKit.setAttributes(model, {
			[W.AnchorId] = anchor.id,
			[W.ZoneId] = anchor.room,
			[W.DoorId] = face.doorId,
			[W.LockVariant] = variant,
			[W.Locked] = true,
		})
		ObjectiveKit.mark(model, Tags.ExitLock, spec, lockStep, "ExitLock")
		built += 1
	end
	return built
end

-- The keypad variant's bar 0 (across the leaves) .. 1 (slid clear).
function LockBuilder.setBar(model: Model, released: number): boolean
	return PropKit.poseLeaf(model, "Bar", CFrame.new(math.clamp(released, 0, 1) * 3.2, 0, 0))
end

function LockBuilder.register(registrar: PropKit.Registrar)
	registrar.fixture("ExitLock", buildExitLocks)
end

return table.freeze(LockBuilder)
