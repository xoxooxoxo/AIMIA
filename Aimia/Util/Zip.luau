--!strict
--!optimize 2

--[[
	Zip archives in buffers, standing in for System.IO.Compression as scripts/map/MapParser.cs uses it: ZipFile.OpenRead,
	ZipArchive.GetEntry, ZipArchiveEntry.Open (Read), ZipFile.ExtractToDirectory, and ZipArchive in Create mode with
	CompressionLevel.NoCompression entries (Create). No @src tag: System.IO.Compression is replaced, not ported.

	Design Notes
		Open parses the end of central directory record and the central directory; local headers are read by Read. Zip64
		and multi-disk archives are refused. Methods 0 (stored) and 8 (deflate, pure Luau inflate: stored, fixed and dynamic
		blocks) are read. Read checks the CRC-32 of every entry it returns.
		Entry names are the stored bytes: UTF-8 when the archive sets the UTF-8 flag, as Luau strings are bytes.
		GetEntry answers the first entry in central directory order with that name (ZipArchive.GetEntry, checked with the oracle).
		Create writes stored entries only (see DEVIATION(zip time) on Create).
		Inflate state is a table of bit reader and output fields; a Huffman table is a lookup over the longest code length.
]]

const FileSystem = require("./FileSystem")

export type Entry = {
	FullName: string,
	Name: string,
	Length: number,
	CompressedLength: number,
	Method: number,
	Flags: number,
	Crc: number,
	LocalOffset: number,
}

export type Archive = {
	Data: buffer,
	Entries: { Entry },
}

type Stream = {
	Input: buffer,
	InputPosition: number,
	InputEnd: number,
	Bits: number,
	BitCount: number,
	Padding: number,
	Output: buffer,
	OutputPosition: number,
}

type Table = {
	Entries: { number },
	Bits: number,
	Mask: number,
}

const EndSignature = 0x06054b50
const CentralSignature = 0x02014b50
const LocalSignature = 0x04034b50
const EndRecordSize = 22
const MaxCommentLength = 65535
const CentralHeaderSize = 46
const LocalHeaderSize = 30
const VersionNeeded = 20
const UtfNameFlag = 0x800
const MethodStored = 0
const MethodDeflate = 8
const DosDateEpoch = 33 -- 1980-01-01 as the DOS date word: ((1980 - 1980) << 9) | (1 << 5) | 1
const EndOfBlock = 256
const LengthCodeCount = 29
const DistanceCodeCount = 30
const MaxLiteralCodes = 286
const MaxDistanceCodes = 30

const LengthBase = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
const LengthExtra = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
const DistanceBase = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
const DistanceExtra = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
const CodeLengthOrder = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- CRC-32 (polynomial 0xEDB88320) table, indexed by byte + 1.
const CrcTable: { number } = table.create(256, 0)

for Index = 0, 255 do
	local Value = Index

	for _ = 1, 8 do
		if bit32.btest(Value, 1) then
			Value = bit32.bxor(0xEDB88320, bit32.rshift(Value, 1))
		else
			Value = bit32.rshift(Value, 1)
		end
	end

	CrcTable[Index + 1] = Value
end

const function Crc32(Data: buffer): number
	local Crc = 0xFFFFFFFF

	for Index = 0, buffer.len(Data) - 1 do
		Crc = bit32.bxor(bit32.rshift(Crc, 8), CrcTable[bit32.band(bit32.bxor(Crc, buffer.readu8(Data, Index)), 0xFF) + 1])
	end

	return bit32.bxor(Crc, 0xFFFFFFFF)
end

-- The name part of a full entry name: the text after the last "/" ("" for a folder entry).
const function NameOf(FullName: string): string
	return string.match(FullName, "([^/]*)$") :: string
end

