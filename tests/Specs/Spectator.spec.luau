--!strict
-- Spectator. SpectatorService's pure rules (who spectates and why, the target candidates, picking and cycling around
-- the run's ring) and the service with every dependency injected: eliminated participants watching the next living
-- teammate, a lost target handing over to the next one, nobody left, coming back at a checkpoint, cycling (wrapping,
-- never onto the spectator or the fallen), present non-participants at BeginRun (over capacity or late, no body),
-- mid-run joiners (only during Deploying / InRun), a target leaving, and EndRun clearing everything. Then
-- SpectatorController's pure maths (the death hold, the reason lines, the comeback promise, the eye, the look easing,
-- the cut).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Types = require(ReplicatedStorage.Shared.Types)

local SpectatorService = require(ServerScriptService.Services.Match.SpectatorService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local SpectatorController = require(StarterPlayer.StarterPlayerScripts.Controllers.Match.SpectatorController)

type Expect = SpecRunner.Expect

type World = {
	players: { Player },
	states: { [Player]: Enums.LifeState },
	characters: { [Player]: Model },
	phase: Enums.MatchPhase,
	spectating: { Player },
	despawned: { Player },
}

local P = Attributes.Player

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local nextUserId = 8600

local function newPlayer(): Player
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "SpectatorSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	writable.DisplayName = "Watcher" .. nextUserId
	return player
end

local function players(count: number): { Player }
	local out: { Player } = {}
	for _ = 1, count do
		table.insert(out, newPlayer())
	end
	return out
end

local function context(participants: { Player }): Types.RunContext
	return { runId = "spectator-spec", seed = 3, difficulty = "Standard", participants = participants, startedAt = 50 }
end

local function count(list: { Player }, player: Player): number
	local total = 0
	for _, entry in list do
		if entry == player then
			total += 1
		end
	end
	return total
end

-- Runs `body` with a fake world of `present` players (all with bodies, all Alive), always tearing it down.
local function withWorld(present: { Player }, body: (world: World) -> ())
	local world: World = {
		players = table.clone(present),
		states = {},
		characters = {},
		phase = "Deploying",
		spectating = {},
		despawned = {},
	}
	for _, player in present do
		world.states[player] = "Alive"
		world.characters[player] = Instance.new("Model")
	end
	SpectatorService.SetDependencies({
		lifeState = function(player: Player): Enums.LifeState
			return world.states[player] or "Lobby"
		end,
		setSpectating = function(player: Player)
			table.insert(world.spectating, player)
			world.states[player] = "Spectating"
		end,
		character = function(player: Player): Model?
			return world.characters[player]
		end,
		despawn = function(player: Player)
			table.insert(world.despawned, player)
			world.characters[player] = nil
		end,
		phase = function(): Enums.MatchPhase
			return world.phase
		end,
		players = function(): { Player }
			return world.players
		end,
	})
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, world)
	SpectatorService.EndRun()
	SpectatorService.SetDependencies(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function targetId(player: Player): number?
	local value = player:GetAttribute(P.SpectateTargetUserId)
	return if type(value) == "number" then value else nil
end

local function reasonOf(player: Player): string?
	local value = player:GetAttribute(P.SpectateReason)
	return if type(value) == "string" then value else nil
end

local function kill(world: World, player: Player)
	world.states[player] = "Dead"
	SpectatorService.Refresh()
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["rules: participants out of play are Eliminated; non-participants watch only when admitted"] = function(t: Expect)
		local reasonFor = SpectatorService.reasonFor
		t.eq(reasonFor({ inRun = false, participant = true, lifeState = "Dead", admitted = nil }), "None", "no run")
		t.eq(reasonFor({ inRun = true, participant = true, lifeState = "Alive", admitted = nil }), "None")
		t.eq(reasonFor({ inRun = true, participant = true, lifeState = "Downed", admitted = nil }), "None")
		t.eq(reasonFor({ inRun = true, participant = true, lifeState = "Dead", admitted = nil }), "Eliminated")
		t.eq(
			reasonFor({ inRun = true, participant = true, lifeState = "Spectating", admitted = nil }),
			"Eliminated",
			"left behind by an airlock"
		)
		t.eq(
			reasonFor({ inRun = true, participant = false, lifeState = "Spectating", admitted = "LateJoin" }),
			"LateJoin"
		)
		t.eq(
			reasonFor({ inRun = true, participant = false, lifeState = "Spectating", admitted = "OverCapacity" }),
			"OverCapacity"
		)
		t.eq(reasonFor({ inRun = true, participant = false, lifeState = "Lobby", admitted = nil }), "None")
		t.eq(SpectatorService.admissionReason(GameConfig.MaxSquad), "OverCapacity", "the squad was full")
		t.eq(SpectatorService.admissionReason(GameConfig.MaxSquad - 1), "LateJoin", "room left: they were late")
		t.eq(SpectatorService.admissionReason(0), "LateJoin")
	end,

	["rules: targets are playing participants, picked and cycled around the run's ring"] = function(t: Expect)
		local ring = { 11, 12, 13, 14 }
		local states: { [number]: Enums.LifeState } = { [11] = "Dead", [12] = "Alive", [13] = "Downed", [14] = "Alive" }
		local valid = SpectatorService.candidates(ring, states, 11)
		t.falsy(valid[11], "never the spectator")
		t.truthy(valid[12])
		t.truthy(valid[13], "a downed teammate is still worth watching")
		t.truthy(valid[14])
		local noSelf = SpectatorService.candidates(ring, states, 12)
		t.falsy(noSelf[12], "a spectator is never their own target")
		t.falsy(SpectatorService.candidates(ring, { [11] = "Dead", [12] = "Spectating" }, 99)[12])

		local pick = SpectatorService.pickTarget
		t.eq(pick(ring, valid, nil, 11, 0), 12, "the first after my own place")
		t.eq(pick(ring, valid, 13, 11, 0), 13, "a valid target stays")
		t.eq(pick(ring, { [14] = true, [12] = true }, 13, 11, 0), 14, "a lost target hands over to the next one")
		t.eq(pick(ring, { [12] = true }, 14, 11, 0), 12, "wrapping")
		t.eq(pick(ring, valid, nil, nil, 0), 12, "an outsider starts at the ring's start")
		t.eq(pick(ring, valid, nil, 99, 0), 12, "an anchor outside the ring too")
		t.eq(pick(ring, valid, 12, 11, 1), 13)
		t.eq(pick(ring, valid, 14, 11, 1), 12, "next wraps past the spectator")
		t.eq(pick(ring, valid, 12, 11, -1), 14, "previous wraps the other way")
		t.eq(pick(ring, valid, nil, nil, -1), 14, "previous from nowhere starts at the end")
		t.eq(pick(ring, { [13] = true }, 13, 11, 1), 13, "a lone target is kept")
		t.eq(pick(ring, {}, 13, 11, 0), nil, "nobody playing: nothing to watch")
		t.eq(pick({}, valid, nil, nil, 1), nil)
	end,

	["service: the eliminated watch the next living teammate, hand over when it falls, and stop on return"] = function(
		t: Expect
	)
		local squad = players(3)
		local a, b, c = squad[1], squad[2], squad[3]
		withWorld(squad, function(world: World)
			SpectatorService.BeginRun(context(squad))
			for _, player in squad do
				t.eq(reasonOf(player), "None", "everyone plays")
				t.eq(targetId(player), nil)
			end
			kill(world, a)
			t.eq(reasonOf(a), "Eliminated")
			t.eq(targetId(a), b.UserId, "the next teammate after me")
			t.eq(SpectatorService.GetTarget(a), b)
			t.truthy(SpectatorService.IsSpectating(a))

			kill(world, b)
			t.eq(targetId(a), c.UserId, "target lost: the next one")
			t.eq(targetId(b), c.UserId)

			world.states[c] = "Downed"
			SpectatorService.Refresh()
			t.eq(targetId(a), c.UserId, "a downed teammate is still watched")

			kill(world, c)
			for _, player in squad do
				t.eq(reasonOf(player), "Eliminated")
				t.eq(targetId(player), nil, "nobody left to watch: results soon")
			end

			-- The airlock brings b and c back.
			world.states[b] = "Alive"
			world.states[c] = "Alive"
			SpectatorService.Refresh()
			t.eq(reasonOf(b), "None", "back on their feet")
			t.eq(targetId(b), nil)
			t.eq(targetId(a), b.UserId)
			t.eq(#world.despawned, 0, "participants keep their bodies (corpses)")
			t.eq(#world.spectating, 0, "participants' life states are LifeStateService's business")
		end)
	end,

	["service: SpectateCycle steps around the ring, wrapping, never onto the spectator or the fallen"] = function(
		t: Expect
	)
		local squad = players(4)
		local a, b, c, d = squad[1], squad[2], squad[3], squad[4]
		withWorld(squad, function(world: World)
			SpectatorService.BeginRun(context(squad))
			kill(world, a)
			t.eq(targetId(a), b.UserId)
			t.truthy(SpectatorService.Cycle(a, 1))
			t.eq(targetId(a), c.UserId)
			SpectatorService.Cycle(a, 1)
			t.eq(targetId(a), d.UserId)
			SpectatorService.Cycle(a, 1)
			t.eq(targetId(a), b.UserId, "wraps past myself")
			SpectatorService.Cycle(a, -1)
			t.eq(targetId(a), d.UserId)
			kill(world, c)
			SpectatorService.Cycle(a, -1)
			t.eq(targetId(a), b.UserId, "skips the fallen")
			t.falsy(SpectatorService.Cycle(a, 0), "no direction, no move")
			t.falsy(SpectatorService.Cycle(b, 1), "a playing teammate does not spectate")
			kill(world, d)
			t.falsy(SpectatorService.Cycle(a, 1), "a lone target stays")
			t.eq(targetId(a), b.UserId)
		end)
	end,

	["service: present non-participants at BeginRun spectate without a body; late joiners only mid-run"] = function(
		t: Expect
	)
		local full = players(GameConfig.MaxSquad + 1)
		local extra = full[#full]
		local squad = table.clone(full)
		table.remove(squad)
		withWorld(full, function(world: World)
			SpectatorService.BeginRun(context(squad))
			t.eq(reasonOf(extra), "OverCapacity")
			t.eq(count(world.spectating, extra), 1, "made Spectating")
			t.eq(count(world.despawned, extra), 1, "and their lobby body removed")
			t.eq(targetId(extra), squad[1].UserId, "an outsider starts at the ring's start")
			for _, player in squad do
				t.eq(reasonOf(player), "None")
				t.eq(count(world.spectating, player), 0)
			end
			SpectatorService.Cycle(extra, -1)
			t.eq(targetId(extra), squad[#squad].UserId, "outsiders cycle too")

			-- Their first lobby spawn finishing mid-run: the body goes again.
			world.characters[extra] = Instance.new("Model")
			SpectatorService.OnCharacterSpawned(extra)
			t.eq(count(world.despawned, extra), 2)
			SpectatorService.OnCharacterSpawned(squad[1])
			t.eq(count(world.despawned, squad[1]), 0, "a participant's spawn is never touched")
		end)

		local pair = players(3)
		local late = pair[3]
		withWorld(pair, function(world: World)
			SpectatorService.BeginRun(context({ pair[1], pair[2] }))
			t.eq(reasonOf(late), "LateJoin", "room left in the squad: they came too late")

			world.phase = "InRun"
			local joiner = newPlayer()
			table.insert(world.players, joiner)
			SpectatorService.OnPlayerJoined(joiner)
			t.eq(reasonOf(joiner), "LateJoin")
			t.eq(count(world.spectating, joiner), 1)
			t.eq(count(world.despawned, joiner), 0, "no body yet: a spawn in flight is never cancelled")
			t.eq(targetId(joiner), pair[1].UserId)
			world.characters[joiner] = Instance.new("Model")
			SpectatorService.OnCharacterSpawned(joiner)
			t.eq(count(world.despawned, joiner), 1, "removed once it arrives")

			world.phase = "Results"
			local afterwards = newPlayer()
			table.insert(world.players, afterwards)
			SpectatorService.OnPlayerJoined(afterwards)
			t.eq(reasonOf(afterwards), "None", "the run is over: they stay in the lobby")
			t.eq(count(world.spectating, afterwards), 0)

			SpectatorService.EndRun()
			for _, player in world.players do
				t.eq(reasonOf(player), "None", "EndRun clears everyone")
				t.eq(targetId(player), nil)
				t.falsy(SpectatorService.IsSpectating(player))
			end
			world.characters[joiner] = Instance.new("Model")
			SpectatorService.OnCharacterSpawned(joiner)
			t.eq(count(world.despawned, joiner), 1, "the lobby body after the run stays")
			world.phase = "Lobby"
			local between = newPlayer()
			table.insert(world.players, between)
			SpectatorService.OnPlayerJoined(between)
			t.eq(reasonOf(between), "None")
		end)
	end,

	["service: a target leaving moves its watchers on; the leaver keeps no record"] = function(t: Expect)
		local squad = players(3)
		local a, b, c = squad[1], squad[2], squad[3]
		withWorld(squad, function(world: World)
			SpectatorService.BeginRun(context(squad))
			kill(world, a)
			t.eq(targetId(a), b.UserId)
			SpectatorService.OnPlayerRemoving(b)
			t.eq(targetId(a), c.UserId, "the next after the leaver")
			SpectatorService.Refresh()
			t.eq(targetId(a), c.UserId, "the leaver (still listed while leaving) is never picked again")
			t.falsy(SpectatorService.IsSpectating(b))
			SpectatorService.OnPlayerRemoving(a)
			t.falsy(SpectatorService.IsSpectating(a))
			t.eq(SpectatorService.GetReason(a), "None")
		end)
	end,

	["SpectatorController: death hold, reason lines, the comeback promise, eye, look and cut"] = function(t: Expect)
		local hold = SpectatorController.DeathHold
		t.falsy(SpectatorController.isWatching("None", nil, 10))
		t.truthy(SpectatorController.isWatching("LateJoin", nil, 10), "late joiners watch at once")
		t.falsy(SpectatorController.isWatching("Eliminated", 10, 10 + hold - 0.1), "the body first")
		t.truthy(SpectatorController.isWatching("Eliminated", 10, 10 + hold))

		t.eq(SpectatorController.reasonKey("Eliminated", "Dead"), "Spectate.Eliminated")
		t.eq(SpectatorController.reasonKey("Eliminated", "Spectating"), "Spectate.LeftBehind")
		t.eq(SpectatorController.reasonKey("LateJoin", "Spectating"), "Spectate.LateJoin")
		t.eq(SpectatorController.reasonKey("OverCapacity", "Spectating"), "Lobby.ServerFull")
		t.eq(SpectatorController.reasonKey("None", "Alive"), nil)
		local keys: { string } = {
			"Spectate.Eliminated",
			"Spectate.LeftBehind",
			"Spectate.LateJoin",
			"Lobby.ServerFull",
			"Spectate.Respawn",
			"Spectate.TargetDowned",
			"Hud.Spectating",
			"Hud.NoOneToSpectate",
		}
		for _, key in keys do
			t.truthy(Strings.has(key), key)
		end

		t.truthy(SpectatorController.showRespawn("Eliminated", "Level0_Basement"), "a stairwell ahead")
		t.falsy(SpectatorController.showRespawn("Eliminated", "Level5_Roof"), "no airlock on the roof")
		t.falsy(SpectatorController.showRespawn("LateJoin", "Level0_Basement"), "outsiders wait for the next run")
		t.falsy(SpectatorController.showRespawn("Eliminated", nil))

		local head = CFrame.new(10, 5, 0) * CFrame.Angles(0, math.rad(90), 0)
		local eye = SpectatorController.eyePosition(head)
		t.truthy(eye.Y > 5, "the eyes sit a little above the head's centre")
		t.truthy((eye - head.Position):Dot(head.LookVector) > 0.2, "and forward, in the face")

		local look = SpectatorController.approachLook({ yaw = math.rad(170), pitch = 0 }, {
			yaw = math.rad(-170),
			pitch = math.rad(30),
		}, 1 / 60)
		t.truthy(look.yaw > math.rad(170) or look.yaw < math.rad(-170), "the short way round")
		t.truthy(look.pitch > 0 and look.pitch < math.rad(30), "eased, not snapped")
		local settled = { yaw = 0, pitch = 0 }
		for _ = 1, 240 do
			settled = SpectatorController.approachLook(settled, { yaw = 1, pitch = 2 }, 1 / 60)
		end
		t.near(settled.yaw, 1, 1e-3, "converges")
		t.near(settled.pitch, math.rad(89), 1e-6, "pitch stays inside ±89°")

		t.eq(SpectatorController.cutStep(0, true, 1), 1, "to black")
		t.eq(SpectatorController.cutStep(1, false, 1), 0, "and back")
		local halfway = SpectatorController.cutStep(0, true, 0.05)
		t.truthy(halfway > 0 and halfway < 1)
	end,
}
