--!strict
-- Scripted: a cutscene holds the Creature (MonsterAIService.AcquireScripted). The brain is paused: no senses, no
-- decisions, no catches; the ScriptedHandle moves, teleports, poses, hides and turns it until Release(nextState).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

local Brain = require(script.Parent.Parent.Brain)

type Context = Brain.Context

local NAME: Enums.MonsterState = "Scripted"

local Scripted = {}

Scripted.Name = NAME

function Scripted.enter(ctx: Context, _from: Enums.MonsterState)
	ctx.setTarget(nil)
	ctx.mover:Stop()
	ctx.mover:SetSpeed(ctx.speedOf(NAME))
	ctx.body:SetWalkSpeed(ctx.speedOf(NAME))
end

function Scripted.update(_ctx: Context, _dt: number) end

function Scripted.exit(ctx: Context, _to: Enums.MonsterState)
	ctx.body:Face(nil)
end

return table.freeze(Scripted)
