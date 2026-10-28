--!strict
-- Every player-facing string, keyed. UI code calls Strings.get(key, ...) and never embeds text, so the game
-- is localization-ready (swap this table per locale) and wording stays consistent.

local STRINGS: { [string]: string } = {
	-- Boot / loading
	["Boot.Generating"] = "THE SCHOOL IS WAKING UP",
	["Boot.Receiving"] = "Receiving the building... %d%%",
	["Boot.Ready"] = "Stay together.",
	["Boot.Error"] = "Something broke while building the school: %s",
	["Boot.Timeout"] = "The school is taking too long to appear. Rejoin to try again.",
	["Boot.DataEphemeral"] = "Progress is not being saved on this server.",
	["Boot.DataGuest"] = "Saving is unavailable right now. You are playing as a guest.",

	-- Lobby
	["Lobby.Title"] = "BOILER ROOM: SAFE ZONE",
	["Lobby.Ready"] = "Ready",
	["Lobby.Unready"] = "Not ready",
	["Lobby.WaitingForSquad"] = "Waiting for the squad (%d / %d ready)",
	["Lobby.Countdown"] = "Descending into the basement in %d...",
	["Lobby.Difficulty"] = "Difficulty",
	["Lobby.Difficulty.Standard"] = "Standard",
	["Lobby.Difficulty.Nightmare"] = "Nightmare",
	["Lobby.Difficulty.NightmareHint"] = "Faster creature. More traps. Fewer batteries.",
	["Lobby.Credits"] = "%d credits",
	["Lobby.PerkShop"] = "Loadout",
	["Lobby.Buy"] = "Buy (%d)",
	["Lobby.Owned"] = "Owned: %d",
	["Lobby.Equip"] = "Equip",
	["Lobby.Unequip"] = "Unequip",
	["Lobby.NotEnoughCredits"] = "Not enough credits.",
	["Lobby.SpectatingUntilCheckpoint"] = "A run is in progress. You will join at the next checkpoint.",
	["Lobby.ServerFull"] = "This squad is full. You are spectating.",

	-- Perks
	["Perk.RustyScrewdriver"] = "Rusty Screwdriver",
	["Perk.RustyScrewdriver.Desc"] = "Unscrew vent grates in 1.2s instead of 3.5s.",
	["Perk.LithiumCell"] = "Heavy-Duty Lithium Cell",
	["Perk.LithiumCell.Desc"] = "+50% flashlight battery capacity.",
	["Perk.AdrenalineSyringe"] = "Adrenaline Syringe",
	["Perk.AdrenalineSyringe.Desc"] = "One use: revive yourself when downed, or refill your stamina.",

	-- Prompts
	["Prompt.Unscrew"] = "Unscrew Quietly",
	["Prompt.Kick"] = "Kick Open",
	["Prompt.Grate"] = "Vent Grate",
	["Prompt.GrateLocked"] = "Rusted shut",
	["Prompt.TrapPry"] = "Pry Open",
	["Prompt.TrapRescue"] = "Free Teammate",
	["Prompt.Trap"] = "Bear Trap",
	["Prompt.Revive"] = "Revive",
	["Prompt.Downed"] = "Downed Teammate",
	["Prompt.Pickup"] = "Pick Up",
	["Prompt.Flask"] = "Volatile Chemical Flask",
	["Prompt.Battery"] = "Battery",
	["Prompt.Hide"] = "Hide",
	["Prompt.Locker"] = "Locker",
	["Prompt.ParachuteGrab"] = "Take Parachute",
	["Prompt.Parachute"] = "Parachute Pack",
	["Prompt.Floodlight"] = "Flip Floodlights",
	["Prompt.FloodlightSwitch"] = "Emergency Switch",

	-- Printed on props (signs, stencils, labels)
	["Prop.Floodlight.Label"] = "POOL FLOODLIGHTS",
	["Prop.Floodlight.Warning"] = "EMERGENCY USE ONLY",
	["Prop.Parachute.Stencil"] = "EMERGENCY CHUTES",
	["Prop.Lab.Hazard"] = "DANGER: CORROSIVE",
	["Prop.Airlock.Sign"] = "FIRE DOOR - KEEP CLOSED",
	["Prop.Roof.Sign"] = "ROOF ACCESS",
	["Prop.Locker.Number"] = "%d",
	["Prop.Sign.NoRunning"] = "NO RUNNING IN THE HALLS",
	["Prop.Sign.Exit"] = "EXIT",
	["Prop.Sign.Stairs"] = "STAIRS",
	["Prop.Sign.Science"] = "SCIENCE WING",
	["Prop.Sign.Gym"] = "GYMNASIUM",
	["Prop.Sign.Lockers"] = "LOCKER ROOMS",
	["Prop.Sign.Pool"] = "POOL - NO DIVING",
	["Prop.Sign.Office"] = "MAIN OFFICE",
	["Prop.Sign.Boiler"] = "BOILER ROOM - STAFF ONLY",
	["Prop.Sign.Missing"] = "HAVE YOU SEEN THIS STUDENT?",
	["Prop.Sign.Assembly"] = "ASSEMBLY CANCELLED",
	["Prop.Sign.Quarantine"] = "QUARANTINE ZONE - DO NOT ENTER",
	["Prop.Sign.Help"] = "HELP US",
	["Prop.Sign.Hide"] = "DON'T LET IT HEAR YOU",
	["Prop.Sign.Room"] = "ROOM %d",
	["Prop.Sign.Lab"] = "LAB %d",
	["Prop.Sign.Caution"] = "CAUTION",
	["Prop.Sign.WetFloor"] = "WET FLOOR",

	-- Input labels (touch buttons and hints)
	["Input.Sprint"] = "RUN",
	["Input.Crouch"] = "CROUCH",
	["Input.Dive"] = "DIVE",
	["Input.Flashlight"] = "LIGHT",
	["Input.Throw"] = "THROW",
	["Input.HoldBreath"] = "HOLD BREATH",
	["Input.Struggle"] = "STRUGGLE",
	["Input.Syringe"] = "SYRINGE",
	["Input.Ripcord"] = "PULL CORD",
	["Input.SpectatePrev"] = "<",
	["Input.SpectateNext"] = ">",
	["Input.Menu"] = "MENU",
	["Input.LeaveLocker"] = "LEAVE",

	-- HUD
	["Hud.Battery"] = "BATTERY",
	["Hud.Stamina"] = "STAMINA",
	["Hud.Oxygen"] = "OXYGEN",
	["Hud.Bleedout"] = "BLEEDING OUT",
	["Hud.Downed"] = "You are down. Crawl to safety.",
	["Hud.SelfRevive"] = "Use your syringe to get back up.",
	["Hud.Trapped"] = "Your leg is caught. Look down and pry the jaws open.",
	["Hud.HoldBreath"] = "It's right outside. Hold your breath.",
	["Hud.HoldBreathNow"] = "HOLD YOUR BREATH",
	["Hud.KeepHolding"] = "Don't breathe.",
	["Hud.Breath"] = "BREATH",
	["Hud.BreathSafe"] = "It moves on.",
	["Hud.LockerLeave.KeyboardMouse"] = "Press E to step out.",
	["Hud.LockerLeave.Gamepad"] = "Press X to step out.",
	["Hud.LockerLeave.Touch"] = "Tap LEAVE to step out.",
	["Hud.LockerOccupied"] = "Someone is already hiding in there.",
	["Hud.LockerSeen"] = "It's watching you. Lose it first.",
	["Hud.LockerBlocked"] = "Something is blocking the door.",
	["Hud.Struggle"] = "It has your legs. STRUGGLE.",
	["Hud.Ripcord"] = "Pull the cord!",
	["Hud.BatteryEmpty"] = "Your flashlight is dead.",
	["Hud.SyringeUsed"] = "Adrenaline floods your veins.",
	["Hud.Spectating"] = "Spectating %s",
	["Hud.NoOneToSpectate"] = "No survivors to watch.",
	["Hud.Straggler"] = "The door seals in %d...",
	["Hud.FlaskThrow.KeyboardMouse"] = "Hold LMB to aim the flask, release to throw.",
	["Hud.FlaskThrow.Gamepad"] = "Hold R2 to aim the flask, release to throw.",
	["Hud.FlaskThrow.Touch"] = "Hold THROW to aim the flask, release to throw.",
	["Hud.FlaskHandsFull"] = "Your hands are full. Throw the flask you're carrying first.",
	["Hud.FlaskStun"] = "Throw a flask to stun it.",

	-- Checkpoints
	["Checkpoint.Reached"] = "Checkpoint reached. +%d credits",
	["Checkpoint.Respawned"] = "You stagger back to your feet.",
	["Checkpoint.Sealed"] = "The fire door seals behind you.",
	["Airlock.Waiting"] = "Waiting for the squad — %s",
	["Airlock.GetIn"] = "Get to the stairwell! %s",
	["Airlock.Sealing"] = "Sealing…",
	["Airlock.LeftBehind"] = "The fire doors sealed without you.",

	-- Results
	["Results.Escaped"] = "ESCAPED",
	["Results.Wiped"] = "THE SCHOOL KEPT YOU",
	["Results.Time"] = "Time: %s",
	["Results.BestTime"] = "Best: %s",
	["Results.Credits"] = "Credits earned: %d",
	["Results.TrapsTriggered"] = "Traps triggered: %d",
	["Results.VentsCrawled"] = "Vents crawled: %d",
	["Results.TimesDowned"] = "Times downed: %d",
	["Results.Revives"] = "Teammates revived: %d",
	["Results.PlayAgain"] = "Play Again",
	["Results.Waiting"] = "Waiting for the squad...",

	-- Settings
	["Settings.Title"] = "SETTINGS",
	["Settings.MouseSensitivity"] = "Mouse sensitivity",
	["Settings.GamepadSensitivity"] = "Gamepad sensitivity",
	["Settings.TouchSensitivity"] = "Touch sensitivity",
	["Settings.InvertY"] = "Invert look",
	["Settings.BaseFov"] = "Field of view",
	["Settings.MotionScale"] = "Camera motion",
	["Settings.FlashScale"] = "Flash intensity",
	["Settings.MasterVolume"] = "Master volume",
	["Settings.AmbienceVolume"] = "Ambience",
	["Settings.WorldVolume"] = "World sounds",
	["Settings.MonsterVolume"] = "Creature",
	["Settings.PlayerVolume"] = "Players",
	["Settings.UIVolume"] = "Interface",
	["Settings.Captions"] = "Sound captions",
	["Settings.Close"] = "Close",

	-- Captions (SynthPresets reference these)
	["Caption.Screech"] = "[an inhuman shriek]",
	["Caption.VentScrape"] = "[metal scraping inside the walls]",
	["Caption.Breathing"] = "[heavy breathing in the ducts]",
	["Caption.Heartbeat"] = "[your heart pounding]",
	["Caption.TrapSnap"] = "[steel jaws snap shut]",
	["Caption.GlassCrunch"] = "[glass crunches underfoot]",
	["Caption.GateSlam"] = "[a gate slams]",
	["Caption.LightBurst"] = "[a bulb bursts]",
	["Caption.Thunder"] = "[thunder]",
	["Caption.Splash"] = "[splashing]",
	["Caption.Gasp"] = "[a loud gasp]",
	["Caption.ChemHiss"] = "[chemicals hissing]",
	["Caption.Static"] = "[electrical static]",
	["Caption.DoorSmash"] = "[a door is torn apart]",
	["Caption.FireDoor"] = "[a fire door slams shut]",
	["Caption.DoorCreak"] = "[a door creaks on its hinges]",
	["Caption.PipeBang"] = "[a pipe bangs somewhere in the dark]",
	["Caption.BoilerSurge"] = "[a boiler roars]",
	["Caption.CeilingDrag"] = "[something drags across the ceiling]",
	["Caption.ChildWhisper"] = "[a child whispers]",
	["Caption.ChildLaugh"] = "[a child giggles in the dark]",
	["Caption.ObjectFall"] = "[something clatters to the floor]",
	["Caption.CreatureVanish"] = "[a rush of air, then nothing]",
	["Caption.CreatureSniff"] = "[something sniffing at the slits]",
	["Caption.LockerRip"] = "[a locker door is torn off]",
	["Caption.LockerSlam"] = "[a locker door bangs somewhere]",
	["Caption.BallBounce"] = "[a ball bouncing in the empty gym]",

	-- Network (Net kicks a client that floods or sends malformed messages)
	["Net.Kicked"] = "Disconnected: your game sent too many invalid requests. Please rejoin.",

	-- Dev tools
	["Dev.Unknown"] = "Unknown dev command: %s",
	["Dev.Denied"] = "Dev commands are disabled here.",
	["Dev.Ok"] = "%s",
	["Dev.Panel.Toggle"] = "DEV",
	["Dev.Panel.Hide"] = "HIDE",
	["Dev.Panel.Title"] = "DEV TOOLS",
	["Dev.Panel.DevRun"] = "Dev Run",
	["Dev.Panel.EndRun"] = "End Run",
	["Dev.Panel.NextLevel"] = "Next Level",
	["Dev.Panel.NoiseRing"] = "Noise Ring",
	["Dev.Panel.NoiseKind"] = "Noise: %s",
	["Dev.Panel.ShowPlan"] = "Show Plan",
	["Dev.Panel.Overlays"] = "Overlays: %s",
	["Dev.Panel.VentGraph"] = "Vent Graph: %s",
	["Dev.Panel.Light"] = "Light: %s",
	["Dev.Panel.Difficulty"] = "Mode: %s",
	["Dev.Panel.Help"] = "Help",
	["Dev.Panel.Levels"] = "Jump to level",
	["Dev.Panel.Level"] = "L%d",
	["Dev.Panel.Sounds"] = "Audition sound (%d presets)",
	["Dev.Panel.SoundPrev"] = "<",
	["Dev.Panel.SoundNext"] = ">",
	["Dev.Panel.SoundPlay2D"] = "Play 2D",
	["Dev.Panel.SoundStop"] = "Stop Sound",
	["Dev.Panel.On"] = "On",
	["Dev.Panel.Off"] = "Off",
	["Dev.Panel.None"] = "-",
	["Dev.Panel.Status"] = "%s | %s | %s",
	["Dev.Panel.Perf"] = "%d FPS | %d ms | lights %d/%d",
	["Dev.Panel.Creature"] = "%s | %s | target %s",
}

local Strings = {}

-- Formats a string by key. Unknown keys return the key itself so a missing string is visible but harmless.
function Strings.get(key: string, ...: any): string
	local template = STRINGS[key]
	if not template then
		return key
	end
	if select("#", ...) == 0 then
		return template
	end
	local ok, formatted = pcall(string.format, template, ...)
	return if ok then formatted else template
end

function Strings.has(key: string): boolean
	return STRINGS[key] ~= nil
end

-- Seconds -> "m:ss".
function Strings.formatTime(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", total // 60, total % 60)
end

return table.freeze(Strings)
