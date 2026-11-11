--!strict
-- Every level blueprint validates (LayoutSchema.validate) and carries the content its level needs (USER_SPEC
-- "LEVELS"), plus the cross-cutting rules the builders rely on: unique ids, dark lighting, patrol loops that hop
-- through doorways, openings that never collide on a wall, and ducts that clear the level below them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ObjectivePlaces = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ObjectivePlaces)
local RunDirector = require(ReplicatedStorage.Shared.World.RunDirector)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor
type Room = LayoutSchema.Room
type Door = LayoutSchema.Door
type Light = LayoutSchema.Light
type Opening = { from: number, to: number, bottom: number, top: number, what: string }

local LAYOUTS: { [string]: Layout } = {
	Lobby = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Lobby),
	Level0_Basement = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Level0_Basement),
	Level1_Hallways = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Level1_Hallways),
	Level2_Auditorium = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Level2_Auditorium),
	Level3_Roof = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Level3_Roof),
}

-- Palette keys the layouts may use (docs: PHASE1 brief, "Palette keys used by layouts").
local PALETTE_KEYS: { string } = {
	"Concrete",
	"ConcreteDark",
	"ConcreteStained",
	"TileWhite",
	"TileGreen",
	"TileBlue",
	"Linoleum",
	"WoodPanel",
	"PlasterSchool",
	"PlasterAsh",
	"BlockGray",
	"MetalRust",
	"MetalGalvanized",
	"RoofGravel",
	"Asphalt",
	"Carpet",
}

local AMBIENCE: { [string]: string } = {
	Lobby = "DroneLobby",
	Level0_Basement = "DroneBasement",
	Level1_Hallways = "DroneHallways",
	Level2_Auditorium = "DroneHallways",
	Level3_Roof = "DroneRoof",
}

local EPS = 1e-3
local HALF_BORE = WorldConfig.VentBore / 2
local HALF_OUTER = HALF_BORE + WorldConfig.VentShell
-- Standing eye height over the floor: a normalized R15 root centre (HipHeight 2 + half the 2-stud root) plus the
-- standing eye offset the server uses for line of sight.
local STANDING_EYE = 3 + CameraConfig.EyeHeightAboveRoot.Standing
local SCHOOL_ORDER: { string } = { "Level0_Basement", "Level1_Hallways", "Level2_Auditorium", "Level3_Roof" }

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function anchorsOf(layout: Layout, kind: Enums.AnchorKind): { Anchor }
	local out: { Anchor } = {}
	for _, a in layout.anchors do
		if a.kind == kind then
			table.insert(out, a)
		end
	end
	return out
end

local function roomOf(layout: Layout, id: string): Room?
	for _, r in layout.rooms do
		if r.id == id then
			return r
		end
	end
	return nil
end

local function lightsOf(layout: Layout): { Light }
	local out: { Light } = {}
	for _, r in layout.rooms do
		for _, l in (r.lights or {}) :: { Light } do
			table.insert(out, l)
		end
	end
	return out
end

local function doorsWhere(layout: Layout, predicate: (Door) -> boolean): { Door }
	local out: { Door } = {}
	for _, d in layout.doors do
		if predicate(d) then
			table.insert(out, d)
		end
	end
	return out
end

local function triggersOf(layout: Layout, kind: Enums.TriggerKind): { LayoutSchema.Trigger }
	local out: { LayoutSchema.Trigger } = {}
	for _, tr in layout.triggers do
		if tr.kind == kind then
			table.insert(out, tr)
		end
	end
	return out
end

local function schoolLevels(): { string }
	local out: { string } = {}
	for _, id: Enums.LevelId in WorldConfig.LevelOrder do
		table.insert(out, id)
	end
	return out
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
end

-- Breadth-first reachability over rooms, doors and (optionally) vents. `shut` blocks door kinds; `lockedAll`
-- treats every lockable grate as locked; `noVents` ignores ducts entirely.
type ReachOptions = { shut: { [string]: boolean }?, lockedAll: boolean?, noVents: boolean? }
local function reachable(layout: Layout, from: string, options: ReachOptions): { [string]: boolean }
	local adjacency: { [string]: { string } } = {}
	local function link(a: string, b: string)
		adjacency[a] = adjacency[a] or {}
		adjacency[b] = adjacency[b] or {}
		table.insert(adjacency[a], b)
		table.insert(adjacency[b], a)
	end
	local shut = options.shut or {}
	for _, d in layout.doors do
		if d.kind ~= "Boarded" and not shut[d.kind] then
			link("room:" .. d.rooms[1], "room:" .. d.rooms[2])
		end
	end
	local vents = layout.vents
	if vents and not options.noVents then
		for _, e in vents.edges do
			link("vent:" .. e.a, "vent:" .. e.b)
		end
		for _, g in vents.grates do
			if not (options.lockedAll and g.lockable) then
				link("room:" .. g.room, "vent:" .. g.node)
			end
		end
	end
	local seen: { [string]: boolean } = { ["room:" .. from] = true }
	local queue: { string } = { "room:" .. from }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, nextId in (adjacency[current] or {}) :: { string } do
			if not seen[nextId] then
				seen[nextId] = true
				table.insert(queue, nextId)
			end
		end
	end
	return seen
end

