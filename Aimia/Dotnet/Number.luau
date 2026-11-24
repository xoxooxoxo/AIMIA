--!strict
--!optimize 2

--[[
	.NET number parsing with the invariant culture: int.Parse, float.Parse, double.Parse and their TryParse forms,
	for the NumberStyles the source uses (Integer, Float, Float | AllowThousands, Any).

	Design Notes
		The grammar follows .NET's Number.TryParseNumber state machine: leading white/sign/parenthesis/currency,
		digits with group separators and one decimal point, an optional exponent, then trailing white/sign/
		parenthesis/currency; the whole text must be consumed. Invariant symbols: "+", "-", ".", ",", currency
		"¤", "Infinity", "-Infinity", "NaN" (matched ignoring case when the number grammar fails, as .NET does).
		White space is U+0009..U+000D and U+0020.
		Single results round the double through Numbers.F32. DEVIATION(float32): .NET rounds the decimal text
		straight to float32; a decimal that lies within half an ulp of a float32 midpoint can differ by one ulp.
]]

const Numbers = require("../Numbers")

const AllowLeadingWhite = 0x001
const AllowTrailingWhite = 0x002
const AllowLeadingSign = 0x004
const AllowTrailingSign = 0x008
const AllowParentheses = 0x010
const AllowDecimalPoint = 0x020
const AllowThousands = 0x040
const AllowExponent = 0x080
const AllowCurrencySymbol = 0x100

const StateSign = 0x01
const StateParens = 0x02
const StateDigits = 0x04
const StateNonZero = 0x08
const StateDecimal = 0x10
const StateCurrency = 0x20

const Styles = {
	Integer = 0x007,
	Float = 0x0A7,
	FloatThousands = 0x0E7,
	Any = 0x1FF,
}

const Currency = "\u{A4}"
const Int32Max = 2147483647
const Int32Min = -2147483648

type Parsed = {
	Negative: boolean,
	Digits: string,
	Scale: number,
}

const function IsWhite(Character: number): boolean
	return Character == 0x20 or (Character >= 0x09 and Character <= 0x0D)
end

const function IsDigit(Character: number): boolean
	return Character >= 48 and Character <= 57
end

