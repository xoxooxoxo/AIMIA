--!strict
--!optimize 2

--[[
	Little-endian reader over a buffer, as scripts/util/FileParser.cs. Pointer is a zero-based byte offset, as buffer offsets are.

	Design Notes
		FromPath reads a FileSystem file; a missing file gives an empty buffer (Godot FileAccess.Open returns null there).
		GetString decodes UTF-8 as Encoding.UTF8.GetString does: each maximal ill-formed subpart becomes U+FFFD.
		GetLine decodes one byte at a time, so every byte >= 0x80 becomes U+FFFD, as the source does.
		GetUInt64 answers a number: exact below 2^53, otherwise the nearest double (C# (double)ulong).
		Get answers a copy. Only the checked reads (Get, GetBool, GetFloat, ..., GetUInt64) check the bounds.
]]

const FileSystem = require("./FileSystem")
const Numbers = require("../Numbers")

export type FileParser = {
	Buffer: buffer,
	Pointer: number,
	Length: number,
}

-- @src scripts/util/FileParser.cs:FileParser L30-35
const function FromBuffer(Data: buffer?): FileParser
	const Bytes = Data or buffer.create(0)

	return {
		Buffer = Bytes,
		Pointer = 0,
		Length = buffer.len(Bytes),
	}
end

-- @src scripts/util/FileParser.cs:checkBounds L37-43
const function CheckBounds(Parser: FileParser, Amount: number)
	if Parser.Pointer + Amount > Parser.Length then
		error(`Attempted to read {Amount} bytes beyond stream length of {Parser.Length}.`, 0)
	end
end

-- The size of the well-formed UTF-8 sequence at Position, or, when it is ill-formed, of its maximal subpart (answered
-- with false). Bytes before Finish only.
const function SequenceAt(Data: buffer, Position: number, Finish: number): (number, boolean)
	const Lead = buffer.readu8(Data, Position)

	if Lead < 0x80 then
		return 1, true
	end

	local Trailing = 0
	local Low = 0x80
	local High = 0xBF

	if Lead >= 0xC2 and Lead <= 0xDF then
		Trailing = 1
	elseif Lead >= 0xE0 and Lead <= 0xEF then
		Trailing = 2

		if Lead == 0xE0 then
			Low = 0xA0
		elseif Lead == 0xED then
			High = 0x9F
		end
	elseif Lead >= 0xF0 and Lead <= 0xF4 then
		Trailing = 3

		if Lead == 0xF0 then
			Low = 0x90
		elseif Lead == 0xF4 then
			High = 0x8F
		end
	else
		return 1, false
	end

	for Offset = 1, Trailing do
		if Position + Offset >= Finish then
			return Offset, false
		end

		const Byte = buffer.readu8(Data, Position + Offset)

		if Byte < Low or Byte > High then
			return Offset, false
		end

		Low = 0x80
		High = 0xBF
	end

	return Trailing + 1, true
end

-- Encoding.UTF8.GetString over Count bytes from Start.
const function DecodeUtf8(Data: buffer, Start: number, Count: number): string
	const Finish = Start + Count
	const Parts: { string } = {}
	local Position = Start

	while Position < Finish do
		const Size, Valid = SequenceAt(Data, Position, Finish)

		if Valid then
			table.insert(Parts, buffer.readstring(Data, Position, Size))
		else
			table.insert(Parts, "\u{FFFD}")
		end

		Position += Size
	end

	return table.concat(Parts)
end

-- @src scripts/util/FileParser.cs:FileParser L11-28
const function FromPath(Path: string): FileParser
	if not FileSystem.Exists(Path) then
		return {
			Buffer = buffer.create(0),
			Pointer = 0,
			Length = 0,
		}
	end

	return FromBuffer(FileSystem.ReadAllBytes(Path))
end

-- @src scripts/util/FileParser.cs:Get L45-50
const function Get(Parser: FileParser, Count: number): buffer
	CheckBounds(Parser, Count)

	Parser.Pointer += Count

	const Copy = buffer.create(Count)

	buffer.copy(Copy, 0, Parser.Buffer, Parser.Pointer - Count, Count)

	return Copy
end

-- @src scripts/util/FileParser.cs:Skip L52-55
const function Skip(Parser: FileParser, Count: number)
	Parser.Pointer += Count
end

-- @src scripts/util/FileParser.cs:Seek L57-60
const function Seek(Parser: FileParser, Position: number)
	Parser.Pointer = Position
end

-- DEVIATION(error): no bounds check, as the source; a count past the buffer raises Luau's buffer error, not .NET's ArgumentOutOfRangeException.
-- @src scripts/util/FileParser.cs:GetString L62-66
const function GetString(Parser: FileParser, Count: number): string
	Parser.Pointer += Count

	return DecodeUtf8(Parser.Buffer, Parser.Pointer - Count, Count)
end

-- @src scripts/util/FileParser.cs:GetLine L68-84
const function GetLine(Parser: FileParser): string
	const Parts: { string } = {}

	while Parser.Pointer < Parser.Length do
		Parser.Pointer += 1

		const Byte = buffer.readu8(Parser.Buffer, Parser.Pointer - 1)

		if Byte == 10 then
			break
		end

		table.insert(Parts, if Byte < 0x80 then string.char(Byte) else "\u{FFFD}")
	end

	return table.concat(Parts)
end

-- @src scripts/util/FileParser.cs:GetBool L86-91
const function GetBool(Parser: FileParser): boolean
	CheckBounds(Parser, 1)

	Parser.Pointer += 1

	return buffer.readu8(Parser.Buffer, Parser.Pointer - 1) ~= 0
end

-- @src scripts/util/FileParser.cs:GetFloat L93-98
const function GetFloat(Parser: FileParser): number
	CheckBounds(Parser, 4)

	Parser.Pointer += 4

	return buffer.readf32(Parser.Buffer, Parser.Pointer - 4)
end

-- @src scripts/util/FileParser.cs:GetDouble L100-105
const function GetDouble(Parser: FileParser): number
	CheckBounds(Parser, 8)

	Parser.Pointer += 8

	return buffer.readf64(Parser.Buffer, Parser.Pointer - 8)
end

-- @src scripts/util/FileParser.cs:GetUInt8 L107-110
const function GetUInt8(Parser: FileParser): number
	return buffer.readu8(Get(Parser, 1), 0)
end

-- @src scripts/util/FileParser.cs:GetUInt16 L112-117
const function GetUInt16(Parser: FileParser): number
	CheckBounds(Parser, 2)

	Parser.Pointer += 2

	return buffer.readu16(Parser.Buffer, Parser.Pointer - 2)
end

-- @src scripts/util/FileParser.cs:GetUInt32 L119-124
const function GetUInt32(Parser: FileParser): number
	CheckBounds(Parser, 4)

	Parser.Pointer += 4

	return buffer.readu32(Parser.Buffer, Parser.Pointer - 4)
end

-- DEVIATION(int64): answers a number, exact below 2^53 and the nearest double above (C# (double)ulong), not the ulong.
-- @src scripts/util/FileParser.cs:GetUInt64 L126-131
const function GetUInt64(Parser: FileParser): number
	CheckBounds(Parser, 8)

	Parser.Pointer += 8

	const Start = Parser.Pointer - 8
	const Low = buffer.readu32(Parser.Buffer, Start)
	const High = buffer.readu32(Parser.Buffer, Start + 4)

	return Numbers.Uint64ToNumber(High, Low)
end

return {
	FromPath = FromPath,
	FromBuffer = FromBuffer,
	Get = Get,
	Skip = Skip,
	Seek = Seek,
	GetString = GetString,
	GetLine = GetLine,
	GetBool = GetBool,
	GetFloat = GetFloat,
	GetDouble = GetDouble,
	GetUInt8 = GetUInt8,
	GetUInt16 = GetUInt16,
	GetUInt32 = GetUInt32,
	GetUInt64 = GetUInt64,
}
