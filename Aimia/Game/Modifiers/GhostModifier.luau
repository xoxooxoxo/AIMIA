--!strict
--!optimize 2

--[[
	Ghost: notes fade out as they approach the hit plane, and the fade is not drawn (scripts/game/modifiers/GhostModifier.cs).
]]

const Numbers = require("../../Numbers")
const Color = require("../../Godot/Color")
const Modifier = require("./Modifier")

-- @src scripts/game/modifiers/GhostModifier.cs:Activate L13-18
const function Activate(Mod: Modifier.Modifier, Attempt: Modifier.Attempt)
	Modifier.Activate(Mod, Attempt)

	Attempt.UseFadeOut = false
end

-- @src scripts/game/modifiers/GhostModifier.cs:ModifyRenderObject L20-25
const function ModifyRenderObject(Note: Modifier.Note, Attempt: Modifier.Attempt)
	const ApproachDistance = Numbers.F32(Attempt.Settings.ApproachDistance.Value)
	const Fade = Numbers.F32(Numbers.F32(ApproachDistance + Note.Transform.Origin.z) / Numbers.F32(ApproachDistance / 2))

	-- Mathf.Min propagates NaN; math.min does not.
	const Limit = if Fade ~= Fade then Fade elseif Fade < 1 then Fade else 1

	Note.Opacity = Numbers.F32(Note.Opacity - Limit)
end

-- @src scripts/game/modifiers/GhostModifier.cs:GhostModifier L3-26
const function New(): Modifier.Modifier
	const Mod = Modifier.New("Ghost", Color.FromRgba(0xffffffff))

	Mod.Rankable = true
	Mod.ScoreMultiplier = 1.03
	Mod.Activate = Activate
	Mod.ModifyRenderObject = ModifyRenderObject

	return Mod
end

return New
