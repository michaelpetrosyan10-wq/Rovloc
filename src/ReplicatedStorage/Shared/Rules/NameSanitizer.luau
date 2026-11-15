--!strict
-- NameSanitizer: how a player's name becomes what the story and the monster may say and show (docs/design/
-- game-spec-v2.md 3.4, 2.3; StoryConfig.Names). One pure module on both platforms (invariant I11: the website's port,
-- web/src/game/rules/names.js, replays golden()); Roblox adds TextService filtering after it.
--
--   tokens(raw)          the input split at spaces, underscores, digits and CamelCase boundaries (a lower letter then
--                        an upper one; an upper one that starts a capitalised word after other capitals)
--   normalise(raw)       the whole input lower-cased, leetspeak read as letters (StoryConfig.Names.Leet), every
--                        other character but a-z dropped: what the blocklist's stems are looked for in
--   blocked(raw)         normalise(raw) on the blocklist or holding a stem anywhere, or the first token (lower case)
--                        on the blocklist or holding a stem
--   sanitize(raw)        the first token when it is letters, ' and - only (starting with a letter), Min..Max long and
--                        not blocked, capitalised (first letter upper, the rest lower); "" otherwise: the nameless twin
--   slots(text)          the name slots a line uses, in order ({P1}..{P4}, {you}, {shooter})
--   fill(text, names)    the line with every slot filled from names (already sanitized); "" when one is missing or
--                        empty
--   compose(line, names, sayNames)  what a page shows and says for a line {text, twin?}: the filled text, or the twin
--                        when names are off or one is missing (the text itself when it has no slot)
--
-- Pure: ASCII only (bytes), no engine, clock or randomness.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StoryConfig = require(ReplicatedStorage.Shared.Config.StoryConfig)

export type GoldenRow = { name: string, fn: string, args: { any }, expect: any }
export type Line = { text: string, twin: string? }

local NameSanitizer = {}

local function isUpper(b: number): boolean
	return b >= 65 and b <= 90
end

local function isLower(b: number): boolean
	return b >= 97 and b <= 122
end

local function isLetter(b: number): boolean
	return isUpper(b) or isLower(b)
end

local function isSeparator(b: number): boolean
	-- space, tab, newline, carriage return, underscore, a digit
	return b == 32 or b == 9 or b == 10 or b == 13 or b == 95 or (b >= 48 and b <= 57)
end

function NameSanitizer.tokens(raw: string): { string }
	local out: { string } = {}
	local current: { string } = {}
	local function flush()
		if #current > 0 then
			table.insert(out, table.concat(current))
			table.clear(current)
		end
	end
	local n = #raw
	for i = 1, n do
		local b = string.byte(raw, i)
		if isSeparator(b) then
			flush()
		else
			if isUpper(b) and #current > 0 then
				local prev = string.byte(raw, i - 1)
				local nextByte = if i < n then string.byte(raw, i + 1) else 0
				if isLower(prev) or (isUpper(prev) and isLower(nextByte)) then
					flush()
				end
			end
			table.insert(current, string.sub(raw, i, i))
		end
	end
	flush()
	return out
end

function NameSanitizer.normalise(raw: string): string
	local leet = StoryConfig.Names.Leet :: { [string]: string }
	local out: { string } = {}
	local lower = string.lower(raw)
	for i = 1, #lower do
		local c = string.sub(lower, i, i)
		local mapped = leet[c] or c
		if isLower(string.byte(mapped)) then
			table.insert(out, mapped)
		end
	end
	return table.concat(out)
end

local function holdsStem(text: string): boolean
	for _, stem in StoryConfig.Names.Stems do
		if string.find(text, stem, 1, true) then
			return true
		end
	end
	return false
end

local function onList(word: string): boolean
	for _, blocked in StoryConfig.Names.Blocked do
		if word == blocked then
			return true
		end
	end
	return false
end

function NameSanitizer.blocked(raw: string): boolean
	local whole = NameSanitizer.normalise(raw)
	if holdsStem(whole) or onList(whole) then
		return true
	end
	local first = NameSanitizer.tokens(raw)[1]
	if not first then
		return false
	end
	local word = NameSanitizer.normalise(first)
	return holdsStem(word) or onList(word)
end

function NameSanitizer.sanitize(raw: string): string
	local first = NameSanitizer.tokens(raw)[1]
	if not first then
		return ""
	end
	local names = StoryConfig.Names
	if #first < names.Min or #first > names.Max or not isLetter(string.byte(first, 1)) then
		return ""
	end
	for i = 2, #first do
		local b = string.byte(first, i)
		if not (isLetter(b) or b == 39 or b == 45) then
			return ""
		end
	end
	if NameSanitizer.blocked(raw) then
		return ""
	end
	return string.upper(string.sub(first, 1, 1)) .. string.lower(string.sub(first, 2))
