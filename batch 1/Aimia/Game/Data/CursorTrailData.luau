--!strict
--!optimize 2

--[[
	CursorTrailData.cs: one sample of the cursor trail (its time, position and rotation). A readonly record struct in C#, so
	the value is copied on assignment; New answers a new table and nothing changes it afterwards.

	Design Notes
		Time is the microsecond tick count (Time.GetTicksUsec), a number below 2^53. Position is a vector with Z = 0.
		The record's compiler-generated equality and ToString are not ported: nothing compares or prints the samples.
]]

export type CursorTrailData = {
	Time: number,
	Rotation: number,
	Position: vector,
}

-- @src scripts/game/data/CursorTrailData.cs:CursorTrailData L9-14
const function New(Time: number, Position: vector, Rotation: number): CursorTrailData
	return {
		Time = Time,
		Rotation = Rotation,
		Position = Position,
	}
end

return New
