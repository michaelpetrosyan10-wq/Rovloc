--!strict
-- Standard vs Nightmare. Nightmare means a faster, sharper-eared Creature, more bear traps and fewer batteries.
-- Pacing knobs scale too, so Nightmare is harder at every stage rather than only faster.

export type DifficultySpec = {
	creatureSpeedMultiplier: number,
	hearingMultiplier: number,
	sightRangeMultiplier: number,
	trapCount: number, -- bear traps placed in the basement
	batteriesPerLevel: number,
	flasksScienceHall: number,
	flasksPool: number,
	lockedGrateFraction: number, -- share of Lockable grates the RunDirector locks
	catchCooldownSeconds: number, -- after a catch the Creature retreats this long
	maxChaseSeconds: number, -- a chase that runs this long breaks off into a reposition
	postAirlockGraceSeconds: number,
	creditMultiplier: number,
}

local DifficultyConfig = table.freeze({
	Standard = table.freeze({
		creatureSpeedMultiplier = 1,
		hearingMultiplier = 1,
		sightRangeMultiplier = 1,
		trapCount = 10,
		batteriesPerLevel = 3,
		flasksScienceHall = 6,
		flasksPool = 2,
		lockedGrateFraction = 0.25,
		catchCooldownSeconds = 18,
		maxChaseSeconds = 40,
		postAirlockGraceSeconds = 12,
		creditMultiplier = 1,
	} :: DifficultySpec),
	Nightmare = table.freeze({
		creatureSpeedMultiplier = 1.2,
		hearingMultiplier = 1.25,
		sightRangeMultiplier = 1.15,
		trapCount = 16,
		batteriesPerLevel = 1,
		flasksScienceHall = 4,
		flasksPool = 1,
		lockedGrateFraction = 0.45,
		catchCooldownSeconds = 11,
		maxChaseSeconds = 65,
		postAirlockGraceSeconds = 6,
		creditMultiplier = 1.5,
	} :: DifficultySpec),
})

return DifficultyConfig
