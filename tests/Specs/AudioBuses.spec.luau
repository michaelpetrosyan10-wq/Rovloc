--!strict
-- The client mixer. Every Enums.AcousticPreset has a complete environment for the fixed chain, with values in the
-- documented ranges; the SoundGroup tree builds (Master > the five buses) and every environment applies onto it
-- (the Lune harness checks each class and property name against the reflection database); neutral slots are
-- bypassed; volumes are clamped and unknown buses ignored.

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

local function chainOf(tree: AudioBuses.Tree, bus: Enums.AudioBus): { SoundEffect }
	return tree.chains[bus]
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
		end
	end,

	["the tree is Master over the five buses"] = function(t: Expect)
		local tree = scratchTree()
		t.eq(tree.master.Name, "Master")
		t.truthy(tree.master:IsA("SoundGroup"))
		t.truthy(tree.masterCompressor:IsA("CompressorSoundEffect"), "master limiter")
		local groups = 0
		for _, child in tree.master:GetChildren() do
			if child:IsA("SoundGroup") then
				groups += 1
				t.truthy(Enums.has(Enums.AudioBus, child.Name), "unexpected group " .. child.Name)
			end
		end
		t.eq(groups, #Enums.AudioBus)
		for _, bus: Enums.AudioBus in Enums.AudioBus do
			local group = groupOf(tree, bus)
			t.truthy(group ~= nil and group.Parent == tree.master, bus .. " under Master")
		end
		for _, bus: Enums.AudioBus in AudioBuses.EnvironmentBuses do
			local chain = chainOf(tree, bus)
			t.eq(#chain, #AudioBuses.Chain, bus .. " chain length")
			for index, effect in chain do
				t.eq(effect.Parent, groupOf(tree, bus), bus .. " effect parent")
				t.eq(effect.Name, AudioBuses.Chain[index], bus .. " effect order")
				if index > 1 then
					t.truthy(chain[index - 1].Priority > effect.Priority, bus .. " priorities descend along the chain")
				end
			end
		end
		local ui = groupOf(tree, "UI")
		t.truthy(ui ~= nil and #ui:GetChildren() == 0, "UI stays dry")
		t.eq(tree.ambienceEq.Parent, groupOf(tree, "Ambience"), "ambience EQ")
		destroy(tree)
	end,

	["every environment applies onto real effects"] = function(t: Expect)
		local tree = scratchTree()
		for _, preset: Enums.AcousticPreset in Enums.AcousticPreset do
			AudioBuses.applyEnvironment(tree, preset)
			local spec = AudioBuses.Environments[preset]
			for _, bus: Enums.AudioBus in AudioBuses.EnvironmentBuses do
				for index, effect in chainOf(tree, bus) do
					for prop, value in spec.effects[index].props do
						t.near(
							(effect :: any)[prop],
							value,
							1e-3,
							preset .. " " .. bus .. " " .. effect.Name .. "." .. prop
						)
					end
				end
			end
		end
		destroy(tree)
	end,

	["neutral slots are bypassed"] = function(t: Expect)
		local tree = scratchTree()
		AudioBuses.applyEnvironment(tree, "Room")
		local chain = chainOf(tree, "World")
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

	["the environment is remembered before the mixer exists"] = function(t: Expect)
		AudioBuses.setEnvironment("Hall", 0)
		t.eq(AudioBuses.getEnvironment(), "Hall")
		AudioBuses.setEnvironment(("Nowhere" :: any) :: Enums.AcousticPreset, 0)
		t.eq(AudioBuses.getEnvironment(), "Hall", "unknown presets ignored")
		AudioBuses.setEnvironment("Room", 0)
		t.eq(AudioBuses.getEnvironment(), "Room")
	end,
}
