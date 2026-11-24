--!strict
--!optimize 2

--[[
	AnimationObject.cs (base of the tween objects) and IAnimatableObject<T> as export types. A tween is a timeline object with
	an ease and a transition type; both are Godot Tween enums stored as their numbers.

	Design Notes
		AnimationObject is abstract upstream: its CompareTo(ITimelineObject), DoProcess and Process throw
		NotImplementedException, and NoteAnimation inherits all three unchanged, so they stay throwing functions here.
		The Runner argument is untyped: the Note module imports this one, so the Runner type cannot come back.
]]

export type AnimationObject = {
	Id: number,
	Index: number,
	Millisecond: number,
	EaseType: number,
	TransitionType: number,
}

export type AnimatableObject<T> = {
	CurrentTween: unknown?,
	AnimationObjects: { T }?,
}

-- @src scripts/map/objects/tweens/AnimationObject.cs:CompareTo L18-21
const function CompareToTimeline(Animation: AnimationObject, Other: unknown): number
	error("The method or operation is not implemented.", 0)
end

-- @src scripts/map/objects/tweens/AnimationObject.cs:DoProcess L23-26
const function DoProcess(Animation: AnimationObject, Runner: unknown): boolean
	error("The method or operation is not implemented.", 0)
end

-- @src scripts/map/objects/tweens/AnimationObject.cs:Process L28-31
const function Process(Animation: AnimationObject, Runner: unknown)
	error("The method or operation is not implemented.", 0)
end

return {
	CompareToTimeline = CompareToTimeline,
	DoProcess = DoProcess,
	Process = Process,
}
