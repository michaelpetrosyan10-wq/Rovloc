--!strict
-- LivesRules: the lives of a run as pure functions of plain data (docs/design/game-spec-v2.md 3.3, LivesConfig). The
-- life-state owner (the Roblox server, the web host) holds each player's Lives and asks these questions; the website's
-- port answers them the same, checked against golden() (written to build/cache/golden.json by the export).
--
--   Lives        a player's respawns by source (stage, run, syringe), their downs on this stage and whether they used
--                this stage's get-up
--   newRun       a run's start: the run respawns, the syringe's one extra (no stage respawn before the first stage)
--   stageActivated  a stage's activation: downs and the get-up reset; on a playable stage the stage respawn is set
--                (never banked: an unused one does not carry over)
--   lethal       a lethal hit (a catch, damage that empties health, the bleed-out): Downed the first time on a stage
--                while Alive, else Killed
--   getUp        the lone get-up: from GetUpDelay after going down, held GetUpHold, once per stage
--   getUpTime    seconds from going down to standing by the get-up (fits inside a catch's Relax)
--   revive       a teammate's revive: ReviveHold, up at ReviveHealth, at any time
--   respawnsLeft stage + run + syringe
--   spend        one respawn, in order: the stage's, the run's, the syringe's (source: the Lives field it came from)
--   afterDeath   what a kill leads to: a respawn (spent; the get-up given back), spectating (co-op) or the run's end
--                (solo)
--   respawn      what a respawn restores: its health, at least RespawnCharges radar charges, at least RespawnTorch of
--                the torch, the grace and the blackout
--   chaseFailure a failed scripted-chase attempt: free up to ChaseFreeAttempts, then the squad member with the most
--                respawns left (lowest slot first) pays one; with none left the run ends
--   runEnds      nobody Alive or Downed and nobody with a respawn left
--   checkpointReturn  the next stage's entry stands a spectator (or the dead) up at CheckpointHealth
--
-- Pure: no engine, no clock, no randomness; plain tables in and out (a nil field is absent, slot 0 is nobody).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LivesConfig = require(ReplicatedStorage.Shared.Config.LivesConfig)
local StageConfig = require(ReplicatedStorage.Shared.Config.StageConfig)

export type Lives = {
	stage: number,
	run: number,
	syringe: number,
	downs: number,
	getUpUsed: boolean,
}

export type Lethal = "Catch" | "Damage" | "BleedOut"

export type Member = { slot: number, left: number, lifeState: string? }

export type GoldenRow = { name: string, fn: string, args: { any }, expect: any }

local LivesRules = {}

local function copy(lives: Lives): Lives
	return {
		stage = lives.stage,
		run = lives.run,
		syringe = lives.syringe,
		downs = lives.downs,
		getUpUsed = lives.getUpUsed,
	}
end

function LivesRules.newRun(difficulty: string, syringe: boolean): Lives
	local c = LivesConfig.of(difficulty)
	return {
		stage = 0,
		run = c.RespawnsPerRun,
		syringe = if syringe then c.SyringeRespawns else 0,
		downs = 0,
		getUpUsed = false,
	}
end

function LivesRules.stageActivated(difficulty: string, lives: Lives, stageId: string): Lives
	local out = copy(lives)
	out.downs = 0
	out.getUpUsed = false
	if StageConfig.isPlayable(stageId) then
		out.stage = LivesConfig.of(difficulty).RespawnsPerStage
	end
	return out
end

function LivesRules.lethal(lives: Lives, lifeState: string, hit: Lethal): { outcome: string, lives: Lives }
	local out = copy(lives)
	if lifeState == "Alive" and hit ~= "BleedOut" and lives.downs == 0 then
		out.downs += 1
		return { outcome = "Downed", lives = out }
	end
	return { outcome = "Killed", lives = out }
end

function LivesRules.getUp(
	difficulty: string,
	lives: Lives,
	downedFor: number,
	held: number
): { allowed: boolean, up: boolean, health: number }
	local c = LivesConfig.of(difficulty)
	local allowed = not lives.getUpUsed and downedFor >= c.GetUpDelay
	local up = allowed and held >= c.GetUpHold
	return { allowed = allowed, up = up, health = if up then c.GetUpHealth else 0 }
end

function LivesRules.getUpTime(difficulty: string): number
	local c = LivesConfig.of(difficulty)
	return c.GetUpDelay + c.GetUpHold
end

function LivesRules.revive(difficulty: string, held: number): { up: boolean, health: number }
	local c = LivesConfig.of(difficulty)
	local up = held >= c.ReviveHold
	return { up = up, health = if up then c.ReviveHealth else 0 }
end

function LivesRules.respawnsLeft(lives: Lives): number
	return lives.stage + lives.run + lives.syringe
end

function LivesRules.spend(lives: Lives): { source: string, lives: Lives }
	local out = copy(lives)
	if out.stage > 0 then
		out.stage -= 1
		return { source = "stage", lives = out }
	elseif out.run > 0 then
		out.run -= 1
		return { source = "run", lives = out }
	elseif out.syringe > 0 then
		out.syringe -= 1
		return { source = "syringe", lives = out }
	end
	return { source = "none", lives = out }
end

function LivesRules.afterDeath(lives: Lives, squadSize: number): { action: string, source: string, lives: Lives }
	if LivesRules.respawnsLeft(lives) > 0 then
		local spent = LivesRules.spend(lives)
		local out = spent.lives
		out.downs = 0
		out.getUpUsed = false
		return { action = "Respawn", source = spent.source, lives = out }
	end
	return { action = if squadSize <= 1 then "RunOver" else "Spectate", source = "none", lives = copy(lives) }
end

function LivesRules.respawn(
	difficulty: string,
	charges: number,
	torch: number,
	torchMax: number
): { health: number, charges: number, torch: number, grace: number, blackout: number }
	local c = LivesConfig.of(difficulty)
	return {
		health = c.RespawnHealth,
		charges = math.max(charges, c.RespawnCharges),
		torch = math.max(torch, c.RespawnTorch * torchMax),
		grace = c.RespawnGrace,
		blackout = c.RespawnBlackout,
	}
end

function LivesRules.chaseFailure(
	difficulty: string,
	failures: number,
	squad: { Member }
): { free: boolean, payer: number, runEnds: boolean }
	if failures <= LivesConfig.of(difficulty).ChaseFreeAttempts then
		return { free = true, payer = 0, runEnds = false }
	end
	local payer: Member? = nil
	for _, member in squad do
		if member.left > 0 then
			local best = payer
			if best == nil or member.left > best.left or (member.left == best.left and member.slot < best.slot) then
				payer = member
			end
		end
	end
	if payer == nil then
		return { free = false, payer = 0, runEnds = true }
	end
	return { free = false, payer = payer.slot, runEnds = false }
end

function LivesRules.runEnds(squad: { Member }): boolean
	for _, member in squad do
		if member.lifeState == "Alive" or member.lifeState == "Downed" or member.left > 0 then
			return false
		end
	end
	return true
end

function LivesRules.checkpointReturn(difficulty: string, lifeState: string): { stand: boolean, health: number }
	if lifeState == "Spectating" or lifeState == "Dead" then
		return { stand = true, health = LivesConfig.of(difficulty).CheckpointHealth }
	end
	return { stand = false, health = 0 }
end

--------------------------------------------------------------------------------
-- Golden rows (every function's answers for the website's port to replay)
--------------------------------------------------------------------------------

-- A Lives table and a squad member, short (the rows hold many).
local function L(stage: number, run: number, syringe: number, downs: number, getUpUsed: boolean): Lives
	return { stage = stage, run = run, syringe = syringe, downs = downs, getUpUsed = getUpUsed }
end

local function M(slot: number, left: number, lifeState: string?): Member
	return { slot = slot, left = left, lifeState = lifeState }
end

local ROWS: { GoldenRow } = {}

local function row(name: string, fn: string, args: { any }, expect: any)
	table.insert(ROWS, { name = name, fn = fn, args = args, expect = expect })
end

row("newRun Standard syringe false", "newRun", { "Standard", false }, L(0, 0, 0, 0, false))
row("newRun Standard syringe true", "newRun", { "Standard", true }, L(0, 0, 1, 0, false))
row("newRun Nightmare syringe false", "newRun", { "Nightmare", false }, L(0, 1, 0, 0, false))
row("newRun Nightmare syringe true", "newRun", { "Nightmare", true }, L(0, 1, 1, 0, false))
row('newRun unknown difficulty "" is Standard', "newRun", { "", true }, L(0, 0, 1, 0, false))
row('newRun unknown difficulty "Easy" is Standard', "newRun", { "Easy", true }, L(0, 0, 1, 0, false))
row('newRun unknown difficulty "nightmare" is Standard', "newRun", { "nightmare", true }, L(0, 0, 1, 0, false))
row('newRun unknown difficulty "NIGHTMARE" is Standard', "newRun", { "NIGHTMARE", true }, L(0, 0, 1, 0, false))
row("newRun Standard (no syringe) again", "newRun", { "Standard", false }, L(0, 0, 0, 0, false))
row("newRun Nightmare with the syringe again", "newRun", { "Nightmare", true }, L(0, 1, 1, 0, false))
row("newRun unknown without syringe", "newRun", { "Hard", false }, L(0, 0, 0, 0, false))
row("newRun Nightmare without syringe again", "newRun", { "Nightmare", false }, L(0, 1, 0, 0, false))
row(
	"stageActivated Standard BackLot",
	"stageActivated",
	{ "Standard", L(0, 1, 1, 1, true), "BackLot" },
	L(0, 1, 1, 0, false)
)
row(
	"stageActivated Standard Level0_Basement",
	"stageActivated",
	{ "Standard", L(0, 1, 1, 1, true), "Level0_Basement" },
	L(1, 1, 1, 0, false)
)
row(
	"stageActivated Standard Level3_Roof",
	"stageActivated",
	{ "Standard", L(0, 1, 1, 1, true), "Level3_Roof" },
	L(1, 1, 1, 0, false)
)
row(
	"stageActivated Standard City2_Airport",
	"stageActivated",
	{ "Standard", L(0, 1, 1, 1, true), "City2_Airport" },
	L(1, 1, 1, 0, false)
)
row(
	"stageActivated Standard Runway",
	"stageActivated",
	{ "Standard", L(0, 1, 1, 1, true), "Runway" },
	L(1, 1, 1, 0, false)
)
row(
	"stageActivated Standard Bahamas",
	"stageActivated",
	{ "Standard", L(0, 1, 1, 1, true), "Bahamas" },
	L(0, 1, 1, 0, false)
)
row(
	"stageActivated Standard Nowhere",
	"stageActivated",
	{ "Standard", L(0, 1, 1, 1, true), "Nowhere" },
	L(0, 1, 1, 0, false)
)
row(
	"stageActivated Nightmare BackLot",
	"stageActivated",
	{ "Nightmare", L(0, 1, 1, 1, true), "BackLot" },
	L(0, 1, 1, 0, false)
)
row(
	"stageActivated Nightmare Level0_Basement",
	"stageActivated",
	{ "Nightmare", L(0, 1, 1, 1, true), "Level0_Basement" },
	L(0, 1, 1, 0, false)
)
row(
	"stageActivated Nightmare Level3_Roof",
	"stageActivated",
	{ "Nightmare", L(0, 1, 1, 1, true), "Level3_Roof" },
	L(0, 1, 1, 0, false)
)
row(
	"stageActivated Nightmare City2_Airport",
	"stageActivated",
	{ "Nightmare", L(0, 1, 1, 1, true), "City2_Airport" },
	L(0, 1, 1, 0, false)
)
row(
	"stageActivated Nightmare Runway",
	"stageActivated",
	{ "Nightmare", L(0, 1, 1, 1, true), "Runway" },
	L(0, 1, 1, 0, false)
)
row(
	"stageActivated Nightmare Bahamas",
	"stageActivated",
	{ "Nightmare", L(0, 1, 1, 1, true), "Bahamas" },
	L(0, 1, 1, 0, false)
)
row(
	"stageActivated Nightmare Nowhere",
	"stageActivated",
	{ "Nightmare", L(0, 1, 1, 1, true), "Nowhere" },
	L(0, 1, 1, 0, false)
)
row(
	"stageActivated Standard never banks an unused stage respawn",
	"stageActivated",
	{ "Standard", L(1, 0, 1, 0, false), "Level1_Hallways" },
	L(1, 0, 1, 0, false)
)
row(
	"stageActivated Nightmare keeps the run respawn",
	"stageActivated",
	{ "Nightmare", L(0, 1, 0, 1, true), "City1_Rooftops" },
	L(0, 1, 0, 0, false)
)
row(
	"lethal downs 0 Alive Catch",
	"lethal",
	{ L(1, 0, 0, 0, false), "Alive", "Catch" },
	{ lives = L(1, 0, 0, 1, false), outcome = "Downed" }
)
row(
	"lethal downs 0 Alive Damage",
	"lethal",
	{ L(1, 0, 0, 0, false), "Alive", "Damage" },
	{ lives = L(1, 0, 0, 1, false), outcome = "Downed" }
)
row(
	"lethal downs 0 Alive BleedOut",
	"lethal",
	{ L(1, 0, 0, 0, false), "Alive", "BleedOut" },
	{ lives = L(1, 0, 0, 0, false), outcome = "Killed" }
)
row(
	"lethal downs 0 Downed Catch",
	"lethal",
	{ L(1, 0, 0, 0, false), "Downed", "Catch" },
	{ lives = L(1, 0, 0, 0, false), outcome = "Killed" }
)
row(
	"lethal downs 0 Downed Damage",
	"lethal",
	{ L(1, 0, 0, 0, false), "Downed", "Damage" },
	{ lives = L(1, 0, 0, 0, false), outcome = "Killed" }
)
row(
	"lethal downs 0 Downed BleedOut",
	"lethal",
	{ L(1, 0, 0, 0, false), "Downed", "BleedOut" },
	{ lives = L(1, 0, 0, 0, false), outcome = "Killed" }
)
row(
	"lethal downs 1 Alive Catch",
	"lethal",
	{ L(1, 0, 0, 1, false), "Alive", "Catch" },
	{ lives = L(1, 0, 0, 1, false), outcome = "Killed" }
)
row(
	"lethal downs 1 Alive Damage",
	"lethal",
	{ L(1, 0, 0, 1, false), "Alive", "Damage" },
	{ lives = L(1, 0, 0, 1, false), outcome = "Killed" }
)
row(
	"lethal downs 1 Alive BleedOut",
	"lethal",
	{ L(1, 0, 0, 1, false), "Alive", "BleedOut" },
	{ lives = L(1, 0, 0, 1, false), outcome = "Killed" }
)
row(
	"lethal downs 1 Downed Catch",
	"lethal",
	{ L(1, 0, 0, 1, false), "Downed", "Catch" },
	{ lives = L(1, 0, 0, 1, false), outcome = "Killed" }
)
row(
	"lethal downs 1 Downed Damage",
	"lethal",
	{ L(1, 0, 0, 1, false), "Downed", "Damage" },
	{ lives = L(1, 0, 0, 1, false), outcome = "Killed" }
)
row(
	"lethal downs 1 Downed BleedOut",
	"lethal",
	{ L(1, 0, 0, 1, false), "Downed", "BleedOut" },
	{ lives = L(1, 0, 0, 1, false), outcome = "Killed" }
)
row(
	"getUp Standard used false downed 2.9 held 10",
	"getUp",
	{ "Standard", L(1, 0, 0, 1, false), 2.9, 10 },
	{ allowed = false, health = 0, up = false }
)
row(
	"getUp Standard used false downed 3 held 0",
	"getUp",
	{ "Standard", L(1, 0, 0, 1, false), 3, 0 },
	{ allowed = true, health = 0, up = false }
)
row(
	"getUp Standard used false downed 3 held 3.9",
	"getUp",
	{ "Standard", L(1, 0, 0, 1, false), 3, 3.9 },
	{ allowed = true, health = 0, up = false }
)
row(
	"getUp Standard used false downed 3 held 4",
	"getUp",
	{ "Standard", L(1, 0, 0, 1, false), 3, 4 },
	{ allowed = true, health = 50, up = true }
)
row(
	"getUp Standard used false downed 8 held 5.9",
	"getUp",
	{ "Standard", L(1, 0, 0, 1, false), 8, 5.9 },
	{ allowed = true, health = 50, up = true }
)
row(
	"getUp Standard used false downed 9 held 6",
	"getUp",
	{ "Standard", L(1, 0, 0, 1, false), 9, 6 },
	{ allowed = true, health = 50, up = true }
)
row(
	"getUp Standard used true downed 20 held 10",
	"getUp",
	{ "Standard", L(1, 0, 0, 1, true), 20, 10 },
	{ allowed = false, health = 0, up = false }
)
row(
	"getUp Nightmare used false downed 2.9 held 10",
	"getUp",
	{ "Nightmare", L(1, 0, 0, 1, false), 2.9, 10 },
	{ allowed = false, health = 0, up = false }
)
row(
	"getUp Nightmare used false downed 3 held 0",
	"getUp",
	{ "Nightmare", L(1, 0, 0, 1, false), 3, 0 },
	{ allowed = true, health = 0, up = false }
)
row(
	"getUp Nightmare used false downed 3 held 3.9",
	"getUp",
	{ "Nightmare", L(1, 0, 0, 1, false), 3, 3.9 },
	{ allowed = true, health = 0, up = false }
)
row(
	"getUp Nightmare used false downed 3 held 4",
	"getUp",
	{ "Nightmare", L(1, 0, 0, 1, false), 3, 4 },
	{ allowed = true, health = 0, up = false }
)
row(
	"getUp Nightmare used false downed 8 held 5.9",
	"getUp",
	{ "Nightmare", L(1, 0, 0, 1, false), 8, 5.9 },
	{ allowed = true, health = 0, up = false }
)
row(
	"getUp Nightmare used false downed 9 held 6",
	"getUp",
	{ "Nightmare", L(1, 0, 0, 1, false), 9, 6 },
	{ allowed = true, health = 35, up = true }
)
row(
	"getUp Nightmare used true downed 20 held 10",
	"getUp",
	{ "Nightmare", L(1, 0, 0, 1, true), 20, 10 },
	{ allowed = false, health = 0, up = false }
)
row('getUpTime 1 "Standard"', "getUpTime", { "Standard" }, 7)
row('getUpTime 2 "Nightmare"', "getUpTime", { "Nightmare" }, 9)
row('getUpTime 3 ""', "getUpTime", { "" }, 7)
row('getUpTime 4 "Easy"', "getUpTime", { "Easy" }, 7)
row('getUpTime 5 "standard"', "getUpTime", { "standard" }, 7)
row('getUpTime 6 "NIGHTMARE"', "getUpTime", { "NIGHTMARE" }, 7)
row('getUpTime 7 "Standard"', "getUpTime", { "Standard" }, 7)
row('getUpTime 8 "Nightmare"', "getUpTime", { "Nightmare" }, 9)
row('getUpTime 9 "x"', "getUpTime", { "x" }, 7)
row('getUpTime 10 "Nightmare"', "getUpTime", { "Nightmare" }, 9)
row('getUpTime 11 "Standard"', "getUpTime", { "Standard" }, 7)
row('getUpTime 12 "?"', "getUpTime", { "?" }, 7)
row("revive Standard held 0", "revive", { "Standard", 0 }, { health = 0, up = false })
row("revive Standard held 2", "revive", { "Standard", 2 }, { health = 0, up = false })
row("revive Standard held 3.99", "revive", { "Standard", 3.99 }, { health = 0, up = false })
row("revive Standard held 4", "revive", { "Standard", 4 }, { health = 50, up = true })
row("revive Standard held 10", "revive", { "Standard", 10 }, { health = 50, up = true })
row("revive Standard held 4.5", "revive", { "Standard", 4.5 }, { health = 50, up = true })
row("revive Nightmare held 0", "revive", { "Nightmare", 0 }, { health = 0, up = false })
row("revive Nightmare held 2", "revive", { "Nightmare", 2 }, { health = 0, up = false })
row("revive Nightmare held 3.99", "revive", { "Nightmare", 3.99 }, { health = 0, up = false })
row("revive Nightmare held 4", "revive", { "Nightmare", 4 }, { health = 50, up = true })
row("revive Nightmare held 10", "revive", { "Nightmare", 10 }, { health = 50, up = true })
row("revive Nightmare held 4.5", "revive", { "Nightmare", 4.5 }, { health = 50, up = true })
row("respawnsLeft 1", "respawnsLeft", { L(0, 0, 0, 0, false) }, 0)
row("respawnsLeft 2", "respawnsLeft", { L(1, 0, 0, 0, false) }, 1)
row("respawnsLeft 3", "respawnsLeft", { L(0, 1, 0, 0, false) }, 1)
row("respawnsLeft 4", "respawnsLeft", { L(0, 0, 1, 0, false) }, 1)
row("respawnsLeft 5", "respawnsLeft", { L(1, 0, 1, 1, true) }, 2)
row("respawnsLeft 6", "respawnsLeft", { L(0, 1, 1, 0, false) }, 2)
row("respawnsLeft 7", "respawnsLeft", { L(1, 1, 1, 0, false) }, 3)
row("respawnsLeft 8", "respawnsLeft", { L(2, 0, 0, 0, false) }, 2)
row("respawnsLeft 9", "respawnsLeft", { L(0, 2, 1, 1, false) }, 3)
row("respawnsLeft 10", "respawnsLeft", { L(1, 0, 0, 1, true) }, 1)
row("respawnsLeft 11", "respawnsLeft", { L(0, 0, 2, 0, false) }, 2)
row("respawnsLeft 12", "respawnsLeft", { L(3, 3, 3, 0, false) }, 9)
row("spend 1", "spend", { L(1, 0, 0, 0, false) }, { lives = L(0, 0, 0, 0, false), source = "stage" })
row("spend 2", "spend", { L(1, 1, 1, 1, true) }, { lives = L(0, 1, 1, 1, true), source = "stage" })
row("spend 3", "spend", { L(0, 1, 1, 0, false) }, { lives = L(0, 0, 1, 0, false), source = "run" })
row("spend 4", "spend", { L(0, 1, 0, 1, false) }, { lives = L(0, 0, 0, 1, false), source = "run" })
row("spend 5", "spend", { L(0, 0, 1, 0, true) }, { lives = L(0, 0, 0, 0, true), source = "syringe" })
row("spend 6", "spend", { L(0, 0, 0, 0, false) }, { lives = L(0, 0, 0, 0, false), source = "none" })
row("spend 7", "spend", { L(2, 0, 1, 0, false) }, { lives = L(1, 0, 1, 0, false), source = "stage" })
row("spend 8", "spend", { L(0, 2, 0, 0, false) }, { lives = L(0, 1, 0, 0, false), source = "run" })
row("spend 9", "spend", { L(1, 0, 1, 1, false) }, { lives = L(0, 0, 1, 1, false), source = "stage" })
row("spend 10", "spend", { L(0, 0, 2, 1, true) }, { lives = L(0, 0, 1, 1, true), source = "syringe" })
row("spend 11", "spend", { L(0, 1, 1, 1, true) }, { lives = L(0, 0, 1, 1, true), source = "run" })
row("spend 12", "spend", { L(1, 1, 0, 0, false) }, { lives = L(0, 1, 0, 0, false), source = "stage" })
row(
	"afterDeath 1/0/0 squad 1 used",
	"afterDeath",
	{ L(1, 0, 0, 1, true), 1 },
	{ action = "Respawn", lives = L(0, 0, 0, 0, false), source = "stage" }
)
row(
	"afterDeath 0/1/0 squad 1 used",
	"afterDeath",
	{ L(0, 1, 0, 1, true), 1 },
	{ action = "Respawn", lives = L(0, 0, 0, 0, false), source = "run" }
)
row(
	"afterDeath 0/0/1 squad 4 used",
	"afterDeath",
	{ L(0, 0, 1, 1, true), 4 },
	{ action = "Respawn", lives = L(0, 0, 0, 0, false), source = "syringe" }
)
row(
	"afterDeath 0/0/0 squad 1 used",
	"afterDeath",
	{ L(0, 0, 0, 1, true), 1 },
	{ action = "RunOver", lives = L(0, 0, 0, 1, true), source = "none" }
)
row(
	"afterDeath 0/0/0 squad 2 used",
	"afterDeath",
	{ L(0, 0, 0, 1, true), 2 },
	{ action = "Spectate", lives = L(0, 0, 0, 1, true), source = "none" }
)
row(
	"afterDeath 0/0/0 squad 4",
	"afterDeath",
	{ L(0, 0, 0, 0, false), 4 },
	{ action = "Spectate", lives = L(0, 0, 0, 0, false), source = "none" }
)
row(
	"afterDeath 1/0/1 squad 3",
	"afterDeath",
	{ L(1, 0, 1, 1, false), 3 },
	{ action = "Respawn", lives = L(0, 0, 1, 0, false), source = "stage" }
)
row(
	"afterDeath 0/1/1 squad 2 used",
	"afterDeath",
	{ L(0, 1, 1, 1, true), 2 },
	{ action = "Respawn", lives = L(0, 0, 1, 0, false), source = "run" }
)
row(
	"afterDeath 0/0/0 squad 0",
	"afterDeath",
	{ L(0, 0, 0, 1, false), 0 },
	{ action = "RunOver", lives = L(0, 0, 0, 1, false), source = "none" }
)
row(
	"afterDeath 2/0/0 squad 1 used",
	"afterDeath",
	{ L(2, 0, 0, 1, true), 1 },
	{ action = "Respawn", lives = L(1, 0, 0, 0, false), source = "stage" }
)
row(
	"afterDeath 0/0/1 squad 1",
	"afterDeath",
	{ L(0, 0, 1, 0, false), 1 },
	{ action = "Respawn", lives = L(0, 0, 0, 0, false), source = "syringe" }
)
row(
	"afterDeath 0/0/0 squad 3 used",
	"afterDeath",
	{ L(0, 0, 0, 1, true), 3 },
	{ action = "Spectate", lives = L(0, 0, 0, 1, true), source = "none" }
)
row(
	"respawn Standard charges 0 torch 0 of 100",
	"respawn",
	{ "Standard", 0, 0, 100 },
	{ blackout = 4, charges = 1, grace = 10, health = 50, torch = 50 }
)
row(
	"respawn Standard charges 2 torch 80 of 100",
	"respawn",
	{ "Standard", 2, 80, 100 },
	{ blackout = 4, charges = 2, grace = 10, health = 50, torch = 80 }
)
row(
	"respawn Standard charges 0 torch 30 of 150",
	"respawn",
	{ "Standard", 0, 30, 150 },
	{ blackout = 4, charges = 1, grace = 10, health = 50, torch = 75 }
)
row(
	"respawn Standard charges 3 torch 49 of 100",
	"respawn",
	{ "Standard", 3, 49, 100 },
	{ blackout = 4, charges = 3, grace = 10, health = 50, torch = 50 }
)
row(
	"respawn Standard charges 1 torch 50 of 100",
	"respawn",
	{ "Standard", 1, 50, 100 },
	{ blackout = 4, charges = 1, grace = 10, health = 50, torch = 50 }
)
row(
	"respawn Standard charges 0 torch 100 of 150",
	"respawn",
	{ "Standard", 0, 100, 150 },
	{ blackout = 4, charges = 1, grace = 10, health = 50, torch = 100 }
)
row(
	"respawn Nightmare charges 0 torch 0 of 100",
	"respawn",
	{ "Nightmare", 0, 0, 100 },
	{ blackout = 4, charges = 1, grace = 6, health = 35, torch = 50 }
)
row(
	"respawn Nightmare charges 2 torch 80 of 100",
	"respawn",
	{ "Nightmare", 2, 80, 100 },
	{ blackout = 4, charges = 2, grace = 6, health = 35, torch = 80 }
)
row(
	"respawn Nightmare charges 0 torch 30 of 150",
	"respawn",
	{ "Nightmare", 0, 30, 150 },
	{ blackout = 4, charges = 1, grace = 6, health = 35, torch = 75 }
)
row(
	"respawn Nightmare charges 3 torch 49 of 100",
	"respawn",
	{ "Nightmare", 3, 49, 100 },
	{ blackout = 4, charges = 3, grace = 6, health = 35, torch = 50 }
)
row(
	"respawn Nightmare charges 1 torch 50 of 100",
	"respawn",
	{ "Nightmare", 1, 50, 100 },
	{ blackout = 4, charges = 1, grace = 6, health = 35, torch = 50 }
)
row(
	"respawn Nightmare charges 0 torch 100 of 150",
	"respawn",
	{ "Nightmare", 0, 100, 150 },
	{ blackout = 4, charges = 1, grace = 6, health = 35, torch = 100 }
)
row(
	"chaseFailure Standard failure 1 of a squad of 4",
	"chaseFailure",
	{ "Standard", 1, { M(1, 1), M(2, 2), M(3, 2), M(4, 0) } },
	{ free = true, payer = 0, runEnds = false }
)
row(
	"chaseFailure Standard failure 2 of a squad of 4",
	"chaseFailure",
	{ "Standard", 2, { M(1, 1), M(2, 2), M(3, 2), M(4, 0) } },
	{ free = true, payer = 0, runEnds = false }
)
row(
	"chaseFailure Standard failure 3 of a squad of 4",
	"chaseFailure",
	{ "Standard", 3, { M(1, 1), M(2, 2), M(3, 2), M(4, 0) } },
	{ free = true, payer = 0, runEnds = false }
)
row(
	"chaseFailure Standard failure 4 of a squad of 4",
	"chaseFailure",
	{ "Standard", 4, { M(1, 1), M(2, 2), M(3, 2), M(4, 0) } },
	{ free = false, payer = 2, runEnds = false }
)
row(
	"chaseFailure Standard failure 4 of a squad of 2 (none left)",
	"chaseFailure",
	{ "Standard", 4, { M(1, 0), M(2, 0) } },
	{ free = false, payer = 0, runEnds = true }
)
row(
	"chaseFailure Standard failure 5 of a squad of 2 (tie)",
	"chaseFailure",
	{ "Standard", 5, { M(3, 1), M(1, 1) } },
	{ free = false, payer = 1, runEnds = false }
)
row(
	"chaseFailure Standard failure 3 of a squad of 2 (none left)",
	"chaseFailure",
	{ "Standard", 3, { M(1, 0), M(2, 0) } },
	{ free = true, payer = 0, runEnds = false }
)
row(
	"chaseFailure Nightmare failure 1 of a squad of 4",
	"chaseFailure",
	{ "Nightmare", 1, { M(1, 1), M(2, 2), M(3, 2), M(4, 0) } },
	{ free = true, payer = 0, runEnds = false }
)
row(
	"chaseFailure Nightmare failure 2 of a squad of 4",
	"chaseFailure",
	{ "Nightmare", 2, { M(1, 1), M(2, 2), M(3, 2), M(4, 0) } },
	{ free = true, payer = 0, runEnds = false }
)
row(
	"chaseFailure Nightmare failure 3 of a squad of 4",
	"chaseFailure",
	{ "Nightmare", 3, { M(1, 1), M(2, 2), M(3, 2), M(4, 0) } },
	{ free = false, payer = 2, runEnds = false }
)
row(
	"chaseFailure Nightmare failure 4 of a squad of 4",
	"chaseFailure",
	{ "Nightmare", 4, { M(1, 1), M(2, 2), M(3, 2), M(4, 0) } },
	{ free = false, payer = 2, runEnds = false }
)
row(
	"chaseFailure Nightmare failure 4 of a squad of 2 (none left)",
	"chaseFailure",
	{ "Nightmare", 4, { M(1, 0), M(2, 0) } },
	{ free = false, payer = 0, runEnds = true }
)
row(
	"chaseFailure Nightmare failure 5 of a squad of 2 (tie)",
	"chaseFailure",
	{ "Nightmare", 5, { M(3, 1), M(1, 1) } },
	{ free = false, payer = 1, runEnds = false }
)
row(
	"chaseFailure Nightmare failure 3 of a squad of 2 (none left)",
	"chaseFailure",
	{ "Nightmare", 3, { M(1, 0), M(2, 0) } },
	{ free = false, payer = 0, runEnds = true }
)
row("runEnds 1", "runEnds", { { M(1, 0, "Alive") } }, false)
row("runEnds 2", "runEnds", { { M(1, 0, "Dead") } }, true)
row("runEnds 3", "runEnds", { { M(1, 1, "Dead") } }, false)
row("runEnds 4", "runEnds", { { M(1, 0, "Downed") } }, false)
row("runEnds 5", "runEnds", { { M(1, 0, "Spectating"), M(2, 0, "Dead") } }, true)
row("runEnds 6", "runEnds", { { M(1, 0, "Spectating"), M(2, 0, "Alive") } }, false)
row("runEnds 7", "runEnds", { { M(1, 0, "Spectating"), M(2, 1, "Dead") } }, false)
row("runEnds 8", "runEnds", { { M(1, 0, "Spectating"), M(2, 0, "Downed") } }, false)
row(
	"runEnds 9",
	"runEnds",
	{ { M(1, 0, "Dead"), M(2, 0, "Dead"), M(3, 0, "Spectating"), M(4, 0, "Spectating") } },
	true
)
row(
	"runEnds 10",
	"runEnds",
	{ { M(1, 0, "Dead"), M(2, 0, "Dead"), M(3, 0, "Spectating"), M(4, 1, "Spectating") } },
	false
)
row("runEnds 11", "runEnds", { {} }, true)
row("runEnds 12", "runEnds", { { M(1, 0, "Lobby") } }, true)
row("checkpointReturn Standard Alive", "checkpointReturn", { "Standard", "Alive" }, { health = 0, stand = false })
row("checkpointReturn Standard Downed", "checkpointReturn", { "Standard", "Downed" }, { health = 0, stand = false })
row("checkpointReturn Standard Dead", "checkpointReturn", { "Standard", "Dead" }, { health = 50, stand = true })
row(
	"checkpointReturn Standard Spectating",
	"checkpointReturn",
	{ "Standard", "Spectating" },
	{ health = 50, stand = true }
)
row("checkpointReturn Standard Lobby", "checkpointReturn", { "Standard", "Lobby" }, { health = 0, stand = false })
row("checkpointReturn Standard Escaped", "checkpointReturn", { "Standard", "Escaped" }, { health = 0, stand = false })
row("checkpointReturn Nightmare Alive", "checkpointReturn", { "Nightmare", "Alive" }, { health = 0, stand = false })
row("checkpointReturn Nightmare Downed", "checkpointReturn", { "Nightmare", "Downed" }, { health = 0, stand = false })
row("checkpointReturn Nightmare Dead", "checkpointReturn", { "Nightmare", "Dead" }, { health = 50, stand = true })
row(
	"checkpointReturn Nightmare Spectating",
	"checkpointReturn",
	{ "Nightmare", "Spectating" },
	{ health = 50, stand = true }
)
row("checkpointReturn Nightmare Lobby", "checkpointReturn", { "Nightmare", "Lobby" }, { health = 0, stand = false })
row("checkpointReturn Nightmare Escaped", "checkpointReturn", { "Nightmare", "Escaped" }, { health = 0, stand = false })

-- The golden rows: { name, fn, args, expect } with expect what LivesRules[fn](table.unpack(args)) returns.
function LivesRules.golden(): { GoldenRow }
	return ROWS
end

return table.freeze(LivesRules)
