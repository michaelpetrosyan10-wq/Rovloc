--!strict
-- VentNetworkService: the wall vents (spec §4). The only writer of a grate's GrateState and of its panel and screw
-- poses after the build; owns vent occupancy (who is crawling, on which level), the crawl entry and exit transitions
-- and the VentRail movement validator; caches each level's VentGraph for every server system (the Creature's vent
-- chase in P5 reads GetGraph / OccupantsOf and kicks grates through ForceGrate).
--
-- Graphs. GetGraph(levelId) builds the level's VentGraph from Workspace.School.<levelId> on first use and caches it
-- for the life of the server (the ducts never change); it is rebuilt only if that level model is replaced.
--
-- Grates. Every VentGrate-tagged Model under Workspace.Runtime is tracked (CollectionService added / removed, plus a
-- scan at BeginRun, since WorldService rebuilds the run's fixtures in its own BeginRun just before this one), from
-- its GrateState attribute (Closed or Locked as built). States and prompt rules: GrateRules.
--   Unscrew (hold LoadoutService.HoldSeconds of the prompt's BaseHold; usable from the room and from inside the duct,
--     the prompt sits in front of the panel): the hold starting makes the grate Unscrewing; the four screws back out
--     with the hold's progress (stepped every Heartbeat from InteractionService's channel) to the looped Unscrew cue
--     at the panel, with a quiet GrateUnscrew noise every NoiseConfig interval. Letting go (or any cancellation) runs
--     the screws back in and the grate is Closed again. Completing it makes the grate Open: the screws drop, the
--     panel swings out over PanelSeconds with a creak.
--   Kick (instant): the grate is Kicked. The panel tears off its hinges and lands in KickSeconds, starting
--     GameConfig.OneShotLead from now so it moves with the cues: the 130-stud GrateKick noise, a MetalCrash cue at the
--     opening, and OneShot "GrateKick" (subject = the grate model) for every client.
-- Both prompts are served while the grate is Closed, Unscrewing or Locked (a locked grate refuses both with
-- Prompt.GrateLocked) and close for good once it is Open or Kicked: InteractionService.Refresh runs after every state
-- change. Grate noises carry the grate's VentNode, and the Vent medium when the player making them is in the duct.
-- ForceGrate(grateId, state) sets a grate from a script, the Creature or a dev command: Closed / Locked shut it
-- (swinging an open panel back, snapping a torn-off one back onto its hinges) with the screws in, Open unscrews and
-- swings it, Kicked kicks it with the same visuals, noise, cue and OneShot as a player's kick. A running unscrew is
-- cancelled first. Locking also relabels both prompts "Rusted shut" (unlocking restores "Vent Grate").
-- GrateChanged(grateId, state, by) fires on every state change (`by` = the player who caused it, nil when forced).
--
-- Crawling (no remote: the owning client drives its root along the rail; the server only moves it in and out). At
-- GameConfig.ServerTickHz, while the run is live:
--   Entry: a participant whose CrawlRules.canEnter holds (Alive, on foot, Crouching, no control lock) with their
--     root in an open grate's mouth box, looking into the wall (CrawlRules), is put in the duct: CollisionService
--     mode "Vent" (the VentCollider ball becomes their only collider), PlayerStateService mode "Vent" (MoveState
--     VentCrawling / VentScurrying), then CharacterService.Teleport to the grate's EntryAnchor with the root on the
--     duct centreline. Entered(player, grateId) fires; RunStats VentsCrawled counts each grate once per player per
--     run. A teleport that fails undoes the modes.
--   Exit: a crawler (Alive or Downed) whose root crossed the room face of an open grate's mouth stub stands up at
--     its ExitAnchor (or 0.75 studs to either side), the first spot whose standing box GetPartBoundsInBox finds clear
--     in the Players group (the player and the grate itself excluded: a kicked panel lies there to be stood on):
--     Teleport, then the modes are popped (CollisionService) and set back (PlayerStateService "OnFoot"), and
--     Exited(player, grateId) fires. A grate that is closed behind a crawler is not a way out. After any exit or
--     release a player cannot crawl back in for EntryCooldown seconds.
--   Rail: MovementAuthority runs the "VentRail" validator for crawlers (CrawlRules.railVerdict against their level's
--     graph): Ok within 1.25 studs of the rail (that rail point becomes their last good one), Correct back onto the
--     nearest rail point within 4, Strike and back to the last good rail point beyond that. MovementAuthority itself
--     judges speed against the vent WalkSpeed.
--   Release (occupancy ends where the player is: modes popped, Released(player, reason) fires): death, spectating
--     or the lobby (LifeStateService), the character going away, being moved off the rail by something else (another
--     system's CharacterService.Teleport landing more than 4 studs from any rail point), leaving, EndRun, and
--     Release(player) for scripted moves. A Downed crawler stays in the duct (DownedCrawling; the Vent collision
--     stays). EndRun also forgets every grate's state (the fixtures are rebuilt each run).
--
-- Dev commands: vent open|kick|close|lock [grateId|nearest] (force a grate; the nearest one by default),
-- vents [level] (read-only: every level's grates and their states, and who is crawling).
--
-- Pure rules: GrateRules (states, prompt eligibility, forced changes, motions) and CrawlRules (entry, exit, rail).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local NoiseConfig = require(ReplicatedStorage.Shared.Config.NoiseConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local VentGrateBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.VentGrateBuilder)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local CollisionService = require(ServerScriptService.Services.Core.CollisionService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local LoadoutService = require(ServerScriptService.Services.Player.LoadoutService)
local MovementAuthority = require(ServerScriptService.Services.Player.MovementAuthority)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)

local CrawlRules = require(script.CrawlRules)
local GrateRules = require(script.GrateRules)

local log = Log.new("Vents")

local W = Attributes.World

local VENT_TOKEN = "Vent" -- CollisionService mode token
local VENT_COLLISION: Enums.CollisionMode = "Vent"
local VALIDATOR_NAME = "VentRail"
local UNSCREW_KIND: Enums.PromptKind = "Unscrew"
local KICK_KIND: Enums.PromptKind = "Kick"
local UNSCREW_NOISE: Enums.NoiseKind = "GrateUnscrew"
local KICK_NOISE: Enums.NoiseKind = "GrateKick"
local KICK_ONESHOT: Enums.OneShotKind = "GrateKick"
local CRAWLED_STAT: Enums.StatKey = "VentsCrawled"
local VENT_MEDIUM: Enums.NoiseMedium = "Vent"
local UNSCREW_PRESET = "Unscrew"
local CRASH_PRESET = "MetalCrash"
local CREAK_PRESET = "MetalCreak"
local CREAK_VOLUME = 0.6
local GRATE_OBJECT = "Prompt.Grate"
local LOCKED_OBJECT = "Prompt.GrateLocked"
local PROMPT_POINT = "PromptPoint"
local ENTRY_ANCHOR = "EntryAnchor"
local EXIT_ANCHOR = "ExitAnchor"
local PANEL_CENTRE = "PanelCentre"

local ENTRY_COOLDOWN = 1 -- seconds after leaving a duct before crawling in again
local ENTRY_CULL = WorldConfig.WallThickness / 2 + CrawlRules.MouthDepth + CrawlRules.MouthHalfWidth
local UNSCREW_INTERVAL = NoiseConfig.Kinds.GrateUnscrew.interval
local LIVE_PHASES: { [string]: boolean } = { Deploying = true, InRun = true }
local GRATE_STATES: { Enums.GrateState } = { "Closed", "Unscrewing", "Open", "Kicked", "Locked" }
local GRATE_PROMPTS: { Enums.PromptKind } = { UNSCREW_KIND, KICK_KIND }
-- A state a fresh tracker reads differently: nobody is holding the grate it just found.
local TRACKED_AS: { [string]: Enums.GrateState } = { Unscrewing = "Closed" }

-- Moves a character so its root lands on the CFrame; false when there is no living character to move.
export type Mover = (player: Player, cframe: CFrame) -> boolean

type PoseKind = "Panel" | "Kick" | "Screws"

type GrateMotion = {
	pose: PoseKind,
	motion: GrateRules.Motion,
	screwsAfter: number?, -- screws posed here once the motion ends (a panel swung shut is screwed back in)
}

type Grate = {
	model: Model,
	id: string,
	levelId: Enums.LevelId?,
	nodeId: string?,
	state: Enums.GrateState,
	prompts: { ProximityPrompt },
	entryAnchor: CFrame?, -- world; grates are anchored and never move
	exitAnchor: CFrame?,
	centre: Vector3, -- the opening's centre (noises and cues)
	handsAt: Vector3, -- the PromptPoint in front of the panel (the unscrew loop)
	-- current poses, 0..1 (kicked > 0: the panel and screws follow the throw)
	panel: number,
	kicked: number,
	screws: number,
	motion: GrateMotion?,
	actor: Player?, -- holding Unscrew
	sound: AudioService.CueHandle?,
	nextNoiseAt: number,
}

type Occupant = {
	character: Model,
	levelId: string,
	graph: VentGraph.Graph,
	entry: string, -- the grate crawled in through
	lastGood: Vector3, -- the last rail point the validator accepted
}

local VentNetworkService = {}

VentNetworkService.Name = "VentNetworkService"
VentNetworkService.ValidatorName = VALIDATOR_NAME
VentNetworkService.CollisionToken = VENT_TOKEN
VentNetworkService.EntryCooldown = ENTRY_COOLDOWN

local entered: Signal.Signal<Player, string> = Signal.new()
local exited: Signal.Signal<Player, string> = Signal.new()
local grateChanged: Signal.Signal<string, Enums.GrateState, Player?> = Signal.new()
local released: Signal.Signal<Player, string> = Signal.new()

-- (player, grateId) after a player crawled in through that grate.
VentNetworkService.Entered = entered
-- (player, grateId) after a crawler came out through that grate.
VentNetworkService.Exited = exited
-- (grateId, state, by) after a grate changed state; `by` is the player who caused it (nil when forced).
VentNetworkService.GrateChanged = grateChanged
-- (player, reason) when a crawler's occupancy ended anywhere but a grate ("Dead", "Spectating", "Lobby",
-- "Despawned", "Moved", "Left", "RunEnded", "Scripted").
VentNetworkService.Released = released

local defaultMover: Mover = function(player: Player, cframe: CFrame): boolean
	return CharacterService.Teleport(player, cframe)
end

local serviceTrove = Trove.new()
local grates: { [string]: Grate } = {}
local gratesByModel: { [Instance]: Grate } = {}
local moving: { [Grate]: boolean } = {}
local unscrewing: { [Grate]: boolean } = {}
local occupants: { [Player]: Occupant } = {}
local participants: { [Player]: boolean } = {}
local crawled: { [number]: { [string]: boolean } } = {} -- UserId -> grates crawled through this run
local cooldownUntil: { [Player]: number } = {} -- os.clock()
local selfMoving: { [Player]: boolean } = {}
local graphCache: { [string]: { root: Instance, graph: VentGraph.Graph? } } = {}
local levelRoots: { [string]: Instance } = {}
local mover: Mover = defaultMover
local running = false -- between BeginRun and EndRun
local live = false -- running, and the match phase is Deploying / InRun
local oneShotSeq = 0
local initialized = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function livingBody(player: Player): (BasePart?, Humanoid?)
	local root = Instances.characterRoot(player)
	local humanoid = Instances.characterHumanoid(player)
	if root and humanoid and humanoid.Health > 0 then
		return root, humanoid
	end
	return nil, nil
end

local function levelOf(instance: Instance): Enums.LevelId?
	local value = instance:GetAttribute(W.LevelId)
	if type(value) == "string" and Enums.has(Enums.LevelId, value) then
		return value :: Enums.LevelId
	end
	return nil
end

-- The state a fresh tracker reads off a built grate (Closed when it carries none).
local function trackedState(model: Model): Enums.GrateState
	local value = model:GetAttribute(W.GrateState)
	if type(value) == "string" and Enums.has(Enums.GrateState, value) then
		local state: Enums.GrateState = value :: Enums.GrateState
		local mapped: Enums.GrateState? = TRACKED_AS[state]
		if mapped ~= nil then
			return mapped
		end
		return state
	end
	return "Closed"
end

local function inRuntime(instance: Instance): boolean
	local runtime = Instances.runtime()
	return runtime ~= nil and instance:IsDescendantOf(runtime)
end

local function worldOf(model: Model, name: string): CFrame?
	local attachment = PropKit.findAttachment(model, name)
	return if attachment then PropKit.attachmentWorld(attachment) else nil
end

local function protected(label: string, fn: () -> ())
	xpcall(fn, function(err: any)
		log.warnThrottled(label, 10, "%s failed: %s\n%s", label, tostring(err), debug.traceback())
	end)
end

--------------------------------------------------------------------------------
-- Graphs
--------------------------------------------------------------------------------

-- The level's VentGraph (built from Workspace.School.<levelId> on first use, then cached).
function VentNetworkService.GetGraph(levelId: string): VentGraph.Graph?
	local root = levelRoots[levelId] or Instances.layoutRoot(levelId)
	if not root then
		return nil
	end
	local cached = graphCache[levelId]
	if cached and cached.root == root then
		return cached.graph
	end
	local graph = VentGraph.build(root, levelId)
	graphCache[levelId] = { root = root, graph = graph }
	return graph
end

-- Builds `levelId`'s graph from `root` instead of Workspace.School.<levelId> (tools and specs that build a level
-- elsewhere); nil goes back to the school.
function VentNetworkService.SetLevelRoot(levelId: string, root: Instance?)
	if root then
		levelRoots[levelId] = root
	else
		levelRoots[levelId] = nil
	end
	graphCache[levelId] = nil
