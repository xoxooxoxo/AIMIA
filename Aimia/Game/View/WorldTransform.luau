--!strict
--!optimize 2

--[[
	Places Godot transforms in the game's Workspace: a Godot unit is STUDS_PER_UNIT studs, the world sits at ORIGIN (far from
	the host place, client-only), and Godot's axes are Roblox's (-Z forward, +Y up, right-handed), so a basis's columns are
	the Roblox right, up and back vectors. The camera's Euler rotation, a quad's rotation about Z and a basis are the three
	cases.

	Representation
		A basis is a Godot Basis: { vector } of three rows (Godot/Math). A Euler rotation is Godot's YXZ order in radians.
		A CFrame is built from its twelve components (CFrame.new takes numbers), and a Part's Size takes a Vector3 made from a
		vector, so no table is made per placement.

	Design Notes
		EulerRows is Spaces/Shaders/WavesPass's EulerBasis (ymat * xmat * zmat) written with vector values; Dot and MultiplyRows
		are Godot/Math's Dot and MultiplyBasis for the same reason.
		DEVIATION(platform): Godot's sinf and cosf are the double sine and cosine rounded to float32 (vector.create), as in
		Godot/Math.luau.
		A quad is a Part one QuadThickness thick; its image is an ImageLabel in a SurfaceGui on the face toward the camera.
]]

const Math = require("../../Godot/Math")
const Numbers = require("../../Numbers")

-- One Godot unit is one stud: the grid, the cursor and the notes keep their upstream sizes relative to the camera.
const StudsPerUnit = 1

-- The world's origin: the client-only folder is built far above the host place.
const Origin = vector.create(0, 10000, 0)

-- The thickness of a quad's Part, in Godot units (Roblox Parts are at least 0.05 studs thick).
const QuadThickness = 0.05

-- The face of a quad's Part that the camera sees: the +Z face of the Part, which holds the SurfaceGui.
const QuadFace = Enum.NormalId.Back

-- Mathf.DegToRad's factor (float32), as Game/Camera/CameraSpin.luau; a rotation in degrees is stored as radians in float32.
const RadiansPerDegree = Numbers.F32(0.0174532925199432957692369077)

-- Vector3.Dot: each product and each sum rounded to float32.
-- @src engine/Vector3.cs:Dot L332-335
const function Dot(Left: vector, Right: vector): number
	return Numbers.F32(Numbers.F32(Numbers.F32(Left.x * Right.x) + Numbers.F32(Left.y * Right.y)) + Numbers.F32(Left.z * Right.z))
end

-- Rows of Left * Right as Math.MultiplyBasis: entry (i, j) is Dot(column j of Right, row i of Left).
-- @src engine/Basis.cs:operator* (Basis, Basis) L1028-1036
const function MultiplyRows(
	Left0: vector,
	Left1: vector,
	Left2: vector,
	Right0: vector,
	Right1: vector,
	Right2: vector
): (vector, vector, vector)
	const Column0 = vector.create(Right0.x, Right1.x, Right2.x)
	const Column1 = vector.create(Right0.y, Right1.y, Right2.y)
	const Column2 = vector.create(Right0.z, Right1.z, Right2.z)

	const Row0 = vector.create(Dot(Column0, Left0), Dot(Column1, Left0), Dot(Column2, Left0))
	const Row1 = vector.create(Dot(Column0, Left1), Dot(Column1, Left1), Dot(Column2, Left1))
	const Row2 = vector.create(Dot(Column0, Left2), Dot(Column1, Left2), Dot(Column2, Left2))

	return Row0, Row1, Row2
end

-- The rows of Godot's Basis.FromEuler in YXZ order: ymat * xmat * zmat, the rows of WavesPass's EulerBasis.
-- @src engine/Basis.cs:FromEuler L959-1002
const function EulerRows(Euler: vector): (vector, vector, vector)
	const SinX = math.sin(Euler.x)
	const CosX = math.cos(Euler.x)
	const SinY = math.sin(Euler.y)
	const CosY = math.cos(Euler.y)
	const SinZ = math.sin(Euler.z)
	const CosZ = math.cos(Euler.z)

	const XRow0 = vector.create(1, 0, 0)
	const XRow1 = vector.create(0, CosX, -SinX)
	const XRow2 = vector.create(0, SinX, CosX)
	const YRow0 = vector.create(CosY, 0, SinY)
	const YRow1 = vector.create(0, 1, 0)
	const YRow2 = vector.create(-SinY, 0, CosY)
	const ZRow0 = vector.create(CosZ, -SinZ, 0)
	const ZRow1 = vector.create(SinZ, CosZ, 0)
	const ZRow2 = vector.create(0, 0, 1)

	const YXRow0, YXRow1, YXRow2 = MultiplyRows(YRow0, YRow1, YRow2, XRow0, XRow1, XRow2)

	return MultiplyRows(YXRow0, YXRow1, YXRow2, ZRow0, ZRow1, ZRow2)
