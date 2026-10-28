--!strict
-- CrawlRules: VentNetworkService's pure entry, exit and rail rules (specs: tests/Specs/VentNetwork.spec.luau).
--
-- Positions are judged in a grate's wall frame (wallSpace): x along the wall (the grate attachment's RightVector),
-- y up, z out into the room along its LookVector, measured from the opening's centre on the wall's centre plane.
--
-- Entry (canEnter + inMouthBox + facesWall). A playing participant who is Alive, on foot, Crouching, free of control
-- locks and not already crawling, whose root stands in an open grate's mouth box: in front of the room face
-- (WallThickness / 2 <= z <= WallThickness / 2 + MouthDepth), at most MouthHalfWidth to either side of the opening's
-- centre, and at a crouched root height over the floor in front of it (the root's standing height above the floor,
-- give or take CrouchBelow / CrouchAbove), while their look faces into the wall (look . -LookVector >= FacingDot).
-- They are moved to the grate's EntryAnchor with the root lifted onto the duct centreline (entryCFrame).
--
-- Exit (canExit + crossedFace). A crawler (Alive or Downed: a downed crawler can drag themselves out) whose root has
-- crossed the room face of an open grate's mouth stub: z >= WallThickness / 2 - 0.1 (and no farther out than
-- ExitReach, inside the bore's square), with no control lock. They stand up at the grate's ExitAnchor, or at one of
-- the points ExitSideStep to either side of it (exitCandidates), the first whose standing box (standingBox) is clear.
--
-- Rail (railVerdict). A crawler's root within RailTolerance of the rail is fine; within RailCorrectReach it is put
-- back on the nearest rail point; farther than that is a strike, and they go back to the last rail point they were
-- fine at.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Types = require(ReplicatedStorage.Shared.Types)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

export type EntryCheck = {
	live: boolean, -- the run is live (Deploying / InRun)
	participant: boolean,
	lifeState: Enums.LifeState,
	inVent: boolean, -- already crawling
	onFoot: boolean, -- PlayerStateService mode OnFoot
	moveState: Enums.MoveState,
	controlLock: Enums.ControlLock,
	hasBody: boolean, -- a living character with a root
}

export type ExitCheck = {
	live: boolean,
	lifeState: Enums.LifeState,
	controlLock: Enums.ControlLock,
	hasBody: boolean,
}

local WALL_HALF = WorldConfig.WallThickness / 2
local HALF_BORE = WorldConfig.VentBore / 2

local MOUTH_DEPTH = 2.4
local MOUTH_HALF_WIDTH = 1.6
local CROUCH_BELOW = 1.5 -- a crouched root may sit this far below its standing height over the floor
local CROUCH_ABOVE = 1 -- or this far above it (standing on a kicked panel)
local FACING_DOT = 0.4
local EXIT_DEPTH = WALL_HALF - 0.1
local EXIT_REACH = WALL_HALF + 3
local EXIT_SIDE_STEP = 0.75
local STAND_SIZE = Vector3.new(2, 4.6, 2) -- a standing R15 body, shoulders to heels
local STAND_LIFT = 0.3 -- the box starts this far above the floor, so the floor itself never fills it
local RAIL_TOLERANCE = 1.25
local RAIL_CORRECT_REACH = 4

local CrawlRules = {}

CrawlRules.MouthDepth = MOUTH_DEPTH
CrawlRules.MouthHalfWidth = MOUTH_HALF_WIDTH
CrawlRules.CrouchBelow = CROUCH_BELOW
CrawlRules.CrouchAbove = CROUCH_ABOVE
CrawlRules.FacingDot = FACING_DOT
CrawlRules.ExitDepth = EXIT_DEPTH
CrawlRules.ExitReach = EXIT_REACH
CrawlRules.ExitSideStep = EXIT_SIDE_STEP
CrawlRules.StandSize = STAND_SIZE
CrawlRules.StandLift = STAND_LIFT
CrawlRules.RailTolerance = RAIL_TOLERANCE
CrawlRules.RailCorrectReach = RAIL_CORRECT_REACH

-- `point` in the wall frame of `wall` (x along the wall, y up, z out into the room).
function CrawlRules.wallSpace(wall: CFrame, point: Vector3): Vector3
	local p = wall:PointToObjectSpace(point)
	return Vector3.new(p.X, p.Y, -p.Z)
end

-- Where a character's root sits above the floor it stands on: HipHeight plus half the root's height.
function CrawlRules.rootHeight(hipHeight: number, rootSizeY: number): number
	return hipHeight + rootSizeY / 2
end

-- Whether a player may start crawling in, and why not.
function CrawlRules.canEnter(check: EntryCheck): (boolean, string?)
	if not check.live then
		return false, "NoRun"
	end
	if not check.participant then
		return false, "NotParticipant"
	end
	if check.lifeState ~= "Alive" then
		return false, "LifeState"
	end
	if check.inVent then
		return false, "InVent"
	end
	if not check.hasBody then
		return false, "NoBody"
	end
	if check.controlLock ~= "None" then
		return false, "Locked"
	end
	if not check.onFoot then
		return false, "Mode"
	end
	if check.moveState ~= "Crouching" then
		return false, "MoveState"
	end
	return true, nil
