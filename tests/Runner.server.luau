--!strict
-- Studio entry point for the specs (only present in places built from test.project.json).
-- Prints one line per test, then a summary; sets ServerScriptService.Tests:SpecsFailed for automation.

local SpecRunner = require(script.Parent.SpecRunner)

local specs = script.Parent:FindFirstChild("Specs")
if not specs then
	warn("[Specs] no Specs folder")
	return
end

local report = SpecRunner.run(specs, require)
for _, line in report.lines do
	if string.sub(line, 1, 4) == "FAIL" then
		warn("[Specs] " .. line)
	else
		print("[Specs] " .. line)
	end
end
local container = script.Parent :: Instance
container:SetAttribute("SpecsPassed", report.passed)
container:SetAttribute("SpecsFailed", report.failed)
