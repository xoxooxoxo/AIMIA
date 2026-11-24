--!strict
--!optimize 2

--[[
	CameraLock.cs: the camera modes that never turn. The cursor follows the mouse, or the replay's cursor.
	CameraLock() is the source's Lock, named "Normal" here: the default of Lobby and of replays, the camera with no button lit.
	Its camera moves with the cursor by the parallax.
	CameraLock(true) is the Lock button's mode (named "Lock", and stored as a "Lock" entry in a replay's modifiers, as Spin is):
	the camera stays where it is and only the cursor moves (Rhythia's Lock at a camera parallax of 0).

	Design Notes
		The default only changed its name when the Lock button came in (2026-11-08): no replay stores it (a replay without Spin
		or Lock is the default), and nothing read the name.
		Vector2 arithmetic is vector arithmetic: the VM rounds each lane to float32, as Godot's float operations do.
		Clamp is vector.clamp to Constants.Bounds, which is Godot's per-lane Vector2.Clamp (Mathf.Clamp on each lane).
]]

const Constants = require("../../Constants")
const CameraMode = require("./CameraMode")
const Numbers = require("../../Numbers")

const Bounds = Constants.Bounds
const MinBounds = -Bounds

-- Each frame the mouse delta is flipped on Y (Vector2(1, -1)) and divided by 120.
const FlipY = vector.create(1, -1, 0)

-- The camera's rest position: the cursor's parallax moves it from here (new Vector3(0, 0, 3.75f)).
const Origin = vector.create(0, 0, 3.75)

-- Moves the cursor, then the camera: by the parallax, or not at all when Still (the Lock button's camera).
-- @src scripts/game/camera/CameraLock.cs:Process L10-53
const function Place(
	Attempt: CameraMode.Attempt,
	ReplayManager: CameraMode.ReplayManager,
	Camera: CameraMode.Camera,
	Cursor: CameraMode.Cursor,
	MouseDelta: vector,
	Sensitivity: number,
	Still: boolean
)
	const Settings = Attempt.Settings
	const Delta = FlipY * (MouseDelta * Sensitivity / 120)

	if not Attempt.IsReplay and not (math.isfinite(Delta.x) and math.isfinite(Delta.y)) then
		return
	end

	if Settings.CursorDrift.Value then
		if Attempt.IsReplay then
			Attempt.CursorPosition = vector.clamp(ReplayManager.CursorPosition, MinBounds, Bounds)
		else
			Attempt.CursorPosition = vector.clamp(Attempt.CursorPosition + Delta, MinBounds, Bounds)
		end
	else
		if Attempt.IsReplay then
			Attempt.RawCursorPosition = ReplayManager.CursorPosition
		else
			const Overshoot = CameraMode.OvershootOf(Settings)
			const Give = vector.create(Overshoot, Overshoot, 0)

			Attempt.RawCursorPosition = vector.clamp(Attempt.RawCursorPosition + Delta, MinBounds - Give, Bounds + Give)
		end

		Attempt.CursorPosition = vector.clamp(Attempt.RawCursorPosition, MinBounds, Bounds)
	end

	const Parallax = Numbers.F32(Settings.CameraParallax.Value)

	-- The camera manages the parallax itself: a replay with several recordings keeps it still, and so does Lock.
	const CursorOffset = if Still or (Attempt.IsReplay and #Attempt.Replays > 1)
		then vector.zero
		else vector.create(Attempt.CursorPosition.x, Attempt.CursorPosition.y, 0) * Parallax

	Camera.Position = Origin + CursorOffset
	Camera.Rotation = vector.zero

	const CursorPoint = vector.create(Attempt.CursorPosition.x, Attempt.CursorPosition.y, 0)

	if math.isfinite(CursorPoint.x) and math.isfinite(CursorPoint.y) and math.isfinite(CursorPoint.z) then
		Cursor.Position = CursorPoint
	end
end

-- The default camera's frame.
const function Process(
	Attempt: CameraMode.Attempt,
	ReplayManager: CameraMode.ReplayManager,
	Camera: CameraMode.Camera,
	Cursor: CameraMode.Cursor,
	MouseDelta: vector,
	Sensitivity: number
)
	Place(Attempt, ReplayManager, Camera, Cursor, MouseDelta, Sensitivity, false)
end

-- The Lock button's frame: the same cursor, and a camera that never moves.
const function ProcessStill(
	Attempt: CameraMode.Attempt,
	ReplayManager: CameraMode.ReplayManager,
	Camera: CameraMode.Camera,
	Cursor: CameraMode.Cursor,
	MouseDelta: vector,
	Sensitivity: number
)
	Place(Attempt, ReplayManager, Camera, Cursor, MouseDelta, Sensitivity, true)
end

-- The default camera ("Normal"), or with Still the Lock button's ("Lock").
-- @src scripts/game/camera/CameraLock.cs:CameraLock L3-8
const function New(Still: boolean?): CameraMode.CameraMode
	if Still then
		return {
			Name = "Lock",
			Rankable = true,
			Process = ProcessStill,
		}
	end

	return {
		Name = "Normal",
		Rankable = true,
		Process = Process,
	}
end

return New
