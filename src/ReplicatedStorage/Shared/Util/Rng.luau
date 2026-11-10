--!strict
-- Rng: the world's random streams, the same numbers on every platform. A pure-Luau xoshiro128** (Blackman and Vigna)
-- seeded by SplitMix32 (the murmur3 finaliser over a Weyl sequence, so neighbouring seeds start uncorrelated). Every
-- step is exact 32-bit integer maths on doubles and bit32, so the web export (Lune), every Roblox server and client and
-- the web runtime's port (web/src/game/util.js: Math.imul and >>> 0) draw identical numbers from an identical seed,
-- bit for bit. The engine's Random cannot promise that (its algorithm and range mapping are the engine's own, and Lune
-- has none), so everything that builds or plans the world draws from these streams: the world builder, the layouts
-- and TunnelPlanner, and RunDirector. Never Random.new, math.random or math.noise there
-- (tests/Specs/WorldDeterminism.spec.luau lints it).
--
--   local random = Rng.seeded(seed, "L0:dress")   the stream of (seed, key): floor(seed) mod 2^32 xor FNV-1a(key)
--   random:NextNumber()                           [0, 1): one 32-bit draw / 2^32
--   random:NextNumber(min, max)                   min + (max - min) * NextNumber()
--   random:NextInteger(min, max)                  uniform over the integers min..max (integer bounds, at most 2^32
--                                                 values), unbiased: a draw at or past the last whole multiple of the
--                                                 range below 2^32 is drawn again; then min + draw mod range
--   Rng.shuffle(list, random)                     Fisher-Yates in place: i = #list down to 2 swaps with
--                                                 NextInteger(1, i)
--
-- tests/Specs/Rng.spec.luau and web/tools/data-test.mjs pin golden values (from an independent C reference), so any
-- drift of either implementation fails its gate.

local MathUtil = require(script.Parent.MathUtil)

local TWO16 = 65536
local TWO32 = 4294967296
local GOLDEN = 0x9E3779B9 -- the Weyl increment of SplitMix32
local MIX1 = 0x85EBCA6B
local MIX2 = 0xC2B2AE35

export type Rng = {
	NextNumber: (self: Rng, min: number?, max: number?) -> number,
	NextInteger: (self: Rng, min: number, max: number) -> number,
}

type State = { s0: number, s1: number, s2: number, s3: number }

local Rng = {}

-- a * b mod 2^32 for a, b in [0, 2^32): a is split into 16-bit halves, so every partial product stays below 2^53 and
-- the double arithmetic is exact (Math.imul in the JS port).
local function mul32(a: number, b: number): number
	local low = a % TWO16
	local high = (a - low) / TWO16
	return ((high * b) % TWO16 * TWO16 + low * b) % TWO32
end

-- The murmur3 finaliser: a bijection of [0, 2^32) with full avalanche.
local function fmix32(x: number): number
	local t = mul32(bit32.bxor(x, bit32.rshift(x, 16)), MIX1)
	t = mul32(bit32.bxor(t, bit32.rshift(t, 13)), MIX2)
	return bit32.bxor(t, bit32.rshift(t, 16))
end

-- One xoshiro128** step: the next 32-bit output in [0, 2^32).
local function step(state: State): number
	local s0, s1, s2, s3 = state.s0, state.s1, state.s2, state.s3
	local result = (bit32.lrotate((s1 * 5) % TWO32, 7) * 9) % TWO32
	local t = bit32.lshift(s1, 9)
	s2 = bit32.bxor(s2, s0)
	s3 = bit32.bxor(s3, s1)
	s1 = bit32.bxor(s1, s2)
	s0 = bit32.bxor(s0, s3)
	s2 = bit32.bxor(s2, t)
	s3 = bit32.lrotate(s3, 11)
	state.s0, state.s1, state.s2, state.s3 = s0, s1, s2, s3
	return result
end

local Methods = {}
Methods.__index = Methods

function Methods.NextNumber(self: State, min: number?, max: number?): number
	local unit = step(self) / TWO32
	if min == nil and max == nil then
		return unit
	end
	if min == nil or max == nil then
		error("Rng:NextNumber takes no bounds or both", 2)
	end
	return min + (max - min) * unit
end

function Methods.NextInteger(self: State, min: number, max: number): number
	local range = max - min + 1
	if not (min == math.floor(min) and max == math.floor(max) and range >= 1 and range <= TWO32) then
		error(
			string.format(
				"Rng:NextInteger(%s, %s) needs integer bounds, min <= max, at most 2^32 values",
				tostring(min),
				tostring(max)
			),
			2
		)
	end
	local limit = TWO32 - TWO32 % range
	local draw = step(self)
	while draw >= limit do
		draw = step(self)
	end
	return min + draw % range
end

table.freeze(Methods)

-- A stream from a finite seed (its floor, mod 2^32): the four state words are SplitMix32's first four outputs.
function Rng.new(seed: number): Rng
	if seed ~= seed or seed == math.huge or seed == -math.huge then
		error("Rng.new needs a finite seed, got " .. tostring(seed), 2)
	end
	local weyl = math.floor(seed) % TWO32
	local words = table.create(4, 0)
	for i = 1, 4 do
		weyl = (weyl + GOLDEN) % TWO32
		words[i] = fmix32(weyl)
	end
	local state: State = { s0 = words[1], s1 = words[2], s2 = words[3], s3 = words[4] }
	return (setmetatable(state, Methods) :: any) :: Rng
end

-- The stream unique to (seed, key): the same inputs give the same sequence on every machine and platform.
function Rng.seeded(seed: number, key: string): Rng
	if seed ~= seed or seed == math.huge or seed == -math.huge then
		error("Rng.seeded needs a finite seed, got " .. tostring(seed), 2)
	end
	return Rng.new(bit32.bxor(math.floor(seed) % TWO32, MathUtil.hash(key)))
end

-- Fisher-Yates shuffle of `list` in place (and returned): i from #list down to 2 swaps with NextInteger(1, i).
function Rng.shuffle<T>(list: { T }, random: Rng): { T }
	for i = #list, 2, -1 do
		local j = random:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

return table.freeze(Rng)