-- DEVIATION(zip64): Zip64 archives (and more than 65535 entries) are refused with an error; map archives are far below 4 GB.
const function Open(Data: buffer): Archive
	const Length = buffer.len(Data)
	local Record = -1
	local Position = Length - EndRecordSize

	while Position >= 0 and Position >= Length - EndRecordSize - MaxCommentLength do
		if buffer.readu32(Data, Position) == EndSignature then
			Record = Position

			break
		end

		Position -= 1
	end

	if Record < 0 then
		error("End of Central Directory record could not be found.", 0)
	end

	const DiskNumber = buffer.readu16(Data, Record + 4)
	const CentralDisk = buffer.readu16(Data, Record + 6)
	const EntryCount = buffer.readu16(Data, Record + 10)
	const CentralSize = buffer.readu32(Data, Record + 12)
	const CentralOffset = buffer.readu32(Data, Record + 16)

	if DiskNumber ~= 0 or CentralDisk ~= 0 then
		error("Multi-disk zip files are not supported.", 0)
	end

	if EntryCount == 0xFFFF or CentralSize == 0xFFFFFFFF or CentralOffset == 0xFFFFFFFF then
		error("Zip64 archives are not supported.", 0)
	end

	if CentralOffset + CentralSize > Record then
		error("Central Directory corrupt.", 0)
	end

	const Entries: { Entry } = {}
	local Cursor = CentralOffset

	for _ = 1, EntryCount do
		if Cursor + CentralHeaderSize > Length or buffer.readu32(Data, Cursor) ~= CentralSignature then
			error("Central Directory corrupt.", 0)
		end

		const NameLength = buffer.readu16(Data, Cursor + 28)
		const ExtraLength = buffer.readu16(Data, Cursor + 30)
		const CommentLength = buffer.readu16(Data, Cursor + 32)
		const Next = Cursor + CentralHeaderSize + NameLength + ExtraLength + CommentLength

		if Next > Record then
			error("Central Directory corrupt.", 0)
		end

		const FullName = buffer.readstring(Data, Cursor + CentralHeaderSize, NameLength)

		table.insert(Entries, {
			FullName = FullName,
			Name = NameOf(FullName),
			Length = buffer.readu32(Data, Cursor + 24),
			CompressedLength = buffer.readu32(Data, Cursor + 20),
			Method = buffer.readu16(Data, Cursor + 10),
			Flags = buffer.readu16(Data, Cursor + 8),
			Crc = buffer.readu32(Data, Cursor + 16),
			LocalOffset = buffer.readu32(Data, Cursor + 42),
		})

		Cursor = Next
	end

	return {
		Data = Data,
		Entries = Entries,
	}
end

const function GetEntry(Archive: Archive, Name: string): Entry?
	for _, Entry in Archive.Entries do
		if Entry.FullName == Name then
			return Entry
		end
	end

	return nil
end

-- Bit reader (LSB first). Past InputEnd it loads zero bytes and counts them; consuming one of them is an error.
const function Refill(Stream: Stream)
	while Stream.BitCount <= 24 do
		local Byte = 0

		if Stream.InputPosition < Stream.InputEnd then
			Byte = buffer.readu8(Stream.Input, Stream.InputPosition)
			Stream.InputPosition += 1
		else
			Stream.Padding += 1
		end

		Stream.Bits = bit32.bor(Stream.Bits, bit32.lshift(Byte, Stream.BitCount))
		Stream.BitCount += 8
	end
end

const function Consume(Stream: Stream, Count: number)
	Stream.Bits = bit32.rshift(Stream.Bits, Count)
	Stream.BitCount -= Count

	if Stream.Padding * 8 > Stream.BitCount then
		error("Invalid data: the deflate data ends before its last block.", 0)
	end
end

const function GetBits(Stream: Stream, Count: number): number
	if Stream.BitCount < Count then
		Refill(Stream)
	end

	const Value = bit32.band(Stream.Bits, bit32.lshift(1, Count) - 1)

	Consume(Stream, Count)

	return Value
end

const function Reverse(Code: number, Length: number): number
	local Result = 0
	local Rest = Code

	for _ = 1, Length do
		Result = bit32.bor(bit32.lshift(Result, 1), bit32.band(Rest, 1))
		Rest = bit32.rshift(Rest, 1)
	end

	return Result
end

-- Canonical Huffman code (RFC 1951 3.2.2) for Count symbols whose code lengths are Lengths[First + Symbol + 1].
-- Entries[Peek + 1] holds Symbol * 16 + Length for every Bits-bit value Peek that starts with that code (0 if none).
const function BuildTable(Lengths: { number }, First: number, Count: number): Table
	const Counts: { number } = table.create(16, 0)
	local MaxLength = 0

	for Symbol = 0, Count - 1 do
		const Length = Lengths[First + Symbol + 1]

		Counts[Length + 1] += 1

		if Length > MaxLength then
			MaxLength = Length
		end
	end

	Counts[1] = 0

	local Left = 1

	for Length = 1, 15 do
		Left = Left * 2 - Counts[Length + 1]

		if Left < 0 then
			error("Invalid data: over-subscribed Huffman code.", 0)
		end
	end

	const NextCode: { number } = table.create(16, 0)
	local Code = 0

	for Length = 1, 15 do
		Code = (Code + Counts[Length]) * 2
		NextCode[Length + 1] = Code
	end

	const Bits = math.max(MaxLength, 1)
	const Size = bit32.lshift(1, Bits)
	const Entries: { number } = table.create(Size, 0)

	for Symbol = 0, Count - 1 do
		const Length = Lengths[First + Symbol + 1]

		if Length > 0 then
			const Value = NextCode[Length + 1]

			NextCode[Length + 1] = Value + 1

			for Index = Reverse(Value, Length), Size - 1, bit32.lshift(1, Length) do
				Entries[Index + 1] = Symbol * 16 + Length
			end
		end
	end

	return {
		Entries = Entries,
		Bits = Bits,
		Mask = Size - 1,
	}
