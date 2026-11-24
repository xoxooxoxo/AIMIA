--!strict
--!optimize 2

--[[
	Slider bounds of a settings item, as scripts/database/settings/SettingsSlider.cs. The fields are float32: New rounds
	each argument with Numbers.F32, as the C# float fields store the float literals.
]]

const Numbers = require("../../Numbers")

export type SettingsSlider = {
	MinValue: number,
	MaxValue: number,
	Step: number,
	Floor: number,
	Ceiling: number,
	Log: boolean,
}

-- Floor and Ceiling limit a typed or saved value, and default to the track's own bounds.
export type Extra = {
	Floor: number?,
	Ceiling: number?,
	Log: boolean?,
}

-- @src scripts/database/settings/SettingsSlider.cs:SettingsSlider L1-8
const function New(Step: number, MinValue: number, MaxValue: number, Options: Extra?): SettingsSlider
	return {
		MinValue = Numbers.F32(MinValue),
		MaxValue = Numbers.F32(MaxValue),
		Step = Numbers.F32(Step),
		Floor = Numbers.F32(if Options and Options.Floor then Options.Floor else MinValue),
		Ceiling = Numbers.F32(if Options and Options.Ceiling then Options.Ceiling else MaxValue),
		Log = Options ~= nil and Options.Log == true,
	}
end

return New
