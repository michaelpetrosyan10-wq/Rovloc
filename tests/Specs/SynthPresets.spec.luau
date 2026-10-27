--!strict
-- Synthesis data. Only the 11 verified engine files are used; every preset the spec and architecture name exists;
-- every layer references a known sample with a region inside its (conservative) length; every effect kind is a
-- real SoundEffect class whose properties instantiate here (the Lune harness checks property names against the
-- reflection database) with values inside the documented ranges; every surface has walk + sprint footsteps; every
-- layout's ambience is a looped 2D bed; regions are resolved safely against measured lengths. Rules that keep the
-- recipes honest on a phone: grain clusters are spaced for 30 fps (sub-frame density comes from echoes), beds loop
-- seamlessly and never loop the explosion, reverbs per preset are capped, chain tails are computed for the effect
-- groups that hold them. The body's own sounds sit on the Body bus; the stock avatar voice is never recognisable;
-- drip emitters and drip stingers are separate presets; the scrape, the trap and the drip are built to ring.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local AudioController = require(StarterPlayer.StarterPlayerScripts.Controllers.Core.AudioController)
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

local BODY = { "Heartbeat", "HeartbeatFast", "Breathing", "BreathingPanic", "EmfStatic" }

local function speedBounds(speed: number | SynthPresets.Range): (number, number)
	if type(speed) == "number" then
		return speed, speed
	end
	return speed.min, speed.max
end

