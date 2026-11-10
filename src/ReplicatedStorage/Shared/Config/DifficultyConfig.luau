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
	maxChaseSeconds: number, -- a chase gives up (FadeOut) after this, whatever happens
	chaseLostSeconds: number, -- line of sight lost this long: it searches the last seen point
	teleportCooldown: { number }, -- seconds between teleports: {low, high}
	reachInSeconds: number, -- it reaches into a hiding spot it saw someone climb into this long after
	postAirlockGraceSeconds: number,
	creditMultiplier: number,
}

local DifficultyConfig = table.freeze({
	Standard = table.freeze({
		creatureSpeedMultiplier = 1,
		hearingMultiplier = 1, -- the Tall Man's radii (NoiseConfig) are the Standard reach
		sightRangeMultiplier = 1,
		trapCount = 10,
		batteriesPerLevel = 2, -- harder Standard: one fewer per floor
		flasksScienceHall = 6,
		flasksPool = 2,
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
		flasksScienceHall = 4,
		flasksPool = 1,
		lockedGrateFraction = 0.45,
		catchCooldownSeconds = 8.8, -- 11 s, -20 % with Standard
		maxChaseSeconds = 28,
		chaseLostSeconds = 5,
		teleportCooldown = table.freeze({ 40, 80 }),
		reachInSeconds = 24,
		postAirlockGraceSeconds = 6,
		creditMultiplier = 1.5,
	} :: DifficultySpec),
})

return DifficultyConfig