const function Matches(Text: string, Position: number, Symbol: string): boolean
	return string.sub(Text, Position, Position + #Symbol - 1) == Symbol
end

-- Returns the sign, the significant digits and the decimal exponent, or nil when the text is not a number.
const function ParseNumber(Text: string, Style: number): Parsed?
	const Length = #Text
	local Position = 1
	local State = 0
	local Negative = false
	local CurrencyOpen = bit32.btest(Style, AllowCurrencySymbol)

	while Position <= Length do
		const Character = string.byte(Text, Position)

		if not IsWhite(Character) or not bit32.btest(Style, AllowLeadingWhite) or (bit32.btest(State, StateSign) and not bit32.btest(State, StateCurrency)) then
			if bit32.btest(Style, AllowLeadingSign) and not bit32.btest(State, StateSign) and (Character == 43 or Character == 45) then
				State = bit32.bor(State, StateSign)
				Negative = Character == 45
			elseif Character == 40 and bit32.btest(Style, AllowParentheses) and not bit32.btest(State, StateSign) then
				State = bit32.bor(State, StateSign, StateParens)
				Negative = true
			elseif CurrencyOpen and Matches(Text, Position, Currency) then
				State = bit32.bor(State, StateCurrency)
				CurrencyOpen = false
				Position += #Currency - 1
			else
				break
			end
		end

		Position += 1
	end

	local Digits = ""
	local Scale = 0

	while Position <= Length do
		const Character = string.byte(Text, Position)

		if IsDigit(Character) then
			State = bit32.bor(State, StateDigits)

			if Character ~= 48 or bit32.btest(State, StateNonZero) then
				Digits = `{Digits}{string.char(Character)}`
				State = bit32.bor(State, StateNonZero)

				if not bit32.btest(State, StateDecimal) then
					Scale += 1
				end
			elseif bit32.btest(State, StateDecimal) then
				Scale -= 1
			end
		elseif bit32.btest(Style, AllowDecimalPoint) and not bit32.btest(State, StateDecimal) and Character == 46 then
			State = bit32.bor(State, StateDecimal)
		elseif bit32.btest(Style, AllowThousands) and bit32.btest(State, StateDigits) and not bit32.btest(State, StateDecimal) and Character == 44 then
			-- Group separators are skipped.
		else
			break
		end

		Position += 1
	end

	if not bit32.btest(State, StateDigits) then
		return nil
	end

	if Position <= Length and bit32.btest(Style, AllowExponent) then
		const Character = string.byte(Text, Position)

		if Character == 69 or Character == 101 then
			local Next = Position + 1
			local ExponentNegative = false
			const Sign = string.byte(Text, Next)

			if Sign == 43 then
				Next += 1
			elseif Sign == 45 then
				Next += 1
				ExponentNegative = true
			end

			const First = string.byte(Text, Next)

			if First and IsDigit(First) then
				local Exponent = 0

				while Next <= Length and IsDigit(string.byte(Text, Next)) do
					Exponent = math.min(Exponent * 10 + string.byte(Text, Next) - 48, 100000)
					Next += 1
				end

				Scale += if ExponentNegative then -Exponent else Exponent
				Position = Next
			end
		end
	end

	while Position <= Length do
		const Character = string.byte(Text, Position)

		if not IsWhite(Character) or not bit32.btest(Style, AllowTrailingWhite) then
			if bit32.btest(Style, AllowTrailingSign) and not bit32.btest(State, StateSign) and (Character == 43 or Character == 45) then
				State = bit32.bor(State, StateSign)
				Negative = Character == 45
			elseif Character == 41 and bit32.btest(State, StateParens) then
				State = bit32.band(State, bit32.bnot(StateParens))
			elseif CurrencyOpen and Matches(Text, Position, Currency) then
				CurrencyOpen = false
				Position += #Currency - 1
			else
				break
			end
		end

		Position += 1
	end

	if bit32.btest(State, StateParens) or Position <= Length then
		return nil
	end

	return {
		Negative = Negative,
		Digits = Digits,
		Scale = Scale,
	}
end

const function TrimWhite(Text: string): string
	local First = 1
	local Last = #Text

	while First <= Last and IsWhite(string.byte(Text, First)) do
		First += 1
	end

	while Last >= First and IsWhite(string.byte(Text, Last)) do
		Last -= 1
	end

	return string.sub(Text, First, Last)
end

-- The .NET fallback for symbols when the number grammar fails.
const function ParseSymbol(Text: string): number?
	const Trimmed = string.lower(TrimWhite(Text))

	if Trimmed == "infinity" or Trimmed == "+infinity" then
		return math.huge
	elseif Trimmed == "-infinity" then
		return -math.huge
	elseif Trimmed == "nan" or Trimmed == "+nan" or Trimmed == "-nan" then
		return 0 / 0
	end

	return nil
end

const function ToDouble(Number: Parsed): number
	local Value = 0

	if #Number.Digits > 0 then
		Value = tonumber(`0.{Number.Digits}e{Number.Scale}`) :: number
	end

	return if Number.Negative then -Value else Value
end

const function TryParseDouble(Text: string, Style: number?): (boolean, number)
	const Number = ParseNumber(Text, Style or Styles.FloatThousands)

	if Number then
		return true, ToDouble(Number)
	end

	const Symbol = ParseSymbol(Text)

	if Symbol then
		return true, Symbol
	end

	return false, 0
end

const function TryParseSingle(Text: string, Style: number?): (boolean, number)
	const Success, Value = TryParseDouble(Text, Style)

	return Success, Numbers.F32(Value)
end

const function TryParseInt32(Text: string, Style: number?): (boolean, number, boolean)
	const Number = ParseNumber(Text, Style or Styles.Integer)

	if not Number then
		return false, 0, false
	end

	const Digits = Number.Digits

	if Number.Scale < #Digits then
		-- Integers reject a fractional part unless it is all zeros, as .NET does.
		return false, 0, false
	end

	if Number.Scale > 10 then
		return false, 0, true
	end

	local Value = 0

	for Index = 1, Number.Scale do
		const Digit = if Index <= #Digits then string.byte(Digits, Index) - 48 else 0

		Value = Value * 10 + Digit
	end

	if Number.Negative then
		Value = -Value
	end

	if Value > Int32Max or Value < Int32Min then
		return false, 0, true
	end

	return true, Value, false
end

const function FormatError(Text: string): string
	return `The input string '{Text}' was not in a correct format.`
end

const function ParseInt32(Text: string, Style: number?): number
	const Success, Value, Overflow = TryParseInt32(Text, Style)

	if Success then
		return Value
	elseif Overflow then
		error("Value was either too large or too small for an Int32.", 0)
	end

	error(FormatError(Text), 0)
end

const function ParseSingle(Text: string, Style: number?): number
	const Success, Value = TryParseSingle(Text, Style)

	if not Success then
		error(FormatError(Text), 0)
	end

	return Value
end

const function ParseDouble(Text: string, Style: number?): number
	const Success, Value = TryParseDouble(Text, Style)

	if not Success then
		error(FormatError(Text), 0)
	end

	return Value
end

return {
	Styles = Styles,
	TryParseInt32 = TryParseInt32,
	TryParseSingle = TryParseSingle,
	TryParseDouble = TryParseDouble,
	ParseInt32 = ParseInt32,
	ParseSingle = ParseSingle,
	ParseDouble = ParseDouble,
}
