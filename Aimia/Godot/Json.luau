--!strict
--!optimize 2

--[[
	Godot's Json.ParseString and Json.Stringify for logic modules (pure Luau).

	Design Notes
		Parse answers nil on a syntax error (Godot prints the error and answers a null Variant). Numbers parse as
		doubles, as Godot's JSON does; objects become string-keyed tables, arrays Luau arrays; JSON null is
		the Null sentinel so arrays keep their length.
		Stringify writes keys sorted (Godot's sort_keys default), the indent per level, ": " after keys when
		indenting. DEVIATION: number text is the shortest form that reads back exactly ("1", "0.25"), not Godot's
		14-digit form; the port's files are only read back by the port. An empty table is written as [].
]]

const Logger = require("../Util/Logger")

const Null = newproxy(false)

type Reader = {
	Text: string,
	Position: number,
}

const Escapes = {
	[34] = "\"",
	[92] = "\\",
	[47] = "/",
	[98] = "\b",
	[102] = "\f",
	[110] = "\n",
	[114] = "\r",
	[116] = "\t",
}

const function SkipWhite(Reader: Reader)
	const Text = Reader.Text
	local Position = Reader.Position

	while Position <= #Text do
		const Character = string.byte(Text, Position)

		if Character ~= 32 and Character ~= 9 and Character ~= 10 and Character ~= 13 then
			break
		end

		Position += 1
	end

	Reader.Position = Position
end

const function Fail(Reader: Reader, Message: string): never
	error(`JSON parse error at {Reader.Position}: {Message}`, 0)
end

const function ReadHex(Reader: Reader): number
	const Digits = string.sub(Reader.Text, Reader.Position, Reader.Position + 3)
	const Value = if string.match(Digits, "^%x%x%x%x$") then tonumber(Digits, 16) else nil

	if not Value then
		Fail(Reader, "invalid unicode escape")
	end

	Reader.Position += 4

	return Value :: number
end

const function ReadString(Reader: Reader): string
	const Text = Reader.Text
	const Parts: { string } = {}

	Reader.Position += 1

	while true do
		const Position = Reader.Position
		const Character = string.byte(Text, Position)

		if not Character then
			Fail(Reader, "unterminated string")
		elseif Character == 34 then
			Reader.Position += 1
			return table.concat(Parts)
		elseif Character == 92 then
			const Kind = string.byte(Text, Position + 1)

			Reader.Position += 2

			if Kind == 117 then
				local CodePoint = ReadHex(Reader)

				if CodePoint >= 0xD800 and CodePoint <= 0xDBFF and string.sub(Text, Reader.Position, Reader.Position + 1) == "\\u" then
					Reader.Position += 2

					const Low = ReadHex(Reader)

					CodePoint = 0x10000 + (CodePoint - 0xD800) * 0x400 + (Low - 0xDC00)
				end

				table.insert(Parts, utf8.char(CodePoint))
			else
				const Escape = if Kind then Escapes[Kind] else nil

				if not Escape then
					Fail(Reader, "invalid escape")
				end

				table.insert(Parts, Escape :: string)
			end
		else
			const Next = string.find(Text, "[\"\\]", Position) or #Text + 1

			table.insert(Parts, string.sub(Text, Position, Next - 1))
			Reader.Position = Next
		end
	end
end

const function FormatNumber(Value: number): string
	if Value ~= Value then
		return "NaN"
	elseif Value == math.huge then
		return "inf"
	elseif Value == -math.huge then
		return "-inf"
	elseif Value == Value // 1 and math.abs(Value) < 2 ^ 53 then
		return string.format("%d", Value)
	end

	for Digits = 15, 17 do
		const Text = string.format(`%.{Digits}g`, Value)

		if tonumber(Text) == Value then
			return Text
		end
	end

	return string.format("%.17g", Value)
end

const function Quote(Text: string): string
	const Escaped = string.gsub(Text, "[%c\"\\]", function(Character: string): string
		const Code = string.byte(Character)

		if Code == 34 then
			return "\\\""
		elseif Code == 92 then
			return "\\\\"
		elseif Code == 8 then
			return "\\b"
		elseif Code == 12 then
			return "\\f"
		elseif Code == 10 then
			return "\\n"
		elseif Code == 13 then
			return "\\r"
		elseif Code == 9 then
			return "\\t"
		end

		return string.format("\\u%04x", Code)
	end)

	return `"{Escaped}"`
end

const function Write(Value: unknown, Indent: string, Level: number, Parts: { string })
	const Kind = type(Value)

	if Value == Null or Value == nil then
		table.insert(Parts, "null")
	elseif Kind == "boolean" then
		table.insert(Parts, if Value then "true" else "false")
	elseif Kind == "number" then
		table.insert(Parts, FormatNumber(Value :: number))
	elseif Kind == "string" then
		table.insert(Parts, Quote(Value :: string))
	elseif Kind == "table" then
		const Table = Value :: { [unknown]: unknown }
		const Newline = if #Indent > 0 then "\n" else ""
		const Inner = string.rep(Indent, Level + 1)
		const Outer = string.rep(Indent, Level)

		if next(Table) == nil or #Table > 0 then
			const Items = Table :: { unknown }

			if #Items == 0 then
				table.insert(Parts, "[]")
				return
			end

			table.insert(Parts, `[{Newline}`)

			for Index, Item in Items do
				table.insert(Parts, Inner)
				Write(Item, Indent, Level + 1, Parts)
				table.insert(Parts, if Index < #Items then `,{Newline}` else Newline)
			end

			table.insert(Parts, `{Outer}]`)
			return
		end

		const Keys: { string } = {}

		for Key in Table do
			table.insert(Keys, tostring(Key))
		end

		table.sort(Keys)
		table.insert(Parts, `\{{Newline}`)

		const Colon = if #Indent > 0 then ": " else ":"

		for Index, Key in Keys do
			table.insert(Parts, `{Inner}{Quote(Key)}{Colon}`)
			Write(Table[Key], Indent, Level + 1, Parts)
			table.insert(Parts, if Index < #Keys then `,{Newline}` else Newline)
		end

		table.insert(Parts, `{Outer}}`)
	else
		table.insert(Parts, "null")
	end
end

const function ReadValue(Reader: Reader): unknown
	SkipWhite(Reader)

	const Text = Reader.Text
	const Position = Reader.Position
	const Character = string.byte(Text, Position)

	if Character == 123 then
		const Values: { [string]: unknown } = {}

		Reader.Position += 1
		SkipWhite(Reader)

		if string.byte(Text, Reader.Position) == 125 then
			Reader.Position += 1
			return Values
		end

		while true do
			SkipWhite(Reader)

			if string.byte(Text, Reader.Position) ~= 34 then
				Fail(Reader, "expected key")
			end

			const Key = ReadString(Reader)

			SkipWhite(Reader)

			if string.byte(Text, Reader.Position) ~= 58 then
				Fail(Reader, "expected ':'")
			end

			Reader.Position += 1
			Values[Key] = ReadValue(Reader)
			SkipWhite(Reader)

			const Next = string.byte(Text, Reader.Position)

			Reader.Position += 1

			if Next == 125 then
				return Values
			elseif Next ~= 44 then
				Fail(Reader, "expected ',' or '}'")
			end
		end
	elseif Character == 91 then
		const Values: { unknown } = {}

		Reader.Position += 1
		SkipWhite(Reader)

		if string.byte(Text, Reader.Position) == 93 then
			Reader.Position += 1
			return Values
		end

		while true do
			table.insert(Values, ReadValue(Reader))
			SkipWhite(Reader)

			const Next = string.byte(Text, Reader.Position)

			Reader.Position += 1

			if Next == 93 then
				return Values
			elseif Next ~= 44 then
				Fail(Reader, "expected ',' or ']'")
			end
		end
	elseif Character == 34 then
		return ReadString(Reader)
	elseif string.sub(Text, Position, Position + 3) == "true" then
		Reader.Position += 4
		return true
	elseif string.sub(Text, Position, Position + 4) == "false" then
		Reader.Position += 5
		return false
	elseif string.sub(Text, Position, Position + 3) == "null" then
		Reader.Position += 4
		return Null
	end

	const Number = string.match(Text, "^-?%d+%.?%d*[eE]?[-+]?%d*", Position)
	const Value = if Number then tonumber(Number) else nil

	if not Value then
		Fail(Reader, "unexpected character")
	end

	Reader.Position += #(Number :: string)

	return Value
end

const function Parse(Text: string): unknown
	const Reader = {
		Text = Text,
		Position = 1,
	}

	const Success, Result = pcall(function()
		const Value = ReadValue(Reader)

		SkipWhite(Reader)

		if Reader.Position <= #Text then
			Fail(Reader, "expected end of text")
		end

		return Value
	end)

	if not Success then
		Logger.Error(tostring(Result))
		return nil
	end

	return Result
end

const function Stringify(Value: unknown, Indent: string?): string
	const Parts: { string } = {}

	Write(Value, Indent or "", 0, Parts)

	return table.concat(Parts)
end

return {
	Null = Null,
	Parse = Parse,
	Stringify = Stringify,
}
