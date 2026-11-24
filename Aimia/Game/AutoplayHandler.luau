--!strict
--!optimize 2

--[[
	AutoplayHandler.cs: the autoplay cursor. The notes are merged by millisecond, grouped into points, compressed and shifted
	so the Catmull-Rom spline through the points still hits every note, then sampled at the playback position. The points
	are cached under the SHA-256 of the merged notes.

	Website path (PathStyle "Website", the default): the cursor of the rhythia.com map preview. It goes through every note's
	centre at the note's time, along a centripetal Catmull-Rom curve (alpha 0.5, Barry-Goldman form) through the stops, walked
	linearly in time from one stop to the next. Notes on one spot in a row (a jack or a stack) are one stop, held from the first
	to the last, and the curve's tangents come from the different spots around it. The path never turns a corner and eases
	toward notes through the curve's own shape. Measured from the site's MP4 (2026-11-08): this model matches its cursor to
	0.06-0.12 px. "Upstream" keeps Rhythia's own path below (shifted points, a time-knot curve with alpha 0.4 and tension -1).
	Autoplay hits don't depend on the path: Runner hits every note at its own millisecond.

	Representation
		An AutoNote is { Position: vector, Millisecond: number }: Position is a Godot Vector2 as a vector with Z = 0, each lane
		a float32 value. A handler is { ProcessedData, LastLoadedNote }; LastLoadedNote is the 0-based index the source keeps
		(ProcessedData[LastLoadedNote + 1] reads it).

	Design Notes
		hitboxSize() is a constant (Constants.HitBoxSize does not change), so its products are constants too.
		The cache is a file of Util/FileSystem under Constants.UserFolder, not the OS user folder.
		Attempt is the structural type below: only Map.Notes is read.
		Vector2 Dot, Normalized and Clamp are written here: Godot/Math exports no two-lane members. DistanceTo is Math.DistanceTo,
		which is exact for Z = 0.
]]

const Constants = require("../Constants")
const Math = require("../Godot/Math")
const Numbers = require("../Numbers")
const FileSystem = require("../Util/FileSystem")
const Sha256 = require("../Util/Sha256")
const Sort = require("../Util/Sort")

export type AutoNote = {
	Position: vector,
	Millisecond: number,
}

-- The fields of a Note that the autoplay path reads (Map/Objects/Note.luau has more).
export type AttemptNote = {
	X: number,
	Y: number,
	Millisecond: number,
}

export type AutoplayAttempt = {
	Map: {
		Notes: { AttemptNote },
	},
}

-- A stop of the website path: where the cursor sits from Arrive to Leave (milliseconds).
export type Stop = {
	Position: vector,
	Arrive: number,
	Leave: number,
}

export type AutoplayHandler = {
	ProcessedData: { AutoNote },
	LastLoadedNote: number,
	-- the website path's stops (PathStyle "Website"); LastLoadedNote is then the stop last arrived at
	Stops: { Stop }?,
}

const CacheVersion = 1
const SplineAlpha = Numbers.F32(0.4)
const SplineTension = -1
const TensionScale = Numbers.F32(1 - SplineTension)
const SpeedScaleBase = Numbers.F32(0.8)
const SpeedScaleSpan = Numbers.F32(0.2)
const MaxShiftMultiplier = Numbers.F32(0.25)
const HitReachFraction = Numbers.F32(0.9)
-- which path the cursor takes (see the header): "Website" or "Upstream"
const PathStyle = "Website"
-- the website path's curve: alpha 0.5 is centripetal (the site's); two stops closer than SameSpot are one spot, and a knot step
-- is at least MinKnot so nearly equal points can't divide by zero
const PathAlpha = 0.5
const SameSpot = 1e-3
const MinKnot = 1e-2

-- @src scripts/game/AutoplayHandler.cs:hitboxSize L339-339
const HitboxSize = Numbers.F32(0.5 + Constants.HitBoxSize)

-- hitboxSize() * 0.9f: a note and the cursor are a hit when they are closer than this on both lanes.
const HitReach = Numbers.F32(HitboxSize * HitReachFraction)

