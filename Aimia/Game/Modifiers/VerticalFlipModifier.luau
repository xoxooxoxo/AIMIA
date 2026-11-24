--!strict
--!optimize 2

--[[
	VFlip: negates the Y of every note of the map (scripts/game/modifiers/VerticalFlipModifier.cs).
]]

const Color = require("../../Godot/Color")
const Modifier = require("./Modifier")

-- @src scripts/game/modifiers/VerticalFlipModifier.cs:ModifyMap L11-17
const function ModifyMap(Map: Modifier.Map, Attempt: Modifier.Attempt)
	for _, Note in Map.Notes do
		Note.Y = -Note.Y
	end
end

-- @src scripts/game/modifiers/VerticalFlipModifier.cs:VerticalFlipModifier L3-18
const function New(): Modifier.Modifier
	const Mod = Modifier.New("VFlip", Color.FromRgba(0xffffffff))

	Mod.Rankable = true
	Mod.ModifyMap = ModifyMap

	return Mod
end

return New
