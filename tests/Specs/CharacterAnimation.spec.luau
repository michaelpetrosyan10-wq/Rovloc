--!strict
-- CharacterAnimationController's pure rules: which pose a rig shows (local prediction vs server-only override
-- states vs life state), footstep surfaces (water, part attribute, Palette material, room, fallback) and
-- LookBroadcast parsing (keyed and positional samples, int16 dequantization, malformed samples skipped).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local CharacterAnimationController =
	require(StarterPlayer.StarterPlayerScripts.Controllers.Characters.CharacterAnimationController)
local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local PlayerR15 = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator.Profiles.PlayerR15)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

type Row = { life: string?, server: string?, predicted: string?, dead: boolean, expected: string }

local resolve = CharacterAnimationController.resolveState

return {
	["resolveState: prediction, server overrides, downed and dead"] = function(t: Expect)
		local rows: { Row } = {
			{ life = "Alive", server = "Standing", predicted = "Sprinting", dead = false, expected = "Sprinting" },
			{ life = "Alive", server = "Sprinting", predicted = nil, dead = false, expected = "Sprinting" },
			{ life = "Alive", server = "Hiding", predicted = "Standing", dead = false, expected = "Hiding" },
			{ life = "Alive", server = "Trapped", predicted = "Crouching", dead = false, expected = "Trapped" },
			{ life = "Alive", server = "Scripted", predicted = "Sprinting", dead = false, expected = "Scripted" },
			{ life = "Alive", server = "Parachuting", predicted = "Standing", dead = false, expected = "Parachuting" },
			{
				life = "Alive",
				server = "VentCrawling",
				predicted = "VentScurrying",
				dead = false,
				expected = "VentScurrying",
			},
			{
				life = "Downed",
				server = "Standing",
				predicted = "Sprinting",
				dead = false,
				expected = "DownedCrawling",
			},
			{ life = "Downed", server = "Grabbed", predicted = nil, dead = false, expected = "Grabbed" },
			{ life = "Alive", server = "DownedCrawling", predicted = "Standing", dead = false, expected = "Standing" },
			{ life = "Alive", server = "DownedCrawling", predicted = nil, dead = false, expected = "Standing" },
			{ life = nil, server = "DownedCrawling", predicted = nil, dead = false, expected = "DownedCrawling" },
			{ life = "Dead", server = "DownedCrawling", predicted = nil, dead = false, expected = PlayerR15.DeadState },
			{ life = "Alive", server = "Standing", predicted = nil, dead = true, expected = PlayerR15.DeadState },
			{ life = "Lobby", server = nil, predicted = nil, dead = false, expected = "Standing" },
			{ life = "Alive", server = "Bogus", predicted = "AlsoBogus", dead = false, expected = "Standing" },
		}
		for index, row in rows do
			t.eq(resolve(row.life, row.server, row.predicted, row.dead), row.expected, "row " .. index)
		end
		for _, state: Enums.MoveState in Enums.MoveState do
			t.truthy(PlayerR15.Profile.states[state] ~= nil, "the profile poses " .. state)
		end
		t.truthy(PlayerR15.Profile.states[PlayerR15.DeadState] ~= nil, "the profile poses the dead")
	end,

	["surfaceFor: water, part attribute, Palette material, room, then concrete"] = function(t: Expect)
		local surfaceFor = CharacterAnimationController.surfaceFor
		t.eq(surfaceFor(true, "Wood", Enum.Material.Metal, "Carpet"), "Water", "standing in water wins")
		t.eq(surfaceFor(false, "Wood", Enum.Material.Metal, "Carpet"), "Wood", "the floor part's Surface")
		t.eq(surfaceFor(false, "Nonsense", Enum.Material.Metal, "Carpet"), "Metal", "invalid attribute ignored")
		t.eq(surfaceFor(false, nil, Enum.Material.Neon, "Carpet"), "Glass", "Palette maps Neon (skyline windows)")
		t.eq(surfaceFor(false, nil, Enum.Material.ForceField, "Carpet"), "Carpet", "unknown material: the room")
		t.eq(surfaceFor(false, nil, nil, nil), "Concrete", "fallback")
		local cases: { [Enum.Material]: Enums.SurfaceKind } = {
			[Enum.Material.Concrete] = "Concrete",
			[Enum.Material.CeramicTiles] = "Tile",
			[Enum.Material.WoodPlanks] = "Wood",
			[Enum.Material.CorrodedMetal] = "Metal",
			[Enum.Material.Carpet] = "Carpet",
			[Enum.Material.Glass] = "Glass",
			[Enum.Material.Grass] = "Grass",
			[Enum.Material.Water] = "Water",
		}
		for material, expected in cases do
			t.eq(CharacterAnimationController.materialSurface(material), expected, tostring(material))
		end
	end,

	["parseLookBroadcast dequantizes keyed and positional samples and skips junk"] = function(t: Expect)
		local yaw, pitch = 1.234, -0.456
		local qYaw, qPitch = MathUtil.quantizeAngle(yaw), MathUtil.quantizeAngle(pitch)
		-- Built item by item: the samples deliberately mix shapes.
		local samples: { any } = {}
		table.insert(samples, { userId = 11, yaw = qYaw, pitch = qPitch })
		table.insert(samples, { 22, qPitch, qYaw })
		table.insert(samples, { userId = 33, yaw = "x", pitch = 1 })
		table.insert(samples, "junk")
		local parsed = CharacterAnimationController.parseLookBroadcast({ samples = samples })
		local first = parsed[11]
		t.truthy(first, "keyed sample")
		assert(first, "keyed sample missing")
		t.near(first.yaw, yaw, 1e-3, "yaw round trip")
		t.near(first.pitch, pitch, 1e-3, "pitch round trip")
		local second = parsed[22]
		assert(second, "positional sample missing")
		t.near(second.yaw, pitch, 1e-3, "positional yaw")
		t.eq(parsed[33], nil, "malformed sample skipped")
		t.eq(next(CharacterAnimationController.parseLookBroadcast("nope")), nil, "non-table payload")
		t.eq(next(CharacterAnimationController.parseLookBroadcast({ samples = 5 })), nil, "non-list samples")
	end,
}
