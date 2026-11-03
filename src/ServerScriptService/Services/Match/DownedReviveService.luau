--!strict
-- DownedReviveService: the teammate revive (spec §6, Downed, crawl and revive). A Downed participant carries a Revive
-- prompt that any Alive teammate can hold for GameConfig.ReviveHoldSeconds (4 s) to bring them back up.
--
-- The anchor. While a participant is Downed during a run their character's HumanoidRootPart holds a ReviveAnchor
-- Attachment, ANCHOR_DROP studs under the root (where the crawling body lies; the crawl pose is drawn on clients over
-- a standing physics body), tagged Interactable with OwnerUserId = the victim and one ProximityPrompt (PropKit:
-- PromptKind Revive, BaseHold ReviveHoldSeconds, Prompt.Revive / Prompt.Downed, PROMPT_DISTANCE studs). It moves with
-- the victim, so the channel's range check covers either of them moving away. A respawned character (fell out of
-- the world while Downed) gets a fresh anchor. Leaving Downed (revived, executed, bled out, leaving the server) or
-- the run ending (the RunEnded phase, EndRun) cancels any channel on it, with the reason, and destroys it; nobody is
-- revived once the run has ended.
--
-- The hold (Handler, served by InteractionService, which times the channel on the server clock: one reviver at a
-- time, the hold, range, the reviver's own life state). Audience "Others" (the victim never sees it). canUse:
-- reviveEligible over the reviver and the victim:
--   * the anchor still belongs to a Downed participant ("NoVictim"), and the reviver is not the victim ("Self"),
--   * the reviver is a run participant ("NotParticipant") and Alive ("LifeState"),
--   * the reviver is free: no ControlLock at all ("Busy": hiding, trapped, in a cutscene, being caught),
--   * the victim is not being caught (a Jumpscare / Drag / Cutscene lock: "Caught"); a Downed victim still held by a
--     bear trap can be revived (they stand up in the trap).
-- At GameConfig.ServerTickHz (Poll) every channel on an anchor is checked again with the same rule and cancelled with
-- its reason the moment it fails (the victim caught or executed, the reviver grabbed or hiding); InteractionService
-- already cancels on range and on the reviver's own life state. Poll also repairs anchors whose victim's character
-- was replaced without a CharacterSpawned (none should be, but a missing anchor would strand a Downed player).
-- Completing it: LifeStateService.Revive(victim, HEALTH_FRACTION), RunStats Revives + 1 for the reviver, Notify both
-- (Revive.YouRevived / Revive.RevivedBy with the other's name).
--
-- Around it. A teammate going down is announced to every other participant still playing (Notify
-- Downed.TeammateDown); a Downed participant dying is announced the same way (Downed.TeammateLost). Coming back up
-- (a teammate's revive or the Adrenaline Syringe, both LifeStateService.Revived) plays a Gasp at the survivor. The
-- syringe self-revive itself stays LoadoutService's (UseSyringe) and LifeStateService's (SyringeUsed); the client
-- surfaces it (DownedController).
--
-- Pure rules (tests/Specs/Revive.spec.luau): reviveEligible, cancelReason, clearReason. SetDependencies swaps every read and write
-- that leaves this module (life states, locks, characters, channels, the revive itself, stats, notifies, audio), so
-- specs run downs, holds, cancellations and revives on a fake clock with hand-built characters.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)

local log = Log.new("Revive")

local W = Attributes.World

-- Everything reviveEligible looks at for one reviver and one anchor.
export type ReviveCheck = {
	reviverUserId: number,
	victimUserId: number?, -- nil: the anchor no longer belongs to a Downed participant
	reviverParticipant: boolean,
	reviverState: Enums.LifeState,
	reviverLock: Enums.ControlLock,
	victimState: Enums.LifeState,
	victimLock: Enums.ControlLock,
}

-- Everything the service reads from and writes to the rest of the game (SetDependencies swaps the whole set).
export type Dependencies = {
	lifeState: (player: Player) -> Enums.LifeState,
	controlLock: (player: Player) -> Enums.ControlLock,
	character: (player: Player) -> Model?,
	channelActor: (host: Instance) -> Player?,
	cancelChannel: (host: Instance, reason: string) -> (),
	revive: (player: Player, healthFraction: number) -> (),
	stat: (player: Player, key: Enums.StatKey) -> (),
	notify: (player: Player, key: string, args: { string }) -> (),
	playOn: (preset: string, attach: Instance) -> (),
}

type Anchor = { victim: Player, attachment: Attachment }

local KIND: Enums.PromptKind = "Revive"
local ANCHOR_NAME = "ReviveAnchor"
local ANCHOR_DROP = 1.8 -- studs under the root centre: the crawling body's chest
local PROMPT_DISTANCE = 6
local HEALTH_FRACTION = 0.5
local REVIVE_STAT: Enums.StatKey = "Revives"
local GASP_PRESET = "Gasp"
local CAUGHT_LOCKS: { [string]: boolean } = { Jumpscare = true, Drag = true, Cutscene = true }
local LIVE_PHASES: { [string]: boolean } = { Deploying = true, InRun = true }
local DOWN_KEY = "Downed.TeammateDown"
local LOST_KEY = "Downed.TeammateLost"
local REVIVER_KEY = "Revive.YouRevived"
local VICTIM_KEY = "Revive.RevivedBy"

local DownedReviveService = {}

DownedReviveService.Name = "DownedReviveService"
DownedReviveService.AnchorName = ANCHOR_NAME
DownedReviveService.AnchorDrop = ANCHOR_DROP
DownedReviveService.PromptDistance = PROMPT_DISTANCE
DownedReviveService.HealthFraction = HEALTH_FRACTION

local function realDependencies(): Dependencies
	return {
		lifeState = LifeStateService.GetState,
		controlLock = CharacterService.GetLock,
		character = CharacterService.GetCharacter,
		channelActor = function(host: Instance): Player?
			local actor = InteractionService.GetChannel(host)
			return actor
		end,
		cancelChannel = InteractionService.CancelChannel,
		revive = LifeStateService.Revive,
		stat = function(player: Player, key: Enums.StatKey)
			RunStatsService.Increment(player, key)
		end,
		notify = function(player: Player, key: string, args: { string })
			local payload: Types.NotifyPayload = { key = key, args = args }
			Net.Server.fire("Notify", player, payload)
		end,
		playOn = function(preset: string, attach: Instance)
			AudioService.PlayOn(preset, attach)
		end,
	}
end

local deps: Dependencies = realDependencies()
local serviceTrove = Trove.new()
local initialized = false

local participants: { Player } = {}
local running = false
local anchors: { [Instance]: Anchor } = {} -- by attachment (the Interactable host)
local byVictim: { [Player]: Anchor } = {}

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Revive.spec.luau)
--------------------------------------------------------------------------------

-- Whether a reviver may hold (or keep holding) a revive anchor, and why not.
function DownedReviveService.reviveEligible(check: ReviveCheck): (boolean, string?)
	local victim = check.victimUserId
	if victim == nil or check.victimState ~= "Downed" then
		return false, "NoVictim"
	end
	if check.reviverUserId == victim then
		return false, "Self"
	end
	if not check.reviverParticipant then
		return false, "NotParticipant"
	end
	if check.reviverState ~= "Alive" then
		return false, "LifeState"
	end
	if check.reviverLock ~= "None" then
		return false, "Busy"
	end
	if CAUGHT_LOCKS[check.victimLock] then
		return false, "Caught"
	end
	return true, nil
end

-- Why a running revive channel must stop now (nil while it may go on): the same rule as starting one.
function DownedReviveService.cancelReason(check: ReviveCheck): string?
	local ok, reason = DownedReviveService.reviveEligible(check)
	return if ok then nil else reason or "Refused"
end

-- Why an anchor goes away when its victim leaves Downed for `state`.
function DownedReviveService.clearReason(state: Enums.LifeState): string
	if state == "Alive" then
		return "Revived"
	elseif state == "Dead" then
		return "VictimDied"
	end
	return "VictimState"
end

--------------------------------------------------------------------------------
-- Anchors
--------------------------------------------------------------------------------

local function isParticipant(player: Player): boolean
	return table.find(participants, player) ~= nil
end

local function rootOf(model: Model?): BasePart?
	if not model then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function checkFor(reviver: Player, anchor: Anchor?): ReviveCheck
	local victim = if anchor then anchor.victim else nil
	return {
		reviverUserId = reviver.UserId,
		victimUserId = if victim then victim.UserId else nil,
		reviverParticipant = isParticipant(reviver),
		reviverState = deps.lifeState(reviver),
		reviverLock = deps.controlLock(reviver),
		victimState = if victim then deps.lifeState(victim) else "Lobby",
		victimLock = if victim then deps.controlLock(victim) else "None",
	}
end

local function removeAnchor(anchor: Anchor, reason: string)
	if anchors[anchor.attachment] == anchor then
		anchors[anchor.attachment] = nil
	end
	if byVictim[anchor.victim] == anchor then
		byVictim[anchor.victim] = nil
	end
	deps.cancelChannel(anchor.attachment, reason)
	anchor.attachment:Destroy()
end

-- Puts a fresh anchor on the victim's current character (replacing an anchor on an older one). Returns it, or nil
-- when the victim has no character with a root yet (CharacterSpawned brings one).
local function placeAnchor(victim: Player): Anchor?
	local root = rootOf(deps.character(victim))
	if not root then
		return nil
	end
	local existing = byVictim[victim]
	if existing then
		if existing.attachment.Parent == root then
			return existing
		end
		removeAnchor(existing, "Respawned")
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = ANCHOR_NAME
	attachment.CFrame = CFrame.new(0, -ANCHOR_DROP, 0)
	attachment:SetAttribute(W.OwnerUserId, victim.UserId)
	PropKit.prompt(attachment, {
		kind = KIND,
		action = "Prompt.Revive",
		object = "Prompt.Downed",
		hold = GameConfig.ReviveHoldSeconds,
		distance = PROMPT_DISTANCE,
	}, attachment)
	-- Registered before it enters the DataModel: InteractionService's filter must already know it when it tracks.
	local anchor: Anchor = { victim = victim, attachment = attachment }
	anchors[attachment] = anchor
	byVictim[victim] = anchor
	attachment.Parent = root
	return anchor
end

local function notifyOthers(victim: Player, key: string)
	for _, player in participants do
		if player ~= victim then
			local state = deps.lifeState(player)
			if state == "Alive" or state == "Downed" then
				deps.notify(player, key, { victim.DisplayName })
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Handler
--------------------------------------------------------------------------------

local function onComplete(reviver: Player, _prompt: ProximityPrompt, host: Instance)
	local anchor = anchors[host]
	if not anchor then
		return
	end
	local ok, reason = DownedReviveService.reviveEligible(checkFor(reviver, anchor))
	if not ok then
		log.debug("%s's revive of %s refused at completion (%s)", reviver.Name, anchor.victim.Name, tostring(reason))
		return
	end
	local victim = anchor.victim
	deps.revive(victim, HEALTH_FRACTION)
	if deps.lifeState(victim) ~= "Alive" then
		return
	end
	deps.stat(reviver, REVIVE_STAT)
	deps.notify(reviver, REVIVER_KEY, { victim.DisplayName })
	deps.notify(victim, VICTIM_KEY, { reviver.DisplayName })
	log.info("%s revived %s", reviver.Name, victim.Name)
end

-- The InteractionService handler for Revive anchors (registered in Init; specs call it directly).
DownedReviveService.Handler = table.freeze({
	kind = KIND,
	filter = function(host: Instance, _prompt: ProximityPrompt): boolean
		return anchors[host] ~= nil
	end,
	canUse = function(player: Player, _prompt: ProximityPrompt, host: Instance): (boolean, string?)
		return DownedReviveService.reviveEligible(checkFor(player, anchors[host]))
	end,
	audience = function(_prompt: ProximityPrompt, _host: Instance): Enums.Audience
		return "Others"
	end,
	onBegin = function(player: Player, _prompt: ProximityPrompt, host: Instance)
		local anchor = anchors[host]
		if anchor then
			log.debug("%s started reviving %s", player.Name, anchor.victim.Name)
		end
	end,
	onComplete = onComplete,
} :: InteractionService.Handler)

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- The revive anchor on `victim` (nil unless they are a Downed participant with a character).
function DownedReviveService.GetAnchor(victim: Player): Attachment?
	local anchor = byVictim[victim]
	return if anchor then anchor.attachment else nil
end

-- A life-state change (LifeStateService.StateChanged): anchors appear on Down and go when the victim leaves Downed.
function DownedReviveService.OnStateChanged(player: Player, new: Enums.LifeState, old: Enums.LifeState)
	if not running or not isParticipant(player) then
		return
	end
	if new == "Downed" then
		placeAnchor(player)
		notifyOthers(player, DOWN_KEY)
		return
	end
	if old ~= "Downed" then
		return
	end
	local anchor = byVictim[player]
	if anchor then
		removeAnchor(anchor, DownedReviveService.clearReason(new))
	end
	if new == "Dead" then
		notifyOthers(player, LOST_KEY)
	end
end

-- A new character for `player` (CharacterService.CharacterSpawned): a Downed participant's anchor moves onto it.
function DownedReviveService.OnCharacterSpawned(player: Player)
	if running and isParticipant(player) and deps.lifeState(player) == "Downed" then
		placeAnchor(player)
	end
end

-- Someone came back up (LifeStateService.Revived: a teammate or the syringe): they gasp for air.
function DownedReviveService.OnRevived(player: Player)
	local root = rootOf(deps.character(player))
	if running and root then
		deps.playOn(GASP_PRESET, root)
	end
end

-- One check of every anchor and its channel (GameConfig.ServerTickHz; specs call it directly).
function DownedReviveService.Poll()
	if not running then
		return
	end
	for _, anchor in table.clone(anchors) do
		if anchors[anchor.attachment] ~= anchor then
			continue
		end
		local victim = anchor.victim
		local state: Enums.LifeState = deps.lifeState(victim)
		-- A boolean, not a direct comparison: refining the union would widen `state` to string below.
		local stillDowned = state == "Downed"
		if not stillDowned then
			removeAnchor(anchor, DownedReviveService.clearReason(state))
			continue
		end
		local root = rootOf(deps.character(victim))
		if root and anchor.attachment.Parent ~= root then
			placeAnchor(victim)
			continue
		end
		local reviver = deps.channelActor(anchor.attachment)
		if reviver then
			local reason = DownedReviveService.cancelReason(checkFor(reviver, anchor))
			if reason then
				deps.cancelChannel(anchor.attachment, reason)
			end
		end
	end
	-- A Downed participant without an anchor (their character arrived without a CharacterSpawned we saw).
	for _, player in participants do
		if byVictim[player] == nil and deps.lifeState(player) == "Downed" then
			placeAnchor(player)
		end
	end
end

-- Swaps in fakes (nil restores the real game).
function DownedReviveService.SetDependencies(fake: Dependencies?)
	deps = fake or realDependencies()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function clearAll(reason: string)
	for _, anchor in table.clone(anchors) do
		removeAnchor(anchor, reason)
	end
	table.clear(anchors)
	table.clear(byVictim)
end

function DownedReviveService.Init()
	if initialized then
		return
	end
	initialized = true
	serviceTrove:Add(InteractionService.Register(DownedReviveService.Handler))
	serviceTrove:Add(LifeStateService.StateChanged:Connect(DownedReviveService.OnStateChanged))
	serviceTrove:Add(LifeStateService.Revived:Connect(DownedReviveService.OnRevived))
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(DownedReviveService.OnPhaseChanged))
	serviceTrove:Add(CharacterService.CharacterSpawned:Connect(function(player: Player)
		-- After CharacterService has finished swapping the rig in.
		task.defer(DownedReviveService.OnCharacterSpawned, player)
	end))
