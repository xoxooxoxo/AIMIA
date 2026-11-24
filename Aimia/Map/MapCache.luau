--!strict
--!optimize 2

--[[
	The map cache of scripts/map/MapCache.cs: the maps table kept in step with the maps folder, and the sorted list
	MapManager.Maps.

	Design Notes
		The table is DatabaseService's (SQLite is replaced): FetchAll answers copies, and each write stores one.
		This module requires no Map module. Map.luau, MapParser.luau and MapManager.luau register their hooks (MapHooks,
		ParserHooks, ManagerHooks) when they load, as Util/Notify takes its Handler. Map requires MapManager, MapManager
		requires this module, and MapParser requires Map: a require from here to any of them would close a cycle the
		validator rejects, lazy or not. Reading a hook before its module has loaded is an error.
		Task.Run and Parallel loops run in the calling thread, in order. FilesToSync and FilesSynced are Bindables, and
		OnFilesSyncFinished is a Signal.
		The maps folder is listed recursively: the .phxm files first, then the folders, each in FileSystem order.
		DEVIATION(platform): image decoding is not logic. CoverDecoder (set by the UI) answers the cover for a cover.png's
		bytes, or nil where LoadImageFromBuffer answers null. With no decoder, no cover is loaded.
		FormatLastWriteTime is MapParser's text for a write time ("O" with a zero fraction, since file times are whole seconds).
		DEVIATION(culture): titles are compared ordinally (see TitleBefore).
		Aimia.TempMode is Constants.TempMapMode here.
]]

const Bindable = require("../Util/Bindables/Bindable")
const Constants = require("../Constants")
const DatabaseService = require("../Database/DatabaseService")
const MapTypes = require("./MapTypes")
const DotnetString = require("../Dotnet/String")
const FileSystem = require("../Util/FileSystem")
const Logger = require("../Util/Logger")
const Md5 = require("../Util/Md5")
const Misc = require("../Util/Misc")
const Numbers = require("../Numbers")
const Signal = require("../Util/Signal")

