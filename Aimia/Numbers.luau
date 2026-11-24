--!optimize 2

--[[
	Source-language number semantics for ports: int32/uint32 wrapping, narrow widths, truncating division,
	exact float32 rounding (C float arithmetic), Java-style float-to-int casts, source rounding modes, 64-bit integers as two uint32
	words (Hi, Lo), and a stable sort. Function names are the ones the port checker accepts as evidence.

	64-bit values travel as two return values (Hi, Lo), both uint32 words, so no tables are created. A 64-bit value that a
	program stores, passes or returns as one value is a Bits64 { Hi, Lo } table, never changed in place: every Bits64*
	function answers a new one.
]]

export type Bits64 = { Hi: number, Lo: number }

const Word = 4294967296
const Half = 65536

const function Signed(Value: number): number
	return if Value >= 2147483648 then Value - Word else Value
end

const function Int32(Value: number): number
	return Signed(bit32.bor(Value, 0))
end

const function Uint32(Value: number): number
	return bit32.bor(Value, 0)
end

const function Int16(Value: number): number
	const Bits = bit32.band(Value, 0xFFFF)

	return if Bits >= 32768 then Bits - 65536 else Bits
end

const function Uint16(Value: number): number
	return bit32.band(Value, 0xFFFF)
end

const function Int8(Value: number): number
	const Bits = bit32.band(Value, 0xFF)

	return if Bits >= 128 then Bits - 256 else Bits
end

const function Uint8(Value: number): number
	return bit32.band(Value, 0xFF)
end

-- int32 * int32 wrapped like Java/C#/Go; the plain product can pass 2^53 before wrapping.
const function Mul32(A: number, B: number): number
	const AL = bit32.band(A, 0xFFFF)
	const AH = bit32.rshift(bit32.bor(A, 0), 16)
	const BL = bit32.band(B, 0xFFFF)
	const BH = bit32.rshift(bit32.bor(B, 0), 16)

	return Int32(AL * BL + bit32.lshift(bit32.band(AH * BL + AL * BH, 0xFFFF), 16))
end

-- Truncation toward zero for integer results: -0.5 gives 0, not -0 (source integers have no negative zero).
const function Trunc(Value: number): number
	const Whole = math.modf(Value)

	return Whole + 0
end