local function hasEffect(layer: SynthPresets.Layer, kind: SynthPresets.EffectKind): SynthPresets.Effect?
	for _, effect in (layer.effects or {}) :: { SynthPresets.Effect } do
		if effect.kind == kind then
			return effect
		end
	end
	return nil
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

	["names() lists every preset once, sorted"] = function(t: Expect)
		local names = SynthPresets.names()
		local count = 0
		for _ in SynthPresets.Presets do
			count += 1
		end
		t.eq(#names, count, "every preset is listed")
		for index = 2, #names do
			t.truthy(names[index - 1] < names[index], "sorted and unique at " .. names[index])
		end
		for _, name in SynthPresets.Required do
			t.truthy(table.find(names, name) ~= nil, name .. " can be auditioned")
		end
	end,

	["chain tails cover reverbs, echoes and modulation"] = function(t: Expect)
		t.eq(SynthPresets.chainTail(nil), 0)
		t.eq(SynthPresets.chainTail({}), 0)
		local reverb: SynthPresets.Effect =
			{ kind = "Reverb", props = { DecayTime = 3.5, WetLevel = -2, DryLevel = 0, Density = 1, Diffusion = 1 } }
		t.near(SynthPresets.chainTail({ reverb }), 3.5, 1e-6, "a reverb rings for its decay time")
		local dryEcho: SynthPresets.Effect =
			{ kind = "Echo", props = { Delay = 0.2, Feedback = 0, WetLevel = 0, DryLevel = 0 } }
		t.near(SynthPresets.chainTail({ dryEcho }), 0.2, 1e-6, "one repeat without feedback")
		local ringing: SynthPresets.Effect =
			{ kind = "Echo", props = { Delay = 0.1, Feedback = 0.5, WetLevel = 0, DryLevel = 0 } }
		local tail = SynthPresets.chainTail({ ringing })
		t.truthy(tail > 0.9 and tail < 1.1, "feedback 0.5 repeats ~10 times to -60 dB, got " .. tail)
		local chorus: SynthPresets.Effect = { kind = "Chorus", props = { Rate = 1, Depth = 0.5, Mix = 0.5 } }
		t.truthy(SynthPresets.chainTail({ chorus }) > 0, "modulation has a short tail")
		t.near(SynthPresets.chainTail({ reverb, dryEcho }), 3.7, 1e-6, "tails in series add")
		local endless: SynthPresets.Effect =
			{ kind = "Echo", props = { Delay = 2, Feedback = 1, WetLevel = 0, DryLevel = 0 } }
		t.eq(SynthPresets.chainTail({ endless }), SynthPresets.MaxTail, "capped")
	end,

	["grain clusters are spaced for 30 fps and fit the budget"] = function(t: Expect)
		eachLayer(function(name: string, index: number, layer: SynthPresets.Layer)
			local grainSpec = layer.grains
			if grainSpec then
				local where = name .. "[" .. index .. "]"
				t.truthy(grainSpec.spacing.min >= SynthPresets.MinGrainSpacing, where .. " grains closer than a frame")
				t.truthy(grainSpec.count.max <= SynthPresets.MaxGrainCount, where .. " too many grains per trigger")
			end
		end)
		for _, name in SynthPresets.names() do
			local preset = SynthPresets.get(name)
			assert(preset, name)
			t.truthy(
				SynthPresets.reverbCount(preset) <= SynthPresets.MaxPresetReverbs,
				name .. " uses too many reverbs"
			)
		end
		t.truthy(SynthPresets.MinGrainSpacing >= 1 / 40, "a 30 fps frame fits about one grain")
	end,

	["beds loop seamlessly and never loop the explosion"] = function(t: Expect)
		local beds = 0
		eachLayer(function(name: string, index: number, layer: SynthPresets.Layer)
			if not SynthPresets.isBedLayer(layer) then
				return
			end
			beds += 1
			local where = name .. "[" .. index .. "]"
			t.truthy(layer.sample ~= "Explosion", where .. " loops the explosion")
			local region = layer.region
			if region == nil then
				t.truthy(SoundLibrary.isSeamless(layer.sample), where .. " loops a file that has a seam")
			else
				t.truthy(region.max - region.min <= SynthPresets.MaxToneRegion, where .. " loops a long region")
			end
		end)
		t.truthy(beds > 30, "the beds were checked")
		for _, key in { "Falling", "Swim", "FootstepsPlastic" } do
			t.truthy(SoundLibrary.isSeamless(key), key .. " is an engine loop")
		end
		t.falsy(SoundLibrary.isSeamless("Explosion"), "the explosion is a one-shot file")
		for _, name in DRONES do
			local preset = SynthPresets.get(name)
			assert(preset, name)
			for index, layer in preset.layers do
				t.truthy(layer.sample ~= "Explosion", name .. "[" .. index .. "] uses the explosion in the bed")
			end
			t.truthy(SynthPresets.reverbCount(preset) <= 1, name .. " has one room, not a reverb per layer")
		end
		local rumble = 0
		for _, stingers in SynthPresets.Beds do
			for _, entry in stingers do
				if entry.preset == "FarRumble" then
					rumble += 1
					t.truthy(entry.interval.min >= 20, "the far rumble is sparse")
				end
			end
		end
		t.truthy(rumble >= 5, "the explosion survives as a far rumble stinger")
		t.falsy(SynthPresets.isLooped("FarRumble"), "and only as a one-shot")
	end,

	["the body's own sounds play on the Body bus"] = function(t: Expect)
		for _, name in BODY do
			local preset = SynthPresets.get(name)
			t.truthy(preset ~= nil and preset.bus == "Body", name .. " is on the Body bus")
			t.truthy(preset ~= nil and preset.rollOff == nil, name .. " is 2D")
		end
		local gasp = SynthPresets.get("Gasp")
		t.truthy(gasp ~= nil and gasp.bus == "Player", "a gasp is heard by others in the room")
		local bodyBus: Enums.AudioBus = "Body"
		t.truthy(SynthPresets.DefaultRollOff[bodyBus] ~= nil, "Body has a default roll-off")
	end,

	["the stock avatar voice is never recognisable"] = function(t: Expect)
		for _, name in { "Gasp", "BreathingPanic", "Breathing" } do
			local preset = SynthPresets.get(name)
			assert(preset, name)
			for index, layer in preset.layers do
				t.truthy(
					layer.sample ~= "Oof" and layer.sample ~= "Ouch",
					name .. "[" .. index .. "] uses a stock voice"
				)
			end
		end
		eachLayer(function(name: string, index: number, layer: SynthPresets.Layer)
			if layer.sample ~= "Oof" and layer.sample ~= "Ouch" then
				return
			end
			local where = name .. "[" .. index .. "]"
			local low, high = speedBounds(layer.speed)
			t.truthy(high <= 0.7 or low >= 1.8, where .. " plays a stock voice near its natural pitch")
			t.truthy(
				hasEffect(layer, "PitchShift") ~= nil or hasEffect(layer, "Distortion") ~= nil,
				where .. " leaves a stock voice undisguised"
			)
		end)
	end,

	["drip emitters and drip stingers are separate presets"] = function(t: Expect)
		for bed, stingers in SynthPresets.Beds do
			for _, entry in stingers do
				t.truthy(entry.preset ~= "Drip", bed .. " stingers must use DripStinger, not the emitter preset")
			end
		end
		local drip = SynthPresets.get("Drip")
		local stinger = SynthPresets.get("DripStinger")
		assert(drip and stinger, "drip presets")
		t.truthy(drip.maxVoices > AudioController.MaxEmitterVoices, "every pipe emitter fits under Drip's own cap")
		t.falsy(SynthPresets.isLooped("DripStinger"), "a stinger is a one-shot")
	end,

	["the scrape, the trap and the drip are built to ring"] = function(t: Expect)
		local scrape = SynthPresets.get("VentScrape")
		assert(scrape, "VentScrape")
		local comb = false
		for _, layer in scrape.layers do
			local echo = hasEffect(layer, "Echo")
			if echo and layer.looped and layer.duration ~= nil then
				if echo.props.Delay <= 0.016 and echo.props.Feedback >= 0.7 then
					comb = true
				end
			end
			if layer.sample == "FootstepsPlastic" then
				local low = speedBounds(layer.speed)
				t.truthy(low >= 1.5, "claws are bright clicks, not slowed knocks")
			end
		end
		t.truthy(comb, "the scrape runs through a tight resonant comb")

		local trap = SynthPresets.get("TrapSnap")
		assert(trap, "TrapSnap")
		local ring = false
		for _, layer in trap.layers do
			local region = layer.region
			if layer.looped and layer.duration and region and region.max - region.min <= SynthPresets.MaxToneRegion then
				ring = layer.duration >= 0.5
			end
		end
		t.truthy(ring, "the jaws ring as a sustained loop tone")

		local drip = SynthPresets.get("Drip")
		assert(drip, "Drip")
		local plink = drip.layers[1]
		local region = plink.region
		t.truthy(plink.looped and region ~= nil and region.max - region.min <= 0.01, "the drop is a pitched plink")
		local glideSpec = plink.glide
		t.truthy(glideSpec ~= nil and glideSpec.to > 1, "its pitch rises")
		t.truthy(SynthPresets.chainTail(plink.effects) > 0.5, "and it rings on after the drop")
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
