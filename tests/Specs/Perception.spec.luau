--!strict
-- Perception (docs/MONSTER.md 3.2 and 3.3; web/src/creature/perception.js). Eyes: the Creature's eye is
-- EyeHeightAboveRoot[PoseMode] up its root frame and EyeForward ahead (at the Tall Man rig's pupil height, straight
-- behind them inside the root's half depth); a player's eye is their root + CameraConfig.EyeHeightAboveRoot[MoveState].
-- Ranges: 70 with the torch on, 38 lit by the fixtures, 20 in the dark; crouched x0.75; x the difficulty. The cone is
-- measured about the upright axis (floor-plane bearing and distance): 55 degrees (75 while they move) plus the 6-stud
-- (10 moving) peripheral sense, which a LookAway switches off. Never seen: not playing, Hiding, in a duct or a crawlway,
-- Underwater unless it swims; no sighting through a wall. Score and rank. The stare: 7 degrees of its head for the
-- second, within 45 (it stands lit or their torch is on) or 18, with a clear line.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local Perception = require(ServerScriptService.Services.Monster.MonsterAIService.Perception)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Viewer = Perception.Viewer
type Observation = Perception.Observation

local C = Attributes.Creature
local SENSES = CreatureConfig.Senses
local STARE = CreatureConfig.Stare
local EPS = 1e-6
local POSITION_EPS = 1e-4 -- CFrame maths runs in single precision
local FORWARD = Vector3.new(0, 0, -1)
local DIFFICULTIES: { Enums.Difficulty } = { "Standard", "Nightmare" }

--------------------------------------------------------------------------------
-- Builders
--------------------------------------------------------------------------------

local nextUserId = 8100

local function newPlayer(): Player
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "PerceptionSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	return player
end

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
		aquatic = false,
		targetUserId = nil,
		blindPeripheral = false,
		raycast = clearRay,
	}
end

local function observationOf(player: Player, eye: Vector3, torch: boolean?, lit: boolean?): Observation
	return {
		player = player,
		eye = eye,
		playing = true,
		downed = false,
		moveState = "Standing",
		torch = torch == true,
		lit = lit == true,
		moving = false,
		inVent = false,
	}
end

local function ahead(distance: number): Vector3
	return FORWARD * distance
end

local function multiplier(difficulty: Enums.Difficulty): number
	return (if difficulty == "Nightmare" then DifficultyConfig.Nightmare else DifficultyConfig.Standard).sightRangeMultiplier
end