end

const function Decode(Stream: Stream, Table: Table): number
	if Stream.BitCount < Table.Bits then
		Refill(Stream)
	end

	const Entry = Table.Entries[bit32.band(Stream.Bits, Table.Mask) + 1]

	if Entry == 0 then
		error("Invalid data: invalid Huffman code.", 0)
	end

	Consume(Stream, bit32.band(Entry, 15))

	return Entry // 16
end

const FixedLengths: { number } = table.create(288, 8)

for Symbol = 144, 255 do
	FixedLengths[Symbol + 1] = 9
end

for Symbol = 256, 279 do
	FixedLengths[Symbol + 1] = 7
end

const FixedLiteralTable = BuildTable(FixedLengths, 0, 288)
const FixedDistanceTable = BuildTable(table.create(32, 5), 0, 32)

const function Stored(Stream: Stream)
	-- Drop the rest of the partial byte, then give the whole buffered bytes back to the input (less zero padding).
	GetBits(Stream, Stream.BitCount % 8)
	Stream.InputPosition -= Stream.BitCount // 8 - Stream.Padding
	Stream.Bits = 0
	Stream.BitCount = 0
	Stream.Padding = 0

	if Stream.InputPosition + 4 > Stream.InputEnd then
		error("Invalid data: the deflate data ends before its last block.", 0)
	end

	const Length = buffer.readu16(Stream.Input, Stream.InputPosition)
	const NotLength = buffer.readu16(Stream.Input, Stream.InputPosition + 2)

	if bit32.bxor(Length, NotLength) ~= 0xFFFF then
		error("Invalid data: stored block lengths do not match.", 0)
	end

	Stream.InputPosition += 4

	if Stream.InputPosition + Length > Stream.InputEnd or Stream.OutputPosition + Length > buffer.len(Stream.Output) then
		error("Invalid data: the deflate data is longer than its entry.", 0)
	end

	buffer.copy(Stream.Output, Stream.OutputPosition, Stream.Input, Stream.InputPosition, Length)

	Stream.InputPosition += Length
	Stream.OutputPosition += Length
end

const function Codes(Stream: Stream, Literal: Table, Distance: Table)
	while true do
		const Symbol = Decode(Stream, Literal)

		if Symbol < 256 then
			if Stream.OutputPosition >= buffer.len(Stream.Output) then
				error("Invalid data: the deflate data is longer than its entry.", 0)
			end

			buffer.writeu8(Stream.Output, Stream.OutputPosition, Symbol)
			Stream.OutputPosition += 1
		elseif Symbol == EndOfBlock then
			return
		else
			const LengthCode = Symbol - 257

			if LengthCode >= LengthCodeCount then
				error("Invalid data: invalid length code.", 0)
			end

			const Length = LengthBase[LengthCode + 1] + GetBits(Stream, LengthExtra[LengthCode + 1])
			const DistanceCode = Decode(Stream, Distance)

			if DistanceCode >= DistanceCodeCount then
				error("Invalid data: invalid distance code.", 0)
			end

			const Back = DistanceBase[DistanceCode + 1] + GetBits(Stream, DistanceExtra[DistanceCode + 1])
			const Start = Stream.OutputPosition

			if Back > Start then
				error("Invalid data: distance too far back.", 0)
			end

			if Start + Length > buffer.len(Stream.Output) then
				error("Invalid data: the deflate data is longer than its entry.", 0)
			end

			for Index = 0, Length - 1 do
				buffer.writeu8(Stream.Output, Start + Index, buffer.readu8(Stream.Output, Start + Index - Back))
			end

			Stream.OutputPosition += Length
		end
	end
end

