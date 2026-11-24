--!strict
--!optimize 2

--[[
	CameraSpin.cs: the Spin camera mode, chosen by a "Spin" entry in a replay's modifiers (stored as "Spin"). The mouse turns the
	camera around the cursor's orbit; the cursor is where the camera's view ray meets the play plane.

	Design Notes
		Godot's camera basis is not stored: LookVector derives its third column (Basis.Z) from Rotation. Godot sets a rotation as
		Ry * Rx * Rz (YXZ Euler), and that product's third column is (sin y cos x, -sin x, cos y cos x): Rz does not reach it.
		Each cosine and sine is float32; the products of two float32 values are exact in double, so one rounding gives the
		float32 product that Godot computes.
		DEVIATION(platform): Godot's cosf and sinf are approximated by the double cosine and sine rounded to float32 (as in
		Godot/Math.luau), which differ by one float32 ulp for some angles. Node3D is not in reference/engine, so the Euler order
		above is Godot's Basis.SetEulerYxz as recalled, not read from the source.
]]

const Constants = require("../../Constants")
const CameraMode = require("./CameraMode")
const Math = require("../../Godot/Math")
const Numbers = require("../../Numbers")

const Bounds = Constants.Bounds
const MinBounds = -Bounds

-- The camera's rest position: the orbit adds the cursor's parallax and the pivot to it (new Vector3(0, 0, 3.5f)).
const Origin = vector.create(0, 0, 3.5)

-- Mathf.DegToRad's factor, (float)0.0174532925199432957692369077M; DegToRad(90f) is the float32 product with it.
const RadiansPerDegree = Numbers.F32(0.0174532925199432957692369077)
const PitchLimit = Numbers.F32(90 * RadiansPerDegree)

-- The most parallax fed back into the aim in live play. Each event adds the old cursor back through it: at 1 the cursor keeps
-- running for as long as the camera is turned, and ends up in a corner. Below 1 a turn settles on one spot.
const MaxFeedback = 0.75

-- Basis.Z of the camera's basis for an YXZ Euler rotation (see the header). Rotation.z is not read.
-- DEVIATION(platform): the sine and cosine are the double ones rounded to float32 (see the header).
const function LookVector(Rotation: vector): vector
	const CosX = Numbers.F32(math.cos(Rotation.x))
	const SinX = Numbers.F32(math.sin(Rotation.x))
	const CosY = Numbers.F32(math.cos(Rotation.y))
	const SinY = Numbers.F32(math.sin(Rotation.y))

	return vector.create(SinY * CosX, -SinX, CosY * CosX)
end

-- @src scripts/game/camera/CameraSpin.cs:Process L10-59
const function Process(
	Attempt: CameraMode.Attempt,
	ReplayManager: CameraMode.ReplayManager,
	Camera: CameraMode.Camera,
	Cursor: CameraMode.Cursor,
	MouseDelta: vector,
	Sensitivity: number,
	Autoplay: boolean?
)
	const Settings = Attempt.Settings

	if not Attempt.IsReplay then
		const Turn = vector.create(-MouseDelta.y, -MouseDelta.x, 0) / 120 * Sensitivity / Math.Pi

		if not (math.isfinite(Turn.x) and math.isfinite(Turn.y)) then
			return
		end

		Camera.Rotation += Turn
	else
		Camera.Rotation += vector.create(MouseDelta.y, -MouseDelta.x, 0) / Math.Pi
	end

	local Parallax = Numbers.F32(Settings.CameraParallax.Value)

	if Attempt.IsReplay or Autoplay then
		Camera.Rotation = vector.create(math.clamp(Camera.Rotation.x, -PitchLimit, PitchLimit), Camera.Rotation.y, Camera.Rotation.z)
	else
		Parallax = math.min(Parallax, MaxFeedback)

		-- The hand can't turn the camera further than the edge plus the overshoot, so there is nothing to undo in a corner.
		-- (Absolute input zeroes the cursor on every event, so nothing feeds back there.)
		const Share = if Settings.AbsoluteInput.Value then 1 else 1 - Parallax
		const Limit = math.atan((Bounds.x + CameraMode.OvershootOf(Settings)) * Share / Origin.z)

		Camera.Rotation = vector.create(math.clamp(Camera.Rotation.x, -Limit, Limit), math.clamp(Camera.Rotation.y, -Limit, Limit), Camera.Rotation.z)
	end

	const CursorLock = vector.create(Attempt.CursorPosition.x, Attempt.CursorPosition.y, 0)
	const Look = LookVector(Camera.Rotation)

	-- The pivot mimics ROBLOX's orbital camera.
	const Pivot = Look / 4

	Camera.Position = Origin + CursorLock * Parallax + Pivot

	-- The cursor is the camera's ray, projected onto the play plane.
	const CameraXY = vector.create(Camera.Position.x, Camera.Position.y, 0)
	const LookXY = vector.create(Look.x, Look.y, 0)
	const Depth = math.abs(Numbers.F32(Camera.Position.z / Look.z))

	Attempt.RawCursorPosition = CameraXY - LookXY * Depth
	Attempt.CursorPosition = vector.clamp(Attempt.RawCursorPosition, MinBounds, Bounds)

	const CursorPoint = vector.create(Attempt.CursorPosition.x, Attempt.CursorPosition.y, 0)

	if math.isfinite(CursorPoint.x) and math.isfinite(CursorPoint.y) and math.isfinite(CursorPoint.z) then
		Cursor.Position = CursorPoint
	end
end

-- @src scripts/game/camera/CameraSpin.cs:CameraSpin L3-8
const function New(): CameraMode.CameraMode
	return {
		Name = "Spin",
		Rankable = true,
		Process = Process,
	}
end

return New
