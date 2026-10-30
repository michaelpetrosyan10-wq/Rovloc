--!strict
-- SquadPanel rules (pure): each participant's status (escaped, down, dead, watching, in the lobby, in the stairwell,
-- alive) with its Strings key and colour, the row order (me first, then by name), the change signature, when the panel
-- may show (a run with company, the HUD up, no cutscene / menu, no onboarding), how it rests dim after a while, and how
-- it yields the touch corner to the objective tracker.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local SpecRunner = require(script.Parent.Parent.SpecRunner)
local Strings = require(ReplicatedStorage.Shared.Strings)

local HUDFolder = StarterPlayer.StarterPlayerScripts.Controllers.HUD
local SquadPanel = require(HUDFolder.SquadPanel)
local UIKit = require(HUDFolder.UIKit)

type Expect = SpecRunner.Expect

local function member(userId: number, name: string, lifeState: string, isLocal: boolean?): SquadPanel.Member
	return {
		userId = userId,
		name = name,
		lifeState = lifeState,
		outcome = "Pending",
		inVestibule = false,
		isLocal = isLocal == true,
	}
end

local STATUSES = { "Alive", "Downed", "Dead", "Spectating", "Lobby", "Airlock", "Escaped" } :: { SquadPanel.Status }

return {
	["each participant reads as one status, escaped first"] = function(t: Expect)
		t.eq(SquadPanel.status("Alive", "Pending", false), "Alive")
		t.eq(SquadPanel.status("Downed", "Pending", false), "Downed")
		t.eq(SquadPanel.status("Dead", "Dead", false), "Dead")
		t.eq(SquadPanel.status("Spectating", "Pending", false), "Spectating")
		t.eq(SquadPanel.status("Lobby", "Pending", false), "Lobby")
		t.eq(SquadPanel.status("Alive", "Pending", true), "Airlock", "alive in the exit vestibule")
		t.eq(SquadPanel.status("Downed", "Pending", true), "Downed", "a downed body in the vestibule is still down")
		t.eq(SquadPanel.status("Alive", "Escaped", false), "Escaped")
		t.eq(SquadPanel.status("Spectating", "Escaped", false), "Escaped", "out is out, whatever the camera does")
		t.eq(SquadPanel.status("Alive", nil, false), "Alive")
	end,

	["every status has a string and a colour of its own kind"] = function(t: Expect)
		for _, status: SquadPanel.Status in STATUSES do
			local key = SquadPanel.statusKey(status)
			t.truthy(Strings.has(key), key)
			t.eq(typeof(SquadPanel.statusColor(status)), "Color3", status)
		end
		t.truthy(Strings.has("Squad.Title"))
		t.eq(Strings.get("Squad.You", "Ana"), "Ana (you)")
		local palette = UIKit.Palette
		t.eq(SquadPanel.statusColor("Downed"), palette.Ember, "down reads urgent")
		t.eq(SquadPanel.statusColor("Dead"), palette.Blood)
		t.eq(SquadPanel.statusColor("Escaped"), palette.Moss)
		t.eq(SquadPanel.statusColor("Airlock"), palette.Amber)
		t.eq(SquadPanel.statusColor("Alive"), palette.Bone)
	end,

	["rows put me first, then the squad by name"] = function(t: Expect)
		local rows = SquadPanel.rows({
			member(30, "Zed", "Alive"),
			member(10, "Bo", "Downed"),
			member(20, "Mia", "Alive", true),
			member(5, "Bo", "Dead"),
		})
		t.eq(#rows, 4)
		t.eq(rows[1].userId, 20, "me first")
		t.truthy(rows[1].isLocal)
		t.eq(rows[2].userId, 5, "equal names keep a stable order")
		t.eq(rows[3].userId, 10)
		t.eq(rows[4].userId, 30)
		t.eq(rows[2].status, "Dead")
		t.eq(rows[3].status, "Downed")
		t.eq(#SquadPanel.rows({}), 0)
	end,

	["the signature changes with a status, a name or the roster, and only then"] = function(t: Expect)
		local base = SquadPanel.rows({ member(1, "A", "Alive", true), member(2, "B", "Alive") })
		local same = SquadPanel.rows({ member(2, "B", "Alive"), member(1, "A", "Alive", true) })
		t.eq(SquadPanel.signature(base), SquadPanel.signature(same), "order of discovery does not matter")
		local downed = SquadPanel.rows({ member(1, "A", "Alive", true), member(2, "B", "Downed") })
		t.truthy(SquadPanel.signature(downed) ~= SquadPanel.signature(base), "a teammate going down")
		local joined =
			SquadPanel.rows({ member(1, "A", "Alive", true), member(2, "B", "Alive"), member(3, "C", "Alive") })
		t.truthy(SquadPanel.signature(joined) ~= SquadPanel.signature(base), "someone joining the list")
		local renamed = SquadPanel.rows({ member(1, "A", "Alive", true), member(2, "Bee", "Alive") })
		t.truthy(SquadPanel.signature(renamed) ~= SquadPanel.signature(base), "a display name changing")
	end,

	["it shows only in a run with company, with the HUD, outside menus and cutscenes"] = function(t: Expect)
		t.truthy(SquadPanel.visible(true, 2, true, "OnFoot", false))
		t.truthy(SquadPanel.visible(true, 4, true, "Struggle", false), "a grabbed player still sees the squad")
		t.falsy(SquadPanel.visible(true, 1, true, "OnFoot", false), "hidden while solo")
		t.falsy(SquadPanel.visible(true, 0, true, "OnFoot", false))
		t.falsy(SquadPanel.visible(false, 3, true, "OnFoot", false), "not in the lobby")
		t.falsy(SquadPanel.visible(true, 3, false, "OnFoot", false), "hidden with the HUD")
		t.falsy(SquadPanel.visible(true, 3, true, "Cutscene", false))
		t.falsy(SquadPanel.visible(true, 3, true, "Menu", false))
		t.falsy(SquadPanel.visible(true, 3, true, "OnFoot", true), "not over the onboarding screens")
	end,

	["it holds full after a change, then rests dim instead of vanishing"] = function(t: Expect)
		t.eq(SquadPanel.restAlpha(0), 1)
		t.eq(SquadPanel.restAlpha(SquadPanel.Hold), 1)
		local mid = SquadPanel.restAlpha(SquadPanel.Hold + 1)
		t.truthy(mid < 1 and mid > SquadPanel.IdleAlpha, "easing down")
		t.near(SquadPanel.restAlpha(SquadPanel.Hold + 60), SquadPanel.IdleAlpha, 1e-9, "resting dim")
		t.truthy(SquadPanel.IdleAlpha > 0.2 and SquadPanel.IdleAlpha < 0.6, "readable at a glance, not loud")
		local previous = 1
		for since = 0, 20, 0.25 do
			local value = SquadPanel.restAlpha(since)
			t.truthy(value <= previous + 1e-9, "never brightens on its own")
			previous = value
		end
	end,

	["on touch it gives the corner to the objective tracker"] = function(t: Expect)
		t.eq(SquadPanel.cornerShare(false, 1), 1, "off touch the tracker is in the other corner")
		t.eq(SquadPanel.cornerShare(true, 0), 1, "the tracker has faded: the corner is the panel's")
		t.eq(SquadPanel.cornerShare(true, 1), 0, "the tracker is up: the panel is gone")
		t.eq(SquadPanel.cornerShare(true, 0.25), 0, "it yields as soon as the tracker starts to show")
		local partial = SquadPanel.cornerShare(true, 0.1)
		t.truthy(partial > 0 and partial < 1)
	end,
}
