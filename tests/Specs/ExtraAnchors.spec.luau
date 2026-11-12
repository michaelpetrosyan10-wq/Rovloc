--!strict
-- ExtraAnchors (docs/design/game-spec-v2.md 3.2, 4.2, 4.3): the post-plan pass that gives the Basement and the Hallways
-- their 36 battery candidates and 8 flask spots, and the Hallways' janitor content it serves.
--   * The counts, and the planned rooms, doors and zone graph of both floors keep the hash recorded from the untouched
--     plan (commit 9773ece): the pass adds and drops anchors only.
--   * Every battery spot stands in a run that is no dead end, every pair is ExtraAnchors.Spacing walked apart, every
--     way in has one in the entry band and every main station one in reach, so RunDirector's four placement rules hold
--     on every seed (RunDirectorPicks.spec replays them on 16 seeds); the pass is deterministic.
--   * The 14 master-key candidates of 4.3: ten in tunnel niches, two in the main office, two on mop-cart handles;
--     none in Gus's closet, all west of the gate, a hiding spot within 25 studs walked of each.
--   * The flask spots stand where 4.2 and 4.3 name them and rest on something: a platform, a cart's tray or the
--     cleaning shelf over a drum.
--   * The six mop carts stand against a run's wall west of the gate, clear of its doorways, a lane free past them; the
--     cot is in the closet, the wall phone in the workshop, the chute's mouth in the delivery bay.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local CleaningShelfBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.CleaningShelfBuilder)
local ExtraAnchors = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ExtraAnchors)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local MopCartBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.MopCartBuilder)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local ObjectivePlaces = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ObjectivePlaces)
local RadarConfig = require(ReplicatedStorage.Shared.Config.RadarConfig)
local RunDirector = require(ReplicatedStorage.Shared.World.RunDirector)
local TunnelRules = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.TunnelRules)
local ZoneGraph = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.ZoneGraph)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Layout = LayoutSchema.LevelLayout
type Anchor = LayoutSchema.Anchor

local FLOORS = { "Level0_Basement", "Level1_Hallways" }

-- The plan hashes recorded from the untouched head (9773ece), before the pass existed: FNV-1a (MathUtil.hash) of the
-- rooms, the doors and the zone graph's nodes and edges as text, and how many rows that text has.
local RECORDED: { [string]: { hash: string, rows: number } } = {
	Level0_Basement = { hash = "adca49fa", rows = 1105 },
	Level1_Hallways = { hash = "1e6ef063", rows = 1403 },
}

local GATE_X = 290 -- the Hallways' gate line: the keys are all west of it
local CLOSET = "L1_JanitorCloset"
local OFFICE = "L1_MainOffice"

local function layoutOf(id: string): Layout
	local layout = Builder.getLayout(id)
	assert(layout, id .. " loads")
	return layout
end

local function anchorsOf(layout: Layout, kind: string): { Anchor }
	local out: { Anchor } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == kind then
			table.insert(out, anchor)
		end
	end
	return out
end

local function anchorById(layout: Layout, id: string?): Anchor?
	for _, anchor in layout.anchors do
		if anchor.id == id then
			return anchor
		end
	end
	return nil
end

local function place(anchor: Anchor): RunDirector.Place
	return { room = anchor.room, pos = anchor.pos }
end

local function num(x: number?): string
	return if x == nil then "-" else string.format("%.3f", x)
end

-- The plan's hash: its rooms, its doors and the zone graph built on it, as text (the recording's exact recipe).
local function planHash(layout: Layout): (string, number)
	local parts: { string } = {}
	for _, r in layout.rooms do
		local rect = r.rect
		local row =
			{ "R", r.id, r.kind, num(rect.x), num(rect.z), num(rect.w), num(rect.d), num(r.height), num(r.drop) }
		table.insert(parts, table.concat(row, "|"))
	end
	for _, d in layout.doors do
		local row = {
			"D",
			d.id,
			d.kind,
			d.rooms[1],
			d.rooms[2],
			num(d.at),
			num(d.width),
			num(d.height),
			tostring(d.crawlOnly == true),
			d.scriptedId or "-",
		}
		table.insert(parts, table.concat(row, "|"))
	end
	local graph = ZoneGraph.build({ layout })
	local ids: { string } = {}
	for id in graph.nodes do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local n = graph.nodes[id]
		table.insert(parts, table.concat({ "N", id, n.kind, num(n.center.X), num(n.center.Y), num(n.center.Z) }, "|"))
	end
	for _, e in graph.edges do
		local row = {
			"E",
			e.a,
			e.b,
			e.kind,
			e.portalId,
			num(e.length),
			num(e.clearance),
			tostring(e.crawlOnly == true),
			tostring(e.lip == true),
		}
		table.insert(parts, table.concat(row, "|"))
	end
	return string.format("%08x", MathUtil.hash(table.concat(parts, "\n"))), #parts
