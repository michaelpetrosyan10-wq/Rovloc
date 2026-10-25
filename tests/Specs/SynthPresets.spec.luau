--!strict
-- Synthesis data. Only the 11 verified engine files are used; every preset the spec and architecture name exists;
-- every layer references a known sample with a region inside its (conservative) length; every effect kind is a
-- real SoundEffect class whose properties instantiate here (the Lune harness checks property names against the
-- reflection database) with values inside the documented ranges; every surface has walk + sprint footsteps; every
-- layout's ambience is a looped 2D bed; regions are resolved safely against measured lengths.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local SoundLibrary = require(ReplicatedStorage.Shared.Audio.SoundLibrary)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local Strings = require(ReplicatedStorage.Shared.Strings)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)

type Expect = SpecRunner.Expect

local VERIFIED_FILES = {
	"action_falling.ogg",
	"action_footsteps_plastic.mp3",
	"action_get_up.mp3",
	"action_jump.mp3",
	"action_jump_land.mp3",
	"action_swim.mp3",
	"impact_explosion_03.mp3",
	"impact_water.mp3",
	"oof.ogg",
	"ouch.ogg",
	"volume_slider.ogg",
}

local DRONES = {
	"DroneBasement",
	"DroneHallways",
	"DroneScience",
	"DroneGym",
	"DronePool",
	"DroneRoof",
	"DroneLobby",
}

-- Creates the effect's real instance and writes every property (throws on an unknown class or property name).
local function instantiate(effect: SynthPresets.Effect): Instance
	local spec = SynthPresets.Effects[effect.kind]
	assert(spec, "unknown effect kind " .. tostring(effect.kind))
	local instance = Instance.new(spec.className :: any)
	for prop, value in effect.props do
		(instance :: any)[prop] = value
	end
	(instance :: any).Priority = 1
	(instance :: any).Enabled = true
	return instance
end

local function eachLayer(fn: (name: string, index: number, layer: SynthPresets.Layer) -> ())
	for _, name in SynthPresets.names() do
		local preset = SynthPresets.get(name)
		assert(preset, name)
		for index, layer in preset.layers do
			fn(name, index, layer)
		end
	end
end

