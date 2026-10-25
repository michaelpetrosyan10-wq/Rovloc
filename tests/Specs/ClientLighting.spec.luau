--!strict
-- Client lighting maths (LightingController's pure helpers): seeded, server-time flicker that every client agrees on,
-- blackouts that fit their slots, the two-stage lightning envelope, the light-burst surge, and the camera-position
-- -> layout mapping that decides which level's fixtures are lit.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LightingController = require(StarterPlayer.StarterPlayerScripts.Controllers.Core.LightingController)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

type Expect = SpecRunner.Expect

local GROUPS = { "L0_Boilers", "L1_NorthHall", "Stairwell_0_1", "L4_Floodlights", "LobbyBoiler" }
local T0 = 1_700_000_000 -- a realistic server time

return {
	["flicker is a pure function of seed, group and server time"] = function(t: Expect)
		for _, group in GROUPS do
			for step = 0, 200 do
				local time = T0 + step * 0.137
				t.eq(
					LightingController.flickerAt(77, group, time),
					LightingController.flickerAt(77, group, time),
					group .. " @" .. step
				)
			end
		end
		local differs = false
		for step = 0, 400 do
			local time = T0 + step * 0.05
			if
				LightingController.flickerAt(77, GROUPS[1], time) ~= LightingController.flickerAt(78, GROUPS[1], time)
			then
				differs = true
				break
			end
		end
		t.truthy(differs, "a different run seed changes the flicker")
	end,

	["flicker stays in [0, 1], mostly lit, with real blackouts"] = function(t: Expect)
		for _, group in GROUPS do
			local samples, dark, lit = 0, 0, 0
			for step = 0, 12000 do
				local value = LightingController.flickerAt(5, group, T0 + step * 0.05)
				t.truthy(value >= 0 and value <= 1, string.format("%s value %s out of range", group, tostring(value)))
				samples += 1
				if value == 0 then
					dark += 1
				elseif value > 0.5 then
					lit += 1
				end
			end
			t.truthy(dark > 0, group .. " never blacks out in 10 minutes")
			t.truthy(dark / samples < 0.25, group .. " is dark too often")
			t.truthy(lit / samples > 0.5, group .. " is not mostly lit")
		end
	end,

	["blackouts and their recovery fit inside their slot"] = function(t: Expect)
		for _, group in GROUPS do
			local profile = LightingController.flickerProfile(9, group)
			t.truthy(profile.slotLength > profile.maxBlackout + LightingController.RecoverySeconds, group)
			local any = false
			for slot = 1_000_000, 1_000_200 do
				local blackout = LightingController.blackoutSlot(9, group, profile, slot)
				t.eq(blackout.slot, slot)
				if blackout.startsAt >= 0 then
					any = true
					local slotStart = slot * profile.slotLength
					local slotEnd = slotStart + profile.slotLength
					t.truthy(blackout.startsAt >= slotStart - 1e-6, "starts before its slot")
					t.truthy(blackout.endsAt > blackout.startsAt, "empty blackout")
					t.truthy(
						blackout.endsAt + LightingController.RecoverySeconds <= slotEnd + 1e-6,
						"recovery spills into the next slot"
					)
					t.truthy(blackout.endsAt - blackout.startsAt <= profile.maxBlackout + 1e-6, "too long")
				end
			end
			t.truthy(any, group .. " has no blackout in 200 slots")
		end
	end,

	["lightning: two strikes with a dark gap, peak 1, then over"] = function(t: Expect)
		local peak = 0
		local finished: number? = nil
		local step = 0
		while step <= 250 do
			local time = step * 0.01
			local value = LightingController.lightningEnvelope(time, 2)
			if value == nil then
				finished = time
				break
			end
			t.truthy(value >= 0 and value <= 1, "envelope out of range at " .. time)
			peak = math.max(peak, value)
			step += 1
		end
		t.near(peak, 1, 1e-6, "main strike peak")
		t.truthy(finished ~= nil and finished <= 1.75, "two-stage flash never ends")
		local first = LightingController.lightningEnvelope(0.08, 2) or 0
		local gap = LightingController.lightningEnvelope(0.36, 2) or 1
		local main = LightingController.lightningEnvelope(0.5, 2) or 0
		t.truthy(first > 0.5, "first strike")
		t.truthy(gap < 0.1, "dark gap between strikes")
		t.truthy(main > first, "the second strike is the brighter one")
		t.eq(LightingController.lightningEnvelope(1.2, 1), nil, "single strike ends by 1.2 s")
		t.near(LightingController.lightningEnvelope(0.08, 1) or 0, 1, 1e-6, "single strike peak")
	end,

	["a bursting bulb surges to about 4x, stutters, then dies"] = function(t: Expect)
		t.near(LightingController.burstMultiplier(0) or -1, 1, 1e-6, "starts at its own brightness")
		t.near(LightingController.burstMultiplier(0.1) or 0, 4, 0.4, "surge")
		local sawDark = false
		for step = 0, 27 do
			local value = LightingController.burstMultiplier(0.14 + step * 0.01)
			if value == 0 then
				sawDark = true
			end
		end
		t.truthy(sawDark, "stutter goes dark between flashes")
		t.eq(LightingController.burstMultiplier(0.5), nil, "dead after the stutter")
	end,

	["camera positions map to the lobby, each school floor and the outdoors"] = function(t: Expect)
		local midX = WorldConfig.FootprintSize.X / 2
		local midZ = WorldConfig.FootprintSize.Y / 2
		for _, levelId: Enums.LevelId in Enums.LevelId do
			local floor = WorldConfig.levelElevation(levelId)
			t.eq(LightingController.layoutAt(Vector3.new(midX, floor + 4.5, midZ)), levelId, levelId .. " standing")
			t.eq(LightingController.layoutAt(Vector3.new(midX, floor + 0.5, midZ)), levelId, levelId .. " downed")
		end
		local west = WorldConfig.Towers.West
		t.eq(
			LightingController.layoutAt(Vector3.new((west.minX + west.maxX) / 2, 22, (west.minZ + west.maxZ) / 2)),
			"Level1_Hallways",
			"inside the west stair tower at L1"
		)
		local lobby = Builder.getLayout("Lobby")
		t.truthy(lobby, "lobby layout")
		if lobby then
			local rect = lobby.rooms[1].rect
			local point = WorldConfig.levelOrigin("Lobby") + Vector3.new(rect.x + rect.w / 2, 5, rect.z + rect.d / 2)
			t.eq(LightingController.layoutAt(point), "Lobby", "lobby room")
		end
		t.eq(LightingController.layoutAt(Vector3.new(midX, WorldConfig.GroundY + 4, -400)), nil, "street")
		t.truthy(LightingController.isOutdoors(nil), "street is outdoors")
		t.truthy(LightingController.isOutdoors("Level5_Roof"), "roof is outdoors")
		t.falsy(LightingController.isOutdoors("Lobby"), "lobby is indoors")
		t.falsy(LightingController.isOutdoors("Level1_Hallways"), "hallways are indoors")
	end,
}
