--!strict
--!optimize 2

--[[
	objects.phxmo decoding: MapParser.DecodePHXMO and DecodePHXMOFile (scripts/map/MapParser.cs L786-823). It lives here, not in
	MapParser, because Map reads its notes lazily and MapParser requires Map: this module needs only Note and FileParser.

	Design Notes
		The file is a version word (ignored), a note count, then per note a uint32 Millisecond, a quantum flag, and float32 X and
		Y, or one byte each for X - 1 and Y - 1. Notes keep the file's order and Index (no sort, unlike the sspm readers).
		A missing file decodes as an empty buffer, which fails on the first read, as the source's FileParser does.
]]

const FileParser = require("../../Util/FileParser")
const Note = require("./Note")
const Numbers = require("../../Numbers")

-- @src scripts/map/MapParser.cs:DecodePHXMO L793-823
const function Decode(Data: buffer): { Note.Note }
	const Parser = FileParser.FromBuffer(Data)

	FileParser.GetUInt32(Parser)

	const NoteCount = FileParser.GetUInt32(Parser)
	const Notes: { Note.Note } = {}

	for Index = 0, NoteCount - 1 do
		const Millisecond = Numbers.Signed(FileParser.GetUInt32(Parser))
		const IsNoteQuantum = FileParser.GetBool(Parser)

		local X: number
		local Y: number

		if IsNoteQuantum then
			X = FileParser.GetFloat(Parser)
			Y = FileParser.GetFloat(Parser)
		else
			X = buffer.readu8(FileParser.Get(Parser, 1), 0) - 1
			Y = buffer.readu8(FileParser.Get(Parser, 1), 0) - 1
		end

		Notes[Index + 1] = Note.New(Index, Millisecond, X, Y)
	end

	return Notes
end

-- @src scripts/map/MapParser.cs:DecodePHXMO L786-791
const function DecodeFile(Path: string): { Note.Note }
	return Decode(FileParser.FromPath(Path).Buffer)
end

return {
	Decode = Decode,
	DecodeFile = DecodeFile,
}