end

function NameSanitizer.slots(text: string): { string }
	local out: { string } = {}
	for slot in string.gmatch(text, "{(%w+)}") do
		table.insert(out, slot)
	end
	return out
end

function NameSanitizer.fill(text: string, names: { [string]: string }): string
	for _, slot in NameSanitizer.slots(text) do
		local name = names[slot]
		if type(name) ~= "string" or name == "" then
			return ""
		end
	end
	return (string.gsub(text, "{(%w+)}", function(slot: string): string
		return names[slot]
	end))
end

function NameSanitizer.compose(line: Line, names: { [string]: string }, sayNames: boolean): string
	if #NameSanitizer.slots(line.text) == 0 then
		return line.text
	end
	local filled = if sayNames then NameSanitizer.fill(line.text, names) else ""
	if filled ~= "" then
		return filled
	end
	return line.twin or ""
end

-- The golden rows (the export writes them for the website's port): what each function returns for its args.
function NameSanitizer.golden(): { GoldenRow }
	local rows: { GoldenRow } = {}
	local function row(name: string, fn: string, args: { any }, expect: any)
		table.insert(rows, { name = name, fn = fn, args = args, expect = expect })
	end
	row("tokens: CamelCase and digits", "tokens", { "xXDarkLord99Xx" }, { "x", "X", "Dark", "Lord", "Xx" })
	row("tokens: an acronym before a word", "tokens", { "NASAPilot" }, { "NASA", "Pilot" })
	row("tokens: underscores and spaces", "tokens", { "mary_jane  O'Brien" }, { "mary", "jane", "O'Brien" })
	row("tokens: nothing", "tokens", { "  42 _" }, {})
	row("normalise: leetspeak", "normalise", { "5h1T_H3ad" }, "shithead")
	row("normalise: symbols", "normalise", { "B@d $ue!" }, "badsuei")
	row("blocked: a stem across the separators", "blocked", { "Bob_Fu_ck" }, true)
	row("blocked: a blocked first word", "blocked", { "Ass Kicker" }, true)
	row("blocked: a name holding a short word", "blocked", { "Cassandra" }, false)
	row("blocked: leetspeak spelling a blocked word", "blocked", { "D1ck" }, true)
	row("blocked: a clean name", "blocked", { "Danny" }, false)
	row("sanitize: a plain name", "sanitize", { "jordan" }, "Jordan")
	row("sanitize: CamelCase gamer tag", "sanitize", { "ShadowHunter_2009" }, "Shadow")
	row("sanitize: a leading lone letter", "sanitize", { "xXDarkLord99Xx" }, "")
	row("sanitize: too short", "sanitize", { "Q" }, "")
	row("sanitize: too long", "sanitize", { "Bartholomewski" }, "")
	row("sanitize: an apostrophe and a hyphen", "sanitize", { "o'neil-ray" }, "O'neil-ray")
	row("sanitize: punctuation", "sanitize", { "Sam!" }, "")
	row("sanitize: blocked", "sanitize", { "Nazi" }, "")
	row("sanitize: a stem behind leetspeak", "sanitize", { "Ana fvck sh1t" }, "")
	row("sanitize: empty", "sanitize", { "" }, "")
	row("slots: two", "slots", { "{P2}, you're paying, {you}." }, { "P2", "you" })
	row("slots: none", "slots", { "Worth the detention." }, {})
	row("fill: every slot", "fill", { "{P1}, back me up.", { P1 = "Maya" } }, "Maya, back me up.")
	row("fill: a missing name", "fill", { "{P2}, you're paying.", { P1 = "Maya" } }, "")
	row("fill: an empty name", "fill", { "I know you're close, {you}.", { you = "" } }, "")
	row(
		"compose: names on",
		"compose",
		{ { text = "I know you're close, {you}.", twin = "I know you're close." }, { you = "Theo" }, true },
		"I know you're close, Theo."
	)
	row(
		"compose: names off",
		"compose",
		{ { text = "I know you're close, {you}.", twin = "I know you're close." }, { you = "Theo" }, false },
		"I know you're close."
	)
	row(
		"compose: a filtered name",
		"compose",
		{ { text = "{you}…", twin = "Still here…" }, { you = "" }, true },
		"Still here…"
	)
	row("compose: no slot", "compose", { { text = "Worth the detention." }, {}, false }, "Worth the detention.")
	return rows
end

return table.freeze(NameSanitizer)
