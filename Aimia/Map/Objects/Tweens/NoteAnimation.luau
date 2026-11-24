--!strict
--!optimize 2

--[[
	NoteAnimation.cs: a tween of one note with a rotation and a scale. The timeline functions are inherited from
	AnimationObject (see that module); a NoteAnimation is a table from New.
]]

const ObjectType = require("../ObjectType")
const AnimationObject = require("./AnimationObject")

export type NoteAnimation = AnimationObject.AnimationObject & {
	Rotation: number,
	Scale: number,
}

-- @src scripts/map/objects/tweens/NoteAnimation.cs:NoteAnimation L3-8
const function New(Index: number, Millisecond: number, EaseType: number, TransitionType: number): NoteAnimation
	return {
		Id = ObjectType.Tween,
		Index = Index,
		Millisecond = Millisecond,
		EaseType = EaseType,
		TransitionType = TransitionType,
		Rotation = 0,
		Scale = 1,
	}
end

return New
