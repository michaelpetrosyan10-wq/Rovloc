--!strict
-- LightingMood: the built lighting is dark but readable — a real share of each level's fixtures burn, the story's
-- dark rooms and scripted lights keep their layout marks, wayfinding lights always burn, every wing casts its own
-- colour (green-teal school floors, amber basement, cyan pool) with a gentle grade to match, and it's deterministic.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local LightingMood = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingMood)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

type Entry = { room: LayoutSchema.Room, light: LayoutSchema.Light }

local function entriesOf(layout: LayoutSchema.LevelLayout): { Entry }
	local out: { Entry } = {}
	for _, room in layout.rooms do
		for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
			table.insert(out, { room = room, light = light })
		end
	end
	return out
end

return {
	["every school level ends up with a real share of lit fixtures"] = function(t: Expect)
		for _, layout in Builder.layouts() do
			local entries = entriesOf(layout)
			local lit, before = 0, 0
			for _, entry in entries do
				if not entry.light.broken then
					before += 1
				end
				if not LightingMood.resolve(layout.id, entry.room.id, entry.light).broken then
					lit += 1
				end
			end
			t.truthy(lit >= before, layout.id .. ": the mood never darkens a lit fixture")
			if #entries >= 20 then
				local share = lit / #entries
				t.truthy(
					share >= 0.3 and share <= 0.85,
					string.format("%s: %d of %d fixtures lit (%.0f%%)", layout.id, lit, #entries, share * 100)
				)
			end
		end
	end,

	["kept-dark rooms and scripted lights keep their layout marks"] = function(t: Expect)
		for _, layout in Builder.layouts() do
			local mood = LightingMood.levelMood(layout.id)
			for _, entry in entriesOf(layout) do
				local light = entry.light
				local kept = (mood.keepDark ~= nil and table.find(mood.keepDark, entry.room.id) ~= nil)
					or light.kind == "Floodlight"
					or light.kind == "ClassroomGlow"
				if kept then
					local resolved = LightingMood.resolve(layout.id, entry.room.id, light)
					t.eq(resolved.broken, light.broken == true, light.id .. " broken mark")
					t.eq(resolved.brightness, light.brightness, light.id .. " brightness")
					t.eq(resolved.flickerGroup, light.flickerGroup, light.id .. " flicker group")
				end
			end
		end
	end,

	["wayfinding lights always burn and nothing exceeds its cap"] = function(t: Expect)
		for _, layout in Builder.layouts() do
			for _, entry in entriesOf(layout) do
				local resolved = LightingMood.resolve(layout.id, entry.room.id, entry.light)
				local kind = entry.light.kind
				local mood = LightingMood.levelMood(layout.id)
				local keptDark = mood.keepDark ~= nil and table.find(mood.keepDark, entry.room.id) ~= nil
				if (kind == "EmergencyRed" or kind == "ExitSign") and not keptDark then
					t.falsy(resolved.broken, entry.light.id .. " burns")
				end
				t.truthy(resolved.range <= 60, entry.light.id .. " range")
				local cap = LightingMood.MaxBrightness[kind] or 2
				t.truthy(resolved.brightness <= math.max(cap, entry.light.brightness) + 1e-6, entry.light.id .. " cap")
			end
		end
	end,

	["each wing casts its own colour; wayfinding, scripted and kept-dark lights keep theirs"] = function(t: Expect)
		local white = Color3.new(1, 1, 1)
		local hallways = LightingMood.cast("Level1_Hallways", "L1_NorthHall_West", "Fluorescent", white)
		t.truthy(hallways.G > hallways.R and hallways.G > hallways.B, "the classroom floors burn a sickly green")
		local science = LightingMood.cast("Level2_ScienceHall", "L2_NorthHall", "Fluorescent", white)
		t.truthy(science.G > science.R and science.B > science.R, "the science wing a green-teal")
		local basement = LightingMood.cast("Level0_Basement", "L0_BoilerHall", "Fluorescent", white)
		t.truthy(basement.R > basement.G and basement.G > basement.B, "the basement tubes an amber")
		local bulb = LightingMood.cast("Level0_Basement", "L0_BoilerHall", "Bulb", white)
		t.truthy(bulb.R > bulb.B + 0.2, "the basement bulbs a warm sodium")
		local pool = LightingMood.cast("Level4_FloodedPool", "L4_Corridor_West", "Fluorescent", white)
		t.truthy(pool.B > pool.R and pool.B >= pool.G, "the pool a cold cyan")
		-- the pull is partial: the layout's own colour still shows through
		t.truthy(hallways.R > 0.5, "a cast, not a recolour")

		local red = Color3.fromRGB(255, 34, 22)
		t.eq(LightingMood.cast("Level1_Hallways", "L1_AirlockEast", "EmergencyRed", red), red, "emergency reds")
		t.eq(LightingMood.cast("Level1_Hallways", "L1_Corridor_West", "ExitSign", red), red, "exit signs")
		t.eq(LightingMood.cast("Level4_FloodedPool", "L4_Natatorium", "Floodlight", white), white, "floodlights")
		t.eq(LightingMood.cast("Level1_Hallways", "L1_Classroom_108", "ClassroomGlow", white), white, "the glow")
		t.eq(LightingMood.cast("Level1_Hallways", "L1_Corridor_East", "Fluorescent", white), white, "kept dark")

		t.eq(LightingMood.grade(nil), white, "no grade outside every building")
		local poolGrade = LightingMood.grade("Level4_FloodedPool")
		t.truthy(poolGrade.B > poolGrade.R, "the pool grade is cold")
		local basementGrade = LightingMood.grade("Level0_Basement")
		t.truthy(basementGrade.R > basementGrade.B, "the basement grade is warm")
		for _, layout in Builder.layouts() do
			local grade = LightingMood.grade(layout.id)
			t.truthy(math.min(grade.R, grade.G, grade.B) > 0.8, layout.id .. " grade stays gentle")
		end
	end,

	["the mood is deterministic"] = function(t: Expect)
		for _, layout in Builder.layouts() do
			for _, entry in entriesOf(layout) do
				local a = LightingMood.resolve(layout.id, entry.room.id, entry.light)
				local b = LightingMood.resolve(layout.id, entry.room.id, entry.light)
				t.eq(a.broken, b.broken, entry.light.id)
				t.eq(a.flickerGroup, b.flickerGroup, entry.light.id)
			end
		end
	end,
}
