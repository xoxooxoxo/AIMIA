--!strict
--!optimize 2

--[[
	MapParser.cs: decodes the map formats (phxm folders and archives, sspm v1 and v2, SSMapV1 text, rhm archives) into Map
	tables, encodes maps into the phxm folder layout, and runs the bulk import. The Node is dropped (its only job was to set
	Instance): the three signals are fields of this module.

	Design Notes
		DEVIATION(concurrency): BulkImport is a sequential loop (Parallel.ForEach and Interlocked are not needed), so the maps
		arrive in file order. Callable.From(...).CallDeferred() fires its signal at once, in order: a listener error raises out
		of BulkImport instead of surfacing later on the main thread.
		SoundManager.UpdateJukeboxQueue is Hooks.UpdateJukeboxQueue (nil does nothing).
		Benchmarks use os.clock(); the log text is kept.
		Each parser's catch (toast, log, rethrow) is Rethrow. Nested parsers toast twice, as the source does.
		DEVIATION(time): LastModifiedMetadata and LastModifiedNotes are "O"-style local times with a zero fraction, because
		FileSystem keeps whole seconds.
		DEVIATION(zip read chunks): CopyCapacity reproduces the MemoryStream of getZipEntryBuffer for entries that .NET reads
		in full 131072-byte chunks (stored entries, and deflated entries that inflate in full chunks). A deflated entry that
		.NET reads in 8 KB input steps can get a different buffer length.
		DEVIATION(conversion): JSON values are read as the Luau type they hold; Godot's Variant conversions of other types are
		not reproduced. A missing ArtistLink or ArtistPlatform is "" (Godot's Nil-to-string is unverified).
		DEVIATION(error): SSPMBytes with version 2 has no folder path, which the source stores as null; here it raises. SSPM
		(byte[]) has no caller upstream.
		Registers MapCache.ParserHooks (Decode, Encode) on load. objects.phxmo decoding is Objects/PHXMO (Map reads it).
]]

const Constants = require("../Constants")
const DotnetString = require("../Dotnet/String")
const FileParser = require("../Util/FileParser")
const FileSystem = require("../Util/FileSystem")
const GodotString = require("../Godot/String")
const Json = require("../Godot/Json")
const Logger = require("../Util/Logger")
const Map = require("./Map")
const MapCache = require("./MapCache")
const MapUtil = require("./MapUtil")
const Md5 = require("../Util/Md5")
const Misc = require("../Util/Misc")
const Note = require("./Objects/Note")
const PHXMO = require("./Objects/PHXMO")
const Numbers = require("../Numbers")
const Signal = require("../Util/Signal")
const Sort = require("../Util/Sort")
const ToastNotification = require("../Util/Notify")
const Zip = require("../Util/Zip")

export type Hooks = {
	UpdateJukeboxQueue: (() -> ())?,
}

const MapsImportStarted = Signal.New()
const MapsImportFinished = Signal.New()
const MapImported = Signal.New()

const Hooks: Hooks = {}

const MemoryStreamInitialCapacity = 256
const CopyBufferSize = 131072
const TwoPowerWord = 4294967296

-- The catch of every parser: a toast, the log, then the same error again.
const function Rethrow(Message: string, Exception: unknown): never
	ToastNotification.Notify(Message, 2)
	Logger.ErrorException(Exception)
	error(Exception, 0)
end

-- (int) of a 64-bit length or offset read from a file: the low word, signed.
const function Int32FromUInt64(Value: number): number
	return Numbers.Signed(Value % TwoPowerWord)
end

-- A JSON value read as a string. A null answers nil (Json.Null is the JSON null); other types are not converted.
const function OptionalText(Value: unknown): string?
	if Value == nil or Value == Json.Null then
		return nil
	end

	return Value :: string
end

-- Godot's Dictionary indexer: a missing key throws.
const function Field(Dictionary: { [string]: unknown }, Key: string): unknown
	const Value = Dictionary[Key]

	if Value == nil then
		error(`The given key '{Key}' was not present in the dictionary.`, 0)
	end

	return Value
end

-- Godot's JSON reads a NUL byte as the end of the text, so the zero padding of a GetBuffer() copy is ignored.
const function JsonText(Data: buffer): string
	return string.match(buffer.tostring(Data), "^[^\0]*") or ""
end

-- The MemoryStream capacity after CopyTo of Length bytes (getZipEntryBuffer L901-906): .NET 10 CopyTo reads 131072-byte
-- chunks, and a write past the capacity grows it to the larger of the end, 256 and twice the capacity.
const function CopyCapacity(Length: number): number
	local Capacity = 0
	local Position = 0
	local Remaining = Length

	while Remaining > 0 do
		const Chunk = math.min(CopyBufferSize, Remaining)
		const Finish = Position + Chunk

		if Finish > Capacity then
			local NewCapacity = math.max(Finish, MemoryStreamInitialCapacity)

			if NewCapacity < 2 * Capacity then
				NewCapacity = 2 * Capacity
			end

			Capacity = NewCapacity
		end

		Position = Finish
		Remaining -= Chunk
	end

	return Capacity
end

-- @src scripts/map/MapParser.cs:getZipEntryBuffer L897-910
const function GetZipEntryBuffer(Archive: Zip.Archive, EntryName: string): buffer
	const Found = Zip.GetEntry(Archive, EntryName)

	if not Found then
		error(`ZipArchiveEntry {EntryName} is missing!`, 0)
	end

	const Data = Zip.Read(Archive, Found)
	const Result = buffer.create(CopyCapacity(buffer.len(Data)))

	buffer.copy(Result, 0, Data)

	return Result
end

-- DateTime.ToString("O") of a local time (File.GetLastWriteTime, MapParser.cs L240-241), with the fraction zero.
const function FormatLastWriteTime(Seconds: number): string
	const Offset = os.date("%z", Seconds)

	return `{os.date("%Y-%m-%dT%H:%M:%S", Seconds)}.0000000{string.sub(Offset, 1, 3)}:{string.sub(Offset, 4, 5)}`
end

-- The quantum flag of Encode and ExportEncode (MapParser.cs L114 and L187): a coordinate that is not a whole number in [-1, 1].
const function IsQuantum(Current: Note.Note): boolean
	return Numbers.TruncInt32(Current.X) ~= Current.X
		or Numbers.TruncInt32(Current.Y) ~= Current.Y
		or Current.X < -1
		or Current.X > 1
		or Current.Y < -1
		or Current.Y > 1
end

-- The objects.phxmo bytes of Encode (L183-212): version 12, the note count, each note as uint32 Millisecond, a quantum flag,
-- then float32 X and Y, or one byte each for X + 1 and Y + 1; eleven zero counts end the file (buffers are zero-filled).
const function ObjectsBuffer(Notes: { Note.Note }): buffer
	local Size = 8 + 11 * 4

	for _, Current in Notes do
		Size += 5 + if IsQuantum(Current) then 8 else 2
	end

	const Data = buffer.create(Size)

	buffer.writeu32(Data, 0, 12)
	buffer.writeu32(Data, 4, #Notes)

	local Cursor = 8

	for _, Current in Notes do
		const Quantum = IsQuantum(Current)

		buffer.writeu32(Data, Cursor, Numbers.Uint32(Current.Millisecond))
		buffer.writeu8(Data, Cursor + 4, if Quantum then 1 else 0)

		if Quantum then
			buffer.writef32(Data, Cursor + 5, Current.X)
			buffer.writef32(Data, Cursor + 9, Current.Y)

			Cursor += 13
		else
			buffer.writeu8(Data, Cursor + 5, Current.X + 1)
			buffer.writeu8(Data, Cursor + 6, Current.Y + 1)

			Cursor += 7
		end
	end

	return Data
end

-- @src scripts/map/MapParser.cs:IsValidExt L30-30
const function IsValidExt(Ext: string): boolean
	return Ext == "phxm" or Ext == "sspm" or Ext == "txt" or Ext == "rhm"
end

-- Artist and song from "Artist - Song" (Split(" - ", 2)), or the whole name as the song; each part is StripEdges'd.
const function SplitMapName(Name: string): (string?, string)
	const Parts = DotnetString.Split(Name, " - ", 2)

	if #Parts == 1 then
		return nil, GodotString.StripEdges(Parts[1])
	end

	return GodotString.StripEdges(Parts[1]), GodotString.StripEdges(Parts[2])
end

-- Array.Sort(notes) by Millisecond, then Index set to each note's sorted position.
const function SortNotes(Notes: { Note.Note })
	Sort(Notes, Note.CompareTo)

	for Index, Current in Notes do
		Current.Index = Index - 1
	end
end

-- @src scripts/map/MapParser.cs:sspmV1 L416-518
const function SSPMV1(Parser: FileParser.FileParser, Path: string?): Map.Map
	const Success, Result = pcall(function(): Map.Map
		FileParser.Skip(Parser, 2)

		const Id = FileParser.GetLine(Parser)
		const Artist, Song = SplitMapName(FileParser.GetLine(Parser))
		const Mappers = DotnetString.SplitAny(FileParser.GetLine(Parser), { "&", "," })
		const MapLength = FileParser.GetUInt32(Parser)
		const NoteCount = FileParser.GetUInt32(Parser)
		const Difficulty = FileParser.GetUInt8(Parser)

		const HasCover = FileParser.GetUInt8(Parser) == 2
		local CoverBuffer: buffer? = nil

		if HasCover then
			CoverBuffer = FileParser.Get(Parser, Int32FromUInt64(FileParser.GetUInt64(Parser)))
		end

		const HasAudio = FileParser.GetBool(Parser)
		local AudioBuffer: buffer? = nil

		if HasAudio then
			AudioBuffer = FileParser.Get(Parser, Int32FromUInt64(FileParser.GetUInt64(Parser)))
		end

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
				X = FileParser.GetUInt8(Parser)
				Y = FileParser.GetUInt8(Parser)
			end

			Notes[Index + 1] = Note.New(Index, Millisecond, Numbers.F32(X - 1), Numbers.F32(-Y + 1))
		end

		SortNotes(Notes)

		return Map.New(
			Path or `{MapUtil.MapsFolder}/{Song}_temp.sspm`,
			Notes,
			Id,
			Artist,
			Song,
			nil,
			Mappers,
			Difficulty,
			nil,
			Numbers.Signed(MapLength),
			AudioBuffer,
			CoverBuffer
		)
	end)

	if Success then
		return Result
	end

	return Rethrow("SSPMV1 file corrupted", Result)
end

-- @src scripts/map/MapParser.cs:sspmV2 L520-672
const function SSPMV2(Parser: FileParser.FileParser, Path: string?): Map.Map
	const Success, Result = pcall(function(): Map.Map
		FileParser.Skip(Parser, 4)
		FileParser.Skip(Parser, 20)

		const MapLength = FileParser.GetUInt32(Parser)
		const NoteCount = FileParser.GetUInt32(Parser)

		FileParser.Skip(Parser, 4)

		const Difficulty = buffer.readu8(FileParser.Get(Parser, 1), 0)

		FileParser.Skip(Parser, 2)

		const HasAudio = FileParser.GetBool(Parser)
		const HasCover = FileParser.GetBool(Parser)

		FileParser.Skip(Parser, 1)

		const CustomDataOffset = FileParser.GetUInt64(Parser)

		-- The custom data length is read and not used (the source does the same).
		FileParser.GetUInt64(Parser)

		const AudioByteOffset = FileParser.GetUInt64(Parser)
		const AudioByteLength = FileParser.GetUInt64(Parser)
		const CoverByteOffset = FileParser.GetUInt64(Parser)
		const CoverByteLength = FileParser.GetUInt64(Parser)

		FileParser.Skip(Parser, 16)

		const MarkerByteOffset = FileParser.GetUInt64(Parser)

		FileParser.Skip(Parser, 8)

		const MapIdLength = FileParser.GetUInt16(Parser)
		const Id = FileParser.GetString(Parser, MapIdLength)
		const MapNameLength = FileParser.GetUInt16(Parser)
		const Artist, Song = SplitMapName(FileParser.GetString(Parser, MapNameLength))

		const SongNameLength = FileParser.GetUInt16(Parser)

		FileParser.Skip(Parser, SongNameLength)

		const MapperCount = FileParser.GetUInt16(Parser)
		const Mappers: { string } = {}

		for Index = 1, MapperCount do
			const MapperNameLength = FileParser.GetUInt16(Parser)

			Mappers[Index] = FileParser.GetString(Parser, MapperNameLength)
		end

		local AudioBuffer: buffer? = nil
		local CoverBuffer: buffer? = nil
		local DifficultyName: string? = nil

		FileParser.Seek(Parser, Int32FromUInt64(CustomDataOffset))
		FileParser.Skip(Parser, 2)

		if FileParser.GetString(Parser, FileParser.GetUInt16(Parser)) == "difficulty_name" then
			local Length = 0
			const Kind = buffer.readu8(FileParser.Get(Parser, 1), 0)

			if Kind == 9 then
				Length = FileParser.GetUInt16(Parser)
			elseif Kind == 11 then
				Length = Numbers.Signed(FileParser.GetUInt32(Parser))
			end

			DifficultyName = FileParser.GetString(Parser, Length)
		end

		if HasAudio then
			FileParser.Seek(Parser, Int32FromUInt64(AudioByteOffset))
			AudioBuffer = FileParser.Get(Parser, Int32FromUInt64(AudioByteLength))
		end

		if HasCover then
			FileParser.Seek(Parser, Int32FromUInt64(CoverByteOffset))
			CoverBuffer = FileParser.Get(Parser, Int32FromUInt64(CoverByteLength))
		end

		FileParser.Seek(Parser, Int32FromUInt64(MarkerByteOffset))

		const Notes: { Note.Note } = {}

		for Index = 0, NoteCount - 1 do
			const Millisecond = Numbers.Signed(FileParser.GetUInt32(Parser))

			FileParser.Skip(Parser, 1)

			const IsNoteQuantum = FileParser.GetBool(Parser)

			local X: number
			local Y: number

			if IsNoteQuantum then
				X = FileParser.GetFloat(Parser)
				Y = FileParser.GetFloat(Parser)
			else
				X = buffer.readu8(FileParser.Get(Parser, 1), 0)
				Y = buffer.readu8(FileParser.Get(Parser, 1), 0)
			end

			Notes[Index + 1] = Note.New(0, Millisecond, Numbers.F32(X - 1), Numbers.F32(-Y + 1))
		end

		SortNotes(Notes)

		return Map.New(
			Path :: string,
			Notes,
			Id,
			Artist,
			Song,
			nil,
			Mappers,
			Difficulty,
			DifficultyName,
			Numbers.Signed(MapLength),
			AudioBuffer,
			CoverBuffer
		)
	end)

	if Success then
		return Result
	end

	return Rethrow("SSPMV2 file corrupted", Result)
end

-- The SSPM header and version, then that version's body (SSPM(string) and SSPM(byte[]) in MapParser.cs L342-414).
const function ReadSSPM(Parser: FileParser.FileParser, Path: string?): Map.Map
	if FileParser.GetString(Parser, 4) ~= "SS+m" then
		error("Incorrect file signature", 0)
	end

	const Version = FileParser.GetUInt16(Parser)

	if Version == 1 then
		return SSPMV1(Parser, Path)
	elseif Version == 2 then
		return SSPMV2(Parser, Path)
	end

	error("Invalid SSPM version", 0)
end

-- @src scripts/map/MapParser.cs:SSPM L342-377
const function SSPM(Path: string): Map.Map
	const Success, Result = pcall(ReadSSPM, FileParser.FromPath(Path), Path)

	if Success then
		return Result
	end

	return Rethrow("SSPM file corrupted", Result)
end

-- @src scripts/map/MapParser.cs:SSPM L379-414
const function SSPMBytes(Bytes: buffer): Map.Map
	const Success, Result = pcall(ReadSSPM, FileParser.FromBuffer(Bytes), nil)

	if Success then
		return Result
	end

	return Rethrow("SSPM file corrupted", Result)
end

-- @src scripts/map/MapParser.cs:SSMapV1 L300-340
const function SSMapV1(Path: string, AudioPath: string?): Map.Map
	const Name = GodotString.TrimSuffix(GodotString.GetFile(Path), ".txt")
	const Parser = FileParser.FromPath(Path)

	const Success, Result = pcall(function(): Map.Map
		const Split = DotnetString.Split(FileParser.GetLine(Parser), ",")
		const Notes: { Note.Note } = {}

		-- Split[1] is the first field, the one before the notes; each note is "x|y|ms".
		for Index = 2, #Split do
			const Parts = DotnetString.Split(Split[Index], "|")

			Notes[Index - 1] = Note.New(
				Index - 2,
				GodotString.ToInt(Parts[3]),
				Numbers.F32(-GodotString.ToFloat(Parts[1]) + 1),
				Numbers.F32(GodotString.ToFloat(Parts[2]) - 1)
			)
		end

		const AudioBuffer = if AudioPath ~= nil then FileSystem.ReadAllBytes(AudioPath) else nil

		return Map.New(Path, Notes, nil, "", Name, nil, nil, nil, nil, nil, AudioBuffer)
	end)

	if Success then
		return Result
	end

	return Rethrow("SSMapV1 file corrupted", Result)
end

-- @src scripts/map/MapParser.cs:PHXMFolder L674-756
const function PHXMFolder(Path: string): Map.Map?
	if not FileSystem.Exists(`{Path}/metadata.json`) or not FileSystem.Exists(`{Path}/objects.phxmo`) then
		return nil
	end

	const Success, Result = pcall(function(): Map.Map
		const Metadata = Json.Parse(FileSystem.ReadAllText(`{Path}/metadata.json`)) :: { [string]: unknown }
		const ObjectsBuffer = FileSystem.ReadAllBytes(`{Path}/objects.phxmo`)

		local AudioBuffer: buffer? = nil
		local CoverBuffer: buffer? = nil
		local VideoBuffer: buffer? = nil

		if Field(Metadata, "HasAudio") == true then
			const AudioExt = Field(Metadata, "AudioExt") :: string

			AudioBuffer = FileSystem.ReadAllBytes(`{Path}/audio.{AudioExt}`)
		end

		if Field(Metadata, "HasCover") == true then
			CoverBuffer = FileSystem.ReadAllBytes(`{Path}/cover.png`)
		end

		if Field(Metadata, "HasVideo") == true then
			VideoBuffer = FileSystem.ReadAllBytes(`{Path}/video.mp4`)
		end

		const Notes = PHXMO.Decode(ObjectsBuffer)
		const Hash = Misc.HashFiles({ FileSystem.Combine(Path, "metadata.json"), FileSystem.Combine(Path, "objects.phxmo") })
		const MetadataModified = FileSystem.GetLastWriteTime(FileSystem.Combine(Path, "metadata.json"))
		const ObjectsModified = FileSystem.GetLastWriteTime(FileSystem.Combine(Path, "objects.phxmo"))

		-- The "ID" entry is read (a missing key throws); the constructor ignores it, as the source does.
		Field(Metadata, "ID")

		const Parsed = Map.New(
			Path,
			Notes,
			nil,
			OptionalText(Field(Metadata, "Artist")),
			OptionalText(Field(Metadata, "Title")),
			nil,
			Field(Metadata, "Mappers") :: { string },
			Numbers.TruncInt32(Field(Metadata, "Difficulty") :: number),
			OptionalText(Field(Metadata, "DifficultyName")),
			Numbers.TruncInt32(Field(Metadata, "Length") :: number),
			AudioBuffer,
			CoverBuffer,
			VideoBuffer,
			false,
			OptionalText(Metadata["ArtistLink"]) or "",
			OptionalText(Metadata["ArtistPlatform"]) or ""
		)

		-- (a map folder has no extension: a name with a dot in it, like "ft.", is kept whole, or its scores went under a cut name)
		Parsed.Name = FileSystem.GetFileName(FileSystem.Normalize(Path))
		Parsed.MetadataObjectHash = Md5.ToHexLower(Hash)
		Parsed.LastModifiedMetadata = FormatLastWriteTime(MetadataModified)
		Parsed.LastModifiedNotes = FormatLastWriteTime(ObjectsModified)

		return Parsed
	end)

	if Success then
		return Result
	end

	ToastNotification.Notify(`{FileSystem.GetFileNameWithoutExtension(Path)} is not the proper format!`, 2)
	Logger.ErrorException(Result)
	error(Result, 0)
end

-- @src scripts/map/MapParser.cs:PHXM L758-784
const function PHXM(Path: string): Map.Map?
	const MapDirectory = MapUtil.MapsFolder
	const ExtractedFolderName = FileSystem.GetFileNameWithoutExtension(Path)
	const ExtractedFolderPath = FileSystem.Combine(MapDirectory, ExtractedFolderName)

	-- An existing map with the same folder is removed from the cache first.
	if FileSystem.DirectoryExists(ExtractedFolderPath) then
		FileSystem.DeleteDirectory(ExtractedFolderPath, true)

		const ExistingMap = MapCache.FindByFolderPath(ExtractedFolderPath)

		MapCache.RemoveMap(ExistingMap)
	end

	Zip.ExtractToDirectory(FileSystem.ReadAllBytes(Path), ExtractedFolderPath)

	-- The archive is deleted once extracted when it sits inside the maps folder.
	-- DEVIATION: Path.GetFullPath resolves against the working directory; here paths are root-relative, so Normalize stands in.
	const FullPath = FileSystem.Normalize(Path)
	const FullMapDirectory = FileSystem.Normalize(MapDirectory)

	if string.sub(FullPath, 1, #FullMapDirectory + 1) == `{FullMapDirectory}/` then
		FileSystem.Delete(Path)
	end

	return PHXMFolder(ExtractedFolderPath)
end

-- @src scripts/map/MapParser.cs:RHM L825-895
const function RHM(Path: string): Map.Map
	const Success, Result = pcall(function(): Map.Map
		const Archive = Zip.Open(FileSystem.ReadAllBytes(Path))
		const MapData = Json.Parse(JsonText(GetZipEntryBuffer(Archive, "map"))) :: { [string]: unknown }
		const NoteData = Field(MapData, "Notes") :: { { [string]: unknown } }
		const Notes: { Note.Note } = {}

		for Index = 1, #NoteData do
			const NoteEntry = NoteData[Index]

			Notes[Index] = Note.New(
				Index - 1,
				Numbers.TruncInt32(Field(NoteEntry, "Time") :: number),
				Numbers.F32(Numbers.F32(Field(NoteEntry, "X") :: number) - 1),
				Numbers.F32(1 - Numbers.F32(Field(NoteEntry, "Y") :: number))
			)
		end

		local Artist: string? = nil
		local Title: string? = nil
		const Split = DotnetString.Split(Field(MapData, "Title") :: string, " - ")

		if #Split == 1 then
			Title = Split[1]
		elseif #Split > 1 then
			Artist = Split[1]
			Title = GodotString.Join(table.move(Split, 2, #Split, 1, {}), " - ")
		end

		const Mappers = Field(MapData, "Mappers") :: { string }
		const Difficulty = Numbers.TruncInt32(Field(MapData, "Difficulty") :: number)
		const DifficultyName = OptionalText(Field(MapData, "CustomDifficultyName"))
		const ImagePath = Field(MapData, "ImagePath") :: string
		const AudioEntry = Zip.GetEntry(Archive, "audio")
		local AudioPath: string

		if AudioEntry then
			AudioPath = AudioEntry.Name
		else
			AudioPath = Field(MapData, "AudioFileName") :: string
		end

		const AudioBuffer = GetZipEntryBuffer(Archive, AudioPath)
		const CoverBuffer = GetZipEntryBuffer(Archive, ImagePath)

		return Map.New(
			Path,
			Notes,
			nil,
			Artist or "",
			Title or "",
			nil,
			Mappers,
			Difficulty,
			DifficultyName,
			Notes[#Notes].Millisecond,
			AudioBuffer,
			CoverBuffer
		)
	end)

	if Success then
		return Result
	end

	return Rethrow("RHM file corrupted", Result)
end

-- @src scripts/map/MapParser.cs:Encode L159-251
-- The asset file of Encode's addAsset.
const function AddAsset(Folder: string, Name: string, Data: buffer)
	FileSystem.WriteAllBytes(FileSystem.Combine(Folder, Name), Data)
end

-- @src scripts/map/MapParser.cs:Encode L159-251
const function Encode(Target: Map.Map, LogBenchmark: boolean?)
	const Start = os.clock()
	const MapDirectory = MapUtil.MapsFolder
	const MapFolderPath = FileSystem.Combine(MapDirectory, Target.Name)

	if not FileSystem.DirectoryExists(MapDirectory) then
		FileSystem.CreateDirectory(MapDirectory)
	end

	if not FileSystem.DirectoryExists(MapFolderPath) then
		FileSystem.CreateDirectory(MapFolderPath)
	end

	const MetadataPath = FileSystem.Combine(MapFolderPath, "metadata.json")
	const ObjectsPath = FileSystem.Combine(MapFolderPath, "objects.phxmo")

	FileSystem.WriteAllBytes(ObjectsPath, ObjectsBuffer(Map.GetNotes(Target)))

	if Target.AudioBuffer ~= nil then
		AddAsset(MapFolderPath, `audio.{Target.AudioExt}`, Target.AudioBuffer)
	end

	if Target.CoverBuffer ~= nil then
		AddAsset(MapFolderPath, "cover.png", Target.CoverBuffer)
	end

	if Target.VideoBuffer ~= nil then
		AddAsset(MapFolderPath, "video.mp4", Target.VideoBuffer)
	end

	FileSystem.WriteAllText(MetadataPath, Map.EncodeMeta(Target))

	const Hash = Misc.HashFiles({ MetadataPath, ObjectsPath })

	Target.MetadataObjectHash = Md5.ToHexLower(Hash)
	Target.LastModifiedMetadata = FormatLastWriteTime(FileSystem.GetLastWriteTime(MetadataPath))
	Target.LastModifiedNotes = FormatLastWriteTime(FileSystem.GetLastWriteTime(ObjectsPath))
	Target.FolderPath = MapFolderPath

	MapCache.InsertMap(Target)

	if LogBenchmark then
		Logger.Log(`ENCODING {string.upper(Constants.DefaultMapExt)}: {(os.clock() - Start) * 1000}ms`)
	end
end

-- @src scripts/map/MapParser.cs:Decode L253-298
const function Decode(Path: string, Audio: string?, LogBenchmark: boolean?, Save: boolean?): Map.Map?
	if FileSystem.Exists(Path) then
		const Ext = GodotString.GetExtension(Path)
		const Start = os.clock()

		if not IsValidExt(Ext) then
			ToastNotification.Notify("Unsupported file format", 1)
			error(Logger.Error(`Unsupported file format ({Ext})`), 0)
		end

		local Decoded: Map.Map?

		if Ext == "phxm" then
			Decoded = PHXM(Path)
		elseif Ext == "sspm" then
			Decoded = SSPM(Path)
		elseif Ext == "txt" then
			Decoded = SSMapV1(Path, Audio)
		elseif Ext == "rhm" then
			Decoded = RHM(Path)
		else
			Decoded = Map.Empty()
		end

		if LogBenchmark then
			Logger.Log(`DECODING {string.upper(Ext)}: {(os.clock() - Start) * 1000}ms`)
		end

		if Save then
			Encode(Decoded :: Map.Map)
		end

		return Decoded
	elseif FileSystem.DirectoryExists(Path) then
		return PHXMFolder(Path)
	end

	ToastNotification.Notify("Invalid map path", 2)
	error(Logger.Error(`Invalid map path ({Path})`), 0)
end

-- BulkImport's per-file step: decode, then encode. Errors are the corrupt-file path of BulkImport.
const function ImportFile(Path: string): Map.Map?
	const Imported = Decode(Path, nil, false, false)

	if Imported then
		Encode(Imported)
	end

	return Imported
end

-- @src scripts/map/MapParser.cs:ExportEncode L83-157
const function ExportEncode(Target: Map.Map)
	-- The cut-down cache list has no buffers: decoding the folder again gets them.
	const Decoded = Decode(Target.FolderPath) :: Map.Map
	const ExportPath = `{Constants.UserFolder}/export/`
	const ExportFilePath = FileSystem.Combine(ExportPath, `{Decoded.Name}.phxm`)

	if not FileSystem.DirectoryExists(ExportPath) then
		FileSystem.CreateDirectory(ExportPath)
	end

	const Entries = {
		{ Name = "metadata.json", Data = buffer.fromstring(Map.EncodeMeta(Decoded)) },
		{ Name = "objects.phxmo", Data = ObjectsBuffer(Map.GetNotes(Decoded)) },
	}

	if Decoded.AudioBuffer ~= nil then
		table.insert(Entries, { Name = `audio.{Decoded.AudioExt}`, Data = Decoded.AudioBuffer })
	end

	if Decoded.CoverBuffer ~= nil then
		table.insert(Entries, { Name = "cover.png", Data = Decoded.CoverBuffer })
	end

	if Decoded.VideoBuffer ~= nil then
		table.insert(Entries, { Name = "video.mp4", Data = Decoded.VideoBuffer })
	end

	FileSystem.WriteAllBytes(ExportFilePath, Zip.Create(Entries))
end

-- @src scripts/map/MapParser.cs:BulkImport L32-81
const function BulkImport(Files: { string }, Notify: boolean?)
	if #Files == 0 then
		return
	end

	if Notify then
		ToastNotification.Notify(`Importing {#Files} map(s)`)
	end

	const Start = os.clock()
	const Maps: { Map.Map } = {}
	local Good = 0
	local Corrupted = 0

	Signal.Fire(MapsImportStarted)

	for _, Path in Files do
		const Success, Imported = pcall(ImportFile, Path)

		if Success then
			Good += 1

			if Imported then
				table.insert(Maps, Imported)
			end

			Signal.Fire(MapImported, Imported)
		else
			Corrupted += 1
		end
	end

	const Duration = (os.clock() - Start) * 1000

	Logger.Log(`BULK IMPORT: {Duration}ms; TOTAL: {Good + Corrupted}; CORRUPT: {Corrupted}`)
	Signal.Fire(MapsImportFinished, Maps)

	if Hooks.UpdateJukeboxQueue then
		Hooks.UpdateJukeboxQueue()
	end

	if Notify then
		ToastNotification.Notify(`Finished importing {#Files} map(s)`)
	end
end

MapCache.ParserHooks = {
	Decode = Decode,
	Encode = Encode,
}

return {
	MapsImportStarted = MapsImportStarted,
	MapsImportFinished = MapsImportFinished,
	MapImported = MapImported,
	Hooks = Hooks,
	IsValidExt = IsValidExt,
	BulkImport = BulkImport,
	ExportEncode = ExportEncode,
	Encode = Encode,
	Decode = Decode,
	SSMapV1 = SSMapV1,
	SSPM = SSPM,
	SSPMBytes = SSPMBytes,
	PHXMFolder = PHXMFolder,
	PHXM = PHXM,
	DecodePHXMO = PHXMO.Decode,
	DecodePHXMOFile = PHXMO.DecodeFile,
	RHM = RHM,
}
