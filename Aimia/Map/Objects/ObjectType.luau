--!strict
--!optimize 2

--[[
	ObjectType enum of scripts/map/objects/ObjectType.cs as numbers: the source casts it (`(int)ObjectType.Note`), so the
	values stay numeric. Id of each timeline object is one of these.
]]

export type ObjectType = number

-- @src scripts/map/objects/ObjectType.cs:ObjectType L1-7
const ObjectType = {
	Unknown = -1,
	Tween = 0,
	Note = 1,
	BPM = 2,
}

return ObjectType
