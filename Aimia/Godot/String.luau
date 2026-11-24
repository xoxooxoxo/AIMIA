--!strict
--!optimize 2

--[[
	Godot's C# string extensions the source uses, ported from GodotSharp Core/StringExtensions.cs (Godot 4.7.2).

	Design Notes
		ToInt is int.Parse and ToFloat is float.Parse with the invariant culture (they throw on bad input).
		RFind is an ordinal LastIndexOf; the separators are ASCII, so byte positions match UTF-16 positions.
		Join: DEVIATION: its definition is not in StringExtensions.cs; the delimiter defaults to ", " as Godot's
		String.join is used with it, unverified.
]]

const DotnetNumber = require("../Dotnet/Number")
const DotnetString = require("../Dotnet/String")

const NonPrintable: { [number]: boolean } = {}

for Code = 0, 32 do
	NonPrintable[Code] = true
end

-- @src engine/StringExtensions.cs:GetExtension L429-437
const function GetExtension(Text: string): string
	const Position = DotnetString.LastIndexOf(Text, ".")

	if Position < 0 or Position < math.max(DotnetString.LastIndexOf(Text, "/"), DotnetString.LastIndexOf(Text, "\\")) then
		return ""
	end

	return string.sub(Text, Position + 2)
end

-- @src engine/StringExtensions.cs:GetBaseName L549-557
const function GetBaseName(Text: string): string
	const Index = DotnetString.LastIndexOf(Text, ".")

	if Index > 0 then
		return string.sub(Text, 1, Index)
	end

	return Text
end

-- @src engine/StringExtensions.cs:GetFile L567-575
const function GetFile(Text: string): string
	const Separator = math.max(DotnetString.LastIndexOf(Text, "/"), DotnetString.LastIndexOf(Text, "\\"))

	if Separator == -1 then
		return Text
	end

	return string.sub(Text, Separator + 2)
end

-- @src engine/StringExtensions.cs:StripEdges L1570-1580
const function StripEdges(Text: string, Left: boolean?, Right: boolean?): string
	return DotnetString.TrimBytes(Text, NonPrintable, Left ~= false, Right ~= false)
end

-- @src engine/StringExtensions.cs:StripEscapes L1591-1604
const function StripEscapes(Text: string): string
	return (string.gsub(Text, "[\0-\31]", ""))
end

-- @src engine/StringExtensions.cs:ToFloat L1642-1645
const function ToFloat(Text: string): number
	return DotnetNumber.ParseSingle(Text)
end

-- @src engine/StringExtensions.cs:ToInt L1653-1656
const function ToInt(Text: string): number
	return DotnetNumber.ParseInt32(Text)
end

-- @src engine/StringExtensions.cs:TrimPrefix L1706-1712
const function TrimPrefix(Text: string, Prefix: string): string
	if DotnetString.StartsWith(Text, Prefix) then
		return string.sub(Text, #Prefix + 1)
	end

	return Text
end

-- @src engine/StringExtensions.cs:TrimSuffix L1720-1726
const function TrimSuffix(Text: string, Suffix: string): string
	if DotnetString.EndsWith(Text, Suffix) then
		return string.sub(Text, 1, #Text - #Suffix)
	end

	return Text
end

const function Join(Parts: { string }, Delimiter: string?): string
	return table.concat(Parts, Delimiter or ", ")
end

return {
	GetExtension = GetExtension,
	GetBaseName = GetBaseName,
	GetFile = GetFile,
	StripEdges = StripEdges,
	StripEscapes = StripEscapes,
	ToFloat = ToFloat,
	ToInt = ToInt,
	TrimPrefix = TrimPrefix,
	TrimSuffix = TrimSuffix,
	Join = Join,
}
