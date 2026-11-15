--!strict
-- NameSanitizer (docs/design/game-spec-v2.md 3.4, 2.3; invariant I11): every golden row, then the spec's rule asserted
-- on its own (the first token after splitting CamelCase, underscores and digits; letters, ' and - only; 2 to 12
-- characters; the blocklist with leetspeak normalised; otherwise the nameless twin), and the module pure.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NameSanitizer = require(ReplicatedStorage.Shared.Rules.NameSanitizer)
local RuleGolden = require(script.Parent.Parent.RuleGolden)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

return {
	["golden rows: every function answers its rows, at least 12, plain data"] = function(t: Expect)
		local rows = RuleGolden.check(t, NameSanitizer, "NameSanitizer")
		t.truthy(#rows >= 12, "at least twelve rows")
	end,

	["pure: no engine, clock or randomness"] = function(t: Expect)
		RuleGolden.checkPure(t, ReplicatedStorage.Shared.Rules.NameSanitizer)
	end,

	["the first token: CamelCase, underscores and digits split it"] = function(t: Expect)
		t.eq(NameSanitizer.sanitize("MayaRivers"), "Maya")
		t.eq(NameSanitizer.sanitize("theo_2010"), "Theo")
		t.eq(NameSanitizer.sanitize("Sam Okafor"), "Sam")
		t.eq(NameSanitizer.sanitize("99lives"), "Lives", "digits split")
	end,

	["2 to 12 characters, letters, ' and - only"] = function(t: Expect)
		t.eq(NameSanitizer.sanitize("Al"), "Al")
		t.eq(NameSanitizer.sanitize("A"), "")
		t.eq(NameSanitizer.sanitize("Maximiliano"), "Maximiliano", "11")
		t.eq(NameSanitizer.sanitize("Maximilianos"), "Maximilianos", "12")
		t.eq(NameSanitizer.sanitize("Maximilianoss"), "", "13")
		t.eq(NameSanitizer.sanitize("D'Arcy"), "D'arcy")
		t.eq(NameSanitizer.sanitize("Jo-Jo"), "Jo-jo")
		t.eq(NameSanitizer.sanitize("Zoë"), "", "a letter outside A-Z")
		t.eq(NameSanitizer.sanitize("-Ann"), "", "starts with a letter")
	end,

	["the blocklist, leetspeak normalised"] = function(t: Expect)
		t.eq(NameSanitizer.sanitize("sh1t"), "", "a stem behind a digit")
		t.eq(NameSanitizer.sanitize("F_U_C_K"), "", "a stem across underscores")
		t.eq(NameSanitizer.sanitize("Ass"), "")
		t.eq(NameSanitizer.sanitize("Cassandra"), "Cassandra", "a word inside a name is no word")
		t.eq(NameSanitizer.sanitize("Dickens"), "Dickens")
	end,

	["each page its own name: {you} filled per page; names off gives the twin everywhere"] = function(t: Expect)
		local line = { text = "I know you're close, {you}.", twin = "I know you're close." }
		t.eq(NameSanitizer.compose(line, { you = "Ana" }, true), "I know you're close, Ana.")
		t.eq(NameSanitizer.compose(line, { you = "Bo" }, true), "I know you're close, Bo.")
		t.eq(NameSanitizer.compose(line, { you = "Ana" }, false), "I know you're close.")
		t.eq(NameSanitizer.compose(line, { you = NameSanitizer.sanitize("x") }, true), "I know you're close.")
	end,
}