-- The bearing in degrees between `facing` and `target - eye`, both flattened onto the floor.
local function flatAngle(eye: Vector3, facing: Vector3, target: Vector3): number
	local f = Vector3.new(facing.X, 0, facing.Z)
	local o = Vector3.new(target.X - eye.X, 0, target.Z - eye.Z)
	if f.Magnitude < EPS or o.Magnitude < EPS then
		return 0
	end
	return math.deg(math.acos(math.clamp(f.Unit:Dot(o.Unit), -1, 1)))
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["sightRange: 70 with the torch, 38 lit, 20 dark; crouched x0.75; times the difficulty"] = function(t: Expect)
		t.eq(SENSES.SightTorch, 70)
		t.eq(SENSES.SightLit, 38)
		t.eq(SENSES.SightDark, 20)
		t.eq(SENSES.CrouchFactor, 0.75)
		local p = newPlayer()
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			local m = multiplier(difficulty)
			t.near(Perception.sightRange(observationOf(p, Vector3.zero, true), difficulty), 70 * m, EPS, "torch")
			t.near(Perception.sightRange(observationOf(p, Vector3.zero, false, true), difficulty), 38 * m, EPS, "lit")
			t.near(Perception.sightRange(observationOf(p, Vector3.zero), difficulty), 20 * m, EPS, "dark")
			t.near(
				Perception.sightRange(observationOf(p, Vector3.zero, true, true), difficulty),
				70 * m,
				EPS,
				"the torch wins over the light"
			)
			for _, state: Enums.MoveState in { "Crouching", "DownedCrawling" } :: { Enums.MoveState } do
				local crouched = observationOf(p, Vector3.zero, false, true)
				crouched.moveState = state
				t.near(Perception.sightRange(crouched, difficulty), 38 * 0.75 * m, EPS, state .. " x0.75")
			end
			t.near(Perception.fullRange(difficulty), 70 * m, EPS, "the full range")
		end
		t.truthy(multiplier("Nightmare") > multiplier("Standard"), "Nightmare sees farther")
	end,

	["inViewCone: the cone and the peripheral sense about the upright axis"] = function(t: Expect)
		local half = SENSES.SightHalfAngle
		local peripheral = SENSES.PeripheralRange
		local eye = Vector3.new(3, 10.34, 7)
		local function at(angleDeg: number, distance: number, drop: number?): Vector3
			local radians = math.rad(angleDeg)
			return eye + Vector3.new(math.sin(radians) * distance, -(drop or 0), -math.cos(radians) * distance)
		end
		t.truthy(Perception.inViewCone(eye, FORWARD, at(0, 60), half, peripheral), "dead ahead")
		t.truthy(Perception.inViewCone(eye, FORWARD, at(half - 1, 60), half, peripheral), "just inside the cone")
		t.falsy(Perception.inViewCone(eye, FORWARD, at(half + 1, 60), half, peripheral), "just outside the cone")
		t.falsy(Perception.inViewCone(eye, FORWARD, at(180, 60), half, peripheral), "behind, far")
		t.truthy(Perception.inViewCone(eye, FORWARD, at(180, peripheral - 0.5), half, peripheral), "behind, close")
		t.falsy(Perception.inViewCone(eye, FORWARD, at(180, peripheral + 0.5), half, peripheral), "behind, beyond")
		-- it stands 11 tall: whoever is at its feet (8 studs below the eye) is in front of it, never under its view
		t.truthy(Perception.inViewCone(eye, FORWARD, at(0, 3, 8), half, 0), "a downed player at its feet, ahead")
		t.truthy(Perception.inViewCone(eye, FORWARD, at(170, 3, 8), half, peripheral), "felt at its heels")
		t.truthy(Perception.inViewCone(eye, FORWARD, eye - Vector3.new(0, 9, 0), half, 0), "straight below")
		t.falsy(Perception.inViewCone(eye, Vector3.new(0, -1, 0), at(0, 30), half, 0), "a facing straight down")
		t.truthy(Perception.inViewCone(eye, Vector3.zero, at(90, 5), half, peripheral), "no facing, still the sense")
		local random = Random.new(51)
		for _ = 1, 400 do
			local facing = random:NextUnitVector()
			local target = eye + random:NextUnitVector() * random:NextNumber(0.5, 120)
			local angle = flatAngle(eye, facing, target)
			local flatFacing = Vector3.new(facing.X, 0, facing.Z).Magnitude
			local inside = Perception.inViewCone(eye, facing, target, half, 0)
			if flatFacing > 1e-3 and math.abs(angle - half) > 1e-3 then
				t.eq(inside, angle < half, string.format("bearing %.3f vs half %.1f", angle, half))
			end
			local floor = Vector3.new(target.X - eye.X, 0, target.Z - eye.Z).Magnitude
			if floor <= peripheral then
				t.truthy(Perception.inViewCone(eye, facing, target, half, peripheral), "inside the sense")
			end
		end
	end,

	["creatureEye: EyeHeightAboveRoot[PoseMode] up the root, EyeForward ahead, behind the rig's pupils"] = function(
		t: Expect
	)
		t.truthy(Perception.EyeForward < CreatureConfig.Rig.RootSize.Z / 2, "the eye stays inside the root's depth")
		local frame = CFrame.new(10, 6, -4) * CFrame.Angles(0, math.rad(37), 0)
		local model = creatureModel(frame)
		for _, mode: Enums.PoseMode in Enums.PoseMode do
			model:SetAttribute(C.PoseMode, mode)
			local eye = Perception.creatureEye(model)
			local fromRoot = eye - frame.Position
			local expected = CreatureConfig.EyeHeightAboveRoot[mode] or CreatureConfig.EyeHeightAboveRoot.Biped
			t.near(fromRoot:Dot(frame.UpVector), expected, POSITION_EPS, mode .. " height")
			t.near(fromRoot:Dot(frame.LookVector), Perception.EyeForward, POSITION_EPS, mode .. " ahead")
			t.near(fromRoot:Dot(frame.RightVector), 0, POSITION_EPS, mode .. " centred")
		end
		model:SetAttribute(C.PoseMode, "Biped")
		model:SetAttribute(C.MonsterState, "Stunned")
		t.eq(Perception.poseOf(model), "Stunned", "stunned: the clawing pose's eye")
		model:SetAttribute(C.MonsterState, "Patrol")
		model:SetAttribute(C.PoseMode, "Sideways")
		t.eq(Perception.poseOf(model), "Biped", "unknown pose: Biped")
		local bare = Instance.new("Model")
		bare.WorldPivot = CFrame.new(1, 2, 3)
		local pivotEye = Perception.creatureEye(bare)
		local expected = Vector3.new(1, 2 + CreatureConfig.EyeHeightAboveRoot.Biped, 3 - Perception.EyeForward)
		t.near((pivotEye - expected).Magnitude, 0, POSITION_EPS, "no root: the model's pivot stands in")

		-- the Tall Man rig: the Biped eye is level with its pupils, straight behind them (the mask juts out past the
		-- root, so the sight line starts inside the body and never from beyond a wall it stands against)
		local base = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(-20), 0)
		local rig = CreatureRigBuilder.build(Instance.new("Folder"), base)
		local names = CreatureRigBuilder.PartNames
		local left = rig:FindFirstChild(names.LeftPupil, true)
		local right = rig:FindFirstChild(names.RightPupil, true)
		local rigRoot = rig.PrimaryPart
		assert(left and left:IsA("BasePart") and right and right:IsA("BasePart") and rigRoot, "the rig has pupils")
		local pupils = rigRoot.CFrame:PointToObjectSpace((left.CFrame.Position + right.CFrame.Position) / 2)
		local eye = rigRoot.CFrame:PointToObjectSpace(Perception.creatureEye(rig))
		t.near(eye.Y, pupils.Y, 0.05, "level with the pupils")
		t.near(eye.X, pupils.X, 0.05, "between them")
		t.truthy(-pupils.Z > Perception.EyeForward, "the pupils are ahead of the eye")
		t.truthy(-pupils.Z - Perception.EyeForward < 1.5, "a short way: " .. (-pupils.Z - Perception.EyeForward))
	end,

	["playerEye: root + CameraConfig.EyeHeightAboveRoot[MoveState]; nil without a character"] = function(t: Expect)
		local player = newPlayer()
		t.eq(Perception.playerEye(player), nil, "no character, no eye")
		local root = Vector3.new(4, 3, -9)
		giveCharacter(player, root)
		local eye = Perception.playerEye(player)
		assert(eye, "an eye")
		t.near((eye - root).Y, CameraConfig.EyeHeightAboveRoot.Standing, EPS, "a standing (default) player")
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

	["judge: only playing players; never Hiding, in a duct or a crawlway; Downed ones are seen"] = function(t: Expect)
		local viewer = viewerAt(Vector3.zero)
		local player = newPlayer()
		t.truthy(Perception.judge(viewer, observationOf(player, ahead(6), true)), "a playing player at point blank")
		local ghost = observationOf(player, ahead(6), true)
		ghost.playing = false
		t.eq(Perception.judge(viewer, ghost), nil, "not playing")
		t.eq(Perception.excluded(viewer, ghost), "NotPlaying", "reason")
		local hiding = observationOf(player, ahead(2), true)
		hiding.moveState = "Hiding"
		t.eq(Perception.judge(viewer, hiding), nil, "a hiding spot hides you even at arm's length")
		t.eq(Perception.excluded(viewer, hiding), "Hiding", "reason")
		local crawling = observationOf(player, ahead(3), true)
		crawling.inVent = true
		crawling.moveState = "Crouching"
		t.eq(Perception.judge(viewer, crawling), nil, "it never looks into a crawlway or a duct")
		t.eq(Perception.excluded(viewer, crawling), "InVent", "reason")
		local downed = observationOf(player, ahead(10))
		downed.downed = true
		downed.moveState = "DownedCrawling"
		t.truthy(Perception.judge(viewer, downed), "a Downed player is seen")
	end,

	["judge: a blocked ray is no sighting, and the ray runs eye to eye after the cheap rules"] = function(t: Expect)
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
		t.eq(rays[1][2], target.eye, "to the player's eye")
		local close = observationOf(newPlayer(), viewer.eye + Vector3.new(0, 0, 2), true)
		t.eq(Perception.judge(viewer, close), nil, "not even point blank behind a wall")
		table.clear(rays)
		t.eq(Perception.judge(viewer, observationOf(newPlayer(), viewer.eye + ahead(500), true)), nil, "out of range")
		t.eq(#rays, 0, "no ray for a player the cheaper rules already rule out")
	end,

	["judge: the dark hides you at 20, the light shows you at 38, the torch gives you away at 70"] = function(
		t: Expect
	)
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			local viewer = viewerAt(Vector3.zero, FORWARD, difficulty)
			local m = multiplier(difficulty)
			local p = newPlayer()
			t.truthy(Perception.judge(viewer, observationOf(p, ahead(20 * m - 0.5))), "dark, in range")
			t.eq(Perception.judge(viewer, observationOf(p, ahead(20 * m + 0.5))), nil, "dark, beyond")
			t.truthy(Perception.judge(viewer, observationOf(p, ahead(38 * m - 0.5), false, true)), "lit, in range")
			t.eq(Perception.judge(viewer, observationOf(p, ahead(38 * m + 0.5), false, true)), nil, "lit, beyond")
			t.truthy(Perception.judge(viewer, observationOf(p, ahead(70 * m - 0.5), true)), "torch, in range")
			t.eq(Perception.judge(viewer, observationOf(p, ahead(70 * m + 0.5), true)), nil, "torch, beyond")
			local crouched = observationOf(p, ahead(20 * 0.75 * m + 0.5))
			crouched.moveState = "Crouching"
			t.eq(Perception.judge(viewer, crouched), nil, "a crouched player in the dark is seen only closer")
		end
	end,

	["judge: the cone widens for a mover, the peripheral sense reaches farther, a LookAway blinds it"] = function(
		t: Expect
	)
		local viewer = viewerAt(Vector3.zero)
		local p = newPlayer()
		local function atBearing(degrees: number, distance: number): Vector3
			local r = math.rad(degrees)
			return Vector3.new(math.sin(r), 0, -math.cos(r)) * distance
		end
		local side = observationOf(p, atBearing(65, 15), true)
		t.eq(Perception.judge(viewer, side), nil, "65 degrees off: outside a still player's cone")
		side.moving = true
		t.truthy(Perception.judge(viewer, side), "inside a mover's 75")
		local behind = observationOf(p, atBearing(180, 8), true)
		t.eq(Perception.judge(viewer, behind), nil, "8 behind a still player: unfelt")
		behind.moving = true
		local felt = Perception.judge(viewer, behind)
		assert(felt, "8 behind a mover: felt")
		t.falsy(felt.inCone, "felt, not in the cone")
		local close = observationOf(p, atBearing(180, 4), true)
		t.truthy(Perception.judge(viewer, close), "4 behind: felt")
		viewer.blindPeripheral = true
		t.eq(Perception.judge(viewer, close), nil, "looking away: nothing felt behind")
		t.truthy(Perception.judge(viewer, observationOf(p, ahead(15), true)), "but what it looks at it sees")
		local seen = Perception.judge(viewerAt(Vector3.zero), observationOf(p, ahead(30), true))
		assert(seen, "ahead")
		t.truthy(seen.inCone, "in the cone")
		t.near(seen.distance, 30, EPS, "distance eye to eye")
		t.eq(seen.player, p, "the player")
		t.truthy(seen.lit, "the torch shows them")
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
		t.truthy(scoreOf(observationOf(p, ahead(10), true)) > scoreOf(observationOf(p, ahead(30), true)), "closer")
		t.truthy(scoreOf(observationOf(p, ahead(15), true)) > scoreOf(observationOf(p, ahead(15))), "lit")
		local side = Vector3.new(0, 0, 1) * (SENSES.PeripheralRange - 2)
		t.truthy(
			scoreOf(observationOf(p, ahead(SENSES.PeripheralRange - 2))) > scoreOf(observationOf(p, side)),
			"in the cone beats the corner of its eye"
		)
		local targeting = viewerAt(Vector3.zero)
		targeting.targetUserId = p.UserId
		t.truthy(scoreOf(observationOf(p, ahead(15)), targeting) > scoreOf(observationOf(p, ahead(15))), "target")
		local downed = observationOf(p, ahead(15))
		downed.downed = true
		t.truthy(scoreOf(observationOf(p, ahead(15))) > scoreOf(downed), "Downed after standing")
		t.eq(Perception.score(0, 70, false, false, false, false), Perception.ScoreWeights.Closeness, "closeness 1")
		t.eq(Perception.score(200, 70, false, false, false, false), 0, "closeness clamps at 0")
		local a, b, c = newPlayer(), newPlayer(), newPlayer()
		local ranked = Perception.rank({
			{ player = a, eye = ahead(30), distance = 30, inCone = true, lit = false, score = 0.5 },
			{ player = b, eye = ahead(10), distance = 10, inCone = true, lit = false, score = 0.9 },
			{ player = c, eye = ahead(20), distance = 20, inCone = true, lit = false, score = 0.5 },
		})
		t.eq(ranked[1].player, b, "best score first")
		t.eq(ranked[2].player, c, "equal scores: nearer first")
		t.eq(ranked[3].player, a, "then the farther one")
		local seen = Perception.scan(viewer, {
			observationOf(a, ahead(40), true),
			observationOf(b, ahead(12), true),
			observationOf(c, ahead(500), true),
		})
		t.eq(#seen, 2, "scan leaves out who it cannot see")
		t.eq(seen[1].player, b, "best first")
	end,

	["property: every sighting passes every rule, and every player passing them is seen"] = function(t: Expect)
		local random = Random.new(73)
		local states: { Enums.MoveState } = { "Standing", "Crouching", "Sprinting", "Hiding", "DownedCrawling" }
		for trial = 1, 600 do
			local difficulty: Enums.Difficulty = DIFFICULTIES[random:NextInteger(1, 2)]
			local eye = Vector3.new(random:NextNumber(-50, 50), random:NextNumber(0, 11), random:NextNumber(-50, 50))
			local facing = random:NextUnitVector()
			local viewer = viewerAt(eye, facing, difficulty)
			viewer.blindPeripheral = random:NextNumber() < 0.2
			local clear = random:NextNumber() < 0.7
			local rays = 0
			viewer.raycast = function(_from: Vector3, _to: Vector3): boolean
				rays += 1
				return clear
			end
			local o = observationOf(
				newPlayer(),
				eye + random:NextUnitVector() * random:NextNumber(0.5, 90),
				random:NextNumber() < 0.4,
				random:NextNumber() < 0.5
			)
			o.playing = random:NextNumber() < 0.85
			o.moveState = states[random:NextInteger(1, #states)]
			o.moving = random:NextNumber() < 0.5
			o.inVent = random:NextNumber() < 0.1
			local sighting = Perception.judge(viewer, o)
			local distance = (o.eye - eye).Magnitude
			local half = if o.moving then SENSES.MovingHalfAngle else SENSES.SightHalfAngle
			local peripheral = if viewer.blindPeripheral
				then 0
				elseif o.moving then SENSES.MovingPeripheralRange
				else SENSES.PeripheralRange
			local passes = o.playing
				and o.moveState ~= "Hiding"
				and not o.inVent
				and distance <= Perception.sightRange(o, difficulty)
				and Perception.inViewCone(eye, facing, o.eye, half, peripheral)
				and clear
			t.eq(sighting ~= nil, passes, "trial " .. trial)
			if sighting then
				t.eq(rays, 1, "a sighting always cast its ray")
				t.near(sighting.distance, distance, EPS, "distance")
				t.eq(sighting.lit, o.torch or o.lit, "lit")
			end
		end
	end,

	["stare: 7 degrees of its head, 45 when it stands lit or the torch is on, 18 in the dark, never through a wall"] = function(
		t: Expect
	)
		t.eq(STARE.HalfAngle, 7)
		t.eq(STARE.Seconds, 1)
		local head = Vector3.new(0, 10, -30)
		local eye = Vector3.new(0, 4.5, 0)
		local straight = (head - eye).Unit
		-- turned `degrees` away from the head about an axis square to the line of sight
		local side = straight:Cross(Vector3.new(1, 0, 0)).Unit
		local function rotated(degrees: number): Vector3
			return CFrame.fromAxisAngle(side, math.rad(degrees)):VectorToWorldSpace(straight)
		end
		t.near(Perception.stareAngle(eye, straight, head), 0, 1e-3, "straight at it")
		t.near(Perception.stareAngle(eye, rotated(5), head), 5, 1e-2, "5 degrees off")
		t.eq(Perception.stareAngle(eye, Vector3.zero, head), 180, "no look")
		t.eq(Perception.stareRange(true, false), 45, "torch on")
		t.eq(Perception.stareRange(false, true), 45, "it stands lit")
		t.eq(Perception.stareRange(false, false), 18, "dark")
		local looker: Perception.Looker = { eye = eye, look = straight, torch = true }
		t.truthy(Perception.staring(looker, head, false, clearRay), "a lit stare at 30")
		looker.look = rotated(6.5)
		t.truthy(Perception.staring(looker, head, false, clearRay), "6.5 degrees is still a stare")
		looker.look = rotated(8)
		t.falsy(Perception.staring(looker, head, false, clearRay), "8 degrees is not")
		looker.look = straight
		looker.torch = false
		t.falsy(Perception.staring(looker, head, false, clearRay), "in the dark 30 is too far")
		t.truthy(Perception.staring(looker, head, true, clearRay), "unless it stands lit")
		t.falsy(
			Perception.staring(looker, head, true, function(_a: Vector3, _b: Vector3): boolean
				return false
			end),
			"never through a wall"
		)
		local near = { eye = head + Vector3.new(0, -5.5, 15), look = Vector3.new(0, 5.5, -15).Unit, torch = false }
		t.truthy(Perception.staring(near, head, false, clearRay), "close enough in the dark")
	end,
}
