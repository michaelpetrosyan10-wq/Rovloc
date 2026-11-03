--!strict
-- The roof jump (Phase 8): ParachuteMotion's shared rules (where the roof ends, the canopy's path, the auto-deploy and
-- landing heights, the packless fall, the validator's verdict, the jump-gap warnings, the jumper's camera maths, the
-- landing field under the glide) and ParachuteService on a fake clock with injected roots, ground, rigs, locks and
-- senders: taking a pack from the crate (and only one), the leap, the cord (also when it beats the server's sight of
-- the leap), the canopy and its descent, the fair auto-deploy and its hard landing, a freefall held in the air, the
-- fatal fall without a pack, packs going back to the crate, a downed jumper, the scripted landing, the validator, and
-- the run's end.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local ParachuteMotion = require(ReplicatedStorage.Shared.Sequence.ParachuteMotion)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local SchoolShellBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.SchoolShellBuilder)

local ParachuteService = require(ServerScriptService.Services.Mechanics.ParachuteService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

type World = {
	now: number,
	live: boolean,
	players: { Player },
	roots: { [Player]: Part },
	life: { [Player]: Enums.LifeState },
	ground: number?,
	executed: { { player: Player, cause: string } },
	revived: { { player: Player, fraction: number } },
	locks: { { player: Player, reason: Enums.ControlLock, mode: Enums.LockMode? } },
	overrides: { { player: Player, push: boolean, state: Enums.MoveState? } },
	teleports: { { player: Player, cframe: CFrame } },
	descents: { { velocity: Vector3, instance: Instance } },
	canopies: { Instance },
	collapses: { { at: Vector3, facing: Vector3 } },
	shown: { { pack: Model, visible: boolean } },
	refreshed: { Instance },
	sounds: { { preset: string, except: Player? } },
	notices: { { player: Player, key: string } },
}

local P = Attributes.Player
local W = Attributes.World
local DECK = ParachuteMotion.DeckY
local GROUND = WorldConfig.GroundY
local STAND = ParachuteMotion.RootHeight
local GAP = ParachuteMotion.Gap
local GAP_Z = (GAP.minZ + GAP.maxZ) / 2
local ON_ROOF = Vector3.new(12, DECK + STAND, GAP_Z)
local OFF_EDGE = Vector3.new(-3, DECK + 1, GAP_Z)

local nextUserId = 9300

local function newPlayer(name: string): Player
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = name
	local writable = player :: any
	writable.UserId = nextUserId
	return player
end

local function newPack(index: number): Model
	local crate = Instance.new("Folder")
	local pack = Instance.new("Model")
	pack.Name = "ParachutePack" .. index
	local base = Instance.new("Part")
	base.Name = "Base"
	base.CFrame = CFrame.new(14, DECK + 1, GAP_Z + index)
	base.Parent = pack
	pack.PrimaryPart = base
	pack.Parent = crate
	return pack
end

local function place(world: World, player: Player, position: Vector3)
	world.roots[player].CFrame = CFrame.new(position)
end

-- Runs `body` with ParachuteService on a fake world, and always tears it down.
local function withWorld(names: { string }, body: (world: World, players: { Player }) -> ())
	local players: { Player } = {}
	local world: World = {
		now = 500,
		live = true,
		players = players,
		roots = {},
		life = {},
		ground = GROUND,
		executed = {},
		revived = {},
		locks = {},
		overrides = {},
		teleports = {},
		descents = {},
		canopies = {},
		collapses = {},
		shown = {},
		refreshed = {},
		sounds = {},
		notices = {},
	}
	for _, name in names do
		local player = newPlayer(name)
		table.insert(players, player)
		local root = Instance.new("Part")
		root.CFrame = CFrame.new(ON_ROOF)
		world.roots[player] = root
		world.life[player] = "Alive"
	end
	local holder = Instance.new("Folder")
	ParachuteService.SetDependencies({
		now = function(): number
			return world.now
		end,
		live = function(): boolean
			return world.live
		end,
		players = function(): { Player }
			return world.players
		end,
		rootOf = function(player: Player): BasePart?
			return world.roots[player]
		end,
		rootHeight = function(_player: Player): number
			return STAND
		end,
		lifeState = function(player: Player): Enums.LifeState
			return world.life[player] or "Lobby"
		end,
		groundBelow = function(_player: Player, _position: Vector3): number?
			return world.ground
		end,
		execute = function(player: Player, cause: string)
			table.insert(world.executed, { player = player, cause = cause })
			world.life[player] = "Dead"
		end,
		revive = function(player: Player, fraction: number)
			table.insert(world.revived, { player = player, fraction = fraction })
			world.life[player] = "Alive"
		end,
		lock = function(player: Player, reason: Enums.ControlLock, mode: Enums.LockMode)
			table.insert(world.locks, { player = player, reason = reason, mode = mode })
		end,
		unlock = function(player: Player, reason: Enums.ControlLock)
			table.insert(world.locks, { player = player, reason = reason, mode = nil })
		end,
		pushOverride = function(player: Player, _token: string, state: Enums.MoveState)
			table.insert(world.overrides, { player = player, push = true, state = state })
		end,
		popOverride = function(player: Player, _token: string)
			table.insert(world.overrides, { player = player, push = false, state = nil })
		end,
		teleport = function(player: Player, cframe: CFrame): boolean
			table.insert(world.teleports, { player = player, cframe = cframe })
			world.roots[player].CFrame = cframe
			return true
		end,
		attachPack = function(_player: Player): Instance?
			return Instance.new("Model")
		end,
		attachCanopy = function(_player: Player): Instance?
			local canopy = Instance.new("Model")
			table.insert(world.canopies, canopy)
			return canopy
		end,
		attachDescent = function(_root: BasePart, velocity: Vector3): Instance?
			local instance: Instance = Instance.new("Folder")
			instance.Parent = holder
			table.insert(world.descents, { velocity = velocity, instance = instance })
			return instance
		end,
		collapse = function(_canopy: Instance, at: Vector3, facing: Vector3)
			table.insert(world.collapses, { at = at, facing = facing })
		end,
		showPack = function(pack: Model, visible: boolean)
			table.insert(world.shown, { pack = pack, visible = visible })
		end,
		refresh = function(host: Instance)
			table.insert(world.refreshed, host)
		end,
		playAt = function(preset: string, _position: Vector3, except: Player?)
			table.insert(world.sounds, { preset = preset, except = except })
		end,
		notify = function(player: Player, key: string)
			table.insert(world.notices, { player = player, key = key })
		end,
	})
	ParachuteService.BeginRun({
		runId = "parachute-spec",
		seed = 8,
		difficulty = "Standard",
		participants = players,
		startedAt = 0,
	})
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, world, players)
	ParachuteService.EndRun()
	ParachuteService.SetDependencies(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function step(world: World, seconds: number?)
	world.now += seconds or 1 / 60
	ParachuteService.Step(world.now)
end

local function soundCount(world: World, preset: string): number
	local count = 0
	for _, sound in world.sounds do
		if sound.preset == preset then
			count += 1
		end
	end
	return count
end

-- Takes a crate pack for `player` and walks them off the jump gap: Freefall.
local function leap(t: Expect, world: World, player: Player): Model
	local pack = newPack(#world.shown + 1)
	t.truthy(ParachuteService.Take(player, pack), player.Name .. " takes a pack")
	place(world, player, OFF_EDGE)
	step(world)
	t.eq(ParachuteService.GetState(player), "Freefall", "off the edge with a pack")
	return pack
end

return {
	["ParachuteMotion: where the roof ends"] = function(t: Expect)
		t.falsy(ParachuteMotion.offRoof(ON_ROOF), "on the deck")
		t.falsy(ParachuteMotion.offRoof(Vector3.new(-0.5, DECK + STAND, GAP_Z)), "standing on the gap's lip")
		t.truthy(ParachuteMotion.offRoof(Vector3.new(-3.2, DECK + STAND, GAP_Z)), "clear of the wall's face")
		t.truthy(ParachuteMotion.offRoof(Vector3.new(-1.2, DECK, GAP_Z)), "past the face and dropping")
		t.falsy(ParachuteMotion.offRoof(Vector3.new(-1.2, DECK + STAND, GAP_Z)), "past the face but still up")
		t.truthy(ParachuteMotion.offRoof(Vector3.new(60, DECK - 30, -4)), "anywhere along the edge: the north side")
		t.falsy(ParachuteMotion.offRoof(Vector3.new(254, DECK - 10, 80)), "climbing the east stair tower")
		t.falsy(ParachuteMotion.offRoof(Vector3.new(-14, DECK - 20, 80)), "in the west stair tower")
		t.near(ParachuteMotion.outside(Vector3.new(-3, 0, GAP_Z)), 3, 1e-6)
		t.eq(ParachuteMotion.outside(ON_ROOF), 0)
	end,

	["ParachuteMotion: the nearest edge and its outward normal"] = function(t: Expect)
		local fromGap = Vector3.new(-3, DECK - 10, GAP_Z)
		t.eq(ParachuteMotion.edgePoint(fromGap), Vector3.new(0, DECK, GAP_Z))
		t.eq(ParachuteMotion.outward(fromGap), Vector3.new(-1, 0, 0))
		local inside = Vector3.new(2, DECK + STAND, GAP_Z)
		t.eq(ParachuteMotion.edgePoint(inside), Vector3.new(0, DECK, GAP_Z), "inside: the nearest side")
		t.eq(ParachuteMotion.outward(inside), Vector3.new(-1, 0, 0))
		t.eq(ParachuteMotion.outward(Vector3.new(120, DECK, 158)), Vector3.new(0, 0, 1), "near the south side")
		local corner = ParachuteMotion.outward(Vector3.new(-3, DECK, -3))
		t.near(corner.X, -math.sqrt(0.5), 1e-6, "past a corner: diagonal")
		t.near(corner.Z, -math.sqrt(0.5), 1e-6)
		local aim = ParachuteMotion.ledgeAim(fromGap)
		t.truthy(aim.Y > DECK and aim.X == 0, "the lookback aims just over the ledge")
	end,

	["ParachuteMotion: the canopy's velocity and canonical path"] = function(t: Expect)
		local west = Vector3.new(-1, 0, 0)
		local velocity = ParachuteMotion.canopyVelocity(west, false)
		t.eq(velocity, Vector3.new(-ParachuteMotion.DriftSpeed, -GameConfig.ParachuteDescentSpeed, 0))
		t.eq(ParachuteMotion.canopyVelocity(west * 5 + Vector3.new(0, 3, 0), true).Y, -ParachuteMotion.HardDescentSpeed)
		t.eq(ParachuteMotion.canopyVelocity(Vector3.zero, false), Vector3.new(0, -GameConfig.ParachuteDescentSpeed, 0))
		local from = Vector3.new(-3, DECK, GAP_Z)
		local at = ParachuteMotion.canopyPosition(from, velocity, 2, GROUND + STAND)
		t.eq(at, from + velocity * 2)
		local late = ParachuteMotion.canopyPosition(from, velocity, 60, GROUND + STAND)
		t.eq(late.Y, GROUND + STAND, "never under the ground")
		t.eq(ParachuteMotion.canopyPosition(from, velocity, -1, 0), from, "no time, no motion")
	end,

	["ParachuteMotion: auto-deploy, landing and the fatal drop"] = function(t: Expect)
		local clearance = ParachuteMotion.AutoDeployClearance
		t.falsy(ParachuteMotion.autoDeployDue(GROUND + clearance + 0.5, GROUND))
		t.truthy(ParachuteMotion.autoDeployDue(GROUND + clearance, GROUND))
		t.truthy(ParachuteMotion.landed(GROUND + STAND + ParachuteMotion.LandingSlack, GROUND))
		t.falsy(ParachuteMotion.landed(GROUND + STAND + ParachuteMotion.LandingSlack + 0.2, GROUND))
		t.truthy(ParachuteMotion.landed(GROUND + 4.5, GROUND, 4), "a taller standing height")
		t.falsy(ParachuteMotion.fatal(DECK - ParachuteMotion.FatalDrop + 1))
		t.truthy(ParachuteMotion.fatal(DECK - ParachuteMotion.FatalDrop))
		t.truthy(
			(clearance - STAND) / ParachuteMotion.HardDescentSpeed >= 1.5,
			"an auto-deployed canopy still flies for a moment before the ground"
		)
	end,

	["ParachuteMotion: the descent verdict"] = function(t: Expect)
		local from = Vector3.new(-3, DECK, GAP_Z)
		local velocity = ParachuteMotion.canopyVelocity(Vector3.new(-1, 0, 0), false)
		local floor = GROUND + STAND
		local function verdict(position: Vector3, elapsed: number): (string, Vector3?)
			return ParachuteMotion.descentVerdict({
				position = position,
				from = from,
				velocity = velocity,
				elapsed = elapsed,
				floorY = floor,
			})
		end
		t.eq((verdict(from + Vector3.new(0, 30, 0), 0.5)), "Ok", "the opening's grace")
		t.eq((verdict(from + velocity * 4, 4)), "Ok", "on the path")
		t.eq((verdict(from + velocity * 4 - Vector3.new(0, 20, 0), 4)), "Ok", "falling faster is no advantage")
		local hovering, back = verdict(from + velocity * 4 + Vector3.new(0, ParachuteMotion.PathTolerance + 1, 0), 4)
		t.eq(hovering, "Correct", "hanging above the path")
		t.truthy(back ~= nil and (back - (from + velocity * 4)).Magnitude < 1e-6, "put back on the path")
		local steered, aside = verdict(from + velocity * 4 + Vector3.new(0, 0, ParachuteMotion.LateralTolerance + 1), 4)
		t.eq(steered, "Correct", "steered off the drift")
		t.truthy(aside ~= nil and math.abs(aside.Z - from.Z) < 1e-6, "back on the drift line")
	end,

	["ParachuteMotion: the jump gap's warnings"] = function(t: Expect)
		local near = Vector3.new(6, DECK + STAND, GAP_Z)
		t.eq(ParachuteMotion.edgeHint(near, false), "Hud.RoofNoPack", "no pack: the fall kills")
		t.eq(ParachuteMotion.edgeHint(near, true), "Hud.RoofLeap", "with a pack: how to go")
		t.eq(ParachuteMotion.edgeHint(Vector3.new(60, DECK + STAND, 60), false), nil, "far from the gap")
		t.eq(ParachuteMotion.edgeHint(OFF_EDGE - Vector3.new(0, 5, 0), true), nil, "already off the roof")
	end,

	["ParachuteMotion: the jumper's camera"] = function(t: Expect)
		local eye = Vector3.new(-40, 60, GAP_Z)
		local target = Vector3.new(0, DECK + 2.5, GAP_Z)
		local still = ParachuteMotion.lookback(eye, target, 3, 0)
		t.truthy((still.LookVector - (target - eye).Unit).Magnitude < 1e-4, "no motion: locked on the ledge")
		for _, time in { 0.7, 2.3, 5.1 } do
			local swaying = ParachuteMotion.lookback(eye, target, time, 1)
			local angle = math.acos(math.clamp(swaying.LookVector:Dot((target - eye).Unit), -1, 1))
			t.truthy(angle < math.rad(3), "the sway stays gentle")
		end
		local overhead = ParachuteMotion.lookback(eye, eye + Vector3.new(0, 30, 0), 0, 0)
		t.truthy(MathUtil.isFiniteVector(overhead.LookVector), "straight up never degenerates")
		t.eq(ParachuteMotion.deployJolt(0, 1), CFrame.identity)
		t.eq(ParachuteMotion.deployJolt(0.95, 1), CFrame.identity)
		t.truthy(ParachuteMotion.deployJolt(0.1, 1).Position.Y < 0, "yanked into the harness")
		t.eq(ParachuteMotion.deployJolt(0.1, 0), CFrame.identity, "motion off")
		local soft = ParachuteMotion.landingDip(0.2, false, 1).Position.Y
		local hard = ParachuteMotion.landingDip(0.2, true, 1).Position.Y
		t.truthy(soft < 0 and hard < soft, "a hard landing goes deeper")
		t.eq(ParachuteMotion.landingDip(0.8, false, 1), CFrame.identity, "a soft landing is over quickly")
		t.truthy(ParachuteMotion.landingDip(0.8, true, 1) ~= CFrame.identity, "a hard one takes longer")
	end,

	["ParachuteMotion: the landing field lies under the glide from the jump gap"] = function(t: Expect)
		local ext = SchoolShellBuilder.Exterior
		local field = ext.landing
		local floor = GROUND + STAND
		-- The cord pulled the moment they leave: the whole descent under the canopy.
		local from = Vector3.new(-(ParachuteMotion.OuterFace + ParachuteMotion.LeaveClear), DECK, GAP_Z)
		local velocity = ParachuteMotion.canopyVelocity(ParachuteMotion.outward(from), false)
		local seconds = (from.Y - floor) / -velocity.Y
		local down = ParachuteMotion.canopyPosition(from, velocity, seconds, floor)
		t.truthy(
			down.X > field.x and down.X < field.x + field.w and down.Z > field.z and down.Z < field.z + field.d,
			"an early pull lands in the field"
		)
		-- Never pulled: freefall straight down to the auto-deploy height, then the harder canopy.
		local opened = Vector3.new(from.X, GROUND + ParachuteMotion.AutoDeployClearance, GAP_Z)
		local hardVelocity = ParachuteMotion.canopyVelocity(ParachuteMotion.outward(from), true)
		local late = ParachuteMotion.canopyPosition(opened, hardVelocity, (opened.Y - floor) / -hardVelocity.Y, floor)
		for _, point in { down, late } do
			t.truthy(
				point.X > ext.minX and point.X < ext.maxX and point.Z > ext.minZ and point.Z < ext.maxZ,
				"over the street-level ground"
			)
			t.truthy(ParachuteMotion.outside(point) > 0 and not ParachuteMotion.inTower(point), "clear of the building")
		end
	end,

	["ParachuteService: grabCheck and advance"] = function(t: Expect)
		t.eq((ParachuteService.grabCheck("None", "Alive", true, true)), true)
		local ok, reason = ParachuteService.grabCheck("Packed", "Alive", true, true)
		t.falsy(ok)
		t.eq(reason, "Hud.ParachuteHaveOne")
		t.falsy((ParachuteService.grabCheck("None", "Downed", true, true)), "hands busy crawling")
		t.falsy((ParachuteService.grabCheck("None", "Alive", false, true)), "not on the live roof")
		t.falsy((ParachuteService.grabCheck("None", "Alive", true, false)), "someone else's")
		local function advance(state: Enums.ParachuteState, position: Vector3, extra: { [string]: any }?): string
			local input: ParachuteService.AdvanceInput = {
				state = state,
				position = position,
				groundY = GROUND,
				rootHeight = STAND,
				now = 10,
				since = 9,
				pullAt = nil,
				alive = true,
			}
			for key, value in (extra or {}) :: { [string]: any } do
				(input :: any)[key] = value
			end
			return ParachuteService.advance(input)
		end
		local high = Vector3.new(-6, DECK - 10, GAP_Z)
		t.eq(advance("Packed", ON_ROOF), "None")
		t.eq(advance("Packed", OFF_EDGE), "Leap")
		t.eq(advance("None", OFF_EDGE), "Fall")
		t.eq(advance("Freefall", high), "None")
		t.eq(advance("Freefall", high, { pullAt = 9.5 }), "Deploy")
		t.eq(advance("Freefall", high, { pullAt = 9 - ParachuteMotion.PullGrace + 0.05 }), "Deploy", "an early pull")
		t.eq(advance("Freefall", high, { pullAt = 9 - ParachuteMotion.PullGrace - 0.1 }), "None", "a stale pull")
		t.eq(advance("Freefall", high, { pullAt = 9.5, alive = false }), "None", "a downed jumper cannot pull")
		t.eq(advance("Freefall", Vector3.new(-6, GROUND + 20, GAP_Z)), "AutoDeploy")
		t.eq(advance("Freefall", high, { now = 9 + ParachuteMotion.FreefallMax }), "AutoDeploy")
		t.eq(advance("Freefall", Vector3.new(-6, GROUND + STAND, GAP_Z)), "LandHard")
		t.eq(advance("Canopy", high), "None")
		t.eq(advance("Canopy", Vector3.new(-6, GROUND + STAND + 0.5, GAP_Z)), "Land")
		t.eq(advance("Canopy", high, { now = 9 + ParachuteMotion.CanopyMax }), "ForceLand")
		t.eq(advance("Canopy", high, { groundY = nil }), "None", "nothing under it yet")
		t.eq(advance("Falling", high), "None")
		t.eq(advance("Falling", Vector3.new(-6, DECK - ParachuteMotion.FatalDrop, GAP_Z)), "Execute")
		t.eq(advance("Landed", Vector3.new(-6, GROUND + STAND, GAP_Z)), "None")
	end,

	["ParachuteService: one pack from the crate"] = function(t: Expect)
		withWorld({ "Alpha", "Bravo" }, function(world: World, players: { Player })
			local alpha, bravo = players[1], players[2]
			local pack = newPack(1)
			t.truthy(ParachuteService.Take(alpha, pack))
			t.eq(pack:GetAttribute(W.TakenByUserId), alpha.UserId)
			t.eq(world.shown[1].visible, false, "gone from the crate")
			t.eq(world.refreshed[1], pack, "its prompt closes")
			t.eq(soundCount(world, "PackBuckle"), 1)
			t.eq(world.notices[1].key, "Hud.ParachuteTaken")
			t.eq(ParachuteService.GetState(alpha), "Packed")
			t.eq(alpha:GetAttribute(P.Parachute), "Packed")
			t.falsy(ParachuteService.Take(alpha, newPack(2)), "one each")
			t.falsy(ParachuteService.Take(bravo, pack), "already taken")
			world.life[bravo] = "Downed"
			t.falsy(ParachuteService.Take(bravo, newPack(3)), "not while downed")
			world.life[bravo] = "Alive"
			world.live = false
			t.falsy(ParachuteService.Take(bravo, newPack(4)), "only on the live roof")
		end)
	end,

	["ParachuteService: the leap, the cord, the canopy and the landing"] = function(t: Expect)
		withWorld({ "Jumper" }, function(world: World, players: { Player })
			local jumper = players[1]
			local leaps: { boolean } = {}
			local opened: { boolean } = {}
			local downs: { boolean } = {}
			local c1 = ParachuteService.Leapt:Connect(function(_player: Player, packed: boolean)
				table.insert(leaps, packed)
			end)
			local c2 = ParachuteService.Deployed:Connect(function(_player: Player, auto: boolean)
				table.insert(opened, auto)
			end)
			local c3 = ParachuteService.Landed:Connect(function(_player: Player, hard: boolean)
				table.insert(downs, hard)
			end)
			leap(t, world, jumper)
			t.eq(leaps[1], true)
			local jump = ParachuteService.GetJump(jumper)
			t.truthy(jump ~= nil and jump.leftFrom == OFF_EDGE, "where they left")
			place(world, jumper, Vector3.new(-4, DECK - 8, GAP_Z))
			step(world)
			t.eq(ParachuteService.GetState(jumper), "Freefall", "falling until the cord")
			t.truthy(ParachuteService.Pull(jumper))
			step(world)
			t.eq(ParachuteService.GetState(jumper), "Canopy")
			t.eq(opened[1], false, "pulled, not auto")
			t.eq(world.descents[1].velocity, ParachuteMotion.canopyVelocity(Vector3.new(-1, 0, 0), false))
			t.eq(#world.canopies, 1, "the canopy is on")
			t.eq(world.overrides[1].state, "Parachuting")
			local cue = world.sounds[#world.sounds]
			t.truthy(cue.preset == "CanopyDeploy" and cue.except == jumper, "everyone else hears it open")
			t.eq(jumper:GetAttribute(P.Parachute), "Canopy")
			t.eq(jumper:GetAttribute(P.ParachuteAuto), nil)
			step(world, 3)
			t.eq(ParachuteService.GetState(jumper), "Canopy", "still descending")
			place(world, jumper, Vector3.new(-30, GROUND + STAND + 0.3, GAP_Z))
			step(world)
			t.eq(ParachuteService.GetState(jumper), "Landed")
			t.eq(downs[1], false, "a soft landing")
			t.eq(world.locks[1].reason, "Parachute")
			t.eq(world.locks[1].mode, "Anchor", "held for the finale camera")
			t.eq(world.overrides[2].push, false, "the override is gone")
			t.eq(#world.collapses, 1, "the canopy settles")
			t.eq(world.collapses[1].facing, Vector3.new(1, 0, 0), "behind them, as they face the school")
			t.eq(soundCount(world, "ParachuteLanding"), 1)
			t.eq(world.descents[1].instance.Parent, nil, "the descent is off")
			t.falsy(ParachuteService.Pull(jumper), "no cord on the ground")
			t.truthy(ParachuteService.IsHeld(jumper), "held for the finale camera")
			t.truthy(ParachuteService.ReleaseHold(jumper), "the finale lets them go")
			t.falsy(ParachuteService.IsHeld(jumper))
			local last = world.locks[#world.locks]
			t.truthy(last.reason == "Parachute" and last.mode == nil, "the hold is released")
			t.eq(ParachuteService.GetState(jumper), "Landed", "still down below")
			t.falsy(ParachuteService.ReleaseHold(jumper), "only once")
			c1:Disconnect()
			c2:Disconnect()
			c3:Disconnect()
		end)
	end,

	["ParachuteService: four players, four packs, four jumps"] = function(t: Expect)
		t.truthy(GameConfig.ParachutePackCount >= GameConfig.MaxSquad, "the crate holds a pack for a full squad")
		withWorld({ "One", "Two", "Three", "Four" }, function(world: World, players: { Player })
			t.eq(#players, GameConfig.ParachutePackCount, "a pack for every member of a full squad")
			local packs: { Model } = {}
			for index, player in players do
				local pack = newPack(index)
				packs[index] = pack
				t.truthy(ParachuteService.Take(player, pack), player.Name .. " takes pack " .. index)
			end
			local owners: { [number]: boolean } = {}
			for _, pack in packs do
				local owner = pack:GetAttribute(W.TakenByUserId)
				t.truthy(type(owner) == "number" and not owners[owner :: number], "one owner per pack")
				owners[owner :: number] = true
			end
			for index, player in players do
				place(world, player, OFF_EDGE + Vector3.new(0, 0, index - 2.5))
			end
			step(world)
			for index, player in players do
				t.eq(ParachuteService.GetState(player), "Freefall", player.Name .. " is off")
				if index % 2 == 0 then
					ParachuteService.Pull(player)
				end
			end
			step(world)
			for index, player in players do
				place(world, player, Vector3.new(-6, GROUND + 25, GAP_Z + index))
			end
			step(world)
			for index, player in players do
				t.eq(ParachuteService.GetState(player), "Canopy", player.Name .. " is under a canopy")
				t.eq(player:GetAttribute(P.ParachuteAuto) == true, index % 2 == 1, "pulled or opened by itself")
				place(world, player, Vector3.new(-40, GROUND + STAND, GAP_Z + index))
			end
			step(world)
			for _, player in players do
				t.eq(ParachuteService.GetState(player), "Landed")
			end
			t.eq(#ParachuteService.Jumpers(), 4)
			t.eq(#world.executed, 0)
		end)
	end,

	["ParachuteService: a pull that reaches the server before it sees the leap"] = function(t: Expect)
		withWorld({ "Quick", "Slow" }, function(world: World, players: { Player })
			local quick, slow = players[1], players[2]
			t.truthy(ParachuteService.Take(quick, newPack(1)))
			t.truthy(ParachuteService.Take(slow, newPack(2)))
			t.truthy(ParachuteService.Pull(quick), "pulled on the lip")
			step(world, 0.2)
			place(world, quick, OFF_EDGE)
			step(world)
			step(world)
			t.eq(ParachuteService.GetState(quick), "Canopy", "the pull counts")
			t.truthy(ParachuteService.Pull(slow), "pulled far too early")
			step(world, ParachuteMotion.PullGrace + 0.5)
			place(world, slow, OFF_EDGE)
			step(world)
			step(world)
			t.eq(ParachuteService.GetState(slow), "Freefall", "a stale pull does not")
		end)
	end,

	["ParachuteService: never pulled, the canopy opens by itself"] = function(t: Expect)
		withWorld({ "Frozen" }, function(world: World, players: { Player })
			local frozen = players[1]
			leap(t, world, frozen)
			place(world, frozen, Vector3.new(-5, GROUND + ParachuteMotion.AutoDeployClearance + 1, GAP_Z))
			step(world)
			t.eq(ParachuteService.GetState(frozen), "Freefall", "still above the safe height")
			place(world, frozen, Vector3.new(-5, GROUND + ParachuteMotion.AutoDeployClearance - 1, GAP_Z))
			step(world)
			t.eq(ParachuteService.GetState(frozen), "Canopy", "opened low, by itself")
			t.eq(frozen:GetAttribute(P.ParachuteAuto), true)
			t.eq(world.descents[1].velocity.Y, -ParachuteMotion.HardDescentSpeed, "a late, faster canopy")
			place(world, frozen, Vector3.new(-12, GROUND + STAND, GAP_Z))
			step(world)
			t.eq(ParachuteService.GetState(frozen), "Landed")
			t.eq(soundCount(world, "HardLanding"), 1, "a hard landing")
			t.eq(#world.executed, 0, "fair: nobody dies with a pack on")
			local jump = ParachuteService.GetJump(frozen)
			t.truthy(jump ~= nil and jump.hard and jump.auto)
		end)
	end,

	["ParachuteService: a freefall held in the air is opened"] = function(t: Expect)
		withWorld({ "Hover" }, function(world: World, players: { Player })
			local hover = players[1]
			leap(t, world, hover)
			place(world, hover, Vector3.new(-6, DECK - 4, GAP_Z))
			step(world, ParachuteMotion.FreefallMax - 0.1)
			t.eq(ParachuteService.GetState(hover), "Freefall")
			step(world, 0.2)
			t.eq(ParachuteService.GetState(hover), "Canopy", "the server opens it")
			world.ground = nil
			step(world, ParachuteMotion.CanopyMax + 0.1)
			t.eq(ParachuteService.GetState(hover), "Landed", "a canopy stuck in the air is put down")
			t.eq(#world.teleports, 1, "on the ground under it")
			t.eq(world.teleports[1].cframe.Position.Y, GROUND + STAND, "the street when nothing answered the cast")
		end)
	end,

	["ParachuteService: jumping without a pack is fatal"] = function(t: Expect)
		withWorld({ "Reckless" }, function(world: World, players: { Player })
			local reckless = players[1]
			local leaps: { boolean } = {}
			local connection = ParachuteService.Leapt:Connect(function(_player: Player, packed: boolean)
				table.insert(leaps, packed)
			end)
			place(world, reckless, OFF_EDGE)
			step(world)
			t.eq(ParachuteService.GetState(reckless), "Falling")
			t.eq(leaps[1], false)
			place(world, reckless, Vector3.new(-4, DECK - ParachuteMotion.FatalDrop + 2, GAP_Z))
			step(world)
			t.eq(#world.executed, 0, "still falling")
			place(world, reckless, Vector3.new(-4, DECK - ParachuteMotion.FatalDrop - 1, GAP_Z))
			step(world)
			t.eq(#world.executed, 1)
			t.eq(world.executed[1].cause, "Fall")
			step(world)
			t.eq(ParachuteService.GetState(reckless), "None", "dead: the jump is over")
			t.eq(reckless:GetAttribute(P.Parachute), nil)
			t.eq(ParachuteService.Pull(reckless), false)
			connection:Disconnect()
		end)
	end,

	["ParachuteService: a pack goes back to the crate"] = function(t: Expect)
		withWorld({ "Fallen", "Leaver" }, function(world: World, players: { Player })
			local fallen, leaver = players[1], players[2]
			local first, second = newPack(1), newPack(2)
			t.truthy(ParachuteService.Take(fallen, first))
			t.truthy(ParachuteService.Take(leaver, second))
			world.life[fallen] = "Dead"
			step(world)
			t.eq(first:GetAttribute(W.TakenByUserId), nil, "its wearer died")
			t.eq(world.shown[#world.shown].visible, true, "back in the crate")
			t.eq(world.refreshed[#world.refreshed], first, "its prompt opens again")
			ParachuteService.OnPlayerRemoving(leaver)
			t.eq(second:GetAttribute(W.TakenByUserId), nil, "its wearer left")
			t.eq(ParachuteService.GetState(leaver), "None")
			world.life[fallen] = "Alive"
			t.truthy(ParachuteService.Take(fallen, second), "and it can be taken again")
		end)
	end,

	["ParachuteService: a downed jumper"] = function(t: Expect)
		withWorld({ "Crawler" }, function(world: World, players: { Player })
			local crawler = players[1]
			t.truthy(ParachuteService.Take(crawler, newPack(1)))
			world.life[crawler] = "Downed"
			place(world, crawler, OFF_EDGE)
			step(world)
			t.eq(ParachuteService.GetState(crawler), "Freefall", "crawled off the edge with the pack on")
			t.falsy(ParachuteService.Pull(crawler), "no hands for the cord")
			place(world, crawler, Vector3.new(-4, GROUND + 20, GAP_Z))
			step(world)
			t.eq(ParachuteService.GetState(crawler), "Canopy", "the auto-deploy saves them")
			place(world, crawler, Vector3.new(-10, GROUND + STAND, GAP_Z))
			step(world)
			t.eq(ParachuteService.GetState(crawler), "Landed")
			t.eq(#world.revived, 1, "back on their feet: they made it out")
			t.eq(world.revived[1].fraction, ParachuteService.LandingRevive)
		end)
	end,

	["ParachuteService: the scripted landing"] = function(t: Expect)
		withWorld({ "Floating" }, function(world: World, players: { Player })
			local floating = players[1]
			t.falsy(ParachuteService.ForceLand(floating), "nobody in the air")
			leap(t, world, floating)
			t.truthy(ParachuteService.Pull(floating))
			step(world)
			place(world, floating, Vector3.new(-40, 70, GAP_Z + 2))
			t.truthy(ParachuteService.ForceLand(floating))
			t.eq(ParachuteService.GetState(floating), "Landed")
			local cframe = world.teleports[1].cframe
			t.eq(cframe.Position, Vector3.new(-40, GROUND + STAND, GAP_Z + 2), "straight down onto the ground")
			t.truthy(cframe.LookVector:Dot(Vector3.new(1, 0, 0)) > 0.99, "facing the school")
			t.falsy(ParachuteService.ForceLand(floating), "only once")
		end)
	end,

	["ParachuteService: the descent validator"] = function(t: Expect)
		withWorld({ "Glider", "Walker" }, function(world: World, players: { Player })
			local glider, walker = players[1], players[2]
			t.eq((ParachuteService.DescentValidator(walker, world.roots[walker], 0.1)), "Ok", "not parachuting")
			leap(t, world, glider)
			t.truthy(ParachuteService.Pull(glider))
			step(world)
			local jump = ParachuteService.GetJump(glider)
			assert(jump and jump.deployFrom and jump.velocity, "an open canopy")
			local from, velocity = jump.deployFrom :: Vector3, jump.velocity :: Vector3
			step(world, 3)
			local elapsed = world.now - (jump.deployedAt :: number)
			place(world, glider, from + velocity * elapsed)
			t.eq((ParachuteService.DescentValidator(glider, world.roots[glider], 0.1)), "Ok", "on the path")
			place(world, glider, from + velocity * elapsed + Vector3.new(0, 12, 0))
			local verdict, back = ParachuteService.DescentValidator(glider, world.roots[glider], 0.1)
			t.eq(verdict, "Correct", "hovering")
			t.truthy(back ~= nil and (back - (from + velocity * elapsed)).Magnitude < 1e-3, "put back on the path")
		end)
	end,

	["ParachuteService: the run's end clears every jump"] = function(t: Expect)
		withWorld({ "Lander" }, function(world: World, players: { Player })
			local lander = players[1]
			leap(t, world, lander)
			t.truthy(ParachuteService.Pull(lander))
			step(world)
			place(world, lander, Vector3.new(-30, GROUND + STAND, GAP_Z))
			step(world)
			t.eq(ParachuteService.GetState(lander), "Landed")
			ParachuteService.EndRun()
			t.eq(ParachuteService.GetState(lander), "None")
			t.eq(lander:GetAttribute(P.Parachute), nil)
			t.eq(lander:GetAttribute(P.ParachuteAt), nil)
			local last = world.locks[#world.locks]
			t.truthy(last.reason == "Parachute" and last.mode == nil, "the hold is released")
			t.eq(#ParachuteService.Jumpers(), 0)
		end)
	end,
}