-- hitboxSize() * max_shift_multiplier: the largest shift of one point.
const MaxShift = Numbers.F32(HitboxSize * MaxShiftMultiplier)

-- Math.Max of two floats as .NET has it: a NaN operand is the result. Luau's math.max keeps a NaN only when it is the
-- first operand. Signed zeros cannot reach it here (no operand is -0).
const function MaxFloat(First: number, Second: number): number
	if First ~= First then
		return First
	elseif Second ~= Second then
		return Second
	end

	return if First >= Second then First else Second
end

-- Vector2.Dot: X*X' + Y*Y', each product and the sum rounded to float32 (the two-lane form of Vector3.Dot).
-- @src engine/Vector3.cs:Dot L332-335
const function Dot(Left: vector, Right: vector): number
	return Numbers.F32(Numbers.F32(Left.x * Right.x) + Numbers.F32(Left.y * Right.y))
end

-- Vector2.Normalized, in the form of Vector3.Normalize (reference/engine has no Vector2.cs): a zero length gives zero,
-- otherwise each lane is divided by the float32 length.
-- @src engine/Vector3.cs:Normalize L108-123
const function Normalized(Value: vector): vector
	const LengthSquared = Numbers.F32(Numbers.F32(Value.x * Value.x) + Numbers.F32(Value.y * Value.y))

	if LengthSquared == 0 then
		return vector.zero
	end

	const Length = Numbers.F32(math.sqrt(LengthSquared))

	return vector.create(Numbers.F32(Value.x / Length), Numbers.F32(Value.y / Length), 0)
end

-- Vector2.Clamp(-Constants.BOUNDS, Constants.BOUNDS): each lane through Mathf.Clamp (a NaN lane stays NaN).
-- @src engine/Vector3.cs:Clamp L171-179
const function ClampToBounds(Position: vector): vector
	const Bounds = Constants.Bounds

	return vector.create(math.clamp(Position.x, -Bounds.x, Bounds.x), math.clamp(Position.y, -Bounds.y, Bounds.y), 0)
end

-- @src scripts/game/AutoplayHandler.cs:clampShift L324-335
const function ClampShift(Shift: vector, Limit: number): vector
	if Shift.x == 0 or Shift.y == 0 then
		return vector.create(math.clamp(Shift.x, -Limit, Limit), math.clamp(Shift.y, -Limit, Limit), 0)
	end

	const FirstScale = Numbers.F32(math.clamp(Shift.x, -Limit, Limit) / Shift.x)
	const Scaled = Shift * FirstScale
	const SecondScale = Numbers.F32(math.clamp(Scaled.y, -Limit, Limit) / Scaled.y)

	return Scaled * SecondScale
end

-- @src scripts/game/AutoplayHandler.cs:sigmoid L337-337
const function Sigmoid(Value: number): number
	return Numbers.F32(1 / Numbers.F32(1 + Numbers.F32(math.exp(-Value))))
end

-- The AutoNote overload of checkHit (L257) is this with cursorPos.Position.
-- @src scripts/game/AutoplayHandler.cs:checkHit L259-263
const function CheckHit(Note: AutoNote, CursorPosition: vector, Size: number): boolean
	const Difference = Note.Position - CursorPosition

	return MaxFloat(math.abs(Difference.x), math.abs(Difference.y)) < Size
end

-- The first index (0-based) whose Millisecond is not before Time.
-- @src scripts/game/AutoplayHandler.cs:lowerBound L341-355
const function LowerBound(Notes: { AutoNote }, Time: number): number
	local Low = 0
	local High = #Notes

	while Low < High do
		const Middle = Low + (High - Low) // 2

		if Notes[Middle + 1].Millisecond < Time then
			Low = Middle + 1
		else
			High = Middle
		end
	end

	return Low
end

-- The comparison of mergeSimultaneousNotes (L363): CompareTo on whole milliseconds, which are never NaN.
const function CompareMilliseconds(First: AutoNote, Second: AutoNote): number
	if First.Millisecond < Second.Millisecond then
		return -1
	elseif First.Millisecond > Second.Millisecond then
		return 1
	end

	return 0