end

-- Whether a root at `rootPosition` stands in the mouth box of the grate whose wall frame is `wall`, over a floor at
-- world height `floorY`, for a character whose root stands `rootHeight` above its floor.
function CrawlRules.inMouthBox(wall: CFrame, rootPosition: Vector3, floorY: number, rootHeight: number): boolean
	if not MathUtil.isFiniteVector(rootPosition) then
		return false
	end
	local p = CrawlRules.wallSpace(wall, rootPosition)
	local out = p.Z - WALL_HALF
	if out < 0 or out > MOUTH_DEPTH or math.abs(p.X) > MOUTH_HALF_WIDTH then
		return false
	end
	local above = rootPosition.Y - floorY
	return above >= rootHeight - CROUCH_BELOW and above <= rootHeight + CROUCH_ABOVE
end

-- Whether a look (yaw, pitch radians; MathUtil.vectorFromYawPitch) faces into the wall of `wall`.
function CrawlRules.facesWall(wall: CFrame, yaw: number, pitch: number): boolean
	if not (MathUtil.isFinite(yaw) and MathUtil.isFinite(pitch)) then
		return false
	end
	return MathUtil.vectorFromYawPitch(yaw, pitch):Dot(-wall.LookVector) >= FACING_DOT
end

-- The root CFrame a player entering through a grate is moved to: the EntryAnchor (in the bore behind the opening,
-- facing into the duct), lifted so the root rides the duct centreline at `centreY`.
function CrawlRules.entryCFrame(entryAnchor: CFrame, centreY: number): CFrame
	local p = entryAnchor.Position
	return CFrame.new(p.X, centreY, p.Z) * entryAnchor.Rotation
end

-- Whether a crawler may come out of a grate, and why not.
function CrawlRules.canExit(check: ExitCheck): (boolean, string?)
	if not check.live then
		return false, "NoRun"
	end
	if check.lifeState ~= "Alive" and check.lifeState ~= "Downed" then
		return false, "LifeState"
	end
	if not check.hasBody then
		return false, "NoBody"
	end
	if check.controlLock ~= "None" then
		return false, "Locked"
	end
	return true, nil
end

-- Whether a crawler's root has crossed the room face of the grate whose wall frame is `wall`.
function CrawlRules.crossedFace(wall: CFrame, rootPosition: Vector3): boolean
	if not MathUtil.isFiniteVector(rootPosition) then
		return false
	end
	local p = CrawlRules.wallSpace(wall, rootPosition)
	return p.Z >= EXIT_DEPTH and p.Z <= EXIT_REACH and math.abs(p.X) <= HALF_BORE and math.abs(p.Y) <= HALF_BORE
end

-- Where a crawler may stand up in front of a grate, in order of preference: its ExitAnchor (floor level, facing
-- into the room), then ExitSideStep to its left and to its right.
function CrawlRules.exitCandidates(exitAnchor: CFrame): { CFrame }
	return {
		exitAnchor,
		exitAnchor * CFrame.new(-EXIT_SIDE_STEP, 0, 0),
		exitAnchor * CFrame.new(EXIT_SIDE_STEP, 0, 0),
	}
end

-- The box a body standing on `candidate` (a floor-level CFrame) fills: its CFrame and size.
function CrawlRules.standingBox(candidate: CFrame): (CFrame, Vector3)
	return candidate * CFrame.new(0, STAND_LIFT + STAND_SIZE.Y / 2, 0), STAND_SIZE
end

-- The root CFrame of a character standing on `candidate` whose root stands `rootHeight` above its floor.
function CrawlRules.exitRootCFrame(candidate: CFrame, rootHeight: number): CFrame
	return CFrame.new(candidate.Position + Vector3.new(0, rootHeight, 0)) * candidate.Rotation
end

-- The rail validator's verdict for a crawler's root at `position` on `graph`: ("Ok", nil, railPoint) on the rail,
-- ("Correct", nearest rail point) within RailCorrectReach, else ("Strike", lastGood or the nearest rail point). A
-- graph without a rail has nothing to judge against ("Ok"); a non-finite position is a strike.
function CrawlRules.railVerdict(
	graph: VentGraph.Graph,
	position: Vector3,
	lastGood: Vector3?
): (Types.MovementVerdict, Vector3?, VentGraph.RailPoint?)
	if not MathUtil.isFiniteVector(position) then
		return "Strike", lastGood, nil
	end
	local near = VentGraph.nearest(graph, position)
	if near == nil then
		return "Ok", nil, nil
	end
	if near.distance <= RAIL_TOLERANCE then
		return "Ok", nil, near
	end
	if near.distance <= RAIL_CORRECT_REACH then
		return "Correct", near.position, near
	end
	return "Strike", lastGood or near.position, near
end

return table.freeze(CrawlRules)
