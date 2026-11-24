--!strict
--!optimize 2

--[[
	The GodotSharp math the modifiers use (reference/engine Vector3.cs, Basis.cs, Transform3D.cs, Mathf.cs), float32 like
	Godot's real_t.

	Representation
		A Vector3 is a Luau vector (float32 lanes). A Basis is { vector } of its three rows (Row0..Row2, as Godot stores
		them). A Transform3D is { Basis, Origin }. Every function answers a new value; no argument is changed.

	Design Notes
		Vector + and - and vector * scalar are lane operations that round to float32 like Godot. Scalar products and sums
		are float32 operations: each one goes through Numbers.F32 separately (a dot product is three products and two
		sums), so the lanes equal the C# float results. Float parameters are float32 values; callers round with Numbers.F32.
]]

const Numbers = require("../Numbers")

export type Basis = { vector }

export type Transform3D = {
	Basis: Basis,
	Origin: vector,
}

-- Mathf.Pi is (real_t)pi, the float32 value.
-- @src engine/Mathf.cs:Pi L24-24
const Pi = Numbers.F32(math.pi)

-- @src engine/Vector3.cs:Up L854-854
const Up = vector.create(0, 1, 0)

-- @src engine/Vector3.cs:Back L883-883
const Back = vector.create(0, 0, 1)

-- Vector3.Dot: X*X' + Y*Y' + Z*Z', each product and each sum rounded to float32.
-- @src engine/Vector3.cs:Dot L332-335
const function Dot(Left: vector, Right: vector): number
	return Numbers.F32(Numbers.F32(Numbers.F32(Left.x * Right.x) + Numbers.F32(Left.y * Right.y)) + Numbers.F32(Left.z * Right.z))
end

-- Vector3.Length is the square root of Dot(v, v): X*X + Y*Y + Z*Z in the same order.
-- @src engine/Vector3.cs:Length L379-386
const function Length(Value: vector): number
	return Numbers.F32(math.sqrt(Dot(Value, Value)))
end

-- @src engine/Vector3.cs:DistanceTo L322-325
const function DistanceTo(From: vector, To: vector): number
	return Length(To - From)
end

-- Diagonal entry of Basis(axis, angle): AxisSquared + Cos * (1 - AxisSquared), each operation rounded to float32.
const function Diagonal(AxisSquared: number, Cosine: number): number
	return Numbers.F32(AxisSquared + Numbers.F32(Cosine * Numbers.F32(1 - AxisSquared)))
end

-- Basis(Vector3 axis, real_t angle): the rotation matrix of Godot's axis-angle constructor.
-- DEVIATION(platform): Godot's float sin and cos are MathF.Sin/MathF.Cos (CRT sinf/cosf), which Luau cannot call. The
-- port rounds the double sine and cosine to float32; the two differ by one float32 ulp for about 0.12% of angles.
-- @src engine/Basis.cs:Basis L889-914
const function NewBasis(Axis: vector, Angle: number): Basis
	const AxisSquared = Axis * Axis
	const Sine = Numbers.F32(math.sin(Angle))
	const Cosine = Numbers.F32(math.cos(Angle))
	const OneMinusCosine = Numbers.F32(1 - Cosine)

	const XyProduct = Numbers.F32(Numbers.F32(Axis.x * Axis.y) * OneMinusCosine)
	const XzProduct = Numbers.F32(Numbers.F32(Axis.x * Axis.z) * OneMinusCosine)
	const YzProduct = Numbers.F32(Numbers.F32(Axis.y * Axis.z) * OneMinusCosine)
	const XSine = Numbers.F32(Axis.x * Sine)
	const YSine = Numbers.F32(Axis.y * Sine)
	const ZSine = Numbers.F32(Axis.z * Sine)

	return {
		vector.create(Diagonal(AxisSquared.x, Cosine), Numbers.F32(XyProduct - ZSine), Numbers.F32(XzProduct + YSine)),
		vector.create(Numbers.F32(XyProduct + ZSine), Diagonal(AxisSquared.y, Cosine), Numbers.F32(YzProduct - XSine)),
		vector.create(Numbers.F32(XzProduct - YSine), Numbers.F32(YzProduct + XSine), Diagonal(AxisSquared.z, Cosine)),
	}
end

-- Basis * Vector3: each row dotted with the vector.
-- @src engine/Basis.cs:operator* (Basis, Vector3) L1044-1052
const function MultiplyBasisVector(Rows: Basis, Value: vector): vector
	return vector.create(Dot(Rows[1], Value), Dot(Rows[2], Value), Dot(Rows[3], Value))
end

-- Basis * Basis: entry (i, j) is the dot product of row i of Left with column j of Right, summed in row order.
-- @src engine/Basis.cs:operator* (Basis, Basis) L1028-1036
const function MultiplyBasis(Left: Basis, Right: Basis): Basis
	const ColumnX = vector.create(Right[1].x, Right[2].x, Right[3].x)
	const ColumnY = vector.create(Right[1].y, Right[2].y, Right[3].y)
	const ColumnZ = vector.create(Right[1].z, Right[2].z, Right[3].z)

	return {
		vector.create(Dot(ColumnX, Left[1]), Dot(ColumnY, Left[1]), Dot(ColumnZ, Left[1])),
		vector.create(Dot(ColumnX, Left[2]), Dot(ColumnY, Left[2]), Dot(ColumnZ, Left[2])),
		vector.create(Dot(ColumnX, Left[3]), Dot(ColumnY, Left[3]), Dot(ColumnZ, Left[3])),
	}
end

-- Transform3D * Transform3D: the origin is Left * Right.Origin (rotated, then Left.Origin added), the basis is Left.Basis * Right.Basis.
-- @src engine/Transform3D.cs:operator* (Transform3D, Transform3D) L409-414
const function MultiplyTransform(Left: Transform3D, Right: Transform3D): Transform3D
	return {
		Basis = MultiplyBasis(Left.Basis, Right.Basis),
		Origin = MultiplyBasisVector(Left.Basis, Right.Origin) + Left.Origin,
	}
end

-- DEVIATION: Godot's DEBUG-only check that the axis is normalized is not run (release builds do not run it).
-- @src engine/Vector3.cs:Rotated L639-648
const function Rotated(Value: vector, Axis: vector, Angle: number): vector
	return MultiplyBasisVector(NewBasis(Axis, Angle), Value)
end

-- @src engine/Transform3D.cs:Identity L314-314
const function IdentityTransform(): Transform3D
	return {
		Basis = {
			vector.create(1, 0, 0),
			vector.create(0, 1, 0),
			vector.create(0, 0, 1),
		},
		Origin = vector.zero,
	}
end

-- Godot's global rotation: new Transform3D(new Basis(axis, angle), Vector3.Zero) * this.
-- @src engine/Transform3D.cs:Rotated L222-225
const function RotatedTransform(Transform: Transform3D, Axis: vector, Angle: number): Transform3D
	return MultiplyTransform({ Basis = NewBasis(Axis, Angle), Origin = vector.zero }, Transform)
end

return {
	Pi = Pi,
	Up = Up,
	Back = Back,
	Rotated = Rotated,
	DistanceTo = DistanceTo,
	NewBasis = NewBasis,
	MultiplyBasis = MultiplyBasis,
	MultiplyBasisVector = MultiplyBasisVector,
	IdentityTransform = IdentityTransform,
	RotatedTransform = RotatedTransform,
}
