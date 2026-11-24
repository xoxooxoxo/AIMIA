--!strict
--!optimize 2

--[[
	The text forms the map info and score panels print, as the .NET 10 calls the source makes: the shortest round-trip
	double text (ToString()), fixed decimals (ToString("F2")), string.Format templates ({0}, {{ and }}) and Color.ToHtml.

	Design Notes
		Shortest keeps the fewest significant digits that read back exactly. It is scientific (d.dddE+xx) when the decimal
		exponent is below -4 or at least 17, otherwise plain: the thresholds of .NET's double.ToString() (oracle
		external/Oracle/Cases/MapInfo.cs). Negative zero is "-0", as .NET writes it.
		Fixed is the C printf rounding of the exact binary value, which rounds exact ties to even as .NET's "F" does.
]]

const Color = require("../../../../Godot/Color")
const Numbers = require("../../../../Numbers")

const ScientificBelow = -4
const ScientificFrom = 17

-- The shortest significant digits (no trailing zeros) and the decimal exponent of a positive finite number.
const function ShortestDigits(Magnitude: number): (string, number)
	local Scientific = ""

	for Precision = 0, 16 do
		Scientific = string.format(`%.{Precision}e`, Magnitude)

		if tonumber(Scientific) == Magnitude then
			break
		end
	end

	const Split = string.find(Scientific, "e", 1, true) :: number
	const Mantissa = string.sub(Scientific, 1, Split - 1)
	const Exponent = tonumber(string.sub(Scientific, Split + 1)) :: number
	const Digits = string.gsub(string.gsub(Mantissa, "%.", ""), "0+$", "")

	return Digits, Exponent
end

-- The text of a finite number in .NET's shortest form.
const function ScientificText(Digits: string, Exponent: number): string
	const Head = string.sub(Digits, 1, 1)
	const Tail = string.sub(Digits, 2)
	const Fraction = if #Tail > 0 then `.{Tail}` else ""
	const ExponentSign = if Exponent < 0 then "-" else "+"

	return `{Head}{Fraction}E{ExponentSign}{string.format("%02d", math.abs(Exponent))}`
end

-- The plain text of a finite number: the digits placed by the exponent, padded with zeros where they run out.
const function PlainText(Digits: string, Exponent: number): string
	if Exponent < 0 then
		return `0.{string.rep("0", -Exponent - 1)}{Digits}`
	end

	const IntegerLength = Exponent + 1
	const IntegerPart = if #Digits >= IntegerLength
		then string.sub(Digits, 1, IntegerLength)
		else `{Digits}{string.rep("0", IntegerLength - #Digits)}`
	const Fraction = string.sub(Digits, IntegerLength + 1)

	return if #Fraction > 0 then `{IntegerPart}.{Fraction}` else IntegerPart
end

-- The shortest round-trip text of a double, as double.ToString(CultureInfo.InvariantCulture).
const function Shortest(Value: number): string
	if Value ~= Value then
		return "NaN"
	elseif Value == math.huge then
		return "Infinity"
	elseif Value == -math.huge then
		return "-Infinity"
	elseif Value == 0 then
		return if 1 / Value < 0 then "-0" else "0"
	end

	const Sign = if Value < 0 then "-" else ""
	const Digits, Exponent = ShortestDigits(math.abs(Value))
	const Body = if Exponent < ScientificBelow or Exponent >= ScientificFrom
		then ScientificText(Digits, Exponent)
		else PlainText(Digits, Exponent)

	return `{Sign}{Body}`
end

-- ToString("F<Digits>") with the invariant culture.
const function Fixed(Value: number, Digits: number): string
	return string.format(`%.{Digits}f`, Value)
end

-- string.Format(format, args): {n} is the n-th argument (0-based), {{ and }} are braces.
const function Template(Format: string, Args: { string }): string
	const Parts: { string } = {}
	local Index = 1

	while Index <= #Format do
		const Char = string.sub(Format, Index, Index)
		const Next = string.sub(Format, Index + 1, Index + 1)

		if Char == "{" and Next == "{" then
			table.insert(Parts, "{")

			Index += 2
		elseif Char == "}" and Next == "}" then
			table.insert(Parts, "}")

			Index += 2
		elseif Char == "{" then
			const Close = string.find(Format, "}", Index, true)

			if not Close then
				error("Input string was not in a correct format.", 0)
			end

			const Argument = tonumber(string.sub(Format, Index + 1, Close - 1))

			if Argument == nil or Argument < 0 or Args[Argument + 1] == nil then
				error("Index was out of range. Must be non-negative and less than the size of the collection.", 0)
			end

			table.insert(Parts, Args[Argument + 1])

			Index = Close + 1
		elseif Char == "}" then
			error("Input string was not in a correct format.", 0)
		else
			table.insert(Parts, Char)

			Index += 1
		end
	end

	return table.concat(Parts)
end

-- One channel as two lowercase hex digits: round(clamp(value * 255)) (ToHex32 and HexEncode).
const function Channel(Value: number): string
	const Scaled = math.clamp(Numbers.F32(Value * 255), 0, 255)

	return string.format("%02x", Numbers.TruncInt32(Numbers.RoundHalfEven(Scaled)))
end

-- Color.ToHtml(includeAlpha = true): the RRGGBBAA hex of a color.
-- @src engine/Color.cs:ToHtml L562-576 (ToHex32 in engine/Color.cs L1020-1024, HexEncode in engine/StringExtensions.cs L670)
const function ToHtml(Value: Color.Color): string
	return `{Channel(Value.R)}{Channel(Value.G)}{Channel(Value.B)}{Channel(Value.A)}`
end

return {
	Shortest = Shortest,
	Fixed = Fixed,
	Template = Template,
	ToHtml = ToHtml,
}
