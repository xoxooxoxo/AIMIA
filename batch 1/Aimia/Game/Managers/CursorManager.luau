--!strict
--!optimize 2

--[[
	CursorManager.cs: the gameplay cursors and the camera input. UpdateCursor moves a cursor from mouse or replay input through
	the camera mode, UpdateAutoplayCursor places the autoplay cursor (straight, or through a Spin camera), ShowCursor and HideCursor
	set a cursor's opacity (instant or a 0.5 s fade), Process turns the scene's cursor and advances the fades, and Exit drops the
	replay cursors. Roblox-free: the camera and the cursors are the tables the view draws (Game/View/GameWorld).

	Representation
		Manager is one table from New. Cursors is the view's list of { Position, RotationDegrees, Transparency }: entry 1 is the
		scene's cursor, the others are the replays' cursors (the source's duplicates). Index arguments are 0-based (the source's
		cursorIndex) and index the list at Index + 1. Camera is { Position, Rotation, Fov }, Transparency is Godot's (0 opaque).
		Fades are the running transparency tweens (the source's CreateTween().TweenProperty); Process advances them each frame.
		Bind answers the three functions Game/Managers/ReplayManager calls, bound to one manager.

	Design Notes
		HideCursor calls ShowCursor, as the source does: it sets the opacity and does not hide the cursor.
		ShowCursor sets Transparency to 1 - CursorOpacity without clamping; the view clamps when it sets up the grid.
		The fade is linear over 0.5 s (Godot's default transition) from the transparency at the call. Godot's tween runs
		whether or not the runner plays, so Process advances the fades before the playing check.
		The cursor spin keeps RotationDegrees in float32 and does not round-trip through radians each frame as Node3D does.
		Basis.LookingAt, Basis.GetEuler (YXZ) and Mathf.AngleDifference are ported from GodotSharp (reference/engine) for the
		Spin autoplay. The trigonometry is double rounded to float32: DEVIATION(platform): MathF.Asin and MathF.Atan2 have no
		Luau form that rounds the same way.
		Mathf.Epsilon is 2^-23, as in UI/Menu/Play/InfoLogic/Speed.luau. Vector3.IsZeroApprox uses 1e-5 (CMP_EPSILON).
]]

const Constants = require("../../Constants")
const CameraMode = require("../Camera/CameraMode")
const Numbers = require("../../Numbers")
const SettingsProfile = require("../../Database/Settings/SettingsProfile")
const Signal = require("../../Util/Signal")

export type Cursor = {
	Position: vector,
	RotationDegrees: number,
	Transparency: number,
}

export type Attempt = CameraMode.Attempt & {
	CameraMode: CameraMode.CameraMode,
}

export type Runner = {
	Attempt: Attempt,
	Playing: boolean,
}

export type Fade = {
	Cursor: Cursor,
	From: number,
	Elapsed: number,
	Duration: number,
}

export type Manager = {
	Runner: Runner,
	ReplayManager: CameraMode.ReplayManager,
	Camera: CameraMode.Camera,
	Cursors: { Cursor },
	Settings: SettingsProfile.SettingsProfile,
	Fades: { Fade },
	DefaultPosition: vector,
	DefaultRotation: vector,
	OnCursorUpdated: Signal.Signal<vector>,
}

export type Bound = {
	UpdateCursor: (vector, number) -> (),
	ShowCursor: (number, boolean) -> (),
	HideCursor: (number, boolean) -> (),
}

const Bounds = Constants.Bounds
const MinBounds = -Bounds

-- The camera's rest position in the scene (new Vector3(0, 0, 3.76f) for the autoplay cursor; the Spin origin is 3.5).
const AutoplayOrigin = vector.create(0, 0, 3.76)
const SpinOrigin = vector.create(0, 0, 3.5)

const FadeDuration = 0.5
const FadeTarget = 1

-- Mathf.Pi (float32), Mathf.Tau (2 * Pi, exact in float32) and Mathf.Epsilon (2^-23).
const Pi = Numbers.F32(math.pi)
const Tau = 2 * Pi
const Epsilon = 1.1920928955078125e-07
const OneMinusEpsilon = Numbers.F32(1 - Epsilon)

-- Vector3.IsZeroApprox tolerance (CMP_EPSILON).
const ZeroApproxEpsilon = 0.00001

-- Vector3.Up
const Up = vector.create(0, 1, 0)

-- Vector3.Cross: each product and each difference rounded to float32.
-- @src engine/Vector3.cs:Cross L204-212
const function Cross(Left: vector, Right: vector): vector
	return vector.create(
		Numbers.F32(Numbers.F32(Left.y * Right.z) - Numbers.F32(Left.z * Right.y)),
		Numbers.F32(Numbers.F32(Left.z * Right.x) - Numbers.F32(Left.x * Right.z)),
		Numbers.F32(Numbers.F32(Left.x * Right.y) - Numbers.F32(Left.y * Right.x))
	)
end

-- Vector3.Normalized: the length from LengthSquared in float32; a zero vector stays zero.
-- @src engine/Vector3.cs:Normalized L548-553
const function Normalized(Value: vector): vector
	const LengthSquared = Numbers.F32(
		Numbers.F32(Numbers.F32(Value.x * Value.x) + Numbers.F32(Value.y * Value.y)) + Numbers.F32(Value.z * Value.z)
	)

	if LengthSquared == 0 then
		return vector.zero
	end

	const Length = Numbers.F32(math.sqrt(LengthSquared))

	return vector.create(Value.x / Length, Value.y / Length, Value.z / Length)
end

-- Vector3.IsZeroApprox: every component within the tolerance of zero.
-- @src engine/Vector3.cs:IsZeroApprox L1258-1260
const function IsZeroApprox(Value: vector): boolean
	return math.abs(Value.x) < ZeroApproxEpsilon and math.abs(Value.y) < ZeroApproxEpsilon and math.abs(Value.z) < ZeroApproxEpsilon
end

-- Mathf.AngleDifference: the signed difference of two angles, in [-Pi, Pi).
-- @src engine/Mathf.cs:AngleDifference L146-150
const function AngleDifference(From: number, To: number): number
	const Difference = Numbers.F32(math.fmod(Numbers.F32(To - From), Tau))

	return Numbers.F32(math.fmod(Numbers.F32(2 * Difference), Tau) - Difference)
end

-- Basis.GetEuler(EulerOrder.Yxz) of the basis whose columns are Column0, Column1 and Column2: rows are read off the columns.
-- @src engine/Basis.cs:GetEuler L255-491
const function EulerYxz(Column0: vector, Column1: vector, Column2: vector): vector
	const Row0 = vector.create(Column0.x, Column1.x, Column2.x)
	const Row1 = vector.create(Column0.y, Column1.y, Column2.y)
	const Row2 = vector.create(Column0.z, Column1.z, Column2.z)
	const M12 = Row1.z

	if M12 < OneMinusEpsilon then
		if M12 > -OneMinusEpsilon then
			-- A pure X rotation is returned in its simplest form.
			if Row1.x == 0 and Row0.y == 0 and Row0.z == 0 and Row2.x == 0 and Row0.x == 1 then
				return vector.create(math.atan2(-M12, Row1.y), 0, 0)
			end

			return vector.create(math.asin(-M12), math.atan2(Row0.z, Row2.z), math.atan2(Row1.x, Row1.y))
		end

		return vector.create(Tau / 4, math.atan2(Row0.y, Row0.x), 0)
	end

	return vector.create(-Tau / 4, -math.atan2(Row0.y, Row0.x), 0)
end

-- Basis.LookingAt(Target, Up).GetEuler(): the Euler angles that turn -Z toward Target (not useModelFront).
-- @src engine/Basis.cs:LookingAt L636-662
const function LookingAtEuler(Target: vector): vector
	const Column2 = -Normalized(Target)
	local Column0 = Cross(Up, Column2)

	if IsZeroApprox(Column0) then
		error("Target and up vectors are colinear. This is not advised as it may cause unwanted rotation around local Z axis.", 0)
	end

	Column0 = Normalized(Column0)

	return EulerYxz(Column0, Cross(Column2, Column0), Column2)
end

-- Advances each running fade (ShowCursor with Instant false): its cursor's transparency moves linearly to FadeTarget, and a
-- fade that arrives is removed.
const function AdvanceFades(Manager: Manager, Delta: number)
	const Fades = Manager.Fades

	for Index = #Fades, 1, -1 do
		const Fade = Fades[Index]

		Fade.Elapsed += Delta

		const Ratio = math.min(1, Fade.Elapsed / Fade.Duration)

		if Ratio >= 1 then
			Fade.Cursor.Transparency = FadeTarget
			table.remove(Fades, Index)
		else
			Fade.Cursor.Transparency = Numbers.F32(Fade.From + Numbers.F32((FadeTarget - Fade.From) * Ratio))
		end
	end
end

-- Turns the scene's cursor by CursorRotation degrees per second while the runner plays.
-- @src scripts/game/managers/CursorManager.cs:updateCursorRotation L171-172
const function UpdateCursorRotation(Manager: Manager, Delta: number)
	const Cursor = Manager.Cursors[1]
	const Step = Numbers.F32(Numbers.F32(Manager.Settings.CursorRotation.Value) * Numbers.F32(Delta))

	Cursor.RotationDegrees = Numbers.F32(Cursor.RotationDegrees + Step)
end

-- Reset everything to zero so it doesn't have infinite sensitivity.
-- @src scripts/game/managers/CursorManager.cs:repositionAbsolute L164-169
const function RepositionAbsolute(Manager: Manager)
	const Attempt = Manager.Runner.Attempt

	Manager.Camera.Rotation = vector.zero
	Attempt.RawCursorPosition = vector.zero
	Attempt.CursorPosition = vector.zero
end

-- The Spin camera turns toward the autoplay position: the mouse delta is the yaw and pitch from the camera's rotation to the
-- look at the position, scaled by 120 * Pi.
-- @src scripts/game/managers/CursorManager.cs:UpdateAutoplayCursor L136-151
const function SpinAutoplay(Manager: Manager, Position: vector)
	const Attempt = Manager.Runner.Attempt
	const Camera = Manager.Camera
	const Target = vector.create(Position.x, Position.y, 0)
	const PreviousCursor = vector.create(Attempt.CursorPosition.x, Attempt.CursorPosition.y, 0)
	const Origin = SpinOrigin + PreviousCursor * Numbers.F32(Attempt.Settings.CameraParallax.Value)
	const TargetEuler = LookingAtEuler(Target - Origin)

	const Pitch = Numbers.F32(TargetEuler.x - Camera.Rotation.x)
	const Yaw = AngleDifference(Camera.Rotation.y, TargetEuler.y)
	const MouseDelta = vector.create(-Yaw, -Pitch, 0) * Numbers.F32(120 * Pi)

	Attempt.CameraMode.Process(Attempt, Manager.ReplayManager, Camera, Manager.Cursors[1], MouseDelta, 1, true)
end

-- Builds the manager for a run. The scene's cursor is reset and the camera is put back at its default, the replays get one
-- cursor each after the first (the source's duplicates, which copy the first cursor's transparency).
-- @src scripts/game/managers/CursorManager.cs:_EnterTree L42-63
const function New(Runner: Runner, ReplayManager: CameraMode.ReplayManager, Camera: CameraMode.Camera, Cursors: { Cursor }): Manager
	const Attempt = Runner.Attempt
	const Settings = if Attempt.IsReplay then (Attempt.Replays[1].Settings :: SettingsProfile.SettingsProfile) else Attempt.Settings

	const Manager = {
		Runner = Runner,
		ReplayManager = ReplayManager,
		Camera = Camera,
		Cursors = Cursors,
		Settings = Settings,
		Fades = {} :: { Fade },
		DefaultPosition = Camera.Position,
		DefaultRotation = Camera.Rotation,
		OnCursorUpdated = Signal.New(),
	}

	Cursors[1].Position = vector.zero
	Cursors[1].RotationDegrees = 0

	for Index = #Cursors, 2, -1 do
		table.remove(Cursors, Index)
	end

	Camera.Position = Manager.DefaultPosition
	Camera.Rotation = Manager.DefaultRotation

	if Attempt.IsReplay then
		for _ = 2, #Attempt.Replays do
			table.insert(Cursors, {
				Position = vector.zero,
				RotationDegrees = 0,
				Transparency = Cursors[1].Transparency,
			})
		end
	end

	return Manager
end

-- The replay cursors are dropped when the scene leaves (the source's _ExitTree); the view removes their parts.
-- @src scripts/game/managers/CursorManager.cs:_ExitTree L65-76
const function Exit(Manager: Manager)
	for Index = #Manager.Cursors, 2, -1 do
		table.remove(Manager.Cursors, Index)
	end
end

-- Sets a cursor's opacity: an instant set to 1 - CursorOpacity, or a fade to fully transparent over 0.5 s. HideCursor is the
-- same call (see the header).
-- @src scripts/game/managers/CursorManager.cs:ShowCursor L86-96
const function ShowCursor(Manager: Manager, CursorIndex: number?, Instant: boolean?)
	const Cursor = Manager.Cursors[(CursorIndex or 0) + 1]

	if Instant ~= false then
		Cursor.Transparency = Numbers.F32(1 - Numbers.F32(Manager.Settings.CursorOpacity.Value))
	else
		table.insert(Manager.Fades, {
			Cursor = Cursor,
			From = Cursor.Transparency,
			Elapsed = 0,
			Duration = FadeDuration,
		})
	end
end

-- @src scripts/game/managers/CursorManager.cs:HideCursor L98-101
const function HideCursor(Manager: Manager, CursorIndex: number?, Instant: boolean?)
	ShowCursor(Manager, CursorIndex, Instant)
end

-- Moves a cursor from input: the input is scaled by sensitivity (and by FoV / 70), then the camera mode places the camera and
-- the cursor. The autoplay position goes through UpdateAutoplayCursor.
-- @src scripts/game/managers/CursorManager.cs:UpdateCursor L103-124
const function UpdateCursor(Manager: Manager, InputDelta: vector, CursorIndex: number?)
	Signal.Fire(Manager.OnCursorUpdated, InputDelta)

	const Settings = Manager.Settings
	const Attempt = Manager.Runner.Attempt
	local Sensitivity = Numbers.F32(Settings.Sensitivity.Value)

	if Settings.AbsoluteInput.Value and not Attempt.IsReplay then
		Sensitivity = Numbers.F32(Settings.AbsoluteSensitivity.Value)
	end

	Sensitivity = Numbers.F32(Sensitivity * Numbers.F32(Numbers.F32(Settings.FoV.Value) / 70))

	if Settings.AbsoluteInput.Value or Attempt.IsReplay then
		RepositionAbsolute(Manager)
	end

	Attempt.CameraMode.Process(Attempt, Manager.ReplayManager, Manager.Camera, Manager.Cursors[(CursorIndex or 0) + 1], InputDelta, Sensitivity)
end

-- Places the autoplay cursor. Positions that are not finite are ignored; a Spin camera turns toward the position instead of
-- moving the camera (the Spin camera moves the cursor itself).
-- @src scripts/game/managers/CursorManager.cs:UpdateAutoplayCursor L126-161
const function UpdateAutoplayCursor(Manager: Manager, Position: vector)
	if not (math.isfinite(Position.x) and math.isfinite(Position.y)) then
		return
	end

	Signal.Fire(Manager.OnCursorUpdated, Position)

	const Attempt = Manager.Runner.Attempt
	const Clamped = vector.clamp(Position, MinBounds, Bounds)

	if Attempt.CameraMode.Name == "Spin" then
		SpinAutoplay(Manager, Clamped)

		return
	end

	Attempt.RawCursorPosition = Clamped
	Attempt.CursorPosition = Clamped

	const CursorPoint = vector.create(Clamped.x, Clamped.y, 0)
	-- (Lock's camera stays still under autoplay too)
	const Parallax = if Attempt.CameraMode.Name == "Lock" then 0 else Numbers.F32(Manager.Settings.CameraParallax.Value)

	Manager.Camera.Position = AutoplayOrigin + CursorPoint * Parallax
	Manager.Camera.Rotation = vector.zero
	Manager.Cursors[1].Position = CursorPoint
end

-- Advances the fades, then, while the runner plays, turns the scene's cursor.
-- @src scripts/game/managers/CursorManager.cs:_Process L78-84
const function Process(Manager: Manager, Delta: number)
	AdvanceFades(Manager, Delta)

	if not Manager.Runner.Playing then
		return
	end

	UpdateCursorRotation(Manager, Delta)
end

-- The functions Game/Managers/ReplayManager calls take no manager: each is a closure over one manager, made once.
const function BindUpdateCursor(Manager: Manager): (vector, number) -> ()
	return function(Position: vector, Index: number)
		UpdateCursor(Manager, Position, Index)
	end
end

const function BindShowCursor(Manager: Manager): (number, boolean) -> ()
	return function(Index: number, Instant: boolean)
		ShowCursor(Manager, Index, Instant)
	end
end

const function BindHideCursor(Manager: Manager): (number, boolean) -> ()
	return function(Index: number, Instant: boolean)
		HideCursor(Manager, Index, Instant)
	end
end

-- The three bound functions of a manager (ReplayManager's CursorManager type).
const function Bind(Manager: Manager): Bound
	return {
		UpdateCursor = BindUpdateCursor(Manager),
		ShowCursor = BindShowCursor(Manager),
		HideCursor = BindHideCursor(Manager),
	}
end

return {
	New = New,
	Exit = Exit,
	Process = Process,
	ShowCursor = ShowCursor,
	HideCursor = HideCursor,
	UpdateCursor = UpdateCursor,
	UpdateAutoplayCursor = UpdateAutoplayCursor,
	Bind = Bind,
}
