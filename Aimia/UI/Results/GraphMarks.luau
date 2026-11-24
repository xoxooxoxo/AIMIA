--!strict
--!optimize 2

--[[
	The marks of the results graph (scripts/ui/results/Graph.cs, _Draw): the hit dots and miss lines at each note's time,
	and the line where the run ended, in the graph's pixels. Pure logic; UI/Results/Graph draws the marks.

	Design Notes
		A mark is a rectangle: Godot's DrawRect and a vertical DrawLine of a given width are both one rectangle here.
		Expressions that are float in C# are float32 here (Numbers.F32), so a position truncates as upstream does.
		A value that Godot's _Draw reads from a 0-based C# array is read with the index plus one.
]]

const Color = require("../../Godot/Color")
const GameAttempt = require("../../Game/Attempt")
const MapModule = require("../../Map/Map")
const Numbers = require("../../Numbers")

export type Mark = {
	X: number,
	Y: number,
	Width: number,
	Height: number,
	Color: Color.Color,
}

-- Hit offsets run from 0 to 55 (the hit window); a hit dot sits at offset / 55 of the height.
const HitOffsetRange = 55

const HitColor = Color.FromRgba(0x00ff00ff)
const MissColor = Color.FromRgba(0xff000044)
const DeathColor = Color.FromRgba(0xffff00ff)

-- The marks of an attempt in a graph of Width x Height pixels.
-- @src scripts/ui/results/Graph.cs:_Draw L5-46
const function Marks(Attempt: GameAttempt.Attempt, Width: number, Height: number): { Mark }
	const Found: { Mark } = {}
	const IsReplay = Attempt.IsReplay
	const HitsInfo = if IsReplay then Attempt.Replays[1].Notes :: { number } else Attempt.HitsInfo
	const DeathTime = Numbers.F32(if IsReplay then Attempt.MaxReplayLength else Attempt.DeathTime)
	const Length = Attempt.Map.Length
	const Notes = MapModule.GetNotes(Attempt.Map)

	for Index = Attempt.FirstNote + 1, #HitsInfo do
		const Offset = HitsInfo[Index]
		const Millisecond = Numbers.F32(Notes[Index].Millisecond)
		const NoteProgress = Numbers.F32(Millisecond / Length)

		if Millisecond > DeathTime and DeathTime ~= -1 then
			break
		end

		if Offset < 0 then
			const Position = Numbers.TruncInt32(Numbers.F32(Width * NoteProgress))

			table.insert(Found, { X = Position, Y = 0, Width = 1, Height = Height, Color = MissColor })
		else
			table.insert(Found, {
				X = Numbers.F32(Width * NoteProgress),
				Y = Numbers.F32(Height * Numbers.F32(Offset / HitOffsetRange)),
				Width = 1,
				Height = 1,
				Color = HitColor,
			})
		end
	end

	if DeathTime >= 0 then
		const Position = Numbers.TruncInt32(Numbers.F32(Width * DeathTime) / Length)

		if Position < Width then
			-- A 3 px line centered on Position.
			table.insert(Found, { X = Position - 1, Y = 0, Width = 3, Height = Height, Color = DeathColor })
		end
	end

	return Found
end

return Marks
