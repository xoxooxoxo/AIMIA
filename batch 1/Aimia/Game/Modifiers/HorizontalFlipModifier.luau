--!strict
--!optimize 2

--[[
	HFlip: negates the X of every note of the map (scripts/game/modifiers/HorizontalFlipModifier.cs).
]]

const Color = require("../../Godot/Color")
const Modifier = require("./Modifier")

-- @src scripts/game/modifiers/HorizontalFlipModifier.cs:ModifyMap L11-17
const function ModifyMap(Map: Modifier.Map, Attempt: Modifier.Attempt)
	for _, Note in Map.Notes do
		Note.X = -Note.X
	end
end

-- @src scripts/game/modifiers/HorizontalFlipModifier.cs:HorizontalFlipModifier L3-18
const function New(): Modifier.Modifier
	const Mod = Modifier.New("HFlip", Color.FromRgba(0xffffffff))

	Mod.Rankable = true
	Mod.ModifyMap = ModifyMap

	return Mod
end

return New
