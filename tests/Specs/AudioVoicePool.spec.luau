--!strict
-- Voice runtime rules. Budget: bus caps from the brief (plus Body), priority stealing (lowest priority, then
-- quietest, then oldest), outranked newcomers refused, per-preset caps replacing the least audible instance but never
-- letting a one-shot evict a looping instance, the distance pre-cull and the per-device budgets. Effect groups: one
-- shared chain per preset layer that outlives its last user by the chain's tail, a global Reverb budget (idle tails
-- cut first, then chains built without their Reverb). Grain timing (SoundSynthesizer.drainDue): frame lateness is
-- never fast-forwarded, only network lateness; at most one trigger per layer per frame, so a cluster keeps every
-- transient on any frame rate. Slots are driven with fake callbacks and effect groups with an explicit clock, so no
-- Sound is ever played.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local SoundSynthesizer = require(ReplicatedStorage.Shared.Audio.SoundSynthesizer)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local VoicePool = require(ReplicatedStorage.Shared.Audio.VoicePool)

type Expect = SpecRunner.Expect

type Fake = { slot: VoicePool.Slot?, stolen: boolean }

type Start = { layer: number, base: number, late: number }

-- A synthetic clock far from os.clock(), so the fx tests never interact with real-time sweeps.
local CLOCK = 5_000_000
local FAR_FUTURE = 1e12

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
	rollOff: SynthPresets.Range?,
	looped: boolean?
): Fake
	local fake: Fake = { slot = nil, stolen = false }
	fake.slot = VoicePool.admit({
		bus = bus,
		preset = preset,
		priority = priority,
		maxVoices = maxVoices,
		looped = looped == true,
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

local function scratchGroup(): SoundGroup
	local group = Instance.new("SoundGroup")
	group.Name = "VoicePoolSpecBus"
	return group
end

local function reverbChain(decay: number): { SynthPresets.Effect }
	return {
		{ kind = "Equalizer", props = { LowGain = -10, MidGain = 0, HighGain = 0 } },
		{ kind = "Reverb", props = { DecayTime = decay, WetLevel = -6, DryLevel = 0, Density = 1, Diffusion = 1 } },
	}
end

local function countClass(group: SoundGroup, className: string): number
	local count = 0
	for _, child in group:GetChildren() do
		if child.ClassName == className then
			count += 1
		end
	end
	return count
end

-- Frees every effect group the spec left behind (all users released first by the tests themselves).
local function sweepAll()
	VoicePool.sweepFxGroups(FAR_FUTURE)
end

local function pending(list: { { number } }): { SoundSynthesizer.Pending }
	local out: { SoundSynthesizer.Pending } = {}
	for _, entry in list do
		table.insert(out, { at = entry[1], layerIndex = entry[2] })
	end
	return out
end

local function recorder(): ({ Start }, SoundSynthesizer.Starter)
	local starts: { Start } = {}
	return starts,
		function(layer: number, base: number, late: number): boolean
			table.insert(starts, { layer = layer, base = base, late = late })
			return true
		end
end

return {
	["bus caps match the brief"] = function(t: Expect)
		t.eq(cap("Monster"), 6)
		t.eq(cap("World"), 16)
		t.eq(cap("Ambience"), 8)
		t.eq(cap("Player"), 12)
		t.eq(cap("Body"), 6)
		t.eq(cap("UI"), 6)
		for _, bus: Enums.AudioBus in Enums.AudioBus do
			t.truthy(cap(bus) ~= nil and cap(bus) > 0, bus .. " has a cap")
		end
	end,

	["phones get a smaller budget than desktops"] = function(t: Expect)
		local phone = VoicePool.budgetFor(true, false)
		local desktop = VoicePool.budgetFor(false, true)
		t.eq(phone.liveSounds, 96)
		t.eq(desktop.liveSounds, 128)
		t.eq(VoicePool.budgetFor(true, true).liveSounds, 128, "a touch laptop with a keyboard is a desktop")
		t.truthy(phone.reverbs < desktop.reverbs and desktop.reverbs <= 6, "reverbs capped, fewer on phones")
		t.truthy(phone.grainsPerVoice <= desktop.grainsPerVoice and desktop.grainsPerVoice <= 10, "grain cap per voice")
		t.truthy(SynthPresets.MaxGrainCount <= desktop.grainsPerVoice, "one trigger's grains fit a desktop voice")
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

	["a one-shot never evicts a looping instance of its own preset"] = function(t: Expect)
		-- Two dripping pipes (looped emitters) fill the preset's cap; a stinger of the same preset must not end one.
		local pipeA = admit("World", "SpecPipe", 15, 2, 0.1, nil, nil, true)
		local pipeB = admit("World", "SpecPipe", 15, 2, 0.05, nil, nil, true)
		t.truthy(pipeA.slot ~= nil and pipeB.slot ~= nil, "both pipes play")
		local stinger = admit("World", "SpecPipe", 15, 2, 1)
		t.eq(stinger.slot, nil, "the one-shot is refused")
		t.falsy(pipeA.stolen or pipeB.stolen, "no pipe dropped out")
		-- A looping newcomer may still replace the quietest instance.
		local pipeC = admit("World", "SpecPipe", 15, 2, 0.5, nil, nil, true)
		t.truthy(pipeC.slot ~= nil and pipeB.stolen, "a new pipe replaces the quietest pipe")
		releaseAll({ pipeA, pipeB, pipeC })
		-- One-shots among themselves still rotate.
		local shotA = admit("World", "SpecShot", 15, 1, 0.2)
		local shotB = admit("World", "SpecShot", 15, 1, 0.9)
		t.truthy(shotB.slot ~= nil and shotA.stolen, "a one-shot replaces an older one-shot")
		releaseAll({ shotA, shotB })
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

	["a layer's chain is one shared group that rings out its tail after the last user"] = function(t: Expect)
		sweepAll()
		local bus = scratchGroup()
		local chain = reverbChain(2)
		local tail = SynthPresets.chainTail(chain)
		t.near(tail, 2, 1e-6, "a 2 s reverb rings for 2 s")

		local first = VoicePool.acquireFxGroup("Spec/Tail/1", bus, chain, 0, nil, CLOCK)
		local second = VoicePool.acquireFxGroup("Spec/Tail/1", bus, chain, 0, nil, CLOCK)
		t.truthy(first ~= nil and first == second, "two voices of the same layer share one group")
		if not first then
			return
		end
		t.eq(first.group.Parent, bus, "under the bus group")
		t.eq(countClass(first.group, "ReverbSoundEffect"), 1, "the chain lives on the group")
		t.eq(countClass(first.group, "EqualizerSoundEffect"), 1)
		t.eq(first.users, 2)

		VoicePool.releaseFxGroup(first, CLOCK + 1)
		VoicePool.sweepFxGroups(CLOCK + 50)
		t.truthy(VoicePool.fxGroup("Spec/Tail/1") == first, "still in use by the other voice")

		VoicePool.releaseFxGroup(first, CLOCK + 2) -- the last voice ends: the tail starts now
		VoicePool.sweepFxGroups(CLOCK + 2 + tail * 0.5)
		t.truthy(VoicePool.fxGroup("Spec/Tail/1") == first, "kept while the reverb rings")
		t.eq(first.group.Parent, bus, "still routed while ringing")

		local again = VoicePool.acquireFxGroup("Spec/Tail/1", bus, chain, 0, nil, CLOCK + 2 + tail * 0.6)
		t.truthy(again == first and first.users == 1 and first.idleSince == nil, "a new voice reuses the ringing group")
		if again then
			VoicePool.releaseFxGroup(again, CLOCK + 10)
		end
		VoicePool.sweepFxGroups(CLOCK + 10 + tail + VoicePool.TailMargin + 0.01)
		t.eq(VoicePool.fxGroup("Spec/Tail/1"), nil, "freed once the tail has rung out")
		t.truthy(first.retired, "retired")
		t.truthy(first.group.Parent ~= bus, "detached from the bus")
		bus:Destroy()
		sweepAll()
	end,

	["a space group outlives the layer groups feeding it"] = function(t: Expect)
		sweepAll()
		local bus = scratchGroup()
		local space = VoicePool.acquireFxGroup("Spec/Space/space", bus, reverbChain(3), 1.5, nil, CLOCK)
		assert(space, "space group")
		local layer = VoicePool.acquireFxGroup("Spec/Space/s1", space.group, reverbChain(1.5), 0, space, CLOCK)
		assert(layer, "layer group")
		t.eq(layer.group.Parent, space.group, "the layer routes into the space")
		t.truthy(space.tail >= layer.tail + 3 - 1e-6, "space tail covers its own reverb after the layer's")
		VoicePool.releaseFxGroup(layer, CLOCK + 1)
		VoicePool.releaseFxGroup(space, CLOCK + 1)
		VoicePool.sweepFxGroups(CLOCK + 1 + layer.tail + VoicePool.TailMargin + 0.01)
		t.eq(VoicePool.fxGroup("Spec/Space/s1"), nil, "the layer tail ended first")
		t.truthy(VoicePool.fxGroup("Spec/Space/space") == space, "the space still rings")
		VoicePool.sweepFxGroups(CLOCK + 1 + space.tail + VoicePool.TailMargin + 0.01)
		t.eq(VoicePool.fxGroup("Spec/Space/space"), nil, "then the space")
		bus:Destroy()
		sweepAll()
	end,

	["the reverb budget cuts idle tails first, then builds chains without their reverb"] = function(t: Expect)
		sweepAll()
		local _, _, reverbsBefore = VoicePool.fxStats()
		t.eq(reverbsBefore, 0, "clean start")
		local bus = scratchGroup()
		local limit = VoicePool.budget().reverbs
		local held: { VoicePool.FxGroup } = {}
		for i = 1, limit do
			local fx = VoicePool.acquireFxGroup("Spec/Rev/" .. i, bus, reverbChain(4), 0, nil, CLOCK)
			assert(fx, "group " .. i)
			t.falsy(fx.degraded, "within budget " .. i)
			table.insert(held, fx)
		end
		local _, _, full = VoicePool.fxStats()
		t.eq(full, limit, "budget full")

		-- One of them goes idle (ringing): a newcomer takes its reverb, cutting that tail.
		VoicePool.releaseFxGroup(held[1], CLOCK + 1)
		local fresh = VoicePool.acquireFxGroup("Spec/Rev/new", bus, reverbChain(4), 0, nil, CLOCK + 1.5)
		assert(fresh, "fresh group")
		t.falsy(fresh.degraded, "an idle tail made room")
		t.truthy(held[1].retired, "the idle tail was cut")

		-- Everything in use: the next chain is built without its reverb (its EQ still applies).
		local starved = VoicePool.acquireFxGroup("Spec/Rev/starved", bus, reverbChain(4), 0, nil, CLOCK + 2)
		assert(starved, "starved group")
		t.truthy(starved.degraded, "no reverb left")
		t.eq(countClass(starved.group, "ReverbSoundEffect"), 0)
		t.eq(countClass(starved.group, "EqualizerSoundEffect"), 1)
		local _, _, after = VoicePool.fxStats()
		t.eq(after, limit, "never over budget")

		for index = 2, #held do
			VoicePool.releaseFxGroup(held[index], CLOCK + 3)
		end
		VoicePool.releaseFxGroup(fresh, CLOCK + 3)
		VoicePool.releaseFxGroup(starved, CLOCK + 3)
		sweepAll()
		local groups, _, reverbs = VoicePool.fxStats()
		t.eq(groups, 0, "all groups freed")
		t.eq(reverbs, 0, "all reverbs freed")
		bus:Destroy()
	end,

	["frame lateness is never fast-forwarded and a cluster keeps every transient"] = function(t: Expect)
		-- Five grains of layer 1 spaced 10 ms apart (all inside one 30 fps frame) and one grain of layer 2.
		local queue = pending({ { 0, 1 }, { 0.01, 1 }, { 0.02, 2 }, { 0.02, 1 }, { 0.03, 1 }, { 0.04, 1 } })
		local starts, start = recorder()
		local frame = 1 / 30
		local t1 = SoundSynthesizer.drainDue(queue, frame, 0, start)
		t.eq(t1, 2, "one grain per layer per frame")
		t.eq(starts[1].layer, 1)
		t.eq(starts[2].layer, 2, "another layer is not held back")
		for _, entry in starts do
			t.eq(entry.late, 0, "not fast-forwarded")
			t.near(entry.base, frame, 1e-9, "clock starts on the frame it really started")
		end
		local frames = 1
		while #queue > 0 and frames < 20 do
			frames += 1
			SoundSynthesizer.drainDue(queue, frames * frame, 0, start)
		end
		t.eq(#starts, 6, "every grain eventually starts")
		t.eq(frames, 5, "the four deferred grains of layer 1 took one frame each")
		for _, entry in starts do
			t.eq(entry.late, 0, "no grain skipped into its slice")
		end
	end,

	["only network lateness is skipped"] = function(t: Expect)
		-- The voice joined 0.5 s late (startOffset): its first step runs at voice time 0.5.
		local queue = pending({ { 0.1, 1 }, { 0.4, 2 }, { 0.6, 1 } })
		local starts, start = recorder()
		SoundSynthesizer.drainDue(queue, 0.5, 0.5, start)
		t.eq(#starts, 2)
		t.near(starts[1].late, 0.4, 1e-9, "skips what the network cost")
		t.near(starts[1].base, 0.1, 1e-9, "its clock is where it should have started")
		t.near(starts[2].late, 0.1, 1e-9)
		t.eq(#queue, 1, "the future grain waits")
		-- A frame later the next grain is due 16 ms late by frame: it starts from the top.
		SoundSynthesizer.drainDue(queue, 0.616, 0.5, start)
		t.eq(#starts, 3)
		t.eq(starts[3].late, 0, "frame lateness after the join is not skipped")
		t.near(starts[3].base, 0.616, 1e-9)
	end,

	["a refused trigger does not hold its layer's turn"] = function(t: Expect)
		local queue = pending({ { 0, 1 }, { 0.001, 1 }, { 0.002, 1 } })
		local calls = 0
		local started = SoundSynthesizer.drainDue(
			queue,
			0.05,
			1,
			function(_layer: number, _base: number, _late: number): boolean
				calls += 1
				return calls >= 3 -- the first two were already over (network-late)
			end
		)
		t.eq(started, 1)
		t.eq(calls, 3, "skipped triggers are consumed in the same frame")
		t.eq(#queue, 0)
	end,
}
