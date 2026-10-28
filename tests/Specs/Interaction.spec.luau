--!strict
-- InteractionService's rules. Trigger acceptance: a timed prompt completes only for the actor of its own channel once
-- duration - LatencyTolerance has passed (late triggers are fine), an instant prompt needs no channel, and both then
-- pass the eligibility rules. Eligibility: out-of-play life states never qualify, range is MaxActivationDistance + 2,
-- the audience follows the host's OwnerUserId, Alive is the default life state and canUse widens or narrows it (and
-- runs only once everything else passed). Channels: one actor per host, release / expiry / tick cancellation reasons
-- in priority order, the per-player token bucket. Handlers: kind and filter matching, the first registration wins,
-- Register / Resolve / unregister round trip on hand-built hosts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local Tags = require(ReplicatedStorage.Shared.Tags)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Check = InteractionService.Check
type Handler = InteractionService.Handler

local W = Attributes.World

local ME = 501
local OTHER = 502
local TOLERANCE = InteractionService.LatencyTolerance

local DOWNED_AND_LOBBY: { Enums.LifeState } = { "Downed", "Lobby" }
local OUT_OF_PLAY: { Enums.LifeState } = { "Dead", "Spectating" }

-- An eligible Alive player standing 3 studs from a 7-stud prompt, holding a 2-second channel since t = 100, with
-- `overrides` applied and the `cleared` fields set to nil.
local function check(overrides: { [string]: any }?, cleared: { string }?): Check
	local base: Check = {
		userId = ME,
		lifeState = "Alive",
		distance = 3,
		maxDistance = 7,
		audience = "All",
		ownerUserId = nil,
		canUse = nil,
		now = 102,
		duration = 2,
		channelUserId = ME,
		channelStartedAt = 100,
	}
	if overrides then
		for key, value in overrides do
			(base :: any)[key] = value
		end
	end
	for _, key in (cleared or {}) :: { string } do
		(base :: any)[key] = nil
	end
	return base
end

local NO_CHANNEL = { "channelUserId", "channelStartedAt" }

local function verdict(ok: boolean, reason: string?): string
	return if ok then "ok" else tostring(reason)
end

local function host(name: string, tags: { string }, kind: Enums.PromptKind): (Model, ProximityPrompt)
	local model = Instance.new("Model")
	model.Name = name
	for _, tag in tags do
		model:AddTag(tag)
	end
	local base = Instance.new("Part")
	base.Name = "Base"
	base.Parent = model
	local point = Instance.new("Attachment")
	point.Name = "PromptPoint"
	point.Parent = base
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = kind
	prompt.Enabled = false
	prompt:SetAttribute(W.PromptKind, kind)
	prompt:SetAttribute(W.BaseHold, 0.25)
	prompt.Parent = point
	return model, prompt
end

local function handler(kind: Enums.PromptKind, filter: ((Instance, ProximityPrompt) -> boolean)?): Handler
	return {
		kind = kind,
		filter = filter,
		onComplete = function() end,
	}
end

local function tagged(tag: string): (Instance, ProximityPrompt) -> boolean
	return function(instance: Instance): boolean
		return instance:HasTag(tag)
	end
end

