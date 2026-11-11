--!strict
-- Collision group names and the full collision matrix as data. CollisionService applies it; specs assert it.
-- The matrix is symmetric: list each colliding pair once. Every pair not listed does not collide.

export type GroupName =
	"Default"
	| "Players"
	| "Monster"
	| "CorpseProps"
	| "Projectiles"
	| "MonsterPassthrough"
	| "VentCollider"
	| "NoCollide"
	| "CreatureBlock"
	| "Traversing"

type Pair = { GroupName }

local Default: GroupName = "Default"
local Players: GroupName = "Players" -- player character parts in Normal mode
local Monster: GroupName = "Monster" -- Creature root (on floors) + CreatureHitbox
local CorpseProps: GroupName = "CorpseProps" -- dynamic ragdolls and loose debris
local Projectiles: GroupName = "Projectiles" -- query group for server flask raycasts
local MonsterPassthrough: GroupName = "MonsterPassthrough" -- trims, lockers, desks, debris piles
local VentCollider: GroupName = "VentCollider" -- the 2.6-stud ball that carries a vent crawler
local NoCollide: GroupName = "NoCollide" -- collides with nothing; never physically queried
-- an invisible wall across every opening from a walkable room into a Gap (an alley): it stops the Creature only, so
-- players leap, cross a plank or drop through it (the web clamps the Creature to the same rects: meta.creatureBlocks)
local CreatureBlock: GroupName = "CreatureBlock"
-- a character on the leap curve (ParkourRules.leap, sampled by the client): it collides with nothing until it lands
local Traversing: GroupName = "Traversing"

-- Registration order. "Default" always exists and is never registered.
local custom: { GroupName } = {
	Players,
	Monster,
	CorpseProps,
	Projectiles,
	MonsterPassthrough,
	VentCollider,
	NoCollide,
	CreatureBlock,
	Traversing,
}
local all: { GroupName } = {
	Default,
	Players,
	Monster,
	CorpseProps,
	Projectiles,
	MonsterPassthrough,
	VentCollider,
	NoCollide,
	CreatureBlock,
	Traversing,
}

local collidingPairs: { Pair } = {
	{ Default, Default },
	{ Default, Players },
	{ Default, Monster },
	{ Default, CorpseProps },
	{ Default, Projectiles },
	{ Default, MonsterPassthrough },
	{ Default, VentCollider },
	{ Players, MonsterPassthrough },
	{ Monster, Projectiles },
	{ CorpseProps, MonsterPassthrough },
	{ Projectiles, MonsterPassthrough },
	{ MonsterPassthrough, MonsterPassthrough },
	{ Monster, CreatureBlock },
}

local pairSet: { [string]: boolean } = {}
for _, pair in collidingPairs do
	pairSet[pair[1] .. "|" .. pair[2]] = true
	pairSet[pair[2] .. "|" .. pair[1]] = true
end

local function collides(a: GroupName, b: GroupName): boolean
	return pairSet[a .. "|" .. b] == true
end

export type CollisionGroupsModule = {
	Default: GroupName,
	Players: GroupName,
	Monster: GroupName,
	CorpseProps: GroupName,
	Projectiles: GroupName,
	MonsterPassthrough: GroupName,
	VentCollider: GroupName,
	NoCollide: GroupName,
	CreatureBlock: GroupName,
	Traversing: GroupName,
	Custom: { GroupName },
	All: { GroupName },
	CollidingPairs: { Pair },
	collides: (a: GroupName, b: GroupName) -> boolean,
}

local CollisionGroups: CollisionGroupsModule = {
	Default = Default,
	Players = Players,
	Monster = Monster,
	CorpseProps = CorpseProps,
	Projectiles = Projectiles,
	MonsterPassthrough = MonsterPassthrough,
	VentCollider = VentCollider,
	NoCollide = NoCollide,
	CreatureBlock = CreatureBlock,
	Traversing = Traversing,
	Custom = custom,
	All = all,
	CollidingPairs = collidingPairs,
	collides = collides,
}

table.freeze(custom)
table.freeze(all)
table.freeze(collidingPairs)

return table.freeze(CollisionGroups)
