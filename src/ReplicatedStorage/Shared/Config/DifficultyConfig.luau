--!strict
-- Standard vs Nightmare. Nightmare means a faster, sharper-eared Creature, more bear traps and fewer batteries.
-- Pacing knobs scale too, so Nightmare is harder at every stage rather than only faster.

export type DifficultySpec = {
	creatureSpeedMultiplier: number,
	hearingMultiplier: number,
	sightRangeMultiplier: number,
	trapCount: number, -- bear traps placed in the basement
	batteriesPerLevel: number, -- the batteries today's runs place per school level (RunDirector's prop plan)
	-- stun flasks a run places per stage, by stage id (RunDirector.pickFlasks; docs/design/game-spec-v2.md 4.2)
	flasksPerStage: { [string]: number },
	lockedGrateFraction: number, -- share of Lockable grates the RunDirector locks
	catchCooldownSeconds: number, -- after a catch the Creature retreats this long
	maxChaseSeconds: number, -- a chase gives up (FadeOut) after this, whatever happens
	chaseLostSeconds: number, -- line of sight lost this long: it searches the last seen point
	teleportCooldown: { number }, -- seconds between teleports: {low, high}
	reachInSeconds: number, -- it reaches into a hiding spot it saw someone climb into this long after
	postAirlockGraceSeconds: number,
	creditMultiplier: number,
}

local DifficultyConfig = {
	Standard = table.freeze({
		creatureSpeedMultiplier = 1,
		hearingMultiplier = 1, -- the Tall Man's radii (NoiseConfig) are the Standard reach
		sightRangeMultiplier = 1,
		trapCount = 10,
		batteriesPerLevel = 2, -- harder Standard: one fewer per floor
		flasksPerStage = table.freeze({
			Level0_Basement = 3,
			Level1_Hallways = 3,
			Level2_Auditorium = 2,
			City1_Rooftops = 2,
			City2_Airport = 2,
		}),
		lockedGrateFraction = 0.25,
		catchCooldownSeconds = 14.4, -- harder Standard: -20 %
		maxChaseSeconds = 22,
		chaseLostSeconds = 4,
		teleportCooldown = table.freeze({ 60, 120 }),
		reachInSeconds = 30,
		postAirlockGraceSeconds = 12,
		creditMultiplier = 1,
	} :: DifficultySpec),
	Nightmare = table.freeze({
		creatureSpeedMultiplier = 1.2,
		hearingMultiplier = 1.25,
		sightRangeMultiplier = 1.15,
		trapCount = 16,
		batteriesPerLevel = 1,
		flasksPerStage = table.freeze({
			Level0_Basement = 2,
			Level1_Hallways = 2,
			Level2_Auditorium = 1,
			City1_Rooftops = 1,
			City2_Airport = 1,
		}),
		lockedGrateFraction = 0.45,
		catchCooldownSeconds = 8.8, -- 11 s, -20 % with Standard
		maxChaseSeconds = 28,
		chaseLostSeconds = 5,
		teleportCooldown = table.freeze({ 40, 80 }),
		reachInSeconds = 24,
		postAirlockGraceSeconds = 6,
		creditMultiplier = 1.5,
	} :: DifficultySpec),
}

-- Both difficulties as plain data for the website (world.json meta.difficultyConfig).
function DifficultyConfig.exportMeta(): { [string]: any }
	local out: { [string]: any } = {}
	for _, name in { "Standard", "Nightmare" } do
		local spec: DifficultySpec = if name == "Nightmare"
			then DifficultyConfig.Nightmare
			else DifficultyConfig.Standard
		local row: { [string]: any } = table.clone(spec :: any)
		row.teleportCooldown = table.clone(spec.teleportCooldown)
		row.flasksPerStage = table.clone(spec.flasksPerStage)
		out[name] = row
	end
	return out
end

return table.freeze(DifficultyConfig)
