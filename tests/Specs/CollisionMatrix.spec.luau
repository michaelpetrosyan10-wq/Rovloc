--!strict
-- The collision matrix must keep the vent and doorway guarantees from docs/ARCHITECTURE.md §4.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

return {
	["players never collide with each other, the creature or corpses"] = function(t: Expect)
		t.falsy(CollisionGroups.collides("Players", "Players"))
		t.falsy(CollisionGroups.collides("Players", "Monster"))
		t.falsy(CollisionGroups.collides("Players", "CorpseProps"))
		t.truthy(CollisionGroups.collides("Players", "Default"))
		t.truthy(CollisionGroups.collides("Players", "MonsterPassthrough"))
	end,
	["the creature passes trims, lockers and ragdolls but not walls"] = function(t: Expect)
		t.falsy(CollisionGroups.collides("Monster", "MonsterPassthrough"))
		t.falsy(CollisionGroups.collides("Monster", "CorpseProps"))
		t.truthy(CollisionGroups.collides("Monster", "Default"))
	end,
	["flasks hit the creature and props but not players"] = function(t: Expect)
		t.truthy(CollisionGroups.collides("Projectiles", "Monster"))
		t.truthy(CollisionGroups.collides("Projectiles", "Default"))
		t.truthy(CollisionGroups.collides("Projectiles", "MonsterPassthrough"))
		t.falsy(CollisionGroups.collides("Projectiles", "Players"))
		t.falsy(CollisionGroups.collides("Projectiles", "CorpseProps"))
	end,
	["the vent collider only touches world geometry"] = function(t: Expect)
		for _, group: CollisionGroups.GroupName in CollisionGroups.All do
			t.eq(CollisionGroups.collides("VentCollider", group), group == "Default", "VentCollider vs " .. group)
		end
	end,
	["NoCollide collides with nothing"] = function(t: Expect)
		for _, group: CollisionGroups.GroupName in CollisionGroups.All do
			t.falsy(CollisionGroups.collides("NoCollide", group), "NoCollide vs " .. group)
		end
	end,
	["matrix is symmetric"] = function(t: Expect)
		for _, a: CollisionGroups.GroupName in CollisionGroups.All do
			for _, b: CollisionGroups.GroupName in CollisionGroups.All do
				t.eq(CollisionGroups.collides(a, b), CollisionGroups.collides(b, a), a .. "/" .. b)
			end
		end
	end,
	["stays within the engine's 32-group limit"] = function(t: Expect)
		t.truthy(#CollisionGroups.All <= 32)
	end,
}
