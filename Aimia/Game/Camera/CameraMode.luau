--!strict
--!optimize 2

--[[
	CameraMode.cs as types: the mode's Name (the id replay files store and the UI lists), Rankable and Process, which
	CameraLock and CameraSpin (Game/Camera/CameraLock, CameraSpin) build. Process moves the cursor and the 3D camera for one
	frame.

	Representation
		The types are declared in Map/ReplayTypes, with the Replay type they cycle through (a replay names its camera mode, and
		the mode's attempt names the replays); this module re-exports them under the names the modes use. Attempt is the fields
		Process reads or writes, typed as Game/Attempt types them, so a real Attempt is passed with no cast.
		Camera is { Position, Rotation, Fov }: Rotation is Godot's YXZ Euler angles in radians. Cursor is { Position }. A Vector2
		is a vector with Z = 0.

	Design Notes
		The mode's Basis is not stored: CameraSpin derives it from Rotation when it needs it.
]]

const ReplayTypes = require("../../Map/ReplayTypes")

export type Attempt = ReplayTypes.CameraAttempt
export type ReplayManager = ReplayTypes.ReplayManager
export type Camera = ReplayTypes.Camera
export type Cursor = ReplayTypes.Cursor
export type CameraMode = ReplayTypes.CameraMode

-- How far past the edge the hidden position can go (Edge Overshoot), in grid units.
const function OvershootOf(Settings: any): number
	const Value = Settings.EdgeOvershoot.Value

	return if math.isfinite(Value) then math.clamp(Value, 0, 3) else 0.5
end

return {
	OvershootOf = OvershootOf,
}