end

-- The graph data of grate `grate` (nil when its level has no graph or the graph does not know it).
local function grateInfo(grate: Grate): VentGraph.Grate?
	local levelId = grate.levelId
	local graph = if levelId then VentNetworkService.GetGraph(levelId) else nil
	return if graph then graph.grates[grate.id] else nil
end

--------------------------------------------------------------------------------
-- Poses and motions
--------------------------------------------------------------------------------

local function pose(grate: Grate, kind: PoseKind, value: number)
	if kind == "Panel" then
		VentGrateBuilder.setPanel(grate.model, value)
		grate.panel = value
	elseif kind == "Kick" then
		VentGrateBuilder.setKicked(grate.model, value)
		grate.kicked = value
		-- the throw carries the panel from its shut pose and the screws with it
		grate.panel = 0
		grate.screws = 0
	else
		VentGrateBuilder.setScrews(grate.model, value)
		grate.screws = value
	end
end

local function stopMotion(grate: Grate)
	grate.motion = nil
	moving[grate] = nil
end

local function startMotion(
	grate: Grate,
	kind: PoseKind,
	from: number,
	to: number,
	seconds: number,
	delay: number,
	ease: GrateRules.Ease,
	screwsAfter: number?
)
	grate.motion = {
		pose = kind,
		motion = { from = from, to = to, delay = delay, seconds = seconds, elapsed = 0, ease = ease },
		screwsAfter = screwsAfter,
	}
	moving[grate] = true