end

-- A copy of `layout` without the pass's own anchors (the added batteries and the flask spots), to run it again.
local function withoutPass(layout: Layout): Layout
	local copy = table.clone(layout) :: any
	copy.anchors = {}
	for _, anchor in layout.anchors do
		local added = anchor.kind == "FlaskCandidate"
			or (anchor.kind == "BatteryCandidate" and string.find(anchor.id, "_BatteryCandidate_X", 1, true) ~= nil)
		if not added then
			table.insert(copy.anchors, anchor)
		end
	end
	return copy
end

local function anchorText(layout: Layout, kinds: { string }): string
	local rows: { string } = {}
	for _, anchor in layout.anchors do
		if table.find(kinds, anchor.kind) then
			local p = anchor.pos
			table.insert(
				rows,
				string.format("%s %s %.3f %.3f %.3f %s", anchor.id, anchor.room, p.X, p.Y, p.Z, num(anchor.yaw))
			)
		end
	end
	return table.concat(rows, "\n")
end

return {
	["36 battery candidates and 8 flask spots on each floor"] = function(t: Expect)
		for _, id in FLOORS do
			local layout = layoutOf(id)
			t.eq(#anchorsOf(layout, "BatteryCandidate"), RadarConfig.Candidates, id .. " battery candidates")
			t.eq(RadarConfig.Candidates, 36)
			t.eq(#anchorsOf(layout, "FlaskCandidate"), 8, id .. " flask spots")
			t.eq(table.concat(LayoutSchema.validate(layout), "; "), "", id .. " still validates")
		end
	end,

	["the planned rooms, doors and zone graph keep their recorded hash"] = function(t: Expect)
		for _, id in FLOORS do
			local hash, rows = planHash(layoutOf(id))
			t.eq(rows, RECORDED[id].rows, id .. " rows")
			t.eq(hash, RECORDED[id].hash, id .. " plan hash")
		end
	end,

	["the pass is deterministic: run again on its own input it adds the same anchors"] = function(t: Expect)
		for _, id in FLOORS do
			local layout = layoutOf(id)
			local again = withoutPass(layout)
			local seed = if id == "Level0_Basement" then 20261103 else 20261104
			local flasks: { ExtraAnchors.FlaskSpot } = {}
			local niche = 0
			for _, anchor in anchorsOf(layout, "FlaskCandidate") do
				if string.find(anchor.room, "Alcove", 1, true) then
					niche += 1
				else
					table.insert(flasks, { pos = anchor.pos, yaw = anchor.yaw or 0, ref = anchor.ref })
				end
			end
			local report = ExtraAnchors.apply(again, {
				seed = seed,
				stations = if id == "Level0_Basement" then { "BreakerPanel" } else { "ExitLock" },
				flasks = flasks,
				nicheFlasks = niche,
				nicheAreas = if id == "Level1_Hallways" then { { 44, 180, GATE_X, 288 }, { 0, 0, 44, 288 } } else nil,
			})
			t.eq(report.batteries, 36, id .. " report")
			t.eq(#report.dropped, 0, id .. ": nothing left to drop")
			local kinds = { "BatteryCandidate", "FlaskCandidate" }
			t.eq(anchorText(again, kinds), anchorText(layout, kinds), id .. " the same anchors")
		end
	end,

	["no battery spot in a dead end; every pair spaced; every way in and main station served"] = function(t: Expect)
		local rules = RadarConfig.Placement
		for _, id in FLOORS do
			local layout = layoutOf(id)
			local dead = RunDirector.deadEndRooms(layout)
			local batteries = anchorsOf(layout, "BatteryCandidate")
			for _, anchor in batteries do
				t.falsy(dead[anchor.room], anchor.id .. " in a dead end (" .. anchor.room .. ")")
				t.eq(anchor.pos.Y, 0, anchor.id .. " on the floor")
			end
			local closest = math.huge
			for i = 1, #batteries do
				for j = i + 1, #batteries do
					closest = math.min(closest, RunDirector.walk(layout, place(batteries[i]), place(batteries[j])))
				end
			end
			t.truthy(
				closest >= ExtraAnchors.Spacing and ExtraAnchors.Spacing >= rules.PairSpacing,
				string.format("%s: the closest pair is %.1f walked apart", id, closest)
			)
			for _, entry in ObjectivePlaces.entries(layout) do
				local served = 0
				for _, anchor in batteries do
					local d = RunDirector.walk(layout, place(anchor), { room = entry.room, pos = entry.pos })
					if d >= rules.EntryMin and d <= rules.EntryMax then
						served += 1
					end
				end
				t.truthy(
					served >= 1,
					string.format("%s: a battery %d-%d from %s", id, rules.EntryMin, rules.EntryMax, entry.room)
				)
			end
			local spec = ObjectiveConfig.forLevel(id)
			local kind = spec and spec.mainStation
			assert(kind, id .. " names its main station")
			for _, station in anchorsOf(layout, kind) do
				local best = math.huge
				for _, anchor in batteries do
					best = math.min(best, RunDirector.walk(layout, place(anchor), place(station)))
				end
				t.truthy(best <= rules.StationReach, string.format("%s: a battery %.1f from %s", id, best, station.id))
			end
		end
	end,

	["the 14 key candidates: none in the closet, all west of the gate, a hide within 25 walked of each"] = function(
		t: Expect
	)
		local layout = layoutOf("Level1_Hallways")
		local keys = anchorsOf(layout, "MasterKeyCandidate")
		t.eq(#keys, 14, "fourteen hooks")
		local onCarts, inOffice, inNiches = 0, 0, 0
		local carts: { [string]: boolean } = {}
		for _, key in keys do
			t.truthy(key.room ~= CLOSET, key.id .. " is not in Gus's closet")
			t.truthy(key.pos.X < GATE_X, string.format("%s west of the gate (x %.1f)", key.id, key.pos.X))
			local hide =
				ObjectivePlaces.nearestHide(layout, { id = key.id, kind = key.kind, room = key.room, pos = key.pos })
			t.truthy(
				hide ~= nil and hide.distance <= ObjectiveConfig.HideReach and ObjectiveConfig.HideReach == 25,
				string.format("%s: a hide %.1f walked away", key.id, if hide then hide.distance else math.huge)
			)
			local cart = anchorById(layout, key.ref)
			if cart and cart.kind == "MopCart" then
				onCarts += 1
				t.falsy(carts[cart.id], cart.id .. " carries one hook")
				carts[cart.id] = true
			elseif key.room == OFFICE then
				inOffice += 1
			elseif string.find(key.room, "Alcove", 1, true) then
				inNiches += 1
			end
		end
		t.eq(inNiches, 10, "ten in tunnel niches")
		t.eq(inOffice, 2, "two in the main office")
		t.eq(onCarts, 2, "two on mop-cart handles")
		-- the closet's hook is empty, and RunDirector can pick every one of them
		local eligible = RunDirector.objectiveCandidates(layout, ObjectiveConfig.forLevel("Level1_Hallways") :: any)
		t.eq(#eligible, 14, "every hook is a candidate a run may use")
	end,

	["the flask spots stand where 4.2 and 4.3 name them, each on something"] = function(t: Expect)
		local want: { [string]: { [string]: number } } = {
			Level0_Basement = { L0_StorageCage = 2, L0_Workshop = 1, L0_BoilerRoom = 1, niche = 4 },
			Level1_Hallways = { L1_JanitorCloset = 2, cart = 4, niche = 2 },
		}
		for _, id in FLOORS do
			local layout = layoutOf(id)
			local got: { [string]: number } = {}
			local holders: { [Anchor]: number } = {}
			for _, anchor in layout.anchors do
				holders[anchor] = 0
			end
			for _, flask in anchorsOf(layout, "FlaskCandidate") do
				local cart = anchorById(layout, flask.ref)
				local key = flask.room
				if cart and cart.kind == "MopCart" then
					key = "cart"
					local spot = MopCartBuilder.flaskSpot(cart.pos, cart.yaw or 0)
					t.truthy((spot.pos - flask.pos).Magnitude < 1e-3, flask.id .. " on " .. cart.id .. "'s tray")
				elseif string.find(flask.room, "Alcove", 1, true) then
					key = "niche"
					local drums = 0
					for _, other in layout.anchors do
						if other.room == flask.room and other.kind == "Barrel" then
							drums += 1
						end
					end
					t.eq(drums, 1, flask.id .. " over a drum")
					t.near(flask.pos.Y, ExtraAnchors.NicheShelfY, 1e-6, flask.id .. " on the shelf over it")
					t.falsy(CleaningShelfBuilder.carried(layout, flask), flask.id .. " gets a cleaning shelf")
				end
				got[key] = (got[key] or 0) + 1
				if key ~= "niche" and key ~= "cart" and not CleaningShelfBuilder.carried(layout, flask) then
					-- the boiler room's: a wall shelf, its spot at the shelf's depth off the wall
					local room = LayoutSchema.indexRooms(layout)[flask.room]
					local r = room.rect
					local x, z = flask.pos.X, flask.pos.Z
					local offWall = math.min(
						math.abs(x - (r.x + 0.5)),
						math.abs(x - (r.x + r.w - 0.5)),
						math.abs(z - (r.z + 0.5)),
						math.abs(z - (r.z + r.d - 0.5))
					)
					t.near(offWall, 0.55, 0.01, flask.id .. " on a wall shelf")
				end
			end
			for key, n in want[id] do
				t.eq(got[key] or 0, n, string.format("%s: %d flask spots in %s", id, n, key))
			end
		end
		-- Level 1's niches are in Kitchen Service (its region's areas hold the niche)
		local hallways = layoutOf("Level1_Hallways")
		local hallRooms = LayoutSchema.indexRooms(hallways)
		for _, flask in anchorsOf(hallways, "FlaskCandidate") do
			if string.find(flask.room, "Alcove", 1, true) then
				local centre = LayoutSchema.rectCenter(hallRooms[flask.room].rect)
				local x, z = centre.X, centre.Y
				local kitchen = (x >= 44 and x <= GATE_X and z >= 180) or x <= 44
				t.truthy(kitchen, flask.id .. " in a Kitchen Service niche")
			end
		end
	end,

	["six mop carts west of the gate, against a run's wall, clear of its doorways, a lane past them"] = function(
		t: Expect
	)
		local layout = layoutOf("Level1_Hallways")
		local rooms = LayoutSchema.indexRooms(layout)
		local carts = anchorsOf(layout, "MopCart")
		t.eq(#carts, 6, "six carts")
		local held: { [string]: number } = {}
		for _, anchor in layout.anchors do
			if anchor.ref and (anchor.kind == "MasterKeyCandidate" or anchor.kind == "FlaskCandidate") then
				held[anchor.ref] = (held[anchor.ref] or 0) + 1
			end
		end
		local reach = MopCartBuilder.Reach
		for _, cart in carts do
			t.eq(held[cart.id], 1, cart.id .. " carries one hook or one flask")
			t.truthy(cart.pos.X < GATE_X, cart.id .. " west of the gate")
			local room = rooms[cart.room]
			t.truthy(room.kind == "Tunnel" or room.kind == "Gallery", cart.id .. " in a run")
			-- its back to a wall: the wall face is WallOffset behind the anchor
			local frame = CFrame.new(cart.pos) * CFrame.Angles(0, math.rad(cart.yaw or 0), 0)
			local wallPoint = frame * Vector3.new(0, 0, MopCartBuilder.WallOffset)
			local r = room.rect
			local onWall = math.abs(wallPoint.X - (r.x + 0.5)) < 0.05
				or math.abs(wallPoint.X - (r.x + r.w - 0.5)) < 0.05
				or math.abs(wallPoint.Z - (r.z + 0.5)) < 0.05
				or math.abs(wallPoint.Z - (r.z + r.d - 0.5)) < 0.05
			t.truthy(onWall, cart.id .. " backs onto a wall")
			-- the lane past it: the run's width less the cart's depth
			local width = math.min(r.w, r.d) - 1
			t.truthy(
				width - reach.depth >= 4,
				string.format("%s leaves %.1f studs to pass", cart.id, width - reach.depth)
			)
			-- clear of every doorway of its run along the cart, its bucket and its sign
			for _, door in layout.doors do
				if table.find(door.rooms, cart.room) then
					local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
					local p = TunnelRules.doorPoint(a.rect, b.rect, door.at)
					if p then
						local here = frame:PointToObjectSpace(Vector3.new(p.X, 0, p.Y))
						local half = LayoutSchema.doorWidth(door) / 2 + 0.5
						local overlaps = here.X > reach.minX - half
							and here.X < reach.maxX + half
							and here.Z > -reach.depth
						t.falsy(overlaps, string.format("%s stands clear of doorway %s", cart.id, door.id))
					end
				end
			end
		end
	end,

	["the cot in the closet, the phone in the workshop, the chute's mouth in the delivery bay"] = function(t: Expect)
		local hallways = layoutOf("Level1_Hallways")
		local cots = anchorsOf(hallways, "JanitorCot")
		t.eq(#cots, 1, "one cot")
		t.eq(cots[1].room, CLOSET, "in Gus's closet")
		local basement = layoutOf("Level0_Basement")
		local phones = anchorsOf(basement, "WallPhone")
		t.eq(#phones, 1, "one wall phone")
		t.eq(phones[1].room, "L0_Workshop", "in the workshop")
		local mouth = anchorById(basement, "L0_Mark_ChuteMouth")
		t.truthy(mouth and mouth.kind == "CutsceneMark" and mouth.room == "L0_DeliveryBay", "the chute's mouth")
		t.eq(basement.entry, "L0_DeliveryBay", "where the squad lands")
		-- nothing of Gus's is a noise, a hide or a light: the closet's hide is its old locker
		for _, anchor in hallways.anchors do
			if anchor.room == CLOSET and TunnelRules.HideKinds[anchor.kind] then
				t.eq(anchor.kind, "Locker", "the closet's one hide")
			end
		end
	end,
}
