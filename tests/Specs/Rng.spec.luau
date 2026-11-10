--!strict
-- Rng: the world's portable random streams. Golden values from an independent C reference of xoshiro128** seeded by
-- SplitMix32 (the same numbers web/tools/data-test.mjs pins for the web's port) fix the algorithm, the seeding, the
-- unit mapping, the unbiased integer mapping (with redraws) and the shuffle; the keyed stream is the seed xor
-- MathUtil.hash(key); bad bounds and seeds are refused; streams never share state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Rng = require(ReplicatedStorage.Shared.Util.Rng)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local MAX32 = 4294967295

local function raw(random: Rng.Rng, count: number): { number }
	local out: { number } = {}
	for i = 1, count do
		out[i] = random:NextInteger(0, MAX32)
	end
	return out
end

local function expectList(t: Expect, actual: { number }, expected: { number }, label: string)
	t.eq(#actual, #expected, label .. ": count")
	for i, value in expected do
		t.eq(actual[i], value, string.format("%s[%d]", label, i))
	end
end

return {
	["golden: the first raw draws of fixed seeds"] = function(t: Expect)
		expectList(t, raw(Rng.new(0), 8), {
			3809008728,
			1133695204,
			53579671,
			2891528803,
			139681546,
			2203266335,
			104831812,
			1587294886,
		}, "new(0)")
		expectList(t, raw(Rng.new(1), 8), {
			2442144158,
			3238099751,
			3819917871,
			2104621829,
			2021136066,
			4223536128,
			1515984730,
			2298887649,
		}, "new(1)")
		expectList(t, raw(Rng.new(MAX32), 8), {
			835879718,
			1921286648,
			2356205009,
			1885780724,
			980451116,
			1053911718,
			3677392737,
			2464361898,
		}, "new(2^32 - 1)")
	end,

	["golden: a keyed stream is the seed xor the key's FNV-1a"] = function(t: Expect)
		t.eq(MathUtil.hash("Objective|Level0_Basement"), 21198310, "FNV-1a of the key")
		local expected = {
			2975473077,
			76520769,
			278978910,
			4012111892,
			1972213258,
			2943740582,
			3088457692,
			2273335167,
		}
		expectList(t, raw(Rng.seeded(20251029, "Objective|Level0_Basement"), 8), expected, "seeded")
		expectList(t, raw(Rng.new(bit32.bxor(20251029, 21198310)), 8), expected, "new(seed xor hash)")
		-- the seed is floored and taken mod 2^32 first
		expectList(t, raw(Rng.seeded(20251029.75, "Objective|Level0_Basement"), 8), expected, "a fractional seed")
		expectList(t, raw(Rng.new(-1), 4), raw(Rng.new(MAX32), 4), "-1 is 2^32 - 1")
		expectList(t, raw(Rng.new(2 ^ 32 + 1), 4), raw(Rng.new(1), 4), "2^32 + 1 is 1")
	end,

	["golden: NextNumber is one draw over 2^32, exactly"] = function(t: Expect)
		local random = Rng.new(12345)
		for i, value in
			{
				0.12076167785562575,
				0.10254896758124232,
				0.98554719984531403,
				0.87494440888985991,
				0.91712428559549153,
				0.31075522652827203,
			}
		do
			t.eq(random:NextNumber(), value, "NextNumber " .. i)
		end
		random = Rng.new(12345)
		for i, value in { -2.033906577154994, -2.1796082593500614, 4.8843775987625122, 3.9995552711188793 } do
			t.eq(random:NextNumber(-3, 5), value, "NextNumber(-3, 5) " .. i)
		end
	end,

	["golden: NextInteger is unbiased, redrawing past the last whole range"] = function(t: Expect)
		local random = Rng.new(42)
		local rolls: { number } = {}
		for i = 1, 12 do
			rolls[i] = random:NextInteger(1, 6)
		end
		expectList(t, rolls, { 1, 2, 3, 1, 1, 1, 5, 5, 1, 3, 4, 5 }, "NextInteger(1, 6)")
		-- a range of 3 x 2^30: a quarter of the draws are redrawn (six of these twelve took a second draw)
		random = Rng.new(42)
		local wide: { number } = {}
		for i = 1, 12 do
			wide[i] = random:NextInteger(0, 3221225471)
		end
		expectList(t, wide, {
			2837322924,
			544945897,
			479756282,
			339756180,
			113173290,
			65323186,
			1112262688,
			1395801302,
			787581093,
			2038421698,
			2132581468,
			3088945547,
		}, "NextInteger(0, 3 x 2^30 - 1)")
		random = Rng.new(99)
		local signed: { number } = {}
		for i = 1, 10 do
			signed[i] = random:NextInteger(-5, 5)
		end
		expectList(t, signed, { 2, 0, 3, -5, 5, -2, 0, -2, -1, -4 }, "NextInteger(-5, 5)")
		random = Rng.new(2026)
		local big: { number } = {}
		for i = 1, 4 do
			big[i] = random:NextInteger(1, 2000000000)
		end
		expectList(t, big, { 1436751615, 742089594, 1736781945, 1312845264 }, "NextInteger(1, 2e9)")
		t.eq(Rng.new(5):NextInteger(7, 7), 7, "a one-value range")
	end,

	["golden: the shuffle"] = function(t: Expect)
		local list = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
		t.eq(Rng.shuffle(list, Rng.new(7)), list, "shuffles in place and returns the list")
		expectList(t, list, { 4, 10, 7, 6, 5, 8, 3, 2, 9, 1 }, "shuffle of 1..10")
	end,

	["refuses bad bounds and seeds"] = function(t: Expect)
		local random = Rng.new(1)
		t.throws(function()
			random:NextInteger(1, 2.5)
		end, "a fractional bound")
		t.throws(function()
			random:NextInteger(3, 2)
		end, "min > max")
		t.throws(function()
			random:NextInteger(0, 2 ^ 32)
		end, "more than 2^32 values")
		t.throws(function()
			random:NextNumber(1)
		end, "one bound of two")
		t.throws(function()
			Rng.new(0 / 0)
		end, "a NaN seed")
		t.throws(function()
			Rng.seeded(math.huge, "key")
		end, "an infinite seed")
	end,

	["streams are independent and in range"] = function(t: Expect)
		local a, b = Rng.seeded(7, "a"), Rng.seeded(7, "a")
		local other = Rng.seeded(7, "b")
		local same, differs = true, false
		for _ = 1, 1000 do
			local x = a:NextNumber()
			t.truthy(x >= 0 and x < 1, "NextNumber in [0, 1)")
			if x ~= b:NextNumber() then
				same = false
			end
			if x ~= other:NextNumber() then
				differs = true
			end
			local n = a:NextInteger(-3, 3)
			t.truthy(n >= -3 and n <= 3 and n == math.floor(n), "NextInteger in range")
			b:NextInteger(-3, 3)
			other:NextInteger(-3, 3)
		end
		t.truthy(same, "the same seed and key give the same stream")
		t.truthy(differs, "another key gives another stream")
		-- neighbouring seeds start uncorrelated (SplitMix32 seeding): the first draws of seeds 1..64 differ in about
		-- half their bits from their neighbour's
		local flips = 0
		local previous = Rng.new(0):NextInteger(0, MAX32)
		for seed = 1, 64 do
			local first = Rng.new(seed):NextInteger(0, MAX32)
			local x = bit32.bxor(first, previous)
			while x ~= 0 do
				flips += bit32.band(x, 1)
				x = bit32.rshift(x, 1)
			end
			previous = first
		end
		t.truthy(flips > 64 * 12 and flips < 64 * 20, string.format("%.1f bits of 32 flip", flips / 64))
	end,
}
