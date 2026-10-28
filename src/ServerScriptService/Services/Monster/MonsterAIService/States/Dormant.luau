--!strict
-- Dormant: the Creature waits, still, where it was placed: at its level's CreatureSpawn before the squad reaches that
-- level, after an airlock relocation (hidden until nobody can see it appear), or held by a dev command. Its root is
-- anchored (no drifting, and the Level 4 spawn is under water); nothing is hunted. MonsterAIService wakes it (Patrol)
-- a short delay after its level activates; a cutscene that acquired it first takes it from there instead.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

local Brain = require(script.Parent.Parent.Brain)

type Context = Brain.Context

local NAME: Enums.MonsterState = "Dormant"

local Dormant = {}

Dormant.Name = NAME

function Dormant.enter(ctx: Context, _from: Enums.MonsterState)
	ctx.setTarget(nil)
	ctx.mover:Stop()
	ctx.mover:SetSpeed(0)
	ctx.body:SetWalkSpeed(0)
	ctx.body:Face(nil)
	local medium = ctx.mover:Medium()
	if medium ~= "Vent" then
		ctx.body:SetAnchored(true)
		ctx.body:SetPose(if medium == "Water" then "Swim" else "Biped")
	end
end

function Dormant.update(_ctx: Context, _dt: number) end

function Dormant.exit(_ctx: Context, _to: Enums.MonsterState) end

return table.freeze(Dormant)
