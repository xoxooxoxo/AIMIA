--!strict
--!optimize 2

--[[
	Leaderboard.cs: the personal bests of one map, a file under user/pbs: a count, the scores (best first, at most 8), and
	the SHA-256 of everything before it. Also the Score it holds (Leaderboard.Score) and its comparer.

	Representation
		A leaderboard is a table from Empty (`new()`), FromBuffer (the buffer constructor) or New (the path constructor).
		Scores is the ordered list; ScoreCount is the count the file stores. Score.Modifiers is Dictionary<string, bool> as
		ordered pairs { Key, Value }, sorted by key (Save writes them sorted, as Godot's Stringify does). Value is a ulong: a
		number, exact below 2^53.

	Design Notes
		Save writes the file through FileSystem (the in-memory user folder); the digest is of the content, appended.
		Corrupt input is reset and rewritten, as the source does: a read that fails (a short file, a count past the data, a
		modifier that is not a boolean) and a digest that does not match.
		Upstream quirk kept: New keeps the default pbs path (user/pbs/<MapID>), not its path argument: the source's
		`this = new(...)` replaces the struct, so the path it set is lost and Save writes to the pbs path.
		DEVIATION(json): a JSON object is an unordered table here, so a modifier list is read in sorted key order; the source
		keeps the file's key order, which is sorted for every file Save writes (only a hand-edited file differs).
		Path is nil only for Empty; Save of it is an error.
]]

const Constants = require("../Constants")
const FileParser = require("../Util/FileParser")
const FileSystem = require("../Util/FileSystem")
const Json = require("../Godot/Json")
const Logger = require("../Util/Logger")
const Sha256 = require("../Util/Sha256")
const Sort = require("../Util/Sort")

export type ModifierEntry = {
	Key: string,
	Value: boolean,
}

export type Score = {
	AttemptID: string,
	Player: string,
	Qualifies: boolean,
	Value: number,
	Accuracy: number,
	Time: number,
	Progress: number,
	MapLength: number,
	Speed: number,
	Modifiers: { ModifierEntry },
}

export type Leaderboard = {
	MapID: string,
	Valid: boolean,
	Path: string?,
	ScoreCount: number,
	Scores: { Score },
}

const MaxScores = 8
const DigestSize = 32
const TwoPow32 = 4294967296

-- @src scripts/map/Leaderboard.cs:Leaderboard L9-16
const function Empty(): Leaderboard
	return {
		MapID = "",
		Valid = false,
		Path = nil,
		ScoreCount = 0,
		Scores = {},
	}
end

-- @src scripts/map/Leaderboard.cs:Score L187-210
const function NewScore(
	AttemptID: string,
	Player: string,
	Qualifies: boolean,
	Value: number,
	Accuracy: number,
	Time: number,
	Progress: number,
	MapLength: number,
	Speed: number,
	Modifiers: { ModifierEntry }
): Score
	return {
		AttemptID = AttemptID,
		Player = Player,
		Qualifies = Qualifies,
		Value = Value,
		Accuracy = Accuracy,
		Time = Time,
		Progress = Progress,
		MapLength = MapLength,
		Speed = Speed,
		Modifiers = Modifiers,
	}
end

-- ScoreComparer.Compare: b.Value.CompareTo(a.Value), so the higher value sorts first.
-- @src scripts/map/Leaderboard.cs:ScoreComparer L215-221
const function CompareScores(First: Score, Second: Score): number
	if Second.Value < First.Value then
		return -1
	elseif Second.Value > First.Value then
		return 1
	end

	return 0
end

-- The modifiers of a stored score: the JSON object's entries, keys sorted (the order Save wrote them in).
-- @src scripts/map/Leaderboard.cs:Score L175-184
const function ParseModifiers(Text: string): { ModifierEntry }
	const Parsed = Json.Parse(Text)

	if type(Parsed) ~= "table" then
		error("Leaderboard modifiers are not an object", 0)
	end

	const Object = Parsed :: { [string]: unknown }
	const Keys: { string } = {}

	for Key, Value in Object do
		if type(Value) ~= "boolean" then
			error(`Leaderboard modifier {Key} is not a boolean`, 0)
		end

		table.insert(Keys, Key)
	end

	table.sort(Keys)

	const Entries: { ModifierEntry } = {}

	for _, Key in Keys do
		table.insert(Entries, {
			Key = Key,
			Value = Object[Key] :: boolean,
		})
	end

	return Entries
end

-- The Score(byte[]) constructor: one entry's payload, without its length prefix.
-- @src scripts/map/Leaderboard.cs:Score L154-185
const function ParseScore(Data: buffer): Score
	const Parser = FileParser.FromBuffer(Data)
	const AttemptIdLength = FileParser.GetUInt32(Parser)
	const AttemptID = FileParser.GetString(Parser, AttemptIdLength)
	const PlayerLength = FileParser.GetUInt32(Parser)
	const Player = FileParser.GetString(Parser, PlayerLength)
	const Qualifies = FileParser.GetBool(Parser)
	const Value = FileParser.GetUInt64(Parser)
	const Accuracy = FileParser.GetDouble(Parser)
	const Time = FileParser.GetDouble(Parser)
	const Progress = FileParser.GetDouble(Parser)
	const MapLength = FileParser.GetDouble(Parser)
	const Speed = FileParser.GetDouble(Parser)
	const ModifiersLength = FileParser.GetUInt32(Parser)
	const Modifiers = ParseModifiers(FileParser.GetString(Parser, ModifiersLength))

	return NewScore(AttemptID, Player, Qualifies, Value, Accuracy, Time, Progress, MapLength, Speed, Modifiers)
end

-- @src scripts/map/Leaderboard.cs:Add L68-79
const function Add(Board: Leaderboard, Entry: Score)
	table.insert(Board.Scores, Entry)
	Sort(Board.Scores, CompareScores)

	for Index = #Board.Scores, MaxScores + 1, -1 do
		table.remove(Board.Scores, Index)
	end

	Board.ScoreCount = #Board.Scores
end

-- The modifiers as the JSON Save writes: the keys sorted, a later duplicate key replacing an earlier one (a Dictionary).
const function ModifiersJson(Modifiers: { ModifierEntry }): string
	const Values: { [string]: boolean } = {}

	for _, Entry in Modifiers do
		Values[Entry.Key] = Entry.Value
	end

	const Keys: { string } = {}

	for Key in Values do
		table.insert(Keys, Key)
	end

	table.sort(Keys)

	const Parts: { string } = {}

	for _, Key in Keys do
		table.insert(Parts, `{Json.Stringify(Key)}:{if Values[Key] then "true" else "false"}`)
	end

	return `\{{table.concat(Parts, ",")}\}`
end

-- One entry's payload (Save's bytes after the length prefix): the ids, the flags and numbers, then the modifiers JSON.
-- @src scripts/map/Leaderboard.cs:Save L81-131
const function ScorePayload(Entry: Score): buffer
	const AttemptIdBytes = buffer.fromstring(Entry.AttemptID)
	const PlayerBytes = buffer.fromstring(Entry.Player)
	const ModifiersBytes = buffer.fromstring(ModifiersJson(Entry.Modifiers))
	const Size = 4 + buffer.len(AttemptIdBytes) + 4 + buffer.len(PlayerBytes) + 1 + 8 + 5 * 8 + 4 + buffer.len(ModifiersBytes)
	const Payload = buffer.create(Size)
	local Offset = 0

	buffer.writeu32(Payload, Offset, buffer.len(AttemptIdBytes))
	Offset += 4
	buffer.copy(Payload, Offset, AttemptIdBytes)
	Offset += buffer.len(AttemptIdBytes)
	buffer.writeu32(Payload, Offset, buffer.len(PlayerBytes))
	Offset += 4
	buffer.copy(Payload, Offset, PlayerBytes)
	Offset += buffer.len(PlayerBytes)
	buffer.writeu8(Payload, Offset, if Entry.Qualifies then 1 else 0)
	Offset += 1

	-- The ulong Value: the low word, then the high word (exact below 2^53).
	buffer.writeu32(Payload, Offset, Entry.Value % TwoPow32)
	buffer.writeu32(Payload, Offset + 4, Entry.Value // TwoPow32)
	Offset += 8

	buffer.writef64(Payload, Offset, Entry.Accuracy)
	buffer.writef64(Payload, Offset + 8, Entry.Time)
	buffer.writef64(Payload, Offset + 16, Entry.Progress)
	buffer.writef64(Payload, Offset + 24, Entry.MapLength)
	buffer.writef64(Payload, Offset + 32, Entry.Speed)
	Offset += 40

	buffer.writeu32(Payload, Offset, buffer.len(ModifiersBytes))
	Offset += 4
	buffer.copy(Payload, Offset, ModifiersBytes)

	return Payload
end

-- The file's content: the count, then each entry as a length and its payload. The digest is not included.
const function Content(Board: Leaderboard): buffer
	const Payloads: { buffer } = {}
	local Size = 4

	for _, Entry in Board.Scores do
		const Payload = ScorePayload(Entry)

		table.insert(Payloads, Payload)
		Size += 4 + buffer.len(Payload)
	end

	const Bytes = buffer.create(Size)

	buffer.writeu32(Bytes, 0, Board.ScoreCount)

	local Offset = 4

	for _, Payload in Payloads do
		buffer.writeu32(Bytes, Offset, buffer.len(Payload))
		buffer.copy(Bytes, Offset + 4, Payload)
		Offset += 4 + buffer.len(Payload)
	end

	return Bytes
end

-- The whole file Save writes: the content, then its SHA-256.
-- @src scripts/map/Leaderboard.cs:Save L81-131
const function Encode(Board: Leaderboard): buffer
	const Bytes = Content(Board)
	const Digest = Sha256.Hash(Bytes)
	const File = buffer.create(buffer.len(Bytes) + DigestSize)

	buffer.copy(File, 0, Bytes)
	buffer.copy(File, buffer.len(Bytes), Digest)

	return File
end

-- @src scripts/map/Leaderboard.cs:Save L81-131
const function Save(Board: Leaderboard)
	const Path = Board.Path

	if not Path then
		error("Leaderboard has no path to save to", 2)
	end

	FileSystem.WriteAllBytes(Path, Encode(Board))
end

-- @src scripts/map/Leaderboard.cs:Reset L133-139
const function Reset(Board: Leaderboard)
	Board.Valid = false
	Board.ScoreCount = 0
	Board.Scores = {}

	Save(Board)
end

-- The buffer constructor's try block: the count and the entries, answering the content (for the digest check).
const function ReadScores(Board: Leaderboard, Parser: FileParser.FileParser): buffer
	const Content = FileParser.Get(Parser, Parser.Length - DigestSize)

	FileParser.Seek(Parser, 0)

	const Count = FileParser.GetUInt32(Parser)

	Board.ScoreCount = Count
	Board.Scores = {}

	for _ = 1, Count do
		Add(Board, ParseScore(FileParser.Get(Parser, FileParser.GetUInt32(Parser))))
	end

	Board.Valid = true

	return Content
end

-- @src scripts/map/Leaderboard.cs:Leaderboard L18-54
const function FromBuffer(MapID: string, Data: buffer): Leaderboard
	const Board = Empty()

	Board.MapID = MapID
	Board.Path = `{Constants.UserFolder}/pbs/{MapID}`

	const Parser = FileParser.FromBuffer(Data)
	const Success, Result = pcall(ReadScores, Board, Parser)

	if not Success then
		Logger.ErrorException(Result)
		Reset(Board)
	elseif not Sha256.Equal(Sha256.Hash(Result), FileParser.Get(Parser, DigestSize)) then
		Logger.Log("Leaderboard file corrupted; invalid leaderboard hash")
		Reset(Board)
	end

	return Board
end

-- @src scripts/map/Leaderboard.cs:Leaderboard L56-66
const function New(MapID: string, Path: string): Leaderboard
	if not FileSystem.Exists(Path) then
		error(Logger.Error(`No leaderboard file found at path {Path}`), 0)
	end

	return FromBuffer(MapID, FileSystem.ReadAllBytes(Path))
end

return {
	Empty = Empty,
	NewScore = NewScore,
	CompareScores = CompareScores,
	ParseScore = ParseScore,
	Add = Add,
	Encode = Encode,
	Save = Save,
	Reset = Reset,
	FromBuffer = FromBuffer,
	New = New,
}
