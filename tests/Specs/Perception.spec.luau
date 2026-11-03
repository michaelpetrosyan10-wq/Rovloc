--!strict
-- Perception. Eyes: the Creature's eye is EyeHeightAboveRoot[PoseMode] up its root frame and EyeForward ahead (at the
-- real rig's pupils for Biped, never past the root's half depth); a player's EyePoint is their root +
-- CameraConfig.EyeHeightAboveRoot[MoveState]. Ranges: lit at SightRange x difficulty, dark at
-- DarknessSightMultiplier of that. Cone: SightHalfAngle around the facing plus the PeripheralRange sphere. Rules
-- (judge): not playing / Hiding / Underwater (unless the Creature swims) / in a vent (unless the Creature is in the
-- same or an adjacent duct) are never seen; Downed players are; a blocked ray means no sighting (no seeing through
-- walls) and the ray runs eye to EyePoint. A random sweep checks every sighting passes every rule and every player
-- passing every rule is seen. Score ordering (close, lit, in-cone, current target; Downed after standing) and rank.
-- The viewer reads the model (facing, PoseMode, aquatic, TargetUserId, its duct edge from VentSegmentId or the rail),
-- and scan() runs end to end on the real player services.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Tags = require(ReplicatedStorage.Shared.Tags)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local VentShaftBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.VentShaftBuilder)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)