end

-- Advances every grate motion by `dt` seconds and poses it, and poses the screws of every grate being unscrewed by
-- its hold's progress (the Heartbeat driver calls this every frame; specs drive it by hand).
function VentNetworkService.StepMotions(dt: number)
	for grate in table.clone(moving) do
		local entry = grate.motion
		if entry == nil or grate.model.Parent == nil then
			stopMotion(grate)
			continue
		end
		local motion = entry.motion
		motion.elapsed += math.max(0, dt)
		if motion.elapsed < motion.delay then
			continue
		end
		local value, done = GrateRules.motionValue(motion)
		pose(grate, entry.pose, value)
		if done then
			stopMotion(grate)
			local screws = entry.screwsAfter
			if screws ~= nil then
				pose(grate, "Screws", screws)
			end
		end
	end
	if next(unscrewing) == nil then
		return
	end
	local now = serverNow()
	for grate in table.clone(unscrewing) do
		local actor, startedAt, duration = InteractionService.GetChannel(grate.model)
		if actor == nil or grate.state ~= "Unscrewing" then
			continue
		end
		pose(grate, "Screws", GrateRules.unscrewProgress(now, startedAt, duration))
	end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local function refreshPrompts(grate: Grate)
	if grate.model.Parent == nil then
		return
	end
	xpcall(InteractionService.Refresh, function(err: any)
		log.warnThrottled("refresh", 10, "prompt refresh on %s failed: %s", grate.model:GetFullName(), tostring(err))
	end, grate.model)
end

local function setObjectText(grate: Grate, key: string)
	local text = Strings.get(key)
	for _, prompt in grate.prompts do
		if prompt.ObjectText ~= text then
			prompt.ObjectText = text
		end
	end
end

local function setState(grate: Grate, state: Enums.GrateState, by: Player?)
	local previous: Enums.GrateState = grate.state
	if previous == state then
		return
	end
	grate.state = state
	Attributes.set(grate.model, W.GrateState, state)
	if state == "Locked" then
		setObjectText(grate, LOCKED_OBJECT)
	elseif previous == "Locked" then
		setObjectText(grate, GRATE_OBJECT)
	end
	if state == "Unscrewing" then
		unscrewing[grate] = true
	else
		unscrewing[grate] = nil
	end
	refreshPrompts(grate)
	grateChanged:Fire(grate.id, state, by)
