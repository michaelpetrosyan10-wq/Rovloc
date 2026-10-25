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

type Pair = { GroupName }

local Default: GroupName = "Default"
local Players: GroupName = "Players" -- player character parts in Normal mode
local Monster: GroupName = "Monster" -- Creature root (on floors) + CreatureHitbox
local CorpseProps: GroupName = "CorpseProps" -- dynamic ragdolls and loose debris
local Projectiles: GroupName = "Projectiles" -- query group for server flask raycasts
local MonsterPassthrough: GroupName = "MonsterPassthrough" -- trims, lockers, desks, debris piles
local VentCollider: GroupName = "VentCollider" -- the 2.6-stud ball that carries a vent crawler
local NoCollide: GroupName = "NoCollide" -- collides with nothing; never physically queried

-- Registration order. "Default" always exists and is never registered.
local custom: { GroupName } =
	{ Players, Monster, CorpseProps, Projectiles, MonsterPassthrough, VentCollider, NoCollide }
local all: { GroupName } =
	{ Default, Players, Monster, CorpseProps, Projectiles, MonsterPassthrough, VentCollider, NoCollide }

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
}

local pairSet: { [string]: boolean } = {}
for _, pair in collidingPairs do
	pairSet[pair[1] .. "|" .. pair[2]] = true
	pairSet[pair[2] .. "|" .. pair[1]] = true
end

local function collides(a: GroupName, b: GroupName): boolean
	return pairSet[a .. "|" .. b] == true
end

return table.freeze({
	Default = Default,
	Players = Players,
	Monster = Monster,
	CorpseProps = CorpseProps,
	Projectiles = Projectiles,
	MonsterPassthrough = MonsterPassthrough,
	VentCollider = VentCollider,
	NoCollide = NoCollide,
	Custom = table.freeze(custom),
	All = table.freeze(all),
	CollidingPairs = table.freeze(collidingPairs),
	collides = collides,
})
