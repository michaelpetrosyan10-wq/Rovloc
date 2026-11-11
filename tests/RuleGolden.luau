--!strict
-- RuleGolden: what the spec of every pure rule module (Shared/Rules) asserts about it, shared by those specs:
--   * golden(): every row { name, fn, args, expect } is named once, names a function of the module, holds plain
--     JSON data (strings, finite numbers, booleans, arrays and string-keyed tables: what golden.json carries to the
--     website's port), and the function returns exactly `expect` for `args`; every function has at least 12 rows;
--   * purity: the module's code (comments and strings aside) uses no engine type, service, clock, task or randomness:
--     its one engine call is the require path (`game:GetService("ReplicatedStorage")`).

local SpecRunner = require(script.Parent.SpecRunner)

type Expect = SpecRunner.Expect

export type Row = { name: string, fn: string, args: { any }, expect: any }

local RuleGolden = {}

RuleGolden.MinRows = 12

-- Whether `value` is plain JSON data; else the path to the first part that is not.
function RuleGolden.plain(value: any, path: string?): (boolean, string)
	local here = path or "value"
	local kind = type(value)
	if kind == "string" or kind == "boolean" then
		return true, here
	elseif kind == "number" then
		return value == value and value ~= math.huge and value ~= -math.huge, here
	elseif kind ~= "table" then
		return false, here .. " is a " .. typeof(value)
	end
	local count = 0
	for _ in value do
		count += 1
	end
	local isArray = count == #value
	for key, item in value do
		if not isArray and type(key) ~= "string" then
			return false, here .. " has a non-string key"
		end
		local ok, at = RuleGolden.plain(item, here .. "." .. tostring(key))
		if not ok then
			return false, at
		end
	end
	return true, here
end

-- Whether `a` and `b` are the same plain data; else where they differ.
function RuleGolden.same(a: any, b: any, path: string?): (boolean, string)
	local here = path or "value"
	if type(a) ~= "table" or type(b) ~= "table" then
		if a == b then
			return true, here
		end
		return false, string.format("%s: %s vs %s", here, tostring(a), tostring(b))
	end
	for key, item in a do
		local ok, at = RuleGolden.same(item, b[key], here .. "." .. tostring(key))
		if not ok then
			return false, at
		end
	end
	for key in b do
		if a[key] == nil then
			return false, here .. "." .. tostring(key) .. " is missing"
		end
	end
	return true, here
end

-- Asserts every golden row of `module` (named `name`) and the row counts.
function RuleGolden.check(t: Expect, module: any, name: string): { Row }
	local rows: { Row } = module.golden()
	t.truthy(type(rows) == "table" and #rows > 0, name .. " has golden rows")
	local seen: { [string]: boolean } = {}
	local perFn: { [string]: number } = {}
	for _, row in rows do
		t.truthy(type(row.name) == "string" and not seen[row.name], name .. ": row named once: " .. tostring(row.name))
		seen[row.name] = true
		local fn = module[row.fn]
		t.truthy(type(fn) == "function" and row.fn ~= "golden", row.name .. ": " .. tostring(row.fn) .. " is a rule")
		local ok, at = RuleGolden.plain(row.args, "args")
		t.truthy(ok and #row.args > 0, row.name .. ": plain arguments (" .. at .. ")")
		ok, at = RuleGolden.plain(row.expect, "expect")
		t.truthy(ok, row.name .. ": a plain answer (" .. at .. ")")
		if type(fn) == "function" then
			local got = fn(table.unpack(row.args))
			local same, where = RuleGolden.same(got, row.expect)
			t.truthy(same, row.name .. ": " .. where)
		end
		perFn[row.fn] = (perFn[row.fn] or 0) + 1
	end
	for key, value in module :: { [string]: any } do
		if type(value) == "function" and key ~= "golden" then
			t.truthy(
				(perFn[key] or 0) >= RuleGolden.MinRows,
				string.format("%s.%s: %d golden rows", name, key, perFn[key] or 0)
			)
		end
	end
	return rows
end

-- `source` with comments and string contents blanked (newlines kept).
local function codeOnly(source: string): string
	local out: { string } = {}
	local i, n = 1, #source
	local function blank(text: string): string
		return (string.gsub(text, "[^\n]", " "))
	end
	while i <= n do
		local c = string.sub(source, i, i)
		if string.sub(source, i, i + 1) == "--" then
			local level = string.match(source, "^%[(=*)%[", i + 2)
			local stop: number
			if level then
				local close = string.find(source, "]" .. level .. "]", i + 4 + #level, true)
				stop = if close then close + #level + 1 else n
			else
				stop = (string.find(source, "\n", i, true) or n + 1) - 1
			end
			table.insert(out, blank(string.sub(source, i, stop)))
			i = stop + 1
		elseif c == '"' or c == "'" or c == "`" then
			local j = i + 1
			while j <= n do
				local d = string.sub(source, j, j)
				if d == "\\" then
					j += 2
				elseif d == c or d == "\n" then
					break
				else
					j += 1
				end
			end
			table.insert(out, c .. blank(string.sub(source, i + 1, j - 1)) .. c)
			i = j + 1
		else
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end

local REQUIRE_PATH = 'local ReplicatedStorage = game:GetService("ReplicatedStorage")'

local BANNED: { { pattern: string, why: string } } = {
	{ pattern = "%f[%w_]game%f[^%w_]", why = "the engine's DataModel (only the require path may name it)" },
	{ pattern = "%f[%w_]workspace%f[^%w_]", why = "workspace" },
	{ pattern = "%f[%w_]Workspace%f[^%w_]", why = "Workspace" },
	{ pattern = "%f[%w_]Instance%f[^%w_]", why = "Instance" },
	{ pattern = "%f[%w_]Vector[23]%f[^%w_]", why = "an engine vector" },
	{ pattern = "%f[%w_]CFrame%f[^%w_]", why = "CFrame" },
	{ pattern = "%f[%w_]Color3%f[^%w_]", why = "Color3" },
	{ pattern = "%f[%w_]UDim2?%f[^%w_]", why = "UDim" },
	{ pattern = "%f[%w_]Enum%f[^%w_]", why = "the engine's Enum" },
	{ pattern = "%f[%w_]task%s*%.", why = "task" },
	{ pattern = "%f[%w_]os%s*%.", why = "os (a clock)" },
	{ pattern = "%f[%w_]tick%s*%(", why = "tick (a clock)" },
	{ pattern = "%f[%w_]wait%s*%(", why = "wait" },
	{ pattern = "%f[%w_]DateTime%f[^%w_]", why = "DateTime" },
	{ pattern = "%f[%w_]math%s*%.%s*random", why = "math.random" },
	{ pattern = "%f[%w_]Random%f[^%w_]", why = "the engine's Random" },
	{ pattern = "%f[%w_]script%f[^%w_]", why = "script" },
}

-- Every engine use in `source` outside the require path: "line N: why".
function RuleGolden.impurities(source: string): { string }
	local at, stop = string.find(source, REQUIRE_PATH, 1, true)
	local rest = if at then string.sub(source, 1, at - 1) .. string.sub(source, (stop :: number) + 1) else source
	local code = codeOnly(rest)
	local out: { string } = {}
	for _, rule in BANNED do
		local start = 1
		while true do
			local first, last = string.find(code, rule.pattern, start)
			if not first then
				break
			end
			local _, lines = string.gsub(string.sub(code, 1, first), "\n", "")
			table.insert(out, string.format("line %d: %s", lines + 1, rule.why))
			start = (last :: number) + 1
		end
	end
	return out
end

-- Asserts `module` (a ModuleScript) is pure.
function RuleGolden.checkPure(t: Expect, module: ModuleScript)
	local ok, source = pcall(function(): string
		return module.Source
	end)
	t.truthy(ok and source ~= "", module.Name .. ": source readable (the lint runs in Lune)")
	if ok then
		local found = RuleGolden.impurities(source)
		t.eq(#found, 0, module.Name .. "\n  " .. table.concat(found, "\n  "))
	end
end

return table.freeze(RuleGolden)
