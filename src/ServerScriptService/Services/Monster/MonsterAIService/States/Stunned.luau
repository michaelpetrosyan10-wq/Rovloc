--!strict
-- Stunned: blinded by a chemical cloud (MonsterAIService.Stun, GameConfig.StunSeconds). The Creature claws at its
-- face and stumbles back away from the cloud at Stunned speed: on floors a short stagger straight back (veering off a
-- wall behind it, flailing in place when boxed in), in the water a backward glide, in the ducts a backward crawl along
-- VentPathfinder.retreatPath (never toward the cloud, facing it). No catches, no noises heard, nobody targeted.
-- When the stun ends the brain sends it off to withdraw (Patrol, out of sight).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)

local Brain = require(script.Parent.Parent.Brain)

type Context = Brain.Context

local NAME: Enums.MonsterState = "Stunned"
local RETREAT_HOPS = 3 -- duct edges a vent retreat may cover
local FLAIL_SECONDS = 0.5

local Stunned = {}

Stunned.Name = NAME
Stunned.RetreatHops = RETREAT_HOPS

-- Starts (or restarts, for a second cloud) the stumbling retreat away from the stun's source.
function Stunned.retreat(ctx: Context)
	local position = ctx.body:GetPosition()
	local from = ctx.stunFrom or (position + ctx.body:GetCFrame().LookVector)
	ctx.mover:SetSpeed(ctx.speedOf(NAME))
	ctx.body:SetWalkSpeed(ctx.speedOf(NAME))
	ctx.mover:Retreat(from, RETREAT_HOPS)
end

function Stunned.enter(ctx: Context, _from: Enums.MonsterState)
	ctx.setTarget(nil)
	ctx.mover:Stop()
	Stunned.retreat(ctx)
end

function Stunned.update(ctx: Context, _dt: number)
	local mover = ctx.mover
	if mover:Busy() or mover:Status() == "Moving" then
		return
	end
	mover:Hold(FLAIL_SECONDS, nil)
end

function Stunned.exit(_ctx: Context, _to: Enums.MonsterState) end

return table.freeze(Stunned)
