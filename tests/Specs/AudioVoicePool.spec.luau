--!strict
-- Voice budget rules: bus caps from the brief, priority stealing (lowest priority, then quietest, then oldest),
-- outranked newcomers refused, per-preset caps replacing the least audible instance, and the distance pre-cull.
-- Slots are driven with fake callbacks, so no Sound is ever created.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local VoicePool = require(ReplicatedStorage.Shared.Audio.VoicePool)

type Expect = SpecRunner.Expect

type Fake = { slot: VoicePool.Slot?, stolen: boolean }

local function cap(bus: Enums.AudioBus): number
	return VoicePool.Caps[bus]
end

local function candidate(priority: number, audibility: number, startedAt: number): VoicePool.Candidate
	return { priority = priority, audibility = audibility, startedAt = startedAt }
end

local function admit(
	bus: Enums.AudioBus,
	preset: string,
	priority: number,
	maxVoices: number,
	gain: number,
	position: Vector3?,
	rollOff: SynthPresets.Range?
): Fake
	local fake: Fake = { slot = nil, stolen = false }
	fake.slot = VoicePool.admit({
		bus = bus,
		preset = preset,
		priority = priority,
		maxVoices = maxVoices,
		rollOff = rollOff,
		position = function(): Vector3?
			return position
		end,
		gain = function(): number
			return gain
		end,
		steal = function()
			fake.stolen = true
		end,
		cull = true,
	})
	return fake
end

local function releaseAll(fakes: { Fake })
	for _, fake in fakes do
		local slot = fake.slot
		if slot then
			VoicePool.release(slot)
		end
	end
end

return {
	["bus caps match the brief"] = function(t: Expect)
		t.eq(cap("Monster"), 6)
		t.eq(cap("World"), 16)
		t.eq(cap("Ambience"), 8)
		t.eq(cap("Player"), 12)
		t.eq(cap("UI"), 6)
		for _, bus: Enums.AudioBus in Enums.AudioBus do
			t.truthy(cap(bus) > 0, bus .. " has a cap")
		end
	end,

	["the lowest priority is stolen first"] = function(t: Expect)
		local index = VoicePool.pickVictim({
			candidate(50, 0.1, 1),
			candidate(10, 0.9, 2),
			candidate(30, 0.01, 0),
		}, 60)
		t.eq(index, 2)
	end,

	["ties go to the quietest, then the oldest"] = function(t: Expect)
		t.eq(VoicePool.pickVictim({ candidate(20, 0.8, 1), candidate(20, 0.2, 5), candidate(20, 0.5, 0) }, 20), 2)
		t.eq(VoicePool.pickVictim({ candidate(20, 0.5, 3), candidate(20, 0.5, 1), candidate(20, 0.5, 2) }, 20), 2)
	end,

	["a voice that outranks the newcomer is never stolen"] = function(t: Expect)
		t.eq(VoicePool.pickVictim({ candidate(90, 0, 0), candidate(80, 0, 0) }, 50), nil)
		t.eq(VoicePool.pickVictim({ candidate(90, 0, 0), candidate(40, 1, 9) }, 50), 2)
		t.eq(VoicePool.pickVictim({}, 100), nil)
	end,

	["attenuation is full inside min and silent at max"] = function(t: Expect)
		local rollOff: SynthPresets.Range = { min = 10, max = 100 }
		t.eq(VoicePool.attenuation(0, rollOff), 1)
		t.eq(VoicePool.attenuation(10, rollOff), 1)
		t.eq(VoicePool.attenuation(100, rollOff), 0)
		t.eq(VoicePool.attenuation(500, rollOff), 0)
		local previous = 1
		for distance = 11, 99, 4 do
			local value = VoicePool.attenuation(distance, rollOff)
			t.truthy(value < previous and value > 0, "monotonic at " .. distance)
			previous = value
		end
	end,

	["a full bus steals for a more important voice and refuses a lesser one"] = function(t: Expect)
		local held: { Fake } = {}
		for i = 1, cap("Monster") do
			table.insert(held, admit("Monster", "SpecHold" .. i, 50, 8, 0.5 + i * 0.01))
			t.truthy(held[i].slot ~= nil, "slot " .. i)
		end
		t.eq(VoicePool.activeCount("Monster"), cap("Monster"))

		local lesser = admit("Monster", "SpecLesser", 40, 8, 1)
		t.eq(lesser.slot, nil, "outranked newcomer refused")
		for _, fake in held do
			t.falsy(fake.stolen, "nothing stolen for a lesser voice")
		end

		local greater = admit("Monster", "SpecGreater", 90, 8, 1)
		t.truthy(greater.slot ~= nil, "more important voice admitted")
		t.truthy(held[1].stolen, "the quietest equal-priority voice was stolen")
		t.eq(VoicePool.activeCount("Monster"), cap("Monster"), "cap holds")

		table.insert(held, greater)
		releaseAll(held)
		t.eq(VoicePool.activeCount("Monster"), 0, "all released")
	end,

	["a preset over its own cap replaces its least audible instance"] = function(t: Expect)
		local first = admit("World", "SpecDrip", 15, 2, 0.9)
		local second = admit("World", "SpecDrip", 15, 2, 0.2)
		local third = admit("World", "SpecDrip", 15, 2, 0.6)
		t.truthy(first.slot ~= nil and second.slot ~= nil and third.slot ~= nil, "all admitted")
		t.truthy(second.stolen, "the quietest instance made room")
		t.falsy(first.stolen)
		releaseAll({ first, second, third })
		t.eq(VoicePool.activeCount("World"), 0)
	end,

	["one-shots beyond their rollOff are culled before taking a slot"] = function(t: Expect)
		local rollOff: SynthPresets.Range = { min = 5, max = 60 }
		local listener = VoicePool.listenerPosition()
		local far = admit("World", "SpecFar", 50, 4, 1, listener + Vector3.new(500, 0, 0), rollOff)
		t.eq(far.slot, nil, "culled")
		t.truthy(VoicePool.shouldCull(listener + Vector3.new(61, 0, 0), rollOff))
		t.falsy(VoicePool.shouldCull(listener + Vector3.new(30, 0, 0), rollOff))
		t.falsy(VoicePool.shouldCull(nil, rollOff), "2D is never culled")
		local near = admit("World", "SpecNear", 50, 4, 1, listener + Vector3.new(10, 0, 0), rollOff)
		t.truthy(near.slot ~= nil, "in range is admitted")
		releaseAll({ near })
	end,
}
