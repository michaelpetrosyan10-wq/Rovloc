--!strict
-- RbxCharacterSounds: replaces the engine's default character sound script. Keep this exact name.
--
-- Why this exists. When a place starts, Roblox copies its own "RbxCharacterSounds" LocalScript into every player's
-- PlayerScripts unless StarterPlayerScripts already holds a script with that name. The stock script parents a set
-- of legacy Sounds (Running, Jumping, Landing, FreeFalling, Swimming, Splash, GettingUp, Climbing, Died) into every
-- character's HumanoidRootPart (or, with the new audio API, AudioPlayers plus an "RbxCharacterSoundsEmitter") and
-- plays them from Humanoid states. In this game that would mean looped plastic footsteps on every player (even while
-- crouching or crawling a duct, since the Humanoid still reports Running), jump / land / fall-wind / swim sounds
-- audible ~150 studs away, bypassing the mixer (no ducking, no vent or underwater muffling, no volume settings),
-- giving teammates' positions away in a game built on noise and doubling the synthesized footsteps.
--
-- Because this script carries the name, the engine never inserts its own. This script then enforces the rule for
-- every character in the session, its own and everyone else's: any of those engine character sounds that still
-- appear in a character's HumanoidRootPart (another engine path, a future engine change, a Studio plugin, a stale
-- build) are destroyed as they arrive. SoundSynthesizer owns all character audio (the procedural footsteps arrive in
-- Phase 3); its voices play through pooled "VoiceEmitter" Attachments named differently and are never touched.

local Players = game:GetService("Players")

-- Instance names the engine's character sound script creates (Sounds, AudioPlayers and the emitter that wires
-- them to the listener under the new audio API).
local ENGINE_SOUND_NAMES: { [string]: boolean } = {
	Running = true,
	Jumping = true,
	Landing = true,
	FreeFalling = true,
	Swimming = true,
	Splash = true,
	GettingUp = true,
	Climbing = true,
	Died = true,
	RbxCharacterSoundsEmitter = true,
}

local ROOT_NAME = "HumanoidRootPart"

type Watch = { character: Model, connections: { RBXScriptConnection } }

local watches: { [Model]: Watch } = {}

local function isEngineSound(instance: Instance): boolean
	if not ENGINE_SOUND_NAMES[instance.Name] then
		return false
	end
	return instance:IsA("Sound") or instance:IsA("AudioPlayer") or instance:IsA("AudioEmitter")
end

-- Destroys an engine character sound once the engine has finished parenting it (destroying an instance during
-- its own ChildAdded can fail while its parent is locked, so it is deferred and protected).
local function strip(instance: Instance)
	if not isEngineSound(instance) then
		return
	end
	task.defer(function()
		if instance.Parent == nil then
			return
		end
		xpcall(function()
			instance:Destroy() -- also ends playback
		end, function(err: any)
			warn("[RbxCharacterSounds] could not remove", instance:GetFullName(), tostring(err))
		end)
	end)
end

local function watchRoot(watch: Watch, root: Instance)
	for _, child in root:GetChildren() do
		strip(child)
	end
	table.insert(watch.connections, root.ChildAdded:Connect(strip))
end

local function unwatch(character: Model)
	local watch = watches[character]
	if not watch then
		return
	end
	watches[character] = nil
	for _, connection in watch.connections do
		connection:Disconnect()
	end
end

local function watchCharacter(character: Model)
	if watches[character] then
		return
	end
	local watch: Watch = { character = character, connections = {} }
	watches[character] = watch
	local root = character:FindFirstChild(ROOT_NAME)
	if root then
		watchRoot(watch, root)
	end
	-- The root part may arrive after the model (replication order) or be replaced; watch whichever appears.
	table.insert(
		watch.connections,
		character.ChildAdded:Connect(function(child: Instance)
			if child.Name == ROOT_NAME and child:IsA("BasePart") then
				watchRoot(watch, child)
			end
		end)
	)
	table.insert(
		watch.connections,
		character.AncestryChanged:Connect(function()
			if character.Parent == nil then
				unwatch(character)
			end
		end)
	)
end

local function watchPlayer(player: Player)
	local character = player.Character
	if character then
		watchCharacter(character)
	end
	player.CharacterAdded:Connect(watchCharacter)
	player.CharacterRemoving:Connect(unwatch)
end

Players.PlayerAdded:Connect(watchPlayer)
for _, player in Players:GetPlayers() do
	watchPlayer(player)
end
