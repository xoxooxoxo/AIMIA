--!strict
--!native
--!optimize 2

--[[
	One frame of the Waves menu space: every pixel of the image is shaded as sky_noise_waves.gdshader (the sky) or
	water_ripple.gdshader (the water plane below the horizon), from a snapshot of a Waves space at its rest pose.

	Representation
		A Pass is the snapshot a frame is drawn from: the camera and sky bases (view to world, view to sky), the water
		plane, TIME, the water uniforms, and two rows of shown noise values (Shown: the row being drawn, Above: the row
		before it). Rows are drawn top to bottom: DrawSpan draws pixels of one row under a deadline, EndRow moves to the
		next row. A pixel's sky band footprint is the noise change to its left and upper neighbours.

	Design Notes
		DEVIATION(render): the frame is drawn at the rest pose (the camera pose the intro settles on). The intro's pitch
		and field of view and the sky's yaw are applied to the shown image by SpaceView, so a pass is not redrawn for them.
		The water normal is the world up: its view-space cosine with the view direction is -WorldY (WaterRipple.Fresnel).
		Colors are sRGB-encoded through a 16384-entry table and written as RGBA8, one 32-bit write per pixel.
		The ray through pixel (u, v) in view space is (2u - 1) * tan(fov / 2) * aspect, (1 - 2v) * tan(fov / 2), -1: the
		image's top row is v = 0 and the camera looks down -Z. EYEDIR is the sky basis times the camera basis times the ray.
]]

const Math = require("../../Godot/Math")
const SkyNoiseWaves = require("./SkyNoiseWaves")
const WaterRipple = require("./WaterRipple")
const Waves = require("../Waves")

export type Pass = {
	Width: number,
	Height: number,
	TanHalfFov: number,
	Aspect: number,
	Time: number,
	Camera: Math.Basis,
	Sky: Math.Basis,
	Origin: vector,
	WaterHeight: number,
	WaterSize: number,
	Water: WaterRipple.WaterUniforms,
	Shown: { number },
	Above: { number },
}

const LutSize = 16384
const SrgbThreshold = 0.0031308
const OpaqueAlpha = 4278190080
const ByteScale = 255

-- Linear to sRGB bytes at LutSize + 1 evenly spaced inputs in [0, 1] (index = Linear * LutSize + 1, 1-based).
const SrgbBytes: { number } = table.create(LutSize + 1, 0)

for Index = 0, LutSize do
	const Linear = Index / LutSize
	const Encoded = if Linear < SrgbThreshold then 12.92 * Linear else 1.055 * Linear ^ (1 / 2.4) - 0.055

	SrgbBytes[Index + 1] = math.round(Encoded * ByteScale)
end

