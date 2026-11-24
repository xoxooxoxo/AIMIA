--!strict
--!optimize 2

--[[
	NoFail: the attempt never fails (scripts/game/modifiers/NoFailModifier.cs). It is an IFailModifier whose fail
	condition is always false.
]]

const Color = require("../../Godot/Color")
const Modifier = require("./Modifier")

-- @src scripts/game/modifiers/NoFailModifier.cs:CheckFailCondition L11-11
const function CheckFailCondition(Hit: boolean, Health: number): boolean
	return false
end

-- @src scripts/game/modifiers/NoFailModifier.cs:NoFailModifier L3-12
const function New(): Modifier.Modifier
	const Mod = Modifier.New("NoFail", Color.FromRgba(0x20e12cff))

	Mod.IsFail = false
	Mod.CheckFailCondition = CheckFailCondition

	return Mod
end

return New
