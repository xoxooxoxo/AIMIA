--!strict
--!optimize 2

--[[
	The start time of the map info: a typed text ("m:s", seconds, or a fraction of the map) becomes milliseconds, clamped to
	the map; the slider's position is the start over the map's length.

	Design Notes
		"m:s" reads as minutes then seconds. (The source read it backwards, so 1:05 meant 5:01 and the slider jumped when let go.)
		A bare number under 1 is a fraction of the map. The slider sets its position directly, so this never reads it.
		The source's float.TryParse / float.Parse for the minute part are the Dotnet/Number float parsers.
]]

const DotnetNumber = require("../../../../Dotnet/Number")
const DotnetString = require("../../../../Dotnet/String")
const Format = require("./Format")
const Numbers = require("../../../../Numbers")
const UtilString = require("../../../../Util/String")

-- The start in milliseconds for a typed text, clamped to the map's length.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:applyStartFrom L268-288
const function ParseInput(Input: string, Length: number): number
	local Value = 0
	const Parts = DotnetString.Split(Input, ":")

	if #Parts > 1 then
		const MinutesValid, Minutes = DotnetNumber.TryParseSingle(Parts[1])

		if MinutesValid then
			Value += Numbers.F32(60 * Minutes)
		end

		const SecondsValid, Seconds = DotnetNumber.TryParseDouble(Parts[2])

		if SecondsValid then
			Value += Seconds
		end
	else
		const Valid, Parsed = DotnetNumber.TryParseDouble(Parts[1])

		if Valid then
			Value = if Parsed < 1 then Parsed * (Length // 1000) else Parsed
		end
	end

	-- ("nan" parses, and a NaN start made the run never start or end)
	if Value ~= Value then
		Value = 0
	end

	return math.clamp(Value * 1000, 0, Length)
end

-- The slider's position of a start: the start over the map's length (startFrom / length).
-- @src scripts/ui/menu/play/MapInfoContainer.cs:displayStartFrom L248-258
const function SliderValue(StartFrom: number, Length: number): number
	return StartFrom / Length
end

-- The text the slider's change applies: the position in the map as seconds with two decimals (F2).
-- @src scripts/ui/menu/play/MapInfoContainer.cs:startFromSlider.ValueChanged L312-315
const function SliderInput(Value: number, Length: number): string
	return Format.Fixed(Numbers.RoundHalfEven(Value * Length) / 1000, 2)
end

-- The time box's text: the start as m:ss.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:displayStartFrom L251
const function TimeText(StartFrom: number): string
	return UtilString.FormatTime(StartFrom / 1000)
end

-- The start button's text: START, and the start time in brackets when it is after 0.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:displayStartFrom L259
const function ButtonText(StartFrom: number, TimeEdit: string): string
	if StartFrom > 0 then
		return `START ({TimeEdit})`
	end

	return "START"
end

return {
	ParseInput = ParseInput,
	SliderValue = SliderValue,
	SliderInput = SliderInput,
	TimeText = TimeText,
	ButtonText = ButtonText,
}
