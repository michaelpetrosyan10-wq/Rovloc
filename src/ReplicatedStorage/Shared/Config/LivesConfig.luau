--!strict
-- LivesConfig: the numbers of the lives rules (docs/design/game-spec-v2.md 3.3), per difficulty. LivesRules is the
-- pure logic over them; both platforms run it (the website through its port, checked against LivesRules.golden()).
-- Seconds, studs and health points.
--
--   A stage's first lethal hit (a catch, or damage that empties health) downs a player: they crawl at CrawlSpeed and
--   bleed out after BleedoutSeconds. From GetUpDelay after going down they may get up alone, once per stage, by holding
--   Interact GetUpHold seconds (up at GetUpHealth); a teammate's revive (ReviveHold, ReviveHealth) works at any time.
--   The next lethal hit on that stage, a catch while Downed or the bleed-out kills.
--   Respawns: RespawnsPerStage (set back at each playable stage's activation, never banked), RespawnsPerRun, and
--   SyringeRespawns with the Adrenaline Syringe; spent in that order. A respawn is RespawnBlackout seconds of black,
--   then the stage's entry at RespawnHealth, ignored by the Creature for RespawnGrace, with at least RespawnCharges
--   radar charges and RespawnTorch of the torch, the stage's get-up given back. The Creature is moved
--   MonsterClearance walked from that entry and PlayerClearance from every player, its next teleport TeleportDelay off.
--   Scripted chases: ChaseFreeAttempts failed attempts per squad are free; each one after spends a squad respawn.
--   Out of respawns: spectate, and stand up at CheckpointHealth at the next stage's entry; the run ends when nobody is
--   Alive or Downed and nobody has a respawn left. A carried objective item lies where its carrier fell, pinned on
--   every HUD for PinSeconds. A catch puts the pacing in Relax for at least RelaxSeconds (getting up fits inside it).

export type Lives = {
	CrawlSpeed: number,
	BleedoutSeconds: number,
	GetUpDelay: number,
	GetUpHold: number,
	GetUpHealth: number,
	ReviveHold: number,
	ReviveHealth: number,
	RespawnsPerStage: number,
	RespawnsPerRun: number,
	SyringeRespawns: number,
	ChaseFreeAttempts: number,
	RespawnBlackout: number,
	RespawnHealth: number,
	RespawnGrace: number,
	RespawnCharges: number,
	RespawnTorch: number, -- a share of the torch's capacity
	MonsterClearance: number,
	PlayerClearance: number,
	TeleportDelay: number,
	CheckpointHealth: number,
	PinSeconds: number,
	RelaxSeconds: number,
	CatchCooldown: number,
}

local Standard: Lives = table.freeze({
	CrawlSpeed = 2.5,
	BleedoutSeconds = 35,
	GetUpDelay = 3,
	GetUpHold = 4,
	GetUpHealth = 50,
	ReviveHold = 4,
	ReviveHealth = 50,
	RespawnsPerStage = 1,
	RespawnsPerRun = 0,
	SyringeRespawns = 1,
	ChaseFreeAttempts = 3,
	RespawnBlackout = 4,
	RespawnHealth = 50,
	RespawnGrace = 10,
	RespawnCharges = 1,
	RespawnTorch = 0.5,
	MonsterClearance = 70,
	PlayerClearance = 45,
	TeleportDelay = 45,
	CheckpointHealth = 50,
	PinSeconds = 10,
	RelaxSeconds = 25,
	CatchCooldown = 14.4,
})

local Nightmare: Lives = table.freeze({
	CrawlSpeed = 2.5,
	BleedoutSeconds = 35,
	GetUpDelay = 3,
	GetUpHold = 6,
	GetUpHealth = 35,
	ReviveHold = 4,
	ReviveHealth = 50,
	RespawnsPerStage = 0,
	RespawnsPerRun = 1,
	SyringeRespawns = 1,
	ChaseFreeAttempts = 2,
	RespawnBlackout = 4,
	RespawnHealth = 35,
	RespawnGrace = 6,
	RespawnCharges = 1,
	RespawnTorch = 0.5,
	MonsterClearance = 70,
	PlayerClearance = 45,
	TeleportDelay = 45,
	CheckpointHealth = 50,
	PinSeconds = 10,
	RelaxSeconds = 15,
	CatchCooldown = 8.8,
})

local LivesConfig = {}

LivesConfig.Standard = Standard
LivesConfig.Nightmare = Nightmare

-- The numbers of `difficulty` (Standard's for anything but "Nightmare").
function LivesConfig.of(difficulty: string): Lives
	return if difficulty == "Nightmare" then Nightmare else Standard
end

-- Both difficulties as plain data for the website (world.json meta.livesConfig).
function LivesConfig.exportMeta(): { [string]: any }
	return { Standard = table.clone(Standard), Nightmare = table.clone(Nightmare) }
end

return table.freeze(LivesConfig)
