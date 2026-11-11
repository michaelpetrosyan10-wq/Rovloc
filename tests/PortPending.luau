--!strict
-- PortPending: the runtime specs parked until the Roblox port of the new game (spec v2 §6 cut the old floors and the
-- old roof; the runtime that replaces them comes with the port). SpecRunner skips every test listed here, reports how
-- many it parked, and fails on an entry that names no test (a stale entry).
--
-- Keys are "<Module>.spec / <test name>", exactly as the runner prints them. World, layout, planner, rig and rule
-- specs are never parked here: only runtime behaviour that waits for the port.

local PortPending: { [string]: string } = {}

return table.freeze(PortPending)
