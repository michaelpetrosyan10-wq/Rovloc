--!strict
-- MovementAuthority's verdict maths: the allowed speed with its grace window after a slow-down, stall-aware
-- intervals, jump and rise limits, the capsule noclip test against walls, poles and corners, the built-in judge
-- (teleport, noclip, fly, accumulated overspeed, clean samples), strike decay, validator ordering, and exemptions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Shared.Types)
local MovementAuthority = require(ServerScriptService.Services.Player.MovementAuthority)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Sample = MovementAuthority.Sample

local GRAVITY = 196.2
local WALK = 11
local SPRINT = 19

local function allowed(walkSpeed: number): number
	return walkSpeed * MovementAuthority.SpeedMultiplier + MovementAuthority.SpeedSlack
end

-- A grounded on-foot step of `distance` studs along +X over `dt` seconds at walking allowance.
local function step(distance: number, dt: number, surplus: number?): Sample
	return {
		from = Vector3.new(0, 3, 0),
		to = Vector3.new(distance, 3, 0),
		dt = dt,
		allowedSpeed = allowed(WALK),
		grounded = true,
		airborneFor = 0,
		checkVertical = true,
		jumpVelocity = MovementAuthority.jumpVelocity(false, 50, 2.5, GRAVITY),
		gravity = GRAVITY,
		surplus = surplus or 0,
	}
end

-- A solid slab occupying `minX <= x <= maxX` within `|z| <= halfWidth` (all heights): true when a ray crosses it.
local function slab(minX: number, maxX: number, halfWidth: number): MovementAuthority.RayCaster
	return function(origin: Vector3, direction: Vector3): boolean
		local samples = 64
		for i = 0, samples do
			local point = origin + direction * (i / samples)
			if point.X >= minX and point.X <= maxX and math.abs(point.Z) <= halfWidth then
				return true
			end
		end
		return false
	end
end

local function fakePlayer(): Player
	return Instance.new("Player")
end

