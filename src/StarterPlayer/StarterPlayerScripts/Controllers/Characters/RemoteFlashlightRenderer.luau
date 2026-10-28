--!strict
-- RemoteFlashlightRenderer: teammates' flashlight beams on this client.
--
-- Every other player whose FlashlightOn attribute is true, who is not Dead or Spectating, and whose character has a
-- Head in Workspace is a candidate. Only the nearest RenderBudgetController budget.remoteFlashlights candidates (to
-- the camera) get a light; ranking runs at RANK_HZ, and a teammate who already has a light ranks as if
-- HYSTERESIS closer, so two teammates at similar distances never trade a light back and forth.
--
-- A beam is one SpotLight (the outer cone only: wide, dim and unshadowed, the cheap part of the dual cone) on an
-- invisible, anchored, never-queried part under the camera, placed just ahead of the teammate's Head every frame.
-- It points along the teammate's look from LookBroadcast (int16 angles, dequantized; the 10 Hz samples are eased
-- toward with a damped, wrap-aware approach, so the beam sweeps smoothly between samples). Before a teammate's first
-- sample the beam follows their root's facing (which tracks their camera yaw) at level pitch. Brightness follows the
-- same rules as the local light (FirstPersonController.FlashlightLevel): their Battery meter dims and warms it below
-- 15 %, and EMF interference at their head (FirstPersonController.EmfIntensityAt with their ZoneId) makes it
-- flicker, on server time, so everyone sees the same flicker.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local RenderBudgetController = require(script.Parent.Parent.Core.RenderBudgetController)
local FirstPersonController = require(script.Parent.Parent.FirstPerson.FirstPersonController)

local P = Attributes.Player

export type Candidate = { userId: number, distance: number }

type Look = { yaw: number, pitch: number, targetYaw: number, targetPitch: number }

type Beam = { part: Part, light: SpotLight, player: Player? }

local RemoteFlashlightRenderer = {}

RemoteFlashlightRenderer.Name = "RemoteFlashlightRenderer"

local RANK_HZ = 4
local HYSTERESIS = 0.85
local MAX_BEAMS = 8
local LOOK_SPEED = 14 -- 1/s easing toward the latest sample
local HEAD_LEAD = 0.55 -- studs ahead of the head centre
local HEAD_DROP = 0.15
local ANGLE = 70
local RANGE = 34
local BRIGHTNESS = 0.9
local HIDDEN_LIFE_STATES: { [string]: boolean } = { Dead = true, Spectating = true }

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local looks: { [number]: Look } = {}
local beams: { Beam } = {}
local assigned: { [Player]: Beam } = {}
local rankClock = math.huge
local cap = 0

--------------------------------------------------------------------------------
-- Pure helpers
--------------------------------------------------------------------------------

