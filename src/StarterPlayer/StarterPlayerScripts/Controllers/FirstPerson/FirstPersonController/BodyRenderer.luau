--!strict
-- BodyRenderer: the only writer of LocalTransparencyModifier. Lets the first-person viewer see their own body.
--
-- For the subject model (the local character, or a teammate a later phase views through), every BasePart and Decal
-- is classified once (and again whenever the model's descendants change):
--   * head-attached: the Head itself, its decals (the face), and anything held to the Head: an accessory whose weld
--     joins the Head, or whose Handle carries an attachment named like one of the Head's (hat, hair, face), and any
--     other part welded straight to the Head;
--   * body: everything else (torso, arms, legs, hands, feet, other accessories, the torch).
-- Every frame, after the camera has moved, Render() writes 1 on head-attached pieces and 0 on the body, so the viewer
-- sees their arms and feet but never the inside of their own head. While the camera is further than HEAD_HIDE_RADIUS
-- from the head (a cutscene or spectator shot of the body from outside), the head shows too. A changed or cleared
-- subject gets its modifiers back to 0.

local BodyRenderer = {}

type PartEntry = { instance: BasePart, head: boolean }
type DecalEntry = { instance: Decal, head: boolean }

local HEAD_HIDE_RADIUS = 2.4

local subject: Model? = nil
local parts: { PartEntry } = {}
local decals: { DecalEntry } = {}
local dirty = true
local connections: { RBXScriptConnection } = {}

local function jointTouches(joint: Instance, part: Instance): boolean
	if joint:IsA("JointInstance") then
		return joint.Part0 == part or joint.Part1 == part
	elseif joint:IsA("WeldConstraint") then
		return joint.Part0 == part or joint.Part1 == part
	end
	return false
end

-- Is `part` (a BasePart of the subject) part of the head, or held to it?
function BodyRenderer.isHeadAttached(part: BasePart, head: BasePart?): boolean
	if head == nil then
		return false
	end
	if part == head then
		return true
	end
	for _, descendant in part:GetDescendants() do
		if jointTouches(descendant, head) then
			return true
		end
	end
	for _, descendant in head:GetDescendants() do
		-- Rig joints (the Neck lives in the Head) join the head to the body; they do not make the torso "head".
		if not descendant:IsA("Motor6D") and jointTouches(descendant, part) then
			return true
		end
	end
	local accessory = part.Parent
	if accessory and accessory:IsA("Accessory") then
		for _, child in part:GetChildren() do
			if child:IsA("Attachment") then
				local match = head:FindFirstChild(child.Name)
				if match and match:IsA("Attachment") then
					return true
				end
			end
		end
	end
	return false
end

local function headOf(model: Model): BasePart?
	local head = model:FindFirstChild("Head")
	return if head and head:IsA("BasePart") then head else nil
end

local function rebuild(model: Model)
	table.clear(parts)
	table.clear(decals)
	local head = headOf(model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, { instance = descendant, head = BodyRenderer.isHeadAttached(descendant, head) })
		elseif descendant:IsA("Decal") then
			local holder = descendant.Parent
			local onHead = false
			if holder and holder:IsA("BasePart") then
				onHead = BodyRenderer.isHeadAttached(holder, head)
			end
			table.insert(decals, { instance = descendant, head = onHead })
		end
	end
	dirty = false
end

local function writePart(part: BasePart, value: number)
	if part.LocalTransparencyModifier ~= value then
		part.LocalTransparencyModifier = value
	end
end

local function writeDecal(decal: Decal, value: number)
	if decal.LocalTransparencyModifier ~= value then
		decal.LocalTransparencyModifier = value
	end
end

local function disconnect()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

-- Puts every modifier of the current subject back to 0.
function BodyRenderer.Restore()
	for _, entry in parts do
		if entry.instance.Parent ~= nil then
			writePart(entry.instance, 0)
		end
	end
	for _, entry in decals do
		if entry.instance.Parent ~= nil then
			writeDecal(entry.instance, 0)
		end
	end
end

function BodyRenderer.SetSubject(model: Model?)
	if model == subject then
		return
	end
	BodyRenderer.Restore()
	disconnect()
	table.clear(parts)
	table.clear(decals)
	subject = model
	dirty = true
	if model then
		local function mark()
			dirty = true
		end
		table.insert(connections, model.DescendantAdded:Connect(mark))
		table.insert(connections, model.DescendantRemoving:Connect(mark))
	end
end

function BodyRenderer.GetSubject(): Model?
	return subject
end

-- Per frame, after the camera: `cameraPosition` decides whether the head is hidden.
function BodyRenderer.Render(cameraPosition: Vector3?)
	local model = subject
	if model == nil or model.Parent == nil then
		return
	end
	if dirty then
		rebuild(model)
	end
	local head = headOf(model)
	local hideHead = head ~= nil
		and cameraPosition ~= nil
		and (head.Position - cameraPosition).Magnitude <= HEAD_HIDE_RADIUS
	for _, entry in parts do
		writePart(entry.instance, if entry.head and hideHead then 1 else 0)
	end
	for _, entry in decals do
		writeDecal(entry.instance, if entry.head and hideHead then 1 else 0)
	end
end

return BodyRenderer
