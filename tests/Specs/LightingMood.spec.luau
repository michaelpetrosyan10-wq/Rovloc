--!strict
-- LightingMood: the built lighting is dark but readable — a real share of each level's fixtures burn, the story's
-- dark rooms and scripted lights keep their layout marks, wayfinding lights always burn, every wing casts its own
-- colour (green-teal school floors, amber basement, cyan pool) with a gentle grade to match, and it's deterministic.
-- Each level's Roblox render reproduces the browser build's frame (docs/LIGHTING-PARITY.md): its exposure, its
-- dark-frame contrast curve, a fill that keeps the gaps readable, and the Brightness setting's steps around it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local LightingMood = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingMood)
local LightingRig = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LightingRig)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
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

	["every level's film stays dark but readable"] = function(t: Expect)
		local films: { [string]: LightingMood.Film } = { outdoors = LightingMood.film(nil) }
		for _, layout in Builder.layouts() do
			films[layout.id] = LightingMood.film(layout.id)
		end
		for id, film in films do
			t.truthy(film.exposure >= 0 and film.exposure <= 0.3, id .. ": exposure trims up, never down")
			t.truthy(film.lift >= 0 and film.lift <= 0.05, id .. ": the blacks are lifted a touch, never washed")
			t.truthy(film.contrast > 0 and film.contrast <= 0.25, id .. ": contrast without crushing the shadows")
			t.truthy(film.saturation < 0 and film.saturation > -0.4, id .. ": drained, not grey")
			t.truthy(film.bloomThreshold >= 1, id .. ": only what really burns blooms")
			t.truthy(film.density > 0 and film.density <= 0.5, id .. ": haze, not fog")
			t.truthy(film.vignette > 0 and film.vignette <= 0.4, id .. ": a vignette that frames, not blinds")
			t.truthy(film.dofFar <= 0.2 and film.dofFocus >= 30, id .. ": the resting blur is subtle and far")
			t.truthy(film.shafts >= 0 and film.dust >= 0 and film.moon >= 0, id)
		end
		t.eq(LightingMood.film(nil), LightingMood.OutdoorFilm, "outdoors is the storm")
		t.eq(LightingMood.film("NoSuchLevel"), LightingMood.BaseFilm, "an unknown layout takes the base film")
		local lobby, basement, pool = films.Lobby, films.Level0_Basement, films.Level4_FloodedPool
		if lobby and basement and pool then
			t.truthy(basement.density > lobby.density and pool.density > lobby.density, "the depths are hazier")
			t.truthy(basement.dust > lobby.dust, "the basement is the dustiest")
			t.eq(basement.moon, 0, "no moonlight in the basement")
		end
	end,

	["each level's Roblox render is the web's exposure and grade"] = function(t: Expect)
		local places: { { id: string? } } = { { id = nil } }
		for _, layout in Builder.layouts() do
			local id: string = layout.id
			table.insert(places, { id = id })
		end
		for _, place in places do
			local id = place.id
			local label = id or "outdoors"
			local film = LightingMood.film(id)
			local render = LightingMood.render(id)
			t.near(render.exposure, LightingMood.webExposure(id), 1e-6, label .. ": the web's exposure, trim included")
			t.truthy(render.exposure > LightingRig.Baseline.ExposureCompensation + film.exposure, label .. ": brighter")
			local worst = 0
			for step = 1, 50 do
				local x = step / 100
				local web = LightingMood.webGrade(x, film)
				local roblox = LightingMood.robloxGrade(x, render.contrast, render.brightness)
				worst = math.max(worst, math.abs(web - roblox))
			end
			t.truthy(worst < 0.015, string.format("%s: grade within 4/255 of the web's (worst %.4f)", label, worst))
			-- the cause: the film's own contrast about mid-grey sends the dark frame to black on Roblox
			t.eq(LightingMood.robloxGrade(0.04, film.contrast, film.lift), 0, label .. ": the old grade crushed 0.04")
			t.truthy(LightingMood.webGrade(0.04, film) > 0.03, label .. ": the web keeps it")
			t.truthy(LightingMood.robloxGrade(0.04, render.contrast, render.brightness) > 0.03, label .. ": now kept")
			t.eq(render.tint, Color3.new(1, 1, 1), label .. ": the area grade carries the colour, as on the web")
			t.truthy(render.haze > 0 and render.haze < film.haze, label .. ": less night-dark haze than the film")
			t.truthy(render.fixtureGain >= 1 and render.fixtureGain <= 2, label .. ": fixture gain")
			t.truthy(render.fixtureRange >= 1 and render.fixtureRange <= 1.2, label .. ": fixture reach")
			t.truthy(render.torch >= 0.8 and render.torch <= 2, label .. ": torch gain")
		end
		t.eq(LightingMood.render(nil), LightingMood.OutdoorRender, "outdoors is the storm's render")
		t.eq(LightingMood.render("NoSuchLevel"), LightingMood.BaseRender, "an unknown layout takes the base render")
		t.truthy(LightingMood.render("Lobby").torch < LightingMood.render("Level1_Hallways").torch, "untrimmed torch")
		t.truthy(LightingMood.TorchOuterRange <= LightingMood.MaxRange, "the torch stays within a SpotLight's reach")
	end,

	["the fills keep the gaps between pools readable, not flat"] = function(t: Expect)
		local base = LightingRig.Baseline
		for _, render in { LightingMood.BaseRender, LightingMood.OutdoorRender, LightingMood.render("Lobby") } do
			local fill = render.ambient
			t.truthy(fill.R > base.Ambient.R and fill.G > base.Ambient.G and fill.B > base.Ambient.B, "lifted")
			t.truthy(math.max(fill.R, fill.G, fill.B) < 0.35, "still a night fill")
			t.truthy(fill.B > fill.R, "cold, like the rig's")
			local outdoor = render.outdoorAmbient
			t.truthy(outdoor.R >= fill.R and outdoor.G >= fill.G and outdoor.B >= fill.B, "open sky reads lighter")
		end
	end,

	["the Brightness setting steps the exposure and the fill around the render"] = function(t: Expect)
		local setting = SettingsSchema.get("Brightness")
		t.truthy(setting and setting.kind == "Number", "a number setting")
		if setting and setting.kind == "Number" then
			t.eq(setting.default, 0, "the graded look by default")
			t.eq(setting.min, -2)
			t.eq(setting.max, 2)
			t.eq(setting.step, 1)
		end
		local exposure, fill = LightingMood.brightnessAdjust(0)
		t.eq(exposure, 0)
		t.eq(fill, 1)
		local previousExposure, previousFill = -math.huge, -math.huge
		for step = -2, 2 do
			local e, f = LightingMood.brightnessAdjust(step)
			t.truthy(e > previousExposure and f > previousFill, "every step brighter than the last")
			t.truthy(math.abs(e) <= 0.5 and f > 0.5 and f < 1.5, "small steps")
			previousExposure, previousFill = e, f
		end
		local color = Color3.fromRGB(51, 56, 70)
		t.eq(LightingMood.scaleFill(color, 1), color)
		t.truthy(LightingMood.scaleFill(color, 1.3).B > color.B and LightingMood.scaleFill(color, 0.7).B < color.B)
		t.truthy(LightingMood.scaleFill(Color3.new(0.9, 0.9, 0.9), 4).R <= 1, "kept in range")
	end,

	["key lights burn hard in tight pools"] = function(t: Expect)
		for _, layout in Builder.layouts() do
			local mood = LightingMood.levelMood(layout.id)
			t.truthy(mood.brightness >= 2.2, layout.id .. ": strong keys under the working fixtures")
			t.truthy(mood.range <= 1.3, layout.id .. ": pools that fall off before the next one")
		end
		t.truthy(LightingMood.Moonlight.unshadowedShare < 1, "an unshadowed spill burns dimmer than a striped one")
	end,
}
