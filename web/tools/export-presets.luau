-- Rovloc Web: the audio presets, generated from the Roblox recipes value for value.
--
--   cd web && lune run tools/export-presets.luau        (npm run presets)
--
-- The place is built fresh with `rojo build`; SynthPresets, AudioBuses and CreatureConfig are required in the Lune
-- harness and written as web/src/engine/audio/presets.js: every preset's shared metadata (bus, roll-off, priority,
-- voices, caption, loop, repeat, duck) and its layer recipe, the beds' stingers, the default roll-offs, the acoustic
-- environments, and the Creature's own footsteps (which of its step sounds each surface plays, and how far a footfall
-- is heard: CreatureConfig.Footfalls). The presets the website defines in its own tables are left out (below). The
-- JSON's keys are sorted, so the same recipes give the same file.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Harness = require("../../tools/lune/harness")

local repo = if fs.isDir("../src") and fs.isFile("../default.project.json") then ".." else "."
local web = if repo == ".." then "." else "web"
local cacheDir = web .. "/build/cache"
fs.writeDir(cacheDir)
local placePath = cacheDir .. "/rovloc-presets.rbxl"

local build = process.exec("rojo", { "build", repo .. "/default.project.json", "-o", placePath })
if not build.ok then
	print(build.stderr)
	process.exit(2)
end

local h = Harness.load(placePath, { server = true })
local SynthPresets = h.require("ReplicatedStorage.Shared.Audio.SynthPresets")
local AudioBuses = h.require("ReplicatedStorage.Shared.Audio.AudioBuses")
local CreatureConfig = h.require("ReplicatedStorage.Shared.Config.CreatureConfig")
local Strings = h.require("ReplicatedStorage.Shared.Strings")
fs.removeFile(placePath)

local problems = SynthPresets.validate()
if #problems > 0 then
	print("SynthPresets.validate() failed:\n  " .. table.concat(problems, "\n  "))
	process.exit(1)
end

-- A frozen table as plain data.
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

-- The presets the website builds from its own tables (SynthPresets carries the Roblox port's versions of them, whose
-- recipes differ where the engines do): they stay out, so the website's own stay the ones it plays.
local OWN_TABLES = { "src/creature/sounds.js", "src/game/objectives/sounds.js" }
local own: { [string]: boolean } = {}
for _, file in OWN_TABLES do
	local found = 0
	for name in string.gmatch(fs.readFile(web .. "/" .. file), "\n  (%u%w+): {") do
		own[name] = true
		found += 1
	end
	if found == 0 then
		print(file .. ": no preset table found (its presets would be overwritten by the Roblox port's)")
		process.exit(1)
	end
end

-- Each preset with its caption's text beside the Strings key (the website shows the text).
local presets = {}
local count = 0
for name, preset in SynthPresets.Presets do
	if own[name] then
		continue
	end
	local copy = plain(preset)
	if copy.caption then
		copy.captionText = Strings.get(copy.caption)
	end
	presets[name] = copy
	count += 1
end

local function json(value: any): string
	return serde.encode("json", value, false)
end

local lines = {
	"// GENERATED from src/ReplicatedStorage/Shared/Audio/SynthPresets.luau, AudioBuses.luau and Config/CreatureConfig.luau",
	"// (the Roblox recipes and shared numbers, value for value) by web/tools/export-presets.luau (npm run presets).",
	"// Do not edit by hand: change the Luau and regenerate.",
	"//",
	"// presets:      name -> { bus, layers[], rollOff?, priority, maxVoices, caption?, captionText?, repeat?, looped?,",
	"//                         duck?[], space?[] } (see SynthPresets.luau's header for every field). A name with a",
	"//                         rendered file (web/sounds) plays the file with this metadata; the layers are the recipe",
	"//                         a name without one falls back to",
	"// beds:         ambience bed -> stingers [{ preset, interval {min,max}, distance? {min,max}, volume? }]",
	"// environments: AcousticPreset -> { effects [Equalizer, Chorus, Reverb, Echo], ambience (EQ), body (EQ), gain }",
	"// creature steps: the surface -> which of its own step sounds it plays there (CreatureStepWalk<it> /",
	"//               CreatureStepChase<it>), and CreatureConfig.Footfalls (their roll-off; how far a footfall is heard)",
	"",
	"export const Presets = " .. json(presets) .. ";",
	"",
	"export const Beds = " .. json(plain(SynthPresets.Beds)) .. ";",
	"",
	"export const DefaultRollOff = " .. json(plain(SynthPresets.DefaultRollOff)) .. ";",
	"",
	"export const Environments = " .. json(plain(AudioBuses.Environments)) .. ";",
	"",
	"export const CreatureStepSurface = " .. json(plain(SynthPresets.CreatureStepSurface)) .. ";",
	"",
	"export const CreatureFootfalls = " .. json(plain(CreatureConfig.Footfalls)) .. ";",
	"",
}
local outPath = web .. "/src/engine/audio/presets.js"
fs.writeFile(outPath, table.concat(lines, "\n"))
print(`presets: {count} presets -> {outPath}`)
