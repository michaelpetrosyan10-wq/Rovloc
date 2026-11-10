--!strict
-- The client predicts its MoveState (MovementController) with the same rules the server enforces
-- (PlayerStateService). If the two ever disagree, the client predicts states the server refuses and the camera,
-- speed and noise stutter. These specs run every input combination through both and require identical answers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MovementController =
	require(StarterPlayer.StarterPlayerScripts.Controllers.FirstPerson.FirstPersonController.MovementController)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local MODES: { PlayerStateService.Mode } = { "OnFoot", "Vent", "Swim" }
local OVERRIDES: { Enums.MoveState } = { "Hiding", "Trapped", "DownedCrawling", "Scripted" }
local STAMINAS: { number } = { 0, 0.5, 50, GameConfig.StaminaMax }
local BOOLS: { boolean } = { false, true }

return {
	["client prediction and server derivation agree on every input"] = function(t: Expect)
		local checked = 0
		for _, mode: PlayerStateService.Mode in MODES do
			for overrideIndex = 1, #OVERRIDES + 1 do
				for _, stamina in STAMINAS do
					for _, crouch in BOOLS do
						for _, sprint in BOOLS do
							for _, dive in BOOLS do
								for _, exhausted in BOOLS do
									for _, moving in BOOLS do
										for _, lowCeiling in BOOLS do
											local overrideState: Enums.MoveState? = if overrideIndex <= #OVERRIDES
												then OVERRIDES[overrideIndex]
												else nil
											local server = PlayerStateService.deriveState({
												mode = mode,
												override = overrideState,
												intent = { crouch = crouch, sprint = sprint, dive = dive },
												stamina = stamina,
												exhausted = exhausted,
												moving = moving,
												lowCeiling = lowCeiling,
											})
											local client = MovementController.deriveState({
												mode = mode,
												override = overrideState,
												crouch = crouch,
												sprint = sprint,
												dive = dive,
												stamina = stamina,
												exhausted = exhausted,
												moving = moving,
												lowCeiling = lowCeiling,
											} :: any)
											checked += 1
											if server ~= client then
												t.eq(
													client,
													server,
													string.format(
														"%s override=%s stamina=%s crouch=%s sprint=%s dive=%s exhausted=%s moving=%s low=%s",
														mode,
														tostring(overrideState),
														tostring(stamina),
														tostring(crouch),
														tostring(sprint),
														tostring(dive),
														tostring(exhausted),
														tostring(moving),
														tostring(lowCeiling)
													)
												)
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
		t.truthy(checked == #MODES * (#OVERRIDES + 1) * #STAMINAS * 64, "every combination checked")
	end,

	["both sides force a crouch under the same head room"] = function(t: Expect)
		local headrooms: { number } =
			{ 0, 1.3, GameConfig.StandHeadroom - 0.01, GameConfig.StandHeadroom, 7, math.huge }
		local kinds: { { kind: string? } } =
			{ { kind = "Crawlway" }, { kind = "Tunnel" }, { kind = "Room" }, { kind = nil } }
		for _, row in kinds do
			local roomKind: string? = row.kind
			for _, headroom in headrooms do
				t.eq(
					MovementController.mustCrouch(roomKind, headroom),
					PlayerStateService.mustCrouch(roomKind, headroom),
					string.format("kind=%s headroom=%s", tostring(roomKind), tostring(headroom))
				)
			end
		end
		-- a crawlway's 4.3-stud mouth: the ceiling 1.3 over a standing root's centre (3 up) forbids standing
		t.truthy(PlayerStateService.mustCrouch(nil, 4.3 - 3), "under a crawlway's mouth")
		t.falsy(PlayerStateService.mustCrouch(nil, 7), "under a doorway lintel")
		t.truthy(PlayerStateService.mustCrouch("Crawlway", math.huge), "anywhere in a Crawlway room")
	end,

	["the exhaustion latch is the same on both sides"] = function(t: Expect)
		local max = GameConfig.StaminaMax
		for _, exhausted in BOOLS do
			for _, held in BOOLS do
				for _, stamina in { 0, 1, max / 2, max - 0.01, max } :: { number } do
					t.eq(
						MovementController.updateExhausted(exhausted, held, stamina, max),
						PlayerStateService.updateExhausted(exhausted, held, stamina, max),
						string.format(
							"exhausted=%s held=%s stamina=%s",
							tostring(exhausted),
							tostring(held),
							tostring(stamina)
						)
					)
				end
			end
		end
	end,

	["predicted walk speeds match the server's"] = function(t: Expect)
		for _, state: Enums.MoveState in Enums.MoveState do
			t.eq(MovementController.speedFor(state), PlayerStateService.walkSpeedFor(state), state)
		end
	end,
}