-- @src engine/Color.cs:LinearToSrgb L418-424
-- One channel: clamped to [0, 1], encoded, rounded to a byte.
const function ToByte(Linear: number): number
	if Linear <= 0 then
		return 0
	end

	if Linear >= 1 then
		return ByteScale
	end

	return SrgbBytes[(Linear * LutSize + 0.5) // 1 + 1]
end

-- @src engine/Basis.cs:FromEuler L959-1002
-- Godot's Basis.FromEuler in YXZ order: ymat * xmat * zmat. Basis.cs builds each matrix from its three column vectors
-- (new Basis(Vector3, Vector3, Vector3) takes the X, Y and Z axes), so the rows here are their transposes: a positive X
-- turns the camera up, as waves.tscn's 15-degree camera does.
const function EulerBasis(Euler: vector): Math.Basis
	const SinX = math.sin(Euler.x)
	const CosX = math.cos(Euler.x)
	const SinY = math.sin(Euler.y)
	const CosY = math.cos(Euler.y)
	const SinZ = math.sin(Euler.z)
	const CosZ = math.cos(Euler.z)

	const XMatrix = {
		vector.create(1, 0, 0),
		vector.create(0, CosX, -SinX),
		vector.create(0, SinX, CosX),
	}
	const YMatrix = {
		vector.create(CosY, 0, SinY),
		vector.create(0, 1, 0),
		vector.create(-SinY, 0, CosY),
	}
	const ZMatrix = {
		vector.create(CosZ, -SinZ, 0),
		vector.create(SinZ, CosZ, 0),
		vector.create(0, 0, 1),
	}

	return Math.MultiplyBasis(Math.MultiplyBasis(YMatrix, XMatrix), ZMatrix)
end

-- The snapshot a frame is drawn from: the space at its rest pose (Waves.RestCamera) and the given row arrays.
-- @src scripts/spaces/Waves.cs:_Process L59-70
const function Begin(Space: Waves.Waves, Width: number, Height: number, Shown: { number }, Above: { number }): Pass
	const Rotation, Fov = Waves.RestCamera(Space)
	const Camera = EulerBasis(Rotation)
	const Sky = Math.MultiplyBasis(EulerBasis(Space.SkyRotation), Camera)

	return {
		Width = Width,
		Height = Height,
		TanHalfFov = math.tan(math.rad(Fov) / 2),
		Aspect = Width / Height,
		Time = Space.Elapsed,
		Camera = Camera,
		Sky = Sky,
		Origin = Space.Camera.Origin,
		WaterHeight = Space.WaterHeight,
		WaterSize = Space.WaterSize,
		Water = Space.WaterMaterial,
		Shown = Shown,
		Above = Above,
	}
end

-- Moves to the next row: the row just drawn becomes the row above.
const function EndRow(Pass: Pass)
	const Previous = Pass.Above

	Pass.Above = Pass.Shown
	Pass.Shown = Previous
end

-- The noise change to the pixel's left and upper neighbours, the footprint of the sky bands at this pixel.
const function SampleChange(Pass: Pass, Column: number, Noise: number, HasAbove: boolean): number
	local Change = 0

	if Column > 0 then
		Change = math.abs(Noise - Pass.Shown[Column])
	end

	if HasAbove then
		Change = math.max(Change, math.abs(Noise - Pass.Above[Column + 1]))
	end

	return Change
end

-- The sky color of the pixel with EYEDIR (EyeX, EyeY, EyeZ) for a sky noise value, and the noise it shows.
-- @src scripts/shaders/sky_noise_waves.gdshader:sky L90-116
const function SkyPixel(Pass: Pass, Column: number, Eye: vector, HasAbove: boolean): (number, vector)
	const Noise = SkyNoiseWaves.Noise(Eye.x, Eye.y, Eye.z, Pass.Time)

	return Noise, SkyNoiseWaves.Color(Noise, SampleChange(Pass, Column, Noise, HasAbove))
end

-- Draws the pixels of Row from FromColumn into Pixels (RGBA8, Width pixels), stopping at Deadline (checked every 8
-- pixels). Returns the column to continue from; Width when the row is complete.
-- @src scripts/shaders/sky_noise_waves.gdshader:sky L90-116
-- @src scripts/shaders/water_ripple.gdshader:fragment L89-108
const function DrawSpan(Pass: Pass, Pixels: buffer, Row: number, FromColumn: number, Deadline: number): number
	const Width = Pass.Width
	const Height = Pass.Height
	const TanHalfFov = Pass.TanHalfFov
	const TanWide = TanHalfFov * Pass.Aspect
	const Time = Pass.Time
	const Shown = Pass.Shown
	const Water = Pass.Water
	const Origin = Pass.Origin
	const WaterHeight = Pass.WaterHeight
	const WaterSize = Pass.WaterSize
	const HalfWater = WaterSize / 2
	const CameraRow1 = Pass.Camera[1]
	const CameraRow2 = Pass.Camera[2]
	const CameraRow3 = Pass.Camera[3]
	const SkyRow1 = Pass.Sky[1]
	const SkyRow2 = Pass.Sky[2]
	const SkyRow3 = Pass.Sky[3]
	const ScreenV = (Row + 0.5) / Height
	const ViewY = (1 - 2 * ScreenV) * TanHalfFov
	const ViewDepth = ViewY * ViewY + 1
	const HasAbove = Row > 0
	local Column = FromColumn

	while Column < Width do
		if Column % 8 == 0 and os.clock() >= Deadline then
			return Column
		end

		const ScreenU = (Column + 0.5) / Width
		const ViewX = (2 * ScreenU - 1) * TanWide
		const Inverse = 1 / math.sqrt(ViewX * ViewX + ViewDepth)
		const WorldY = (CameraRow2.x * ViewX + CameraRow2.y * ViewY - CameraRow2.z) * Inverse

		local Noise = 0
		local Color = vector.zero
		local Underwater = false

		if WorldY < 0 then
			const WorldX = (CameraRow1.x * ViewX + CameraRow1.y * ViewY - CameraRow1.z) * Inverse
			const WorldZ = (CameraRow3.x * ViewX + CameraRow3.y * ViewY - CameraRow3.z) * Inverse
			const Distance = (WaterHeight - Origin.y) / WorldY
			const HitX = Origin.x + Distance * WorldX
			const HitZ = Origin.z + Distance * WorldZ

			if math.abs(HitX) <= HalfWater and math.abs(HitZ) <= HalfWater then
				Underwater = true

				const Fresnel = WaterRipple.Fresnel(-WorldY)
				const Ripple = WaterRipple.Ripple(Fresnel, ScreenU, ScreenV, Time)
				const RippledU = math.clamp(ScreenU + Ripple, 0, 1)
				const RippledV = math.clamp(ScreenV + 2 * Ripple, 0, 1)
				const ReflectX = (2 * RippledU - 1) * TanWide
				const ReflectY = (1 - 2 * RippledV) * TanHalfFov
				const ReflectInverse = 1 / math.sqrt(ReflectX * ReflectX + ReflectY * ReflectY + 1)
				const ReflectEye = vector.create(
					(SkyRow1.x * ReflectX + SkyRow1.y * ReflectY - SkyRow1.z) * ReflectInverse,
					(SkyRow2.x * ReflectX + SkyRow2.y * ReflectY - SkyRow2.z) * ReflectInverse,
					(SkyRow3.x * ReflectX + SkyRow3.y * ReflectY - SkyRow3.z) * ReflectInverse
				)
				const ReflectNoise, ReflectColor = SkyPixel(Pass, Column, ReflectEye, HasAbove)
				const EchoDistance = math.sqrt(HitX * HitX + HitZ * HitZ) / WaterSize

				Noise = ReflectNoise
				Color = WaterRipple.Shade(Fresnel, ReflectColor * 0.5, EchoDistance, Water)
			end
		end

		if not Underwater then
			const SkyEye = vector.create(
				(SkyRow1.x * ViewX + SkyRow1.y * ViewY - SkyRow1.z) * Inverse,
				(SkyRow2.x * ViewX + SkyRow2.y * ViewY - SkyRow2.z) * Inverse,
				(SkyRow3.x * ViewX + SkyRow3.y * ViewY - SkyRow3.z) * Inverse
			)

			Noise, Color = SkyPixel(Pass, Column, SkyEye, HasAbove)
		end

		Shown[Column + 1] = Noise

		buffer.writeu32(
			Pixels,
			Column * 4,
			ToByte(Color.x) + ToByte(Color.y) * 256 + ToByte(Color.z) * 65536 + OpaqueAlpha
		)

		Column += 1
	end

	return Width
end

return {
	Begin = Begin,
	DrawSpan = DrawSpan,
	EndRow = EndRow,
}
