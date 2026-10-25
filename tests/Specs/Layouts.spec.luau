--!strict
-- Every level blueprint validates (LayoutSchema.validate) and carries the content its level needs (USER_SPEC
-- "LEVELS"), plus the cross-cutting rules the builders rely on: unique ids, dark lighting, patrol loops that hop
-- through doorways, openings that never collide on a wall, and a pool basin that clears the level below it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
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
	Level2_ScienceHall = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Level2_ScienceHall),
	Level3_Gymnasium = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Level3_Gymnasium),
	Level4_FloodedPool = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Level4_FloodedPool),
	Level5_Roof = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Level5_Roof),
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
	"WoodGym",
	"WoodPanel",
	"PlasterSchool",
	"PlasterGreen",
	"Brick",
	"MetalRust",
	"MetalGalvanized",
	"RoofGravel",
	"Asphalt",
	"PoolTile",
	"Carpet",
	"Lab",
}

local AMBIENCE: { [string]: string } = {
	Lobby = "DroneLobby",
	Level0_Basement = "DroneBasement",
	Level1_Hallways = "DroneHallways",
	Level2_ScienceHall = "DroneScience",
	Level3_Gymnasium = "DroneGym",
	Level4_FloodedPool = "DronePool",
	Level5_Roof = "DroneRoof",
}

