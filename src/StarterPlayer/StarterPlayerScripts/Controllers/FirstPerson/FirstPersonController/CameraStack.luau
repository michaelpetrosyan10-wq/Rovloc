--!strict
-- CameraStack: priority camera overrides blended over the first-person base view.
--
-- Priority (low to high): base < Trapped < Struggle < Spectating < Jumpscare < Cutscene. Each pushed override
-- supplies a CFrame function (called once per frame while it has any weight), an optional FOV and blend-in /
-- blend-out times. Its weight ramps 0 -> 1 linearly over blendIn while pushed and back to 0 over blendOut after
-- PopOverride (a zero time switches instantly); the layer leaves the stack once it has fully blended out.
--
-- Composition walks the layers in ascending priority, pulling the running result toward each layer by its eased
-- weight (smoothstep): result = lerp(result, layer, ease(w)). A fully blended layer therefore replaces everything
-- below it, so the highest active override wins outright, and while a higher layer blends in or out the one below
-- shows through instead of the base. FOV follows the same rule; a layer without an FOV keeps the FOV below it.
-- Pushing a kind that is already on the stack swaps its source in place and keeps its current weight (a re-push
-- during a blend-out blends back in from where it is). A source whose CFrame function throws is skipped for that
-- frame (logged, throttled) rather than breaking the camera.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local log = Log.new("CameraStack")

export type Source = {
	cframe: () -> CFrame,
	fov: number?,
	blendIn: number?, -- seconds (default DefaultBlendIn)
	blendOut: number?, -- seconds (default DefaultBlendOut)
}

-- One evaluated layer for blend(): its frame this frame, optional FOV, and linear weight 0..1.
export type Sample = { cframe: CFrame, fov: number?, weight: number }

type Layer = {
	kind: Enums.CameraOverride,
	priority: number,
	source: Source,
	weight: number,
	active: boolean,
}

export type Stack = {
	Push: (self: Stack, kind: Enums.CameraOverride, source: Source) -> (),
	Pop: (self: Stack, kind: Enums.CameraOverride) -> (),
	Clear: (self: Stack, instant: boolean?) -> (),
	Step: (self: Stack, dt: number) -> (),
	Evaluate: (self: Stack, base: CFrame, baseFov: number) -> (CFrame, number),
	Top: (self: Stack) -> Enums.CameraOverride?,
	Weight: (self: Stack, kind: Enums.CameraOverride) -> number,
	IsActive: (self: Stack, kind: Enums.CameraOverride) -> boolean,
	Coverage: (self: Stack) -> number,
}

local CameraStack = {}

CameraStack.DefaultBlendIn = 0.35
CameraStack.DefaultBlendOut = 0.5

CameraStack.Priority = table.freeze({
	Trapped = 1,
	Struggle = 2,
	Spectating = 3,
	Jumpscare = 4,
	Cutscene = 5,
} :: { [string]: number })

-- Weight after `dt` seconds of blending toward 1 (active) or 0 (popped).
function CameraStack.stepWeight(weight: number, active: boolean, blendIn: number, blendOut: number, dt: number): number
	if active then
		if blendIn <= 0 then
			return 1
		end
		return math.min(1, weight + dt / blendIn)
	end
	if blendOut <= 0 then
		return 0
	end
	return math.max(0, weight - dt / blendOut)
end

-- The eased share a layer takes of the view below it.
function CameraStack.ease(weight: number): number
	return MathUtil.smoothstep(0, 1, weight)
end

-- Composes `samples` (ascending priority) over the base frame and FOV.
function CameraStack.blend(base: CFrame, baseFov: number, samples: { Sample }): (CFrame, number)
	local cframe = base
	local fov = baseFov
	for _, sample in samples do
		local share = CameraStack.ease(sample.weight)
		if share <= 0 then
			continue
		end
		local layerFov = sample.fov
		if share >= 1 then
			cframe = sample.cframe
			if layerFov then
				fov = layerFov
			end
		else
			cframe = cframe:Lerp(sample.cframe, share)
			if layerFov then
				fov = MathUtil.lerp(fov, layerFov, share)
			end
		end
	end
	return cframe, fov
end

local function blendIn(source: Source): number
	local value = source.blendIn
	return if value ~= nil and value == value then math.max(0, value) else CameraStack.DefaultBlendIn
end

local function blendOut(source: Source): number
	local value = source.blendOut
	return if value ~= nil and value == value then math.max(0, value) else CameraStack.DefaultBlendOut
end

function CameraStack.new(): Stack
	local layers: { Layer } = {}

	local function find(kind: Enums.CameraOverride): Layer?
		for _, layer in layers do
			if layer.kind == kind then
				return layer
			end
		end
		return nil
	end

	local stack: Stack = {
		Push = function(_self: Stack, kind: Enums.CameraOverride, source: Source)
			local priority = CameraStack.Priority[kind]
			if priority == nil then
				log.warnThrottled("kind" .. tostring(kind), 30, "unknown camera override %s", tostring(kind))
				return
			end
			local existing = find(kind)
			if existing then
				existing.source = source
				existing.active = true
				return
			end
			table.insert(layers, { kind = kind, priority = priority, source = source, weight = 0, active = true })
			table.sort(layers, function(a: Layer, b: Layer): boolean
				return a.priority < b.priority
			end)
		end,
		Pop = function(_self: Stack, kind: Enums.CameraOverride)
			local existing = find(kind)
			if existing then
				existing.active = false
			end
		end,
		Clear = function(_self: Stack, instant: boolean?)
			if instant then
				table.clear(layers)
				return
			end
			for _, layer in layers do
				layer.active = false
			end
		end,
		Step = function(_self: Stack, dt: number)
			for index = #layers, 1, -1 do
				local layer = layers[index]
				layer.weight = CameraStack.stepWeight(
					layer.weight,
					layer.active,
					blendIn(layer.source),
					blendOut(layer.source),
					dt
				)
				if not layer.active and layer.weight <= 0 then
					table.remove(layers, index)
				end
			end
		end,
		Evaluate = function(_self: Stack, base: CFrame, baseFov: number): (CFrame, number)
			if #layers == 0 then
				return base, baseFov
			end
			local samples: { Sample } = {}
			for _, layer in layers do
				if layer.weight <= 0 then
					continue
				end
				local ok, result = pcall(layer.source.cframe)
				if ok and typeof(result) == "CFrame" then
					local fov = layer.source.fov
					table.insert(samples, {
						cframe = result,
						fov = if fov ~= nil and fov == fov then math.clamp(fov, 1, 120) else nil,
						weight = layer.weight,
					})
				else
					log.warnThrottled(
						"source" .. layer.kind,
						10,
						"%s override source failed: %s",
						layer.kind,
						tostring(result)
					)
				end
			end
			return CameraStack.blend(base, baseFov, samples)
		end,
		Top = function(_self: Stack): Enums.CameraOverride?
			for index = #layers, 1, -1 do
				local layer = layers[index]
				if layer.active then
					return layer.kind
				end
			end
			return nil
		end,
		Weight = function(_self: Stack, kind: Enums.CameraOverride): number
			local layer = find(kind)
			return if layer then layer.weight else 0
		end,
		IsActive = function(_self: Stack, kind: Enums.CameraOverride): boolean
			local layer = find(kind)
			return layer ~= nil and layer.active
		end,
		-- How much of the final view the overrides own (0 = pure base view, 1 = fully overridden).
		Coverage = function(_self: Stack): number
			local base = 1
			for _, layer in layers do
				base *= 1 - CameraStack.ease(layer.weight)
			end
			return 1 - base
		end,
	}
	return stack
end

return table.freeze(CameraStack)
