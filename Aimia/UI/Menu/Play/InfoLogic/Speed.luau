--!strict
--!optimize 2

--[[
	The speed of the map info: the lobby holds a ratio (1 is 100%), the speed box and slider show percent, and a typed value
	is parsed back into a ratio clamped to 25% to 1000%.

	Design Notes
		Display rounds the percent to one decimal only when that is within float32 epsilon of the value (displaySpeed).
		An unparsable text is 100%, as applySpeed does.
]]

const DotnetNumber = require("../../../../Dotnet/Number")
const Format = require("./Format")
const Numbers = require("../../../../Numbers")

-- Mathf.Epsilon (float32 2^-23) as the double the comparison promotes it to.
const Epsilon = 1.1920928955078125e-07
const DefaultPercent = 100
const MinimumPercent = 25
const MaximumPercent = 1000

-- The percent a speed ratio is shown as: rounded to a tenth only when that is within epsilon of it.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:displaySpeed L191-206
const function DisplayPercent(Speed: number): number
	const Percent = Speed * 100
	const Rounded = Numbers.RoundHalfEven(Percent * 10) / 10

	if math.abs(Rounded - Percent) <= Epsilon then
		return Rounded
	end

	return Percent
end

-- The text of a percent: double.ToString(CultureInfo.InvariantCulture).
-- @src scripts/ui/menu/play/MapInfoContainer.cs:displaySpeed L208
const function DisplayText(Percent: number): string
	return Format.Shortest(Percent)
end

-- The ratio a typed text names: double.TryParse (100% when it does not parse), clamped to 25% to 1000%, over 100.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:applySpeed L215-224
const function ParseRatio(Text: string): number
	local Percent = DefaultPercent
	const Success, Parsed = DotnetNumber.TryParseDouble(Text)

	-- (and not "nan", which parses: a NaN speed made the run never start or end)
	if Success and Parsed == Parsed then
		Percent = Parsed
	end

	return math.clamp(Percent, MinimumPercent, MaximumPercent) / 100
end

return {
	DisplayPercent = DisplayPercent,
	DisplayText = DisplayText,
	ParseRatio = ParseRatio,
}