local EPS = 1e-3

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
	for _, id: Enums.LevelId in Enums.LevelId do
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
			t.eq(LAYOUTS[spec.from].exit, spec.fromRoom, spec.id .. " leaves from the lower level's exit")
			t.eq(LAYOUTS[spec.to].entry, spec.toRoom, spec.id .. " arrives in the upper level's entry")
		end
		local basementEntry = roomOf(LAYOUTS.Level0_Basement, LAYOUTS.Level0_Basement.entry)
		t.truthy(basementEntry and basementEntry.rect.x == 0, "the basement spawn room sits on the west wall")
		local roofExit = roomOf(LAYOUTS.Level5_Roof, LAYOUTS.Level5_Roof.exit)
		t.truthy(roofExit and roofExit.rect.x == 0, "the roof exit is the west edge")
		for id, layout in LAYOUTS do
			t.eq(layout.ambience, AMBIENCE[id], id .. " ambience bed")
			if id ~= "Lobby" and id ~= "Level5_Roof" then
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
			for _, b in (layout.basins or {}) :: { LayoutSchema.Basin } do
				claim(b.id, layoutId)
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
			local spawns: { Anchor } = {}
			for _, a in anchorsOf(layout, "PlayerSpawn") do
				t.eq(a.room, layout.entry, id .. " spawn " .. a.id .. " is in the entry room")
				table.insert(spawns, a)
			end
			t.eq(#spawns, 4, id .. " has four PlayerSpawn anchors")
			for i = 1, #spawns do
				for j = i + 1, #spawns do
					t.truthy(
						flatDistance(spawns[i].pos, spawns[j].pos) >= WorldConfig.SpawnSpacing - EPS,
						id .. " spawns keep SpawnSpacing"
					)
				end
			end
		end
	end,

	["the creature has a spawn on every level from the hallways up"] = function(t: Expect)
		for _, id in schoolLevels() do
			local count = #anchorsOf(LAYOUTS[id], "CreatureSpawn")
			if id == "Level0_Basement" then
				t.truthy(count <= 1, "the basement holds at most a dormant placement")
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
			local lit = 0
			local groups: { [string]: boolean } = {}
			for _, l in lights do
				t.truthy(l.range <= 60, l.id .. " range <= 60")
				t.truthy(l.brightness > 0, l.id .. " brightness")
				if not l.broken then
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
			if id ~= "Lobby" then
				t.truthy(
					lit <= math.max(2, 0.2 * #lights),
					string.format("%s: %d of %d fixtures lit", id, lit, #lights)
				)
			end
		end
	end,

	["patrol loops hop through doorways and cover levels 1-5"] = function(t: Expect)
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
					t.truthy(
						a.room == b.room or joined[a.room .. "|" .. b.room],
						string.format("%s loop %s: %s -> %s crosses no doorway", id, loop, a.id, b.id)
					)
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
			local floorOf: { [string]: number } = {}
			for _, b in (layout.basins or {}) :: { LayoutSchema.Basin } do
				floorOf[b.room] = math.min(floorOf[b.room] or 0, -b.depth)
			end
			for _, a in layout.anchors do
				local r = rooms[a.room]
				if r then
					t.truthy(a.pos.Y <= LayoutSchema.roomHeight(layout, r), id .. " " .. a.id .. " under the ceiling")
					t.truthy(a.pos.Y >= (floorOf[a.room] or 0), id .. " " .. a.id .. " above the floor")
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

	["basement: trap fields, batteries, debris and the checkpoint"] = function(t: Expect)
		local layout = LAYOUTS.Level0_Basement
		local rooms = LayoutSchema.indexRooms(layout)
		local traps = anchorsOf(layout, "TrapCandidate")
		t.truthy(#traps >= 40, "at least 40 trap candidates")
		for i, a in traps do
			t.truthy(a.room ~= layout.entry and rooms[a.room].kind ~= "Airlock", a.id .. " outside spawn/airlock")
			for j = i + 1, #traps do
				t.truthy(flatDistance(a.pos, traps[j].pos) >= 6, a.id .. " keeps 6 studs from " .. traps[j].id)
			end
		end
		t.truthy(#anchorsOf(layout, "BatteryCandidate") >= 6, "battery candidates")
		t.truthy(#triggersOf(layout, "FloorDebris") >= 1, "floor debris")
		local checkpoints = triggersOf(layout, "Checkpoint")
		t.eq(#checkpoints, 1, "one checkpoint")
		t.eq(checkpoints[1].room, "L0_AirlockEast", "checkpoint in the airlock")
		t.falsy(layout.vents, "no vents in the basement")
		t.truthy(#(layout.pillars or {}) >= 20, "a pillar grid")
		t.truthy(#(layout.windows or {}) >= 8, "boarded windows")
		for _, w in (layout.windows or {}) :: { LayoutSchema.Window } do
			t.truthy(w.boarded and w.sill >= layout.height / 2, "basement windows are boarded and high")
		end
		t.eq(#anchorsOf(layout, "PatrolWaypoint"), 0, "no creature activity")
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
		local glow = 0
		for _, l in (classroom.lights or {}) :: { Light } do
			if l.kind == "ClassroomGlow" and not l.broken then
				glow += 1
			end
		end
		t.eq(glow, 1, "the classroom glows")
		local poses = anchorsOf(layout, "CreatureScarePose")
		t.eq(#poses, 1, "one scare pose")
		t.eq(poses[1].room, classroom.id, "the Creature crouches in the glowing classroom")
		local glass = triggersOf(layout, "ScareStep")
		t.eq(#glass, 1, "one ScareStep")
		t.eq(glass[1].room, corridor.id, "the glass lies in the corridor")
		local doorEdge = LayoutSchema.sharedEdge(classroom.rect, corridor.rect)
		local glassRect = glass[1].rect
		local spansDoor = if doorEdge and doorEdge.axis == "Z"
			then glassRect.x <= classroomDoor.at and glassRect.x + glassRect.w >= classroomDoor.at
			else glassRect.z <= classroomDoor.at and glassRect.z + glassRect.d >= classroomDoor.at
		t.truthy(spansDoor, "the glass spans the classroom doorway")

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
		local total, lockable, critical = grateCounts(layout)
		t.truthy(total >= 2 and critical >= 2, "the bypass vent has critical grates")
		t.eq(lockable, 0, "the first wall vent never locks")
		local vents = layout.vents
		if vents then
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
		t.truthy(#triggersOf(layout, "Checkpoint") == 1, "exit checkpoint")
	end,

	["science hall: labs, flasks on counters and an extensive vent network"] = function(t: Expect)
		local layout = LAYOUTS.Level2_ScienceHall
		local labs = 0
		for _, r in layout.rooms do
			if r.kind == "Lab" then
				labs += 1
			end
		end
		t.truthy(labs >= 6, "chem, bio and prep labs")
		local counters = anchorsOf(layout, "LabCounter")
		local flasks = anchorsOf(layout, "FlaskCandidate")
		t.truthy(#counters >= 8, "lab counters")
		t.truthy(#flasks >= 10, "at least 10 flask candidates")
		for _, f in flasks do
			local onCounter = false
			for _, c in counters do
				if c.room == f.room and math.abs(f.pos.X - c.pos.X) <= 5 and math.abs(f.pos.Z - c.pos.Z) <= 1.75 then
					onCounter = true
				end
			end
			t.truthy(onCounter and f.pos.Y > 2.5, f.id .. " stands on a lab counter")
		end
		local chases = 0
		for _, r in layout.rooms do
			if r.kind == "Chase" then
				chases += 1
			end
		end
		t.truthy(chases >= 6, "many chases")
		local total, lockable, critical = grateCounts(layout)
		t.truthy(total >= 20, "an extensive network")
		t.truthy(critical >= 2, "a critical route")
		t.truthy(lockable >= 4 and lockable * 2 >= total - critical, "at least half the other grates lock")
		t.truthy(#anchorsOf(layout, "BatteryCandidate") >= 6, "battery candidates")
	end,

	["gymnasium: tall gym with bleachers, locker rooms, low vents"] = function(t: Expect)
		local layout = LAYOUTS.Level3_Gymnasium
		local rooms = LayoutSchema.indexRooms(layout)
		local gym: Room? = nil
		local lockerRooms: { [string]: boolean } = {}
		local coach = false
		for _, r in layout.rooms do
			if r.kind == "Gym" and LayoutSchema.roomHeight(layout, r) >= 28 then
				gym = r
			elseif r.kind == "LockerRoom" then
				lockerRooms[r.id] = true
			end
			if string.find(r.id, "Coach", 1, true) then
				coach = true
			end
		end
		t.truthy(gym, "a tall gym")
		t.truthy(coach, "a coach office")
		if not gym then
			return
		end
		t.truthy(gym.rect.w >= 100 and gym.rect.d >= 60, "the gym is massive")
		local bleachers = 0
		for _, p in (layout.platforms or {}) :: { LayoutSchema.Platform } do
			if p.room == gym.id then
				bleachers += 1
			end
		end
		t.truthy(bleachers >= 4, "bleachers")
		local lockers = anchorsOf(layout, "Locker")
		t.truthy(#lockers >= 20, "many hideable lockers")
		local inLockerRooms = 0
		for _, a in lockers do
			if lockerRooms[a.room] then
				inLockerRooms += 1
			end
		end
		t.truthy(inLockerRooms * 2 >= #lockers, "most lockers line the locker rooms")
		local vents = layout.vents
		t.truthy(vents, "vents")
		if not vents then
			return
		end
		local opensInto: { [string]: boolean } = {}
		for _, g in vents.grates do
			opensInto[g.room] = true
		end
		t.truthy(opensInto[gym.id], "a grate into the gym")
		for roomId in lockerRooms do
			t.truthy(opensInto[roomId], "a grate into " .. roomId)
		end
		for _, n in vents.nodes do
			t.near(LayoutSchema.ventNodeY(n), WorldConfig.VentCenterHeight, EPS, n.id .. " is a low wall vent")
		end
		local total, lockable, critical = grateCounts(layout)
		t.truthy(lockable * 2 >= total - critical, "at least half the other grates lock")
		-- the way into the gym from the locker wing is the vent
		local doorsOnly = reachable(layout, layout.entry, { noVents = true })
		t.falsy(doorsOnly["room:" .. gym.id], "the gym's doors to the locker wing are shut")
		t.truthy(rooms[layout.exit] and #anchorsOf(layout, "BatteryCandidate") >= 6, "battery candidates")
	end,

	["flooded pool: deep basin, collapsed walkways, submerged ducts, floodlight switch"] = function(t: Expect)
		local layout = LAYOUTS.Level4_FloodedPool
		local pool: Room? = nil
		for _, r in layout.rooms do
			if r.kind == "Pool" then
				pool = r
			end
		end
		t.truthy(pool, "a pool hall")
		if not pool then
			return
		end
		t.truthy(LayoutSchema.roomHeight(layout, pool) >= 26, "cavernous")
		t.truthy(pool.rect.w >= 120 and pool.rect.d >= 90, "about 140 x 100")
		local basins = layout.basins or {}
		t.eq(#basins, 1, "one basin")
		local basin = basins[1]
		t.eq(basin.room, pool.id, "the basin is in the pool hall")
		t.near(basin.waterLevel, WorldConfig.WaterSurfaceOffset, EPS, "murky water just below the deck")
		t.truthy(basin.depth >= 8, "deep enough to swim")
		t.truthy(basin.rect.w * basin.rect.d >= 0.5 * pool.rect.w * pool.rect.d, "the hall is mostly basin")
		t.truthy(
			math.abs(basin.rect.z - pool.rect.z) < EPS and math.abs(basin.rect.d - pool.rect.d) < EPS,
			"the basin runs wall to wall, so the crossing is a swim"
		)
		local fragments = 0
		for _, p in (layout.platforms or {}) :: { LayoutSchema.Platform } do
			if LayoutSchema.rectOverlapArea(p.rect, basin.rect) > 0 and math.abs(p.top) <= 1 then
				fragments += 1
			end
		end
		t.truthy(fragments >= 3, "collapsed walkway fragments")
		local vents = layout.vents
		t.truthy(vents, "maintenance ducts")
		if vents then
			local submerged = 0
			for _, e in vents.edges do
				if e.submerged then
					submerged += 1
				end
			end
			t.truthy(submerged >= 1, "half-submerged duct edges")
			local criticalIntoPool = 0
			for _, g in vents.grates do
				if g.criticalPath and g.room == pool.id then
					criticalIntoPool += 1
				end
			end
			t.truthy(criticalIntoPool >= 2, "the flooded duct is part of the route across the pool")
		end
		t.eq(#anchorsOf(layout, "FloodlightSwitch"), 1, "the emergency floodlight switch")
		local deckFlasks = 0
		for _, f in anchorsOf(layout, "FlaskCandidate") do
			if f.room == pool.id and f.pos.Y >= 0 then
				deckFlasks += 1
			end
		end
		t.truthy(deckFlasks >= 3, "flasks on the deck")
		t.truthy(#triggersOf(layout, "PoolWater") >= 1, "pool water volumes")
		local floodlights = 0
		for _, l in lightsOf(layout) do
			if l.kind == "Floodlight" then
				floodlights += 1
			end
		end
		t.truthy(floodlights >= 4, "pool floodlights for the switch")
	end,

	["roof: parapets, the roof stair door, HVAC, crate and the jump"] = function(t: Expect)
		local layout = LAYOUTS.Level5_Roof
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
		t.eq(layout.entry, "L5_RoofAccess", "entry is the roof access housing")
		local roofDoors = doorsWhere(layout, function(d: Door): boolean
			return d.kind == "RoofDoor"
		end)
		t.eq(#roofDoors, 1, "one roof stair door")
		t.eq(roofDoors[1].scriptedId, "RoofStairDoor", "scripted roof door")
		t.truthy(table.find(roofDoors[1].rooms, "L5_RoofAccess"), "the roof door opens from the housing")
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
		local tower = WorldConfig.Towers.West
		t.truthy(
			exitRoom.rect.z >= tower.maxZ or exitRoom.rect.z + exitRoom.rect.d <= tower.minZ,
			"the jump clears the west stair tower"
		)
		t.truthy(#(layout.platforms or {}) >= 3, "HVAC units")
		t.truthy(#lightsOf(layout) <= 6, "almost no lights")
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

	["the pool basin clears the level below"] = function(t: Expect)
		local upperId, lowerId = "Level4_FloodedPool", "Level3_Gymnasium"
		local upper, lower = LAYOUTS[upperId], LAYOUTS[lowerId]
		for _, basin in (upper.basins or {}) :: { LayoutSchema.Basin } do
			local basinUnderside = WorldConfig.levelElevation(upperId) - basin.depth - WorldConfig.SlabThickness
			for _, r in lower.rooms do
				if LayoutSchema.rectOverlapArea(r.rect, basin.rect) > 0 then
					local ceilingTop = WorldConfig.levelElevation(lowerId) + LayoutSchema.roomHeight(lower, r) + 1
					t.truthy(
						ceilingTop <= basinUnderside,
						string.format(
							"%s (top %.1f) clears basin %s (%.1f)",
							r.id,
							ceilingTop,
							basin.id,
							basinUnderside
						)
					)
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