end

local function stopSound(grate: Grate)
	local sound = grate.sound
	grate.sound = nil
	if sound then
		sound:Stop()
	end
end

-- The noise medium of a grate noise a player makes: the duct's when they are inside it.
local function mediumFor(by: Player?): Enums.NoiseMedium?
	return if by ~= nil and occupants[by] ~= nil then VENT_MEDIUM else nil
end

local function emitNoise(grate: Grate, kind: Enums.NoiseKind, by: Player?)
	NoiseAndDirectorService.Emit(grate.centre, kind, {
		sourcePlayer = by,
		levelId = grate.levelId,
		ventNodeId = grate.nodeId,
		medium = mediumFor(by),
	})
end

local function sendKickOneShot(grate: Grate, by: Player?)
	oneShotSeq += 1
	local args: { [string]: Types.OneShotArg } = { grateId = grate.id }
	if by then
		args.userId = by.UserId
	end
	local event: Types.OneShotEvent = {
		seq = oneShotSeq,
		kind = KICK_ONESHOT,
		subject = grate.model,
		startAt = serverNow() + GameConfig.OneShotLead,
		args = args,
	}
	Net.Server.fireAll("OneShot", event)
end

-- Tears the panel off (a player's kick, the Creature's, a script's): pose, noise, cue, OneShot, then the state.
local function kick(grate: Grate, by: Player?)
	stopSound(grate)
	startMotion(grate, "Kick", grate.kicked, 1, GrateRules.KickSeconds, GameConfig.OneShotLead, "Linear", nil)
	emitNoise(grate, KICK_NOISE, by)
	AudioService.PlayAt(CRASH_PRESET, grate.centre)
	sendKickOneShot(grate, by)
	setState(grate, "Kicked", by)
	log.info("%s kicked open%s", grate.id, if by then " by " .. by.Name else "")
end

-- Swings the unscrewed panel open (the screws are out).
local function swingOpen(grate: Grate, by: Player?)
	stopSound(grate)
	stopMotion(grate)
	pose(grate, "Screws", 1)
	startMotion(grate, "Panel", grate.panel, 1, GrateRules.PanelSeconds, 0, "Out", nil)
	AudioService.PlayAt(CREAK_PRESET, grate.centre, { volume = CREAK_VOLUME })
	setState(grate, "Open", by)
end

-- Shuts the grate with its screws in (`state` Closed or Locked): an open panel swings back, a torn-off one is put
-- back on its hinges.
local function shut(grate: Grate, state: Enums.GrateState, by: Player?)
	stopSound(grate)
	stopMotion(grate)
	if grate.kicked > 0 then
		pose(grate, "Kick", 0)
		pose(grate, "Screws", 0)
	elseif grate.panel > 0 then
		startMotion(grate, "Panel", grate.panel, 0, GrateRules.PanelSeconds, 0, "Out", 0)
	elseif grate.screws > 0 then
		pose(grate, "Screws", 0)
	end
	setState(grate, state, by)
end

-- Applies a forced state (ForceGrate, dev commands). Returns GrateRules.forceVerdict's answer.
local function force(grate: Grate, state: Enums.GrateState, by: Player?): GrateRules.ForceVerdict
	if grate.state == "Unscrewing" then
		InteractionService.CancelChannel(grate.model, "Forced")
		if grate.state == "Unscrewing" then
			-- the channel was already gone: settle the grate as a cancelled unscrew would
			grate.actor = nil
			stopSound(grate)
			setState(grate, "Closed", nil)
		end
	end
	local verdict: GrateRules.ForceVerdict = GrateRules.forceVerdict(grate.state, state)
	-- a boolean, not a direct comparison: refining one union by another widens both to string
	local applies = verdict == "Apply"
	if not applies then
		return verdict
	end
	local target: Enums.GrateState = state
	if target == "Kicked" then
		kick(grate, by)
	elseif target == "Open" then
		swingOpen(grate, by)
	else
		shut(grate, state, by)
	end
	return verdict
end

--------------------------------------------------------------------------------
-- Prompt handlers
--------------------------------------------------------------------------------

local function baseHold(prompt: ProximityPrompt): number
	return Attributes.getNumber(prompt, W.BaseHold, prompt.HoldDuration)
end

local function onUnscrewBegin(player: Player, _prompt: ProximityPrompt, host: Instance)
	local grate = gratesByModel[host]
	if not grate then
		return
	end
	local nextState: Enums.GrateState? = GrateRules.nextState(grate.state, "UnscrewBegin")
	if nextState == nil then
		return
	end
	local _, _, duration = InteractionService.GetChannel(host)
	stopMotion(grate)
	stopSound(grate)
	grate.actor = player
	-- the grate never moves, so the loop plays at a fixed point: the panel's prompt point, where the hands are
	grate.sound = AudioService.PlayAt(UNSCREW_PRESET, grate.handsAt, { duration = math.max(duration, 0.1) })
	emitNoise(grate, UNSCREW_NOISE, player)
	grate.nextNoiseAt = serverNow() + UNSCREW_INTERVAL
	setState(grate, nextState :: Enums.GrateState, player)
end

local function onUnscrewCancel(player: Player, _prompt: ProximityPrompt, host: Instance, _reason: string)
	local grate = gratesByModel[host]
	if not grate or grate.actor ~= player then
		return
	end
	grate.actor = nil
	stopSound(grate)
	local nextState: Enums.GrateState? = GrateRules.nextState(grate.state, "UnscrewCancel")
	if nextState == nil then
		return
	end
	if grate.screws > 0 then
		startMotion(grate, "Screws", grate.screws, 0, GrateRules.ScrewResetSeconds, 0, "Out", nil)
	end
	setState(grate, nextState :: Enums.GrateState, player)
end

local function onUnscrewComplete(player: Player, _prompt: ProximityPrompt, host: Instance)
	local grate = gratesByModel[host]
	if not grate or grate.actor ~= player then
		return
	end
	grate.actor = nil
	if GrateRules.nextState(grate.state, "UnscrewComplete") == nil then
		return
	end
	swingOpen(grate, player)
	log.info("%s unscrewed by %s", grate.id, player.Name)
end

local function onKickComplete(player: Player, _prompt: ProximityPrompt, host: Instance)
	local grate = gratesByModel[host]
	if not grate or GrateRules.nextState(grate.state, "Kick") == nil then
		return
	end
	kick(grate, player)
end

local function serves(host: Instance, _prompt: ProximityPrompt): boolean
	local grate = gratesByModel[host]
	return grate ~= nil and GrateRules.servesPrompts(grate.state)
end

-- Unscrew on a grate's PromptPoint: an Alive player, from the room or from the duct, while it is Closed.
VentNetworkService.UnscrewHandler = table.freeze({
	kind = UNSCREW_KIND,
	filter = serves,
	canUse = function(player: Player, _prompt: ProximityPrompt, host: Instance): (boolean, string?)
		local grate = gratesByModel[host]
		local actor = InteractionService.GetChannel(host)
		return GrateRules.unscrewEligible({
			state = if grate then grate.state else nil,
			lifeState = LifeStateService.GetState(player),
			channelling = actor == player,
		})
	end,
	holdSeconds = function(player: Player, prompt: ProximityPrompt, _host: Instance): number
		return LoadoutService.HoldSeconds(player, UNSCREW_KIND, baseHold(prompt))
	end,
	onBegin = onUnscrewBegin,
	onComplete = onUnscrewComplete,
	onCancel = onUnscrewCancel,
} :: InteractionService.Handler)

-- Kick on a grate's PromptPoint: an Alive player, at once, while it is Closed.
VentNetworkService.KickHandler = table.freeze({
	kind = KICK_KIND,
	filter = serves,
	canUse = function(player: Player, _prompt: ProximityPrompt, host: Instance): (boolean, string?)
		local grate = gratesByModel[host]
		return GrateRules.kickEligible({
			state = if grate then grate.state else nil,
			lifeState = LifeStateService.GetState(player),
		})
	end,
	onComplete = onKickComplete,
} :: InteractionService.Handler)

--------------------------------------------------------------------------------
-- Tracking
--------------------------------------------------------------------------------

local function forget(model: Instance)
	local grate = gratesByModel[model]
	if not grate then
		return
	end
	gratesByModel[model] = nil
	if grates[grate.id] == grate then
		grates[grate.id] = nil
	end
	stopMotion(grate)
	stopSound(grate)
	unscrewing[grate] = nil
	grate.actor = nil
end

-- Starts managing a built grate (its state from GrateState, its anchors and prompts). Returns false when the model is
-- not a complete grate. Tracking a grate twice is harmless; a second model with the same GrateId replaces the first.
function VentNetworkService.Track(model: Model): boolean
	if gratesByModel[model] then
		return true
	end
	local id = model:GetAttribute(W.GrateId)
	local promptPoint = PropKit.findAttachment(model, PROMPT_POINT)
	if type(id) ~= "string" or id == "" or not promptPoint or not model.PrimaryPart then
		log.warn("%s is not a complete vent grate; left alone", model:GetFullName())
		return false
	end
	local previous = grates[id]
	if previous then
		forget(previous.model)
	end
	local handsAt = PropKit.attachmentWorld(promptPoint).Position
	local prompts: { ProximityPrompt } = {}
	for _, kind: Enums.PromptKind in GRATE_PROMPTS do
		local prompt = PropKit.findPrompt(model, kind)
		if prompt then
			table.insert(prompts, prompt)
		end
	end
	local state: Enums.GrateState = trackedState(model)
	local nodeId = model:GetAttribute(W.NodeId)
	local grate: Grate = {
		model = model,
		id = id,
		levelId = levelOf(model),
		nodeId = if type(nodeId) == "string" then nodeId else nil,
		state = state,
		prompts = prompts,
		entryAnchor = worldOf(model, ENTRY_ANCHOR),
		exitAnchor = worldOf(model, EXIT_ANCHOR),
		centre = handsAt,
		handsAt = handsAt,
		panel = 0,
		kicked = 0,
		screws = 0,
		motion = nil,
		actor = nil,
		sound = nil,
		nextNoiseAt = 0,
	}
	local info = grateInfo(grate)
	if info then
		grate.centre = info.wall.Position
	else
		local centre = worldOf(model, PANEL_CENTRE)
		if centre then
			grate.centre = centre.Position
		end
	end
	Attributes.set(model, W.GrateState, state)
	grates[id] = grate
	gratesByModel[model] = grate
	if grate.state == "Open" then
		pose(grate, "Screws", 1)
		pose(grate, "Panel", 1)
	elseif grate.state == "Kicked" then
		pose(grate, "Kick", 1)
	end
	refreshPrompts(grate)
	return true
end

local function onGrateTagged(instance: Instance)
	if instance:IsA("Model") and instance.Parent ~= nil and inRuntime(instance) then
		VentNetworkService.Track(instance)
	end
end

local function onGrateUntagged(instance: Instance)
	forget(instance)
end

local function scan()
	for _, instance in CollectionService:GetTagged(Tags.VentGrate) do
		onGrateTagged(instance)
	end
end

--------------------------------------------------------------------------------
-- Occupancy
--------------------------------------------------------------------------------

-- Ends `player`'s occupancy where they are: their modes back to on foot. False when they were not crawling.
local function endOccupancy(player: Player): boolean
	local occupant = occupants[player]
	if not occupant then
		return false
	end
	occupants[player] = nil
	CollisionService.PopMode(occupant.character, VENT_TOKEN)
	PlayerStateService.SetMode(player, "OnFoot")
	cooldownUntil[player] = os.clock() + ENTRY_COOLDOWN
	return true
end

local function release(player: Player, reason: string): boolean
	if not endOccupancy(player) then
		return false
	end
	log.info("%s left the vents (%s)", player.Name, reason)
	released:Fire(player, reason)
	return true
end

local function move(player: Player, cframe: CFrame): boolean
	selfMoving[player] = true
	local ok, moved = pcall(mover, player, cframe)
	selfMoving[player] = nil
	if not ok then
		log.warnThrottled("move:" .. player.UserId, 10, "moving %s failed: %s", player.Name, tostring(moved))
		return false
	end
	return moved == true
end

-- Puts `player` in the duct behind `grate` (see the header). False when they could not be moved there.
local function enter(player: Player, grate: Grate, info: VentGraph.Grate, graph: VentGraph.Graph): boolean
	local character = player.Character
	local entryAnchor = grate.entryAnchor
	local node = graph.nodes[info.nodeId]
	if not (character and entryAnchor and node) then
		return false
	end
	local target = CrawlRules.entryCFrame(entryAnchor, node.position.Y)
	CollisionService.PushMode(character, VENT_TOKEN, VENT_COLLISION)
	PlayerStateService.SetMode(player, "Vent")
	if not move(player, target) then
		CollisionService.PopMode(character, VENT_TOKEN)
		PlayerStateService.SetMode(player, "OnFoot")
		return false
	end
	local rail = VentGraph.nearest(graph, target.Position)
	occupants[player] = {
		character = character,
		levelId = graph.levelId,
		graph = graph,
		entry = grate.id,
		lastGood = if rail then rail.position else target.Position,
	}
	local seen = crawled[player.UserId]
	if not seen then
		seen = {}
		crawled[player.UserId] = seen
	end
	if not seen[grate.id] then
		seen[grate.id] = true
		RunStatsService.Increment(player, CRAWLED_STAT)
	end
	log.info("%s crawled into %s", player.Name, grate.id)
	entered:Fire(player, grate.id)
	return true
end

-- Where in front of `grate` a body can stand up (CrawlRules.exitCandidates, first clear standing box), or nil.
local function freeExitSpot(grate: Grate, character: Model): CFrame?
	local exitAnchor = grate.exitAnchor
	if not exitAnchor then
		return nil
	end
	local exclude: { Instance } = { character, grate.model }
	local params = SpatialQuery.overlapParams(exclude, "Players")
	for _, candidate in CrawlRules.exitCandidates(exitAnchor) do
		local cframe, size = CrawlRules.standingBox(candidate)
		if #Workspace:GetPartBoundsInBox(cframe, size, params) == 0 then
			return candidate
		end
	end
	return nil
end

local function exit(player: Player, grate: Grate, root: BasePart, humanoid: Humanoid): boolean
	local occupant = occupants[player]
	if not occupant then
		return false
	end
	local spot = freeExitSpot(grate, occupant.character)
	if not spot then
		log.warnThrottled("blocked:" .. grate.id, 10, "%s: no clear spot to stand up in front of it", grate.id)
		return false
	end
	local rootHeight = CrawlRules.rootHeight(humanoid.HipHeight, root.Size.Y)
	if not move(player, CrawlRules.exitRootCFrame(spot, rootHeight)) then
		return false
	end
	endOccupancy(player)
	log.info("%s crawled out of %s", player.Name, grate.id)
	exited:Fire(player, grate.id)
	return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function VentNetworkService.GetGrateModel(grateId: string): Model?
	local grate = grates[grateId]
	return if grate and grate.model.Parent ~= nil then grate.model else nil
end

-- The grate's state ("Closed" for a grate this run has not built).
function VentNetworkService.GetGrateState(grateId: string): Enums.GrateState
	local grate = grates[grateId]
	return if grate then grate.state else "Closed"
end

-- Open or Kicked: crawlers (and the Creature) can pass.
function VentNetworkService.IsGrateOpen(grateId: string): boolean
	return GrateRules.isOpen(VentNetworkService.GetGrateState(grateId))
end

-- Sets a grate's state with its poses (see the header); Unscrewing cannot be forced.
function VentNetworkService.ForceGrate(grateId: string, state: Enums.GrateState)
	local grate = grates[grateId]
	if not grate then
		log.warn("ForceGrate(%s, %s): no such grate this run", grateId, tostring(state))
		return
	end
	local verdict = force(grate, state, nil)
	if verdict == "NotForcible" then
		log.warn("ForceGrate(%s): %s cannot be forced", grateId, tostring(state))
	end
end

function VentNetworkService.IsInVent(player: Player): boolean
	return occupants[player] ~= nil
end

-- Where on its level's rail a crawler's root is (nil when they are not crawling or have no root).
function VentNetworkService.GetRailPoint(player: Player): VentGraph.RailPoint?
	local occupant = occupants[player]
	local root = Instances.characterRoot(player)
	if not occupant or not root then
		return nil
	end
	return VentGraph.nearest(occupant.graph, root.CFrame.Position)
end

-- Everyone crawling in `levelId`'s ducts (in UserId order).
function VentNetworkService.OccupantsOf(levelId: string): { Player }
	local out: { Player } = {}
	for player, occupant in occupants do
		if occupant.levelId == levelId then
			table.insert(out, player)
		end
	end
	table.sort(out, function(a: Player, b: Player): boolean
		return a.UserId < b.UserId
	end)
	return out
end

-- The grate a crawler came in through (nil when they are not crawling).
function VentNetworkService.GetEntryGrate(player: Player): string?
	local occupant = occupants[player]
	return if occupant then occupant.entry else nil
end

-- Ends `player`'s occupancy where they are (a script about to move them out of the duct its own way). False when
-- they were not crawling.
function VentNetworkService.Release(player: Player): boolean
	return release(player, "Scripted")
end

-- Replaces how crawlers are moved in and out (specs pass a stand-in; nil restores CharacterService.Teleport).
function VentNetworkService.SetMover(fake: Mover?)
	mover = fake or defaultMover
end

-- The rail validator MovementAuthority runs for every checked player (registered as ValidatorName).
function VentNetworkService.RailValidator(
	player: Player,
	root: BasePart,
	_dt: number
): (Types.MovementVerdict, Vector3?)
	local occupant = occupants[player]
	if not occupant or occupant.character ~= player.Character then
		return "Ok", nil
	end
	local verdict: Types.MovementVerdict, target, rail =
		CrawlRules.railVerdict(occupant.graph, root.CFrame.Position, occupant.lastGood)
	local onRail = verdict == "Ok"
	if onRail and rail then
		occupant.lastGood = rail.position
	end
	return verdict, target
end

--------------------------------------------------------------------------------
-- Poll
--------------------------------------------------------------------------------

local function pollEntry(player: Player)
	local root, humanoid = livingBody(player)
	local allowed = CrawlRules.canEnter({
		live = live,
		participant = participants[player] == true,
		lifeState = LifeStateService.GetState(player),
		inVent = occupants[player] ~= nil,
		onFoot = PlayerStateService.GetMode(player) == "OnFoot",
		moveState = PlayerStateService.GetMoveState(player),
		controlLock = CharacterService.GetLock(player),
		hasBody = root ~= nil,
	})
	if not (allowed and root and humanoid) or (cooldownUntil[player] or -math.huge) > os.clock() then
		return
	end
	local position = root.CFrame.Position
	local rootHeight = CrawlRules.rootHeight(humanoid.HipHeight, root.Size.Y)
	local yaw, pitch = PlayerStateService.GetLook(player)
	for _, grate in grates do
		local exitAnchor = grate.exitAnchor
		local levelId = grate.levelId
		if not (GrateRules.isOpen(grate.state) and exitAnchor and levelId and grate.model.Parent) then
			continue
		end
		if MathUtil.horizontalDistance(grate.centre, position) > ENTRY_CULL then
			continue
		end
		local graph = VentNetworkService.GetGraph(levelId)
		local info = if graph then graph.grates[grate.id] else nil
		if not (graph and info) then
			continue
		end
		if
			CrawlRules.inMouthBox(info.wall, position, exitAnchor.Position.Y, rootHeight)
			and CrawlRules.facesWall(info.wall, yaw, pitch)
		then
			enter(player, grate, info, graph)
			return
		end
	end
end

local function pollOccupant(player: Player, occupant: Occupant)
	if player.Character ~= occupant.character then
		release(player, "Despawned")
		return
	end
	local root, humanoid = livingBody(player)
	local allowed = CrawlRules.canExit({
		live = live,
		lifeState = LifeStateService.GetState(player),
		controlLock = CharacterService.GetLock(player),
		hasBody = root ~= nil,
	})
	if not (allowed and root and humanoid) then
		return
	end
	local position = root.CFrame.Position
	for _, grate in grates do
		if grate.levelId ~= occupant.levelId or not GrateRules.isOpen(grate.state) or grate.model.Parent == nil then
			continue
		end
		local info = occupant.graph.grates[grate.id]
		if info and CrawlRules.crossedFace(info.wall, position) then
			exit(player, grate, root, humanoid)
			return
		end
	end
end

-- One pass (GameConfig.ServerTickHz; specs call it directly): unscrew noises, exits, then entries.
function VentNetworkService.Poll()
	if not live then
		return
	end
	local now = serverNow()
	for grate in table.clone(unscrewing) do
		local actor = grate.actor
		if actor and grate.state == "Unscrewing" and now >= grate.nextNoiseAt then
			emitNoise(grate, UNSCREW_NOISE, actor)
			grate.nextNoiseAt = now + UNSCREW_INTERVAL
		end
	end
	for player, occupant in table.clone(occupants) do
		pollOccupant(player, occupant)
	end
	for player in participants do
		if occupants[player] == nil then
			pollEntry(player)
		end
	end
end

--------------------------------------------------------------------------------
-- Dev commands
--------------------------------------------------------------------------------

local DEV_ACTIONS: { [string]: Enums.GrateState } = {
	open = "Open",
	kick = "Kicked",
	close = "Closed",
	lock = "Locked",
}

local function sortedGrateIds(levelId: string?): { string }
	local ids: { string } = {}
	for id, grate in grates do
		if levelId == nil or grate.levelId == levelId then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

-- The grate a dev command means: `query` as an id (exact, else a unique case-insensitive part of one), or the grate
-- nearest the caller for nil / "nearest".
local function findGrate(player: Player, query: string?): (Grate?, string?)
	if query == nil or string.lower(query) == "nearest" then
		local root = Instances.characterRoot(player)
		if not root then
			return nil, player.Name .. " has no character"
		end
		local position = root.CFrame.Position
		local best: Grate? = nil
		local bestDistance = math.huge
		for _, id in sortedGrateIds(nil) do
			local grate = grates[id]
			local distance = (grate.centre - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = grate, distance
			end
		end
		if best == nil then
			return nil, "no grates this run"
		end
		return best, nil
	end
	local exact = grates[query]
	if exact then
		return exact, nil
	end
	local needle = string.lower(query)
	local matches: { string } = {}
	for _, id in sortedGrateIds(nil) do
		if string.find(string.lower(id), needle, 1, true) then
			table.insert(matches, id)
		end
	end
	if #matches == 1 then
		return grates[matches[1]], nil
	end
	if #matches == 0 then
		return nil, string.format("no grate matches %q", query)
	end
	return nil, string.format("%d grates match %q: %s", #matches, query, table.concat(matches, ", "))
end

local function ventCommand(player: Player, args: { string }): string?
	local action = if args[1] then string.lower(args[1]) else ""
	local target = DEV_ACTIONS[action]
	if target == nil then
		return "usage: vent open|kick|close|lock [grateId|nearest]"
	end
	if not running then
		return "no run in progress"
	end
	local grate, why = findGrate(player, args[2])
	if not grate then
		return why
	end
	local before = grate.state
	local verdict = force(grate, target :: Enums.GrateState, player)
	local note = if verdict == "Apply" then "" else " (" .. verdict .. ")"
	return string.format("%s: %s -> %s%s", grate.id, before, grate.state, note)
end

local function ventsCommand(_player: Player, args: { string }): string?
	local only: Enums.LevelId? = if args[1] then DevToolsService.parseLevel(args[1]) else nil
	if args[1] and only == nil then
		return string.format("unknown level %q", args[1])
	end
	local lines: { string } = {}
	for _, levelId: Enums.LevelId in Enums.LevelId do
		if only and only ~= levelId then
			continue
		end
		local ids = sortedGrateIds(levelId)
		local crawlers = VentNetworkService.OccupantsOf(levelId)
		if #ids == 0 and #crawlers == 0 then
			continue
		end
		local counts: { [string]: number } = {}
		local entries: { string } = {}
		for _, id in ids do
			local state = grates[id].state
			counts[state] = (counts[state] or 0) + 1
			table.insert(entries, id .. "=" .. state)
		end
		local summary: { string } = {}
		for _, state in GRATE_STATES do
			if counts[state] then
				table.insert(summary, string.format("%d %s", counts[state], state))
			end
		end
		local names: { string } = {}
		for _, crawler in crawlers do
			table.insert(names, crawler.Name)
		end
		table.insert(
			lines,
			string.format(
				"%s: %s [%s]; crawling: %s",
				levelId,
				if #summary > 0 then table.concat(summary, ", ") else "no grates",
				table.concat(entries, ", "),
				if #names > 0 then table.concat(names, ", ") else "nobody"
			)
		)
	end
	if #lines == 0 then
		return "no grates this run"
	end
	return table.concat(lines, "\n")
end

local function registerDevCommands()
	DevToolsService.Register(
		"vent",
		"vent open|kick|close|lock [grateId|nearest]: force a vent grate (the nearest one by default)",
		ventCommand
	)
	DevToolsService.Register("vents", "vents [level]: every grate's state and who is crawling", ventsCommand, true)
end

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

local function onLifeStateChanged(player: Player, state: Enums.LifeState, _previous: Enums.LifeState)
	if state ~= "Alive" and state ~= "Downed" then
		release(player, state)
	end
end

local function onCharacterRemoving(player: Player, model: Model)
	local occupant = occupants[player]
	if occupant and occupant.character == model then
		release(player, "Despawned")
	end
end

-- Another system moved a crawler: off the rail means out of the duct.
local function onMoved(player: Player, model: Model, cframe: CFrame)
	if selfMoving[player] then
		return
	end
	local occupant = occupants[player]
	if not occupant or occupant.character ~= model then
		return
	end
	if VentGraph.nearest(occupant.graph, cframe.Position, CrawlRules.RailCorrectReach) == nil then
		release(player, "Moved")
	end
end

local function onPhaseChanged(phase: Enums.MatchPhase)
	live = running and LIVE_PHASES[phase] == true
end

local function releaseAll(reason: string)
	for player in table.clone(occupants) do
		release(player, reason)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function VentNetworkService.Init()
	if initialized then
		return
	end
	initialized = true
	serviceTrove:Add(InteractionService.Register(VentNetworkService.UnscrewHandler))
	serviceTrove:Add(InteractionService.Register(VentNetworkService.KickHandler))
	MovementAuthority.RegisterValidator(VALIDATOR_NAME, VentNetworkService.RailValidator)
	serviceTrove:Add(function()
		MovementAuthority.UnregisterValidator(VALIDATOR_NAME)
	end)
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.VentGrate), onGrateTagged)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.VentGrate), onGrateUntagged)
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(onPhaseChanged))
	serviceTrove:Add(LifeStateService.StateChanged:Connect(onLifeStateChanged))
	serviceTrove:Add(CharacterService.CharacterRemoving:Connect(onCharacterRemoving))
	serviceTrove:Add(CharacterService.Moved:Connect(onMoved))
	registerDevCommands()
end

function VentNetworkService.Start()
	local interval = 1 / GameConfig.ServerTickHz
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		if next(moving) ~= nil or next(unscrewing) ~= nil then
			protected("grate motion", function()
				VentNetworkService.StepMotions(dt)
			end)
		end
		accumulated += dt
		if accumulated < interval then
			return
		end
		accumulated = 0
		protected("vent poll", VentNetworkService.Poll)
	end)
end

function VentNetworkService.BeginRun(ctx: Types.RunContext)
	releaseAll("RunEnded")
	table.clear(participants)
	for _, player in ctx.participants do
		participants[player] = true
	end
	table.clear(crawled)
	table.clear(cooldownUntil)
	running = true
	live = true -- BeginRun runs while Deploying
	scan()
end

function VentNetworkService.EndRun()
	running = false
	live = false
	releaseAll("RunEnded")
	for model in table.clone(gratesByModel) do
		forget(model)
	end
	table.clear(participants)
	table.clear(crawled)
	table.clear(cooldownUntil)
end

function VentNetworkService.OnPlayerRemoving(player: Player)
	release(player, "Left")
	participants[player] = nil
	cooldownUntil[player] = nil
	selfMoving[player] = nil
end

return VentNetworkService
