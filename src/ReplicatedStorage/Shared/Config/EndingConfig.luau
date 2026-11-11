--!strict
-- EndingConfig: the bell tower's standoff (spec v2 §4.6): when it starts, its timeline from T_s, the revolver's hit
-- test and the authority's tolerances, the holder's buttons and the monster's approach. EndingRules (Shared/Rules)
-- runs them; the web reads them through exportMeta() (meta.endingConfig).
--
-- The timeline is Standard's, in seconds from T_s. Nightmare moves every event after FireOpens to
-- FireOpens + (t - FireOpens) x NightmareScale, which makes its fire window exactly 10.0 s (I5), and cuts the lines in
-- NightmareCuts so no two lines overlap.

export type Line = { id: string, at: number, length: number }
export type Walk = { from: number, to: number, stop: number }
export type Spot = { id: string, x: number, z: number }

local EndingConfig = {
	TickRate = 30,
	-- when the standoff starts: T_s = max(first belfry arrival + ArrivalDelay, revolver taken + TakenDelay), and not
	-- before every active runner is on the belfry or StragglerWait after the shutter slammed
	ArrivalDelay = 12,
	TakenDelay = 5,
	StragglerWait = 20,
	LiftLead = 1, -- at T_s - 1 anyone still on the stair is lifted through the hatch, and it bolts
	PickUpLineAt = 4.0, -- nobody holding the revolver at T_s + 4.0: "Go on. Pick it up, {name}."
	WalkCap = 11, -- everyone walks at 11 at most during the standoff

	-- the timeline (Standard, from T_s)
	WarningAt = -1.6, -- the teleport warning on the belfry (I2)
	FadeInAt = 0.0,
	FadeInSeconds = 0.8,
	StareAt = 0.8,
	FireOpens = 2.0, -- fire is enabled; a button already held is ignored until released
	ContactAt = 15.5, -- contact: Ending B (the window closes)
	CutAt = 17.0, -- a lightning cut puts it on the holder
	Walks = table.freeze({
		table.freeze({ from = 2.0, to = 5.5, stop = 20 } :: Walk),
		table.freeze({ from = 8.8, to = 10.5, stop = 13 } :: Walk),
		table.freeze({ from = 13.4, to = 15.5, stop = 4 } :: Walk),
	}),
	Lines = table.freeze({
		table.freeze({ id = "Name", at = 1.0, length = 1.0 } :: Line), -- Monster: "{name}."
		table.freeze({ id = "Plea", at = 5.6, length = 3.2 } :: Line), -- Danny: "It's me. It's still me. Please... don't."
		table.freeze({ id = "YouHid", at = 10.6, length = 2.4 } :: Line), -- Monster: "You hid. You always hide."
		table.freeze({ id = "DoIt", at = 13.2, length = 1.0 } :: Line), -- Danny: "...do it."
	}),
	NightmareScale = 10.0 / 13.5, -- 0.741: the 13.5 s window becomes 10.0 s
	NightmareCuts = table.freeze({ "YouHid" }),

	-- the monster's approach
	WalkMin = 2, -- each walk's speed is the remaining distance / the remaining time, clamped to WalkMin..WalkMax
	WalkMax = 9,
	ContactDistance = 4,
	LungeSpeed = 12, -- still over ContactDistance away at ContactAt
	LoweredSpeed = 6, -- the gun lowered: "I knew you wouldn't."
	MissedSpeed = 9, -- a clear miss: "Missed."
	ReaimSeconds = 0.35, -- it walks straight lines, re-aimed this often
	Spots = table.freeze({ -- where it fades in: whichever is farthest from the holder (or the players' centre)
		table.freeze({ id = "E", x = 35, z = 88 } :: Spot),
		table.freeze({ id = "N", x = 22, z = 75 } :: Spot),
		table.freeze({ id = "S", x = 22, z = 101 } :: Spot),
		table.freeze({ id = "W", x = 9, z = 88 } :: Spot),
	}),

	-- the hit test: the camera's centre ray at the fire tick, against the Biped hitbox grown by the input's margin
	RayLength = 60,
	Hitbox = table.freeze({ x = 2.6, y = 11, z = 2.7 }),
	Margins = table.freeze({ Mouse = 0.6, Gamepad = 1.2, Touch = 1.8 }),

	-- the authority
	LateGrace = 0.35, -- a shot must arrive within this of the window's end
	OriginTolerance = 3, -- studs from the holder's head
	LookWindow = 0.15, -- seconds either side of the shot's client time
	LookCos = 0.9063077870366499, -- cos 25 degrees: the shot's direction must be this close to a relayed look
	MaxRewind = 0.5, -- the monster's pose is rewound by one-way latency + render delay, at most this

	-- the holder
	LockboxSeconds = 1.0,
	TakeSeconds = 0.6, -- taking the revolver, or picking it up
	LoadSeconds = 1.6, -- cosmetic: the load in the hand
	ArmSeconds = 0.6, -- taken during the standoff, it can fire this long after
	LowerSeconds = 1.5, -- hold Lower this long to lower the gun
	DropTapSeconds = 0.3, -- a tap under this drops it (passing it on)
	TakeLoweredSeconds = 1.2, -- a teammate takes the gun from a lowered holder
	IdleSeconds = 4, -- no look, move or aim input this long during the standoff drops it at the holder's feet
}

-- What the web needs (meta.endingConfig): every number and table above, as plain tables.
function EndingConfig.exportMeta(): { [string]: any }
	local function plain(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local out = {}
		for k, v in value do
			out[k] = plain(v)
		end
		return out
	end
	local meta: { [string]: any } = {}
	for key, value in EndingConfig :: { [string]: any } do
		if type(value) ~= "function" then
			meta[key] = plain(value)
		end
	end
	return meta
end

return table.freeze(EndingConfig)