-- Registered by Map.luau: the constructor of a blank map (C# new Map()) and the cover every map starts with.
export type MapHooks = {
	New: () -> MapTypes.Map,
	DefaultCover: unknown,
}

-- Registered by MapParser.luau.
export type ParserHooks = {
	Decode: (Path: string, Audio: string?, LogBenchmark: boolean?, Save: boolean?) -> MapTypes.Map?,
	Encode: (Map: MapTypes.Map) -> (),
}

-- Registered by MapManager.luau: the list it publishes and the sanitizer it runs on each map before publishing.
export type ManagerHooks = {
	Maps: { MapTypes.Map },
	Sanitize: (Map: MapTypes.Map) -> (),
}

const MapsFolder = `{Constants.UserFolder}/maps`

-- The Map properties with [Ignore] upstream: they live on the object only.
const IgnoredMapFields = { "MapSet", "Ephemeral", "Mappers", "AudioBuffer", "Cover", "Audio", "CoverBuffer", "VideoBuffer", "Notes" }

local MapTable: DatabaseService.Table<MapTypes.Map>? = nil

const MapCache = {
	FilesToSync = Bindable.New(0),
	FilesSynced = Bindable.New(0),
	OnFilesSyncFinished = Signal.New(),
	OldCacheFormat = false,
	MapsToBeFavorited = {} :: { string },
	MapsFolder = MapsFolder,
	CoverDecoder = nil :: ((CoverBuffer: buffer) -> unknown?)?,
	MapHooks = nil :: MapHooks?,
	ParserHooks = nil :: unknown?,
	ManagerHooks = nil :: ManagerHooks?,
}

-- A hook a module registers when it loads; reading it before that is an error.
const function Registered<T>(Hook: T?, Module: string): T
	if Hook == nil then
		error(`{Module} has not been required: its hooks are not registered`, 3)
	end

	return Hook
end

-- The maps table, which Initialize creates.
const function MapsTable(): DatabaseService.Table<MapTypes.Map>
	if MapTable == nil then
		error("MapCache.Initialize has not run", 2)
	end

	return MapTable
end

-- A row predicate: the stored field equals Value.
const function FieldIs(Field: string, Value: unknown): (DatabaseService.Fields) -> boolean
	return function(Stored: DatabaseService.Fields): boolean
		return Stored[Field] == Value
	end
end

-- Directory.GetFiles(MapsFolder, "*.phxm", AllDirectories) and GetDirectories(MapsFolder, "*", AllDirectories): the walk
-- adds the .phxm files of each folder, and every folder below it, depth first.
const function CollectMaps(Folder: string, Files: { string }, Folders: { string })
	for _, File in FileSystem.GetFiles(Folder, `.{Constants.DefaultMapExt}`) do
		table.insert(Files, File)
	end

	for _, Child in FileSystem.GetDirectories(Folder) do
		table.insert(Folders, Child)
		CollectMaps(Child, Files, Folders)
	end
end

-- The .phxm files, then the folders, as Load lists them.
const function ListMaps(): { string }
	const Files: { string } = {}
	const Folders: { string } = {}

	CollectMaps(MapsFolder, Files, Folders)
	table.move(Folders, 1, #Folders, #Files + 1, Files)

	return Files
end

-- @src scripts/map/MapCache.cs:syncFiles L65-192
const function SyncFiles(ToParseMaps: { string })
	const Parser = Registered(MapCache.ParserHooks, "MapParser") :: ParserHooks
	const Maps = MapCache.FetchAll()

	if #Maps > 0 then
		const First = Maps[1]

		if First.CacheVersion == nil or First.CacheVersion <= 1 then
			MapCache.OldCacheFormat = true
			Logger.Log("Old map cache detected! Re-converting...")
		end
	end

	Bindable.Set(MapCache.FilesToSync, #Maps)
	Bindable.Set(MapCache.FilesSynced, 0)

	for Index = 1, #ToParseMaps do
		ToParseMaps[Index] = MapCache.BackSlashToForwardSlash(ToParseMaps[Index])
	end

	const MapPathSet: { [string]: boolean } = {}

	for _, MapPath in ToParseMaps do
		MapPathSet[MapPath] = true
	end

	local DeletedMapCount = 0

	for _, Map in Maps do
		const MapPath = MapCache.BackSlashToForwardSlash(Map.FolderPath)

		if MapCache.OldCacheFormat and Map.Favorite then
			-- The new cache re-writes it from scratch with a new format, so we will need to store these for later
			table.insert(MapCache.MapsToBeFavorited, Map.Name)
		end

		if MapPathSet[MapPath] then
			const MetadataModifiedDate = FileSystem.GetLastWriteTime(FileSystem.Combine(MapPath, "metadata.json"))
			const ObjectModifiedDate = FileSystem.GetLastWriteTime(FileSystem.Combine(MapPath, "objects.phxmo"))
			const MetadataResult = MapCache.FormatLastWriteTime(MetadataModifiedDate)
			const NotesResult = MapCache.FormatLastWriteTime(ObjectModifiedDate)

			const MetadataCheck = Map.LastModifiedMetadata == MetadataResult
			const ObjectsCheck = Map.LastModifiedNotes == NotesResult

			-- Last modified comes before checksum since it is faster
			if MetadataCheck or ObjectsCheck then
				Bindable.Set(MapCache.FilesSynced, MapCache.FilesSynced.Value + 1)

				continue
			end

			const Checksum = MapCache.GetMd5Checksum(MapPath)

			if Map.MetadataObjectHash == Checksum then
				Bindable.Set(MapCache.FilesSynced, MapCache.FilesSynced.Value + 1)

				continue
			end

			const Success, Result = pcall(Parser.Decode, MapPath, nil, false, true)

			if not Success then
				Logger.ErrorException(Result)

				if FileSystem.Exists(MapPath) then
					FileSystem.Delete(MapPath)
				elseif FileSystem.DirectoryExists(MapPath) then
					FileSystem.DeleteDirectory(MapPath, true)
				end

				DatabaseService.Delete(MapsTable(), Map)
				Bindable.Set(MapCache.FilesSynced, MapCache.FilesSynced.Value + 1)

				continue
			end

			const NewMap = Result :: MapTypes.Map

			NewMap.LastModifiedMetadata = MetadataResult
			NewMap.LastModifiedNotes = NotesResult
			NewMap.Id = Map.Id
			NewMap.MetadataObjectHash = Checksum

			DatabaseService.Update(MapsTable(), NewMap)
			Logger.Log(`Updated cached map: {NewMap.Name}`)
			Bindable.Set(MapCache.FilesSynced, MapCache.FilesSynced.Value + 1)

			continue
		end

		const MapFolder = `{MapsFolder}/{Map.Name}`

		if FileSystem.DirectoryExists(MapFolder) then
			-- Check if valid map
			if not FileSystem.Exists(`{MapFolder}/metadata.json`) or not FileSystem.Exists(`{MapFolder}/objects.phxmo`) then
				FileSystem.DeleteDirectory(MapFolder, nil)
			end
		end

		DatabaseService.Delete(MapsTable(), Map)
		DeletedMapCount += 1
		Bindable.Set(MapCache.FilesSynced, MapCache.FilesSynced.Value + 1)
	end

	if DeletedMapCount > 0 then
		Logger.Log(`Removed {DeletedMapCount} maps from the cache.`)
	end
end

-- The try block of addNonCachedFiles for one path: false when the parser answers nothing for it.
const function AddNonCachedMap(ToParseMap: string): boolean
	const Parser = Registered(MapCache.ParserHooks, "MapParser") :: ParserHooks
	const Map: MapTypes.Map? = Parser.Decode(ToParseMap)

	if Map == nil then
		Logger.Log(`Failed to add map non-cached map {ToParseMap}`)

		return false
	end

	Map.FolderPath = MapCache.BackSlashToForwardSlash(ToParseMap)
	Map.MetadataObjectHash = MapCache.GetMd5Checksum(Map.FolderPath)

	if MapCache.OldCacheFormat and table.find(MapCache.MapsToBeFavorited, Map.Name) ~= nil then
		Map.Favorite = true
	end

	MapCache.InsertMap(Map)

	return true
end

-- @src scripts/map/MapCache.cs:addNonCachedFiles L194-255
const function AddNonCachedFiles(ToParseMaps: { string })
	const Maps = MapCache.FetchAll()
	const CachedPaths: { [string]: boolean } = {}

	for _, Map in Maps do
		CachedPaths[Map.FolderPath] = true
	end

	-- Maps that need to be parsed - maps in database cache
	Bindable.Set(MapCache.FilesToSync, #ToParseMaps - #Maps)
	Bindable.Set(MapCache.FilesSynced, 0)

	-- For Old Cache version
	if table.find(ToParseMaps, `{MapsFolder}/default`) ~= nil then
		Bindable.Set(MapCache.FilesToSync, MapCache.FilesToSync.Value - 1)
	end

	Logger.Log(`Decoding {#ToParseMaps} maps\nFiles To Sync: {MapCache.FilesToSync.Value}`)

	for _, ToParseMap in ToParseMaps do
		-- If the map path already exists in the map cache, skip it
		if CachedPaths[MapCache.BackSlashToForwardSlash(ToParseMap)] then
			continue
		end

		const Success, Result = pcall(AddNonCachedMap, ToParseMap)

		if not Success then
			Logger.Log(`Failed to add map non-cached map {ToParseMap}`)
			Logger.ErrorException(Result)
		elseif not Result then
			continue
		end

		Bindable.Set(MapCache.FilesSynced, MapCache.FilesSynced.Value + 1)
	end

	Logger.Log(`Files Synced: {MapCache.FilesSynced.Value}`)
end

-- The try block of Load: lists the maps folder, syncs it when FullSync, then orders the maps.
const function LoadMaps(FullSync: boolean)
	const ToParseMaps = ListMaps()

	if FullSync then
		SyncFiles(ToParseMaps)
		AddNonCachedFiles(ToParseMaps)

		-- Old caching format used to just extract .phxm files, essentially doubling your game size
		const OldCacheFolder = `{Constants.UserFolder}/cache/maps`

		if MapCache.OldCacheFormat and FileSystem.DirectoryExists(OldCacheFolder) then
			FileSystem.DeleteDirectory(OldCacheFolder, true)
		end

		Signal.Fire(MapCache.OnFilesSyncFinished, MapCache.FilesSynced.Value)
		Bindable.Set(MapCache.FilesToSync, 0)
		Bindable.Set(MapCache.FilesSynced, 0)
	end

	MapCache.OrderAndSetMaps()
end

-- The cover pass of OrderAndSetMaps: a map still on the default cover takes the one its cover.png decodes to. The source
-- runs it on a Task and sets each cover with CallDeferred, checking MapManager.Maps.Contains(map) when the call runs; the
-- list was set just before, so every map is in it, and the check is not repeated here.
const function LoadCovers(Maps: { MapTypes.Map })
	const Defaults = Registered(MapCache.MapHooks, "Map")

	for _, Map in Maps do
		const CoverPath = `{MapsFolder}/{Map.Name}/cover.png`

		-- The Cover getter answers DefaultCover for an unset cover (Map.GetCover: Map.Cover or DefaultCover).
		if (Map.Cover or Defaults.DefaultCover) ~= Defaults.DefaultCover or not FileSystem.Exists(CoverPath) then
			continue
		end

		const CoverBuffer = FileSystem.ReadAllBytes(CoverPath)

		if buffer.len(CoverBuffer) == 0 then
			continue
		end

		const Decoder = MapCache.CoverDecoder
		const Cover = if Decoder then Decoder(CoverBuffer) else nil

		if Cover ~= nil then
			Map.Cover = Cover
		end
	end
end

-- The try block of InsertMap.
const function StoreMap(Map: MapTypes.Map, Existing: MapTypes.Map?, Updated: MapTypes.Map?): number
	if Updated and Existing then
		Map.Id = Updated.Id
		MapCache.UpdateMap(Map)

		return Map.Id
	end

	DatabaseService.Insert(MapsTable(), Map)

	return DatabaseService.Get(MapsTable(), FieldIs("MetadataObjectHash", Map.MetadataObjectHash)).Id
end

-- OrderBy(x => x.PrettyTitle). DEVIATION(culture): the comparison is ordinal (byte order of the UTF-8 text). The source
-- compares with Comparer<string>.Default: the culture's collation, which is case-insensitive first and puts lowercase
-- before uppercase on a tie (Windows invariant culture: "apple" before "Banana"; "alpha" before "Alpha" before "Same").
const function TitleBefore(First: MapTypes.Map, Second: MapTypes.Map): boolean
	return First.PrettyTitle < Second.PrettyTitle
end

-- @src scripts/map/MapCache.cs:Initialize L18-21
function MapCache.Initialize()
	if MapTable == nil then
		MapTable = DatabaseService.CreateTable("Map", Registered(MapCache.MapHooks, "Map").New, IgnoredMapFields, true)
	end
end

-- @src scripts/map/MapCache.cs:Load L23-63
function MapCache.Load(FullSync: boolean)
	if Constants.TempMapMode then
		return
	end

	const Success = pcall(LoadMaps, FullSync)

	-- catch: the list is still set from the rows
	if not Success then
		MapCache.OrderAndSetMaps()
	end
end

-- @src scripts/map/MapCache.cs:InsertMap L257-294
function MapCache.InsertMap(Map: MapTypes.Map): number
	const Existing = DatabaseService.Find(MapsTable(), FieldIs("MetadataObjectHash", Map.MetadataObjectHash))
	const Updated = DatabaseService.Find(MapsTable(), FieldIs("Name", Map.Name))
	const Success, Result = pcall(StoreMap, Map, Existing, Updated)

	if Success then
		return Result
	end

	if Existing == nil or Updated == nil then
		Logger.Error(tostring(Result))

		return -1
	end

	const NewPath = FileSystem.Combine(MapsFolder, Map.Name)
	const ExistingPath = FileSystem.Combine(MapsFolder, Existing.FolderPath)

	if ExistingPath ~= NewPath then
		FileSystem.DeleteDirectory(NewPath, true)
	end

	return -1
end

-- @src scripts/map/MapCache.cs:UpdateMap L296-306
function MapCache.UpdateMap(Map: MapTypes.Map)
	const Success, Failure = pcall(function()
		DatabaseService.Update(MapsTable(), Map)
	end)

	if not Success then
		Logger.Error(tostring(Failure))
	end
end

-- @src scripts/map/MapCache.cs:RemoveMap L308-318
-- Map may be nil (MapParser.PHXM passes the cache lookup through): the delete fails and is logged, as in C#.
function MapCache.RemoveMap(Map: MapTypes.Map?)
	const Success, Failure = pcall(function()
		DatabaseService.Delete(MapsTable(), Map)
	end)

	if not Success then
		Logger.Error(tostring(Failure))
	end
end

-- @src scripts/map/MapCache.cs:OrderAndSetMaps L320-373
function MapCache.OrderAndSetMaps()
	const Manager = Registered(MapCache.ManagerHooks, "MapManager")
	const Maps = MapCache.FetchAll()

	if #Maps < 1 then
		Manager.Maps = {}

		return
	end

	const Favorites: { MapTypes.Map } = {}
	const Others: { MapTypes.Map } = {}

	for _, Map in Maps do
		if Map.Favorite then
			table.insert(Favorites, Map)
		else
			table.insert(Others, Map)
		end
	end

	Numbers.StableSort(Favorites, TitleBefore)
	Numbers.StableSort(Others, TitleBefore)

	const SortedMaps = Favorites

	table.move(Others, 1, #Others, #SortedMaps + 1, SortedMaps)

	for _, Map in SortedMaps do
		Manager.Sanitize(Map)
	end

	Manager.Maps = SortedMaps

	LoadCovers(Maps)
end

-- @src scripts/map/MapCache.cs:GetMd5Checksum L375-382
function MapCache.GetMd5Checksum(Path: string): string
	const MetadataPath = FileSystem.Combine(Path, "metadata.json")
	const ObjectsPath = FileSystem.Combine(Path, "objects.phxmo")

	return Md5.ToHexLower(Misc.HashFiles({ MetadataPath, ObjectsPath }))
end

-- @src scripts/map/MapCache.cs:FetchAll L384-384
function MapCache.FetchAll(): { MapTypes.Map }
	return DatabaseService.All(MapsTable())
end

-- @src scripts/map/MapCache.cs:BackSlashToForwardSlash L386-386
function MapCache.BackSlashToForwardSlash(Path: string): string
	return DotnetString.Replace(Path, "\\", "/")
end

-- The row whose FolderPath is Path, or nil: DatabaseService.Connection.Table<Map>().FirstOrDefault(x => x.FolderPath == path)
-- in MapParser.PHXM.
function MapCache.FindByFolderPath(Path: string): MapTypes.Map?
	return DatabaseService.Find(MapsTable(), FieldIs("FolderPath", Path))
end

-- DateTime.ToString("O") of a local time (File.GetLastWriteTime, MapParser.cs L240-241), with the fraction zero. The same text
-- as MapParser's stored LastModified strings, so the sync compares them (Util/FileSystem gives whole seconds).
-- @src scripts/map/MapParser.cs:FormatLastWriteTime L240-241
function MapCache.FormatLastWriteTime(Seconds: number): string
	const Offset = os.date("%z", Seconds)

	return `{os.date("%Y-%m-%dT%H:%M:%S", Seconds)}.0000000{string.sub(Offset, 1, 3)}:{string.sub(Offset, 4, 5)}`
end

return MapCache