const function DynamicTables(Stream: Stream): (Table, Table)
	const LiteralCount = GetBits(Stream, 5) + 257
	const DistanceCount = GetBits(Stream, 5) + 1
	const CodeCount = GetBits(Stream, 4) + 4

	if LiteralCount > MaxLiteralCodes or DistanceCount > MaxDistanceCodes then
		error("Invalid data: too many length or distance codes.", 0)
	end

	const CodeLengths: { number } = table.create(19, 0)

	for Index = 1, CodeCount do
		CodeLengths[CodeLengthOrder[Index] + 1] = GetBits(Stream, 3)
	end

	const CodeTable = BuildTable(CodeLengths, 0, 19)
	const Total = LiteralCount + DistanceCount
	const Lengths: { number } = table.create(Total, 0)
	local Index = 0

	while Index < Total do
		const Symbol = Decode(Stream, CodeTable)

		if Symbol < 16 then
			Lengths[Index + 1] = Symbol
			Index += 1
		else
			local Value = 0
			local Repeat: number

			if Symbol == 16 then
				if Index == 0 then
					error("Invalid data: a length repeat with no length before it.", 0)
				end

				Value = Lengths[Index]
				Repeat = 3 + GetBits(Stream, 2)
			elseif Symbol == 17 then
				Repeat = 3 + GetBits(Stream, 3)
			else
				Repeat = 11 + GetBits(Stream, 7)
			end

			if Index + Repeat > Total then
				error("Invalid data: code lengths overflow the code count.", 0)
			end

			for _ = 1, Repeat do
				Lengths[Index + 1] = Value
				Index += 1
			end
		end
	end

	if Lengths[EndOfBlock + 1] == 0 then
		error("Invalid data: the literal code has no end-of-block code.", 0)
	end

	return BuildTable(Lengths, 0, LiteralCount), BuildTable(Lengths, LiteralCount, DistanceCount)
end

