--!strict
-- Dependency-free spec runner shared by the Studio runner (Runner.server.luau) and the Lune CLI
-- (tools/lune/check.luau specs). A spec is a ModuleScript named "<Name>.spec" returning
-- { [testName]: (t: Expect) -> () }. Tests run in name order; a throwing test fails without stopping the rest.
-- `parked` (tests/PortPending.luau: "<Module>.spec / <test name>" -> reason) names tests that are skipped and counted
-- as parked; an entry that names no test is a failure (a stale entry).

export type Expect = {
	eq: (actual: any, expected: any, message: string?) -> (),
	near: (actual: number, expected: number, epsilon: number, message: string?) -> (),
	truthy: (value: any, message: string?) -> (),
	falsy: (value: any, message: string?) -> (),
	fail: (message: string) -> (),
	throws: (fn: () -> (), message: string?) -> (),
}

export type Report = {
	passed: number,
	failed: number,
	parked: number,
	lines: { string },
}

local SpecRunner = {}

local function describe(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

local expect: Expect = {
	eq = function(actual: any, expected: any, message: string?)
		if actual ~= expected then
			error(
				string.format(
					"%sexpected %s, got %s",
					if message then message .. ": " else "",
					describe(expected),
					describe(actual)
				),
				2
			)
		end
	end,
	near = function(actual: number, expected: number, epsilon: number, message: string?)
		if math.abs(actual - expected) > epsilon then
			error(
				string.format(
					"%sexpected %s within %s, got %s",
					if message then message .. ": " else "",
					tostring(expected),
					tostring(epsilon),
					tostring(actual)
				),
				2
			)
		end
	end,
	truthy = function(value: any, message: string?)
		if not value then
			error(message or "expected a truthy value", 2)
		end
	end,
	falsy = function(value: any, message: string?)
		if value then
			error(message or "expected a falsy value", 2)
		end
	end,
	fail = function(message: string)
		error(message, 2)
	end,
	throws = function(fn: () -> (), message: string?)
		local ok = pcall(fn)
		if ok then
			error(message or "expected the function to throw", 2)
		end
	end,
}

function SpecRunner.run(folder: Instance, requireFn: (ModuleScript) -> any, parked: { [string]: string }?): Report
	local report: Report = { passed = 0, failed = 0, parked = 0, lines = {} }
	local skip: { [string]: string } = parked or {}
	local seen: { [string]: boolean } = {}
	local modules: { ModuleScript } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("ModuleScript") and string.sub(child.Name, -5) == ".spec" then
			table.insert(modules, child)
		end
	end
	table.sort(modules, function(a: ModuleScript, b: ModuleScript): boolean
		return a.Name < b.Name
	end)

	for _, module in modules do
		local okLoad, spec = pcall(requireFn, module)
		if not okLoad or type(spec) ~= "table" then
			report.failed += 1
			table.insert(report.lines, string.format("FAIL %s (load): %s", module.Name, tostring(spec)))
			continue
		end
		local names: { string } = {}
		for name in spec :: { [string]: any } do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			local test = (spec :: { [string]: any })[name]
			if type(test) ~= "function" then
				continue
			end
			local key = module.Name .. " / " .. name
			local reason = skip[key]
			if reason ~= nil then
				seen[key] = true
				report.parked += 1
				table.insert(report.lines, string.format("park %s: %s", key, reason))
				continue
			end
			local ok, err = pcall(test, expect)
			if ok then
				report.passed += 1
				table.insert(report.lines, string.format("ok   %s / %s", module.Name, name))
			else
				report.failed += 1
				table.insert(report.lines, string.format("FAIL %s / %s: %s", module.Name, name, tostring(err)))
			end
		end
	end
	local stale: { string } = {}
	for key in skip do
		if not seen[key] then
			table.insert(stale, key)
		end
	end
	table.sort(stale)
	for _, key in stale do
		report.failed += 1
		table.insert(report.lines, string.format("FAIL %s: parked in PortPending but no such test", key))
	end
	table.insert(
		report.lines,
		string.format("%d passed, %d failed, %d parked", report.passed, report.failed, report.parked)
	)
	return report
end

return SpecRunner
