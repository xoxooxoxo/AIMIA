--!strict
--!optimize 2

--[[
	The per-note math of NoteRenderer.cs: which notes draw (doRender), a note's depth and progress, its fades, its transform
	after the modifiers' render changes, and its alpha. Roblox-free: the view (Game/View/NoteRenderer) reads each drawn note's
	Transform and alpha and writes its Part.

	Representation
		Params is one table per renderer: New builds it and Refresh rewrites it from the settings before each frame, so no table is
		made per note or per frame. Its Basis is the note's scale (noteSize / 2 on each axis), one table shared by every note;
		nothing mutates a basis in place (the modifiers build new ones). A note's Transform is the note's own table (Note.New),
		written in place, as the source's struct field is written in place.
		Place answers the alpha, or nil for a slot that is not drawn (the source's transparent instance).

	Design Notes
		Each float the source computes is Numbers.F32 of its operation. Math.Max, Math.Min and Math.Clamp propagate NaN, so Max,
		Min and Clamp01 here do too. The doRender bound is a double (-HIT_WINDOW * speed), compared with the float offset.
		Mathf.Epsilon is 2^-23 as in UI/Menu/Play/InfoLogic/Speed.luau.
]]

const Constants = require("../../Constants")
const HitResult = require("../Judgments/HitResult")
const Math = require("../../Godot/Math")
const Modifier = require("../Modifiers/Modifier")
const Numbers = require("../../Numbers")
const SettingsProfile = require("../../Database/Settings/SettingsProfile")

export type Note = Modifier.Note & {
	Millisecond: number,
	LastResult: HitResult.HitResult,
}

export type Attempt = Modifier.Attempt & {
	Modifiers: { Modifier.Modifier },
}

export type Params = {
	NoteSize: number,
	ApproachTime: number,
	ApproachDistance: number,
	FadeIn: number,
	FadeOut: number,
	NoteOpacity: number,
	NoteOpacityExponent: number,
	Pushback: boolean,
	HitWindowDepth: number,
	Basis: Math.Basis,
}

-- Mathf.Epsilon (float32 2^-23), the floor of the opacity exponent.
const Epsilon = 1.1920928955078125e-07

-- Math.Max of two floats: NaN when either is NaN.
const function Max(First: number, Second: number): number
	if First ~= First then
		return First
	end

	if Second ~= Second then
		return Second
	end

	if Second > First then
		return Second
	end

	return First
end

-- Math.Min of two floats: NaN when either is NaN.
const function Min(First: number, Second: number): number
	if First ~= First then
		return First
	end

	if Second ~= Second then
		return Second
	end

	if Second < First then
		return Second
	end

	return First
end

-- Math.Clamp(value, 0, 1) of a float: NaN stays NaN.
const function Clamp01(Value: number): number
	if Value < 0 then
		return 0
	end

	if Value > 1 then
		return 1
	end

	return Value
end

-- The note's scale basis: each axis scaled by Half (new Transform3D(x, y, z, zero) of the source).
const function ScaleBasis(Half: number): Math.Basis
	return {
		vector.create(Half, 0, 0),
		vector.create(0, Half, 0),
		vector.create(0, 0, Half),
	}
end

-- Rewrites Params from the settings (Render's locals). The basis is rebuilt only when the note size changes.
-- @src scripts/game/renderers/NoteRenderer.cs:Render L65-132
const function Refresh(Params: Params, Settings: SettingsProfile.SettingsProfile)
	const ApproachRate = Numbers.F32(Settings.ApproachRate.Value)
	const NoteSize = Numbers.F32(Settings.NoteSize.Value)

	if NoteSize ~= Params.NoteSize then
		Params.Basis = ScaleBasis(Numbers.F32(NoteSize / 2))
	end

	Params.NoteSize = NoteSize
	Params.ApproachTime = Numbers.F32(Settings.ApproachTime.Value)
	Params.ApproachDistance = Numbers.F32(Settings.ApproachDistance.Value)
	Params.FadeIn = Numbers.F32(Numbers.F32(Settings.FadeIn.Value) / 100)
	Params.FadeOut = Numbers.F32(Numbers.F32(Settings.FadeOut.Value) / 100)
	Params.NoteOpacity = Numbers.F32(Settings.NoteOpacity.Value)
	Params.NoteOpacityExponent = Max(Epsilon, Numbers.F32(Settings.NoteOpacityExponent.Value))
	Params.Pushback = Settings.Pushback.Value
	Params.HitWindowDepth = if Params.Pushback then Numbers.F32(Numbers.F32(Constants.HitWindow * ApproachRate) / 1000) else 0
end

-- A renderer's Params before its first Render; Render refreshes them from the settings each frame.
const function New(): Params
	const Params = {
		NoteSize = 0,
		ApproachTime = 0,
		ApproachDistance = 0,
		FadeIn = 0,
		FadeOut = 0,
		NoteOpacity = 0,
		NoteOpacityExponent = 1,
		Pushback = false,
		HitWindowDepth = 0,
		Basis = ScaleBasis(0),
	}

	return Params
end

-- doRender: the note is at most ApproachTime * 1000 * speed ms ahead, and, with pushback, at least HIT_WINDOW * speed behind.
-- @src scripts/game/renderers/NoteRenderer.cs:doRender L59-63
const function DoRender(Params: Params, Millisecond: number, Time: number, Speed: number): boolean
	const Offset = Numbers.F32(Millisecond - Time)
	const Lower = if Params.Pushback then -Constants.HitWindow * Speed else 0
	const Upper = Numbers.F32(Numbers.F32(Params.ApproachTime * 1000) * Speed)

	return Offset >= Lower and Offset <= Upper
end

-- The note's distance in front of the camera: (Millisecond - Progress) / (1000 * ApproachTime) * ApproachDistance / Speed.
-- @src scripts/game/renderers/NoteRenderer.cs:Render L100-100
const function DepthOf(Params: Params, Millisecond: number, Time: number, Speed: number): number
	const Offset = Numbers.F32(Millisecond - Time)
	const Scale = Numbers.F32(1000 * Params.ApproachTime)

	return Numbers.F32(Numbers.F32(Numbers.F32(Offset / Scale) * Params.ApproachDistance) / Speed)
end

-- 1 - max(0, (depth + hitWindowDepth) / (ApproachDistance + hitWindowDepth)).
-- @src scripts/game/renderers/NoteRenderer.cs:Render L101-101
const function ProgressOf(Params: Params, Depth: number): number
	const Window = Params.HitWindowDepth
	const Ratio = Numbers.F32(Numbers.F32(Depth + Window) / Numbers.F32(Params.ApproachDistance + Window))

	return Numbers.F32(1 - Max(0, Ratio))
end

-- Draws one note into its slot: sets the note's Opacity and Transform as the source does (before and after the modifiers)
-- and answers the alpha its color takes, or nil when the slot is not drawn.
-- @src scripts/game/renderers/NoteRenderer.cs:Render L65-132
const function Place(Params: Params, Note: Note, Attempt: Attempt): number?
	const Time = Numbers.F32(Attempt.Progress)
	const Speed = Numbers.F32(Attempt.Speed)

	if not DoRender(Params, Note.Millisecond, Time, Speed) or Note.LastResult == HitResult.Hit then
		return nil
	end

	const Depth = DepthOf(Params, Note.Millisecond, Time, Speed)
	const Progress = ProgressOf(Params, Depth)

	Note.Opacity = 1
	Note.Transform.Basis = Params.Basis

	if Params.FadeIn > 0 then
		Note.Opacity = Min(1, Numbers.F32(Progress / Params.FadeIn))
	end

	if Params.FadeOut > 0 and Attempt.UseFadeOut then
		Note.Opacity = Numbers.F32(Note.Opacity - Numbers.F32(1 - Min(1, Numbers.F32(Numbers.F32(1 - Progress) / Params.FadeOut))))
	end

	Note.Transform.Origin = vector.create(Note.X, Note.Y, -Depth)

	for _, Mod in Attempt.Modifiers do
		if Mod.ModifyRenderObject then
			Mod.ModifyRenderObject(Note, Attempt)
		end
	end

	const Opacity = Max(0, Numbers.F32(Note.Opacity * Params.NoteOpacity))

	return Clamp01(Numbers.F32(math.pow(Opacity, Params.NoteOpacityExponent)))
end

return {
	New = New,
	Refresh = Refresh,
	Place = Place,
}