return {
	["acceptTrigger: a timed prompt completes for its own actor once the hold has run"] = function(t: Expect)
		t.eq(verdict(InteractionService.acceptTrigger(check())), "ok", "exactly on time")
		t.eq(verdict(InteractionService.acceptTrigger(check({ now = 130 }))), "ok", "late triggers still count")
		t.eq(
			verdict(InteractionService.acceptTrigger(check({ now = 102 - TOLERANCE + 0.01 }))),
			"ok",
			"inside the latency tolerance"
		)
		t.eq(
			verdict(InteractionService.acceptTrigger(check({ now = 102 - TOLERANCE - 0.01 }))),
			"TooEarly",
			"just outside the tolerance"
		)
		t.eq(verdict(InteractionService.acceptTrigger(check({ now = 100.4 }))), "TooEarly")
		t.eq(
			verdict(InteractionService.acceptTrigger(check(nil, NO_CHANNEL))),
			"NoChannel",
			"no channel on this prompt"
		)
		t.eq(verdict(InteractionService.acceptTrigger(check(nil, { "channelStartedAt" }))), "NoChannel")
		t.eq(verdict(InteractionService.acceptTrigger(check({ channelUserId = OTHER }))), "NotActor")
	end,

	["acceptTrigger: instant prompts need no channel, only eligibility"] = function(t: Expect)
		local instant = check({ duration = 0, now = 0 }, NO_CHANNEL)
		t.eq(verdict(InteractionService.acceptTrigger(instant)), "ok")
		local far = check({ duration = 0, distance = 40 }, NO_CHANNEL)
		t.eq(verdict(InteractionService.acceptTrigger(far)), "OutOfRange")
	end,

	["eligibility: range is MaxActivationDistance plus the slack; no living character never reaches"] = function(
		t: Expect
	)
		local slack = InteractionService.RangeSlack
		t.eq(slack, 2)
		t.truthy(InteractionService.inRange(7 + slack, 7), "on the slack boundary")
		t.falsy(InteractionService.inRange(7 + slack + 0.01, 7), "past the slack")
		t.falsy(InteractionService.inRange(nil, 7), "no character")
		t.falsy(InteractionService.inRange(0 / 0, 7), "NaN distance")
		t.eq(verdict(InteractionService.eligible(check({ distance = 9.5 }))), "OutOfRange")
		t.eq(verdict(InteractionService.eligible(check(nil, { "distance" }))), "OutOfRange", "no character")
	end,

	["eligibility: Alive by default, canUse widens and narrows, Dead and Spectating never"] = function(t: Expect)
		t.eq(verdict(InteractionService.eligible(check())), "ok")
		for _, state: Enums.LifeState in DOWNED_AND_LOBBY do
			t.eq(
				verdict(InteractionService.eligible(check({ lifeState = state }))),
				"LifeState",
				state .. " by default"
			)
			local widened = check({
				lifeState = state,
				canUse = function(): (boolean, string?)
					return true, nil
				end,
			})
			t.eq(verdict(InteractionService.eligible(widened)), "ok", state .. " widened by canUse")
		end
		for _, state: Enums.LifeState in OUT_OF_PLAY do
			local insisting = check({
				lifeState = state,
				canUse = function(): (boolean, string?)
					return true, nil
				end,
			})
			t.eq(verdict(InteractionService.eligible(insisting)), "LifeState", state .. " is out of play")
		end
		local narrowed = check({
			canUse = function(): (boolean, string?)
				return false, "Prompt.GrateLocked"
			end,
		})
		t.eq(verdict(InteractionService.eligible(narrowed)), "Prompt.GrateLocked", "canUse's reason comes back")
		local silent = check({
			canUse = function(): (boolean, string?)
				return false, nil
			end,
		})
		t.eq(verdict(InteractionService.eligible(silent)), "Refused")
	end,

	["eligibility: canUse runs only after range, audience and life state passed"] = function(t: Expect)
		local calls = 0
		local function counting(): (boolean, string?)
			calls += 1
			return true, nil
		end
		InteractionService.eligible(check({ distance = 50, canUse = counting }))
		InteractionService.eligible(check({ audience = "Self", ownerUserId = OTHER, canUse = counting }))
		InteractionService.eligible(check({ lifeState = "Dead", canUse = counting }))
		t.eq(calls, 0, "refused before canUse")
		InteractionService.eligible(check({ canUse = counting }))
		t.eq(calls, 1)
	end,

	["audience: Self is the owner only, Others everyone but the owner, All everyone"] = function(t: Expect)
		local includes = InteractionService.audienceIncludes
		t.truthy(includes("All", nil, ME))
		t.truthy(includes("All", ME, ME))
		t.truthy(includes("Self", ME, ME))
		t.falsy(includes("Self", OTHER, ME))
		t.falsy(includes("Self", nil, ME), "an unowned Self prompt serves nobody")
		t.falsy(includes("Others", ME, ME))
		t.truthy(includes("Others", OTHER, ME))
		t.truthy(includes("Others", nil, ME), "an unowned Others prompt serves everyone")
		t.eq(verdict(InteractionService.eligible(check({ audience = "Self", ownerUserId = OTHER }))), "Audience")
		t.eq(verdict(InteractionService.eligible(check({ audience = "Others", ownerUserId = ME }))), "Audience")
		t.eq(verdict(InteractionService.eligible(check({ audience = "Self", ownerUserId = ME }))), "ok")
	end,

	["acceptBegin: one actor per host; instant prompts open no channel"] = function(t: Expect)
		local fresh = check(nil, NO_CHANNEL)
		t.eq(verdict(InteractionService.acceptBegin(fresh)), "ok")
		t.eq(verdict(InteractionService.acceptBegin(check({ channelUserId = OTHER }))), "Busy", "a second actor")
		t.eq(verdict(InteractionService.acceptBegin(check())), "ok", "the same actor may restart")
		t.eq(verdict(InteractionService.acceptBegin(check({ duration = 0 }))), "Instant")
		t.eq(verdict(InteractionService.acceptBegin(check({ distance = 30 }, NO_CHANNEL))), "OutOfRange")
	end,

	["channels: release, expiry and tick cancellations"] = function(t: Expect)
		t.eq(InteractionService.releaseVerdict(101, 100, 2), "Cancel", "released halfway")
		t.eq(InteractionService.releaseVerdict(102 - TOLERANCE + 0.01, 100, 2), "Await", "released at completion")
		t.eq(InteractionService.releaseVerdict(103, 100, 2), "Await")
		t.eq(InteractionService.channelExpiry(100, 1.2, 3.5), 100 + 3.5 + 2, "a client on BaseHold still completes")
		t.eq(InteractionService.channelExpiry(100, 4, 0.25), 106)

		local function state(overrides: { [string]: any }?, cleared: { string }?): InteractionService.ChannelState
			local base: InteractionService.ChannelState = {
				now = 101,
				alive = true,
				lifeState = "Alive",
				beganLifeState = "Alive",
				distance = 4,
				maxDistance = 7,
				releasedAt = nil,
				expiresAt = 105,
			}
			if overrides then
				for key, value in overrides do
					(base :: any)[key] = value
				end
			end
			for _, key in (cleared or {}) :: { string } do
				(base :: any)[key] = nil
			end
			return base
		end
		t.eq(InteractionService.channelCheck(state()), nil, "a healthy channel goes on")
		t.eq(InteractionService.channelCheck(state({ alive = false }, { "distance" })), "Died")
		t.eq(InteractionService.channelCheck(state(nil, { "distance" })), "OutOfRange", "the prompt went away")
		t.eq(InteractionService.channelCheck(state({ lifeState = "Downed" })), "LifeState")
		t.eq(InteractionService.channelCheck(state({ distance = 9.01 })), "OutOfRange")
		t.eq(InteractionService.channelCheck(state({ releasedAt = 100.8 })), nil, "inside the release grace")
		t.eq(InteractionService.channelCheck(state({ releasedAt = 100.4 })), "Released")
		t.eq(InteractionService.channelCheck(state({ now = 105.1 })), "Timeout")
		t.eq(
			InteractionService.channelCheck(state({ alive = false, lifeState = "Dead", distance = 50, now = 200 })),
			"Died",
			"the first reason wins"
		)
	end,

	["rate limit: a burst of 6, then 6 per second"] = function(t: Expect)
		local limit = InteractionService.MaxEventsPerSecond
		t.eq(limit, 6)
		local bucket: InteractionService.Bucket? = nil
		local admitted = 0
		for _ = 1, 10 do
			local ok, nextBucket = InteractionService.takeToken(bucket, 50, limit, limit)
			bucket = nextBucket
			if ok then
				admitted += 1
			end
		end
		t.eq(admitted, 6, "a flood at one instant")
		local okHalf, half = InteractionService.takeToken(bucket, 50.5, limit, limit)
		t.truthy(okHalf, "half a second refills three tokens")
		bucket = half
		local more = 0
		for _ = 1, 5 do
			local ok, nextBucket = InteractionService.takeToken(bucket, 50.5, limit, limit)
			bucket = nextBucket
			if ok then
				more += 1
			end
		end
		t.eq(more, 2)
		local okLater, later = InteractionService.takeToken(bucket, 1000, limit, limit)
		t.truthy(okLater)
		t.near(later.tokens, limit - 1, 1e-9, "refill caps at the burst")
	end,

	["handlers: kind and filter matching; the first registered match serves the prompt"] = function(t: Expect)
		local battery, batteryPrompt = host("Battery_A", { Tags.Interactable, Tags.BatteryPickup }, "Pickup")
		local flask, flaskPrompt = host("Flask_A", { Tags.Interactable, Tags.ChemicalItem }, "Pickup")
		local grate, grateUnscrew = host("Grate_A", { Tags.Interactable, Tags.VentGrate }, "Unscrew")
		local batteries = handler("Pickup", tagged(Tags.BatteryPickup))
		local flasks = handler("Pickup", tagged(Tags.ChemicalItem))
		local unscrew = handler("Unscrew", nil)
		local exploding = handler("Pickup", function(): boolean
			error("filter bug")
		end)

		t.truthy(InteractionService.matches(batteries, battery, batteryPrompt))
		t.falsy(InteractionService.matches(batteries, flask, flaskPrompt), "filter")
		t.falsy(InteractionService.matches(unscrew, battery, batteryPrompt), "kind")
		t.truthy(InteractionService.matches(unscrew, grate, grateUnscrew), "no filter: every prompt of the kind")
		t.falsy(InteractionService.matches(exploding, battery, batteryPrompt), "a throwing filter matches nothing")

		local list = { exploding, flasks, batteries, unscrew }
		local chosen, count = InteractionService.selectHandler(list, battery, batteryPrompt)
		t.eq(chosen, batteries)
		t.eq(count, 1)
		t.eq((InteractionService.selectHandler(list, flask, flaskPrompt)), flasks)
		t.eq((InteractionService.selectHandler(list, grate, grateUnscrew)), unscrew)
		local overlapping = handler("Pickup", nil)
		local first, overlaps = InteractionService.selectHandler({ overlapping, batteries }, battery, batteryPrompt)
		t.eq(first, overlapping, "registration order decides an overlap")
		t.eq(overlaps, 2)

		local stray = Instance.new("ProximityPrompt")
		stray:SetAttribute(W.PromptKind, "Juggle")
		t.eq(InteractionService.promptKind(stray), nil, "unknown kinds are not prompt kinds")
		t.eq(InteractionService.promptKind(grateUnscrew), "Unscrew")
		battery:Destroy()
		flask:Destroy()
		grate:Destroy()
		stray:Destroy()
	end,

	["Register / Resolve / unregister on hand-built hosts"] = function(t: Expect)
		local battery, batteryPrompt = host("Battery_B", { Tags.Interactable, Tags.BatteryPickup }, "Pickup")
		local flask, flaskPrompt = host("Flask_B", { Tags.Interactable, Tags.ChemicalItem }, "Pickup")
		local loose, loosePrompt = host("Loose_B", {}, "Pickup")
		local batteries = handler("Pickup", tagged(Tags.BatteryPickup))
		local flasks = handler("Pickup", tagged(Tags.ChemicalItem))

		local dropBatteries = InteractionService.Register(batteries)
		local dropFlasks = InteractionService.Register(flasks)
		local resolved, resolvedHost = InteractionService.Resolve(batteryPrompt)
		t.eq(resolved, batteries)
		t.eq(resolvedHost, battery, "the host is the Interactable ancestor, not the prompt's attachment")
		t.eq((InteractionService.Resolve(flaskPrompt)), flasks)
		local none, noHost = InteractionService.Resolve(loosePrompt)
		t.eq(none, nil, "a prompt outside any Interactable host is never served")
		t.eq(noHost, nil)

		dropBatteries()
		t.eq((InteractionService.Resolve(batteryPrompt)), nil, "unregistered")
		t.eq((InteractionService.Resolve(flaskPrompt)), flasks, "the other registration stays")
		dropBatteries()
		dropFlasks()
		t.eq((InteractionService.Resolve(flaskPrompt)), nil)

		t.throws(function()
			InteractionService.Register(({ kind = "Juggle", onComplete = function() end } :: any) :: Handler)
		end, "unknown kinds are refused")
		t.throws(function()
			InteractionService.Register(({ kind = "Pickup" } :: any) :: Handler)
		end, "onComplete is required")

		local actor, startedAt, duration = InteractionService.GetChannel(battery)
		t.eq(actor, nil)
		t.eq(startedAt, 0)
		t.eq(duration, 0)
		battery:Destroy()
		flask:Destroy()
		loose:Destroy()
	end,
}