end

-- Godot's Node3D rotation set in degrees (RotationDegrees): the radians it stores.
const function DegreesToRadians(Degrees: number): number
	return Numbers.F32(Degrees * RadiansPerDegree)
end

-- The Roblox Vector3 of a vector, for the Part properties that take one (Size).
const function ToVector3(Value: vector): Vector3
	return Vector3.xAxis * Value.x + Vector3.yAxis * Value.y + Vector3.zAxis * Value.z
end

-- A vector normalized, a zero vector staying zero.
const function Unit(Value: vector): vector
	const Length = vector.magnitude(Value)

	if Length == 0 then
		return Value
	end

	return Value / Length
end

-- A Godot point in the Workspace.
const function Point(Value: vector): vector
	return Value * StudsPerUnit + Origin
end

-- The CFrame at a Godot position whose rotation has the basis columns X, Y and Z. CFrame components are row-major, so row
-- i is (X[i], Y[i], Z[i]).
const function CFrameOf(Position: vector, X: vector, Y: vector, Z: vector): CFrame
	const Where = Point(Position)

	return CFrame.new(Where.x, Where.y, Where.z, X.x, Y.x, Z.x, X.y, Y.y, Z.y, X.z, Y.z, Z.z)
end

-- The Godot camera's CFrame: its position and the basis of its Euler rotation (the scene's Camera3D, as Node3D.Basis).
const function CameraCFrame(Position: vector, Rotation: vector): CFrame
	const Row0, Row1, Row2 = EulerRows(Rotation)

	return CFrameOf(Position, vector.create(Row0.x, Row1.x, Row2.x), vector.create(Row0.y, Row1.y, Row2.y), vector.create(Row0.z, Row1.z, Row2.z))
end

-- Places a Part at a transform: its CFrame is the position and the basis's unit columns, its size the extents (in Godot units)
-- scaled by the basis's column lengths.
const function Place(Part: BasePart, Rows: Math.Basis, Position: vector, Extents: vector)
	const Column0 = vector.create(Rows[1].x, Rows[2].x, Rows[3].x)
	const Column1 = vector.create(Rows[1].y, Rows[2].y, Rows[3].y)
	const Column2 = vector.create(Rows[1].z, Rows[2].z, Rows[3].z)

	Part.CFrame = CFrameOf(Position, Unit(Column0), Unit(Column1), Unit(Column2))
	Part.Size = ToVector3(
		vector.create(
			Extents.x * vector.magnitude(Column0) * StudsPerUnit,
			Extents.y * vector.magnitude(Column1) * StudsPerUnit,
			Extents.z * vector.magnitude(Column2) * StudsPerUnit
		)
	)
end

-- Places a flat quad of Width by Height at a transform: its face is the basis's unit columns X and Y, its thickness is
-- QuadThickness whatever the basis scale (a scaled quad is wider, not thicker).
const function PlaceFlat(Part: BasePart, Rows: Math.Basis, Position: vector, Width: number, Height: number)
	const Column0 = vector.create(Rows[1].x, Rows[2].x, Rows[3].x)
	const Column1 = vector.create(Rows[1].y, Rows[2].y, Rows[3].y)
	const Column2 = vector.create(Rows[1].z, Rows[2].z, Rows[3].z)

	Part.CFrame = CFrameOf(Position, Unit(Column0), Unit(Column1), Unit(Column2))
	Part.Size = ToVector3(
		vector.create(
			Width * vector.magnitude(Column0) * StudsPerUnit,
			Height * vector.magnitude(Column1) * StudsPerUnit,
			QuadThickness * StudsPerUnit
		)
	)
end

-- Places a square quad turned by Angle about Z (a cursor, a trail sample): no table is made.
const function PlaceQuad(Part: BasePart, Angle: number, Position: vector, Size: number)
	const Sine = Numbers.F32(math.sin(Angle))
	const Cosine = Numbers.F32(math.cos(Angle))

	Part.CFrame = CFrameOf(Position, vector.create(Cosine, Sine, 0), vector.create(-Sine, Cosine, 0), vector.create(0, 0, 1))
	Part.Size = ToVector3(vector.create(Size * StudsPerUnit, Size * StudsPerUnit, QuadThickness * StudsPerUnit))
end

return {
	StudsPerUnit = StudsPerUnit,
	QuadThickness = QuadThickness,
	QuadFace = QuadFace,
	Origin = Origin,
	CameraCFrame = CameraCFrame,
	DegreesToRadians = DegreesToRadians,
	Place = Place,
	PlaceFlat = PlaceFlat,
	PlaceQuad = PlaceQuad,
}
