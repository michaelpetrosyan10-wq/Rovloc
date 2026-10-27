--!strict
-- The client mixer. Every Enums.AcousticPreset has a complete environment for the fixed chain plus the Ambience and
-- Body EQs, with values in the documented ranges; the SoundGroup tree builds (Master > Ambience, Room, Body, UI;
-- Room > World, Monster, Player, with the one environment chain on Room) and every environment applies onto it (the
-- Lune harness checks each class and property name against the reflection database); the Body bus only ever gets an
-- EQ (a heartbeat never picks up room reverb) yet is muffled underwater and in ducts; neutral slots are bypassed;
-- echo delays never jump while their echo is audible; volumes are clamped, unknown buses ignored, and Body follows
-- the Player volume until it is set on its own.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AudioBuses = require(ReplicatedStorage.Shared.Audio.AudioBuses)
local Enums = require(ReplicatedStorage.Shared.Enums)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)

type Expect = SpecRunner.Expect

local function scratchTree(): AudioBuses.Tree
	local folder = Instance.new("Folder")
	folder.Name = "AudioBusesSpec"
	return AudioBuses.build(folder)
end

-- Indexers keyed by singleton unions only accept typed keys, so specs go through these.
local function groupOf(tree: AudioBuses.Tree, bus: Enums.AudioBus): SoundGroup?
	return tree.groups[bus]
end

local function envOf(preset: Enums.AcousticPreset): AudioBuses.EnvironmentSpec
	return AudioBuses.Environments[preset]
end

local function destroy(tree: AudioBuses.Tree)
	local parent = tree.master.Parent
	if parent then
		parent:Destroy()
	end
end

