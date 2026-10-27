--!strict
-- Small numeric helpers shared by cameras, animation, AI and audio.

local MathUtil = {}

local TAU = math.pi * 2

function MathUtil.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function MathUtil.inverseLerp(a: number, b: number, value: number): number
	if a == b then
		return 0
	end
	return (value - a) / (b - a)
end

function MathUtil.remap(value: number, inMin: number, inMax: number, outMin: number, outMax: number): number
	return MathUtil.lerp(outMin, outMax, MathUtil.inverseLerp(inMin, inMax, value))
end

function MathUtil.clamp01(value: number): number
	return math.clamp(value, 0, 1)
end

function MathUtil.remapClamped(value: number, inMin: number, inMax: number, outMin: number, outMax: number): number
	return MathUtil.lerp(outMin, outMax, MathUtil.clamp01(MathUtil.inverseLerp(inMin, inMax, value)))
end

function MathUtil.smoothstep(edge0: number, edge1: number, value: number): number
	local t = MathUtil.clamp01(MathUtil.inverseLerp(edge0, edge1, value))
	return t * t * (3 - 2 * t)
end

-- Frame-rate independent exponential approach: the fraction of the remaining distance to cover this frame.
function MathUtil.damp(speed: number, dt: number): number
	return 1 - math.exp(-speed * dt)
end

function MathUtil.dampNumber(current: number, target: number, speed: number, dt: number): number
	return MathUtil.lerp(current, target, MathUtil.damp(speed, dt))
end

-- Moves `current` toward `target` by at most `maxDelta`.
function MathUtil.approach(current: number, target: number, maxDelta: number): number
	if current < target then
		return math.min(current + maxDelta, target)
	end
	return math.max(current - maxDelta, target)
end

function MathUtil.wrapAngle(radians: number): number
	local wrapped = (radians + math.pi) % TAU
	return wrapped - math.pi
end

function MathUtil.angleDelta(from: number, to: number): number
	return MathUtil.wrapAngle(to - from)
end

function MathUtil.round(value: number, step: number): number
	return math.round(value / step) * step
end

-- Angles travel as int16 (LookRelay): radians in [-pi, pi] <-> [-32767, 32767].
function MathUtil.quantizeAngle(radians: number): number
	return math.clamp(math.round(MathUtil.wrapAngle(radians) / math.pi * 32767), -32767, 32767)
end

function MathUtil.dequantizeAngle(value: number): number
	return math.clamp(value, -32767, 32767) / 32767 * math.pi
end

function MathUtil.flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function MathUtil.horizontalDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

function MathUtil.isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function MathUtil.isFiniteVector(v: Vector3): boolean
	return MathUtil.isFinite(v.X) and MathUtil.isFinite(v.Y) and MathUtil.isFinite(v.Z)
end

-- Yaw and pitch (radians) of a look direction. Yaw 0 looks down -Z, matching CFrame.lookAt.
function MathUtil.yawPitchFromVector(direction: Vector3): (number, number)
	local unit = if direction.Magnitude > 1e-6 then direction.Unit else Vector3.new(0, 0, -1)
	local yaw = math.atan2(-unit.X, -unit.Z)
	local pitch = math.asin(math.clamp(unit.Y, -1, 1))
	return yaw, pitch
end

function MathUtil.vectorFromYawPitch(yaw: number, pitch: number): Vector3
	local cosPitch = math.cos(pitch)
	return Vector3.new(-math.sin(yaw) * cosPitch, math.sin(pitch), -math.cos(yaw) * cosPitch)
end

-- Exact 32-bit FNV-1a hash of a string (offset basis 2166136261, prime 16777619), for seeding per-entity Random
-- streams. A plain `hash * 16777619` reaches 2^56 and the double rounds its low bits away, so the multiply is split
-- along the prime's bits (2^24 + 2^8 + 0x93): every partial product stays below 2^53 and the result is exact.
function MathUtil.hash(text: string): number
	local hash = 2166136261
	for i = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, i))
		hash = (bit32.lshift(hash, 24) + bit32.lshift(hash, 8) + hash * 0x93) % 4294967296
	end
	return hash
end

-- A Random stream unique to (seed, key): same inputs give the same sequence on every machine.
function MathUtil.seededRandom(seed: number, key: string): Random
	return Random.new(bit32.bxor(math.floor(seed) % 4294967296, MathUtil.hash(key)))
end

-- Fisher-Yates shuffle in place using the given Random.
function MathUtil.shuffle<T>(list: { T }, random: Random): { T }
	for i = #list, 2, -1 do
		local j = random:NextInteger(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

-- Smooth value noise in [-1, 1] for flicker and sway (cheap, deterministic, no allocations).
function MathUtil.noise1(t: number, seed: number): number
	return math.noise(t, seed * 0.137, 0.5) * 2
end

return table.freeze(MathUtil)
