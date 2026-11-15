--!strict
-- DreadBuilder: the scary-surroundings pass on the stages DreadConfig.Levels names (static kind "Dread": once at boot,
-- the same on every server, into <level>.Props as one Model "Dread_<layoutId>"), as densely as each stage asks. What
-- it builds is DreadKit's; a stage that is not listed there (the Auditorium and the roof being rebuilt, the city) calls
-- DreadKit.plan and DreadKit.build from its own package.

local DreadKit = require(script.Parent.DreadKit)
local PropKit = require(script.Parent.PropKit)

local DreadBuilder = {}

local function buildDread(ctx: PropKit.StaticContext): number
	local options = DreadKit.levelOptions(ctx.layout.id)
	if not options then
		return 0
	end
	return DreadKit.build(ctx.parent, ctx.layout, DreadKit.plan(ctx.layout, options))
end

function DreadBuilder.register(registrar: PropKit.Registrar)
	registrar.static("Dread", buildDread)
end

return table.freeze(DreadBuilder)
