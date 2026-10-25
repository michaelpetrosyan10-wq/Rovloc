--!strict
-- Every remote in the game. Net creates them from this list; nothing else creates RemoteEvents.
-- Client-to-server entries declare a validator, a token-bucket rate limit, and the match phases and
-- life states in which the server accepts them. Payload shapes match Types.*Payload.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local V = require(ReplicatedStorage.Shared.Net.Validators)

export type RateLimit = { burst: number, perSecond: number }

export type RemoteSpec = {
	name: string,
	kind: Enums.RemoteKind,
	direction: Enums.RemoteDirection,
	validate: V.Validator?,
	rate: RateLimit?,
	phases: { Enums.MatchPhase }?, -- nil = any phase
	lifeStates: { Enums.LifeState }?, -- nil = any life state
}

local INT16 = 32767

local RUN_PHASES: { Enums.MatchPhase } = { "InRun", "Deploying" }
local LOBBY_PHASES: { Enums.MatchPhase } = { "Lobby", "Countdown" }
local RESULTS_PHASES: { Enums.MatchPhase } = { "Results" }
local PLAYING: { Enums.LifeState } = { "Alive", "Downed" }
local ALIVE: { Enums.LifeState } = { "Alive" }
local WATCHING: { Enums.LifeState } = { "Spectating", "Dead" }

local list: { RemoteSpec } = {
	---------------------------------------------------------------- client -> server
	{
		name = "ClientWorldReady",
		kind = "Event",
		direction = "ToServer",
		validate = V.shape({ partCount = V.integer(0, 10_000_000) }),
		rate = { burst = 3, perSecond = 0.2 },
	},
	{
		name = "MoveIntent",
		kind = "Event",
		direction = "ToServer",
		validate = V.shape({ intent = V.enum(Enums.MoveIntent) }),
		rate = { burst = 12, perSecond = 8 },
		phases = RUN_PHASES,
		lifeStates = PLAYING,
	},
	{
		name = "FlashlightToggle",
		kind = "Event",
		direction = "ToServer",
		validate = V.shape({ on = V.boolean() }),
		rate = { burst = 6, perSecond = 4 },
	},
	{
		name = "ItemThrow",
		kind = "Event",
		direction = "ToServer",
		validate = V.shape({ direction = V.unitVector() }),
		rate = { burst = 2, perSecond = 1 },
		phases = RUN_PHASES,
		lifeStates = ALIVE,
	},
	{
		name = "BreathInput",
		kind = "Event",
		direction = "ToServer",
		validate = V.shape({ held = V.boolean() }),
		rate = { burst = 10, perSecond = 6 },
		phases = RUN_PHASES,
		lifeStates = ALIVE,
	},
	{
		name = "StrugglePress",
		kind = "Event",
		direction = "ToServer",
		validate = V.shape({ sequence = V.integer(0, 1_000_000) }),
		rate = { burst = 12, perSecond = 12 },
		phases = RUN_PHASES,
		lifeStates = PLAYING,
	},
	{
		name = "UseSyringe",
		kind = "Event",
		direction = "ToServer",
		validate = V.shape({ mode = V.enum(Enums.SyringeMode) }),
		rate = { burst = 2, perSecond = 0.5 },
		phases = RUN_PHASES,
		lifeStates = PLAYING,
	},
	{
		name = "ExitHide",
		kind = "Event",
		direction = "ToServer",
		validate = V.empty(),
		rate = { burst = 3, perSecond = 1 },
		phases = RUN_PHASES,
		lifeStates = ALIVE,
	},
	{
		name = "ParachutePull",
		kind = "Event",
		direction = "ToServer",
		validate = V.empty(),
		rate = { burst = 3, perSecond = 1 },
		phases = RUN_PHASES,
		lifeStates = ALIVE,
	},
	{
		name = "LobbyAction",
		kind = "Event",
		direction = "ToServer",
		validate = V.shape({
			action = V.enum(Enums.LobbyActionKind),
			difficulty = V.optional(V.enum(Enums.Difficulty)),
			perk = V.optional(V.enum(Enums.PerkId)),
		}),
		rate = { burst = 8, perSecond = 3 },
		phases = LOBBY_PHASES,
	},
	{
		name = "PlayAgain",
		kind = "Event",
		direction = "ToServer",
		validate = V.empty(),
		rate = { burst = 3, perSecond = 1 },
		phases = RESULTS_PHASES,
	},
	{
		name = "SettingsSave",
		kind = "Event",
		direction = "ToServer",
		validate = V.shape({
			settings = V.mapOf(V.string(32), V.oneOf({ V.number(-1000, 1000), V.boolean() }), 24),
		}),
		rate = { burst = 4, perSecond = 0.5 },
	},
	{
		name = "SpectateCycle",
		kind = "Event",
		direction = "ToServer",
		validate = V.shape({ direction = V.integer(-1, 1) }),
		rate = { burst = 6, perSecond = 4 },
		lifeStates = WATCHING,
	},
	{
		name = "DevCommand",
		kind = "Event",
		direction = "ToServer",
		validate = V.shape({ command = V.string(32), args = V.arrayOf(V.string(64), 8) }),
		rate = { burst = 6, perSecond = 2 },
	},
	{
		name = "LookRelay",
		kind = "Unreliable",
		direction = "ToServer",
		validate = V.shape({ yaw = V.integer(-INT16, INT16), pitch = V.integer(-INT16, INT16) }),
		rate = { burst = 30, perSecond = 25 },
	},
	{
		name = "PerkPurchase",
		kind = "Function",
		direction = "ToServer",
		validate = V.shape({ perk = V.enum(Enums.PerkId) }),
		rate = { burst = 4, perSecond = 1 },
		phases = LOBBY_PHASES,
	},

	---------------------------------------------------------------- server -> client
	{ name = "OneShot", kind = "Event", direction = "ToClient" },
	{ name = "PrivateCue", kind = "Event", direction = "ToClient" },
	{ name = "AudioCue", kind = "Event", direction = "ToClient" },
	{ name = "ProjectileEvent", kind = "Event", direction = "ToClient" },
	{ name = "RunSummary", kind = "Event", direction = "ToClient" },
	{ name = "Notify", kind = "Event", direction = "ToClient" },
	{ name = "LookBroadcast", kind = "Unreliable", direction = "ToClient" },
	{ name = "DevOverlay", kind = "Event", direction = "ToClient" }, -- dev-only visualizers (noise rings, plans)
}

local byName: { [string]: RemoteSpec } = {}
for _, spec in list do
	assert(byName[spec.name] == nil, "duplicate remote " .. spec.name)
	byName[spec.name] = spec
end

local RemoteRegistry = {}

RemoteRegistry.List = table.freeze(list)

function RemoteRegistry.get(name: string): RemoteSpec?
	return byName[name]
end

return table.freeze(RemoteRegistry)
