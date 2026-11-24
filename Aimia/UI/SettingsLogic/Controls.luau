--!strict
--!optimize 2

--[[
	Rules of the settings controls, Roblox-free: the Node API value of a color, the option index of a stored list value and the
	press interval of a settings button.

	Design Notes
		Node values are the scene-data forms UI/Nodes takes ({ Color = { r, g, b, a } }).
		A press is counted when at least PressInterval milliseconds have passed since the last counted press; the last press
		starts at 0, so a press in the first 250 ms of the clock is not counted (upstream's ulong lastPressedAt = 0).
]]

const Color = require("../../Godot/Color")

-- SettingsMenu.setupButton: presses closer together than this are ignored (milliseconds).
const PressInterval = 250

-- A Godot Color as a Node API value.
const function ColorValue(Value: Color.Color): { Color: { number } }
	return { Color = { Value.R, Value.G, Value.B, Value.A } }
end

-- SettingsMenu.setupList.getIndex: the 0-based index of the first value equal to the selected one, or the count when none
-- matches (the loop runs to its end).
const function ListIndex(Values: { unknown }, Selected: unknown): number
	for Index, Value in Values do
		if Value == Selected then
			return Index - 1
		end
	end

	return #Values
end

-- SettingsMenu.setupButton: a press is counted when PressInterval has passed since the last counted press.
const function PressAllowed(Now: number, LastPressed: number): boolean
	return Now - LastPressed >= PressInterval
end

return {
	ColorValue = ColorValue,
	ListIndex = ListIndex,
	PressAllowed = PressAllowed,
}
