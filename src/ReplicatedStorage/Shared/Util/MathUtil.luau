--!strict
-- Small numeric helpers shared by cameras, animation, AI and audio, and the colour and interpolation maths of
-- whatever builds the world (lerpColor .. fromHSV: Luau's own doubles, the same bits on every platform).

local MathUtil = {}

local TAU = math.pi * 2

-- `a` toward `b` by `t`, exact at both ends (Luau's math.lerp: `b` itself at 1, where a + (b - a) may round).
function MathUtil.lerp(a: number, b: number, t: number): number
	if t == 1 then
		return b
	end
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

-- `color` as a part stores it: Roblox keeps BasePart.Color as Color3uint8, so each channel goes to the nearest 1/255
-- (clamped to 0..1). A colour already on that grid is stored exactly by the engine, kept exactly by Lune's floats and
-- baked to the same byte by the web, so it reads back the same on every platform.
function MathUtil.color8(color: Color3): Color3
	return Color3.fromRGB(
		math.clamp(math.round(color.R * 255), 0, 255),
		math.clamp(math.round(color.G * 255), 0, 255),
		math.clamp(math.round(color.B * 255), 0, 255)
	)
end

-- World maths in Luau's doubles. The engine's Lerp and HSV methods work in float32 the way each engine does: Lune's
-- Lerp computes a * (1 - t) + b * t, so a channel lerped to its own value comes back off it and a .5 tie can round
-- to the other byte, and one ulp flips a part colour on the 8-bit grid (or a point onto the other side of a seam).
-- These compute in doubles and store once (the constructor rounds a double to float32 the same way everywhere), so
-- Lune, every Roblox server and every client get the same bits. World code never calls the engine's (the lint in
-- tests/Specs/WorldDeterminism.spec refuses them).

-- `a` toward `b` by `t`, channel by channel (what Color3:Lerp means).
function MathUtil.lerpColor(a: Color3, b: Color3, t: number): Color3
	return Color3.new(MathUtil.lerp(a.R, b.R, t), MathUtil.lerp(a.G, b.G, t), MathUtil.lerp(a.B, b.B, t))
end

-- `a` toward `b` by `t`, component by component (what Vector2:Lerp and Vector3:Lerp mean).
function MathUtil.lerpVector2(a: Vector2, b: Vector2, t: number): Vector2
	return Vector2.new(MathUtil.lerp(a.X, b.X, t), MathUtil.lerp(a.Y, b.Y, t))
end

function MathUtil.lerpVector3(a: Vector3, b: Vector3, t: number): Vector3
	return Vector3.new(MathUtil.lerp(a.X, b.X, t), MathUtil.lerp(a.Y, b.Y, t), MathUtil.lerp(a.Z, b.Z, t))
end

local function unitQuaternion(w: number, x: number, y: number, z: number): (number, number, number, number)
	local length = math.sqrt(w * w + x * x + y * y + z * z)
	return w / length, x / length, y / length, z / length
end

-- The unit quaternion (w, x, y, z) of a rotation given by its matrix rows, from its largest component (Shoemake).
local function quaternion(
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number
): (number, number, number, number)
	local trace = r00 + r11 + r22
	if trace > 0 then
		local s = math.sqrt(trace + 1) * 2
		return unitQuaternion(s / 4, (r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s)
	elseif r00 > r11 and r00 > r22 then
		local s = math.sqrt(1 + r00 - r11 - r22) * 2
		return unitQuaternion((r21 - r12) / s, s / 4, (r01 + r10) / s, (r02 + r20) / s)
	elseif r11 > r22 then
		local s = math.sqrt(1 + r11 - r00 - r22) * 2
		return unitQuaternion((r02 - r20) / s, (r01 + r10) / s, s / 4, (r12 + r21) / s)
	end
	local s = math.sqrt(1 + r22 - r00 - r11) * 2
	return unitQuaternion((r10 - r01) / s, (r02 + r20) / s, (r12 + r21) / s, s / 4)
end

-- `a` toward `b` by `t` the way CFrame:Lerp moves it: the position along the straight line, the rotation along the
-- shorter great arc (slerp; straight when the arc is tiny). `a` itself at 0 and `b` at 1.
function MathUtil.lerpCFrame(a: CFrame, b: CFrame, t: number): CFrame
	if t == 0 then
		return a
	elseif t == 1 then
		return b
	end
	local ax, ay, az, a00, a01, a02, a10, a11, a12, a20, a21, a22 = a:GetComponents()
	local bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22 = b:GetComponents()
	local aw, ai, aj, ak = quaternion(a00, a01, a02, a10, a11, a12, a20, a21, a22)
	local bw, bi, bj, bk = quaternion(b00, b01, b02, b10, b11, b12, b20, b21, b22)
	local cos = aw * bw + ai * bi + aj * bj + ak * bk
	if cos < 0 then
		bw, bi, bj, bk, cos = -bw, -bi, -bj, -bk, -cos
	end
	local fromA, fromB = 1 - t, t
	if cos < 1 - 1e-6 then
		local angle = math.acos(cos)
		local sin = math.sin(angle)
		fromA, fromB = math.sin((1 - t) * angle) / sin, math.sin(t * angle) / sin
	end
	local w, i, j, k = unitQuaternion(
		fromA * aw + fromB * bw,
		fromA * ai + fromB * bi,
		fromA * aj + fromB * bj,
		fromA * ak + fromB * bk
	)
	return CFrame.new(
		MathUtil.lerp(ax, bx, t),
		MathUtil.lerp(ay, by, t),
		MathUtil.lerp(az, bz, t),
		1 - 2 * (j * j + k * k),
		2 * (i * j - w * k),
		2 * (i * k + w * j),
		2 * (i * j + w * k),
		1 - 2 * (i * i + k * k),
		2 * (j * k - w * i),
		2 * (i * k - w * j),
		2 * (j * k + w * i),
		1 - 2 * (i * i + j * j)
	)
end

-- Hue, saturation and value of `color`, each 0..1 (a grey's hue is 0): what Color3:ToHSV gives.
function MathUtil.toHSV(color: Color3): (number, number, number)
	local r, g, b = color.R, color.G, color.B
	local high = math.max(r, g, b)
	local span = high - math.min(r, g, b)
	local saturation = if high > 0 then span / high else 0
	if span <= 0 then
		return 0, saturation, high
	end
	local sector: number
	if high == r then
		sector = (g - b) / span
		if sector < 0 then
			sector += 6
		end
	elseif high == g then
		sector = (b - r) / span + 2
	else
		sector = (r - g) / span + 4
	end
	return sector / 6, saturation, high
end

-- The colour of hue `h` (wrapped into 0..1), saturation `s` and value `v`: what Color3.fromHSV builds.
function MathUtil.fromHSV(h: number, s: number, v: number): Color3
	local sector = (h % 1) * 6
	local index = math.floor(sector)
	local f = sector - index
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	if index == 0 then
		return Color3.new(v, t, p)
	elseif index == 1 then
		return Color3.new(q, v, p)
	elseif index == 2 then
		return Color3.new(p, v, t)
	elseif index == 3 then
		return Color3.new(p, q, v)
	elseif index == 4 then
		return Color3.new(t, p, v)
	end
	return Color3.new(v, p, q)
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

-- Exact 32-bit FNV-1a hash of a string (offset basis 2166136261, prime 16777619), for seeding per-entity streams
-- (Rng.seeded, seededRandom). A plain `hash * 16777619` reaches 2^56 and the double rounds its low bits away, so the
-- multiply is split along the prime's bits (2^24 + 2^8 + 0x93): every partial product stays below 2^53 and the result
-- is exact.
function MathUtil.hash(text: string): number
	local hash = 2166136261
	for i = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, i))
		hash = (bit32.lshift(hash, 24) + bit32.lshift(hash, 8) + hash * 0x93) % 4294967296
	end
	return hash
end

-- An engine Random stream unique to (seed, key), for the runtime's own randomness (pacing, beats, spawns): the same
-- inputs give the same sequence on every Roblox machine, but not in Lune or on the web. Whatever builds or plans the
-- world draws from Util/Rng instead (Rng.seeded: the same key scheme, the same numbers on every platform).
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
