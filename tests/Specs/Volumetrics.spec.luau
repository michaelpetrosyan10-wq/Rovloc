--!strict
-- The air's world data the web export writes: moonlight through every window above grade (Volumetrics.windowSpecs,
-- meta.windows) and the haze cones every burning fixture kind throws (FixtureGlow.cone, meta.lighting.fixtureCones).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local FixtureGlow = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.FixtureGlow)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local Volumetrics = require(ReplicatedStorage.Shared.World.Volumetrics)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

type Expect = SpecRunner.Expect

return {
	["moonlight falls in and down through every window above grade"] = function(t: Expect)
		for _, inward in { Vector3.new(0, 0, 1), Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0) } do
			local direction = Volumetrics.moonDirection(inward)
			t.near(direction.Magnitude, 1, 1e-6)
			t.truthy(direction.Y < -0.4 and direction.Y > -0.9, "down at the moon's pitch")
			t.truthy(direction:Dot(inward) > 0.5, "into the room")
		end
		local total = 0
		for _, layout in Builder.layouts() do
			local specs = Volumetrics.windowSpecs(layout)
			total += #specs
			local origin = WorldConfig.levelOrigin(layout.id)
			for _, spec in specs do
				t.eq(spec.layoutId, layout.id)
				t.truthy(spec.center.Y > origin.Y and spec.width > 0 and spec.height > 0, spec.id)
				t.truthy(spec.direction:Dot(spec.inward) > 0 and spec.direction.Y < 0, spec.id .. " shines in")
				t.near(spec.inward:Dot(spec.tangent), 0, 1e-6, spec.id .. " tangent runs along the wall")
				local top = spec.center.Y + spec.height / 2 - origin.Y
				if layout.id ~= "Lobby" then
					local grade = WorldConfig.GroundY - WorldConfig.levelElevation(layout.id)
					t.truthy(top > grade, spec.id .. " sits above street grade")
				end
			end
		end
		t.truthy(total > 0, "the school's facades have windows the moon reaches")
		local basement = Builder.getLayout("Level0_Basement")
		if basement then
			t.eq(#Volumetrics.windowSpecs(basement), 0, "the basement's windows look into soil-filled light wells")
		end
	end,

	["burning fixtures throw haze cones that follow their glow"] = function(t: Expect)
		for _, kind in { "Fluorescent", "Bulb", "Floodlight", "EmergencyRed", "ClassroomGlow" } do
			local shape = FixtureGlow.cone(kind)
			assert(shape, kind .. " throws a cone")
			t.truthy(shape.width1 > shape.width0 and shape.length > 0, kind .. " widens toward the floor")
			t.eq(FixtureGlow.coneBrightness(shape, 0, 1), 0, kind .. " dead: no cone")
			local full = FixtureGlow.coneBrightness(shape, 1, 1)
			local dip = FixtureGlow.coneBrightness(shape, 0.3, 1)
			t.truthy(full > dip and dip > 0, kind .. " a dipping tube's cone thins with it")
			t.near(FixtureGlow.coneBrightness(shape, 1, 0.5), full * 0.5, 1e-9, kind .. " the air scales it")
		end
		t.eq(FixtureGlow.cone("ExitSign"), nil, "exit signs throw no cone")
		t.eq(FixtureGlow.cone("BoilerGlow"), nil, "nor do the boiler embers")
	end,
}
