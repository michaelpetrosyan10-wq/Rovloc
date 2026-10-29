--!strict
-- InputGlyphs: which glyph stands for an input action on the current device, and a cap that draws it. Used by the
-- onboarding (the Controls page), the objective tracker's key hint and the first-time hints.
--
--   * Keyboard / mouse: the binding's first key as a UIKit key cap; a mouse button reads as text (LMB / RMB).
--   * Gamepad: the binding's first button (face buttons tinted, d-pad arms lit) as a UIKit key cap.
--   * Touch: the label of the action's on-screen button (RUN, LIGHT, THROW ...) in a pill, or TAP for actions done by
--     tapping their ProximityPrompt (no button of their own).
-- Fixed controls without an action (move, look) pass their own text.
--
-- Pure (tests/Specs/Onboarding.spec.luau): forAction.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)

local UIKit = require(script.Parent.UIKit)

local Palette = UIKit.Palette

export type Glyph = { kind: UIKit.GlyphKind, keyCode: Enum.KeyCode?, text: string? }

export type Cap = {
	root: Frame,
	SetGlyph: (self: Cap, glyph: Glyph) -> (),
	SetAlpha: (self: Cap, alpha: number) -> (),
}

local TAP_KEY = "Tutorial.Control.TapPrompt"
local UNBOUND_KEY = "Input.Unbound"

local InputGlyphs = {}

-- The glyph for `action` (an Enums.InputAction) on `device` ("KeyboardMouse" | "Gamepad" | "Touch").
function InputGlyphs.forAction(action: string, device: string): Glyph
	local binding = InputConfig.Bindings[action]
	if device == "Touch" then
		local touch = if binding then binding.touch else nil
		return { kind = "Touch", text = Strings.get(if touch then touch.label else TAP_KEY) }
	end
	if not binding then
		return { kind = if device == "Gamepad" then "Gamepad" else "Keyboard", text = Strings.get(UNBOUND_KEY) }
	end
	if device == "Gamepad" then
		local button = binding.gamepad[1]
		return { kind = "Gamepad", keyCode = button, text = if button then nil else Strings.get(UNBOUND_KEY) }
	end
	local first = binding.keyboard[1]
	if typeof(first) == "EnumItem" and first.EnumType == Enum.KeyCode then
		return { kind = "Keyboard", keyCode = first :: Enum.KeyCode }
	elseif typeof(first) == "EnumItem" and first.EnumType == Enum.UserInputType then
		return { kind = "Keyboard", text = Strings.get("Input.Mouse." .. (first :: Enum.UserInputType).Name) }
	end
	return { kind = "Keyboard", text = Strings.get(UNBOUND_KEY) }
end

-- A glyph cap `size` design px tall: a UIKit key cap for keys and buttons, a pill of text otherwise.
function InputGlyphs.cap(parent: Instance, name: string, size: number): Cap
	local root = UIKit.frame(parent, name)
	root.Size = UDim2.fromOffset(size, size)
	root.AutomaticSize = Enum.AutomaticSize.X

	local key = UIKit.keyCap(root, "Key", size)

	local pill = UIKit.fill(root, "Pill", Palette.Ink, 0.22)
	pill.Size = UDim2.fromOffset(size, size)
	pill.AutomaticSize = Enum.AutomaticSize.X
	pill.Visible = false
	UIKit.corner(pill, UDim.new(0.5, 0))
	local pillStroke = UIKit.stroke(pill, Palette.Bone, 1, 0.45)
	UIKit.padding(pill, math.floor(size * 0.32), 0)
	local text = UIKit.label(pill, "Text", UIKit.Fonts.Strong, math.floor(size * 0.4), Palette.Bone)
	text.TextWrapped = false
	text.AutomaticSize = Enum.AutomaticSize.X
	text.Size = UDim2.fromScale(0, 1)

	local alpha = 1
	local cap = {} :: Cap
	cap.root = root
	function cap.SetGlyph(_self: Cap, glyph: Glyph)
		local keyCode = glyph.keyCode
		if keyCode and glyph.kind ~= "Touch" then
			key.root.Visible = true
			pill.Visible = false
			key:SetGlyph(glyph.kind, keyCode)
		else
			key.root.Visible = false
			pill.Visible = true
			text.Text = glyph.text or Strings.get(UNBOUND_KEY)
			text.TextColor3 = if glyph.kind == "Touch" then Palette.Amber else Palette.Bone
		end
	end
	function cap.SetAlpha(_self: Cap, value: number)
		alpha = value
		key:SetAlpha(value)
		UIKit.setTransparency(pill, UIKit.fade(0.22, alpha))
		UIKit.setTextTransparency(text, UIKit.fade(0, alpha))
		UIKit.setStrokeTransparency(pillStroke, UIKit.fade(0.45, alpha))
	end
	return cap
end

return table.freeze(InputGlyphs)