end

-- Notes at one millisecond become one note at their average position, summed in list order (the order the sort leaves).
-- @src scripts/game/AutoplayHandler.cs:mergeSimultaneousNotes L357-385
const function MergeSimultaneousNotes(Notes: { AutoNote }): { AutoNote }
	for Index = 2, #Notes do
		if Notes[Index].Millisecond < Notes[Index - 1].Millisecond then
			Sort(Notes, CompareMilliseconds)

			break
		end
	end

	const Merged: { AutoNote } = {}
	local NoteIndex = 0

	while NoteIndex < #Notes do
		const First = Notes[NoteIndex + 1]

		NoteIndex += 1

		local Position = First.Position
		local Count = 1

		while NoteIndex < #Notes and Notes[NoteIndex + 1].Millisecond == First.Millisecond do
			Position += Notes[NoteIndex + 1].Position
			NoteIndex += 1
			Count += 1
		end

		table.insert(Merged, { Position = Position / Count, Millisecond = First.Millisecond })
	end

	return Merged
end

-- One lane of the spline. The tangents are one-sided Catmull-Rom slopes over the time steps; a non-finite tangent is 0.
-- @src scripts/game/AutoplayHandler.cs:catmullRomRaw L287-322
const function CatmullRomRaw(
	Pos0: number,
	Pos1: number,
	Pos2: number,
	Pos3: number,
	U: number,
	Time0: number,
	Time1: number,
	Time2: number,
	Time3: number
): number
	const Step01 = Numbers.F32(MaxFloat(math.abs(Numbers.F32(Time0 - Time1)), 1) ^ SplineAlpha)
	const Step12 = Numbers.F32(MaxFloat(math.abs(Numbers.F32(Time1 - Time2)), 1) ^ SplineAlpha)
	const Step23 = Numbers.F32(MaxFloat(math.abs(Numbers.F32(Time2 - Time3)), 1) ^ SplineAlpha)

	const Slope01 = Numbers.F32(Numbers.F32(Pos1 - Pos0) / Step01)
	const Slope02 = Numbers.F32(Numbers.F32(Pos2 - Pos0) / Numbers.F32(Step01 + Step12))
	const Inner1 = Numbers.F32(Numbers.F32(Pos2 - Pos1) + Numbers.F32(Step12 * Numbers.F32(Slope01 - Slope02)))
	local Tangent1 = Numbers.F32(TensionScale * Inner1)

	const Slope23 = Numbers.F32(Numbers.F32(Pos3 - Pos2) / Step23)
	const Slope13 = Numbers.F32(Numbers.F32(Pos3 - Pos1) / Numbers.F32(Step12 + Step23))
	const Inner2 = Numbers.F32(Numbers.F32(Pos2 - Pos1) + Numbers.F32(Step12 * Numbers.F32(Slope23 - Slope13)))
	local Tangent2 = Numbers.F32(TensionScale * Inner2)

	if not math.isfinite(Tangent1) then
		Tangent1 = 0
	end

	if not math.isfinite(Tangent2) then
		Tangent2 = 0
	end

	const U2 = Numbers.F32(U * U)
	const Difference = Numbers.F32(Pos1 - Pos2)
	const Cubic = Numbers.F32(Numbers.F32(Numbers.F32(Numbers.F32(2 * Difference) + Tangent1) + Tangent2) * U2)
	const CubicTerm = Numbers.F32(Cubic * U)
	const Quadratic = Numbers.F32(Numbers.F32(Numbers.F32(Numbers.F32(-3 * Difference) - Tangent1) - Tangent1) - Tangent2)
	const QuadraticTerm = Numbers.F32(Quadratic * U2)
	const LinearTerm = Numbers.F32(Tangent1 * U)

	return Numbers.F32(Numbers.F32(Numbers.F32(CubicTerm + QuadraticTerm) + LinearTerm) + Pos1)
end

