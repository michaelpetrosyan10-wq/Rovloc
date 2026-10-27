--!strict
-- Server -> client audio cues (AudioService's pure rules and AudioController's late-cue rule). A cue reaches exactly
-- its audience (everyone, everyone but one player, or a list); a looped cue stays live until its duration (plus the
-- client fade) has passed or its attach target leaves the world, which is what decides whether a joining player is
-- sent it; a cue that arrives a little late plays from its start, a really late one is skipped into.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local AudioController = require(StarterPlayer.StarterPlayerScripts.Controllers.Core.AudioController)
local AudioService = require(ServerScriptService.Services.Core.AudioService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local Types = require(ReplicatedStorage.Shared.Types)

type Expect = SpecRunner.Expect

local T0 = 1_700_000_000

local function fakePlayer(userId: number): Player
	return ({ UserId = userId, Name = "CueSpec" .. userId } :: any) :: Player
end

local function cue(duration: number?, attach: Instance?): Types.AudioCuePayload
	return {
		id = 42,
		preset = "VentScrape",
		position = Vector3.zero,
		attach = attach,
		startAt = T0,
		seed = 7,
		volume = nil,
		duration = duration,
	}
end

local function always(_instance: Instance): boolean
	return true
end

local function never(_instance: Instance): boolean
	return false
end

return {
	["a cue reaches exactly its audience"] = function(t: Expect)
		local a, b, c = fakePlayer(1), fakePlayer(2), fakePlayer(3)
		t.truthy(AudioService.audienceIncludes({}, a), "everyone")
		t.falsy(AudioService.audienceIncludes({ except = a }, a), "everyone but the noisy player")
		t.truthy(AudioService.audienceIncludes({ except = a }, b))
		t.truthy(AudioService.audienceIncludes({ players = { a, b } }, b), "a list")
		t.falsy(AudioService.audienceIncludes({ players = { a, b } }, c), "a joiner is not in an old list")
	end,

	["a timed loop expires after its duration and the client fade"] = function(t: Expect)
		t.eq(AudioService.loopExpiry(cue(nil)), nil, "untimed loops end only when stopped")
		local expiry = AudioService.loopExpiry(cue(3.5))
		t.truthy(expiry ~= nil and expiry > T0 + 3.5 and expiry < T0 + 4.5, "duration plus the fade-out")
	end,

	["a loop is live until it times out or its target leaves the world"] = function(t: Expect)
		local timed: AudioService.ActiveLoop = {
			cue = cue(2),
			audience = {},
			expiresAt = AudioService.loopExpiry(cue(2)),
			runScoped = true,
		}
		t.truthy(AudioService.loopIsLive(timed, T0 + 1, always), "still playing")
		t.falsy(AudioService.loopIsLive(timed, T0 + 10, always), "long over: not re-sent to joiners")
		local target = Instance.new("Part")
		local attached: AudioService.ActiveLoop = {
			cue = cue(nil, target),
			audience = {},
			expiresAt = nil,
			runScoped = false,
		}
		t.truthy(AudioService.loopIsLive(attached, T0 + 9999, always), "untimed and attached: live while it exists")
		t.falsy(AudioService.loopIsLive(attached, T0 + 1, never), "its target left the world")
		target:Destroy()
	end,

	["a slightly late cue plays from its start; a late one is skipped into"] = function(t: Expect)
		t.eq(AudioController.cueStartOffset(0), 0)
		t.eq(AudioController.cueStartOffset(0.12), 0, "network jitter keeps the attack")
		t.eq(AudioController.cueStartOffset(0.8), 0.8, "really late: stay in sync")
		t.eq(AudioController.cueStartOffset(30), 30, "a late joiner fast-forwards into a loop")
	end,
}
