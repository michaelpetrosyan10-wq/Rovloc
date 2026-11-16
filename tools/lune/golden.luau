-- Prints what a rule module's golden rows answer now, as the Luau table its EXPECT pins them in.
--
--   lune run tools/lune/golden.luau <module path> [out file]
--   lune run tools/lune/golden.luau ReplicatedStorage.Shared.Sequence.CinematicTracks /tmp/expect.luau
--
-- A rule module pins each golden row's answer in its own EXPECT table (the spec asserts the module still gives it, the
-- export writes it for the website's port). When the data a rule reads is changed on purpose (a timeline retimed), this
-- prints the table to paste over the old one: every row of golden() in order, each function called with the row's
-- arguments, numbers with 17 significant digits, keys in name order. Read the difference before pasting it: a row that
-- moved without a reason is a bug, not a new expectation. The place is built fresh with `rojo build`
-- (default.project.json); run it from the repo root, then `stylua` the module.

local fs = require("@lune/fs")
local process = require("@lune/process")

local Harness = require("./harness")

local modulePath = process.args[1]
if not modulePath then
	print("usage: lune run tools/lune/golden.luau <module path> [out file]")
	process.exit(2)
end

local tmpDir = process.env.TMPDIR or "/tmp"
local placePath = tmpDir .. "/rovloc-golden.rbxl"
local build = process.exec("rojo", { "build", "default.project.json", "-o", placePath })
if not build.ok then
	print(build.stderr)
	process.exit(2)
end

local h = Harness.load(placePath, { server = true })
local module = h.require(modulePath)
assert(type(module) == "table" and type(module.golden) == "function", modulePath .. " has no golden()")

local function isArray(value: { [any]: any }): boolean
	local count = 0
	for _ in value do
		count += 1
	end
	return count == #value
end

-- The keys a table has, through every level (what a strict table literal's shape is).
local function shape(value: any, prefix: string, into: { [string]: boolean })
	if type(value) ~= "table" or isArray(value) then
		return
	end
	for key, item in value do
		into[prefix .. tostring(key)] = true
		shape(item, prefix .. tostring(key) .. ".", into)
	end
end

-- Whether `value` lacks a key the list's first element has: such an element needs `:: any` beside the first.
local function otherShape(first: any, value: any): boolean
	local a, b = {}, {}
	shape(first, "", a)
	shape(value, "", b)
	for key in a do
		if not b[key] then
			return true
		end
	end
	return false
end

local function literal(value: any, indent: string): string
	local kind = type(value)
	if kind == "number" then
		return string.format("%.17g", value)
	elseif kind == "string" then
		return string.format("%q", value)
	elseif kind ~= "table" then
		return tostring(value)
	end
	local inner = indent .. "\t"
	local lines = {}
	if isArray(value) then
		for i, item in value do
			local cast = if i > 1 and type(item) == "table" and otherShape(value[1], item) then " :: any" else ""
			table.insert(lines, inner .. literal(item, inner) .. cast .. ",")
		end
	else
		local keys = {}
		for key in value do
			table.insert(keys, key)
		end
		table.sort(keys)
		for _, key in keys do
			local name = if string.match(key, "^[%a_][%w_]*$") then key else string.format("[%q]", key)
			table.insert(lines, inner .. name .. " = " .. literal(value[key], inner) .. ",")
		end
	end
	if #lines == 0 then
		return "{}"
	end
	return "{\n" .. table.concat(lines, "\n") .. "\n" .. indent .. "}"
end

local out = { "local EXPECT: { [string]: any } = {" }
for _, row in module.golden() do
	local fn = module[row.fn]
	assert(type(fn) == "function", row.name .. ": no function " .. tostring(row.fn))
	local got = fn(table.unpack(row.args))
	table.insert(out, string.format("\t[%q] = %s,", row.name, literal(got, "\t")))
end
table.insert(out, "}")
local text = table.concat(out, "\n") .. "\n"
if process.args[2] then
	fs.writeFile(process.args[2], text)
	print(string.format("%d rows -> %s", #module.golden(), process.args[2]))
else
	print(text)
end
