--!strict
--!optimize 2

--[[
	Strobe: notes are hidden for the second half of each approach period (scripts/game/modifiers/StrobeModifier.cs).
]]

const Color = require("../../Godot/Color")
const Modifier = require("./Modifier")

-- @src scripts/game/modifiers/StrobeModifier.cs:ModifyRenderObject L13-21
const function ModifyRenderObject(Note: Modifier.Note, Attempt: Modifier.Attempt)
	const ApproachTime = Attempt.Settings.ApproachTime.Value

	-- C# % on doubles is fmod (sign of the dividend), not Luau's floor modulo.
	if math.fmod(Attempt.Progress / 1000 / Attempt.Speed, ApproachTime) >= ApproachTime / 2 then
		Note.Opacity = 0
	end
end

-- @src scripts/game/modifiers/StrobeModifier.cs:StrobeModifier L3-22
const function New(): Modifier.Modifier
	const Mod = Modifier.New("Strobe", Color.FromRgba(0xffe854ff))

	Mod.Rankable = true
	Mod.ScoreMultiplier = 1.035
	Mod.ModifyRenderObject = ModifyRenderObject

	return Mod
end

return New
