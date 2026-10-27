--!strict
-- DebrisNoise: floor debris (broken glass, cans, rubble) is loud. A player whose root or feet enter a `FloorDebris`
-- trigger volume (ZoneService.VolumeEntered) while the match is InRun makes one 130-stud `FloorDebris` noise
-- (NoiseConfig, Critical priority) where they stand and one `GlassCrunch` cue there for everyone. Each
-- (player, volume) pair then rests for `Cooldown` seconds, so stepping off and back onto the same glass, or walking
-- along a volume's edge, does not machine-gun the Creature's hearing; a different volume crunches at once.
--
-- NoiseAndDirectorService owns this (docs/ARCHITECTURE.md §5 "Floor debris"); the Floor 1 ScareStep trigger stays
-- with the P6 Level 1 controller. The rules are written against injected dependencies (Deps), so specs drive them
-- with fake players, clocks and emitters.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Tags = require(ReplicatedStorage.Shared.Tags)

local LocomotionNoiseSampler = require(script.Parent.LocomotionNoiseSampler)

type EmitOptions = LocomotionNoiseSampler.EmitOptions

export type Deps = {
	inRun: () -> boolean,
	now: () -> number, -- seconds (server time in the live service)
	-- Where `player` crunches `volume`: their root, or nil when they have no living character.
	positionOf: (player: Player, volume: BasePart) -> Vector3?,
	emit: (position: Vector3, kind: Enums.NoiseKind, options: EmitOptions) -> (),
	playCue: (preset: string, position: Vector3) -> (),
}

export type Debris = {
	-- ZoneService.VolumeEntered handler. Returns true when this entry crunched.
	onVolumeEntered: (player: Player, volume: BasePart, tag: string) -> boolean,
	-- Drops `player`'s cooldowns (they left).
	forget: (player: Player) -> (),
	-- Drops every cooldown (run start / end).
	reset: () -> (),
}

local KIND: Enums.NoiseKind = "FloorDebris"
local PRESET = "GlassCrunch"

local DebrisNoise = {}

DebrisNoise.Cooldown = 2
DebrisNoise.Kind = KIND
DebrisNoise.Preset = PRESET

local function levelOf(volume: BasePart): Enums.LevelId?
	local value = volume:GetAttribute(Attributes.World.LevelId)
	if type(value) == "string" and Enums.has(Enums.LevelId, value) then
		return (value :: any) :: Enums.LevelId
	end
	return nil
end

function DebrisNoise.new(deps: Deps, cooldown: number?): Debris
	local rest = cooldown or DebrisNoise.Cooldown
	local lastCrunch: { [Player]: { [BasePart]: number } } = {}

	local function onVolumeEntered(player: Player, volume: BasePart, tag: string): boolean
		if tag ~= Tags.FloorDebris or not deps.inRun() then
			return false
		end
		local now = deps.now()
		local perVolume = lastCrunch[player]
		local previous = perVolume and perVolume[volume]
		if previous ~= nil and now - previous < rest then
			return false
		end
		local position = deps.positionOf(player, volume)
		if position == nil then
			return false
		end
		if not perVolume then
			perVolume = {}
			lastCrunch[player] = perVolume
		end
		perVolume[volume] = now
		deps.emit(position, KIND, { sourcePlayer = player, levelId = levelOf(volume) })
		deps.playCue(PRESET, position)
		return true
	end

	local debris: Debris = {
		onVolumeEntered = onVolumeEntered,
		forget = function(player: Player)
			lastCrunch[player] = nil
		end,
		reset = function()
			table.clear(lastCrunch)
		end,
	}
	return debris
end

return table.freeze(DebrisNoise)