local function grateCounts(layout: Layout): (number, number, number)
	local total, lockable, critical = 0, 0, 0
	local vents = layout.vents
	if vents then
		for _, g in vents.grates do
			total += 1
			if g.lockable then
				lockable += 1
			end
			if g.criticalPath then
				critical += 1
			end
		end
	end
	return total, lockable, critical
end

local function nodeById(layout: Layout, id: string): LayoutSchema.VentNodeSpec?
	local vents = layout.vents
	if vents then
		for _, n in vents.nodes do
			if n.id == id then
				return n
			end
		end
	end
	return nil
end

-- The chase room a vent node lies in or on (its boundary counts).
local function chaseOf(layout: Layout, node: LayoutSchema.VentNodeSpec): Room?
	for _, r in layout.rooms do
		if r.kind == "Chase" and LayoutSchema.rectContains(r.rect, node.x, node.z) then
			return r
		end
	end
	return nil
end

-- Whether the straight line from `eye` to `target` passes through `door`'s opening at both faces of its wall:
-- inside the door's width and under its lintel (the wall around it is what blocks the view).
local function throughDoor(eye: Vector3, target: Vector3, door: Door, edge: LayoutSchema.SharedEdge): boolean
	local half = LayoutSchema.doorWidth(door) / 2
	local wall = WorldConfig.WallThickness / 2
	local e = if edge.axis == "Z" then eye.Z else eye.X
	local g = if edge.axis == "Z" then target.Z else target.X
	if math.abs(g - e) < EPS then
		return false
	end
	for _, face in { edge.coord - wall, edge.coord + wall } do
		local k = (face - e) / (g - e)
		if k < 0 or k > 1 then
			return false
		end
		local p = eye:Lerp(target, k)
		local u = if edge.axis == "Z" then p.X else p.Z
		if u < door.at - half or u > door.at + half or p.Y > LayoutSchema.doorHeight(door) then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------------

