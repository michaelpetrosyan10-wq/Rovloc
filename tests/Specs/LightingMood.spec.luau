--!strict
-- LightingMood: the built lighting is dark but readable — a real share of each level's fixtures burn, the story's
-- dark rooms and scripted lights keep their layout marks, wayfinding lights always burn, and it's deterministic.

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