-- The spline through four notes at time Time, with Catmull-Rom tangents (alpha 0.4, tension -1), float32 at each step.
-- @src scripts/game/AutoplayHandler.cs:getSplinePosition L265-285
const function GetSplinePosition(Note0: AutoNote, Note1: AutoNote, Note2: AutoNote, Note3: AutoNote, Time: number): vector
	const SegmentDuration = Note2.Millisecond - Note1.Millisecond

	if SegmentDuration <= 0 then
		return Note1.Position
	end

	if Note1.Position == Note2.Position then
		return Note1.Position
	end

	const U = Numbers.F32(math.clamp((Time - Note1.Millisecond) / SegmentDuration, 0, 1))

	return vector.create(
		CatmullRomRaw(Note0.Position.x, Note1.Position.x, Note2.Position.x, Note3.Position.x, U, Note0.Millisecond, Note1.Millisecond, Note2.Millisecond, Note3.Millisecond),
		CatmullRomRaw(Note0.Position.y, Note1.Position.y, Note2.Position.y, Note3.Position.y, U, Note0.Millisecond, Note1.Millisecond, Note2.Millisecond, Note3.Millisecond),
		0
	)
end

-- The spline through the points around LastIndex (0-based), clamped to the bounds: the tail of GetCursorPosition
-- (L81-86) and of getCursorPositionFromNotes (L249-254).
const function SplinePositionAt(NoteData: { AutoNote }, LastIndex: number, Progress: number): vector
	const Count = #NoteData
	const Note0 = NoteData[math.max(LastIndex - 1, 0) + 1]
	const Note1 = NoteData[LastIndex + 1]
	const Note2 = NoteData[math.min(LastIndex + 1, Count - 1) + 1]
	const Note3 = NoteData[math.min(LastIndex + 2, Count - 1) + 1]

	return ClampToBounds(GetSplinePosition(Note0, Note1, Note2, Note3, Progress))
end

-- @src scripts/game/AutoplayHandler.cs:getCursorPositionFromNotes L228-255
const function GetCursorPositionFromNotes(NoteData: { AutoNote }, Elapsed: number): vector
	if #NoteData == 0 then
		return vector.zero
	end

	local TempLastLoadedNote = 0

	while TempLastLoadedNote + 1 < #NoteData do
		if NoteData[TempLastLoadedNote + 2].Millisecond > Elapsed then
			break
		end

		TempLastLoadedNote += 1
	end

	return SplinePositionAt(NoteData, TempLastLoadedNote, Elapsed)
end

