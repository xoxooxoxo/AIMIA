--!strict
--!optimize 2

--[[
	Note.cs: a hit object at a lane position (X, Y, float32) with its hit state and the transform the renderer reads.
	IHitObject, ITimelineObject and IAnimatableObject<NoteAnimation> are the export types below (the interfaces are not
	ported as classes).

	Representation
		A Note is a table from New. Index is the 0-based position after the map's sort (Notes[Index + 1] reads it).
		Runner is the structural type the hit functions read: HitResultChanged (fired with Index and LastResult), Speed and
		Attempt. Replay and Attempt are the fields Note reads.

	Design Notes
		SoundManager is not ported: Sounds.PlayHitSound and Sounds.PlayMissSound are optional hooks, nil meaning no sound.
		A nil playSound argument is C#'s default true.
]]

const Constants = require("../../Constants")
const HitResult = require("../../Game/Judgments/HitResult")
const Math = require("../../Godot/Math")
const Numbers = require("../../Numbers")
const Signal = require("../../Util/Signal")
const AnimationObject = require("./Tweens/AnimationObject")
const NoteAnimation = require("./Tweens/NoteAnimation")
const ObjectType = require("./ObjectType")

export type TimelineObject = {
	Id: number,
	Index: number,
	Millisecond: number,
}

export type HitObject = TimelineObject & {
	X: number,
	Y: number,
	HitWindow: number,
	Hittable: boolean,
	LastResult: HitResult.HitResult,
}

export type Replay = {
	Notes: { number },
}

export type Attempt = {
	StartFrom: number,
	Progress: number,
	IsReplay: boolean,
	Replays: { Replay },
	Settings: {
		AlwaysPlayHitSound: { Value: boolean },
	},
	CursorPosition: vector,
}

export type Runner = {
	HitResultChanged: Signal.Signal<number, number>,
	Speed: number,
	Attempt: Attempt,
}

export type Note = HitObject & AnimationObject.AnimatableObject<NoteAnimation.NoteAnimation> & {
	Opacity: number,
	Transform: Math.Transform3D,
}

export type Sounds = {
	PlayHitSound: (() -> ())?,
	PlayMissSound: (() -> ())?,
}

const Sounds: Sounds = {}

-- @src scripts/map/objects/Note.cs:Note L5-112
const function New(Index: number, Millisecond: number, X: number, Y: number): Note
	return {
		Id = ObjectType.Note,
		Index = Index,
		Millisecond = Millisecond,
		X = X,
		Y = Y,
		HitWindow = 55,
		Hittable = false,
		LastResult = HitResult.None,
		CurrentTween = nil,
		AnimationObjects = nil,
		Opacity = 1,
		Transform = Math.IdentityTransform(),
	}
end

const function PlayHitSound()
	const Play = Sounds.PlayHitSound

	if Play then
		Play()
	end
end

const function PlayMissSound()
	const Play = Sounds.PlayMissSound

	if Play then
		Play()
	end
end

-- @src scripts/map/objects/Note.cs:isPastWindow L108-111
const function IsPastWindow(Note: Note, Runner: Runner, HitWindow: number): boolean
	return Note.Millisecond < Runner.Attempt.Progress - HitWindow * Runner.Speed
end

-- @src scripts/map/objects/Note.cs:CheckHitResult L83-96
const function CheckHitResult(Note: Note, Attempt: Attempt): HitResult.HitResult
	const Cursor = Attempt.CursorPosition
	const HitBox = Constants.HitBoxSize

	if Cursor.x + HitBox >= Numbers.F32(Note.X - 0.5)
		and Cursor.x - HitBox <= Numbers.F32(Note.X + 0.5)
		and Cursor.y + HitBox >= Numbers.F32(Note.Y - 0.5)
		and Cursor.y - HitBox <= Numbers.F32(Note.Y + 0.5)
	then
		return HitResult.Hit
	end

	return HitResult.Miss
end

-- @src scripts/map/objects/Note.cs:Hit L22-32
const function Hit(Note: Note, Runner: Runner, PlaySound: boolean?)
	if Note.LastResult ~= HitResult.None then
		return
	end

	Note.LastResult = HitResult.Hit
	Signal.Fire(Runner.HitResultChanged, Note.Index, Note.LastResult)

	if PlaySound ~= false then
		PlayHitSound()
	end
end

-- @src scripts/map/objects/Note.cs:Miss L34-44
const function Miss(Note: Note, Runner: Runner, PlaySound: boolean?)
	if Note.LastResult ~= HitResult.None then
		return
	end

	Note.LastResult = HitResult.Miss
	Signal.Fire(Runner.HitResultChanged, Note.Index, Note.LastResult)

	if PlaySound ~= false then
		PlayMissSound()
	end
end

-- @src scripts/map/objects/Note.cs:DoProcess L46-51
const function DoProcess(Note: Note, Runner: Runner): boolean
	const Attempt = Runner.Attempt

	return Note.Millisecond >= Attempt.StartFrom
		and Note.Millisecond - Attempt.Progress <= 0
		and Note.LastResult == HitResult.None
end

-- @src scripts/map/objects/Note.cs:Process L53-81
const function Process(Note: Note, Runner: Runner)
	const Attempt = Runner.Attempt

	if not Note.Hittable then
		Note.Hittable = true

		if Attempt.Settings.AlwaysPlayHitSound.Value then
			PlayHitSound()
		end
	end

	const Late = IsPastWindow(Note, Runner, Note.HitWindow)
	const ReplayLateness = if Attempt.IsReplay and #Attempt.Replays == 1 then Attempt.Replays[1].Notes[Note.Index + 1] else 0

	if Late and (not Attempt.IsReplay or ReplayLateness == -1) then
		Miss(Note, Runner)
	elseif (not Attempt.IsReplay and CheckHitResult(Note, Attempt) == HitResult.Hit)
		or (Attempt.IsReplay and ReplayLateness ~= -1 and IsPastWindow(Note, Runner, ReplayLateness))
	then
		Hit(Note, Runner)
	end
end

-- @src scripts/map/objects/Note.cs:CompareTo L98-101
const function CompareTo(Note: Note, Other: Note): number
	if Note.Millisecond < Other.Millisecond then
		return -1
	elseif Note.Millisecond > Other.Millisecond then
		return 1
	end

	return 0
end

-- @src scripts/map/objects/Note.cs:CompareTo L103-106
const function CompareToTimeline(Note: Note, Other: unknown): number
	error("The method or operation is not implemented.", 0)
end

return {
	New = New,
	Hit = Hit,
	Miss = Miss,
	DoProcess = DoProcess,
	Process = Process,
	CheckHitResult = CheckHitResult,
	CompareTo = CompareTo,
	CompareToTimeline = CompareToTimeline,
	Sounds = Sounds,
}