end

function DownedReviveService.Start()
	local interval = 1 / GameConfig.ServerTickHz
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		accumulated += dt
		if accumulated < interval then
			return
		end
		accumulated = 0
		if not running then
			return
		end
		xpcall(DownedReviveService.Poll, function(err: any)
			log.warnThrottled("poll", 10, "revive poll failed: %s", tostring(err))
		end)
	end)
end

-- The match phase moved on (RunLifecycleService.PhaseChanged): once the run has ended (RunEnded / Results) nobody is
-- revived any more, whatever their life state.
function DownedReviveService.OnPhaseChanged(phase: Enums.MatchPhase)
	if running and not LIVE_PHASES[phase] then
		running = false
		clearAll("RunEnded")
	end
end

function DownedReviveService.BeginRun(ctx: Types.RunContext)
	clearAll("RunEnded")
	participants = table.clone(ctx.participants)
	running = true
end

function DownedReviveService.EndRun()
	clearAll("RunEnded")
	running = false
	table.clear(participants)
end

function DownedReviveService.OnPlayerRemoving(player: Player)
	local anchor = byVictim[player]
	if anchor then
		removeAnchor(anchor, "Left")
	end
	local index = table.find(participants, player)
	if index then
		table.remove(participants, index)
	end
end

return DownedReviveService
