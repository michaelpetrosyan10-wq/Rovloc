--!strict
-- CastConfig: who the story's actors are and how they look (docs/design/game-spec-v2.md 2.2). The avatar renderer
-- dresses an actor from its costume; the Creature rig plays the two monsters with their host's voice; the mask crawler
-- is the Tall Man's mask scaled down on finger-legs. Exported as meta.castConfig (exportMeta); the website's cutscene
-- package reads it, the Roblox port the same table.
--
--   Costume    body colours per R15 group (Head, Torso, Arms, Legs, Feet) and the pieces worn over them, each a kind
--              the renderer builds (Beanie, Backpack, Patch, KeyRing, HearingAid, Torch, Laces, Belt, Collar) with
--              its colour and, for a patch, its text. Colours are 0..255 RGB triples.
--   Voice      the spoken lines' voice on each platform: the web's speech pitch / rate, Roblox's Pitch / Speed.
--   Monster    a Creature rig played as an actor: its host (whose voice it twists) and that voice.
--   Crawler    the mask crawler's numbers (studs, seconds): the mask at MaskScale of the Tall Man's, legs of
--              LegSegments segments, LegLength long in all, splayed LegSpread degrees from the rim, clicking every
--              ClickInterval while it moves; one music-box tick when it opens (TickPitch).

export type Rgb = { number }

export type Voice = {
	web: { pitch: number, rate: number },
	roblox: { pitch: number, speed: number },
}

export type Wear = {
	kind: string,
	color: Rgb,
	text: string?,
}

export type Costume = {
	body: { Head: Rgb, Torso: Rgb, Arms: Rgb, Legs: Rgb, Feet: Rgb },
	wear: { Wear },
}

export type Actor = {
	name: string,
	age: number,
	costume: Costume,
	voice: Voice,
	catchphrase: string?,
}

export type Monster = {
	host: string, -- the Actor whose voice it twists
	rig: string, -- Builder rig kind
	voice: Voice,
}

local SKIN_DANNY: Rgb = { 196, 150, 118 }
local SKIN_GUS: Rgb = { 170, 128, 104 }

local function freezeDeep<T>(value: T): T
	if type(value) == "table" and not table.isfrozen(value :: any) then
		for _, child in value :: any do
			freezeDeep(child)
		end
		table.freeze(value :: any)
	end
	return value
end

local CastConfig = {}

CastConfig.Actors = freezeDeep({
	Danny = {
		name = "Danny Reyes",
		age = 16,
		catchphrase = "Wait up, you guys!",
		costume = {
			body = {
				Head = SKIN_DANNY,
				Torso = { 122, 124, 128 }, -- the grey hoodie
				Arms = { 122, 124, 128 },
				Legs = { 58, 64, 76 }, -- jeans
				Feet = { 226, 226, 222 }, -- white sneakers
			},
			wear = {
				{ kind = "Beanie", color = { 176, 34, 30 } }, -- the red beanie
				{ kind = "Backpack", color = { 44, 46, 50 } },
				{ kind = "Laces", color = { 236, 236, 232 } },
			},
		},
		voice = { web = { pitch = 1.15, rate = 1.05 }, roblox = { pitch = 1.0, speed = 1.05 } },
	},
	Gus = {
		name = "Gus Pruitt",
		age = 58,
		costume = {
			body = {
				Head = SKIN_GUS,
				Torso = { 98, 102, 100 }, -- the grey jumpsuit
				Arms = { 98, 102, 100 },
				Legs = { 98, 102, 100 },
				Feet = { 58, 50, 44 }, -- work boots
			},
			wear = {
				{ kind = "Patch", color = { 228, 228, 222 }, text = "GUS" },
				{ kind = "Belt", color = { 40, 36, 32 } },
				{ kind = "KeyRing", color = { 168, 170, 172 } },
				{ kind = "HearingAid", color = { 204, 176, 156 } },
				{ kind = "Torch", color = { 36, 38, 40 } },
				{ kind = "Collar", color = { 86, 90, 88 } },
			},
		},
		voice = { web = { pitch = 0.7, rate = 0.9 }, roblox = { pitch = 0.8, speed = 0.9 } },
	},
} :: { [string]: Actor })

-- The two monsters: the Creature rig as the Tall Man (Danny) and the Tall Janitor (Gus)
CastConfig.Monsters = freezeDeep({
	TallMan = {
		host = "Danny",
		rig = "Creature",
		voice = { web = { pitch = 0.4, rate = 0.82 }, roblox = { pitch = 0.6, speed = 0.85 } },
	},
	TallJanitor = {
		host = "Gus",
		rig = "Creature",
		voice = { web = { pitch = 0.25, rate = 0.78 }, roblox = { pitch = 0.5, speed = 0.8 } },
	},
} :: { [string]: Monster })

-- The mask crawler (the opening's S5-S8): the Tall Man's mask at 0.45 scale on eight pale two-segment finger-legs
CastConfig.Crawler = freezeDeep({
	MaskScale = 0.45,
	Height = 0.6, -- about this tall standing on its legs
	Legs = 8,
	LegSegments = 2,
	LegLength = 0.9,
	LegThickness = 0.06,
	LegSpread = 38,
	LegColor = { 222, 214, 204 },
	ClickInterval = 0.11,
	TickPitch = 1.6,
	LatchSeconds = 0.25, -- S8: it springs onto Danny's face this fast
})

-- The cast as plain data for the website (world.json meta.castConfig).
function CastConfig.exportMeta(): { [string]: any }
	local function plain(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local out: { [any]: any } = {}
		for key, item in value do
			out[key] = plain(item)
		end
		return out
	end
	return {
		Actors = plain(CastConfig.Actors),
		Monsters = plain(CastConfig.Monsters),
		Crawler = plain(CastConfig.Crawler),
	}
end

return table.freeze(CastConfig)