-- Integer division truncating toward zero (C, Java, C#, Go, Rust). MIN / -1 wraps to MIN; B == 0 errors like Java/C#/Go/Rust.
const function TruncDiv32(A: number, B: number): number
	if B == 0 then
		error("integer division by zero", 2)
	end

	return Int32(Trunc(A / B))
end

-- Java (int) cast of a float/double: NaN -> 0, saturates at the int range, truncates toward zero.
-- Java Math.round(float) is TruncInt32(RoundHalfUp(Value)).
-- C (int) cast of a float/double: the same inside the int range; outside it (and for NaN) the cast is undefined
-- behavior, so there is no result to match: x86-64 hardware gives INT_MIN, this helper saturates. A port states
-- the policy once.
const function TruncInt32(Value: number): number
	if Value ~= Value then
		return 0
	end

	return math.clamp(Trunc(Value), -2147483648, 2147483647)
end

-- IEEE binary32 rounding (round to nearest, ties to even; overflow gives ±Infinity; NaN, ±0 and subnormals follow
-- the hardware conversion): a `vector` component is a float32, so `vector.create` rounds a double exactly like a C
-- (float) cast. Every C/Java/C#/Rust float operation (+ - * /, sqrt) is the correctly rounded result of the exact
-- one, and computing it in a double then rounding once equals that result (a double has more than twice a float's
-- precision plus 2 bits), so a float32 result is F32(A op B) with float32 operands, as C compiles it without
-- extended precision (x86-64 SSE, no -ffast-math, no contraction into fused multiply-add). An int operand converts
-- with F32 as well (an int32 or uint32 above 2^24 rounds), a float operand of a double operation does not.
-- Comparisons of float32 values are plain Luau comparisons.
const function F32(Value: number): number
	return vector.create(Value, 0, 0).x
end

-- Java/JS Math.round: half rounds up (-2.5 -> -2). Exact, unlike (Value + 0.5) // 1 for 0.49999999999999994.
-- Zero results are +0 (Java integers); JS returns -0 for inputs in [-0.5, -0].
-- NaN and infinities pass through (JS); Java's int/long results come from TruncInt32 / TruncInt64 around it.
const function RoundHalfUp(Value: number): number
	const Floor = Value // 1

	return if Value - Floor >= 0.5 then Floor + 1 else Floor + 0
end

-- C# Math.Round / Python round: half rounds to even (2.5 -> 2, 3.5 -> 4).
const function RoundHalfEven(Value: number): number
	const Floor = Value // 1
	const Fraction = Value - Floor

	if Fraction > 0.5 then
		return Floor + 1
	elseif Fraction < 0.5 then
		return Floor
	end

	return if Floor % 2 == 0 then Floor else Floor + 1
end

-- 64-bit integers: Hi and Lo are uint32 words of the two's complement value.

-- Value must be an integer in [-2^63, 2^63); every such double converts exactly.
const function Int64FromNumber(Value: number): (number, number)
	const Hi = Value // Word

	return bit32.bor(Hi, 0), Value - Hi * Word
end

-- Java (long) cast of a float/double: NaN -> 0, saturates at the long range, truncates toward zero.
-- Java Math.round(double) is TruncInt64(RoundHalfUp(Value)).
const function TruncInt64(Value: number): (number, number)
	if Value ~= Value then
		return 0, 0
	elseif Value >= 9223372036854775808 then
		return 0x7FFFFFFF, 0xFFFFFFFF
	elseif Value <= -9223372036854775808 then
		return 0x80000000, 0
	end

	return Int64FromNumber(Trunc(Value))
end

-- Correctly rounded like Java/C# (double) long: the sum of two exact terms is rounded once.
const function Int64ToNumber(Hi: number, Lo: number): number
	return Signed(Hi) * Word + Lo
end

-- Correctly rounded (double) of an unsigned 64-bit value.
const function Uint64ToNumber(Hi: number, Lo: number): number
	return Hi * Word + Lo
end

const function Int64Add(AH: number, AL: number, BH: number, BL: number): (number, number)
	const Low = AL + BL
	const Carry = if Low >= Word then 1 else 0

	return bit32.bor(AH + BH + Carry, 0), Low - Carry * Word
end

const function Int64Negate(Hi: number, Lo: number): (number, number)
	const Low = bit32.bnot(Lo) + 1
	const Carry = if Low >= Word then 1 else 0

	return bit32.bor(bit32.bnot(Hi) + Carry, 0), Low - Carry * Word
end

const function Int64Sub(AH: number, AL: number, BH: number, BL: number): (number, number)
	const Low = AL - BL
	const Borrow = if Low < 0 then 1 else 0

	return bit32.bor(AH - BH - Borrow, 0), Low + Borrow * Word
end

-- Low 64 bits of the product, from 16-bit limbs so every partial sum stays below 2^53.
const function Int64Mul(AH: number, AL: number, BH: number, BL: number): (number, number)
	const A0 = bit32.band(AL, 0xFFFF)
	const A1 = bit32.rshift(AL, 16)
	const A2 = bit32.band(AH, 0xFFFF)
	const A3 = bit32.rshift(AH, 16)
	const B0 = bit32.band(BL, 0xFFFF)
	const B1 = bit32.rshift(BL, 16)
	const B2 = bit32.band(BH, 0xFFFF)
	const B3 = bit32.rshift(BH, 16)

	const R0 = A0 * B0
	const R1 = A1 * B0 + A0 * B1 + R0 // Half
	const R2 = A2 * B0 + A1 * B1 + A0 * B2 + R1 // Half
	const R3 = A3 * B0 + A2 * B1 + A1 * B2 + A0 * B3 + R2 // Half

	return (R3 % Half) * Half + R2 % Half, (R1 % Half) * Half + R0 % Half
end

-- Shift counts use the low 6 bits, like Java and C#.
const function Int64ShiftLeft(Hi: number, Lo: number, Count: number): (number, number)
	const Shift = bit32.band(Count, 63)

	if Shift == 0 then
		return Hi, Lo
	elseif Shift >= 32 then
		return bit32.lshift(Lo, Shift - 32), 0
	end

	return bit32.bor(bit32.lshift(Hi, Shift), bit32.rshift(Lo, 32 - Shift)), bit32.lshift(Lo, Shift)
end

-- Arithmetic (sign-filling) >> on a signed 64-bit value.
const function Int64ShiftRight(Hi: number, Lo: number, Count: number): (number, number)
	const Shift = bit32.band(Count, 63)

	if Shift == 0 then
		return Hi, Lo
	elseif Shift >= 32 then
		return bit32.arshift(Hi, 31), bit32.arshift(Hi, Shift - 32)
	end

	return bit32.arshift(Hi, Shift), bit32.bor(bit32.rshift(Lo, Shift), bit32.lshift(Hi, 32 - Shift))
end

-- Logical (zero-filling) >>> on a 64-bit value.
const function Int64ShiftRightLogical(Hi: number, Lo: number, Count: number): (number, number)
	const Shift = bit32.band(Count, 63)

	if Shift == 0 then
		return Hi, Lo
	elseif Shift >= 32 then
		return 0, bit32.rshift(Hi, Shift - 32)
	end

	return bit32.rshift(Hi, Shift), bit32.bor(bit32.rshift(Lo, Shift), bit32.lshift(Hi, 32 - Shift))
end

const function Int64And(AH: number, AL: number, BH: number, BL: number): (number, number)
	return bit32.band(AH, BH), bit32.band(AL, BL)
end

const function Int64Or(AH: number, AL: number, BH: number, BL: number): (number, number)
	return bit32.bor(AH, BH), bit32.bor(AL, BL)
end

const function Int64Xor(AH: number, AL: number, BH: number, BL: number): (number, number)
	return bit32.bxor(AH, BH), bit32.bxor(AL, BL)
end

const function Int64Not(Hi: number, Lo: number): (number, number)
	return bit32.bnot(Hi), bit32.bnot(Lo)
end

-- Signed comparison: -1, 0 or 1.
const function Int64Compare(AH: number, AL: number, BH: number, BL: number): number
	const SignedA = Signed(AH)
	const SignedB = Signed(BH)

	if SignedA ~= SignedB then
		return if SignedA < SignedB then -1 else 1
	elseif AL ~= BL then
		return if AL < BL then -1 else 1
	end

	return 0
end

-- Unsigned comparison: -1, 0 or 1.
const function Uint64Compare(AH: number, AL: number, BH: number, BL: number): number
	if AH ~= BH then
		return if AH < BH then -1 else 1
	elseif AL ~= BL then
		return if AL < BL then -1 else 1
	end

	return 0
end

-- C (float) of an unsigned 64-bit value, rounded once. Rounding through a double first can go the wrong way when
-- the double lands exactly between two floats and the discarded low bits decide the tie, so the low bits that do
-- not fit 53 bits are folded into the lowest kept bit (round to odd); rounding that to 24 bits is then exact.
const function Uint64ToF32(Hi: number, Lo: number): number
	const Length = if Hi ~= 0 then 64 - bit32.countlz(Hi) else 32 - bit32.countlz(Lo)

	if Length <= 53 then
		return F32(Hi * Word + Lo)
	end

	const Shift = Length - 53
	const KeptHi, KeptLo = Int64ShiftRightLogical(Hi, Lo, Shift)
	const BackHi, BackLo = Int64ShiftLeft(KeptHi, KeptLo, Shift)
	const Sticky = if BackHi == Hi and BackLo == Lo then 0 else 1

	return F32((KeptHi * Word + KeptLo + (1 - KeptLo % 2) * Sticky) * 2 ^ Shift)
end

-- C (float) of a signed 64-bit value, rounded once.
const function Int64ToF32(Hi: number, Lo: number): number
	if Hi < 2147483648 then
		return Uint64ToF32(Hi, Lo)
	end

	const MagnitudeHi, MagnitudeLo = Int64Negate(Hi, Lo)

	return -Uint64ToF32(MagnitudeHi, MagnitudeLo)
end

-- Unsigned 64-bit division; a zero divisor errors. Every intermediate stays below 2^53.
const function Uint64DivRem(NH: number, NL: number, DH: number, DL: number): (number, number, number, number)
	if DH == 0 and DL == 0 then
		error("integer division by zero", 2)
	end

	if DH == 0 then
		if NH == 0 then
			const Quotient = NL // DL

			return 0, Quotient, 0, NL - Quotient * DL
		end

		-- 64 / 32 bits: long division over four 16-bit limbs.
		local Part = bit32.rshift(NH, 16)
		const Q0 = Part // DL

		Part = (Part - Q0 * DL) * Half + bit32.band(NH, 0xFFFF)

		const Q1 = Part // DL

		Part = (Part - Q1 * DL) * Half + bit32.rshift(NL, 16)

		const Q2 = Part // DL

		Part = (Part - Q2 * DL) * Half + bit32.band(NL, 0xFFFF)

		const Q3 = Part // DL

		return Q0 * Half + Q1, Q2 * Half + Q3, 0, Part - Q3 * DL
	end

	if NH < DH or (NH == DH and NL < DL) then
		return 0, 0, NH, NL
	end

	-- Both high words are non-zero, so the quotient fits in 32 bits: shift-subtract over the bit-length gap.
	const Shift = bit32.countlz(DH) - bit32.countlz(NH)
	local SH, SL = Int64ShiftLeft(DH, DL, Shift)
	local RH, RL = NH, NL
	local Quotient = 0

	for Bit = Shift, 0, -1 do
		if RH > SH or (RH == SH and RL >= SL) then
			RH, RL = Int64Sub(RH, RL, SH, SL)
			Quotient = bit32.replace(Quotient, 1, Bit)
		end

		SH, SL = bit32.rshift(SH, 1), bit32.bor(bit32.rshift(SL, 1), bit32.lshift(SH, 31))
	end

	return 0, Quotient, RH, RL
end

-- Signed division truncating toward zero (Java/C# long / and %); a zero divisor errors. MIN / -1 wraps to MIN.
const function Int64DivRem(NH: number, NL: number, DH: number, DL: number): (number, number, number, number)
	const NegativeN = NH >= 2147483648
	const NegativeD = DH >= 2147483648
	local AH, AL = NH, NL
	local BH, BL = DH, DL

	if NegativeN then
		AH, AL = Int64Negate(AH, AL)
	end

	if NegativeD then
		BH, BL = Int64Negate(BH, BL)
	end

	local QH, QL, RH, RL = Uint64DivRem(AH, AL, BH, BL)

	if NegativeN ~= NegativeD then
		QH, QL = Int64Negate(QH, QL)
	end

	if NegativeN then
		RH, RL = Int64Negate(RH, RL)
	end

	return QH, QL, RH, RL
end

-- A 64-bit integer as one value: an immutable { Hi, Lo } table of the uint32 words of its two's complement.

-- Value must be an integer in [-2^63, 2^63); a uint64 past that is built from its words.
const function Bits64FromNumber(Value: number): Bits64
	const Hi, Lo = Int64FromNumber(Value)

	return { Hi = Hi, Lo = Lo }
end

-- The correctly rounded double of the signed or unsigned value.
const function Bits64ToNumber(A: Bits64, Signed64: boolean): number
	return if Signed64 then Int64ToNumber(A.Hi, A.Lo) else Uint64ToNumber(A.Hi, A.Lo)
end

-- The exact number of a value in [-2^53, 2^53) (an index, a count, a size passed on as a number); anything wider is an error.
const function Bits64ToInteger(A: Bits64, Signed64: boolean): number
	const Hi = if Signed64 and A.Hi >= 0x80000000 then A.Hi - 0x100000000 else A.Hi

	if Hi < -0x200000 or Hi >= 0x200000 then
		error("64-bit value does not fit a number exactly", 2)
	end

	return Hi * 0x100000000 + A.Lo
end

const function Bits64ToF32(A: Bits64, Signed64: boolean): number
	return if Signed64 then Int64ToF32(A.Hi, A.Lo) else Uint64ToF32(A.Hi, A.Lo)
end

const function Bits64Add(A: Bits64, B: Bits64): Bits64
	const Hi, Lo = Int64Add(A.Hi, A.Lo, B.Hi, B.Lo)

	return { Hi = Hi, Lo = Lo }
end

const function Bits64Sub(A: Bits64, B: Bits64): Bits64
	const Hi, Lo = Int64Sub(A.Hi, A.Lo, B.Hi, B.Lo)

	return { Hi = Hi, Lo = Lo }
end

const function Bits64Mul(A: Bits64, B: Bits64): Bits64
	const Hi, Lo = Int64Mul(A.Hi, A.Lo, B.Hi, B.Lo)

	return { Hi = Hi, Lo = Lo }
end

const function Bits64Negate(A: Bits64): Bits64
	const Hi, Lo = Int64Negate(A.Hi, A.Lo)

	return { Hi = Hi, Lo = Lo }
end

const function Bits64And(A: Bits64, B: Bits64): Bits64
	return { Hi = bit32.band(A.Hi, B.Hi), Lo = bit32.band(A.Lo, B.Lo) }
end

const function Bits64Or(A: Bits64, B: Bits64): Bits64
	return { Hi = bit32.bor(A.Hi, B.Hi), Lo = bit32.bor(A.Lo, B.Lo) }
end

const function Bits64Xor(A: Bits64, B: Bits64): Bits64
	return { Hi = bit32.bxor(A.Hi, B.Hi), Lo = bit32.bxor(A.Lo, B.Lo) }
end

const function Bits64Not(A: Bits64): Bits64
	return { Hi = bit32.bnot(A.Hi), Lo = bit32.bnot(A.Lo) }
end

const function Bits64ShiftLeft(A: Bits64, Count: number): Bits64
	const Hi, Lo = Int64ShiftLeft(A.Hi, A.Lo, Count)

	return { Hi = Hi, Lo = Lo }
end

-- Arithmetic (sign-filling) shift right, for a signed value.
const function Bits64ShiftRight(A: Bits64, Count: number): Bits64
	const Hi, Lo = Int64ShiftRight(A.Hi, A.Lo, Count)

	return { Hi = Hi, Lo = Lo }
end

-- Logical (zero-filling) shift right, for an unsigned value.
const function Bits64ShiftRightLogical(A: Bits64, Count: number): Bits64
	const Hi, Lo = Int64ShiftRightLogical(A.Hi, A.Lo, Count)

	return { Hi = Hi, Lo = Lo }
end

-- Division truncating toward zero for a signed value; a zero divisor errors.
const function Bits64Div(A: Bits64, B: Bits64, Signed64: boolean): Bits64
	if Signed64 then
		const Hi, Lo = Int64DivRem(A.Hi, A.Lo, B.Hi, B.Lo)

		return { Hi = Hi, Lo = Lo }
	end

	const Hi, Lo = Uint64DivRem(A.Hi, A.Lo, B.Hi, B.Lo)

	return { Hi = Hi, Lo = Lo }
end

const function Bits64Rem(A: Bits64, B: Bits64, Signed64: boolean): Bits64
	if Signed64 then
		const _, _, Hi, Lo = Int64DivRem(A.Hi, A.Lo, B.Hi, B.Lo)

		return { Hi = Hi, Lo = Lo }
	end

	const _, _, Hi, Lo = Uint64DivRem(A.Hi, A.Lo, B.Hi, B.Lo)

	return { Hi = Hi, Lo = Lo }
end

const function Bits64Equal(A: Bits64, B: Bits64): boolean
	return A.Hi == B.Hi and A.Lo == B.Lo
end

const function Bits64NotZero(A: Bits64): boolean
	return A.Hi ~= 0 or A.Lo ~= 0
end

-- -1, 0 or 1.
const function Bits64Compare(A: Bits64, B: Bits64, Signed64: boolean): number
	return if Signed64 then Int64Compare(A.Hi, A.Lo, B.Hi, B.Lo) else Uint64Compare(A.Hi, A.Lo, B.Hi, B.Lo)
end

-- Stable sort (Java Collections.sort, Python sorted, JS sort with a comparator). Less(A, B) is strict.
-- Bottom-up merge sort; runs already in order are copied without comparing every element.
const function StableSort<T>(Array: { T }, Less: (T, T) -> boolean)
	const Count = #Array

	if Count < 2 then
		return
	end

	local Source = Array
	local Target: { T } = table.create(Count)
	local Width = 1

	while Width < Count do
		for Start = 1, Count, Width * 2 do
			const Middle = math.min(Start + Width - 1, Count)
			const Finish = math.min(Start + Width * 2 - 1, Count)

			if Middle == Finish or not Less(Source[Middle + 1], Source[Middle]) then
				table.move(Source, Start, Finish, Start, Target)

				continue
			end

			local Left = Start
			local Right = Middle + 1
			local Index = Start

			while Left <= Middle and Right <= Finish do
				if Less(Source[Right], Source[Left]) then
					Target[Index] = Source[Right]
					Right += 1
				else
					Target[Index] = Source[Left]
					Left += 1
				end

				Index += 1
			end

			if Left <= Middle then
				table.move(Source, Left, Middle, Index, Target)
			else
				table.move(Source, Right, Finish, Index, Target)
			end
		end

		Source, Target = Target, Source
		Width *= 2
	end

	if Source ~= Array then
		table.move(Source, 1, Count, 1, Array)
	end
end

-- Count the set bits in the low 32 bits, using parallel sums of pairs, nibbles and bytes.
const function Popcount(Value: number): number
	Value = bit32.band(Value, 0xFFFFFFFF)
	Value -= bit32.band(bit32.rshift(Value, 1), 0x55555555)
	Value = bit32.band(Value, 0x33333333) + bit32.band(bit32.rshift(Value, 2), 0x33333333)
	Value = bit32.band(Value + bit32.rshift(Value, 4), 0x0F0F0F0F)
	Value += bit32.rshift(Value, 8)
	Value += bit32.rshift(Value, 16)

	return bit32.band(Value, 0x3F)
end

-- Number.isFinite / Number.isNaN do not coerce their argument, unlike the global JS functions.
const function JsIsFinite(Value: unknown): boolean
	return type(Value) == "number" and math.isfinite(Value)
end

const function JsIsNaN(Value: unknown): boolean
	return type(Value) == "number" and Value ~= Value
end

-- ECMAScript's falsy primitive values. The argument is evaluated once, including calls that return NaN.
const function JsTruthy(Value: unknown): boolean
	return Value ~= nil and Value ~= false and Value ~= 0 and Value ~= "" and Value == Value
end

return {
	Signed = Signed,
	JsTruthy = JsTruthy,
	JsIsFinite = JsIsFinite,
	JsIsNaN = JsIsNaN,
	Int32 = Int32,
	Uint32 = Uint32,
	Int16 = Int16,
	Uint16 = Uint16,
	Int8 = Int8,
	Uint8 = Uint8,
	Mul32 = Mul32,
	Trunc = Trunc,
	TruncDiv32 = TruncDiv32,
	TruncInt32 = TruncInt32,
	F32 = F32,
	RoundHalfUp = RoundHalfUp,
	RoundHalfEven = RoundHalfEven,
	Int64FromNumber = Int64FromNumber,
	TruncInt64 = TruncInt64,
	Int64ToNumber = Int64ToNumber,
	Uint64ToNumber = Uint64ToNumber,
	Int64ToF32 = Int64ToF32,
	Uint64ToF32 = Uint64ToF32,
	Int64Add = Int64Add,
	Int64Sub = Int64Sub,
	Int64Negate = Int64Negate,
	Int64Mul = Int64Mul,
	Int64ShiftLeft = Int64ShiftLeft,
	Int64ShiftRight = Int64ShiftRight,
	Int64ShiftRightLogical = Int64ShiftRightLogical,
	Int64And = Int64And,
	Int64Or = Int64Or,
	Int64Xor = Int64Xor,
	Int64Not = Int64Not,
	Int64Compare = Int64Compare,
	Int64DivRem = Int64DivRem,
	Uint64Compare = Uint64Compare,
	Uint64DivRem = Uint64DivRem,
	Bits64FromNumber = Bits64FromNumber,
	Bits64ToNumber = Bits64ToNumber,
	Bits64ToInteger = Bits64ToInteger,
	Bits64ToF32 = Bits64ToF32,
	Bits64Add = Bits64Add,
	Bits64Sub = Bits64Sub,
	Bits64Mul = Bits64Mul,
	Bits64Negate = Bits64Negate,
	Bits64And = Bits64And,
	Bits64Or = Bits64Or,
	Bits64Xor = Bits64Xor,
	Bits64Not = Bits64Not,
	Bits64ShiftLeft = Bits64ShiftLeft,
	Bits64ShiftRight = Bits64ShiftRight,
	Bits64ShiftRightLogical = Bits64ShiftRightLogical,
	Bits64Div = Bits64Div,
	Bits64Rem = Bits64Rem,
	Bits64Equal = Bits64Equal,
	Bits64NotZero = Bits64NotZero,
	Bits64Compare = Bits64Compare,
	StableSort = StableSort,
	Popcount = Popcount,
}