-- Inflates the raw deflate data at Input[Start, End) into a buffer of Length bytes (the entry's size).
const function Inflate(Input: buffer, Start: number, End: number, Length: number): buffer
	const Output = buffer.create(Length)
	const Stream = {
		Input = Input,
		InputPosition = Start,
		InputEnd = End,
		Bits = 0,
		BitCount = 0,
		Padding = 0,
		Output = Output,
		OutputPosition = 0,
	}

	local Final = false

	while not Final do
		Final = GetBits(Stream, 1) == 1

		const Kind = GetBits(Stream, 2)

		if Kind == 0 then
			Stored(Stream)
		elseif Kind == 1 then
			Codes(Stream, FixedLiteralTable, FixedDistanceTable)
		elseif Kind == 2 then
			const Literal, Distance = DynamicTables(Stream)

			Codes(Stream, Literal, Distance)
		else
			error("Invalid data: invalid block type.", 0)
		end
	end

	if Stream.OutputPosition ~= Length then
		error("Invalid data: the deflate data does not match the entry's size.", 0)
	end

	return Output
end

const function Read(Archive: Archive, Entry: Entry): buffer
	const Data = Archive.Data
	const Local = Entry.LocalOffset

	if Local + LocalHeaderSize > buffer.len(Data) or buffer.readu32(Data, Local) ~= LocalSignature then
		error("A local file header is corrupt.", 0)
	end

	if bit32.btest(Entry.Flags, 1) then
		error("Encrypted zip entries are not supported.", 0)
	end

	const DataStart = Local + LocalHeaderSize + buffer.readu16(Data, Local + 26) + buffer.readu16(Data, Local + 28)
	const DataEnd = DataStart + Entry.CompressedLength

	if DataEnd > buffer.len(Data) then
		error("Unexpected end of zip archive.", 0)
	end

	local Output: buffer

	if Entry.Method == MethodStored then
		if Entry.CompressedLength ~= Entry.Length then
			error("Invalid data: stored entry sizes differ.", 0)
		end

		Output = buffer.create(Entry.Length)

		buffer.copy(Output, 0, Data, DataStart, Entry.Length)
	elseif Entry.Method == MethodDeflate then
		Output = Inflate(Data, DataStart, DataEnd, Entry.Length)
	else
		error("The archive entry was compressed using an unsupported compression method.", 0)
	end

	if Crc32(Output) ~= Entry.Crc then
		error(`Invalid data: CRC-32 mismatch in {Entry.FullName}.`, 0)
	end

	return Output
end

const function ExtractToDirectory(Data: buffer, Folder: string)
	const Archive = Open(Data)

	FileSystem.CreateDirectory(Folder)

	for _, Entry in Archive.Entries do
		if string.sub(Entry.FullName, 1, 1) == "/" then
			error("Extracting Zip entry would have resulted in a file outside the specified destination directory.", 0)
		end

		for Segment in string.gmatch(Entry.FullName, "[^/]+") do
			if Segment == ".." then
				error("Extracting Zip entry would have resulted in a file outside the specified destination directory.", 0)
			end
		end

		const Target = FileSystem.Combine(Folder, Entry.FullName)

		if string.sub(Entry.FullName, -1) == "/" then
			FileSystem.CreateDirectory(Target)
		else
			const Parent = FileSystem.GetDirectoryName(Target)

			if Parent then
				FileSystem.CreateDirectory(Parent)
			end

			if FileSystem.Exists(Target) then
				error(`The file '{Target}' already exists.`, 0)
			end

			FileSystem.WriteAllBytes(Target, Read(Archive, Entry))
		end
	end
end

-- DEVIATION(zip time): every entry is stamped 1980-01-01 00:00:00 (the zip epoch), not the current time, so the same entries give the same bytes.
const function Create(Entries: { { Name: string, Data: buffer } }): buffer
	if #Entries > 0xFFFF then
		error("Too many entries for a zip archive.", 0)
	end

	local Size = EndRecordSize

	for _, Entry in Entries do
		Size += LocalHeaderSize + #Entry.Name + buffer.len(Entry.Data) + CentralHeaderSize + #Entry.Name
	end

	const Archive = buffer.create(Size)
	const Offsets: { number } = {}
	const Crcs: { number } = {}
	local Cursor = 0

	for Index, Entry in Entries do
		const NameLength = #Entry.Name
		const DataLength = buffer.len(Entry.Data)
		const Crc = Crc32(Entry.Data)
		const Flags = if string.find(Entry.Name, "[\128-\255]") then UtfNameFlag else 0

		Offsets[Index] = Cursor
		Crcs[Index] = Crc

		buffer.writeu32(Archive, Cursor, LocalSignature)
		buffer.writeu16(Archive, Cursor + 4, VersionNeeded)
		buffer.writeu16(Archive, Cursor + 6, Flags)
		buffer.writeu16(Archive, Cursor + 8, MethodStored)
		buffer.writeu16(Archive, Cursor + 12, DosDateEpoch)
		buffer.writeu32(Archive, Cursor + 14, Crc)
		buffer.writeu32(Archive, Cursor + 18, DataLength)
		buffer.writeu32(Archive, Cursor + 22, DataLength)
		buffer.writeu16(Archive, Cursor + 26, NameLength)
		buffer.writestring(Archive, Cursor + LocalHeaderSize, Entry.Name)
		buffer.copy(Archive, Cursor + LocalHeaderSize + NameLength, Entry.Data)

		Cursor += LocalHeaderSize + NameLength + DataLength
	end

	const CentralStart = Cursor

	for Index, Entry in Entries do
		const NameLength = #Entry.Name
		const Flags = if string.find(Entry.Name, "[\128-\255]") then UtfNameFlag else 0

		buffer.writeu32(Archive, Cursor, CentralSignature)
		buffer.writeu16(Archive, Cursor + 4, VersionNeeded)
		buffer.writeu16(Archive, Cursor + 6, VersionNeeded)
		buffer.writeu16(Archive, Cursor + 8, Flags)
		buffer.writeu16(Archive, Cursor + 10, MethodStored)
		buffer.writeu16(Archive, Cursor + 12, 0)
		buffer.writeu16(Archive, Cursor + 14, DosDateEpoch)
		buffer.writeu32(Archive, Cursor + 16, Crcs[Index])
		buffer.writeu32(Archive, Cursor + 20, buffer.len(Entry.Data))
		buffer.writeu32(Archive, Cursor + 24, buffer.len(Entry.Data))
		buffer.writeu16(Archive, Cursor + 28, NameLength)
		buffer.writeu32(Archive, Cursor + 42, Offsets[Index])
		buffer.writestring(Archive, Cursor + CentralHeaderSize, Entry.Name)

		Cursor += CentralHeaderSize + NameLength
	end

	buffer.writeu32(Archive, Cursor, EndSignature)
	buffer.writeu16(Archive, Cursor + 8, #Entries)
	buffer.writeu16(Archive, Cursor + 10, #Entries)
	buffer.writeu32(Archive, Cursor + 12, Cursor - CentralStart)
	buffer.writeu32(Archive, Cursor + 16, CentralStart)

	return Archive
end

return {
	Open = Open,
	GetEntry = GetEntry,
	Read = Read,
	ExtractToDirectory = ExtractToDirectory,
	Create = Create,
	Inflate = Inflate,
}
