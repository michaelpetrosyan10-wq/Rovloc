--!strict
-- VentChase: a crawler gave itself away (seen climbing into a duct, heard scurrying or kicking in one, spotted through
-- a grate), and the Creature goes in after them.
--
--   Choose    the way in (chooseEntry): every grate of the level that is not Locked, costed as the time to walk to
--             its mouth (straight-line estimate) plus the time to crawl from it along the ducts to the target. Open
--             (or already kicked) grates win; a Closed one is kicked in only when no open grate leads to the target.
--             Locked grates are never used. No way in (or every way in unreachable on foot) ends the chase.
--   Approach  it rushes to the grate's room side at WallChase speed, kicks it in if it has to
--             (VentNetworkService.ForceGrate "Kicked": the same crash, noise and OneShot as a player's kick), and
--             squeezes through the opening into the spider crawl (Locomotion: anchored root on the centreline,
--             PoseMode Quadruped, InVent). A grate it cannot reach on foot is set aside and another is chosen.
--   Hunt      A* along the VentGraph to the target's rail point at VentChase speed, re-routed every
--             Repath.ChaseInterval as they move; anyone in the ducts within VentCatchDistance is caught ("Vent").
--   Exit      when the target leaves the ducts it comes out after them: through the grate they used if it is open,
--             else the open grate nearest to where they went. Once out, the chase is done (the brain chases on sight
--             or searches).
-- VentSegmentId follows the duct it is in (MonsterAIService publishes Locomotion's segment).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)

local Brain = require(script.Parent.Parent.Brain)
local Locomotion = require(script.Parent.Parent.Locomotion)

type Context = Brain.Context

export type EntryOption = {
	grateId: string,
	state: Enums.GrateState,
	walk: number, -- studs on foot to its mouth (math.huge: unreachable)
	crawl: number, -- studs along the ducts from its mouth to the target (math.huge: no duct leads there)
}

type Phase = "Choose" | "Approach" | "Hunt" | "Exit"

type Run = {
	phase: Phase,
	grateId: string?,
	unreachable: { [string]: number }, -- grateId -> when it failed
	routedAt: number,
	routedTo: Vector3?,
}

local NAME: Enums.MonsterState = "VentChase"
local KICK_SECONDS = Locomotion.KickRecover + 0.3 -- the wind-up and the panel flying
local WALK_DETOUR = 1.3 -- straight-line walks are this much shorter than real ones
local UNREACHABLE_SECONDS = 20
local REROUTE_MOVE = 1.5 -- studs the target's rail point moves before an early re-route

local VentChase = {}

VentChase.Name = NAME
VentChase.KickSeconds = KICK_SECONDS

local runs: { [Context]: Run } = setmetatable({}, { __mode = "k" }) :: any

--------------------------------------------------------------------------------
-- Pure helpers
--------------------------------------------------------------------------------

local function isOpen(state: Enums.GrateState): boolean
	return state == "Open" or state == "Kicked"
end

-- The way into the ducts: (grateId, kick) or nil when there is none. See the header.
function VentChase.chooseEntry(options: { EntryOption }, walkSpeed: number, crawlSpeed: number): (string?, boolean)
	local function time(option: EntryOption, kick: boolean): number
		if option.walk == math.huge or option.crawl == math.huge then
			return math.huge
		end
		return option.walk / math.max(walkSpeed, 1e-3)
			+ option.crawl / math.max(crawlSpeed, 1e-3)
			+ (if kick then KICK_SECONDS else 0)
	end
	local bestOpen: string?, bestOpenTime = nil, math.huge
	local bestKick: string?, bestKickTime = nil, math.huge
	for _, option in options do
		if option.state == "Locked" then
			continue
		end
		local open = isOpen(option.state)
		local cost = time(option, not open)
		if cost == math.huge then
			continue
		end
		if open then
			if cost < bestOpenTime or (cost == bestOpenTime and bestOpen ~= nil and option.grateId < bestOpen) then
				bestOpen, bestOpenTime = option.grateId, cost
			end
		elseif cost < bestKickTime or (cost == bestKickTime and bestKick ~= nil and option.grateId < bestKick) then
			bestKick, bestKickTime = option.grateId, cost
		end
	end
	if bestOpen then
		return bestOpen, false
	end
	if bestKick then
		return bestKick, true
	end
	return nil, false
end

-- The duct distance from grate `grate`'s mouth to the rail point `target` (math.huge when no duct leads there).
function VentChase.crawlDistance(graph: VentGraph.Graph, grate: VentGraph.Grate, target: VentGraph.RailPoint): number
	local node = graph.nodes[grate.nodeId]
	if not node then
		return math.huge
	end
	local start: VentGraph.RailPoint = { a = grate.nodeId, b = nil, t = 0, position = node.position, distance = 0 }
	local _, cost = Locomotion.railRoute(graph, start, target)
	if cost == math.huge then
		return math.huge
	end
	return cost + (grate.mouth - node.position).Magnitude
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local function runOf(ctx: Context): Run
	local run = runs[ctx]
	if not run then
		run = { phase = "Choose", grateId = nil, unreachable = {}, routedAt = -math.huge, routedTo = nil }
		runs[ctx] = run
	end
	return run
end

local function setCrawling(ctx: Context)
	ctx.mover:SetSpeed(ctx.speedOf(NAME))
	ctx.mover:SetRepathInterval(CreatureConfig.Repath.ChaseInterval)
end

local function setRunning(ctx: Context)
	local speed = ctx.speedOf("WallChase")
	ctx.mover:SetSpeed(speed)
	ctx.body:SetWalkSpeed(speed)
	ctx.mover:SetRepathInterval(CreatureConfig.Repath.ChaseInterval)
end

local function options(ctx: Context, run: Run, target: VentGraph.RailPoint): { EntryOption }
	local graph = ctx.graph
	local out: { EntryOption } = {}
	if not graph then
		return out
	end
	local position = ctx.body:GetPosition()
	local now = ctx.now()
	for id, grate in graph.grates do
		local failedAt = run.unreachable[id]
		local walk = math.huge
		if failedAt == nil or now - failedAt >= UNREACHABLE_SECONDS then
			local stand = ctx.standPoint(grate).Position
			walk = MathUtil.horizontalDistance(position, stand) * WALK_DETOUR + math.abs(position.Y - stand.Y) * 2
		end
		table.insert(out, {
			grateId = id,
			state = ctx.grateState(id),
			walk = walk,
			crawl = VentChase.crawlDistance(graph, grate, target),
		})
	end
	return out
end

local function choose(ctx: Context, run: Run, target: Player)
	local graph = ctx.graph
	local rail = ctx.railPointOf(target)
	if not (graph and rail) then
		ctx.ventBlocked = true
		ctx.stateDone = true
		return
	end
	local grateId, kick = VentChase.chooseEntry(options(ctx, run, rail), ctx.speedOf("WallChase"), ctx.speedOf(NAME))
	local grate = if grateId then graph.grates[grateId] else nil
	if not (grateId and grate) then
		ctx.ventBlocked = true
		ctx.stateDone = true
		return
	end
	run.grateId = grateId
	run.phase = "Approach"
	setRunning(ctx)
	ctx.mover:EnterVent(grate, kick)
end

local function exitAfter(ctx: Context, run: Run, target: Player)
	local graph = ctx.graph
	local used = ctx.exitGrateOf(target)
	local grate: VentGraph.Grate? = nil
	if graph and used then
		local candidate = graph.grates[used]
		if candidate and isOpen(ctx.grateState(used)) then
			grate = candidate
		end
	end
	run.phase = "Exit"
	if not ctx.mover:ExitVent(grate, ctx.rootOf(target)) then
		ctx.stateDone = true
	end
end

local function hunt(ctx: Context, run: Run, target: Player)
	for _, player in ctx.ventOccupants() do
		local kind = ctx.catchKind(player)
		if kind == "Vent" and ctx.tryCatch(player, kind) then
			return
		end
	end
	local rail = ctx.railPointOf(target)
	if not rail then
		return
	end
	local now = ctx.now()
	local moved = run.routedTo == nil or ((run.routedTo :: Vector3) - rail.position).Magnitude >= REROUTE_MOVE
	if ctx.mover:Busy() then
		return
	end
	if moved or now - run.routedAt >= CreatureConfig.Repath.ChaseInterval or ctx.mover:Status() ~= "Moving" then
		if ctx.mover:RailTo(rail) then
			run.routedAt = now
			run.routedTo = rail.position
		end
	end
end

function VentChase.enter(ctx: Context, _from: Enums.MonsterState)
	local run = runOf(ctx)
	run.grateId = nil
	run.routedAt = -math.huge
	run.routedTo = nil
	ctx.ventBlocked = false
	ctx.body:Face(nil)
	if ctx.mover:Medium() == "Vent" then
		run.phase = "Hunt"
		setCrawling(ctx)
	else
		run.phase = "Choose"
		setRunning(ctx)
	end
end

function VentChase.update(ctx: Context, _dt: number)
	local run = runOf(ctx)
	local mover = ctx.mover
	local target = ctx.target
	local inside = mover:Medium() == "Vent"
	if not target or not ctx.inVent(target) then
		if run.phase == "Exit" then
			if not inside and not mover:Busy() then
				ctx.stateDone = true
			end
			return
		end
		if inside and target then
			exitAfter(ctx, run, target)
		elseif inside then
			run.phase = "Exit"
			if not mover:ExitVent(nil, nil) then
				ctx.stateDone = true
			end
		elseif not mover:Busy() then
			ctx.stateDone = true
		end
		return
	end
	if run.phase == "Choose" then
		if inside then
			run.phase = "Hunt"
			setCrawling(ctx)
		else
			choose(ctx, run, target)
		end
		return
	end
	if run.phase == "Approach" then
		local status = mover:Status()
		local grateId = run.grateId
		if inside and not mover:Busy() then
			run.phase = "Hunt"
			setCrawling(ctx)
			return
		end
		if (status == "Failed" or status == "Stuck") and not inside then
			if grateId then
				run.unreachable[grateId] = ctx.now()
			end
			run.phase = "Choose"
			return
		end
		if grateId and not inside and ctx.grateState(grateId) == "Locked" then
			run.phase = "Choose"
		end
		return
	end
	if run.phase == "Hunt" then
		if not inside then
			run.phase = "Choose"
			return
		end
		hunt(ctx, run, target)
	end
end

function VentChase.exit(ctx: Context, _to: Enums.MonsterState)
	local run = runOf(ctx)
	run.phase = "Choose"
	run.grateId = nil
	ctx.body:Face(nil)
end

return table.freeze(VentChase)