return {
	["speed: allowance is WalkSpeed × 1.25 + 3, with a grace window after a slow-down"] = function(t: Expect)
		local track = MovementAuthority.newSpeedTrack(SPRINT, 0)
		t.eq(MovementAuthority.allowedSpeed(track, 5), SPRINT * 1.25 + 3)
		MovementAuthority.trackWalkSpeed(track, WALK, 10)
		t.eq(MovementAuthority.allowedSpeed(track, 10.3), SPRINT * 1.25 + 3, "sprint still allowed in the grace")
		t.eq(MovementAuthority.allowedSpeed(track, 10.7), WALK * 1.25 + 3, "grace over")
		MovementAuthority.trackWalkSpeed(track, SPRINT, 11)
		t.eq(MovementAuthority.allowedSpeed(track, 11), SPRINT * 1.25 + 3, "a speed-up applies at once")
		MovementAuthority.trackWalkSpeed(track, SPRINT, 12)
		t.eq(track.changedAt, 11, "an unchanged WalkSpeed is not a change")
		MovementAuthority.trackWalkSpeed(track, 0, 20)
		t.eq(MovementAuthority.allowedSpeed(track, 21), 3, "held still: latency slack only")
	end,

	["intervals stretch over a replication stall, up to the cap"] = function(t: Expect)
		t.near(MovementAuthority.effectiveInterval(10.1, 10, 10), 0.1, 1e-9)
		t.near(MovementAuthority.effectiveInterval(10.1, 10, 9.6), 0.5, 1e-9, "root was still for half a second")
		t.near(MovementAuthority.effectiveInterval(10.1, 10, 5), MovementAuthority.MaxStallSeconds, 1e-9, "capped")
		t.near(MovementAuthority.effectiveInterval(12, 10, 10), 2, 1e-9, "never shorter than the gap")
	end,

	["jumps: take-off speed and the rise still possible in the air"] = function(t: Expect)
		local v = MovementAuthority.jumpVelocity(false, 50, 2.5, GRAVITY)
		t.near(v, math.sqrt(2 * GRAVITY * 2.5), 1e-9)
		t.eq(MovementAuthority.jumpVelocity(true, 50, 2.5, GRAVITY), 50)
		t.near(MovementAuthority.allowedRise(0.1, 0.1, v, GRAVITY), v + MovementAuthority.VerticalSlack, 1e-9)
		t.eq(MovementAuthority.allowedRise(0.6, 0.1, v, GRAVITY), MovementAuthority.VerticalSlack, "long past the apex")
	end,

	["noclip: a wall blocks the whole capsule; poles, corners and short steps do not"] = function(t: Expect)
		local from = Vector3.new(0, 3, 0)
		local wall = slab(4, 5, 50)
		t.truthy(MovementAuthority.capsuleBlocked(from, Vector3.new(8, 3, 0), wall), "through a wall")
		t.falsy(MovementAuthority.capsuleBlocked(from, Vector3.new(3, 3, 0), wall), "stopped short of it")
		local pole = slab(4, 5, 0.4)
		t.falsy(MovementAuthority.capsuleBlocked(from, Vector3.new(8, 3, 0), pole), "a thin pole can be passed")
		local corner = slab(4, 5, 0.6)
		t.falsy(
			MovementAuthority.capsuleBlocked(Vector3.new(0, 3, 0.5), Vector3.new(8, 3, 0.5), corner),
			"a chord clipping a corner: the centre ray hits, one side is free"
		)
		local floor = function(origin: Vector3, direction: Vector3): boolean
			return origin.Y > 0 and origin.Y + direction.Y < 0
		end
		t.truthy(
			MovementAuthority.capsuleBlocked(Vector3.new(0, 3, 0), Vector3.new(0.5, -6, 0), floor),
			"down through a floor"
		)
		t.falsy(MovementAuthority.capsuleBlocked(from, Vector3.new(0.1, 3, 0), wall), "jitter is never ray-checked")
	end,

	["judge: walking is clean, sprinting while walking-allowed builds surplus until corrected"] = function(t: Expect)
		local walk = MovementAuthority.judge(step(1.1, 0.1), nil)
		t.eq(walk.verdict, "Ok")
		t.truthy(walk.clean)
		t.eq(walk.surplus, 0)
		-- A lone late packet (one step at sprint pace before the server knew) is tolerated.
		local spike = MovementAuthority.judge(step(SPRINT * 0.1, 0.1), nil)
		t.eq(spike.verdict, "Ok")
		t.falsy(spike.clean, "an over-speed step never becomes a safe position")
		t.truthy(spike.surplus > 0)
		local back = MovementAuthority.judge(step(1.1, 0.1, spike.surplus), nil)
		t.eq(back.surplus, 0, "walking pays the surplus back")
		-- A sustained 30 studs/s on a walking allowance is corrected within a few samples.
		local surplus = 0
		local verdict: Types.MovementVerdict = "Ok"
		local samples = 0
		while verdict == "Ok" and samples < 20 do
			samples += 1
			local judgement = MovementAuthority.judge(step(3, 0.1, surplus), nil)
			verdict = judgement.verdict
			surplus = judgement.surplus
		end
		t.eq(verdict, "Correct")
		t.truthy(samples <= 4, "corrected after " .. samples .. " samples")
	end,

	["judge: teleports, noclips and flying are strikes"] = function(t: Expect)
		local teleport = MovementAuthority.judge(step(allowed(WALK) * 0.1 + MovementAuthority.TeleportSlack + 0.1, 0.1))
		t.eq(teleport.verdict, "Strike")
		t.eq(teleport.reason, "Teleport")
		local stalled = MovementAuthority.judge(step(10, 1), nil)
		t.eq(stalled.verdict, "Ok", "a stalled client's catch-up is judged over the stall")
		local always = function(_from: Vector3, _to: Vector3): boolean
			return true
		end
		local noclip = MovementAuthority.judge(step(1, 0.1), always)
		t.eq(noclip.verdict, "Strike")
		t.eq(noclip.reason, "Noclip")

		local fly = step(0.5, 0.1)
		fly.grounded = false
		fly.airborneFor = 0.8
		fly.to = Vector3.new(0.5, 4, 0)
		local flying = MovementAuthority.judge(fly, nil)
		t.eq(flying.verdict, "Strike")
		t.eq(flying.reason, "Fly")
		fly.airborneFor = 0.3
		t.eq(MovementAuthority.judge(fly, nil).verdict, "Ok", "a fresh jump may rise")
		fly.airborneFor = 0.8
		fly.to = Vector3.new(0.5, 1, 0)
		t.eq(MovementAuthority.judge(fly, nil).verdict, "Ok", "falling is fine")
		fly.to = Vector3.new(0.5, 4, 0)
		fly.checkVertical = false
		t.eq(MovementAuthority.judge(fly, nil).verdict, "Ok", "vents and water skip the jump rule")
	end,

	["settling: checks resume once the client takes the server's position"] = function(t: Expect)
		local target = Vector3.new(0, 3, 0)
		local from = Vector3.new(10, 3, 0)
		local settled = MovementAuthority.settled
		t.falsy(settled(from, target, from, 2), "still replicating the old spot")
		t.truthy(settled(Vector3.new(1, 3, 0), target, from, 2), "took it and walked a little")
		t.falsy(settled(Vector3.new(0, 3, 30), target, from, 2), "nowhere near either")
		t.truthy(settled(Vector3.new(0.5, 3, 0), target, nil, 0), "a fresh character")
		t.falsy(settled(Vector3.new(3, 3, 0), target, Vector3.new(4, 3, 0), 10), "closer to where it came from")
		t.falsy(settled(Vector3.new(0, 43, 0), target, nil, 1), "a floor apart counts in 3D")
	end,

	["strikes decay one per StrikeDecaySeconds"] = function(t: Expect)
		local decay = MovementAuthority.decayStrikes
		t.eq(decay(6, 0), 6)
		t.eq(decay(6, MovementAuthority.StrikeDecaySeconds), 5)
		t.eq(decay(6, MovementAuthority.StrikeDecaySeconds * 2.5), 3.5)
		t.eq(decay(2, MovementAuthority.StrikeDecaySeconds * 10), 0)
		t.eq(decay(2, -5), 2)
	end,

	["validators: run in order, the first refusal wins, errors count as Ok"] = function(t: Expect)
		local player = fakePlayer()
		local root = Instance.new("Part")
		local calls: { string } = {}
		local list: { MovementAuthority.ValidatorEntry } = {
			{
				name = "Broken",
				validator = function(_player: Player, _root: BasePart, _dt: number): (Types.MovementVerdict, Vector3?)
					table.insert(calls, "Broken")
					error("validator bug")
				end,
			},
			{
				name = "Fine",
				validator = function(): (Types.MovementVerdict, Vector3?)
					table.insert(calls, "Fine")
					return "Ok", nil
				end,
			},
			{
				name = "VentRail",
				validator = function(): (Types.MovementVerdict, Vector3?)
					table.insert(calls, "VentRail")
					return "Correct", Vector3.new(1, 2, 3)
				end,
			},
			{
				name = "Never",
				validator = function(): (Types.MovementVerdict, Vector3?)
					table.insert(calls, "Never")
					return "Strike", nil
				end,
			},
		}
		local verdict, safe, name = MovementAuthority.runValidators(list, player, root, 0.1)
		t.eq(verdict, "Correct")
		t.eq(safe, Vector3.new(1, 2, 3))
		t.eq(name, "VentRail")
		t.eq(table.concat(calls, ","), "Broken,Fine,VentRail")
		local okVerdict, okSafe = MovementAuthority.runValidators({ list[2] }, player, root, 0.1)
		t.eq(okVerdict, "Ok")
		t.eq(okSafe, nil)

		MovementAuthority.RegisterValidator("SpecA", list[2].validator)
		MovementAuthority.RegisterValidator("SpecB", list[2].validator)
		MovementAuthority.RegisterValidator("SpecA", list[3].validator)
		local names = table.concat(MovementAuthority.GetValidatorNames(), ",")
		t.truthy(string.find(names, "SpecA,SpecB", 1, true) ~= nil, "re-registering keeps the slot: " .. names)
		MovementAuthority.UnregisterValidator("SpecA")
		MovementAuthority.UnregisterValidator("SpecB")
		t.eq(string.find(table.concat(MovementAuthority.GetValidatorNames(), ","), "Spec", 1, true), nil)
		root:Destroy()
	end,

	["exemptions: tokens, timed and untimed"] = function(t: Expect)
		t.falsy(MovementAuthority.isExempt(nil, 10))
		t.truthy(MovementAuthority.isExempt({ cutscene = math.huge }, 10))
		t.truthy(MovementAuthority.isExempt({ vault = 12 }, 10))
		t.falsy(MovementAuthority.isExempt({ vault = 12 }, 12), "expired")
		t.truthy(MovementAuthority.isExempt({ vault = 9, cutscene = 30 }, 10), "any live token")
		local player = fakePlayer()
		t.falsy(MovementAuthority.IsExempt(player))
		MovementAuthority.Exempt(player, "cutscene")
		MovementAuthority.Exempt(player, "vault", 0)
		t.truthy(MovementAuthority.IsExempt(player))
		MovementAuthority.Unexempt(player, "cutscene")
		t.falsy(MovementAuthority.IsExempt(player), "the zero-second token already lapsed")
		MovementAuthority.Exempt(player, "long", 60)
		t.truthy(MovementAuthority.IsExempt(player))
		MovementAuthority.OnPlayerRemoving(player)
		t.falsy(MovementAuthority.IsExempt(player), "leaving clears exemptions")
		t.eq(MovementAuthority.GetStrikes(player), 0)
	end,
}