return {
	["only the 11 verified rbxasset://sounds files are catalogued"] = function(t: Expect)
		local count = 0
		for key, sample in SoundLibrary.Samples do
			count += 1
			t.eq(sample.id, key, "sample id matches its key")
			t.eq(string.sub(sample.path, 1, 18), "rbxasset://sounds/", key .. " path root")
			local file = string.sub(sample.path, 19)
			t.truthy(table.find(VERIFIED_FILES, file) ~= nil, key .. " uses an unverified file " .. file)
			t.truthy(sample.duration > 0 and sample.duration < 10, key .. " duration estimate is sane")
			t.truthy(#sample.character > 0, key .. " has a character description")
		end
		t.eq(count, #VERIFIED_FILES, "exactly the verified files")
	end,

	["preset data validates cleanly"] = function(t: Expect)
		local problems = SynthPresets.validate()
		if #problems > 0 then
			t.fail(#problems .. " problem(s): " .. table.concat(problems, " | "))
		end
	end,

	["every required preset exists"] = function(t: Expect)
		for _, name in SynthPresets.Required do
			t.truthy(SynthPresets.has(name), "missing preset " .. name)
		end
		for _, name in DRONES do
			t.truthy(table.find(SynthPresets.Required, name) ~= nil, name .. " is required")
		end
	end,

	["every layer references a known sample with a region inside it"] = function(t: Expect)
		eachLayer(function(name: string, index: number, layer: SynthPresets.Layer)
			local where = name .. "[" .. index .. "]"
			local sample = SoundLibrary.get(layer.sample)
			t.truthy(sample ~= nil, where .. " unknown sample " .. layer.sample)
			if not sample then
				return
			end
			local region = layer.region
			if region then
				t.truthy(region.min >= 0 and region.max <= sample.duration, where .. " region outside the sample")
				t.truthy(region.max - region.min >= SoundLibrary.MinRegion, where .. " region too short")
			end
		end)
	end,

	["every effect kind is a real SoundEffect class with real properties"] = function(t: Expect)
		for _, kind: SynthPresets.EffectKind in SynthPresets.EffectKinds do
			local spec = SynthPresets.Effects[kind]
			t.truthy(spec ~= nil, "no metadata for " .. kind)
			local instance = Instance.new(spec.className :: any)
			t.truthy(instance:IsA("SoundEffect"), spec.className .. " is a SoundEffect")
			for prop, range in spec.props do
				t.truthy(range.min <= range.max, kind .. "." .. prop .. " range ordered")
				local default = spec.defaults[prop]
				t.truthy(default ~= nil, kind .. "." .. prop .. " has a default"); -- Each write is checked against the reflection database by the harness.
				(instance :: any)[prop] = range.min;
				(instance :: any)[prop] = range.max;
				(instance :: any)[prop] = default
			end
			for prop in spec.defaults do
				t.truthy(spec.props[prop] ~= nil, kind .. " default for undriven property " .. prop)
			end
			instance:Destroy()
		end
	end,

	["every recipe effect instantiates with in-range values"] = function(t: Expect)
		local effects = 0
		eachLayer(function(name: string, index: number, layer: SynthPresets.Layer)
			for effectIndex, effect in (layer.effects or {}) :: { SynthPresets.Effect } do
				local where = string.format("%s[%d].effects[%d]", name, index, effectIndex)
				local problems = SynthPresets.validateEffect(effect, where)
				t.eq(#problems, 0, table.concat(problems, " | "))
				local ok, err = pcall(instantiate, effect)
				t.truthy(ok, where .. " failed to instantiate: " .. tostring(err))
				if ok then
					(err :: Instance):Destroy()
				end
				effects += 1
			end
		end)
		t.truthy(effects > 100, "the recipes actually use DSP")
	end,

	["every surface has walk and sprint footsteps"] = function(t: Expect)
		for _, surface: Enums.SurfaceKind in Enums.SurfaceKind do
			local walk = SynthPresets.footstep(surface, false)
			local sprint = SynthPresets.footstep(surface, true)
			t.eq(walk, "Footstep" .. surface)
			t.eq(sprint, "FootstepSprint" .. surface)
			local walkPreset = SynthPresets.get(walk)
			local sprintPreset = SynthPresets.get(sprint)
			t.truthy(walkPreset ~= nil and sprintPreset ~= nil, surface .. " footsteps exist")
			if walkPreset and sprintPreset then
				t.eq(walkPreset.bus, "Player", walk .. " bus")
				t.truthy(
					SynthPresets.rollOff(sprintPreset).max > SynthPresets.rollOff(walkPreset).max,
					"sprint carries further"
				)
				t.falsy(SynthPresets.isLooped(walk), walk .. " is a one-shot")
			end
		end
		t.eq(SynthPresets.footstep("Lava", false), "FootstepConcrete", "unknown surfaces fall back to concrete")
	end,

	["every layout ambience is a looped 2D bed"] = function(t: Expect)
		local layouts = ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts
		local seen: { [string]: boolean } = {}
		for _, id: Enums.LayoutId in Enums.LayoutId do
			local module = layouts:FindFirstChild(id)
			t.truthy(module ~= nil and module:IsA("ModuleScript"), "layout module " .. id)
			if not (module and module:IsA("ModuleScript")) then
				continue
			end
			local layout = require(module) :: any
			local ambience = layout.ambience
			t.truthy(type(ambience) == "string", id .. " declares an ambience")
			t.truthy(SynthPresets.has(ambience), id .. " ambience " .. tostring(ambience) .. " is a preset")
			seen[ambience] = true
		end
		for _, name in DRONES do
			local preset = SynthPresets.get(name)
			t.truthy(preset ~= nil, name .. " exists")
			if preset then
				t.eq(preset.bus, "Ambience", name .. " bus")
				t.truthy(SynthPresets.isLooped(name), name .. " loops")
				t.truthy(preset.rollOff == nil, name .. " is 2D")
				t.truthy(SynthPresets.Beds[name] ~= nil, name .. " has stingers")
			end
		end
		for name in seen do
			t.truthy(table.find(DRONES, name) ~= nil, "layout ambience " .. name .. " is one of the Drone beds")
		end
	end,

	["captions are real Strings keys"] = function(t: Expect)
		local captioned = 0
		for _, name in SynthPresets.names() do
			local preset = SynthPresets.get(name)
			local caption = if preset then preset.caption else nil
			if caption then
				captioned += 1
				t.truthy(Strings.has(caption), name .. " caption " .. caption)
			end
		end
		t.truthy(captioned >= 10, "the important sounds are captioned")
		for _, name in { "Screech", "Heartbeat", "VentScrape", "TrapSnap", "GlassCrunch", "GateSlam", "Gasp" } do
			local preset = SynthPresets.get(name)
			t.truthy(preset ~= nil and preset.caption ~= nil, name .. " is captioned")
		end
	end,

	["pulses and loops are declared where they belong"] = function(t: Expect)
		for _, name in { "Heartbeat", "HeartbeatFast", "Breathing", "BreathingPanic", "VentScrape", "VentBreathing" } do
			local preset = SynthPresets.get(name)
			t.truthy(preset ~= nil and preset["repeat"] ~= nil, name .. " pulses")
			t.truthy(SynthPresets.isLooped(name), name .. " runs until stopped")
		end
		for _, name in { "Screech", "TrapSnap", "GlassCrunch", "Drip", "GateSlam", "Thunder", "MetalCrash", "Lunge" } do
			t.falsy(SynthPresets.isLooped(name), name .. " is a one-shot")
		end
		local drip = SynthPresets.get("Drip")
		t.truthy(drip ~= nil and drip["repeat"] ~= nil, "Drip knows how to repeat when an emitter loops it")
		t.truthy(SynthPresets.isLooped("FluorescentBuzz") and SynthPresets.isLooped("BoilerHum"), "emitter beds loop")
	end,

	["the screech is built from the cry pitched up hard"] = function(t: Expect)
		local preset = SynthPresets.get("Screech")
		assert(preset, "Screech")
		local shriek = preset.layers[1]
		t.eq(shriek.sample, "Ouch")
		local speed = shriek.speed
		local minSpeed = if type(speed) == "number" then speed else speed.min
		t.truthy(minSpeed >= 2, "pitched up hard")
		local kinds: { [string]: boolean } = {}
		for _, layer in preset.layers do
			for _, effect in (layer.effects or {}) :: { SynthPresets.Effect } do
				kinds[effect.kind] = true
			end
		end
		for _, kind in { "PitchShift", "Distortion", "Tremolo", "Echo", "Flanger" } do
			t.truthy(kinds[kind], "Screech uses " .. kind)
		end
		t.eq(preset.bus, "Monster")
		t.eq(preset.priority, 100, "nothing outranks the screech")
	end,

	["regions resolve inside the real file"] = function(t: Expect)
		SoundLibrary.resetMeasurements()
		local estimate = SoundLibrary.length("Explosion")
		local a, b = SoundLibrary.resolveRegion("Explosion", 0.2, 1.6)
		t.near(a, 0.2, 1e-6, "unmeasured: as authored")
		t.near(b, 1.6, 1e-6, "unmeasured: as authored")
		a, b = SoundLibrary.resolveRegion("Explosion", -1, estimate + 5)
		t.truthy(a >= 0 and b <= estimate, "clamped to the estimate")

		-- Shorter than estimated: the slice is remapped proportionally into the real length.
		SoundLibrary.recordLength("Explosion", 0.9)
		t.truthy(SoundLibrary.isMeasured("Explosion"))
		t.near(SoundLibrary.length("Explosion"), 0.9, 1e-6)
		a, b = SoundLibrary.resolveRegion("Explosion", 0.2, 1.6)
		t.truthy(a >= 0 and b <= 0.9 and b - a >= SoundLibrary.MinRegion, "remapped inside the measured length")
		t.near(a / b, 0.2 / 1.6, 1e-3, "keeps the same part of the file")

		-- Longer than estimated: authored regions already fit and are kept.
		SoundLibrary.recordLength("Explosion", 4)
		a, b = SoundLibrary.resolveRegion("Explosion", 0.2, 1.6)
		t.near(a, 0.2, 1e-6)
		t.near(b, 1.6, 1e-6)

		-- Nonsense measurements are ignored.
		SoundLibrary.recordLength("Explosion", 0 / 0)
		SoundLibrary.recordLength("Explosion", -3)
		SoundLibrary.recordLength("NotASample", 2)
		t.near(SoundLibrary.length("Explosion"), 4, 1e-6)
		t.falsy(SoundLibrary.isMeasured("NotASample"))

		-- Degenerate slices still come back playable.
		a, b = SoundLibrary.resolveRegion("VolumeSlider", 0.05, 0.05)
		t.truthy(b - a >= SoundLibrary.MinRegion and a >= 0, "never an empty region")
		SoundLibrary.resetMeasurements()
		t.falsy(SoundLibrary.isMeasured("Explosion"))
	end,
}
