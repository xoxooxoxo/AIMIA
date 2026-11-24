--!strict
--!native
--!optimize 2

--[[
	sky_noise_waves.gdshader in plain double math: the simplex noise (Snoise), the noise value of an EYEDIR at a TIME
	(Noise) and the sky's COLOR (Color) for that value, with the contour bands anti-aliased.

	Representation
		Scalars are Luau numbers (doubles) and a color is a vector (linear RGB). Snoise takes its coordinates as
		numbers, so the hot path builds no tables and no closures.

	Design Notes
		DEVIATION(render): the contour bands are anti-aliased. Godot tests floor(noise * 96) and floor(noise * 384) for
		multiples of 20 (a sharp band of width 1 in those units). Color takes the noise change over one pixel (Change, in
		noise units) and ramps each band over that width, so a band thinner than a pixel stays visible as a faint line;
		a Change of 0 gives the sharp bands. The renderer passes the change between neighbouring pixels.
		DEVIATION(render): the image blend (images a and b, the sine color swap, opacity, background color) is not in
		the shader: the map cover is not drawn yet, and the empty texture is transparent black. Coverage is not here: the
		view fades the frame in (ImageLabel transparency), and the sky is drawn at full coverage.
		DEVIATION(render): the gradient lattice is exact in integers, and the seven cells whose gradient height is exactly
		zero take the sign the shader's float32 lattice gives them (TieShiftCells), so the noise matches the shader's
		gradients at every cell; the arithmetic on the noise itself is double (within 3e-5 of float32 at the oracle's rows).
]]

-- The shader's literal constants as doubles (C = vec2(1/6, 1/3), taylorInvSqrt, 0.6, 42).
const SkewFactor = 1 / 3
const UnskewFactor = 1 / 6
const TaylorOffset = 1.79284291400159
const TaylorScale = 0.85373472095314
const KernelRadius = 0.6
const NoiseScale = 42
const PermuteModulus = 289
const GradientCells = 49
const GradientRow = 7

-- The gradient lattice: cell coordinates k in 0..6 give x = (4k - 13) / 14 (the shader's 2k/7 - 13/14), exact in
-- integers in units of 1/14. A cell's gradient height is h = 1 - |x| - |y|, an integer multiple of 1/14: exactly 0 for
-- seven cells, where the shader's float32 lattice decides the sign of h by rounding (the cells below are the ones it
-- rounds negative: they shift). Other cells are decided by the sign of h.
const LatticeUnits = 14
const LatticeOffset = 4
const LatticeBias = 13
const TieShiftCells = { [34] = true, [40] = true, [46] = true }

-- The contour bands: primary every 96 noise units with a band of 1 in 20, secondary every 384 at 0.2.
const PrimaryScale = 96
const SecondaryScale = 384
const BandPeriod = 20
const SecondaryWeight = 0.2
const DriftDivisor = 70

-- @src scripts/shaders/sky_noise_waves.gdshader:permute L16-18
-- One lane of permute(vec4 x) = mod(((x * 34.0) + 1.0) * x, 289.0), exact for the integer lattice coordinates.
const function Permute(Value: number): number
	return ((Value * 34 + 1) * Value) % PermuteModulus
end

-- One corner of the simplex: the gradient of permuted index Permuted (p mod 49 selects one of 49 gradients on an
-- octahedron, shifted toward the corner), normalized, dotted with the corner offset (X, Y, Z), times the kernel.
-- @src scripts/shaders/sky_noise_waves.gdshader:snoise L24-88
const function Corner(Permuted: number, X: number, Y: number, Z: number): number
	const Radius = KernelRadius - (X * X + Y * Y + Z * Z)

	if Radius <= 0 then
		return 0
	end

	const Cell = Permuted % GradientCells
	const CellX = Cell // GradientRow
	const CellY = Cell - CellX * GradientRow
	const UnitsX = LatticeOffset * CellX - LatticeBias
	const UnitsY = LatticeOffset * CellY - LatticeBias
	const HeightUnits = LatticeUnits - math.abs(UnitsX) - math.abs(UnitsY)
	const Shift = if HeightUnits < 0 or (HeightUnits == 0 and TieShiftCells[Cell] == true) then -1 else 0
	const BaseX = UnitsX / LatticeUnits
	const BaseY = UnitsY / LatticeUnits
	const Height = HeightUnits / LatticeUnits
	const GradientX = BaseX + ((BaseX // 1) * 2 + 1) * Shift
	const GradientY = BaseY + ((BaseY // 1) * 2 + 1) * Shift
	const Norm = TaylorOffset - TaylorScale * (GradientX * GradientX + GradientY * GradientY + Height * Height)
	const Kernel = Radius * Radius

	return Kernel * Kernel * (GradientX * X + GradientY * Y + Height * Z) * Norm
end

-- @src scripts/shaders/sky_noise_waves.gdshader:snoise L24-88
-- 3D simplex noise (Ian McEwan, Stefan Gustavson): the shader's snoise, in double math.
const function Snoise(X: number, Y: number, Z: number): number
	const Skew = (X + Y + Z) * SkewFactor
	const CellX = (X + Skew) // 1
	const CellY = (Y + Skew) // 1
	const CellZ = (Z + Skew) // 1
	const Unskew = (CellX + CellY + CellZ) * UnskewFactor
	const X0 = X - CellX + Unskew
	const Y0 = Y - CellY + Unskew
	const Z0 = Z - CellZ + Unskew

	const GreaterX = if X0 >= Y0 then 1 else 0
	const GreaterY = if Y0 >= Z0 then 1 else 0
	const GreaterZ = if Z0 >= X0 then 1 else 0
	const OrderX = 1 - GreaterZ
	const OrderY = 1 - GreaterX
	const OrderZ = 1 - GreaterY

	const LowX = GreaterX * OrderX
	const LowY = GreaterY * OrderY
	const LowZ = GreaterZ * OrderZ
	const HighX = GreaterX + OrderX - LowX
	const HighY = GreaterY + OrderY - LowY
	const HighZ = GreaterZ + OrderZ - LowZ

	const X1 = X0 - LowX + UnskewFactor
	const Y1 = Y0 - LowY + UnskewFactor
	const Z1 = Z0 - LowZ + UnskewFactor
	const X2 = X0 - HighX + 2 * UnskewFactor
	const Y2 = Y0 - HighY + 2 * UnskewFactor
	const Z2 = Z0 - HighZ + 2 * UnskewFactor
	const X3 = X0 - 0.5
	const Y3 = Y0 - 0.5
	const Z3 = Z0 - 0.5

	const ModX = CellX % PermuteModulus
	const ModY = CellY % PermuteModulus
	const ModZ = CellZ % PermuteModulus
	const Permuted0 = Permute(Permute(Permute(ModZ) + ModY) + ModX)
	const Permuted1 = Permute(Permute(Permute(ModZ + LowZ) + ModY + LowY) + ModX + LowX)
	const Permuted2 = Permute(Permute(Permute(ModZ + HighZ) + ModY + HighY) + ModX + HighX)
	const Permuted3 = Permute(Permute(Permute(ModZ + 1) + ModY + 1) + ModX + 1)

	const Sum = Corner(Permuted0, X0, Y0, Z0) + Corner(Permuted1, X1, Y1, Z1)
	const Total = Sum + Corner(Permuted2, X2, Y2, Z2) + Corner(Permuted3, X3, Y3, Z3)

	return NoiseScale * Total
end

-- The noise value in [0, 1] of EYEDIR at TIME: the sky's pos = (x, |y| + TIME / 70, z).
-- @src scripts/shaders/sky_noise_waves.gdshader:sky L90-116
const function Noise(EyeX: number, EyeY: number, EyeZ: number, Time: number): number
	const Value = (Snoise(EyeX, math.abs(EyeY) + Time / DriftDivisor, EyeZ) + 1) / 2

	return math.clamp(Value, 0, 1)
end

-- Coverage of the band [0, 1) of Q mod BandPeriod, under a pixel footprint of Footprint in Q units. Footprint 0 is the
-- sharp band.
const function Band(Q: number, Footprint: number): number
	if Footprint <= 0 then
		return if Q % BandPeriod < 1 then 1 else 0
	end

	local Distance = math.abs(Q % BandPeriod - 0.5)

	if Distance > BandPeriod / 2 then
		Distance = BandPeriod - Distance
	end

	return math.clamp((0.5 + Footprint / 2 - Distance) / Footprint, 0, 1)
end

-- The sky's COLOR (linear RGB) for a noise value; Change is the noise change over one pixel (0 for sharp bands).
-- @src scripts/shaders/sky_noise_waves.gdshader:sky L90-116
const function Color(NoiseValue: number, Change: number): vector
	const Primary = Band(NoiseValue * PrimaryScale, PrimaryScale * Change)
	const Secondary = Band(NoiseValue * SecondaryScale, SecondaryScale * Change)
	const Ring = math.max(Primary, SecondaryWeight * Secondary)

	const Squared = NoiseValue * NoiseValue
	const Fourth = Squared * Squared
	const Eighth = Fourth * Fourth
	const Sixteenth = Eighth * Eighth
	const ThirtySecond = Sixteenth * Sixteenth
	const SixtyFourth = ThirtySecond * ThirtySecond
	const Pressure = (1 - SixtyFourth * ThirtySecond * Fourth) / 50
	const Weight = Ring + Pressure

	return vector.create(Weight, 0.1 * Weight, NoiseValue / 4 * Weight)
end

return {
	Snoise = Snoise,
	Noise = Noise,
	Color = Color,
}
