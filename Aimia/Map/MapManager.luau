--!strict
--!optimize 2

--[[
	The loaded maps and the selection, as scripts/map/MapManager.cs (an autoload singleton: module state).

	Design Notes
		Initialize is _Ready: the cache is set up and loaded in the calling thread, then MapsInitialized fires once.
		Callable.From(...).CallDeferred() runs its call at once, in order, so the toast and MapDeleted fire at the end of
		Delete as they are queued upstream. DEVIATION(concurrency): no deferred frame here.
		This module registers itself on MapCache when it loads (ManagerHooks), and reads the parser through MapCache's
		ParserHooks (see MapCache's header for the cycle this avoids).
		DEVIATION(platform): InsertVideo gets the video's bytes; the source opens the file at a path the user picked.
		Upstream quirks kept: InsertVideo deletes the map folder without recursion (it throws while the folder has files)
		and stores the checksum of the folder in FolderPath; RemoveVideo throws on a folder path (File.Delete of a folder).
]]

const Bindable = require("../Util/Bindables/Bindable")
const DotnetString = require("../Dotnet/String")
const FileSystem = require("../Util/FileSystem")
const Logger = require("../Util/Logger")
const MapCache = require("./MapCache")
const MapTypes = require("./MapTypes")
const Notify = require("../Util/Notify")
const Signal = require("../Util/Signal")
const UtilString = require("../Util/String")


const MapManager = {
	Selected = Bindable.New(nil :: MapTypes.Map?),
	Maps = {} :: { MapTypes.Map },
	MapDeleted = Signal.New(),
	MapUpdated = Signal.New(),
	Initialized = false,
	MapsInitialized = Signal.New(),
	MapsFolder = MapCache.MapsFolder,
}

-- The parser hooks MapParser.luau registers; reading them before it loaded is an error.
const function RegisteredParser(): MapCache.ParserHooks
	const Hooks = MapCache.ParserHooks

	if Hooks == nil then
		error("MapParser has not been required: its hooks are not registered", 3)
	end

	return Hooks :: MapCache.ParserHooks
end

-- The folder of a map whose deletion failed is still there: the rest of Delete does not run (the C# return).
-- @src scripts/map/MapManager.cs:Delete L96-113
const function DeleteFolder(Map: MapTypes.Map): boolean
	const Deleted = pcall(FileSystem.DeleteDirectory, Map.FolderPath, true)

	if Deleted then
		if not FileSystem.DirectoryExists(Map.FolderPath) then
			Logger.Log(`{Map.Title} has been deleted`)
		end
	elseif FileSystem.Exists(Map.FolderPath) or FileSystem.DirectoryExists(Map.FolderPath) then
		Logger.Error("Unable to delete map")

		return false
	end

	return true
end

-- The try block of Delete: the folder, then the row and the list entry, then the deferred calls in order.
-- @src scripts/map/MapManager.cs:Delete L94-130
const function DeleteMap(Map: MapTypes.Map)
	if not DeleteFolder(Map) then
		return
	end

	MapCache.RemoveMap(Map)

	for Index = #MapManager.Maps, 1, -1 do
		if MapManager.Maps[Index].Id == Map.Id then
			table.remove(MapManager.Maps, Index)
		end
	end

	Notify.Notify(`Deleted {Map.PrettyTitle}!`)
	Signal.Fire(MapManager.MapDeleted, Map)
end

-- @src scripts/map/MapManager.cs:_Ready L22-35
function MapManager.Initialize()
	MapCache.Initialize()
	MapCache.Load(true)

	if not MapManager.Initialized then
		MapManager.Initialized = true
		Signal.Fire(MapManager.MapsInitialized, MapManager.Maps)
	end
end

-- @src scripts/map/MapManager.cs:Select L37-40
function MapManager.Select(Map: MapTypes.Map)
	Bindable.Set(MapManager.Selected, MapManager.GetMapById(Map.Id))
end

-- @src scripts/map/MapManager.cs:GetMapById L42-46
function MapManager.GetMapById(Id: number): MapTypes.Map?
	for _, Map in MapManager.Maps do
		if Map.Id == Id then
			return Map
		end
	end

	return nil
end

-- @src scripts/map/MapManager.cs:Update L48-52
function MapManager.Update(Map: MapTypes.Map)
	MapCache.UpdateMap(Map)
	Signal.Fire(MapManager.MapUpdated, Map)
end

-- @src scripts/map/MapManager.cs:InsertVideo L54-73
function MapManager.InsertVideo(Map: MapTypes.Map, VideoBuffer: buffer)
	const Parser = RegisteredParser()

	Map.VideoBuffer = VideoBuffer

	const OldMap = Parser.Decode(Map.FolderPath) :: MapTypes.Map

	Map.Mappers = DotnetString.Split(Map.CachedMappers, "_")
	Map.AudioBuffer = OldMap.AudioBuffer
	Map.CoverBuffer = OldMap.CoverBuffer

	FileSystem.DeleteDirectory(Map.FolderPath, nil)

	Parser.Encode(Map)
	Map.FolderPath = MapCache.GetMd5Checksum(Map.FolderPath)
	MapManager.Update(Map)
end

-- @src scripts/map/MapManager.cs:RemoveVideo L75-92
function MapManager.RemoveVideo(Map: MapTypes.Map)
	const Parser = RegisteredParser()

	-- The Godot.FileAccess.Open(FolderPath) of the source only discards its result: no effect here.
	Map.VideoBuffer = nil

	const OldMap = Parser.Decode(Map.FolderPath) :: MapTypes.Map

	Map.Mappers = DotnetString.Split(Map.PrettyMappers, " ")
	Map.AudioBuffer = OldMap.AudioBuffer
	Map.CoverBuffer = OldMap.CoverBuffer

	-- File.Delete of a folder throws in .NET (access denied); FileSystem.Delete would ignore it.
	if FileSystem.DirectoryExists(Map.FolderPath) then
		error(`Access to the path '{Map.FolderPath}' is denied.`, 0)
	end

	FileSystem.Delete(Map.FolderPath)

	Parser.Encode(Map)
	Map.MetadataObjectHash = MapCache.GetMd5Checksum(Map.FolderPath)
	MapManager.Update(Map)
end

-- @src scripts/map/MapManager.cs:Delete L94-130
function MapManager.Delete(Map: MapTypes.Map)
	const Success, Failure = pcall(DeleteMap, Map)

	if not Success then
		Logger.Error(tostring(Failure))
	end
end

-- @src scripts/map/MapManager.cs:Sanitize L132-149
function MapManager.Sanitize(Map: MapTypes.Map)
	const SanitizedTitle = UtilString.SanitizeZalgo(Map.PrettyTitle)
	const SanitizedMappers = UtilString.SanitizeZalgo(Map.PrettyMappers)
	const SanitizedDiffName = UtilString.SanitizeZalgo(Map.DifficultyName)

	const Updated = SanitizedTitle ~= Map.PrettyTitle
		or SanitizedMappers ~= Map.PrettyMappers
		or SanitizedDiffName ~= Map.DifficultyName

	if Updated then
		Map.PrettyTitle = SanitizedTitle
		Map.PrettyMappers = SanitizedMappers
		Map.DifficultyName = SanitizedDiffName

		MapManager.Update(Map)
		Logger.Log(`Sanitized map {Map.Name}`)
	end
end

-- Registers this module with MapCache: the list it publishes and the sanitizer it runs.
MapCache.ManagerHooks = MapManager

return MapManager
