--!strict
-- Client lighting maths (LightingController's pure helpers): seeded, server-time flicker that every client agrees on,
-- blackouts that fit their slots, the two-stage lightning envelope, the light-burst surge, the camera-position
-- -> layout mapping that decides which level's fixtures are lit, the glow curve every fixture's tubes follow
-- (FixtureGlow) and the area grade's easing; the nearest fixtures keep their shadows; each level's film grade eases
-- in and settles; the volumetrics' client maths (plank gaps, ranking, spill, shaft and dust strength). The windows
-- and the haze cones themselves are world data: tests/Specs/Volumetrics.spec.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local FixtureGlow = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.FixtureGlow)
local LightingController = require(StarterPlayer.StarterPlayerScripts.Controllers.Core.LightingController)
local LightingFilm = require(StarterPlayer.StarterPlayerScripts.Controllers.Core.LightingController.Film)
local LightingMood = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingMood)
local Volumetrics = require(StarterPlayer.StarterPlayerScripts.Controllers.Core.LightingController.Volumetrics)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local Tags = require(ReplicatedStorage.Shared.Tags)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

type Expect = SpecRunner.Expect

local W = Attributes.World

-- A Zone volume like SchoolShellBuilder's, spanning `low`..`high` in world space.
local function zone(parent: Instance, id: string, levelId: string, roomKind: string, low: Vector3, high: Vector3): Part
	local part = Instance.new("Part")
	part.Name = id
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = high - low
	part.CFrame = CFrame.new((low + high) / 2)
	part:SetAttribute(W.ZoneId, id)
	part:SetAttribute(W.LevelId, levelId)
	part:SetAttribute(W.RoomKind, roomKind)
	part:AddTag(Tags.Zone)
	part.Parent = parent
	return part
end

local GROUPS = { "L0_Boilers", "L1_NorthHall", "Stairwell_0_1", "L2_HouseLights", "LobbyBoiler" }
local T0 = 1_700_000_000 -- a realistic server time

