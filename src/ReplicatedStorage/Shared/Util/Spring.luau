--!strict
-- Damped springs for camera motion and procedural animation. `speed` is angular frequency (rad/s);
-- `damping` 1 is critical. Steps are frame-rate independent (analytic critically/under-damped solution).

export type NumberSpring = {
	position: number,
	velocity: number,
	target: number,
	speed: number,
	damping: number,
	step: (self: NumberSpring, dt: number) -> number,
	impulse: (self: NumberSpring, velocity: number) -> (),
	reset: (self: NumberSpring, value: number) -> (),
}

export type VectorSpring = {
	position: Vector3,
	velocity: Vector3,
	target: Vector3,
	speed: number,
	damping: number,
	step: (self: VectorSpring, dt: number) -> Vector3,
	impulse: (self: VectorSpring, velocity: Vector3) -> (),
	reset: (self: VectorSpring, value: Vector3) -> (),
}

local Spring = {}

-- One damped-harmonic step for a single axis. Returns new offset (relative to target) and velocity.
local function solve(offset: number, velocity: number, speed: number, damping: number, dt: number): (number, number)
	if speed <= 0 then
		return offset, velocity
	end
	local w = speed
	if damping >= 1 then
		-- Critically (or over-) damped: treat as critical for stability.
		local decay = math.exp(-w * dt)
		local c1 = offset
		local c2 = velocity + w * offset
		local newOffset = (c1 + c2 * dt) * decay
		local newVelocity = (c2 - w * (c1 + c2 * dt)) * decay
		return newOffset, newVelocity
	end
	local wd = w * math.sqrt(1 - damping * damping)
	local decay = math.exp(-damping * w * dt)
	local cosT = math.cos(wd * dt)
	local sinT = math.sin(wd * dt)
	local c1 = offset
	local c2 = (velocity + damping * w * offset) / wd
	local newOffset = decay * (c1 * cosT + c2 * sinT)
	local newVelocity = decay * ((c2 * wd - damping * w * c1) * cosT - (c1 * wd + damping * w * c2) * sinT)
	return newOffset, newVelocity
end

function Spring.number(initial: number, speed: number, damping: number): NumberSpring
	local spring: NumberSpring = {
		position = initial,
		velocity = 0,
		target = initial,
		speed = speed,
		damping = damping,
		step = function(self: NumberSpring, dt: number): number
			local offset, velocity = solve(self.position - self.target, self.velocity, self.speed, self.damping, dt)
			self.position = self.target + offset
			self.velocity = velocity
			return self.position
		end,
		impulse = function(self: NumberSpring, velocity: number)
			self.velocity += velocity
		end,
		reset = function(self: NumberSpring, value: number)
			self.position = value
			self.target = value
			self.velocity = 0
		end,
	}
	return spring
end

function Spring.vector(initial: Vector3, speed: number, damping: number): VectorSpring
	local spring: VectorSpring = {
		position = initial,
		velocity = Vector3.zero,
		target = initial,
		speed = speed,
		damping = damping,
		step = function(self: VectorSpring, dt: number): Vector3
			local offset = self.position - self.target
			local ox, vx = solve(offset.X, self.velocity.X, self.speed, self.damping, dt)
			local oy, vy = solve(offset.Y, self.velocity.Y, self.speed, self.damping, dt)
			local oz, vz = solve(offset.Z, self.velocity.Z, self.speed, self.damping, dt)
			self.position = self.target + Vector3.new(ox, oy, oz)
			self.velocity = Vector3.new(vx, vy, vz)
			return self.position
		end,
		impulse = function(self: VectorSpring, velocity: Vector3)
			self.velocity += velocity
		end,
		reset = function(self: VectorSpring, value: Vector3)
			self.position = value
			self.target = value
			self.velocity = Vector3.zero
		end,
	}
	return spring
end

return table.freeze(Spring)
