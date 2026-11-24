--!strict
--!optimize 2

--[[
	Autoplay: the attempt plays itself, so it does not qualify for scores (scripts/game/modifiers/AutoplayModifier.cs).
]]

const Color = require("../../Godot/Color")
const Modifier = require("./Modifier")

-- @src scripts/game/modifiers/AutoplayModifier.cs:Activate L9-13
const function Activate(Mod: Modifier.Modifier, Attempt: Modifier.Attempt)
	Modifier.Activate(Mod, Attempt)

	Attempt.Qualifies = false
end

-- @src scripts/game/modifiers/AutoplayModifier.cs:AutoplayModifier L3-14
const function New(): Modifier.Modifier
	const Mod = Modifier.New("Autoplay", Color.FromRgba(0xffd166ff))

	Mod.Activate = Activate

	return Mod
end

return New
