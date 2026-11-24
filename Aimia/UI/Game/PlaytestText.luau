--!strict
--!optimize 2

--[[
	The playtest overlay's start field rules (scripts/game/ui/PlaytestOverlay.cs ApplyStartFrom and GetStartFrom), Roblox-free:
	a typed start (seconds, "m:s", or a fraction of the map) becomes the text the field shows, clamped to the map, and the field's
	text becomes the start in seconds. The view sets the field to the text ApplyStartFrom returns.

	Design Notes
		ApplyStartFrom sets the field on its invalid path and again at its end; only the last text is kept, so the result is that
		text.
		Upstream quirk kept: the source calls split.Reverse() and discards the result, so the parts keep their order. For "m:s" the
		first part is the seconds and the second is added as 60 times its value.
		IsValidFloat is float.TryParse (Dotnet/Number); ToFloat is float.Parse (Godot/String); map lengths are whole milliseconds, so
		the fraction of the map is a whole division (//).
]]

const DotnetNumber = require("../../Dotnet/Number")
const DotnetString = require("../../Dotnet/String")
const GodotString = require("../../Godot/String")
const Numbers = require("../../Numbers")
const UtilString = require("../../Util/String")

-- float.TryParse of the text.
const function IsValidFloat(Text: string): boolean
	const Success = DotnetNumber.TryParseSingle(Text)

	return Success
end

-- The text the start field shows for a typed start, clamped to the map (its length in milliseconds).
-- @src scripts/game/ui/PlaytestOverlay.cs:ApplyStartFrom L87-134
const function ApplyStartFrom(Input: string, MapLength: number): string
	if string.find(Input, ":", 1, true) then
		local Value = 0
		const Parts = DotnetString.Split(Input, ":")

		if #Parts > 1 and IsValidFloat(Parts[2]) then
			Value += Numbers.F32(60 * GodotString.ToFloat(Parts[2]))
		end

		const Parsed, InputValue = DotnetNumber.TryParseDouble(Parts[1])

		if Parsed then
			local Amount = InputValue

			if Amount < 1 then
				Amount *= (MapLength // 1000)
			end

			Value += Amount
		end

		return UtilString.FormatTime(math.clamp(Value * 1000, 0, MapLength) / 1000)
	end

	local Value = 0
	const Parsed, InputValue = DotnetNumber.TryParseDouble(Input)

	if Parsed then
		Value = InputValue
	end

	return UtilString.FormatTime(math.clamp(Value, 0, MapLength))
end

-- The start in seconds the field reads: a bare number, or minutes and seconds ("m:s", minutes first, as the source adds them).
-- @src scripts/game/ui/PlaytestOverlay.cs:GetStartFrom L136-162
const function StartFromSeconds(Text: string): number
	local Value = 0
	const Parts = DotnetString.Split(Text, ":")

	if #Parts == 1 then
		if IsValidFloat(Parts[1]) then
			Value = GodotString.ToFloat(Parts[1])
		end
	else
		if IsValidFloat(Parts[1]) then
			Value += Numbers.F32(GodotString.ToFloat(Parts[1]) * 60)
		end

		if IsValidFloat(Parts[2]) then
			Value += GodotString.ToFloat(Parts[2])
		end
	end

	return Value
end

return {
	ApplyStartFrom = ApplyStartFrom,
	StartFromSeconds = StartFromSeconds,
}
