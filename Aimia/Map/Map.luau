--!strict
--!optimize 2

--[[
	Map.cs: one map, a folder under user/maps (metadata.json, objects.phxmo, optional audio, cover and video buffers) and its
	metadata. A Map is a table from New (the C# constructor) or Empty (`new()`).

	Representation
		Notes and Cover are the backing fields. GetNotes is the Notes getter: it parses objects.phxmo on first use and answers an
		empty array when that fails (the source's catch-all, which leaves Notes unset). GetCover is the Cover getter.

	Design Notes
		GetCover decodes cover.png on first use (Util/ImageDecode, through Misc.LoadImageFromBuffer) and keeps the image on the
			map; the UI registers it with UI/Images. A map without a readable cover answers DefaultCover (a res:// path).
		The constructor's id argument is unused, as in the source: Map.Id is the database key set by MapCache.
		Notes are decoded by Objects/PHXMO, not MapParser (MapParser requires this module). Registers MapCache.MapHooks on load.
		Audio is the AudioStream of the audio port, which is not ported; it stays nil.
]]

const Constants = require("../Constants")
const FileSystem = require("../Util/FileSystem")
const GodotString = require("../Godot/String")
const Json = require("../Godot/Json")
const MapCache = require("./MapCache")
const ImageDecode = require("../Util/ImageDecode")
const MapTypes = require("./MapTypes")
const Misc = require("../Util/Misc")
const MapManager = require("./MapManager")
const MapUtil = require("./MapUtil")
const Note = require("./Objects/Note")
const PHXMO = require("./Objects/PHXMO")

export type Map = MapTypes.Map

const DefaultCover = "res://textures/empty.png"

-- @src scripts/map/Map.cs:Map L128-128
const function Empty(): Map
	return {
		Id = 0,
		Name = "",
		CacheVersion = nil,
		LastModifiedMetadata = nil,
		LastModifiedNotes = nil,
		MetadataObjectHash = nil,
		Collection = "",
		MapSet = nil,
		FolderPath = "",
		Favorite = false,
		Ephemeral = false,
		Artist = "",
		ArtistLink = "",
		ArtistPlatform = "",
		Title = "",
		PrettyTitle = "",
		Rating = 0,
		CachedMappers = "",
		Mappers = {},
		PrettyMappers = "",
		DifficultyName = "",
		Difficulty = 0,
		Length = 0,
		AudioBuffer = buffer.create(0),
		AudioExt = "",
		PlayCount = 0,
		Cover = nil,
		Audio = nil,
		CoverBuffer = buffer.create(0),
		VideoBuffer = buffer.create(0),
		Notes = nil,
	}
end

-- @src scripts/map/Map.cs:Map L130-178
const function New(
	FolderPath: string,
	Data: { Note.Note }?,
	MapId: string?,
	Artist: string?,
	Title: string?,
	Rating: number?,
	Mappers: { string }?,
	Difficulty: number?,
	DifficultyName: string?,
	Length: number?,
	AudioBuffer: buffer?,
	CoverBuffer: buffer?,
	VideoBuffer: buffer?,
	Ephemeral: boolean?,
	ArtistLink: string?,
	ArtistPlatform: string?
): Map
	const Created = Empty()
	const Parsed = Data or {}

	Created.CacheVersion = 2
	Created.FolderPath = FolderPath
	Created.Ephemeral = Ephemeral or false
	Created.MetadataObjectHash = ""
	Created.LastModifiedMetadata = ""
	Created.LastModifiedNotes = ""

	Created.Artist = GodotString.StripEscapes(Artist or "")
	Created.ArtistLink = ArtistLink or ""
	Created.ArtistPlatform = ArtistPlatform or ""
	Created.Title = GodotString.StripEscapes(Title or "")
	Created.PrettyTitle = if Created.Artist ~= "" then `{Created.Artist} - {Created.Title}` else Created.Title
	Created.Rating = Rating or 0

	Created.Mappers = Mappers or { "N/A" }
	Created.PrettyMappers = GodotString.Join(Created.Mappers)
	Created.CachedMappers = GodotString.Join(Created.Mappers, "_")

	Created.Difficulty = math.clamp(Difficulty or 0, 0, #Constants.Difficulties - 1)
	Created.DifficultyName = if DifficultyName ~= nil
		then GodotString.StripEscapes(DifficultyName)
		else Constants.Difficulties[Created.Difficulty + 1]

	Created.AudioBuffer = AudioBuffer
	Created.CoverBuffer = CoverBuffer
	Created.VideoBuffer = VideoBuffer
	Created.Notes = Parsed
	Created.Length = Length or Parsed[#Parsed].Millisecond

	Created.Name = FileSystem.GetFileNameWithoutExtension(FolderPath)
	-- DEVIATION(error): a buffer shorter than 4 bytes raises here, as the source's AudioBuffer[0..4] does.
	Created.AudioExt = if AudioBuffer ~= nil and buffer.readstring(AudioBuffer, 0, 4) == "OggS" then "ogg" else "mp3"

	MapManager.Sanitize(Created)

	return Created
end

-- @src scripts/map/Map.cs:TryParseNotes L97-108
const function TryParseNotes(Map: Map): { Note.Note }
	const Success, Result = pcall(PHXMO.DecodeFile, `{MapUtil.MapsFolder}/{Map.Name}/objects.phxmo`)

	if Success then
		Map.Notes = Result
		return Result
	end

	return {}
end

-- @src scripts/map/Map.cs:Notes L91-95
const function GetNotes(Map: Map): { Note.Note }
	return Map.Notes or TryParseNotes(Map)
end

-- @src scripts/map/Map.cs:Notes L91-95
const function SetNotes(Map: Map, Notes: { Note.Note }?)
	Map.Notes = Notes
end

-- The cover: the decoded image of the map's cover.png, or DefaultCover. The image is kept on the map (getCover's cache), so
-- the file is decoded once; a cover set by the caller (a decoded image or a path) is answered as it is.
-- @src scripts/map/Map.cs:getCover L110-126
const function GetCover(Map: Map): ImageDecode.Image | string
	if Map.Cover == nil or Map.Cover == DefaultCover then
		const CoverPath = `{MapUtil.MapsFolder}/{Map.Name}/cover.png`

		if FileSystem.Exists(CoverPath) then
			const Decoded = Misc.LoadImageFromBuffer(FileSystem.ReadAllBytes(CoverPath))

			if Decoded then
				Map.Cover = Decoded
			end
		end
	end

	return (Map.Cover :: ImageDecode.Image | string?) or DefaultCover
end

-- @src scripts/map/Map.cs:EncodeMeta L180-203
const function EncodeMeta(Map: Map): string
	const Path = `{MapUtil.MapsFolder}/{Map.Name}`

	return Json.Stringify({
		ID = Map.Name,
		Artist = Map.Artist,
		ArtistLink = Map.ArtistLink,
		ArtistPlatform = Map.ArtistPlatform,
		Title = Map.Title,
		Rating = Map.Rating,
		Mappers = Map.Mappers,
		Difficulty = Map.Difficulty,
		DifficultyName = Map.DifficultyName,
		Length = Map.Length,
		HasAudio = Map.AudioBuffer ~= nil and FileSystem.Exists(`{Path}/audio.{Map.AudioExt}`),
		HasCover = Map.CoverBuffer ~= nil and FileSystem.Exists(`{Path}/cover.png`),
		HasVideo = Map.VideoBuffer ~= nil and FileSystem.Exists(`{Path}/video.mp4`),
		AudioExt = Map.AudioExt,
	}, "\t")
end

MapCache.MapHooks = {
	New = Empty,
	DefaultCover = DefaultCover,
}

return {
	DefaultCover = DefaultCover,
	Empty = Empty,
	New = New,
	GetNotes = GetNotes,
	SetNotes = SetNotes,
	TryParseNotes = TryParseNotes,
	GetCover = GetCover,
	EncodeMeta = EncodeMeta,
}
