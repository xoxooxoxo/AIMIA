--!strict
--!optimize 2

--[[
	Godot's Color struct for logic modules, ported from GodotSharp Core/Color.cs (Godot 4.7.2).

	Design Notes
		Components are float32 values stored in Luau numbers; every float operation rounds through Numbers.F32,
		as the C# float math does. The UI converts with Color3.new(R, G, B) and Transparency = 1 - A.
		C# Color is a struct: functions answer new tables and never change their arguments.
]]

const Numbers = require("../Numbers")

export type Color = {
	R: number,
	G: number,
	B: number,
	A: number,
}

-- @src engine/Color.cs:Color L589-595
const function New(R: number, G: number, B: number, A: number?): Color
	return {
		R = Numbers.F32(R),
		G = Numbers.F32(G),
		B = Numbers.F32(B),
		A = Numbers.F32(A or 1),
	}
end

-- @src engine/Color.cs:Color L619-628
const function FromRgba(Rgba: number): Color
	return {
		R = Numbers.F32(bit32.extract(Rgba, 24, 8) / 255),
		G = Numbers.F32(bit32.extract(Rgba, 16, 8) / 255),
		B = Numbers.F32(bit32.extract(Rgba, 8, 8) / 255),
		A = Numbers.F32(bit32.extract(Rgba, 0, 8) / 255),
	}
end

-- @src engine/Color.cs:Color8 L785-788
const function Color8(R8: number, G8: number, B8: number, A8: number?): Color
	return {
		R = Numbers.F32(R8 / 255),
		G = Numbers.F32(G8 / 255),
		B = Numbers.F32(B8 / 255),
		A = Numbers.F32((A8 or 255) / 255),
	}
end

-- @src engine/Color.cs:ParseCol4 L939-956
const function ParseCol4(Text: string, Index: number): number
	const Character = string.byte(Text, Index + 1)

	if Character >= 48 and Character <= 57 then
		return Character - 48
	elseif Character >= 97 and Character <= 102 then
		return Character - 87
	elseif Character >= 65 and Character <= 70 then
		return Character - 55
	end

	return -1
end

-- @src engine/Color.cs:ParseCol8 L958-961
const function ParseCol8(Text: string, Index: number): number
	return ParseCol4(Text, Index) * 16 + ParseCol4(Text, Index + 1)
end

-- @src engine/Color.cs:FromHtml L688-774
const function FromHtml(Code: string): Color
	if #Code == 0 then
		return New(0, 0, 0, 1)
	end

	local Rgba = Code

	if string.byte(Rgba, 1) == 35 then
		Rgba = string.sub(Rgba, 2)
	end

	const IsShorthand = #Rgba < 5
	local Alpha = false

	if #Rgba == 8 then
		Alpha = true
	elseif #Rgba == 6 then
		Alpha = false
	elseif #Rgba == 4 then
		Alpha = true
	elseif #Rgba == 3 then
		Alpha = false
	else
		error(`Invalid color code. Length is {#Rgba}, but a length of 6 or 8 is expected: {Rgba}`, 0)
	end

	local R: number
	local G: number
	local B: number
	local A = 1

	if IsShorthand then
		R = Numbers.F32(ParseCol4(Rgba, 0) / 15)
		G = Numbers.F32(ParseCol4(Rgba, 1) / 15)
		B = Numbers.F32(ParseCol4(Rgba, 2) / 15)

		if Alpha then
			A = Numbers.F32(ParseCol4(Rgba, 3) / 15)
		end
	else
		R = Numbers.F32(ParseCol8(Rgba, 0) / 255)
		G = Numbers.F32(ParseCol8(Rgba, 2) / 255)
		B = Numbers.F32(ParseCol8(Rgba, 4) / 255)

		if Alpha then
			A = Numbers.F32(ParseCol8(Rgba, 6) / 255)
		end
	end

	if R < 0 then
		error(`Invalid color code. Red part is not valid hexadecimal: {Rgba}`, 0)
	end

	if G < 0 then
		error(`Invalid color code. Green part is not valid hexadecimal: {Rgba}`, 0)
	end

	if B < 0 then
		error(`Invalid color code. Blue part is not valid hexadecimal: {Rgba}`, 0)
	end

	if A < 0 then
		error(`Invalid color code. Alpha part is not valid hexadecimal: {Rgba}`, 0)
	end

	return {
		R = R,
		G = G,
		B = B,
		A = A,
	}
end

-- @src engine/Mathf.cs:Lerp L1098-1101
const function LerpF32(From: number, To: number, Weight: number): number
	return Numbers.F32(From + Numbers.F32(Numbers.F32(To - From) * Weight))
end

-- @src engine/Color.cs:Lerp L401-410
const function Lerp(From: Color, To: Color, Weight: number): Color
	const Weight32 = Numbers.F32(Weight)

	return {
		R = LerpF32(From.R, To.R, Weight32),
		G = LerpF32(From.G, To.G, Weight32),
		B = LerpF32(From.B, To.B, Weight32),
		A = LerpF32(From.A, To.A, Weight32),
	}
end

const function Equals(Left: Color, Right: Color): boolean
	return Left.R == Right.R and Left.G == Right.G and Left.B == Right.B and Left.A == Right.A
end

return {
	New = New,
	FromRgba = FromRgba,
	Color8 = Color8,
	FromHtml = FromHtml,
	Lerp = Lerp,
	Equals = Equals,
}
