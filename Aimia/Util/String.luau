--!strict
--!optimize 2

--[[
	Text formatting of scripts/util/String.cs: times, relative times, magnitudes, Zalgo and BBCode sanitizing.

	Design Notes
		Numbers follow the invariant culture: N0 groups thousands with "," and rounds ties to even, which "%.0f" does too
		(-0.4 gives "-0", as .NET does). "00" and "D2" pad to two digits.
		SanitizeZalgo walks UTF-8 code points without checking continuation bytes, so its input must be valid UTF-8.
		The source's regex matches UTF-16 code units, so only BMP marks (MarkRanges, baked from .NET by
		external/Unicode/BakeMarks.mjs) form runs, and a run of at least Limit + 1 marks becomes its last mark.
]]

const DotnetString = require("../Dotnet/String")
const MarkRanges = require("./MarkRanges")
const Numbers = require("../Numbers")

-- True for a code point of .NET's \p{M} (BMP only, see MarkRanges).
const function IsMark(CodePoint: number): boolean
	local Low = 1
	local High = #MarkRanges

	while Low <= High do
		const Middle = (Low + High) // 2
		const Range = MarkRanges[Middle]

		if CodePoint < Range[1] then
			High = Middle - 1
		elseif CodePoint > Range[2] then
			Low = Middle + 1
		else
			return true
		end
	end

	return false
end

-- @src scripts/util/String.cs:PadMagnitude L60-63
const function PadMagnitude(Value: number): string
	if Value ~= Value then
		return "NaN"
	elseif Value == math.huge then
		return "Infinity"
	elseif Value == -math.huge then
		return "-Infinity"
	end

	const Rounded = string.format("%.0f", Value)
	const Negative = string.sub(Rounded, 1, 1) == "-"
	const Digits = if Negative then string.sub(Rounded, 2) else Rounded
	const Groups: { string } = {}
	local End = #Digits

	while End > 0 do
		const Start = math.max(1, End - 2)

		table.insert(Groups, 1, string.sub(Digits, Start, End))
		End = Start - 1
	end

	return `{if Negative then "-" else ""}{table.concat(Groups, ",")}`
end

-- "1 day", "2 days": the count through PadMagnitude, then the unit with an "s" above one.
const function Plural(Count: number, Unit: string): string
	return `{PadMagnitude(Count)} {Unit}{if Count > 1 then "s" else ""}`
end

-- The maximal run of BMP marks from Start, as the text the source's regex replacement leaves and the position after it.
const function CollapseRun(Input: string, Start: number, Minimum: number): (string, number)
	local Count = 0
	local LastStart = Start
	local Next = Start

	while Next <= #Input do
		const CodePoint, Size = DotnetString.DecodeAt(Input, Next)

		if not IsMark(CodePoint) then
			break
		end

		Count += 1
		LastStart = Next
		Next += Size
	end

	if Count >= Minimum then
		return string.sub(Input, LastStart, Next - 1), Next
	end

	return string.sub(Input, Start, Next - 1), Next
end

-- @src scripts/util/String.cs:FormatTime L10-18
const function FormatTime(Seconds: number, PadMinutes: boolean?): string
	const Negative = Seconds < 0
	const Magnitude = math.abs(Seconds)
	const Minutes = Numbers.TruncInt32((Magnitude / 60) // 1)
	const WholeSeconds = Numbers.TruncInt32(math.fmod(Magnitude, 60) // 1)
	const MinuteText = if PadMinutes then string.format("%02d", Minutes) else tostring(Minutes)

	return `{if Negative then "-" else ""}{MinuteText}:{string.format("%02d", WholeSeconds)}`
end

-- @src scripts/util/String.cs:FormatUnixTimePretty L20-58
const function FormatUnixTimePretty(Now: number, Time: number): string
	const Difference = Now - Time
	const Prefix = if Difference < 0 then "in " else ""
	const Suffix = if Difference > 0 then " ago" else ""
	const Seconds = Difference // 1
	const Minutes = (Seconds / 60) // 1
	const Hours = (Minutes / 60) // 1
	const Days = (Hours / 24) // 1
	local Formatted: string

	if Days > 0 then
		Formatted = Plural(Days, "day")
	elseif Hours > 0 then
		Formatted = Plural(Hours, "hour")
	elseif Minutes > 0 then
		Formatted = Plural(Minutes, "minute")
	elseif Seconds > 0 then
		Formatted = Plural(Seconds, "second")
	else
		Formatted = "just now"
	end

	return `{Prefix}{Formatted}{Suffix}`
end

-- @src scripts/util/String.cs:SanitizeZalgo L65-70
const function SanitizeZalgo(Input: string, Limit: number?): string
	-- The source pattern is ([\p{M}]){N,} with N = Limit + 1, the int sum wrapping like C#.
	const Minimum = Numbers.Int32((Limit or 3) + 1)
	const Parts: { string } = {}
	local Position = 1

	while Position <= #Input do
		const CodePoint, Size = DotnetString.DecodeAt(Input, Position)

		if not IsMark(CodePoint) then
			table.insert(Parts, string.sub(Input, Position, Position + Size - 1))
			Position += Size
		elseif Minimum < 0 then
			-- With N < 0, "{N,}" is literal text after the group: a mark followed by it becomes the mark alone.
			const Quantifier = `\{{Minimum},}`
			const MarkEnd = Position + Size

			table.insert(Parts, string.sub(Input, Position, MarkEnd - 1))

			if string.sub(Input, MarkEnd, MarkEnd + #Quantifier - 1) == Quantifier then
				Position = MarkEnd + #Quantifier
			else
				Position = MarkEnd
			end
		else
			const Text, Next = CollapseRun(Input, Position, Minimum)

			table.insert(Parts, Text)
			Position = Next
		end
	end

	return table.concat(Parts)
end

-- @src scripts/util/String.cs:SanitizeBBCode L72-75
const function SanitizeBBCode(Input: string): string
	return DotnetString.Replace(Input, "[", "[lb]")
end

return {
	FormatTime = FormatTime,
	FormatUnixTimePretty = FormatUnixTimePretty,
	PadMagnitude = PadMagnitude,
	SanitizeZalgo = SanitizeZalgo,
	SanitizeBBCode = SanitizeBBCode,
}
