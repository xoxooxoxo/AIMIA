--!strict
--!optimize 2

--[[
	FlatPreview's logic: the 3 x 3 grid of the map's notes as they pass the playhead. Each note lights the tile of its
	position; the tiles fade back every frame.

	Design Notes
		A tile is 0-based (0 is the top left, 8 the bottom right), as the source computes pos.X + 3 * pos.Y. The UI maps it to
		its ColorRect (tile + 1).
		Passed answers the notes that a time reaches from the last one passed, in the source's loop: the first index it
		checks and the last one reached. Notes [first, last] (0-based) light; an empty range means none did.
		Upstream quirk kept: the first index is clamped to the last note, so the last note's tile is lit again every frame
		once the playhead is past it.
]]

const Misc = require("../../../../Util/Misc")
const Note = require("../../../../Map/Objects/Note")
const Numbers = require("../../../../Numbers")

const GridSize = 3
const LastCell = 2
const FadeRate = 6

-- The tile of a note, 0-based: its column (x + 1.5, floored, clamped) and its row (-y + 1.5, floored, clamped).
-- @src scripts/ui/FlatPreview.cs:_Process L80-81
const function TileOf(Entry: Note.Note): number
	const Column = math.clamp(Numbers.TruncInt32((Entry.X + 1.5) // 1), 0, LastCell)
	const Row = math.clamp(Numbers.TruncInt32((-Entry.Y + 1.5) // 1), 0, LastCell)

	return Column + GridSize * Row
end

-- The millisecond of every note, in order (the timestamps the playhead is searched in).
-- @src scripts/ui/FlatPreview.cs:Setup L101
const function Timestamps(Notes: { Note.Note }): { number }
	const Times: { number } = {}

	for _, Entry in Notes do
		table.insert(Times, Entry.Millisecond)
	end

	return Times
end

-- The index (0-based) of the last note at or before a time, from the timestamps (-1 before the first).
-- @src scripts/ui/FlatPreview.cs:Seek L111
const function Rewind(Times: { number }, Time: number): number
	return Misc.BinarySearch(Times, Time)
end

-- The notes a time reaches after the last one passed (0-based, -1 for none). The loop checks from First and stops at the first
-- note the time has not reached: notes [First, Lit] light, where Lit is First - 1 when none is reached, and LastPassed
-- becomes Lit only when some note was reached (the source sets it inside the passing branch).
-- @src scripts/ui/FlatPreview.cs:_Process L74-89
const function Passed(Notes: { Note.Note }, Time: number, LastPassed: number): (number, number, number)
	const Count = #Notes
	const First = math.clamp(LastPassed + 1, 0, math.max(0, Count - 1))
	local Lit = First - 1
	local Index = First

	while Index < Count do
		if Time < Notes[Index + 1].Millisecond then
			break
		end

		Lit = Index
		Index += 1
	end

	const NewLastPassed = if Lit >= First then Lit else LastPassed

	return First, Lit, NewLastPassed
end

-- The brightness a tile has after a frame of fading (float32 of min(1, delta * 6)).
-- @src scripts/ui/FlatPreview.cs:_Process L45
const function FadeAmount(Delta: number): number
	return Numbers.F32(math.min(1, Delta * FadeRate))
end

return {
	TileOf = TileOf,
	Timestamps = Timestamps,
	Rewind = Rewind,
	Passed = Passed,
	FadeAmount = FadeAmount,
}