return {
	["every layout passes LayoutSchema.validate"] = function(t: Expect)
		for id, layout in LAYOUTS do
			t.eq(layout.id, id, "layout id matches its module")
			local errors = LayoutSchema.validate(layout)
			t.eq(#errors, 0, id .. ": " .. (errors[1] or ""))
		end
	end,

	["entries and exits follow the stairwell chain"] = function(t: Expect)
		for _, spec in WorldConfig.Stairwells do
			if spec.slot == "Middle" then
				t.eq(LAYOUTS[spec.from].exit, spec.fromRoom, spec.id .. " leaves from the lower level's exit")
				t.eq(LAYOUTS[spec.to].entry, spec.toRoom, spec.id .. " arrives in the upper level's entry")
			end
			local lower, upper = roomOf(LAYOUTS[spec.from], spec.fromRoom), roomOf(LAYOUTS[spec.to], spec.toRoom)
			t.truthy(lower and lower.kind == "Airlock", spec.id .. " leaves from an airlock vestibule")
			t.truthy(upper and (upper.kind == "Airlock" or upper.kind == "Stairwell"), spec.id .. " arrives in one")
		end
		t.eq(table.concat(SCHOOL_ORDER, ","), table.concat(WorldConfig.LevelOrder, ","), "the school's four levels")
		for pair = 1, #SCHOOL_ORDER - 1 do
			local slots = {}
			for _, spec in WorldConfig.Stairwells do
				if spec.pair == pair then
					table.insert(slots, spec.slot)
				end
			end
			t.eq(#slots, 3, "floor pair " .. pair .. " has three candidate stairwells")
		end
		local basementEntry = roomOf(LAYOUTS.Level0_Basement, LAYOUTS.Level0_Basement.entry)
		t.truthy(
			basementEntry and basementEntry.rect.x + basementEntry.rect.w <= WorldConfig.FootprintSize.X / 4,
			"the basement arrival bay is on the west side (its first quarter)"
		)
		local roofExit = roomOf(LAYOUTS.Level3_Roof, LAYOUTS.Level3_Roof.exit)
		t.truthy(roofExit and roofExit.rect.x == 0, "the roof exit is the west edge")
		for id, layout in LAYOUTS do
			t.eq(layout.ambience, AMBIENCE[id], id .. " ambience bed")
			if id ~= "Lobby" and id ~= "Level3_Roof" then
				t.near(layout.height, WorldConfig.Levels[id].height, EPS, id .. " height matches WorldConfig")
			end
		end
	end,

	["ids are unique across every layout"] = function(t: Expect)
		local seen: { [string]: string } = {}
		local function claim(id: string, where: string)
			t.falsy(seen[id], string.format("%s used by %s and %s", id, seen[id] or "", where))
			seen[id] = where
		end
		for layoutId, layout in LAYOUTS do
			for _, r in layout.rooms do
				claim(r.id, layoutId)
				for _, l in (r.lights or {}) :: { Light } do
					claim(l.id, layoutId)
				end
			end
			for _, d in layout.doors do
				claim(d.id, layoutId)
			end
			for _, a in layout.anchors do
				claim(a.id, layoutId)
			end
			for _, tr in layout.triggers do
				claim(tr.id, layoutId)
			end
			for _, p in (layout.platforms or {}) :: { LayoutSchema.Platform } do
				claim(p.id, layoutId)
			end
			local vents = layout.vents
			if vents then
				for _, n in vents.nodes do
					claim(n.id, layoutId)
				end
				for _, g in vents.grates do
					claim(g.id, layoutId)
				end
			end
		end
	end,

	["every entry room holds four player spawns"] = function(t: Expect)
		for id, layout in LAYOUTS do
			-- the layout's entry and every entry vestibule candidate (the stairwells arriving on it)
			local entries: { [string]: { Anchor } } = { [layout.entry] = {} }
			for _, spec in WorldConfig.Stairwells do
				if spec.to == id then
					entries[spec.toRoom] = {}
				end
			end
			for _, a in anchorsOf(layout, "PlayerSpawn") do
				local list = entries[a.room]
				t.truthy(list ~= nil, id .. " spawn " .. a.id .. " is in an entry room")
				if list then
					table.insert(list, a)
				end
			end
			for room, spawns in entries do
				t.eq(#spawns, 4, room .. " has four PlayerSpawn anchors")
				for i = 1, #spawns do
					for j = i + 1, #spawns do
						t.truthy(
							flatDistance(spawns[i].pos, spawns[j].pos) >= WorldConfig.SpawnSpacing - EPS,
							room .. " spawns keep SpawnSpacing"
						)
					end
				end
			end
		end
	end,

	["the creature has a spawn on every level from the hallways up"] = function(t: Expect)
		for _, id in schoolLevels() do
			local count = #anchorsOf(LAYOUTS[id], "CreatureSpawn")
			if LAYOUTS[id].tunnels then
				-- a tunnel floor: the Creature hunts the tunnels, several starts for the spawn rule to choose from
				t.truthy(count >= 4, id .. ": the tunnels hold several Creature starts")
			elseif id == "Level3_Roof" then
				-- one behind each stair housing's roof door (the run arrives in one of them)
				t.eq(count, 3, id .. " CreatureSpawn per stair housing")
				for _, a in anchorsOf(LAYOUTS[id], "CreatureSpawn") do
					t.eq(string.sub(a.room, 1, 13), "L3_RoofAccess", a.id .. " waits in a housing")
				end
			else
				t.eq(count, 1, id .. " CreatureSpawn")
			end
		end
		t.eq(#anchorsOf(LAYOUTS.Lobby, "CreatureSpawn"), 0, "the lobby is a safe zone")
	end,

	["rooms carry palette keys, surfaces and acoustics"] = function(t: Expect)
		for id, layout in LAYOUTS do
			t.truthy(Enums.has(Enums.AcousticPreset, layout.acoustic), id .. " acoustic")
			for _, r in layout.rooms do
				if r.kind == "Solid" then
					-- the ground between tunnels: only its walls show (in the tunnels' keys)
					t.truthy(r.wall and table.find(PALETTE_KEYS, r.wall), r.id .. " wall key")
					continue
				end
				for _, key in { r.floor, r.wall, r.ceiling } :: { string? } do
					t.truthy(
						key and table.find(PALETTE_KEYS, key),
						id .. "/" .. r.id .. " palette key " .. tostring(key)
					)
				end
				t.truthy(r.surface and Enums.has(Enums.SurfaceKind, r.surface), r.id .. " surface")
				t.truthy(r.acoustic and Enums.has(Enums.AcousticPreset, r.acoustic), r.id .. " acoustic")
			end
		end
	end,

	["levels stay dark: few lit fixtures, all dim, a flicker group each"] = function(t: Expect)
		for id, layout in LAYOUTS do
			local lights = lightsOf(layout)
			-- the stair vestibules' dim emergency lamps burn whatever route a run takes; they never count as lit
			local vestibule: { [string]: boolean } = {}
			for _, r in layout.rooms do
				if r.kind == "Airlock" or r.kind == "Stairwell" then
					for _, l in (r.lights or {}) :: { LayoutSchema.Light } do
						vestibule[l.id] = true
					end
				end
			end
			local lit = 0
			local groups: { [string]: boolean } = {}
			for _, l in lights do
				t.truthy(l.range <= 60, l.id .. " range <= 60")
				t.truthy(l.brightness > 0, l.id .. " brightness")
				if not l.broken and not vestibule[l.id] then
					lit += 1
					if id ~= "Lobby" then
						t.truthy(l.brightness <= 1.2, l.id .. " is dim")
					end
				end
				if l.flickerGroup then
					groups[l.flickerGroup] = true
				end
			end
			t.truthy(next(groups) ~= nil, id .. " has a flicker group")
			if layout.tunnels then
				-- a tunnel floor's caged bulbs: about a third dead, the rest on a group the power switch holds down
				-- (the floor starts dark but for its emergency reds)
				t.truthy(lit <= 0.75 * #lights, string.format("%s: %d of %d fixtures lit", id, lit, #lights))
				for _, l in lights do
					if not l.broken and (l.kind == "Bulb" or l.kind == "Fluorescent") then
						t.truthy(l.flickerGroup ~= nil, l.id .. " is on a group the power switch holds")
					end
				end
			elseif id ~= "Lobby" then
				t.truthy(
					lit <= math.max(2, 0.2 * #lights),
					string.format("%s: %d of %d fixtures lit", id, lit, #lights)
				)
			end
		end
	end,

	["patrol loops hop through doorways and cover every level"] = function(t: Expect)
		for id, layout in LAYOUTS do
			local rooms = LayoutSchema.indexRooms(layout)
			local joined: { [string]: boolean } = {}
			for _, d in layout.doors do
				if d.kind ~= "Boarded" then
					joined[d.rooms[1] .. "|" .. d.rooms[2]] = true
					joined[d.rooms[2] .. "|" .. d.rooms[1]] = true
				end
			end
			local loops: { [string]: { [number]: Anchor } } = {}
			local total = 0
			for _, a in anchorsOf(layout, "PatrolWaypoint") do
				total += 1
				local r = rooms[a.room]
				t.truthy(r and r.kind ~= "Chase", a.id .. " stands in a walkable room")
				local loop, index = string.match(a.id, "_WP_(.-)_(%d+)$")
				t.truthy(loop and index, a.id .. " is named <prefix>_WP_<loop>_<nn>")
				if loop and index then
					loops[loop] = loops[loop] or {}
					loops[loop][tonumber(index) :: number] = a
				end
			end
			for loop, points in loops do
				local n = #points
				t.truthy(n >= 3, id .. " loop " .. loop .. " has at least three waypoints")
				for i = 1, n do
					local a, b = points[i], points[(i % n) + 1]
					if layout.tunnels then
						-- tunnel floors: junction to junction along the tunnels, a short walk apart
						local walk = ObjectivePlaces.walkDistance(layout, a.room, a.pos, b.room, b.pos)
						t.truthy(
							walk <= 140,
							string.format("%s loop %s: %s -> %s walks %.0f studs", id, loop, a.id, b.id, walk)
						)
					else
						t.truthy(
							a.room == b.room or joined[a.room .. "|" .. b.room],
							string.format("%s loop %s: %s -> %s crosses no doorway", id, loop, a.id, b.id)
						)
					end
				end
			end
			if id ~= "Lobby" and id ~= "Level0_Basement" then
				t.truthy(total >= 20, id .. " has patrol coverage")
			end
		end
	end,

	["anchors stay inside their room's volume"] = function(t: Expect)
		for id, layout in LAYOUTS do
			local rooms = LayoutSchema.indexRooms(layout)
			for _, a in layout.anchors do
				local r = rooms[a.room]
				if r then
					t.truthy(a.pos.Y <= LayoutSchema.roomHeight(layout, r), id .. " " .. a.id .. " under the ceiling")
					t.truthy(a.pos.Y >= 0, id .. " " .. a.id .. " above the floor")
				end
			end
		end
	end,

	["doors, grates and windows never collide on a wall"] = function(t: Expect)
		for id, layout in LAYOUTS do
			local rooms = LayoutSchema.indexRooms(layout)
			local walls: { [string]: { Opening } } = {}
			local function add(axis: string, coord: number, opening: Opening)
				local key = string.format("%s:%.2f", axis, coord)
				walls[key] = walls[key] or {}
				table.insert(walls[key], opening)
			end
			for _, d in layout.doors do
				local edge = LayoutSchema.sharedEdge(rooms[d.rooms[1]].rect, rooms[d.rooms[2]].rect)
				if edge then
					local half = LayoutSchema.doorWidth(d) / 2
					add(edge.axis, edge.coord, {
						from = d.at - half,
						to = d.at + half,
						bottom = 0,
						top = LayoutSchema.doorHeight(d),
						what = d.id,
					})
				end
			end
			local vents = layout.vents
			if vents then
				for _, g in vents.grates do
					local node = nodeById(layout, g.node)
					local r = rooms[g.room]
					if node and r then
						local side = LayoutSchema.sideOfPoint(r.rect, node.x, node.z)
						local half = WorldConfig.VentBore / 2
						local y = LayoutSchema.ventNodeY(node)
						local alongZ = side == "W" or side == "E"
						local along = if alongZ then node.z else node.x
						add(if alongZ then "X" else "Z", if alongZ then node.x else node.z, {
							from = along - half,
							to = along + half,
							bottom = y - half,
							top = y + half,
							what = g.id,
						})
					end
				end
			end
			for _, w in (layout.windows or {}) :: { LayoutSchema.Window } do
				local rect = rooms[w.room].rect
				local alongX = w.side == "N" or w.side == "S"
				local coord = if w.side == "N"
					then rect.z
					elseif w.side == "S" then rect.z + rect.d
					elseif w.side == "W" then rect.x
					else rect.x + rect.w
				add(if alongX then "Z" else "X", coord, {
					from = w.at - w.width / 2,
					to = w.at + w.width / 2,
					bottom = w.sill,
					top = w.sill + w.height,
					what = "window of " .. w.room,
				})
			end
			for key, list in walls do
				for i = 1, #list do
					for j = i + 1, #list do
						local a, b = list[i], list[j]
						local overlapAlong = math.min(a.to, b.to) - math.max(a.from, b.from)
						local overlapUp = math.min(a.top, b.top) - math.max(a.bottom, b.bottom)
						t.truthy(
							overlapAlong <= -0.5 or overlapUp <= 0,
							string.format("%s wall %s: %s collides with %s", id, key, a.what, b.what)
						)
					end
				end
			end
		end
	end,

	["windows sit on the facade, clear of the stair towers"] = function(t: Expect)
		for _, id in schoolLevels() do
			local layout = LAYOUTS[id]
			local rooms = LayoutSchema.indexRooms(layout)
			if layout.legacy then
				continue -- still the old plan: its facade and the old towers' places are not this footprint's
			end
			for _, w in (layout.windows or {}) :: { LayoutSchema.Window } do
				local r = rooms[w.room]
				local rect = r.rect
				local onFacade = (w.side == "N" and rect.z == 0)
					or (w.side == "S" and rect.z + rect.d == WorldConfig.FootprintSize.Y)
					or (w.side == "W" and rect.x == 0)
					or (w.side == "E" and rect.x + rect.w == WorldConfig.FootprintSize.X)
				t.truthy(onFacade, id .. " window of " .. w.room .. " is on an exterior wall")
				if w.side == "W" or w.side == "E" then
					local tower = WorldConfig.Towers.West
					t.truthy(
						w.at + w.width / 2 <= tower.minZ or w.at - w.width / 2 >= tower.maxZ,
						id .. " window of " .. w.room .. " clears the stair tower"
					)
				end
				t.truthy(
					w.sill + w.height <= (r.wallHeight or LayoutSchema.roomHeight(layout, r)) + EPS,
					id .. " window of " .. w.room .. " fits under the wall top"
				)
			end
		end
	end,

	["basement: tunnels, trap spots, batteries, debris, checkpoints and the hunt"] = function(t: Expect)
		local layout = LAYOUTS.Level0_Basement
		local rooms = LayoutSchema.indexRooms(layout)
		t.truthy(layout.tunnels ~= nil, "the basement is a tunnel floor (TunnelPlanner)")
		-- bear traps: Nightmare's sixteen fit, never on the only way, never two within 6 studs (RunDirector's spacing)
		local traps = anchorsOf(layout, "TrapCandidate")
		local excluded = RunDirector.trapExcludedRooms(layout)
		local open = 0
		for _, a in traps do
			if not excluded[a.room] then
				open += 1
			end
			t.truthy(a.room ~= layout.entry and rooms[a.room].kind ~= "Airlock", a.id .. " outside spawn/airlock")
		end
		t.truthy(open >= 16, "at least 16 trap spots a run may arm (Nightmare's trapCount)")
		local spaced = 0
		for i, a in traps do
			local clear = true
			for j, b in traps do
				if i ~= j and flatDistance(a.pos, b.pos) < 6 then
					clear = false
				end
			end
			if clear then
				spaced += 1
			end
		end
		t.truthy(spaced >= 16, "at least 16 trap spots stand 6 studs from every other")
		t.truthy(#anchorsOf(layout, "BatteryCandidate") >= 6, "battery candidates")
		t.truthy(#triggersOf(layout, "FloorDebris") >= 3, "floor debris in the tunnels")
		t.truthy(#triggersOf(layout, "ScareStep") >= 2, "scare steps in the tunnels")
		local checkpoints = triggersOf(layout, "Checkpoint")
		t.eq(#checkpoints, 3, "one checkpoint per exit vestibule candidate")
		for _, spec in WorldConfig.stairwellCandidates(layout.id) do
			local here = 0
			for _, trigger in checkpoints do
				if trigger.room == spec.fromRoom then
					here += 1
				end
			end
			t.eq(here, 1, "a checkpoint in " .. spec.fromRoom)
		end
		t.falsy(layout.vents, "no vents in the basement (crawlways instead)")
		t.truthy(#anchorsOf(layout, "PatrolWaypoint") >= 12, "patrol waypoints at the junctions")
		t.truthy(#anchorsOf(layout, "Barrel") + #anchorsOf(layout, "Cabinet") >= 20, "barrels and cabinets to hide in")
		t.truthy(#anchorsOf(layout, "Corpse") >= 1 and #anchorsOf(layout, "Clutter") >= 8, "corpses and clutter")
		t.truthy(#anchorsOf(layout, "DripPipe") >= 3, "leaking pipes")
		-- the spawn rule (CreatureBand studs walked from the entry, outside every objective room) has options
		local band = RunDirector.CreatureBand
		local entry = ObjectivePlaces.entryPoint(layout)
		local objectiveRooms: { [string]: boolean } = {}
		for _, place in ObjectivePlaces.places(layout) do
			objectiveRooms[place.room] = true
		end
		local starts = 0
		for _, a in anchorsOf(layout, "CreatureSpawn") do
			local walk = ObjectivePlaces.walkDistance(layout, layout.entry, entry, a.room, a.pos)
			if walk >= band[1] and walk <= band[2] and not objectiveRooms[a.room] then
				starts += 1
			end
		end
		t.truthy(
			starts >= 4,
			string.format("%d Creature starts %d..%d studs walked from the entry", starts, band[1], band[2])
		)
	end,

	["hallways: the scripted classroom, glass step, gate and gate-bypass vent"] = function(t: Expect)
		local layout = LAYOUTS.Level1_Hallways
		local rooms = LayoutSchema.indexRooms(layout)
		local ajar = doorsWhere(layout, function(d: Door): boolean
			return d.kind == "Ajar" and d.scriptedId == "ClassroomDoor"
		end)
		t.eq(#ajar, 1, "one ajar ClassroomDoor")
		local classroomDoor = ajar[1]
		local classroom: Room? = nil
		local corridor: Room? = nil
		for _, roomId in classroomDoor.rooms do
			local r = rooms[roomId]
			if r.kind == "Classroom" then
				classroom = r
			elseif r.kind == "Corridor" then
				corridor = r
			end
		end
		t.truthy(classroom and corridor, "the ajar door joins a classroom and a corridor")
		if not (classroom and corridor) then
			return
		end
		-- the pale glow: only this classroom on the level glows, and one glow fixture sits just inside the ajar door
		-- so its (shadowed, downward) cone leaves the room under the door lintel and lights the corridor floor
		local doorEdge = LayoutSchema.sharedEdge(classroom.rect, corridor.rect)
		t.truthy(doorEdge, "the ajar door's wall")
		if not doorEdge then
			return
		end
		local glow, spill = 0, 0
		for _, r in layout.rooms do
			for _, l in (r.lights or {}) :: { Light } do
				if l.kind == "ClassroomGlow" and not l.broken then
					t.eq(r.id, classroom.id, l.id .. ": only the scripted classroom glows")
					glow += 1
					local along = if doorEdge.axis == "Z" then l.pos.X else l.pos.Z
					local inside = math.abs((if doorEdge.axis == "Z" then l.pos.Z else l.pos.X) - doorEdge.coord)
					if
						math.abs(along - classroomDoor.at) <= LayoutSchema.doorWidth(classroomDoor) / 2
						and inside <= 4
					then
						spill += 1
					end
				end
			end
		end
		t.truthy(glow >= 1, "the classroom glows")
		t.truthy(spill >= 1, "a glow fixture just inside the ajar door spills into the corridor")
		local poses = anchorsOf(layout, "CreatureScarePose")
		t.eq(#poses, 1, "one scare pose")
		t.eq(poses[1].room, classroom.id, "the Creature crouches in the glowing classroom")
		local glass = triggersOf(layout, "ScareStep")
		t.eq(#glass, 1, "one ScareStep")
		t.eq(glass[1].room, corridor.id, "the glass lies in the corridor")
		local glassRect = glass[1].rect
		local spansDoor = if doorEdge.axis == "Z"
			then glassRect.x <= classroomDoor.at and glassRect.x + glassRect.w >= classroomDoor.at
			else glassRect.z <= classroomDoor.at and glassRect.z + glassRect.d >= classroomDoor.at
		t.truthy(spansDoor, "the glass spans the classroom doorway")
		-- whoever steps on the glass sees the Creature: from standing eye height over the glass, the line to its
		-- hunched head or its chest runs through the ajar doorway from most of the trigger and from every stretch of
		-- it along the corridor (the snap the P6 controller plays on entry happens in view)
		local pose = poses[1].pos
		local head = pose + Vector3.new(0, CreatureConfig.EyeHeightAboveRoot.Hunched, 0)
		local seen, samples = 0, 0
		local columns: { [number]: boolean } = {}
		for i = 0, math.floor(glassRect.w) - 1 do
			for j = 0, math.floor(glassRect.d) - 1 do
				local eye = Vector3.new(glassRect.x + i + 0.5, STANDING_EYE, glassRect.z + j + 0.5)
				samples += 1
				if
					throughDoor(eye, head, classroomDoor, doorEdge) or throughDoor(eye, pose, classroomDoor, doorEdge)
				then
					seen += 1
					columns[if doorEdge.axis == "Z" then i else j] = true
				end
			end
		end
		t.truthy(
			seen >= 0.6 * samples,
			string.format("the Creature is in sight from %d of %d glass cells", seen, samples)
		)
		for i = 0, math.floor(if doorEdge.axis == "Z" then glassRect.w else glassRect.d) - 1 do
			t.truthy(columns[i], string.format("the Creature is in sight from the glass %d studs along", i))
		end

		local gates = doorsWhere(layout, function(d: Door): boolean
			return d.kind == "Gate"
		end)
		t.eq(#gates, 1, "one gate")
		t.eq(gates[1].scriptedId, "HallwayGate", "the gate is scripted")
		t.truthy(
			rooms[gates[1].rooms[1]].kind == "Corridor" and rooms[gates[1].rooms[2]].kind == "Corridor",
			"the gate spans the corridor"
		)
		-- The gate is what blocks the way: open it and the corridor walks through; shut it and only the vent does.
		t.truthy(reachable(layout, layout.entry, { noVents = true })["room:" .. layout.exit], "gate open: walk through")
		t.falsy(
			reachable(layout, layout.entry, { shut = { Gate = true }, noVents = true })["room:" .. layout.exit],
			"gate shut and no vent: the corridor is sealed"
		)
		t.truthy(
			reachable(layout, layout.entry, { shut = { Gate = true }, lockedAll = true })["room:" .. layout.exit],
			"gate shut: the critical vent still gets through"
		)
		-- The squad reaches the classroom before the gate: the classroom is on the entry side.
		t.truthy(
			reachable(layout, layout.entry, { shut = { Gate = true }, noVents = true })["room:" .. classroom.id],
			"the classroom lies before the gate"
		)
		local total, _, critical = grateCounts(layout)
		t.truthy(total >= 2 and critical >= 2, "the bypass vent has critical grates")
		local vents = layout.vents
		if vents then
			-- the first wall vent (the chase holding the critical grates) never locks, not one of its grates
			local bypass: { [string]: boolean } = {}
			for _, g in vents.grates do
				local node = nodeById(layout, g.node)
				local chase = node and chaseOf(layout, node)
				if g.criticalPath and chase then
					bypass[chase.id] = true
				end
			end
			t.truthy(next(bypass) ~= nil, "the bypass chase")
			for _, g in vents.grates do
				local node = nodeById(layout, g.node)
				local chase = node and chaseOf(layout, node)
				if chase and bypass[chase.id] then
					t.falsy(g.lockable, g.id .. ": the first wall vent never locks")
				end
			end
			local sides: { [string]: boolean } = {}
			for _, g in vents.grates do
				if g.criticalPath then
					sides[g.room] = true
				end
			end
			t.truthy(
				sides[gates[1].rooms[1]] and sides[gates[1].rooms[2]],
				"critical grates open on both sides of the gate"
			)
		end
		t.truthy(#anchorsOf(layout, "Corpse") >= 4, "ragdoll corpses")
		t.truthy(#anchorsOf(layout, "SmashedLocker") >= 8, "smashed lockers")
		t.truthy(#anchorsOf(layout, "DripPipe") >= 4, "dripping pipes")
		t.truthy(#anchorsOf(layout, "BatteryCandidate") >= 6, "battery candidates")
		t.truthy(#triggersOf(layout, "Checkpoint") == 3, "a checkpoint in every exit vestibule candidate")
	end,

	["the hallway and Auditorium floors keep the classic vent only where the script needs it"] = function(t: Expect)
		-- Tunnel floors escape by crawlways (TunnelPlanner); Level 1 keeps one vent, the gate's bypass, because the
		-- scare's gate is scripted around it (both runtimes crawl vents; crawlways are not on Roblox yet)
		local l1 = LAYOUTS.Level1_Hallways
		local rooms1 = LayoutSchema.indexRooms(l1)
		local vents = l1.vents
		t.truthy(vents, "Level 1 keeps the gate's bypass vent")
		if vents then
			local sides: { [string]: boolean } = {}
			for _, g in vents.grates do
				local node = nodeById(l1, g.node)
				local chase = node and chaseOf(l1, node)
				t.truthy(chase and chase.id == "L1_Chase_Gate", g.id .. " opens from the bypass chase")
				t.truthy(g.criticalPath and not g.lockable, g.id .. " is on the critical path and never locks")
				sides[g.room] = true
			end
			t.truthy(sides.L1_Corridor_East and sides.L1_Corridor_West, "a grate on each side of the gate")
		end
		local chases = 0
		for _, r in l1.rooms do
			if r.kind == "Chase" then
				chases += 1
			end
		end
		t.eq(chases, 1, "the bypass is Level 1's only chase")
		-- the scripted classroom's one way in is its ajar door (the Creature leaves it unseen, hidden)
		for _, d in l1.doors do
			if d.rooms[1] == "L1_Classroom_108" or d.rooms[2] == "L1_Classroom_108" then
				t.eq(d.kind, "Ajar", d.id .. " is the scripted classroom's ajar door")
			end
		end
		t.truthy(rooms1.L1_Classroom_108 ~= nil, "the scare classroom")
		t.falsy(LAYOUTS.Level2_Auditorium.vents, "no vents on the Auditorium storey (crawlways instead)")
		for _, id in { "Level1_Hallways", "Level2_Auditorium" } do
			local crawls = 0
			for _, r in LAYOUTS[id].rooms do
				if r.kind == "Crawlway" then
					crawls += 1
				end
			end
			t.truthy(crawls >= 3, string.format("%s: %d crawlways", id, crawls))
		end
	end,

	["roof: parapets, the roof stair door, HVAC, crate and the jump"] = function(t: Expect)
		local layout = LAYOUTS.Level3_Roof
		local rooms = LayoutSchema.indexRooms(layout)
		for _, r in layout.rooms do
			if r.kind == "Roof" then
				t.truthy(r.noCeiling, r.id .. " is open to the sky")
				if r.id == layout.exit then
					t.eq(r.wallHeight, 0, "the jump point is a gap in the parapet")
				else
					t.near(r.wallHeight or 0, WorldConfig.ParapetHeight, EPS, r.id .. " parapet height")
				end
			end
		end
		t.eq(layout.entry, "L3_RoofAccess", "entry is the roof access housing")
		local roofDoors = doorsWhere(layout, function(d: Door): boolean
			return d.kind == "RoofDoor"
		end)
		t.eq(#roofDoors, 3, "a roof stair door per stair housing")
		for _, slot in { "", "North", "South" } do
			local found = false
			for _, door in roofDoors do
				if door.scriptedId == "RoofStairDoor" .. slot then
					found = table.find(door.rooms, "L3_RoofAccess" .. slot) ~= nil
				end
			end
			t.truthy(found, "the roof door RoofStairDoor" .. slot .. " opens from its housing")
		end
		local crates = anchorsOf(layout, "ParachuteCrate")
		t.eq(#crates, 1, "one parachute crate")
		t.truthy(crates[1].pos.X <= 30, "the crate is near the west edge")
		local exits = triggersOf(layout, "LevelExit")
		t.eq(#exits, 1, "one LevelExit")
		t.eq(exits[1].room, layout.exit, "the LevelExit fills the parapet gap")
		local portals = doorsWhere(layout, function(d: Door): boolean
			return table.find(d.rooms, layout.exit) ~= nil
		end)
		t.truthy(#portals >= 1, "the gap is reachable from the roof")
		for _, d in portals do
			t.eq(d.kind, "Doorway", d.id .. " is an open portal")
		end
		local exitRoom = rooms[layout.exit]
		t.eq(exitRoom.rect.x, 0, "the gap is on the west edge")
		t.truthy(exitRoom.rect.d <= 16, "a gap, not a missing wall")
		if not layout.legacy then
			for _, tower in WorldConfig.Towers do
				if tower.side == "West" then
					t.truthy(
						exitRoom.rect.z >= tower.maxZ or exitRoom.rect.z + exitRoom.rect.d <= tower.minZ,
						"the jump clears the west stair towers"
					)
				end
			end
		end
		t.truthy(#(layout.platforms or {}) >= 3, "HVAC units")
		t.truthy(#lightsOf(layout) <= 10, "almost no lights (the three stair housings' lamps and the beacon)")
		-- the old maze is gone: no objective on the roof, and every roof cell opens onto its neighbours
		t.eq(ObjectiveConfig.forLevel(layout.id), nil, "no floor objective")
		local itemSpots: { [string]: boolean } = {}
		for _, floor in ObjectiveConfig.Floors do
			local item = floor.item
			if item then
				itemSpots[item.candidate] = true
			end
		end
		for _, a in layout.anchors do
			t.falsy(itemSpots[a.kind], a.id .. " is no objective item spot")
		end
		local cells = 0
		for _, r in layout.rooms do
			if r.kind == "Roof" and r.id ~= layout.exit then
				cells += 1
			end
		end
		local seen = reachable(layout, layout.entry, { noVents = true })
		for _, r in layout.rooms do
			if r.kind == "Roof" then
				t.truthy(seen["room:" .. r.id], r.id .. " is walkable from the housing")
			end
		end
		t.truthy(cells >= 9, "the open roof cells")
	end,

	["auditorium storey: an interim tunnel floor, west in, east out, 28 high"] = function(t: Expect)
		local layout = LAYOUTS.Level2_Auditorium
		t.truthy(layout.tunnels ~= nil, "a tunnel floor (TunnelPlanner)")
		t.near(layout.height, 28, EPS, "the storey the theatre will fill")
		local entry = roomOf(layout, layout.entry)
		local exit = roomOf(layout, layout.exit)
		t.truthy(entry and entry.kind == "Airlock" and entry.rect.x + entry.rect.w <= 40, "in from the west vestibules")
		t.truthy(
			exit and exit.kind == "Airlock" and exit.rect.x >= WorldConfig.FootprintSize.X - 40,
			"out by the east vestibules"
		)
		t.eq(#triggersOf(layout, "Checkpoint"), 3, "a checkpoint in every exit vestibule candidate")
		t.truthy(#anchorsOf(layout, "BatteryCandidate") >= 6, "battery candidates")
		t.truthy(
			reachable(layout, layout.entry, { noVents = true })["room:" .. layout.exit],
			"the exit is reached on foot"
		)
	end,

	["lobby: spawns, ready pads and both terminals, no hazards"] = function(t: Expect)
		local layout = LAYOUTS.Lobby
		t.eq(#anchorsOf(layout, "PlayerSpawn"), 4, "spawns")
		t.eq(#anchorsOf(layout, "ReadyPad"), 4, "ready pads")
		local terminals = anchorsOf(layout, "Terminal")
		t.eq(#terminals, 2, "two terminals")
		local difficulty, perks = false, false
		for _, a in terminals do
			difficulty = difficulty or string.find(a.id, "Difficulty", 1, true) ~= nil
			perks = perks or string.find(a.id, "Perks", 1, true) ~= nil
		end
		t.truthy(difficulty and perks, "a difficulty terminal and a perk terminal")
		t.falsy(layout.vents, "no vents")
		t.eq(#anchorsOf(layout, "TrapCandidate"), 0, "no traps")
		t.eq(#layout.triggers, 0, "no hazard volumes")
	end,

	["ducts sunk below a floor clear the ceilings of the level below"] = function(t: Expect)
		for i = 2, #SCHOOL_ORDER do
			local upperId, lowerId = SCHOOL_ORDER[i], SCHOOL_ORDER[i - 1]
			local upper, lower = LAYOUTS[upperId], LAYOUTS[lowerId]
			local vents = upper.vents
			if not vents then
				continue
			end
			for _, e in vents.edges do
				local a, b = nodeById(upper, e.a), nodeById(upper, e.b)
				if not (a and b) then
					continue
				end
				local bottom = LayoutSchema.ventNodeY(a) - HALF_OUTER
				if bottom >= -WorldConfig.SlabThickness then
					continue
				end
				local footprint = LayoutSchema.rect(
					math.min(a.x, b.x) - HALF_OUTER,
					math.min(a.z, b.z) - HALF_OUTER,
					math.abs(a.x - b.x) + 2 * HALF_OUTER,
					math.abs(a.z - b.z) + 2 * HALF_OUTER
				)
				local worldBottom = WorldConfig.levelElevation(upperId) + bottom
				for _, r in lower.rooms do
					if LayoutSchema.rectOverlapArea(r.rect, footprint) > 0 then
						local ceilingTop = WorldConfig.levelElevation(lowerId) + LayoutSchema.roomHeight(lower, r) + 1
						t.truthy(
							ceilingTop <= worldBottom,
							string.format(
								"%s (top %.1f) clears duct %s-%s (%.2f)",
								r.id,
								ceilingTop,
								e.a,
								e.b,
								worldBottom
							)
						)
					end
				end
			end
		end
	end,

	["exit airlocks hold the checkpoint volume"] = function(t: Expect)
		for _, spec in WorldConfig.Stairwells do
			local layout = LAYOUTS[spec.from]
			local found = false
			for _, tr in triggersOf(layout, "Checkpoint") do
				if tr.room == spec.fromRoom then
					found = true
				end
			end
			t.truthy(found, spec.from .. " checkpoint in " .. spec.fromRoom)
		end
	end,
}
