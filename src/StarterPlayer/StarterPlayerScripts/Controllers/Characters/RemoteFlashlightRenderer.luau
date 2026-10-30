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
-- flicker, on server time, so everyone sees the same flicker. Like the local torch it burns at the camera level's
-- torch gain (LightingController.GetRender().torch).
--
-- Focus (P8 spectating). SetFocus(player, view) makes one teammate's torch the one seen from inside their eyes: it
-- always has a beam (outside the budget cap), placed at view() (the spectator camera) plus the torch's look-space
-- offset, and lit as the whole dual cone the holder sees (FirstPersonController.BeamCones: the inner cone too, shadowed
-- when the budget allows shadows). SetFocus(nil) returns it to an ordinary outer-cone beam.

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

local LightingController = require(script.Parent.Parent.Core.LightingController)
local RenderBudgetController = require(script.Parent.Parent.Core.RenderBudgetController)
local FirstPersonController = require(script.Parent.Parent.FirstPerson.FirstPersonController)

local P = Attributes.Player

export type Candidate = { userId: number, distance: number }

type Look = { yaw: number, pitch: number, targetYaw: number, targetPitch: number }

type Beam = { part: Part, light: SpotLight, inner: SpotLight, player: Player?, focused: boolean }

type Focus = { player: Player, view: () -> CFrame }

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
local shadows = false
local focus: Focus? = nil

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
	local inner = Instance.new("SpotLight")
	inner.Name = "Inner"
	inner.Face = Enum.NormalId.Front
	inner.Angle = FirstPersonController.BeamCones.innerAngle
	inner.Range = FirstPersonController.BeamCones.innerRange
	inner.Brightness = 0
	inner.Shadows = false
	inner.Enabled = false
	inner.Parent = part
	return { part = part, light = light, inner = inner, player = nil, focused = false }
end

-- Shapes a beam as the ordinary outer cone or as the focused teammate's whole dual cone.
local function shape(beam: Beam, focused: boolean)
	if beam.focused == focused then
		return
	end
	beam.focused = focused
	local cones = FirstPersonController.BeamCones
	beam.light.Angle = if focused then cones.outerAngle else ANGLE
	beam.light.Range = if focused then cones.outerRange else RANGE
	if not focused then
		beam.inner.Enabled = false
		beam.inner.Shadows = false
	end
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
		shape(beam, false)
	end
end

local function rerank(cameraPosition: Vector3)
	local candidates: { Candidate } = {}
	local byId: { [number]: Player } = {}
	local current: { [number]: boolean } = {}
	local focused = focus
	local focusPlayer: Player? = if focused and isCandidate(focused.player) then focused.player else nil
	for _, player in Players:GetPlayers() do
		if player ~= focusPlayer and isCandidate(player) then
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
	if focusPlayer then
		chosen[focusPlayer] = true
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
		if free == nil and (#beams < MAX_BEAMS or player == focusPlayer) then
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
	local focused = focus
	local cones = FirstPersonController.BeamCones
	for player, beam in assigned do
		local head = headOf(player)
		if not head or not Attributes.getBool(player, P.FlashlightOn, false) then
			beam.light.Enabled = false
			beam.inner.Enabled = false
			continue
		end
		if beam.part.Parent ~= camera then
			beam.part.Parent = camera
		end
		local isFocus = focused ~= nil and focused.player == player
		shape(beam, isFocus)
		if focused and isFocus then
			beam.part.CFrame = focused.view() * CFrame.new(cones.offset)
		else
			local yaw, pitch = lookFor(player, head, dt)
			local rotation = CFrame.fromOrientation(pitch, yaw, 0)
			local position = head.Position + rotation.LookVector * HEAD_LEAD - Vector3.new(0, HEAD_DROP, 0)
			beam.part.CFrame = CFrame.new(position) * rotation
		end

		local maxBattery = Attributes.getNumber(player, P.BatteryMax, GameConfig.BatteryMax)
		local battery = Attributes.readMeter(player, P.Battery, P.BatteryRate, P.BatteryAt, maxBattery, serverNow)
		local fraction = if maxBattery > 0 then MathUtil.clamp01(battery / maxBattery) else 0
		local emf = FirstPersonController.EmfIntensityAt(head.Position, Attributes.getString(player, P.ZoneId, ""))
		local level = FirstPersonController.FlashlightLevel(fraction, emf, serverNow, player.UserId)
		local on = level > 0.01
		if beam.light.Enabled ~= on then
			beam.light.Enabled = on
		end
		local innerOn = on and isFocus
		if beam.inner.Enabled ~= innerOn then
			beam.inner.Enabled = innerOn
		end
		if on then
			local gain = LightingController.GetRender().torch
			beam.light.Brightness = (if isFocus then cones.outerBrightness else BRIGHTNESS) * level * gain
			local color = FirstPersonController.BeamColor(fraction)
			if beam.light.Color ~= color then
				beam.light.Color = color
			end
			if innerOn then
				beam.inner.Brightness = cones.innerBrightness * level * gain
				if beam.inner.Color ~= color then
					beam.inner.Color = color
				end
				if beam.inner.Shadows ~= shadows then
					beam.inner.Shadows = shadows
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Lights `player`'s torch as seen from inside their eyes, placed along `view()` (the spectator camera, called every
-- frame); nil returns every teammate to an ordinary beam.
function RemoteFlashlightRenderer.SetFocus(player: Player?, view: (() -> CFrame)?)
	if player and view then
		focus = { player = player, view = view }
	else
		focus = nil
	end
	rankClock = math.huge
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
	shadows = budget.shadows
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