-- The userIds that get a beam: nearest first, `current` holders ranked HYSTERESIS closer, at most `limit`.
function RemoteFlashlightRenderer.select(
	candidates: { Candidate },
	current: { [number]: boolean },
	limit: number
): { number }
	local ranked = table.clone(candidates)
	local function rank(candidate: Candidate): number
		return if current[candidate.userId] then candidate.distance * HYSTERESIS else candidate.distance
	end
	table.sort(ranked, function(a: Candidate, b: Candidate): boolean
		local ra, rb = rank(a), rank(b)
		if ra == rb then
			return a.userId < b.userId
		end
		return ra < rb
	end)
	local out: { number } = {}
	for index = 1, math.min(#ranked, math.max(0, math.floor(limit))) do
		table.insert(out, ranked[index].userId)
	end
	return out
end

-- Eases an angle toward a target the short way round.
function RemoteFlashlightRenderer.approachAngle(current: number, target: number, speed: number, dt: number): number
	return MathUtil.wrapAngle(current + MathUtil.angleDelta(current, target) * MathUtil.damp(speed, dt))
end

--------------------------------------------------------------------------------
-- Runtime
--------------------------------------------------------------------------------

local function newBeam(): Beam
	local part = Instance.new("Part")
	part.Name = "TeammateBeam"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	local light = Instance.new("SpotLight")
	light.Name = "Outer"
	light.Face = Enum.NormalId.Front
	light.Angle = ANGLE
	light.Range = RANGE
	light.Brightness = 0
	light.Shadows = false
	light.Enabled = false
	light.Parent = part
	return { part = part, light = light, player = nil }
end

local function headOf(player: Player): BasePart?
	local character = player.Character
	if not character or not character:IsDescendantOf(Workspace) then
		return nil
	end
	local head = character:FindFirstChild("Head")
	return if head and head:IsA("BasePart") then head else nil
end

local function isCandidate(player: Player): boolean
	return player ~= localPlayer
		and player.Parent == Players
		and Attributes.getBool(player, P.FlashlightOn, false)
		and not HIDDEN_LIFE_STATES[Attributes.getString(player, P.LifeState, "Lobby")]
		and headOf(player) ~= nil
end

local function release(player: Player)
	local beam = assigned[player]
	if beam then
		assigned[player] = nil
		beam.player = nil
		beam.light.Enabled = false
	end
end

local function rerank(cameraPosition: Vector3)
	local candidates: { Candidate } = {}
	local byId: { [number]: Player } = {}
	local current: { [number]: boolean } = {}
	for _, player in Players:GetPlayers() do
		if isCandidate(player) then
			local head = headOf(player)
			if head then
				table.insert(
					candidates,
					{ userId = player.UserId, distance = (head.Position - cameraPosition).Magnitude }
				)
				byId[player.UserId] = player
				if assigned[player] then
					current[player.UserId] = true
				end
			end
		end
	end
	local chosen: { [Player]: boolean } = {}
	for _, userId in RemoteFlashlightRenderer.select(candidates, current, cap) do
		chosen[byId[userId]] = true
	end
	for player in table.clone(assigned) do
		if not chosen[player] then
			release(player)
		end
	end
	for player in chosen do
		if assigned[player] then
			continue
		end
		local free: Beam? = nil
		for _, beam in beams do
			if beam.player == nil then
				free = beam
				break
			end
		end
		if free == nil and #beams < MAX_BEAMS then
			local made = newBeam()
			table.insert(beams, made)
			free = made
		end
		if free then
			free.player = player
			assigned[player] = free
		end
	end
end

local function lookFor(player: Player, head: BasePart, dt: number): (number, number)
	local look = looks[player.UserId]
	if look == nil then
		local character = player.Character
		local rootPart = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local facing = if rootPart and rootPart:IsA("BasePart")
			then rootPart.CFrame.LookVector
			else head.CFrame.LookVector
		local yaw = MathUtil.yawPitchFromVector(facing)
		return yaw, 0
	end
	look.yaw = RemoteFlashlightRenderer.approachAngle(look.yaw, look.targetYaw, LOOK_SPEED, dt)
	look.pitch = RemoteFlashlightRenderer.approachAngle(look.pitch, look.targetPitch, LOOK_SPEED, dt)
	return look.yaw, look.pitch
end

local function onRender(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	rankClock += dt
	if rankClock >= 1 / RANK_HZ then
		rankClock = 0
		rerank(camera.CFrame.Position)
	end
	local serverNow = Workspace:GetServerTimeNow()
	for player, beam in assigned do
		local head = headOf(player)
		if not head or not Attributes.getBool(player, P.FlashlightOn, false) then
			beam.light.Enabled = false
			continue
		end
		if beam.part.Parent ~= camera then
			beam.part.Parent = camera
		end
		local yaw, pitch = lookFor(player, head, dt)
		local rotation = CFrame.fromOrientation(pitch, yaw, 0)
		local position = head.Position + rotation.LookVector * HEAD_LEAD - Vector3.new(0, HEAD_DROP, 0)
		beam.part.CFrame = CFrame.new(position) * rotation

		local maxBattery = Attributes.getNumber(player, P.BatteryMax, GameConfig.BatteryMax)
		local battery = Attributes.readMeter(player, P.Battery, P.BatteryRate, P.BatteryAt, maxBattery, serverNow)
		local fraction = if maxBattery > 0 then MathUtil.clamp01(battery / maxBattery) else 0
		local emf = FirstPersonController.EmfIntensityAt(head.Position, Attributes.getString(player, P.ZoneId, ""))
		local level = FirstPersonController.FlashlightLevel(fraction, emf, serverNow, player.UserId)
		local on = level > 0.01
		if beam.light.Enabled ~= on then
			beam.light.Enabled = on
		end
		if on then
			beam.light.Brightness = BRIGHTNESS * level
			local color = FirstPersonController.BeamColor(fraction)
			if beam.light.Color ~= color then
				beam.light.Color = color
			end
		end
	end
end

local function onLookBroadcast(payload: any)
	if type(payload) ~= "table" or type(payload.samples) ~= "table" then
		return
	end
	local me = if localPlayer then localPlayer.UserId else nil
	for _, sample in payload.samples :: { any } do
		if type(sample) ~= "table" then
			continue
		end
		local userId, rawYaw, rawPitch = sample.userId, sample.yaw, sample.pitch
		if type(userId) ~= "number" or type(rawYaw) ~= "number" or type(rawPitch) ~= "number" or userId == me then
			continue
		end
		local yaw = MathUtil.dequantizeAngle(rawYaw)
		local pitch = MathUtil.dequantizeAngle(rawPitch)
		local look = looks[userId]
		if look then
			look.targetYaw, look.targetPitch = yaw, pitch
		else
			looks[userId] = { yaw = yaw, pitch = pitch, targetYaw = yaw, targetPitch = pitch }
		end
	end
end

local function applyBudget(budget: RenderBudgetController.Budget)
	cap = math.clamp(math.floor(budget.remoteFlashlights), 0, MAX_BEAMS)
	rankClock = math.huge
end

function RemoteFlashlightRenderer.Init()
	applyBudget(RenderBudgetController.GetBudget())
	serviceTrove:Add(RenderBudgetController.BudgetChanged:Connect(applyBudget))
end

function RemoteFlashlightRenderer.Start()
	local connection = Net.Client.on("LookBroadcast", onLookBroadcast)
	if connection then
		serviceTrove:Add(connection)
	end
	serviceTrove:Connect(Players.PlayerRemoving, function(player: Player)
		release(player)
		looks[player.UserId] = nil
	end)
	serviceTrove:Connect(RunService.PreRender, onRender)
	serviceTrove:Add(function()
		for _, beam in beams do
			beam.part:Destroy()
		end
		table.clear(beams)
		table.clear(assigned)
	end)
end

function RemoteFlashlightRenderer.OnRunStarted(_info: Types.RunInfo)
	rankClock = math.huge
end

return RemoteFlashlightRenderer
