--!strict
-- Revive. DownedReviveService's pure rules (who may revive, what cancels a revive, why an anchor goes), the service
-- with every dependency injected (the anchor built on a Downed participant's character and removed with the right
-- reason on revive / death / leaving / the run's end, the respawn and the repair, the teammate notices, the handler's
-- audience / filter / eligibility, Poll cancelling a running hold the moment it can no longer go on, completion), the
-- hold timed by InteractionService's acceptance rules on a fake clock over this handler, and the live LifeStateService
-- on a fake clock: a revive that beats the bleedout and one that loses to it. Then DownedController's pure maths.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)

local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local DownedReviveService = require(ServerScriptService.Services.Match.DownedReviveService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local DownedController = require(StarterPlayer.StarterPlayerScripts.Controllers.Match.DownedController)

type Expect = SpecRunner.Expect

type Note = { player: Player, key: string, args: { string } }

type World = {
	states: { [Player]: Enums.LifeState },
	locks: { [Player]: Enums.ControlLock },
	characters: { [Player]: Model },
	actor: { [Instance]: Player },
	cancels: { { host: Instance, reason: string } },
	revives: { { player: Player, fraction: number } },
	stats: { { player: Player, key: Enums.StatKey } },
	notes: { Note },
	sounds: { string },
}

type Timer = { at: number, callback: () -> (), thread: thread, cancelled: boolean }

type FakeClock = { clock: LifeStateService.Clock, advance: (seconds: number) -> (), now: () -> number }

local W = Attributes.World
local MAX = GameConfig.MaxHealth
local HOLD = GameConfig.ReviveHoldSeconds

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local nextUserId = 8100

-- A player with a minimal character (root, humanoid) at `position`, not parented anywhere.
local function newPlayer(position: Vector3?): (Player, Model, BasePart)
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "ReviveSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	writable.DisplayName = "Mate" .. nextUserId
	local model = Instance.new("Model")
	model.Name = player.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(position or Vector3.new(0, 3, 0))
	root.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = MAX
	humanoid.Health = MAX
	humanoid.Parent = model
	player.Character = model
	return player, model, root
end

local function context(players: { Player }): Types.RunContext
	return { runId = "revive-spec", seed = 7, difficulty = "Standard", participants = players, startedAt = 1000 }
end

local function newWorld(): World
	return {
		states = {},
		locks = {},
		characters = {},
		actor = {},
		cancels = {},
		revives = {},
		stats = {},
		notes = {},
		sounds = {},
	}
end

local function install(world: World)
	DownedReviveService.SetDependencies({
		lifeState = function(player: Player): Enums.LifeState
			return world.states[player] or "Lobby"
		end,
		controlLock = function(player: Player): Enums.ControlLock
			return world.locks[player] or "None"
		end,
		character = function(player: Player): Model?
			return world.characters[player]
		end,
		channelActor = function(host: Instance): Player?
			return world.actor[host]
		end,
		cancelChannel = function(host: Instance, reason: string)
			world.actor[host] = nil
			table.insert(world.cancels, { host = host, reason = reason })
		end,
		revive = function(player: Player, fraction: number)
			table.insert(world.revives, { player = player, fraction = fraction })
			world.states[player] = "Alive"
		end,
		stat = function(player: Player, key: Enums.StatKey)
			table.insert(world.stats, { player = player, key = key })
		end,
		notify = function(player: Player, key: string, args: { string })
			table.insert(world.notes, { player = player, key = key, args = args })
		end,
		playOn = function(preset: string, _attach: Instance)
			table.insert(world.sounds, preset)
		end,
	})
end

-- Runs `body` with a fake world around a live run of `players`, always tearing it down.
local function withService(players: { Player }, body: (world: World) -> ())
	local world = newWorld()
	for _, player in players do
		world.states[player] = "Alive"
		local character = player.Character
		if character then
			world.characters[player] = character
		end
	end
	install(world)
	DownedReviveService.BeginRun(context(players))
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, world)
	DownedReviveService.EndRun()
	DownedReviveService.SetDependencies(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function down(world: World, player: Player)
	world.states[player] = "Downed"
	DownedReviveService.OnStateChanged(player, "Downed", "Alive")
end

local function lastCancel(world: World): string?
	local entry = world.cancels[#world.cancels]
	return if entry then entry.reason else nil
end

local function notesFor(world: World, player: Player, key: string): number
	local count = 0
	for _, note in world.notes do
		if note.player == player and note.key == key then
			count += 1
		end
	end
	return count
end

local function promptOf(anchor: Attachment): ProximityPrompt
	local prompt = anchor:FindFirstChildOfClass("ProximityPrompt")
	assert(prompt, "the anchor holds a prompt")
	return prompt
end

-- InteractionService's acceptance check for `player` on `anchor` at server time `now`.
local function check(
	player: Player,
	anchor: Attachment,
	now: number,
	channelUserId: number?,
	startedAt: number?
): InteractionService.Check
	local prompt = promptOf(anchor)
	local handler = DownedReviveService.Handler
	local canUse = handler.canUse
	assert(canUse, "the handler checks eligibility")
	local audience = handler.audience
	return {
		userId = player.UserId,
		lifeState = LifeStateService.GetState(player),
		distance = 2,
		maxDistance = prompt.MaxActivationDistance,
		audience = if audience then audience(prompt, anchor) else "All",
		ownerUserId = Attributes.getNumber(anchor, W.OwnerUserId, 0),
		canUse = function(): (boolean, string?)
			return canUse(player, prompt, anchor)
		end,
		now = now,
		duration = Attributes.getNumber(prompt, W.BaseHold, 0),
		channelUserId = channelUserId,
		channelStartedAt = startedAt,
	}
end

-- A clock whose time only moves when the spec advances it; due callbacks run in time order.
local function fakeClock(start: number): FakeClock
	local now = start
	local timers: { Timer } = {}
	local clock: LifeStateService.Clock = {
		now = function(): number
			return now
		end,
		delay = function(seconds: number, callback: () -> ()): thread
			local thread = coroutine.create(function() end)
			table.insert(
				timers,
				{ at = now + math.max(0, seconds), callback = callback, thread = thread, cancelled = false }
			)
			return thread
		end,
		cancel = function(thread: thread)
			for _, timer in timers do
				if timer.thread == thread then
					timer.cancelled = true
				end
			end
		end,
	}
	local function advance(seconds: number)
		local target = now + seconds
		while true do
			local nextIndex: number? = nil
			for index, timer in timers do
				if timer.cancelled or timer.at > target then
					continue
				end
				if nextIndex == nil or timer.at < timers[nextIndex].at then
					nextIndex = index
				end
			end
			if nextIndex == nil then
				break
			end
			local timer = table.remove(timers, nextIndex)
			if timer then
				now = math.max(now, timer.at)
				timer.callback()
			end
		end
		now = target
	end
	return {
		clock = clock,
		advance = advance,
		now = function(): number
			return now
		end,
	}
end

-- Runs `body` with the real LifeStateService (fake clock) feeding DownedReviveService, whose remaining dependencies
-- record; always tears everything down.
local function liveRun(players: { Player }, body: (world: World, clock: FakeClock) -> ())
	Net.Server.setup()
	local clock = fakeClock(1000)
	LifeStateService.SetClock(clock.clock)
	local world = newWorld()
	for _, player in players do
		local character = player.Character
		if character then
			world.characters[player] = character
		end
		-- LifeStateService gets a body without a root (its Gasp is positional audio, and Position reads throw in the
		-- harness); DownedReviveService keeps the rigged one above through its character dependency.
		local plain = Instance.new("Model")
		local humanoid = Instance.new("Humanoid")
		humanoid.MaxHealth = MAX
		humanoid.Health = MAX
		humanoid.Parent = plain
		player.Character = plain
	end
	DownedReviveService.SetDependencies({
		lifeState = LifeStateService.GetState,
		controlLock = function(player: Player): Enums.ControlLock
			return world.locks[player] or "None"
		end,
		character = function(player: Player): Model?
			return world.characters[player]
		end,
		channelActor = function(host: Instance): Player?
			return world.actor[host]
		end,
		cancelChannel = function(host: Instance, reason: string)
			world.actor[host] = nil
			table.insert(world.cancels, { host = host, reason = reason })
		end,
		revive = LifeStateService.Revive,
		stat = function(player: Player, key: Enums.StatKey)
			RunStatsService.Increment(player, key)
		end,
		notify = function(player: Player, key: string, args: { string })
			table.insert(world.notes, { player = player, key = key, args = args })
		end,
		playOn = function(preset: string, _attach: Instance)
			table.insert(world.sounds, preset)
		end,
	})
	local ctx = context(players)
	RunStatsService.BeginRun(ctx)
	PlayerStateService.BeginRun(ctx)
	LifeStateService.BeginRun(ctx)
	DownedReviveService.BeginRun(ctx)
	local stateConnection = LifeStateService.StateChanged:Connect(DownedReviveService.OnStateChanged)
	local revivedConnection = LifeStateService.Revived:Connect(DownedReviveService.OnRevived)
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, world, clock)
	stateConnection:Disconnect()
	revivedConnection:Disconnect()
	DownedReviveService.EndRun()
	LifeStateService.EndRun()
	PlayerStateService.EndRun()
	RunStatsService.EndRun()
	for _, player in players do
		LifeStateService.OnPlayerRemoving(player)
		PlayerStateService.OnPlayerRemoving(player)
	end
	LifeStateService.SetClock(nil)
	DownedReviveService.SetDependencies(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["rules: an Alive, free teammate revives a Downed participant who is not being caught"] = function(t: Expect)
		local function ok(overrides: { [string]: any }): (boolean, string?)
			local base: DownedReviveService.ReviveCheck = {
				reviverUserId = 1,
				victimUserId = 2,
				reviverParticipant = true,
				reviverState = "Alive",
				reviverLock = "None",
				victimState = "Downed",
				victimLock = "None",
			}
			local merged = table.clone(base) :: any
			for key, value in overrides do
				merged[key] = value
			end
			return DownedReviveService.reviveEligible(merged :: DownedReviveService.ReviveCheck)
		end
		local allowed, none = ok({})
		t.eq(allowed, true)
		t.eq(none, nil, "eligible has no reason")
		local _, gone = DownedReviveService.reviveEligible({
			reviverUserId = 1,
			victimUserId = nil,
			reviverParticipant = true,
			reviverState = "Alive",
			reviverLock = "None",
			victimState = "Downed",
			victimLock = "None",
		})
		t.eq(gone, "NoVictim", "the anchor no longer belongs to anyone")
		local _, noVictim = ok({ victimState = "Alive" })
		t.eq(noVictim, "NoVictim", "the victim is back up")
		local _, dead = ok({ victimState = "Dead" })
		t.eq(dead, "NoVictim")
		local _, own = ok({ reviverUserId = 2 })
		t.eq(own, "Self")
		local _, outsider = ok({ reviverParticipant = false })
		t.eq(outsider, "NotParticipant", "a spectator or late joiner never revives")
		local refusedStates: { Enums.LifeState } = { "Downed", "Dead", "Spectating", "Lobby" }
		for _, state: Enums.LifeState in refusedStates do
			local _, reason = ok({ reviverState = state })
			t.eq(reason, "LifeState", "a " .. state .. " reviver")
		end
		local busyLocks: { Enums.ControlLock } = { "Trap", "Locker", "Jumpscare", "Cutscene", "Drag", "Airlock" }
		for _, lock: Enums.ControlLock in busyLocks do
			local _, reason = ok({ reviverLock = lock })
			t.eq(reason, "Busy", "a reviver held by " .. lock)
		end
		local caughtLocks: { Enums.ControlLock } = { "Jumpscare", "Drag", "Cutscene" }
		for _, lock: Enums.ControlLock in caughtLocks do
			local _, reason = ok({ victimLock = lock })
			t.eq(reason, "Caught", "a victim held by " .. lock)
		end
		t.eq(ok({ victimLock = "Trap" }), true, "a downed victim still in a bear trap can be revived")
		t.eq(
			DownedReviveService.cancelReason({
				reviverUserId = 1,
				victimUserId = 2,
				reviverParticipant = true,
				reviverState = "Alive",
				reviverLock = "None",
				victimState = "Downed",
				victimLock = "Drag",
			}),
			"Caught",
			"a running hold stops for the same reasons"
		)
		t.eq(DownedReviveService.clearReason("Alive"), "Revived")
		t.eq(DownedReviveService.clearReason("Dead"), "VictimDied")
		t.eq(DownedReviveService.clearReason("Spectating"), "VictimState")
		t.eq(DownedReviveService.clearReason("Lobby"), "VictimState")
	end,

	["anchor: a Downed participant carries one lowered, owned Revive prompt, announced to the squad"] = function(
		t: Expect
	)
		local victim, _, victimRoot = newPlayer()
		local mate = newPlayer(Vector3.new(4, 3, 0))
		local outsider = newPlayer(Vector3.new(8, 3, 0))
		withService({ victim, mate }, function(world: World)
			world.states[outsider] = "Downed"
			DownedReviveService.OnStateChanged(outsider, "Downed", "Alive")
			t.eq(DownedReviveService.GetAnchor(outsider), nil, "only participants get an anchor")

			down(world, victim)
			local anchor = DownedReviveService.GetAnchor(victim)
			assert(anchor, "an anchor on the downed victim")
			t.eq(anchor.Parent, victimRoot, "on the victim's root")
			t.eq(anchor.Name, DownedReviveService.AnchorName)
			t.near(anchor.CFrame.Position.Y, -DownedReviveService.AnchorDrop, 1e-4, "lowered to the crawling body")
			t.eq(anchor:GetAttribute(W.OwnerUserId), victim.UserId)
			t.truthy(anchor:HasTag(Tags.Interactable), "the anchor is the Interactable host")
			local prompt = promptOf(anchor)
			t.eq(prompt:GetAttribute(W.PromptKind), "Revive")
			t.eq(prompt:GetAttribute(W.BaseHold), HOLD)
			t.eq(prompt.HoldDuration, HOLD)
			t.eq(prompt.MaxActivationDistance, DownedReviveService.PromptDistance)
			t.eq(prompt.Enabled, false, "InteractionService enables it")
			t.eq(prompt.ActionText, Strings.get("Prompt.Revive"))
			t.eq(prompt.ObjectText, Strings.get("Prompt.Downed"))
			local handler = DownedReviveService.Handler
			local filter = handler.filter
			assert(filter, "the handler filters its anchors")
			t.truthy(filter(anchor, prompt), "the handler serves this anchor")
			t.falsy(filter(victimRoot, prompt), "and nothing else")
			local audience = handler.audience
			assert(audience, "the handler sets an audience")
			t.eq(audience(prompt, anchor), "Others", "the victim never sees their own prompt")
			t.eq(notesFor(world, mate, "Downed.TeammateDown"), 1, "the squad hears about it")
			t.eq(notesFor(world, victim, "Downed.TeammateDown"), 0)
			t.eq(world.notes[1].args[1], victim.DisplayName)

			DownedReviveService.OnStateChanged(victim, "Downed", "Downed")
			t.eq(DownedReviveService.GetAnchor(victim), anchor, "one anchor per victim")
		end)
	end,

	["anchor: revive, death, leaving and the run's end each remove it with their reason"] = function(t: Expect)
		local victim = newPlayer()
		local mate = newPlayer(Vector3.new(4, 3, 0))
		withService({ victim, mate }, function(world: World)
			down(world, victim)
			local first = DownedReviveService.GetAnchor(victim)
			assert(first, "anchor")
			world.states[victim] = "Alive"
			DownedReviveService.OnStateChanged(victim, "Alive", "Downed")
			t.eq(lastCancel(world), "Revived")
			t.eq(first.Parent, nil, "destroyed")
			t.eq(DownedReviveService.GetAnchor(victim), nil)

			down(world, victim)
			local second = DownedReviveService.GetAnchor(victim)
			assert(second, "a fresh anchor on the next down")
			t.truthy(second ~= first)
			world.states[victim] = "Dead"
			DownedReviveService.OnStateChanged(victim, "Dead", "Downed")
			t.eq(lastCancel(world), "VictimDied")
			t.eq(notesFor(world, mate, "Downed.TeammateLost"), 1, "the squad hears they are gone")

			world.states[mate] = "Downed"
			DownedReviveService.OnStateChanged(mate, "Downed", "Alive")
			local mates = DownedReviveService.GetAnchor(mate)
			assert(mates, "the mate's anchor")
			DownedReviveService.OnPlayerRemoving(mate)
			t.eq(lastCancel(world), "Left")
			t.eq(mates.Parent, nil)

			world.states[mate] = "Alive"
			down(world, victim)
			local third = DownedReviveService.GetAnchor(victim)
			assert(third, "anchor before the run ends")
			DownedReviveService.EndRun()
			t.eq(lastCancel(world), "RunEnded")
			t.eq(third.Parent, nil)
			down(world, victim)
			t.eq(DownedReviveService.GetAnchor(victim), nil, "nothing between runs")

			DownedReviveService.BeginRun(context({ victim, mate }))
			down(world, victim)
			DownedReviveService.OnPhaseChanged("InRun")
			local fourth = DownedReviveService.GetAnchor(victim)
			assert(fourth, "the run going on keeps it")
			DownedReviveService.OnPhaseChanged("RunEnded")
			t.eq(lastCancel(world), "RunEnded", "the run resolved: no revives during the summary")
			t.eq(fourth.Parent, nil)
			DownedReviveService.OnStateChanged(victim, "Downed", "Alive")
			t.eq(DownedReviveService.GetAnchor(victim), nil)
		end)
	end,

	["anchor: a respawned Downed victim's new character gets it; Poll repairs a missing one"] = function(t: Expect)
		local victim = newPlayer()
		local mate = newPlayer(Vector3.new(4, 3, 0))
		withService({ victim, mate }, function(world: World)
			world.characters[victim] = nil
			down(world, victim)
			t.eq(DownedReviveService.GetAnchor(victim), nil, "no character yet: nothing to hold the prompt")
			local _, model, root = newPlayer(Vector3.new(0, 3, 10))
			world.characters[victim] = model
			DownedReviveService.OnCharacterSpawned(victim)
			local anchor = DownedReviveService.GetAnchor(victim)
			assert(anchor, "the new character carries it")
			t.eq(anchor.Parent, root)

			local _, replacement, replacementRoot = newPlayer(Vector3.new(0, 3, 20))
			world.characters[victim] = replacement
			DownedReviveService.Poll()
			local moved = DownedReviveService.GetAnchor(victim)
			assert(moved, "repaired")
			t.eq(moved.Parent, replacementRoot, "Poll moves it onto the character the victim has now")
			t.eq(anchor.Parent, nil, "the old one is gone")
			t.eq(lastCancel(world), "Respawned")

			moved:Destroy()
			DownedReviveService.Poll()
			local rebuilt = DownedReviveService.GetAnchor(victim)
			assert(rebuilt, "rebuilt after it was destroyed")
			t.eq(rebuilt.Parent, replacementRoot)

			world.states[victim] = "Alive"
			DownedReviveService.Poll()
			t.eq(DownedReviveService.GetAnchor(victim), nil, "a missed revive is noticed too")
			t.eq(lastCancel(world), "Revived")
		end)
	end,

	["hold: InteractionService times it on the server clock; completion revives at half health"] = function(t: Expect)
		local victim = newPlayer()
		local reviver = newPlayer(Vector3.new(3, 3, 0))
		local second = newPlayer(Vector3.new(-3, 3, 0))
		withService({ victim, reviver, second }, function(world: World)
			down(world, victim)
			local anchor = DownedReviveService.GetAnchor(victim)
			assert(anchor, "anchor")
			local start = 500
			local ok, reason = InteractionService.acceptBegin(check(victim, anchor, start, nil, nil))
			t.falsy(ok, "the victim cannot hold their own")
			t.eq(reason, "Audience")
			local began = InteractionService.acceptBegin(check(reviver, anchor, start, nil, nil))
			t.truthy(began, "an Alive teammate starts the hold")
			local busy, busyReason =
				InteractionService.acceptBegin(check(second, anchor, start + 1, reviver.UserId, start))
			t.falsy(busy)
			t.eq(busyReason, "Busy", "one reviver at a time")
			local early, earlyReason =
				InteractionService.acceptTrigger(check(reviver, anchor, start + 3, reviver.UserId, start))
			t.falsy(early)
			t.eq(earlyReason, "TooEarly")
			local due = start + HOLD - InteractionService.LatencyTolerance
			t.truthy(
				InteractionService.acceptTrigger(check(reviver, anchor, due, reviver.UserId, start)),
				"done after the 4 s hold (less the latency tolerance)"
			)
			world.locks[reviver] = "Locker"
			local hidden, hiddenReason =
				InteractionService.acceptTrigger(check(reviver, anchor, due, reviver.UserId, start))
			t.falsy(hidden)
			t.eq(hiddenReason, "Busy")
			world.locks[reviver] = nil

			local prompt = promptOf(anchor)
			DownedReviveService.Handler.onComplete(reviver, prompt, anchor)
			t.eq(#world.revives, 1)
			t.eq(world.revives[1].player, victim)
			t.eq(world.revives[1].fraction, DownedReviveService.HealthFraction)
			t.eq(DownedReviveService.HealthFraction, 0.5)
			t.eq(#world.stats, 1)
			t.eq(world.stats[1].player, reviver)
			t.eq(world.stats[1].key, "Revives")
			t.eq(notesFor(world, reviver, "Revive.YouRevived"), 1)
			t.eq(notesFor(world, victim, "Revive.RevivedBy"), 1)
			DownedReviveService.Handler.onComplete(second, prompt, anchor)
			t.eq(#world.revives, 1, "a completion on a victim already up does nothing")
		end)
	end,

	["poll: a running hold stops the moment the victim is caught or the reviver is not free"] = function(t: Expect)
		local victim = newPlayer()
		local reviver = newPlayer(Vector3.new(3, 3, 0))
		withService({ victim, reviver }, function(world: World)
			down(world, victim)
			local anchor = DownedReviveService.GetAnchor(victim)
			assert(anchor, "anchor")
			world.actor[anchor] = reviver
			DownedReviveService.Poll()
			t.eq(#world.cancels, 0, "a clean hold goes on")

			world.locks[victim] = "Jumpscare"
			DownedReviveService.Poll()
			t.eq(lastCancel(world), "Caught")
			world.locks[victim] = nil

			world.actor[anchor] = reviver
			world.locks[reviver] = "Drag"
			DownedReviveService.Poll()
			t.eq(lastCancel(world), "Busy", "the reviver grabbed")
			world.locks[reviver] = nil

			world.actor[anchor] = reviver
			world.states[reviver] = "Downed"
			DownedReviveService.Poll()
			t.eq(lastCancel(world), "LifeState", "the reviver went down")
			t.truthy(DownedReviveService.GetAnchor(reviver), "and now carries an anchor of their own")
			world.states[reviver] = "Alive"
			DownedReviveService.OnStateChanged(reviver, "Alive", "Downed")

			world.actor[anchor] = reviver
			world.states[victim] = "Dead"
			DownedReviveService.Poll()
			t.eq(lastCancel(world), "VictimDied", "the victim executed mid-hold")
			t.eq(DownedReviveService.GetAnchor(victim), nil)
		end)
	end,

	["live: a revive beats the bleedout on the fake clock; a late one loses to it"] = function(t: Expect)
		local victim = newPlayer()
		local reviver = newPlayer(Vector3.new(3, 3, 0))
		liveRun({ victim, reviver }, function(world: World, clock: FakeClock)
			LifeStateService.Down(victim, "Spec")
			t.eq(LifeStateService.GetState(victim), "Downed")
			local anchor = DownedReviveService.GetAnchor(victim)
			assert(anchor, "Down put the anchor on")
			clock.advance(GameConfig.BleedoutSeconds - HOLD - 1)
			local start = clock.now()
			t.truthy(InteractionService.acceptBegin(check(reviver, anchor, start, nil, nil)), "begun in time")
			clock.advance(HOLD)
			t.truthy(InteractionService.acceptTrigger(check(reviver, anchor, clock.now(), reviver.UserId, start)))
			DownedReviveService.Handler.onComplete(reviver, promptOf(anchor), anchor)
			t.eq(LifeStateService.GetState(victim), "Alive", "back up before the bleedout")
			t.near(LifeStateService.GetHealth(victim), MAX * DownedReviveService.HealthFraction, 1e-6)
			t.eq(RunStatsService.Get(reviver, "Revives"), 1)
			t.eq(DownedReviveService.GetAnchor(victim), nil, "the anchor went with the revive")
			t.eq(lastCancel(world), "Revived")
			t.eq(world.sounds[#world.sounds], "Gasp", "a gasp for air")
			clock.advance(GameConfig.BleedoutSeconds)
			t.eq(LifeStateService.GetState(victim), "Alive", "the old bleedout no longer runs")

			LifeStateService.Down(reviver, "Spec")
			local late = DownedReviveService.GetAnchor(reviver)
			assert(late, "the second victim's anchor")
			local latePrompt = promptOf(late)
			clock.advance(GameConfig.BleedoutSeconds - 1)
			local lateStart = clock.now()
			t.truthy(InteractionService.acceptBegin(check(victim, late, lateStart, nil, nil)), "begun too late")
			world.actor[late] = victim
			clock.advance(1.5)
			t.eq(LifeStateService.GetState(reviver), "Dead", "bled out mid-hold")
			t.eq(lastCancel(world), "VictimDied")
			t.eq(late.Parent, nil)
			DownedReviveService.Handler.onComplete(victim, latePrompt, late)
			t.eq(LifeStateService.GetState(reviver), "Dead", "a completion after death revives nobody")
			t.eq(RunStatsService.Get(victim, "Revives"), 0)
			t.eq(notesFor(world, victim, "Downed.TeammateLost"), 1)
		end)
	end,

	["DownedController: panic, grade, heart rate, status, syringe and marker rules"] = function(t: Expect)
		t.near(DownedController.panicFloor(1), 0.3, 1e-9, "just down: a raised floor")
		t.near(DownedController.panicFloor(0), 0.95, 1e-9, "bled out: almost full panic")
		t.truthy(DownedController.panicFloor(0.3) > DownedController.panicFloor(0.7), "rises as time runs out")
		local saturation, contrast, brightness = DownedController.grade(1)
		t.near(saturation, 0, 1e-9, "no grade while there is time")
		t.near(contrast, 0, 1e-9)
		t.near(brightness, 0, 1e-9)
		local drained = DownedController.grade(0)
		t.truthy(drained < -0.8, "the world drains of colour at the end")
		t.truthy(DownedController.grade(0.25) < DownedController.grade(0.75), "steadily")
		t.truthy(DownedController.heartRate(0) > DownedController.heartRate(1), "the heart races")

		local key, args = DownedController.statusLine("Mate", 0)
		t.eq(key, "Downed.BeingRevived")
		t.eq(args[1], "Mate")
		t.eq((DownedController.statusLine(nil, 2)), "Downed.TeammateCanRevive")
		t.eq((DownedController.statusLine(nil, 0)), "Downed.NoTeammates")
		for _, used: string in { "Downed.BeingRevived", "Downed.TeammateCanRevive", "Downed.NoTeammates" } do
			t.truthy(Strings.has(used), used)
		end

		t.eq(DownedController.syringeMode("Downed", 1), "SelfRevive")
		t.eq(DownedController.syringeMode("Alive", 1), "Stamina")
		t.eq(DownedController.syringeMode("Downed", 0), nil, "no charge, nothing to send")
		t.eq(DownedController.syringeMode("Dead", 1), nil)
		t.eq(DownedController.syringeMode("Lobby", 1), nil)

		local near, range = DownedController.MarkerNear, DownedController.MarkerRange
		t.eq(DownedController.markerAlpha(range + 1, near, range), 0, "out of range")
		t.eq(DownedController.markerAlpha(1, near, range), 0, "up close the prompt takes over")
		t.near(DownedController.markerAlpha(near * 3, near, range), 1, 1e-9, "full in between")
		t.truthy(DownedController.markerAlpha(range * 0.9, near, range) < 1, "fading toward the range")

		t.near(DownedController.reviveProgress(10, 4, 12), 0.5, 1e-9)
		t.eq(DownedController.reviveProgress(10, 4, 20), 1)
		t.eq(DownedController.reviveProgress(10, 0, 12), 0)
	end,
}
