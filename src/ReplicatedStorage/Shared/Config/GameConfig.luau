--!strict
-- Global rules, timers and economy. Seconds and studs unless noted.

local GameConfig = table.freeze({
	-- Squad
	MinSquad = 1,
	MaxSquad = 4, -- also set Server Size = 4 in the Creator Dashboard (Players.MaxPlayers is read-only)

	-- Match flow
	CountdownSeconds = 8,
	ResultsSeconds = 12,
	WorldReadyTimeout = 30, -- LoadingCurtain shows BootError if the world is not ready by then
	ClientAckTimeout = 20, -- players are deployed even if their WorldAck is late

	-- Health and life state
	MaxHealth = 100,
	BleedoutSeconds = 35,
	ReviveHoldSeconds = 4,
	CheckpointRespawnHealthFraction = 0.5,
	DownedMoveSpeed = 2.5,

	-- Checkpoints
	StragglerSeconds = 20,

	-- Bear traps
	TrapDamage = 35,
	TrapSoloPrySeconds = 5,
	TrapRescueSeconds = 1.5,
	TrapLookDownPitch = -35, -- degrees; the solo pry needs the victim looking at the trap

	-- Vents
	UnscrewSeconds = 3.5,
	KickSeconds = 0,

	-- Chemicals
	StunSeconds = 6,
	FlaskThrowSpeed = 70,
	FlaskThrowCooldown = 1.2,
	FlaskCloudRadius = 14,
	FlaskCloudSeconds = 7,
	FlaskMaxFlightSeconds = 3,
	FlaskVentHopRadius = 2, -- VentGraph edges between an in-duct shatter and the Creature

	-- Lockers
	BreathHoldMaxSeconds = 7,
	BreathRecoverPerSecond = 0.6,

	-- Pool
	StrugglePressesToEscape = 14, -- Floor 4 fairness (was 22): a grab is escapable
	StruggleMaxPressesPerSecond = 12,

	-- Roof
	ParachutePackCount = 4,
	ParachuteDescentSpeed = 9,

	-- Meters (value units; drains and regen per second)
	StaminaMax = 100,
	StaminaSprintDrain = 16,
	StaminaScurryDrain = 22,
	StaminaFreestyleDrain = 20,
	StaminaTreadDrain = 2,
	StaminaRegen = 14,
	StaminaRegenDelay = 1.2,
	OxygenMax = 100,
	OxygenDrain = 7, -- about 14 s underwater
	OxygenDrainGrabbed = 5, -- slower than a dive while held (was 9): time to struggle free
	OxygenRegen = 30,
	BatteryMax = 100,
	BatteryDrain = 0.6325, -- +15 % (harder Standard; every difficulty): about 2.6 minutes of light per full cell
	BatteryPickupCharge = 45,

	-- Movement speeds (WalkSpeed)
	WalkSpeed = 11,
	SprintSpeed = 19,
	CrouchSpeed = 5.5,
	VentCrawlSpeed = 4.5,
	VentScurrySpeed = 9,
	TreadSpeed = 4,
	FreestyleSpeed = 9,
	UnderwaterSpeed = 5,

	-- Network timing
	OneShotLead = 0.2,
	OneShotMaxLate = 1.5,
	LookRelayHz = 20,
	ServerTickHz = 10,

	-- Economy
	CreditsPerLevelCleared = 20,
	CreditsEscapeBonus = 100,

	-- Dev (Studio is always allowed)
	DevAllowlistUserIds = table.freeze({} :: { number }),
	-- The experience's owner (the creator user, or the owner of the creator group) gets dev tools on live servers,
	-- so a phone-only developer can test a published build without Studio. Set false before a public launch if the
	-- owner should play without the dev panel.
	DevToolsForCreator = true,
})

return GameConfig
