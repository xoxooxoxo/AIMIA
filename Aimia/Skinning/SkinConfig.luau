--!strict
--!optimize 2

--[[
	The skin's config.toml model, as scripts/skinning/SkinConfig.cs, with the TOML subset the model is read and written with.

	Design Notes
		Parse answers the model, or nil when the text is not valid for it, as Toml.TryToModel fails: a model key whose value is
		not one single-line string, a line that is not `key = value`, a table header, a duplicate key, or a string that does
		not close. A missing key keeps its default. A key the model does not have is skipped whatever its value.
		Write puts the five keys in declaration order, one `key = "value"` line each, and a final newline.
		DEVIATION: the subset is bare keys, basic ("...", with the TOML escapes) and literal ('...') single-line strings, and
		# comments. Multi-line strings, arrays, inline tables, numbers, booleans, dates and quoted keys are not read.
		Unverified against Tomlyn (its package is not available offline): the exact text Tomlyn writes, and whether it sets
		properties with a private setter (assumed: it does, so a stored config is read back).
]]

const DotnetString = require("../Dotnet/String")

export type SkinConfig = {
	ThemeColor: string,
	NoteColors: string,
	NoteMesh: string,
	GameSpace: string,
	MenuSpace: string,
}

-- The model's properties in declaration order, the keys Parse reads.
const Keys = { "ThemeColor", "NoteColors", "NoteMesh", "GameSpace", "MenuSpace" }

-- Bytes that separate tokens on a line (space, tab, carriage return).
const Whitespace = {
	[9] = true,
	[32] = true,
	[13] = true,
}

-- The single-character escapes of a TOML basic string, by the letter after the backslash.
const SimpleEscapes = {
	["b"] = "\b",
	["t"] = "\t",
	["n"] = "\n",
	["f"] = "\f",
	["r"] = "\r",
	['"'] = '"',
	["\\"] = "\\",
}

-- The escapes Write uses for a basic string's characters.
const WriteEscapes = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\t"] = "\\t",
	["\n"] = "\\n",
	["\f"] = "\\f",
	["\r"] = "\\r",
}

-- @src scripts/skinning/SkinConfig.cs:SkinConfig L1-12
const function New(): SkinConfig
	return {
		ThemeColor = "c90045",
		NoteColors = "default",
		NoteMesh = "squircle",
		GameSpace = "grid",
		MenuSpace = "waves",
	}
end

-- The escape at Position (the character after a backslash): the decoded text and the characters it used after the
-- backslash, or nil for an unknown escape, a bad hexadecimal number or a code point that is not a character.
const function DecodeEscape(Text: string, Position: number): (string?, number)
	const Letter = string.sub(Text, Position, Position)

	if SimpleEscapes[Letter] then
		return SimpleEscapes[Letter], 1
	end

	const Width = if Letter == "u" then 4 elseif Letter == "U" then 8 else 0
	const Digits = string.sub(Text, Position + 1, Position + Width)

	if Width == 0 or #Digits ~= Width or not string.match(Digits, "^%x+$") then
		return nil, 0
	end

	const CodePoint = tonumber(Digits, 16) :: number

	if CodePoint > 0x10FFFF or (CodePoint >= 0xD800 and CodePoint <= 0xDFFF) then
		return nil, 0
	end

	return utf8.char(CodePoint), Width + 1
end

-- The value of a basic ("...") or literal ('...') string that is all of Text, followed by white space or a comment only.
const function ParseString(Text: string): string?
	const Quote = string.sub(Text, 1, 1)

	if Quote ~= '"' and Quote ~= "'" then
		return nil
	end

	const Parts: { string } = {}
	local Position = 2

	while Position <= #Text do
		const Character = string.sub(Text, Position, Position)

		if Character == Quote then
			const Rest = DotnetString.TrimBytes(string.sub(Text, Position + 1), Whitespace, true, true)

			if #Rest == 0 or string.sub(Rest, 1, 1) == "#" then
				return table.concat(Parts)
			end

			return nil
		end

		if Quote == '"' and Character == "\\" then
			const Decoded, Consumed = DecodeEscape(Text, Position + 1)

			if not Decoded then
				return nil
			end

			table.insert(Parts, Decoded)
			Position += Consumed + 1
		else
			const Code = string.byte(Character)

			if (Code < 0x20 and Code ~= 0x09) or Code == 0x7F then
				return nil
			end

			table.insert(Parts, Character)
			Position += 1
		end
	end

	return nil
end

-- Tomlyn TryToModel for the model (no C# member).
const function Parse(Text: string): SkinConfig?
	const Found: { [string]: string } = {}
	const Seen: { [string]: boolean } = {}

	for _, Line in DotnetString.Split(Text, "\n") do
		const Trimmed = DotnetString.TrimBytes(Line, Whitespace, true, true)

		if #Trimmed > 0 and string.sub(Trimmed, 1, 1) ~= "#" then
			const Key, Value = string.match(Trimmed, "^([%w_%-]+)%s*=%s*(.-)$")

			if not Key or not Value or Seen[Key] then
				return nil
			end

			Seen[Key] = true

			if table.find(Keys, Key) then
				const Parsed = ParseString(Value)

				if not Parsed then
					return nil
				end

				Found[Key] = Parsed
			end
		end
	end

	const Defaults = New()

	return {
		ThemeColor = Found.ThemeColor or Defaults.ThemeColor,
		NoteColors = Found.NoteColors or Defaults.NoteColors,
		NoteMesh = Found.NoteMesh or Defaults.NoteMesh,
		GameSpace = Found.GameSpace or Defaults.GameSpace,
		MenuSpace = Found.MenuSpace or Defaults.MenuSpace,
	}
end

-- A value as a TOML basic string: quotes, backslashes and control characters escaped.
const function Quoted(Value: string): string
	const Escaped = string.gsub(Value, '[%c"\\]', function(Character: string): string
		return WriteEscapes[Character] or string.format("\\u%04X", string.byte(Character))
	end)

	return `"{Escaped}"`
end

-- Tomlyn TryFromModel for the model (no C# member).
const function Write(Config: SkinConfig): string
	const Lines = {
		`ThemeColor = {Quoted(Config.ThemeColor)}`,
		`NoteColors = {Quoted(Config.NoteColors)}`,
		`NoteMesh = {Quoted(Config.NoteMesh)}`,
		`GameSpace = {Quoted(Config.GameSpace)}`,
		`MenuSpace = {Quoted(Config.MenuSpace)}`,
	}

	return `{table.concat(Lines, "\n")}\n`
end

return {
	New = New,
	Parse = Parse,
	Write = Write,
}
