--!strict
--!optimize 2

--[[
	.NET System.String members the source uses, on Luau (UTF-8) strings, ordinal comparison.

	Design Notes
		Split keeps empty entries (StringSplitOptions.None); an empty separator returns the text whole, and a
		count caps the number of parts with the remainder in the last one, as .NET does.
		Trim removes char.IsWhiteSpace code points (decoded from UTF-8) at both ends. Separators and trim sets
		given as bytes are ASCII, so byte operations match UTF-16 ones.
]]

const MaxCount = 2147483647

const function IsWhiteSpace(CodePoint: number): boolean
	return (CodePoint >= 0x09 and CodePoint <= 0x0D)
		or CodePoint == 0x20
		or CodePoint == 0x85
		or CodePoint == 0xA0
		or CodePoint == 0x1680
		or (CodePoint >= 0x2000 and CodePoint <= 0x200A)
		or CodePoint == 0x2028
		or CodePoint == 0x2029
		or CodePoint == 0x202F
		or CodePoint == 0x205F
		or CodePoint == 0x3000
end

-- Decodes the UTF-8 sequence starting at a byte position; answers the code point and the sequence length.
const function DecodeAt(Text: string, Position: number): (number, number)
	const Lead = string.byte(Text, Position)

	if Lead < 0x80 then
		return Lead, 1
	end

	const Length = if Lead >= 0xF0 then 4 elseif Lead >= 0xE0 then 3 elseif Lead >= 0xC0 then 2 else 1

	if Length == 1 or Position + Length - 1 > #Text then
		return Lead, 1
	end

	local CodePoint = bit32.band(Lead, bit32.rshift(0x7F, Length))

	for Offset = 1, Length - 1 do
		CodePoint = bit32.bor(bit32.lshift(CodePoint, 6), bit32.band(string.byte(Text, Position + Offset), 0x3F))
	end

	return CodePoint, Length
end

-- .NET String.Split(string separator, int count, StringSplitOptions.None)
const function Split(Text: string, Separator: string, Count: number?): { string }
	const Limit = Count or MaxCount
	const Parts: { string } = {}

	if Limit == 0 then
		return Parts
	end

	if #Separator == 0 or Limit == 1 then
		table.insert(Parts, Text)
		return Parts
	end

	local Start = 1

	while #Parts < Limit - 1 do
		const First, Last = string.find(Text, Separator, Start, true)

		if not First then
			break
		end

		table.insert(Parts, string.sub(Text, Start, First - 1))
		Start = (Last :: number) + 1
	end

	table.insert(Parts, string.sub(Text, Start))

	return Parts
end

-- .NET String.Split(char[] separator)
const function SplitAny(Text: string, Separators: { string }): { string }
	const Parts: { string } = {}
	local Start = 1

	for Position = 1, #Text do
		const Character = string.sub(Text, Position, Position)

		if table.find(Separators, Character) then
			table.insert(Parts, string.sub(Text, Start, Position - 1))
			Start = Position + 1
		end
	end

	table.insert(Parts, string.sub(Text, Start))

	return Parts
end

-- .NET String.Trim()
const function Trim(Text: string): string
	local First = 1
	local Last = #Text

	while First <= Last do
		const CodePoint, Length = DecodeAt(Text, First)

		if not IsWhiteSpace(CodePoint) then
			break
		end

		First += Length
	end

	while Last >= First do
		local Start = Last

		while Start > First and bit32.band(string.byte(Text, Start), 0xC0) == 0x80 do
			Start -= 1
		end

		const CodePoint = DecodeAt(Text, Start)

		if not IsWhiteSpace(CodePoint) then
			break
		end

		Last = Start - 1
	end

	return string.sub(Text, First, Last)
end

-- .NET String.Trim(char[]), TrimStart(char[]), TrimEnd(char[]) for an ASCII set given as a byte lookup
const function TrimBytes(Text: string, Set: { [number]: boolean }, Start: boolean, End: boolean): string
	local First = 1
	local Last = #Text

	if Start then
		while First <= Last and Set[string.byte(Text, First)] do
			First += 1
		end
	end

	if End then
		while Last >= First and Set[string.byte(Text, Last)] do
			Last -= 1
		end
	end

	return string.sub(Text, First, Last)
end

const function StartsWith(Text: string, Prefix: string): boolean
	return string.sub(Text, 1, #Prefix) == Prefix
end

const function EndsWith(Text: string, Suffix: string): boolean
	return #Suffix == 0 or string.sub(Text, -#Suffix) == Suffix
end

const function Contains(Text: string, Value: string): boolean
	return string.find(Text, Value, 1, true) ~= nil
end

-- Byte index (0-based, like .NET) of the last occurrence, or -1.
const function LastIndexOf(Text: string, Value: string): number
	local Found = -1
	local Start = 1

	while true do
		const First = string.find(Text, Value, Start, true)

		if not First then
			return Found
		end

		Found = First - 1
		Start = First + 1
	end
end

const function Replace(Text: string, Old: string, New: string): string
	const Parts = Split(Text, Old)

	return table.concat(Parts, New)
end

const function IsNullOrEmpty(Text: string?): boolean
	return Text == nil or #Text == 0
end

const function IsNullOrWhiteSpace(Text: string?): boolean
	return Text == nil or #Trim(Text) == 0
end

return {
	Split = Split,
	SplitAny = SplitAny,
	Trim = Trim,
	TrimBytes = TrimBytes,
	StartsWith = StartsWith,
	EndsWith = EndsWith,
	Contains = Contains,
	LastIndexOf = LastIndexOf,
	Replace = Replace,
	IsNullOrEmpty = IsNullOrEmpty,
	IsNullOrWhiteSpace = IsNullOrWhiteSpace,
	DecodeAt = DecodeAt,
}