return {
	["a fixture's glow follows its light: dims, flickers dark and dies to glass"] = function(t: Expect)
		t.eq(FixtureGlow.level(0, 1.2), 0, "off")
		t.near(FixtureGlow.level(0.6, 1.2), 0.5, 1e-9, "half its working brightness")
		t.eq(FixtureGlow.level(4.8, 1.2), 1, "a burst surge clamps at full")
		t.eq(FixtureGlow.level(2, 0), 1, "an override lighting a dark fixture glows")
		t.eq(FixtureGlow.level(0 / 0, 1), 0, "NaN is off")

		local lit = FixtureGlow.litColor("Fluorescent", Color3.fromRGB(168, 236, 196))
		t.truthy(lit.R > 168 / 255 and lit.G >= 236 / 255 - 1e-6, "tubes burn whiter than the light they cast")
		local material, color = FixtureGlow.look(lit, 1)
		t.eq(material, FixtureGlow.OnMaterial, "lit tubes are Neon")
		t.near(color.R, lit.R, 1e-6, "at full level in their lit colour")
		t.near(color.G, lit.G, 1e-6)
		t.near(color.B, lit.B, 1e-6)
		material, color = FixtureGlow.look(lit, 0)
		t.eq(material, FixtureGlow.OffMaterial, "dead tubes are glass")
		t.truthy(color == FixtureGlow.OffColor, "grey")
		local _, half = FixtureGlow.look(lit, 0.5)
		local _, dip = FixtureGlow.look(lit, 0.12)
		t.truthy(half.G < lit.G and half.G > dip.G, "a dimmer light, a darker tube")
		t.truthy(dip.G > FixtureGlow.DimColor.G - 1e-6, "a flicker dip stays Neon, just dark")
		t.eq(FixtureGlow.guiBrightness(0), 0, "an exit sign's letters go black")
		t.near(FixtureGlow.guiBrightness(1), FixtureGlow.GuiBrightness, 1e-9, "and bloom at full")
	end,

	["the area grade eases toward the camera's level and settles"] = function(t: Expect)
		local white = Color3.new(1, 1, 1)
		local cold = Color3.fromRGB(226, 244, 255)
		local step = LightingController.gradeStep(white, cold, 1 / 60)
		t.truthy(step.R < 1 and step.R > cold.R, "a frame moves part of the way")
		local current = white
		for _ = 1, 600 do
			current = LightingController.gradeStep(current, cold, 1 / 60)
		end
		t.near(current.R, cold.R, 1e-3, "ten seconds later it has arrived")
		local settled = LightingController.gradeStep(cold, cold, 0.5)
		t.near(settled.R, cold.R, 1e-6, "a settled grade stays put")
		t.near(settled.B, cold.B, 1e-6)
	end,

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
		for _, levelId: Enums.LevelId in WorldConfig.LevelOrder do
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
		t.truthy(LightingController.isOutdoors("Level3_Roof"), "roof is outdoors")
		t.falsy(LightingController.isOutdoors("Lobby"), "lobby is indoors")
		t.falsy(LightingController.isOutdoors("Level1_Hallways"), "hallways are indoors")
	end,

	["a zone volume decides the layout and only roof zones see the sky"] = function(t: Expect)
		local folder = Instance.new("Folder")
		folder.Name = "SpecZones"
		folder.Parent = Workspace
		local ok, problem = pcall(function()
			local origin = WorldConfig.SchoolOrigin
			local roofY = origin.Y + WorldConfig.levelElevation("Level3_Roof")
			local hallY = origin.Y + WorldConfig.levelElevation("Level2_Auditorium")
			-- The open roof, a stair house standing on it, and an auditorium hall drawn taller than its floor band.
			zone(
				folder,
				"SpecRoof",
				"Level3_Roof",
				"Roof",
				origin + Vector3.new(0, roofY - origin.Y, 0),
				origin + Vector3.new(60, roofY - origin.Y + 40, 60)
			)
			zone(
				folder,
				"SpecStairHouse",
				"Level3_Roof",
				"Corridor",
				origin + Vector3.new(10, roofY - origin.Y, 10),
				origin + Vector3.new(20, roofY - origin.Y + 12, 20)
			)
			zone(
				folder,
				"SpecHall",
				"Level2_Auditorium",
				"Gallery",
				origin + Vector3.new(100, hallY - origin.Y, 0),
				origin + Vector3.new(140, roofY - origin.Y + 6, 40)
			)

			local open = LightingController.placeAt(origin + Vector3.new(40, roofY - origin.Y + 4, 40))
			t.eq(open.layoutId, "Level3_Roof", "open roof layout")
			t.eq(open.zoneId, "SpecRoof", "open roof zone")
			t.truthy(open.outdoors, "the open roof sees the sky")

			local house = LightingController.placeAt(origin + Vector3.new(15, roofY - origin.Y + 4, 15))
			t.eq(house.zoneId, "SpecStairHouse", "the smaller zone wins where volumes meet")
			t.falsy(house.outdoors, "the stair house is indoors")

			-- Above the roof's floor band but inside the auditorium hall's volume: the zone outranks the band.
			local tall = origin + Vector3.new(120, roofY - origin.Y + 2, 20)
			t.eq(LightingController.layoutAt(tall), "Level2_Auditorium", "auditorium hall above its band")
			t.falsy(LightingController.placeAt(tall).outdoors, "the auditorium hall is indoors")

			-- No zone holds a point inside the school (a duct, a wall): bands decide and, with zones built, the roof
			-- band is not outdoors.
			local duct = LightingController.placeAt(origin + Vector3.new(200, roofY - origin.Y + 2, 150))
			t.eq(duct.layoutId, "Level3_Roof", "band fallback")
			t.eq(duct.zoneId, nil, "no zone")
			t.falsy(duct.outdoors, "a zoneless point inside the school is indoors once zones exist")
		end)
		folder:Destroy()
		if not ok then
			error(problem, 0)
		end
	end,

	["the nearest fixtures keep their shadows, ties stay stable"] = function(t: Expect)
		local slots = LightingController.shadowSlots({ 30, 5, 18, 5, 60 }, 3)
		t.eq(slots[1], false, "30 studs: fourth nearest")
		t.eq(slots[2], true, "5 studs")
		t.eq(slots[3], true, "18 studs")
		t.eq(slots[4], true, "the tie at 5 studs keeps list order")
		t.eq(slots[5], false, "60 studs")
		local none = LightingController.shadowSlots({ 1, 2 }, 0)
		t.falsy(none[1] or none[2], "a budget of none casts none")
		local all = LightingController.shadowSlots({ 1, 2 }, 10)
		t.truthy(all[1] and all[2], "a bigger budget than fixtures casts all")
		t.eq(#LightingController.shadowSlots({}, 4), 0)
	end,

	["each level's film eases in from the last one and settles on it"] = function(t: Expect)
		local from = LightingMood.film("Lobby")
		local to = LightingMood.film("Level0_Basement")
		t.truthy(LightingFilm.distance(from, to) > 0.05, "the lobby and the basement are graded apart")
		t.eq(LightingFilm.distance(to, to), 0)
		local step = LightingFilm.step(from, to, 1 / 60)
		t.truthy(step.density > from.density and step.density < to.density, "a frame moves part of the way")
		t.truthy(LightingFilm.distance(step, to) < LightingFilm.distance(from, to))
		local current = from
		for _ = 1, 60 * 12 do
			current = LightingFilm.step(current, to, 1 / 60)
		end
		t.truthy(LightingFilm.distance(current, to) < 0.0015, "twelve seconds later it has settled")
		local held = LightingFilm.step(to, to, 0.5)
		t.truthy(LightingFilm.distance(held, to) < 1e-6, "a settled grade stays put")
		local frozen = LightingFilm.step(from, to, 0)
		t.truthy(LightingFilm.distance(frozen, from) < 1e-6, "no time, no change")
	end,

	["each level's Roblox render eases with the film and settles on it"] = function(t: Expect)
		local from = LightingMood.render("Lobby")
		local to = LightingMood.render("Level0_Basement")
		t.truthy(LightingFilm.renderDistance(from, to) > 0.05, "the lobby and the basement render apart")
		t.eq(LightingFilm.renderDistance(to, to), 0)
		local step = LightingFilm.stepRender(from, to, 1 / 60)
		t.truthy(step.exposure < from.exposure and step.exposure > to.exposure, "a frame moves part of the way")
		local current = from
		for _ = 1, 60 * 12 do
			current = LightingFilm.stepRender(current, to, 1 / 60)
		end
		t.truthy(LightingFilm.renderDistance(current, to) < 0.0015, "twelve seconds later it has settled")
		local frozen = LightingFilm.stepRender(from, to, 0)
		t.truthy(LightingFilm.renderDistance(frozen, from) < 1e-6, "no time, no change")
	end,

	["a probed opening yields its tallest plank gaps, bottom first"] = function(t: Expect)
		local open = { false, true, true, false, false, true, false, true, true, true, true, false, true }
		local bands, share = Volumetrics.gapBands(open, 0.1, 2, 0.15)
		t.eq(#bands, 2, "the two tallest runs that are tall enough")
		t.near(bands[1].y0, 0.1, 1e-9, "bottom first")
		t.near(bands[1].y1, 0.3, 1e-9)
		t.near(bands[2].y0, 0.7, 1e-9)
		t.near(bands[2].y1, 1.1, 1e-9)
		t.near(share, 8 / 13, 1e-9, "the open share counts every sample")
		local shut, none = Volumetrics.gapBands({ false, false }, 0.1, 3, 0.05)
		t.eq(#shut, 0)
		t.eq(none, 0, "a sealed opening lets nothing in")
		local wide, all = Volumetrics.gapBands({ true, true, true }, 0.1, 3, 0.05)
		t.eq(#wide, 1)
		t.eq(all, 1)
		local _, empty = Volumetrics.gapBands({}, 0.1, 3, 0.05)
		t.eq(empty, 0)
	end,

	["shafts, spills and dust follow the air, the moon and the lightning"] = function(t: Expect)
		local view = CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, -1))
		t.near(Volumetrics.rank(view, Vector3.new(0, 0, -20)), 20, 1e-6, "ahead ranks by distance")
		t.truthy(Volumetrics.rank(view, Vector3.new(0, 0, 20)) > 20, "behind the camera ranks further away")

		local quiet = Volumetrics.moonBrightness(true, 1, 0)
		t.truthy(quiet > 0, "a shadowed spill burns")
		t.truthy(Volumetrics.moonBrightness(false, 1, 0) < quiet, "an unshadowed spill burns at the planks' share")
		t.eq(Volumetrics.moonBrightness(true, 0, 1), 0, "no moon, no spill, lightning or not")
		t.truthy(Volumetrics.moonBrightness(true, 1, 1) > quiet * 3, "lightning surges through the windows")
		t.eq(Volumetrics.rayBrightness(0, 1, 0), 0, "clear air shows no rays")
		t.truthy(Volumetrics.rayBrightness(1.2, 1, 0) > Volumetrics.rayBrightness(1, 1, 0), "denser air shows more")
		t.eq(Volumetrics.dustRate(0, 1), 0, "a budget without particles has no dust")
		t.eq(Volumetrics.dustRate(1, 0), 0, "nor does air without dust")
		t.truthy(Volumetrics.dustRate(1, 1.4) > Volumetrics.dustRate(0.4, 1.4))
	end,

	["layers: a tunnel's mains burn steady, its circuits flicker; a stutter only dims, then lets go"] = function(
		t: Expect
	)
		t.truthy(LightingController.steadyGroup("Mains:3"), "a mains group is steady (the power switch holds it)")
		t.falsy(LightingController.steadyGroup("Circuit:3"), "a circuit flickers")
		t.falsy(LightingController.steadyGroup("HallA"), "so does any other group")
		t.falsy(LightingController.steadyGroup(nil), "no group, no hold")
		local dropped = 0
		for i = 0, 159 do
			local value = LightingController.stutterFactor(3, 100, 1.6, 100 + i / 100)
			t.truthy(value > 0 and value <= 1, "a stutter only dims")
			t.eq(value, LightingController.stutterFactor(3, 100, 1.6, 100 + i / 100), "the same on every client")
			if value < 0.5 then
				dropped += 1
			end
		end
		t.truthy(dropped > 30, "it stutters (" .. dropped .. " dark frames of 160)")
		t.eq(LightingController.stutterFactor(3, 100, 1.6, 99.9), 1, "not before the warning")
		t.eq(LightingController.stutterFactor(3, 100, 1.6, 101.61), 1, "nor after it")
		t.truthy(LightingController.stutterFactor(3, 100, 1.6, 101.59) > 0.9, "easing back by the end")
	end,
}
