--!strict
--!optimize 2

--[[
	BaseSpace.cs (Node3D): the state a menu space keeps: the camera it is seen through, whether a game plays in it, the
	note hit color, and the tweens Godot's CreateTween runs on _Process. Waves builds on it.

	Representation
		A space is one table with Playing, Camera (Rotation as Godot's Euler radians, Origin, Fov in degrees, Current),
		NoteHitColor, Settings, Elapsed (seconds, the shaders' TIME) and Tweens. Base functions take the space first; a
		derived space calls them as base.X does.
		A tween is a list of tweeners. A tweener interpolates From to To over Duration with its Transition and calls Apply
		on each step. Sequential tweeners start when the previous one ends; parallel ones start with the previous one.

	Design Notes
		Elapsed starts at 0 when the space is built; Godot's TIME counts from engine start, which only shifts the phase.
		DEVIATION(render): tween values are doubles, not float32 as the C# float properties are.
		DEVIATION(render): the map cover (Map.GetCover, decoded) is not kept or drawn: the sky draws no cover image yet.
]]

const Color = require("../Godot/Color")
const SettingsProfile = require("../Database/Settings/SettingsProfile")

export type Transition = (number) -> number

export type Tweener = {
	Start: number,
	Duration: number,
	From: number,
	To: number,
	Transition: Transition,
	Apply: (number) -> (),
}

export type Tween = {
	Elapsed: number,
	Parallel: boolean,
	Transition: Transition,
	Tweeners: { Tweener },
	LastStart: number,
	End: number,
}

export type Camera = {
	Rotation: vector,
	Origin: vector,
	Fov: number,
	Current: boolean,
}

export type BaseSpace = {
	Playing: boolean,
	Camera: Camera,
	NoteHitColor: Color.Color,
	Settings: SettingsProfile.SettingsProfile,
	Elapsed: number,
	Tweens: { Tween },
}

-- Godot's TRANS_LINEAR (the tween code is not in reference/).
const function Linear(Progress: number): number
	return Progress
end

-- Godot's TRANS_QUART with EASE_OUT: 1 - (1 - t)^4.
const function QuartOut(Progress: number): number
	return 1 - (1 - Progress) ^ 4
end

-- The space before a derived space adds its own fields. The camera is Godot's default Camera3D (Fov 70); a scene's
-- camera is set by the derived space.
const function New(Settings: SettingsProfile.SettingsProfile): BaseSpace
	return {
		Playing = false,
		Camera = { Rotation = vector.zero, Origin = vector.zero, Fov = 70, Current = false },
		NoteHitColor = Color.FromRgba(0xFFFFFFFF),
		Settings = Settings,
		Elapsed = 0,
		Tweens = {},
	}
end

-- Godot's CreateTween(): a Linear tween whose tweeners run one after another.
const function CreateTween(Space: BaseSpace): Tween
	const Created = {
		Elapsed = 0,
		Parallel = false,
		Transition = Linear,
		Tweeners = {},
		LastStart = 0,
		End = 0,
	}

	table.insert(Space.Tweens, Created)

	return Created
end

-- SetTrans / SetEase: the transition of the tweeners appended after this call.
const function SetTransition(Tween: Tween, Transition: Transition)
	Tween.Transition = Transition
end

-- SetParallel: the tweeners appended after this call start with the previous one (true) or after it (false).
const function SetParallel(Tween: Tween, Parallel: boolean)
	Tween.Parallel = Parallel
end

-- TweenMethod (and TweenProperty, which is the same with an Apply that writes the property).
const function TweenMethod(Tween: Tween, From: number, To: number, Duration: number, Apply: (number) -> ())
	const Start = if Tween.Parallel then Tween.LastStart else Tween.End

	table.insert(Tween.Tweeners, {
		Start = Start,
		Duration = Duration,
		From = From,
		To = To,
		Transition = Tween.Transition,
		Apply = Apply,
	})

	Tween.LastStart = Start
	Tween.End = math.max(Tween.End, Start + Duration)
end

-- Advances every tween by Delta and drops those that finished.
const function ProcessTweens(Space: BaseSpace, Delta: number)
	for Index = #Space.Tweens, 1, -1 do
		const Tween = Space.Tweens[Index]

		Tween.Elapsed += Delta

		for _, Tweener in Tween.Tweeners do
			const Time = Tween.Elapsed - Tweener.Start

			if Time < 0 then
				continue
			end

			const Progress = math.clamp(Time / Tweener.Duration, 0, 1)

			Tweener.Apply(Tweener.From + (Tweener.To - Tweener.From) * Tweener.Transition(Progress))
		end

		if Tween.Elapsed >= Tween.End then
			table.remove(Space.Tweens, Index)
		end
	end
end

-- @src scripts/spaces/BaseSpace.cs:_Process L44-55
-- Advances the clock and the tweens. The hit-color lerp while playing reads Game.Attempt.LastHitColour: phase 3, so
-- that branch does nothing yet.
const function Process(Space: BaseSpace, Delta: number)
	Space.Elapsed += Delta

	ProcessTweens(Space, Delta)
end

-- @src scripts/spaces/BaseSpace.cs:OnHit L57-57
-- Game hook: the hit effects of a playing space. Phase 3 (Game is not ported); nothing happens yet.
const function OnHit(Space: BaseSpace, Combo: number)
end

-- @src scripts/spaces/BaseSpace.cs:onHitResultChanged L28-34
-- Game hook connected to Game.Instance.Runner while playing. Phase 3 (Game is not ported); nothing happens yet.
const function OnHitResultChanged(Space: BaseSpace, NoteIndex: number, HitResult: number)
end

-- @src scripts/spaces/BaseSpace.cs:Load L59-64
-- The hit color is the skin's last note color (SkinManager is not ported: the caller passes the skin's NoteColors).
const function Load(Space: BaseSpace, NoteColors: { Color.Color })
	const Last = NoteColors[#NoteColors]

	Space.NoteHitColor = Color.New(Last.R, Last.G, Last.B, Last.A)
end

-- @src scripts/spaces/BaseSpace.cs:UpdateMap L66-69
-- DEVIATION(render): the cover is not drawn yet (WavesPass has no image sampler), so nothing is kept.
const function UpdateMap(Space: BaseSpace)
end

-- @src scripts/spaces/BaseSpace.cs:UpdateState L71-81
-- Camera.Current follows Playing. The hit connection to Game.Instance.Runner is phase 3.
const function UpdateState(Space: BaseSpace, Playing: boolean)
	Space.Playing = Playing
	Space.Camera.Current = not Playing
end

return {
	New = New,
	Linear = Linear,
	QuartOut = QuartOut,
	CreateTween = CreateTween,
	SetTransition = SetTransition,
	SetParallel = SetParallel,
	TweenMethod = TweenMethod,
	Process = Process,
	OnHit = OnHit,
	OnHitResultChanged = OnHitResultChanged,
	Load = Load,
	UpdateMap = UpdateMap,
	UpdateState = UpdateState,
}