return {
	["every acoustic preset has a complete environment"] = function(t: Expect)
		for _, preset: Enums.AcousticPreset in Enums.AcousticPreset do
			local spec = AudioBuses.Environments[preset]
			t.truthy(spec ~= nil, "no environment for " .. preset)
			if not spec then
				continue
			end
			t.eq(#spec.effects, #AudioBuses.Chain, preset .. " fills every chain slot")
			for index, kind: SynthPresets.EffectKind in AudioBuses.Chain do
				local effect = spec.effects[index]
				t.eq(effect.kind, kind, preset .. " slot " .. index)
				local meta = SynthPresets.Effects[kind]
				for prop in meta.props do
					t.truthy(effect.props[prop] ~= nil, preset .. " sets " .. kind .. "." .. prop)
				end
			end
			t.eq(spec.ambience.kind, "Equalizer", preset .. " ambience EQ")
			t.eq(spec.body.kind, "Equalizer", preset .. " body EQ")
			t.truthy(spec.gain > 0 and spec.gain <= 1, preset .. " gain")
		end
	end,

	["environment values lie inside the documented ranges"] = function(t: Expect)
		for _, preset: Enums.AcousticPreset in Enums.AcousticPreset do
			local spec = AudioBuses.Environments[preset]
			for index, effect in spec.effects do
				local problems = SynthPresets.validateEffect(effect, preset .. "[" .. index .. "]")
				t.eq(#problems, 0, table.concat(problems, " | "))
			end
			local problems = SynthPresets.validateEffect(spec.ambience, preset .. ".ambience")
			t.eq(#problems, 0, table.concat(problems, " | "))
			local bodyProblems = SynthPresets.validateEffect(spec.body, preset .. ".body")
			t.eq(#bodyProblems, 0, table.concat(bodyProblems, " | "))
		end
	end,

	["the tree is Master over Ambience, Room (World, Monster, Player), Body and UI"] = function(t: Expect)
		local tree = scratchTree()
		t.eq(tree.master.Name, "Master")
		t.truthy(tree.master:IsA("SoundGroup"))
		t.truthy(tree.masterCompressor:IsA("CompressorSoundEffect"), "master limiter")
		t.eq(tree.room.Parent, tree.master, "Room under Master")
		local routed = { World = true, Monster = true, Player = true }
		local seen = 0
		for _, bus: Enums.AudioBus in Enums.AudioBus do
			local group = groupOf(tree, bus)
			t.truthy(group ~= nil, bus .. " exists")
			if not group then
				continue
			end
			seen += 1
			t.eq(group.Name, bus)
			if routed[bus] then
				t.eq(group.Parent, tree.room, bus .. " routes through the room chain")
				t.eq(#group:GetChildren(), 0, bus .. " carries no chain of its own")
			else
				t.eq(group.Parent, tree.master, bus .. " under Master")
			end
		end
		t.eq(seen, #Enums.AudioBus)
		for _, bus: Enums.AudioBus in AudioBuses.EnvironmentBuses do
			t.truthy(routed[bus], bus .. " is an environment bus")
		end
		t.eq(#tree.chain, #AudioBuses.Chain, "chain length")
		for index, effect in tree.chain do
			t.eq(effect.Parent, tree.room, "chain on Room")
			t.eq(effect.Name, AudioBuses.Chain[index], "chain order")
			if index > 1 then
				t.truthy(tree.chain[index - 1].Priority > effect.Priority, "priorities descend along the chain")
			end
		end
		local ui = groupOf(tree, "UI")
		t.truthy(ui ~= nil and #ui:GetChildren() == 0, "UI stays dry")
		t.eq(tree.ambienceEq.Parent, groupOf(tree, "Ambience"), "ambience EQ")
		local body = groupOf(tree, "Body")
		t.eq(tree.bodyEq.Parent, body, "body EQ")
		t.truthy(body ~= nil and #body:GetChildren() == 1, "the Body bus has only its EQ (no reverb, no echo)")
		destroy(tree)
	end,

	["every environment applies onto real effects"] = function(t: Expect)
		local tree = scratchTree()
		for _, preset: Enums.AcousticPreset in Enums.AcousticPreset do
			AudioBuses.applyEnvironment(tree, preset)
			local spec = AudioBuses.Environments[preset]
			for index, effect in tree.chain do
				for prop, value in spec.effects[index].props do
					t.near((effect :: any)[prop], value, 1e-3, preset .. " " .. effect.Name .. "." .. prop)
				end
			end
			for prop, value in spec.body.props do
				t.near((tree.bodyEq :: any)[prop], value, 1e-3, preset .. " body " .. prop)
			end
		end
		destroy(tree)
	end,

	["body sounds are muffled underwater and in ducts but never reverberate"] = function(t: Expect)
		local tree = scratchTree()
		AudioBuses.applyEnvironment(tree, "Basement")
		t.falsy(tree.bodyEq.Enabled, "the basement's long reverb does not touch the body")
		AudioBuses.applyEnvironment(tree, "Underwater")
		t.truthy(tree.bodyEq.Enabled and tree.bodyEq.HighGain < -10, "underwater dulls the heartbeat")
		AudioBuses.applyEnvironment(tree, "Vent")
		t.truthy(tree.bodyEq.Enabled, "boxed in inside a duct")
		destroy(tree)
	end,

	["neutral slots are bypassed"] = function(t: Expect)
		local tree = scratchTree()
		AudioBuses.applyEnvironment(tree, "Room")
		local chain = tree.chain
		t.falsy(chain[1].Enabled, "flat EQ bypassed in a room")
		t.falsy(chain[2].Enabled, "no chorus in a room")
		t.truthy(chain[3].Enabled, "room reverb on")
		t.falsy(chain[4].Enabled, "no echo in a room")
		t.falsy(tree.ambienceEq.Enabled, "ambience untouched in a room")

		AudioBuses.applyEnvironment(tree, "Underwater")
		t.truthy(chain[1].Enabled, "underwater low-pass on")
		t.truthy(chain[2].Enabled, "underwater wobble on")
		t.truthy(tree.ambienceEq.Enabled, "ambience muffled underwater")
		local eq = chain[1] :: EqualizerSoundEffect
		t.truthy(eq.HighGain <= -40, "underwater cuts the highs hard")

		AudioBuses.applyEnvironment(tree, "Vent")
		t.truthy(chain[4].Enabled, "vents ring with a tight echo")
		local echo = chain[4] :: EchoSoundEffect
		t.truthy(echo.Delay < 0.06, "tight comb delay in the duct")
		destroy(tree)
	end,

	["acoustic character matches the spaces"] = function(t: Expect)
		local function decay(preset: Enums.AcousticPreset): number
			return envOf(preset).effects[3].props.DecayTime
		end
		t.truthy(decay("Hall") > decay("Corridor") and decay("Corridor") > decay("Room"), "halls ring longest")
		t.truthy(decay("Basement") > decay("Room"), "concrete basement rings")
		t.truthy(envOf("Outdoor").effects[3].props.WetLevel <= -24, "outdoors is nearly dry")
		t.truthy(envOf("Stairwell").effects[4].props.WetLevel > -80, "stairwells slap back")
		t.truthy(envOf("Underwater").gain < 1, "underwater is quieter")
	end,

	["echo delays never jump while the echo is audible"] = function(t: Expect)
		local corridor = envOf("Corridor").effects[4].props
		local room = envOf("Room").effects[4].props
		local stairwell = envOf("Stairwell").effects[4].props
		-- Leaving an audible echo for a silent one: hold the old delay until the fade is over.
		t.eq(AudioBuses.fadeDelay(corridor, room, 0), corridor.Delay, "corridor -> room starts on the old delay")
		t.eq(AudioBuses.fadeDelay(corridor, room, 0.99), corridor.Delay, "and keeps it while the wet fades")
		t.eq(AudioBuses.fadeDelay(corridor, room, 1), room.Delay, "switches once silent")
		-- Entering an echo from silence: jump at once (nothing is ringing in the line yet).
		t.eq(AudioBuses.fadeDelay(room, corridor, 0), corridor.Delay, "room -> corridor jumps immediately")
		-- Between two audible echoes the delay jumps at the start (no pitch-smearing sweep).
		t.eq(AudioBuses.fadeDelay(corridor, stairwell, 0), stairwell.Delay)
	end,

	["volumes clamp and unknown buses are ignored"] = function(t: Expect)
		AudioBuses.setVolume("World", 5)
		t.eq(AudioBuses.getVolume("World"), 2, "clamped to 2")
		AudioBuses.setVolume("World", -1)
		t.eq(AudioBuses.getVolume("World"), 0, "clamped to 0")
		AudioBuses.setVolume("World", 0 / 0)
		t.eq(AudioBuses.getVolume("World"), 0, "NaN ignored")
		AudioBuses.setVolume("Master", 0.5)
		t.eq(AudioBuses.getVolume("Master"), 0.5)
		AudioBuses.setVolume(("Nope" :: any) :: AudioBuses.BusName, 1)
		t.eq(AudioBuses.getVolume(("Nope" :: any) :: AudioBuses.BusName), 1, "unknown bus untouched")
		AudioBuses.setVolume("World", 1)
		AudioBuses.setVolume("Master", 1)
	end,

	["the body bus follows the player volume"] = function(t: Expect)
		AudioBuses.setVolume("Player", 0.4)
		t.eq(AudioBuses.getVolume("Body"), 0.4, "Body follows Player")
		AudioBuses.setVolume("Player", 1)
		t.eq(AudioBuses.getVolume("Body"), 1)
	end,

	["the environment is remembered before the mixer exists"] = function(t: Expect)
		AudioBuses.setEnvironment("Hall", 0)
		t.eq(AudioBuses.getEnvironment(), "Hall")
		AudioBuses.setEnvironment(("Nowhere" :: any) :: Enums.AcousticPreset, 0)
		t.eq(AudioBuses.getEnvironment(), "Hall", "unknown presets ignored")
		AudioBuses.setEnvironment("Room", 0)
		t.eq(AudioBuses.getEnvironment(), "Room")
	end,
}