-- The website path's stops: a note within 5 ms and within hit reach of the one before it joins its stop (as upstream groups
-- them, at their average), and a stop on the same spot as the one before it (a jack or a stack) extends that one instead.
const function BuildStops(Notes: { AutoNote }): { Stop }
	const Stops: { Stop } = {}
	local Index = 1

	while Index <= #Notes do
		const Note = Notes[Index]
		local Sum = Note.Position
		local Count = 1
		local Leave = Note.Millisecond

		Index += 1

		while Index <= #Notes and math.abs(Notes[Index].Millisecond - Note.Millisecond) <= 5 and CheckHit(Note, Notes[Index].Position, HitReach) do
			Sum += Notes[Index].Position
			Count += 1
			Leave = Notes[Index].Millisecond
			Index += 1
		end

		const Position = Sum / Count
		const Previous = Stops[#Stops]

		if Previous and vector.magnitude(Position - Previous.Position) < SameSpot then
			Previous.Leave = Leave
		else
			table.insert(Stops, { Position = Position, Arrive = Note.Millisecond, Leave = Leave })
		end
	end

	return Stops
end

-- The knot step between two points: their distance to the power alpha.
const function Knot(From: vector, To: vector): number
	return math.max(vector.magnitude(To - From), MinKnot) ^ PathAlpha
end

-- The point at fraction S (0 to 1) of the way from P1 to P2 on the Catmull-Rom curve through P0 to P3 (Barry-Goldman's
-- pyramid of linear blends, with knots from Knot).
const function Centripetal(P0: vector, P1: vector, P2: vector, P3: vector, S: number): vector
	const T1 = Knot(P0, P1)
	const T2 = T1 + Knot(P1, P2)
	const T3 = T2 + Knot(P2, P3)
	const T = T1 + (T2 - T1) * S
	const A1 = P0 * ((T1 - T) / T1) + P1 * (T / T1)
	const A2 = P1 * ((T2 - T) / (T2 - T1)) + P2 * ((T - T1) / (T2 - T1))
	const A3 = P2 * ((T3 - T) / (T3 - T2)) + P3 * ((T - T2) / (T3 - T2))
	const B1 = A1 * ((T2 - T) / T2) + A2 * (T / T2)
	const B2 = A2 * ((T3 - T) / (T3 - T1)) + A3 * ((T - T1) / (T3 - T1))

	return B1 * ((T2 - T) / (T2 - T1)) + B2 * ((T - T1) / (T2 - T1))
end

-- The stop last arrived at by Progress (0-based; 0 before the first).
const function StopIndexAt(Stops: { Stop }, Progress: number): number
	local Low = 0
	local High = #Stops

	while Low < High do
		const Middle = Low + (High - Low) // 2

		if Stops[Middle + 1].Arrive <= Progress then
			Low = Middle + 1
		else
			High = Middle
		end
	end

	return math.max(Low - 1, 0)
end

-- The website path at Progress: held on a stop until it leaves, then on the curve to the next stop, linear in time.
-- The ends are mirrored (the point before the first stop is the first stop mirrored away from the second).
const function StopsPositionAt(Handler: AutoplayHandler, Stops: { Stop }, Progress: number): vector
	const Count = #Stops

	if Count == 0 then
		return vector.zero
	end

	if Progress < Stops[Handler.LastLoadedNote + 1].Arrive then
		Handler.LastLoadedNote = StopIndexAt(Stops, Progress)
	end

	while Handler.LastLoadedNote + 1 < Count and Stops[Handler.LastLoadedNote + 2].Arrive <= Progress do
		Handler.LastLoadedNote += 1
	end

	const Index = Handler.LastLoadedNote + 1
	const Here = Stops[Index]

	if Index == Count or Progress <= Here.Leave then
		return Here.Position
	end

	const Next = Stops[Index + 1]
	const Span = Next.Arrive - Here.Leave

	if Span <= 0 then
		return Next.Position
	end

	const Before = if Index > 1 then Stops[Index - 1].Position else 2 * Here.Position - Next.Position
	const After = if Index + 2 <= Count then Stops[Index + 2].Position else 2 * Next.Position - Here.Position

	return ClampToBounds(Centripetal(Before, Here.Position, Next.Position, After, math.clamp((Progress - Here.Leave) / Span, 0, 1)))
end

-- The points of the notes: a note joins the group of the one before it when it is within 5 ms and within hit reach; the
-- group is averaged, then pulled toward the spline speed and direction.
-- @src scripts/game/AutoplayHandler.cs:initialPreprocess L89-159
const function InitialPreprocess(Notes: { AutoNote }): { AutoNote }
	const PreprocessedData: { AutoNote } = {}
	local Index = 0

	while Index < #Notes do
		const Note = Notes[Index + 1]

		Index += 1

		const Collected = { Note }

		while Index < #Notes do
			const Next = Notes[Index + 1]

			if math.abs(Next.Millisecond - Note.Millisecond) <= 5 and CheckHit(Note, Next.Position, HitReach) then
				table.insert(Collected, Next)
				Index += 1
			else
				break
			end
		end

		local AveragePosition = vector.zero

		for _, CollectedNote in Collected do
			AveragePosition += CollectedNote.Position
		end

		AveragePosition /= #Collected

		if #PreprocessedData > 0 then
			const Previous = PreprocessedData[#PreprocessedData]
			const TimeElapsed = Numbers.F32(math.abs(Previous.Millisecond - Note.Millisecond) / 1000)

			if TimeElapsed > 0 then
				const Speed = Numbers.F32(Math.DistanceTo(Previous.Position, AveragePosition) / Numbers.F32(TimeElapsed * 100))
				const SpeedScale = Numbers.F32(SpeedScaleBase + Numbers.F32(Numbers.F32(Numbers.F32(Sigmoid(Numbers.F32(Speed * 5)) - 0.5) * 2) * SpeedScaleSpan))

				AveragePosition *= SpeedScale
			end

			if Index > 2 and #PreprocessedData >= 2 then
				const PreviousPrevious = PreprocessedData[#PreprocessedData - 1]
				const Direction1 = Normalized(Previous.Position - PreviousPrevious.Position)
				const Direction2 = Normalized(AveragePosition - Previous.Position)
				const TurnWeight = Numbers.F32(1 / Numbers.F32(Numbers.F32(TimeElapsed * 20) + 1))
				const TurnFactor = Numbers.F32(1 + Numbers.F32(MaxFloat(Numbers.F32(-Dot(Direction1, Direction2) - 0.5), 0) * TurnWeight))

				AveragePosition *= TurnFactor
			end
		end

		local NewNote = { Position = AveragePosition, Millisecond = Note.Millisecond }
		const PreviousNote = Notes[math.max(Index - 2, 0) + 1]

		if #Collected == 1 and Note.Position.x == PreviousNote.Position.x and Note.Position.y == PreviousNote.Position.y and #PreprocessedData > 0 then
			NewNote = { Position = PreprocessedData[#PreprocessedData].Position, Millisecond = NewNote.Millisecond }
		end

		table.insert(PreprocessedData, NewNote)
	end

	return PreprocessedData
end

-- Drops a point between two points at the same position, when both neighbours sit there too (a stack).
-- @src scripts/game/AutoplayHandler.cs:compressStacks L161-177
const function CompressStacks(Notes: { AutoNote }): { AutoNote }
	const Compressed: { AutoNote } = {}

	for Index = 0, #Notes - 1 do
		const Note = Notes[Index + 1]

		if Index > 0 and Index + 1 < #Notes and Notes[Index].Position == Note.Position and Notes[Index + 2].Position == Note.Position then
			continue
		end

		table.insert(Compressed, Note)
	end

	return Compressed
end

-- Shifts each compressed point toward the spline through its neighbours, keeping the shift when every note in range is
-- still hit by the cursor path through the new points; appends the last preprocessed point.
-- @src scripts/game/AutoplayHandler.cs:shiftPreprocess L179-226
const function ShiftPreprocess(Handler: AutoplayHandler, OriginalNotes: { AutoNote }, PreprocessedData: { AutoNote }, SecondaryData: { AutoNote })
	const ProcessedData = Handler.ProcessedData
	const SecondaryCount = #SecondaryData

	for Index = 0, SecondaryCount - 2 do
		const Note0 = SecondaryData[math.max(Index - 2, 0) + 1]
		const Note1 = SecondaryData[math.max(Index - 1, 0) + 1]
		const Note2 = SecondaryData[Index + 1]
		const Note3 = SecondaryData[Index + 2]
		const Note4 = SecondaryData[math.min(Index + 2, SecondaryCount - 1) + 1]

		if Note1.Position == Note2.Position or Note2.Position == Note3.Position then
			table.insert(ProcessedData, Note2)

			continue
		end

		const Spline = GetSplinePosition(Note0, Note1, Note3, Note4, Note2.Millisecond)
		const Shift = ClampShift(Spline - Note2.Position, MaxShift)
		const Shifted = { Position = Note2.Position + Shift, Millisecond = Note2.Millisecond }

		-- The last three processed points, the shifted point, then the next three secondary points.
		const Validation: { AutoNote } = {}
		const ProcessedCount = #ProcessedData

		for Processed = math.max(ProcessedCount - 3, 0) + 1, ProcessedCount do
			table.insert(Validation, ProcessedData[Processed])
		end

		table.insert(Validation, Shifted)

		for Secondary = Index + 2, math.min(Index + 4, SecondaryCount) do
			table.insert(Validation, SecondaryData[Secondary])
		end

		local Valid = true
		const Low = Validation[math.min(2, #Validation - 1) + 1].Millisecond
		const High = Validation[math.max(0, #Validation - 3) + 1].Millisecond

		for NoteIndex = LowerBound(OriginalNotes, Low), #OriginalNotes - 1 do
			const Note = OriginalNotes[NoteIndex + 1]

			if Note.Millisecond > High then
				break
			end

			const Hit = CheckHit(Note, GetCursorPositionFromNotes(Validation, Note.Millisecond + 1), HitReach)
				or CheckHit(Note, GetCursorPositionFromNotes(Validation, Note.Millisecond + 5), HitReach)

			if not Hit then
				Valid = false

				break
			end
		end

		table.insert(ProcessedData, if Valid then Shifted else Note2)
	end

	table.insert(ProcessedData, PreprocessedData[#PreprocessedData])
end

-- Upper-case hexadecimal of a digest (Convert.ToHexString).
const function ToHexUpper(Digest: buffer): string
	const Hex: { string } = {}

	for Index = 0, buffer.len(Digest) - 1 do
		table.insert(Hex, string.format("%02X", buffer.readu8(Digest, Index)))
	end

	return table.concat(Hex)
end

-- The cache file of the merged notes: the little-endian bytes of the cache version, HitBoxSize (double), Bounds (two
-- floats), then each note's X, Y (floats) and Millisecond (double), hashed with SHA-256 (BinaryWriter layout).
-- @src scripts/game/AutoplayHandler.cs:getCachePath L387-404
const function GetCachePath(Notes: { AutoNote }): string
	const Key = buffer.create(20 + 16 * #Notes)

	buffer.writei32(Key, 0, CacheVersion)
	buffer.writef64(Key, 4, Constants.HitBoxSize)
	buffer.writef32(Key, 12, Constants.Bounds.x)
	buffer.writef32(Key, 16, Constants.Bounds.y)

	for Index = 1, #Notes do
		const Offset = 20 + (Index - 1) * 16

		buffer.writef32(Key, Offset, Notes[Index].Position.x)
		buffer.writef32(Key, Offset + 4, Notes[Index].Position.y)
		buffer.writef64(Key, Offset + 8, Notes[Index].Millisecond)
	end

	const Folder = FileSystem.Combine(FileSystem.Combine(Constants.UserFolder, "cache"), "autoplay")

	return FileSystem.Combine(Folder, `{ToHexUpper(Sha256.Hash(Key))}.bin`)
end

-- Loads the points of a cache file when it is well formed: the version, a count within the note count, the exact file
-- length, finite values, and strictly increasing times. Any other file is ignored and the points are computed.
-- DEVIATION(platform): the file is read from Util/FileSystem, which is session memory unless the host persists it. A missing
-- file is the IOException upstream catches.
-- @src scripts/game/AutoplayHandler.cs:tryLoadCache L406-440
const function TryLoadCache(Handler: AutoplayHandler, FilePath: string, NoteCount: number): boolean
	if not FileSystem.Exists(FilePath) then
		return false
	end

	const Data = FileSystem.ReadAllBytes(FilePath)
	const Length = buffer.len(Data)

	if Length < 8 or buffer.readi32(Data, 0) ~= CacheVersion then
		return false
	end

	const Count = buffer.readi32(Data, 4)

	if Count <= 0 or Count > NoteCount or Length ~= 8 + Count * 16 then
		return false
	end

	const Cached: { AutoNote } = {}
	local PreviousTime = -math.huge

	for Index = 0, Count - 1 do
		const Offset = 8 + Index * 16
		const X = buffer.readf32(Data, Offset)
		const Y = buffer.readf32(Data, Offset + 4)
		const Time = buffer.readf64(Data, Offset + 8)

		if not math.isfinite(X) or not math.isfinite(Y) or not math.isfinite(Time) or Time <= PreviousTime then
			return false
		end

		table.insert(Cached, { Position = vector.create(X, Y, 0), Millisecond = Time })

		PreviousTime = Time
	end

	for _, Note in Cached do
		table.insert(Handler.ProcessedData, Note)
	end

	return true
end

-- Writes the points as a cache file, in the layout TryLoadCache reads.
-- DEVIATION(platform): written in one step to Util/FileSystem, which cannot leave a half-written file, so upstream's temporary
-- file (a GUID name, moved over the target) is not made. The file system raises no IOException for these writes.
-- @src scripts/game/AutoplayHandler.cs:saveCache L442-473
const function SaveCache(Handler: AutoplayHandler, FilePath: string)
	const ProcessedData = Handler.ProcessedData
	const Data = buffer.create(8 + 16 * #ProcessedData)

	buffer.writei32(Data, 0, CacheVersion)
	buffer.writei32(Data, 4, #ProcessedData)

	for Index = 1, #ProcessedData do
		const Offset = 8 + (Index - 1) * 16

		buffer.writef32(Data, Offset, ProcessedData[Index].Position.x)
		buffer.writef32(Data, Offset + 4, ProcessedData[Index].Position.y)
		buffer.writef64(Data, Offset + 8, ProcessedData[Index].Millisecond)
	end

	FileSystem.CreateDirectory(assert(FileSystem.GetDirectoryName(FilePath)))
	FileSystem.WriteAllBytes(FilePath, Data)
end

-- @src scripts/game/AutoplayHandler.cs:AutoplayHandler L27-49
const function New(Attempt: AutoplayAttempt): AutoplayHandler
	const ProcessedData: { AutoNote } = {}
	const Handler: AutoplayHandler = { ProcessedData = ProcessedData, LastLoadedNote = 0, Stops = nil }
	local Notes: { AutoNote } = {}

	for _, Note in Attempt.Map.Notes do
		table.insert(Notes, { Position = vector.create(Note.X, Note.Y, 0), Millisecond = Note.Millisecond })
	end

	if #Notes == 0 then
		return Handler
	end

	Notes = MergeSimultaneousNotes(Notes)

	if PathStyle == "Website" then
		Handler.Stops = BuildStops(Notes)

		return Handler
	end

	const CachePath = GetCachePath(Notes)

	if TryLoadCache(Handler, CachePath, #Notes) then
		return Handler
	end

	const PreprocessedData = InitialPreprocess(Notes)
	const SecondaryData = CompressStacks(PreprocessedData)

	ShiftPreprocess(Handler, Notes, PreprocessedData, SecondaryData)
	SaveCache(Handler, CachePath)

	return Handler
end

-- @src scripts/game/AutoplayHandler.cs:Reset L51-55
const function Reset(Handler: AutoplayHandler, Progress: number)
	if Handler.Stops then
		Handler.LastLoadedNote = StopIndexAt(Handler.Stops, Progress)

		return
	end

	const ProcessedData = Handler.ProcessedData
	const Index = LowerBound(ProcessedData, Progress)

	Handler.LastLoadedNote = if Index < #ProcessedData and ProcessedData[Index + 1].Millisecond == Progress then Index else math.max(0, Index - 1)
end

-- @src scripts/game/AutoplayHandler.cs:GetCursorPosition L57-87
const function GetCursorPosition(Handler: AutoplayHandler, Progress: number): vector
	if Handler.Stops then
		return StopsPositionAt(Handler, Handler.Stops, Progress)
	end

	const ProcessedData = Handler.ProcessedData

	if #ProcessedData == 0 then
		return vector.zero
	end

	if Progress < ProcessedData[Handler.LastLoadedNote + 1].Millisecond then
		Reset(Handler, Progress)
	end

	while Handler.LastLoadedNote + 1 < #ProcessedData do
		if ProcessedData[Handler.LastLoadedNote + 2].Millisecond > Progress then
			break
		end

		Handler.LastLoadedNote += 1
	end

	return SplinePositionAt(ProcessedData, Handler.LastLoadedNote, Progress)
end

return {
	New = New,
	Reset = Reset,
	GetCursorPosition = GetCursorPosition,
}