local FlashlightService = require(ServerScriptService.Services.Player.FlashlightService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local Perception = require(ServerScriptService.Services.Monster.MonsterAIService.Perception)
local VentNetworkService = require(ServerScriptService.Services.Vents.VentNetworkService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Viewer = Perception.Viewer
type Observation = Perception.Observation

local C = Attributes.Creature
local W = Attributes.World
local SENSES = CreatureConfig.Senses
local EPS = 1e-6
local POSITION_EPS = 1e-4 -- CFrame maths runs in single precision
local FORWARD = Vector3.new(0, 0, -1)
local DIFFICULTIES: { Enums.Difficulty } = { "Standard", "Nightmare" }
local SPEC_LEVEL = "PerceptionSpecLevel"

--------------------------------------------------------------------------------
-- Builders
--------------------------------------------------------------------------------

local nextUserId = 8100

local function newPlayer(): Player
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "PerceptionSpec" .. nextUserId
	player.UserId = nextUserId
	return player
end

-- A character with just a root at `position` (what the server reads: it never sees limbs).
local function giveCharacter(player: Player, position: Vector3): Model
	local model = Instance.new("Model")
	model.Name = player.Name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(position)
	root.Parent = model
	model.PrimaryPart = root
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = GameConfig.MaxHealth
	humanoid.Health = GameConfig.MaxHealth
	humanoid.Parent = model
	player.Character = model
	return model
end

-- A Creature model with a root at `cframe`.
local function creatureModel(cframe: CFrame): Model
	local model = Instance.new("Model")
	model.Name = "Creature"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = CreatureConfig.Rig.RootSize
	root.CFrame = cframe
	root.Parent = model
	model.PrimaryPart = root
	model:SetAttribute(C.PoseMode, "Biped")
	return model
end

local function clearRay(_from: Vector3, _to: Vector3): boolean
	return true
end

local function viewerAt(eye: Vector3, facing: Vector3?, difficulty: Enums.Difficulty?): Viewer
	return {
		eye = eye,
		facing = facing or FORWARD,
		difficulty = difficulty or "Standard",
		inVent = false,
		ventNodes = nil,
		aquatic = false,
		targetUserId = nil,
		raycast = clearRay,
	}
end

local function observationOf(player: Player, eye: Vector3, lit: boolean?): Observation
	return {
		player = player,
		eye = eye,
		playing = true,
		downed = false,
		moveState = "Standing",
		lit = lit == true,
		inVent = false,
		rail = nil,
	}
end

-- Straight ahead of a viewer at the origin facing -Z.
local function ahead(distance: number): Vector3
	return FORWARD * distance
end

-- a - b - c - d in a row along -Z (10 studs apart) plus a grate stub on b; segments a-b, b-c (c-d has none).
local function rowGraph(): VentGraph.Graph
	local nodes: { [string]: VentGraph.Node } = {
		a = { id = "a", position = Vector3.new(0, 0, 0), links = { "b" }, grateId = nil },
		b = { id = "b", position = Vector3.new(0, 0, -10), links = { "a", "c" }, grateId = "g" },
		c = { id = "c", position = Vector3.new(0, 0, -20), links = { "b", "d" }, grateId = nil },
		d = { id = "d", position = Vector3.new(0, 0, -30), links = { "c" }, grateId = nil },
	}
	local wall = CFrame.lookAt(Vector3.new(1, 0, -10), Vector3.new(2, 0, -10))
	return {
		levelId = SPEC_LEVEL,
		nodes = nodes,
		grates = {
			g = {
				id = "g",
				nodeId = "b",
				facingZoneId = "Room",
				lockable = false,
				criticalPath = false,
				wall = wall,
				mouth = wall.Position + wall.LookVector * VentGraph.MouthOut,
			},
		},
		grateAtNode = { b = "g" },
		segments = { ["a|b"] = "a-b", ["b|a"] = "a-b", ["b|c"] = "b-c", ["c|b"] = "b-c" },
	}
end

-- A level holding rowGraph's ducts as instances (VentNodeRoot attachments + VentShaft floors), for VentGraph.build.
local function rowLevel(): Model
	local level = Instance.new("Model")
	level.Name = SPEC_LEVEL
	local vents = Instance.new("Folder")
	vents.Name = "Vents"
	vents.Parent = level
	local root = Instance.new("Part")
	root.Name = VentShaftBuilder.RootName
	root.CFrame = CFrame.identity
	root.Parent = vents
	local links: { [string]: string } = { a = "b", b = "a,c", c = "b,d", d = "c" }
	for id, linked in links do
		local attachment = Instance.new("Attachment")
		attachment.Name = "VentNode_" .. id
		attachment.CFrame = CFrame.new(rowGraph().nodes[id].position)
		attachment:SetAttribute(W.NodeId, id)
		attachment:SetAttribute(W.Links, linked)
		attachment:AddTag(Tags.VentNode)
		attachment.Parent = root
	end
	for _, pair in { { "a", "b" }, { "b", "c" } } do
		local floor = Instance.new("Part")
		floor.Name = "Duct_" .. pair[1] .. pair[2]
		floor:SetAttribute(W.SegmentId, ZoneGraph.segmentId(pair[1], pair[2]))
		floor:AddTag(Tags.VentShaft)
		floor.Parent = vents
	end
	return level
end

local function railAt(graph: VentGraph.Graph, position: Vector3): VentGraph.RailPoint
	local rail = VentGraph.nearest(graph, position)
	assert(rail, "position projects onto the rail")
	return rail
end

local function sameSet(a: { string }?, b: { string }): boolean
	if a == nil or #a ~= #b then
		return false
	end
	for _, id in b do
		if table.find(a, id) == nil then
			return false
		end
	end
	return true
end

local function spec(difficulty: Enums.Difficulty): DifficultyConfig.DifficultySpec
	return if difficulty == "Nightmare" then DifficultyConfig.Nightmare else DifficultyConfig.Standard
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["visibleRange: lit at SightRange x difficulty, dark at DarknessSightMultiplier of it"] = function(t: Expect)
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			local full = SENSES.SightRange * spec(difficulty).sightRangeMultiplier
			t.near(Perception.visibleRange(true, difficulty), full, EPS, difficulty .. " lit")
			t.near(
				Perception.visibleRange(false, difficulty),
				full * SENSES.DarknessSightMultiplier,
				EPS,
				difficulty .. " dark"
			)
			t.truthy(
				Perception.visibleRange(false, difficulty) < Perception.visibleRange(true, difficulty),
				"dark < lit"
			)
		end
		t.truthy(
			Perception.visibleRange(false, "Nightmare") > Perception.visibleRange(false, "Standard"),
			"Nightmare sees farther"
		)
	end,

	["inViewCone: the cone around the facing, the peripheral sphere, and a sweep matching the angle"] = function(
		t: Expect
	)
		local half = SENSES.SightHalfAngle
		local peripheral = SENSES.PeripheralRange
		local eye = Vector3.new(3, 5, 7)
		local function at(angleDeg: number, distance: number): Vector3
			local radians = math.rad(angleDeg)
			return eye + Vector3.new(math.sin(radians), 0, -math.cos(radians)) * distance
		end
		t.truthy(Perception.inViewCone(eye, FORWARD, at(0, 60), half, peripheral), "dead ahead")
		t.truthy(Perception.inViewCone(eye, FORWARD, at(half - 1, 60), half, peripheral), "just inside the cone")
		t.falsy(Perception.inViewCone(eye, FORWARD, at(half + 1, 60), half, peripheral), "just outside the cone")
		t.falsy(Perception.inViewCone(eye, FORWARD, at(180, 60), half, peripheral), "behind, far")
		t.truthy(Perception.inViewCone(eye, FORWARD, at(180, peripheral - 0.5), half, peripheral), "behind, close")
		t.falsy(Perception.inViewCone(eye, FORWARD, at(180, peripheral + 0.5), half, peripheral), "behind, beyond")
		t.truthy(Perception.inViewCone(eye, FORWARD, eye, half, 0), "the eye's own spot")
		t.falsy(Perception.inViewCone(eye, Vector3.zero, at(0, 30), half, peripheral), "no facing, no cone")
		t.truthy(Perception.inViewCone(eye, Vector3.zero, at(90, 5), half, peripheral), "no facing, still the sphere")

		local random = Random.new(51)
		for _ = 1, 400 do
			local facing = random:NextUnitVector()
			local target = eye + random:NextUnitVector() * random:NextNumber(0.5, 120)
			local angle = math.deg(math.acos(math.clamp(facing:Dot((target - eye).Unit), -1, 1)))
			local inside = Perception.inViewCone(eye, facing, target, half, 0)
			if math.abs(angle - half) > 1e-3 then
				t.eq(inside, angle < half, string.format("angle %.3f vs half %.1f", angle, half))
			end
			if (target - eye).Magnitude <= peripheral then
				t.truthy(Perception.inViewCone(eye, facing, target, half, peripheral), "inside the sphere")
			end
		end
	end,

	["creatureEye: EyeHeightAboveRoot[PoseMode] up the root, EyeForward ahead, at the rig's pupils"] = function(
		t: Expect
	)
		t.truthy(Perception.EyeForward < CreatureConfig.Rig.RootSize.Z / 2, "the eye stays inside the root's depth")
		local frame = CFrame.new(10, 6, -4) * CFrame.Angles(0, math.rad(37), 0)
		local model = creatureModel(frame)
		for _, mode: Enums.PoseMode in Enums.PoseMode do
			model:SetAttribute(C.PoseMode, mode)
			local eye = Perception.creatureEye(model)
			local fromRoot = eye - frame.Position
			t.near(
				fromRoot:Dot(frame.UpVector),
				CreatureConfig.EyeHeightAboveRoot[mode],
				POSITION_EPS,
				mode .. " height"
			)
			t.near(fromRoot:Dot(frame.LookVector), Perception.EyeForward, POSITION_EPS, mode .. " ahead")
			t.near(fromRoot:Dot(frame.RightVector), 0, POSITION_EPS, mode .. " centred")
		end
		model:SetAttribute(C.PoseMode, "Sideways")
		local fallback = Perception.creatureEye(model) - frame.Position
		t.near(
			fallback:Dot(frame.UpVector),
			CreatureConfig.EyeHeightAboveRoot.Biped,
			POSITION_EPS,
			"unknown pose: Biped"
		)
		local bare = Instance.new("Model")
		bare.WorldPivot = CFrame.new(1, 2, 3)
		local pivotEye = Perception.creatureEye(bare)
		local expected = Vector3.new(1, 2 + CreatureConfig.EyeHeightAboveRoot.Biped, 3 - Perception.EyeForward)
		t.near((pivotEye - expected).Magnitude, 0, POSITION_EPS, "no root: the model's pivot stands in")

		local base = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(-20), 0)
		local rig = CreatureRigBuilder.build(Instance.new("Folder"), base)
		local names = CreatureRigBuilder.PartNames
		local left = rig:FindFirstChild(names.LeftPupil, true)
		local right = rig:FindFirstChild(names.RightPupil, true)
		assert(left and left:IsA("BasePart") and right and right:IsA("BasePart"), "the rig has pupils")
		local pupils = (left.CFrame.Position + right.CFrame.Position) / 2
		local gap = (Perception.creatureEye(rig) - pupils).Magnitude
		t.truthy(gap < 0.5, "the Biped eye sits at the pupils: " .. gap)
	end,

	["playerEye: root + CameraConfig.EyeHeightAboveRoot[MoveState]; nil without a character"] = function(t: Expect)
		local player = newPlayer()
		t.eq(Perception.playerEye(player), nil, "no character, no eye")
		local root = Vector3.new(4, 3, -9)
		giveCharacter(player, root)
		local eye = Perception.playerEye(player)
		assert(eye, "an eye")
		t.near((eye - root).Y, CameraConfig.EyeHeightAboveRoot.Standing, EPS, "a standing (default) player")
		local offset = eye - root
		t.near(Vector3.new(offset.X, 0, offset.Z).Magnitude, 0, EPS, "straight above the root")
		for _, state: Enums.MoveState in Enums.MoveState do
			local at = Perception.playerEyeAt(root, state)
			t.near(at.Y - root.Y, CameraConfig.EyeHeightAboveRoot[state], EPS, state)
		end
		t.near(
			Perception.playerEyeAt(root, "Nope").Y - root.Y,
			CameraConfig.EyeHeightAboveRoot.Standing,
			EPS,
			"unknown"
		)
	end,

	["judge: only playing players; Hiding ones never; Downed ones are seen"] = function(t: Expect)
		local viewer = viewerAt(Vector3.zero)
		local player = newPlayer()
		local close = observationOf(player, ahead(6), true)
		t.truthy(Perception.judge(viewer, close), "a playing player at point blank")

		local ghost = observationOf(player, ahead(6), true)
		ghost.playing = false
		t.eq(Perception.judge(viewer, ghost), nil, "not playing")
		t.eq(Perception.excluded(viewer, ghost), "NotPlaying", "reason")

		local hiding = observationOf(player, ahead(2), true)
		hiding.moveState = "Hiding"
		t.eq(Perception.judge(viewer, hiding), nil, "a locker hides you even at arm's length")
		t.eq(Perception.excluded(viewer, hiding), "Hiding", "reason")

		local downed = observationOf(player, ahead(20))
		downed.downed = true
		downed.moveState = "DownedCrawling"
		t.truthy(Perception.judge(viewer, downed), "a Downed player is seen")
	end,

	["judge: a blocked ray is no sighting, and the ray runs eye to EyePoint"] = function(t: Expect)
		local viewer = viewerAt(Vector3.new(1, 2, 3))
		local rays: { { Vector3 } } = {}
		viewer.raycast = function(from: Vector3, to: Vector3): boolean
			table.insert(rays, { from, to })
			return false
		end
		local target = observationOf(newPlayer(), Vector3.new(1, 2, -20), true)
		t.eq(Perception.judge(viewer, target), nil, "never through a wall")
		t.eq(#rays, 1, "one ray")
		t.eq(rays[1][1], viewer.eye, "from the Creature's eye")
		t.eq(rays[1][2], target.eye, "to the player's EyePoint")

		local close = observationOf(newPlayer(), viewer.eye + Vector3.new(0, 0, 2), true)
		t.eq(Perception.judge(viewer, close), nil, "not even point blank behind a wall")

		table.clear(rays)
		local far = observationOf(newPlayer(), viewer.eye + ahead(500), true)
		t.eq(Perception.judge(viewer, far), nil, "out of range")
		t.eq(#rays, 0, "no ray is cast for a player the cheaper rules already rule out")
	end,

	["judge: darkness shortens sight unless the flashlight is on; Nightmare sees farther"] = function(t: Expect)
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			local viewer = viewerAt(Vector3.zero, FORWARD, difficulty)
			local dark = Perception.visibleRange(false, difficulty)
			local lit = Perception.visibleRange(true, difficulty)
			local player = newPlayer()
			t.truthy(Perception.judge(viewer, observationOf(player, ahead(dark - 0.5), false)), "dark, in range")
			t.eq(Perception.judge(viewer, observationOf(player, ahead(dark + 0.5), false)), nil, "dark, beyond")
			t.truthy(
				Perception.judge(viewer, observationOf(player, ahead(dark + 0.5), true)),
				"the torch gives you away"
			)
			t.truthy(Perception.judge(viewer, observationOf(player, ahead(lit - 0.5), true)), "lit, in range")
			t.eq(Perception.judge(viewer, observationOf(player, ahead(lit + 0.5), true)), nil, "lit, beyond")
		end
	end,

	["judge: the view cone and the peripheral sphere"] = function(t: Expect)
		local viewer = viewerAt(Vector3.zero)
		local player = newPlayer()
		local behindFar = observationOf(player, Vector3.new(0, 0, SENSES.PeripheralRange + 1), true)
		t.eq(Perception.judge(viewer, behindFar), nil, "behind, beyond the sphere")
		local behindClose = observationOf(player, Vector3.new(0, 0, SENSES.PeripheralRange - 1), true)
		local felt = Perception.judge(viewer, behindClose)
		assert(felt, "behind, inside the sphere: noticed")
		t.falsy(felt.inCone, "noticed peripherally, not in the cone")
		local seen = Perception.judge(viewer, observationOf(player, ahead(30), true))
		assert(seen, "ahead")
		t.truthy(seen.inCone, "in the cone")
		t.near(seen.distance, 30, EPS, "distance eye to eye")
		t.eq(seen.player, player, "the player")
		t.eq(seen.eye, ahead(30), "their EyePoint")
		t.truthy(seen.lit, "lit")
	end,

	["judge: a player in a vent is seen only from the same or an adjacent duct"] = function(t: Expect)
		local graph = rowGraph()
		local player = newPlayer()
		local function inDuct(position: Vector3): Observation
			local observation = observationOf(player, position)
			observation.inVent = true
			observation.moveState = "VentCrawling"
			observation.rail = railAt(graph, position)
			return observation
		end
		local onFoot = viewerAt(Vector3.new(0, 0, 8))
		t.eq(Perception.judge(onFoot, inDuct(Vector3.new(0, 0, -3))), nil, "a Creature on foot never sees into ducts")
		t.eq(Perception.excluded(onFoot, inDuct(Vector3.new(0, 0, -3))), "InVent", "reason")

		local crawler = viewerAt(Vector3.new(0, 0, -2))
		crawler.inVent = true
		crawler.ventNodes = { "a", "b" }
		t.truthy(Perception.judge(crawler, inDuct(Vector3.new(0, 0, -8))), "the same duct")
		t.truthy(Perception.judge(crawler, inDuct(Vector3.new(0, 0, -16))), "the next duct (shares b)")
		local stub = graph.grates.g.mouth:Lerp(graph.nodes.b.position, 0.3)
		t.truthy(Perception.judge(crawler, inDuct(stub)), "the grate stub off b")
		t.eq(Perception.judge(crawler, inDuct(Vector3.new(0, 0, -27))), nil, "two ducts along (c-d)")

		local lost = viewerAt(Vector3.new(0, 0, -2))
		lost.inVent = true
		lost.ventNodes = nil
		t.eq(Perception.judge(lost, inDuct(Vector3.new(0, 0, -8))), nil, "unknown duct: not seen")

		local noRail = inDuct(Vector3.new(0, 0, -8))
		noRail.rail = nil
		t.eq(Perception.judge(crawler, noRail), nil, "a crawler with no rail point: not seen")

		local roomPlayer = observationOf(newPlayer(), Vector3.new(0, 0, -30), true)
		t.truthy(Perception.judge(crawler, roomPlayer), "from a duct the ray decides for players outside")
	end,

	["judge: Underwater players only by a swimming Creature"] = function(t: Expect)
		local player = newPlayer()
		local diver = observationOf(player, ahead(10))
		diver.moveState = "Underwater"
		local walker = viewerAt(Vector3.zero)
		t.eq(Perception.judge(walker, diver), nil, "on foot")
		t.eq(Perception.excluded(walker, diver), "Underwater", "reason")
		local swimmer = viewerAt(Vector3.zero)
		swimmer.aquatic = true
		t.truthy(Perception.judge(swimmer, diver), "swimming")
		local treading = observationOf(player, ahead(10))
		treading.moveState = "Treading"
		t.truthy(Perception.judge(walker, treading), "a player at the surface is in plain view")
	end,

	["score + rank: close, lit, in-cone and the current target first; Downed after standing"] = function(t: Expect)
		local viewer = viewerAt(Vector3.zero)
		local function scoreOf(observation: Observation, v: Viewer?): number
			local sighting = Perception.judge(v or viewer, observation)
			assert(sighting, "seen")
			return sighting.score
		end
		local p = newPlayer()
		t.truthy(scoreOf(observationOf(p, ahead(10))) > scoreOf(observationOf(p, ahead(30))), "closer")
		t.truthy(scoreOf(observationOf(p, ahead(20), true)) > scoreOf(observationOf(p, ahead(20), false)), "lit")
		local side = Vector3.new(0, 0, 1) * (SENSES.PeripheralRange - 2)
		t.truthy(
			scoreOf(observationOf(p, ahead(SENSES.PeripheralRange - 2))) > scoreOf(observationOf(p, side)),
			"in the cone beats the corner of its eye"
		)
		local targeting = viewerAt(Vector3.zero)
		targeting.targetUserId = p.UserId
		t.truthy(scoreOf(observationOf(p, ahead(20)), targeting) > scoreOf(observationOf(p, ahead(20))), "target")
		local downed = observationOf(p, ahead(20))
		downed.downed = true
		t.truthy(scoreOf(observationOf(p, ahead(20))) > scoreOf(downed), "Downed after standing")
		t.eq(Perception.score(0, 95, false, false, false, false), Perception.ScoreWeights.Closeness, "closeness 1")
		t.eq(Perception.score(200, 95, false, false, false, false), 0, "closeness clamps at 0")

		local a, b, c = newPlayer(), newPlayer(), newPlayer()
		local ranked = Perception.rank({
			{ player = a, eye = ahead(30), distance = 30, inCone = true, lit = false, score = 0.5 },
			{ player = b, eye = ahead(10), distance = 10, inCone = true, lit = false, score = 0.9 },
			{ player = c, eye = ahead(20), distance = 20, inCone = true, lit = false, score = 0.5 },
		})
		t.eq(ranked[1].player, b, "best score first")
		t.eq(ranked[2].player, c, "equal scores: nearer first")
		t.eq(ranked[3].player, a, "then the farther one")
	end,

	["property: every sighting passes every rule, and every player passing them is seen"] = function(t: Expect)
		local random = Random.new(73)
		local states: { Enums.MoveState } = { "Standing", "Crouching", "Sprinting", "Hiding", "DownedCrawling" }
		for trial = 1, 600 do
			local difficulty: Enums.Difficulty = DIFFICULTIES[random:NextInteger(1, 2)]
			local eye = Vector3.new(random:NextNumber(-50, 50), random:NextNumber(0, 8), random:NextNumber(-50, 50))
			local viewer = viewerAt(eye, random:NextUnitVector(), difficulty)
			local clear = random:NextNumber() < 0.7
			local rays = 0
			viewer.raycast = function(_from: Vector3, _to: Vector3): boolean
				rays += 1
				return clear
			end
			local observation = observationOf(
				newPlayer(),
				eye + random:NextUnitVector() * random:NextNumber(0.5, 130),
				random:NextNumber() < 0.5
			)
			observation.playing = random:NextNumber() < 0.85
			observation.moveState = states[random:NextInteger(1, #states)]
			local sighting = Perception.judge(viewer, observation)
			local distance = (observation.eye - eye).Magnitude
			local passes = observation.playing
				and observation.moveState ~= "Hiding"
				and distance <= Perception.visibleRange(observation.lit, difficulty)
				and Perception.inViewCone(
					eye,
					viewer.facing,
					observation.eye,
					SENSES.SightHalfAngle,
					SENSES.PeripheralRange
				)
				and clear
			t.eq(sighting ~= nil, passes, "trial " .. trial)
			if sighting then
				t.eq(rays, 1, "a sighting always cast its ray")
				t.near(sighting.distance, distance, EPS, "distance")
				t.eq(
					sighting.inCone,
					Perception.inViewCone(eye, viewer.facing, observation.eye, SENSES.SightHalfAngle, 0),
					"inCone"
				)
				t.eq(sighting.lit, observation.lit, "lit")
			end
		end
	end,

	["vent edges: SegmentId to nodes, the rail piece under a point, adjacency"] = function(t: Expect)
		local graph = rowGraph()
		t.truthy(sameSet(Perception.segmentNodes(graph, "a-b"), { "a", "b" }), "a-b")
		t.truthy(sameSet(Perception.segmentNodes(graph, "b-c"), { "b", "c" }), "b-c")
		t.eq(Perception.segmentNodes(graph, "c-d"), nil, "a duct with no floor part carries no SegmentId")
		t.truthy(sameSet(Perception.railNodes(graph, Vector3.new(0.5, 0, -25)), { "c", "d" }), "on c-d")
		t.truthy(sameSet(Perception.railNodes(graph, graph.grates.g.mouth), { "b" }), "on the grate stub")
		t.eq(Perception.railNodes(graph, Vector3.new(60, 0, 0)), nil, "far off the rail")
		t.truthy(Perception.ventsAdjacent({ "a", "b" }, railAt(graph, Vector3.new(0, 0, -4))), "same")
		t.truthy(Perception.ventsAdjacent({ "c", "d" }, railAt(graph, Vector3.new(0, 0, -14))), "adjacent")
		t.falsy(Perception.ventsAdjacent({ "a", "b" }, railAt(graph, Vector3.new(0, 0, -25))), "two along")
	end,

	["viewer: the model's facing, PoseMode, swimming, TargetUserId and duct edge"] = function(t: Expect)
		local frame = CFrame.lookAt(Vector3.new(0, 4, 0), Vector3.new(10, 4, 0))
		local model = creatureModel(frame)
		local ctx: Perception.SightContext =
			{ difficulty = "Nightmare", creatureInVent = false, creatureSegment = nil, raycast = clearRay }
		local viewer = Perception.viewer(model, ctx)
		t.near((viewer.facing - frame.LookVector).Magnitude, 0, EPS, "facing")
		t.near((viewer.eye - Perception.creatureEye(model)).Magnitude, 0, EPS, "eye")
		t.eq(viewer.difficulty, "Nightmare", "difficulty")
		t.falsy(viewer.aquatic, "on foot")
		t.eq(viewer.targetUserId, nil, "no target")
		t.eq(viewer.ventNodes, nil, "not in a vent")
		t.eq(viewer.raycast, clearRay, "the injected ray")

		model:SetAttribute(C.TargetUserId, 4242)
		model:SetAttribute(C.PoseMode, "Swim")
		viewer = Perception.viewer(model, ctx)
		t.eq(viewer.targetUserId, 4242, "target")
		t.truthy(viewer.aquatic, "PoseMode Swim")
		model:SetAttribute(C.PoseMode, "Biped")
		model:SetAttribute(C.MonsterState, "AquaticStalk")
		t.truthy(Perception.viewer(model, ctx).aquatic, "AquaticStalk")
		model:SetAttribute(C.TargetUserId, 0)
		t.eq(Perception.viewer(model, ctx).targetUserId, nil, "0 = no target")

		local level = rowLevel()
		VentNetworkService.SetLevelRoot(SPEC_LEVEL, level)
		local ok, err = pcall(function()
			local crawler = creatureModel(CFrame.lookAt(Vector3.new(0, 0, -12), Vector3.new(0, 0, -30)))
			crawler:SetAttribute(C.LevelId, SPEC_LEVEL)
			crawler:SetAttribute(C.PoseMode, "Quadruped")
			local inVent: Perception.SightContext =
				{ difficulty = "Standard", creatureInVent = true, creatureSegment = "b-c", raycast = clearRay }
			t.truthy(sameSet(Perception.viewer(crawler, inVent).ventNodes, { "b", "c" }), "from VentSegmentId")
			inVent.creatureSegment = nil
			t.truthy(sameSet(Perception.viewer(crawler, inVent).ventNodes, { "b", "c" }), "from the rail")
			local root = crawler.PrimaryPart
			assert(root, "root")
			root.CFrame = CFrame.new(0, 0, -26)
			inVent.creatureSegment = "no-such"
			t.truthy(sameSet(Perception.viewer(crawler, inVent).ventNodes, { "c", "d" }), "unknown id: the rail")
		end)
		VentNetworkService.SetLevelRoot(SPEC_LEVEL, nil)
		if not ok then
			error(err, 0)
		end
	end,

	["scan: the real player services decide who is playing and lit; best first"] = function(t: Expect)
		local creature = creatureModel(CFrame.lookAt(Vector3.new(0, 5, 0), Vector3.new(0, 5, -100)))
		local near, far, lobby = newPlayer(), newPlayer(), newPlayer()
		giveCharacter(near, Vector3.new(2, 4, -20))
		giveCharacter(far, Vector3.new(-3, 4, -45))
		giveCharacter(lobby, Vector3.new(0, 4, -10))
		local nobody = newPlayer()
		local ok, err = pcall(function()
			LifeStateService.SetAlive(near)
			LifeStateService.SetAlive(far)
			t.truthy(FlashlightService.SetOn(far, true), "far switches the torch on")
			local ctx: Perception.SightContext =
				{ difficulty = "Standard", creatureInVent = false, creatureSegment = nil, raycast = clearRay }
			local seen = Perception.scan(creature, { lobby, far, near, nobody }, ctx)
			t.eq(#seen, 2, "the lobby player and the one without a character are not candidates")
			t.eq(seen[1].player, near, "the nearer player first")
			t.eq(seen[2].player, far, "then the farther one")
			t.falsy(seen[1].lit, "near is dark")
			t.truthy(seen[2].lit, "far is lit")
			local nearEye = Perception.playerEye(near)
			assert(nearEye, "near has an eye")
			t.eq(seen[1].eye, nearEye, "EyePoint")

			creature:SetAttribute(C.TargetUserId, far.UserId)
			local sticky = Perception.scan(creature, { near, far }, ctx)
			t.eq(sticky[1].player, far, "the current (lit) target keeps the lead over a nearer player")

			local walled: Perception.SightContext = {
				difficulty = "Standard",
				creatureInVent = false,
				creatureSegment = nil,
				raycast = function(_from: Vector3, to: Vector3): boolean
					return (to - nearEye).Magnitude > EPS
				end,
			}
			local blocked = Perception.scan(creature, { near, far }, walled)
			t.eq(#blocked, 1, "a wall hides near")
			t.eq(blocked[1].player, far, "far is still seen")

			ctx.raycast = nil
			t.eq(#Perception.scan(creature, { near, far }, ctx), 2, "the default ray (no geometry in the harness)")
		end)
		FlashlightService.ForceOff(far)
		LifeStateService.SetLobby(near)
		LifeStateService.SetLobby(far)
		if not ok then
			error(err, 0)
		end
	end,
}
