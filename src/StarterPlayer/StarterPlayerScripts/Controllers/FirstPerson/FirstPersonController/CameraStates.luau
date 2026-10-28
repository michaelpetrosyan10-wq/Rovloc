--!strict
-- CameraStates: which first-person camera state each MoveState uses, and each state's eye offset, pitch range and
-- view-bob profile. Pure data and functions; FirstPersonController and the specs read them.
--
-- Eye offsets. CameraConfig.StateOffsets[state] moves the eye away from the standing eye (rotated by camera yaw, so
-- the vent crawl's -0.5 Z always leans into the duct ahead). Several MoveStates share one camera state (Sprinting
-- rides Standing, Freestyle rides SurfaceSwimming, Grabbed rides UnderwaterSwimming, ...). Each camera state has a
-- primary MoveState whose eye is exactly the configured offset; a sibling MoveState adds a vertical trim equal to
-- the difference between the two states' server eye heights (CameraConfig.EyeHeightAboveRoot, the point Creature
-- line of sight aims at). A sprinting player therefore sees from 0.1 lower than a walking one, exactly as the
-- server's eye point drops, and a camera state forced by a later phase (LockerPeeking, ParachuteLookback, ...) uses
-- its configured offset as is.
--
-- Pitch ranges are degrees (CameraConfig.Pitch): free on foot and in water, ±35 in the 3.5-stud ducts, narrow
-- behind the locker slits, and limited downward while crawling on the stomach.
--
-- Bob profiles scale CameraConfig.Bob per MoveState: `amplitude` multiplies the walk bob, `frequency` the gait
-- cadence at the state's own nominal speed (GameConfig), so the bob's rhythm follows the legs in every posture.
-- States where the body is held still (hiding, trapped, grabbed, parachuting, scripted) do not bob.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

export type PitchRange = { min: number, max: number } -- degrees

export type BobProfile = {
	amplitude: number, -- multiplier on CameraConfig.Bob walk amplitudes
	frequency: number, -- multiplier on CameraConfig.Bob.WalkFrequency at nominalSpeed
	nominalSpeed: number, -- studs/s at which the profile runs at full amplitude and cadence
}

local CameraStates = {}

local MOVE_TO_CAMERA: { [string]: Enums.CameraState } = {
	Standing = "Standing",
	Sprinting = "Standing",
	Crouching = "Crouching",
	VentCrawling = "VentCrawling",
	VentScurrying = "VentCrawling",
	DownedCrawling = "DownedCrawling",
	Treading = "SurfaceSwimming",
	Freestyle = "SurfaceSwimming",
	Underwater = "UnderwaterSwimming",
	Hiding = "LockerPeeking",
	Trapped = "Standing",
	Grabbed = "UnderwaterSwimming",
	Parachuting = "Standing",
	Scripted = "Standing",
}

-- The MoveState whose eye a camera state's configured offset describes exactly.
local PRIMARY_MOVE: { [string]: Enums.MoveState } = {
	Standing = "Standing",
	Crouching = "Crouching",
	VentCrawling = "VentCrawling",
	DownedCrawling = "DownedCrawling",
	LockerPeeking = "Hiding",
	SurfaceSwimming = "Treading",
	UnderwaterSwimming = "Underwater",
	ParachuteLookback = "Parachuting",
}

local P = CameraConfig.Pitch

local PITCH: { [string]: PitchRange } = {
	Standing = { min = P.Min, max = P.Max },
	Crouching = { min = P.Min, max = P.Max },
	VentCrawling = { min = P.VentMin, max = P.VentMax },
	DownedCrawling = { min = -50, max = 65 },
	LockerPeeking = { min = -25, max = 25 },
	SurfaceSwimming = { min = -70, max = 75 },
	UnderwaterSwimming = { min = P.Min, max = P.Max },
	ParachuteLookback = { min = P.Min, max = P.Max },
}

local B = CameraConfig.Bob

local STILL: BobProfile = { amplitude = 0, frequency = 1, nominalSpeed = GameConfig.WalkSpeed }

local BOB: { [string]: BobProfile } = {
	Standing = { amplitude = 1, frequency = 1, nominalSpeed = GameConfig.WalkSpeed },
	Sprinting = { amplitude = B.SprintMultiplier, frequency = 1.32, nominalSpeed = GameConfig.SprintSpeed },
	Crouching = { amplitude = B.CrouchMultiplier, frequency = 0.8, nominalSpeed = GameConfig.CrouchSpeed },
	VentCrawling = { amplitude = B.VentMultiplier, frequency = 0.7, nominalSpeed = GameConfig.VentCrawlSpeed },
	VentScurrying = { amplitude = B.VentMultiplier * 1.4, frequency = 0.95, nominalSpeed = GameConfig.VentScurrySpeed },
	DownedCrawling = { amplitude = 0.9, frequency = 0.5, nominalSpeed = GameConfig.DownedMoveSpeed },
	Treading = { amplitude = 0.35, frequency = 0.45, nominalSpeed = GameConfig.TreadSpeed },
	Freestyle = { amplitude = 0.6, frequency = 0.65, nominalSpeed = GameConfig.FreestyleSpeed },
	Underwater = { amplitude = 0.3, frequency = 0.4, nominalSpeed = GameConfig.UnderwaterSpeed },
	Hiding = STILL,
	Trapped = STILL,
	Grabbed = STILL,
	Parachuting = STILL,
	Scripted = STILL,
}

local function serverEye(moveState: string): number
	local heights = CameraConfig.EyeHeightAboveRoot
	return heights[moveState] or heights.Standing
end

-- The camera state a MoveState renders with.
function CameraStates.fromMoveState(moveState: Enums.MoveState): Enums.CameraState
	return MOVE_TO_CAMERA[moveState] or "Standing"
end

-- Vertical trim of `moveState` relative to the primary MoveState of `cameraState` (0 for the primary itself).
function CameraStates.eyeTrim(moveState: Enums.MoveState, cameraState: Enums.CameraState): number
	local primary = PRIMARY_MOVE[cameraState]
	if primary == nil or MOVE_TO_CAMERA[moveState] ~= cameraState then
		return 0
	end
	return serverEye(moveState) - serverEye(primary)
end

-- Eye offset from the standing eye, in camera-yaw space. `forced` is a camera state a later phase pinned.
function CameraStates.offset(moveState: Enums.MoveState, forced: Enums.CameraState?): Vector3
	local cameraState: Enums.CameraState = forced or CameraStates.fromMoveState(moveState)
	local base = CameraConfig.StateOffsets[cameraState] or Vector3.zero
	return base + Vector3.new(0, CameraStates.eyeTrim(moveState, cameraState), 0)
end

-- Pitch range of a camera state, degrees (min, max).
function CameraStates.pitchLimits(cameraState: Enums.CameraState): (number, number)
	local range = PITCH[cameraState] or PITCH.Standing
	return range.min, range.max
end

function CameraStates.bob(moveState: Enums.MoveState): BobProfile
	return BOB[moveState] or BOB.Standing
end

-- Every camera state has a primary MoveState, an offset and a pitch range (specs walk this list).
CameraStates.List = Enums.CameraState

return table.freeze(CameraStates)
