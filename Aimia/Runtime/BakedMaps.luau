--!strict
--!optimize 2

--[[
	Imports the map files in ReplicatedStorage/AimiaContent/Maps (baked by external/Bake/BakeMaps.mjs, or put there by the
	Aimia Map Tool): each Folder in it is one map file, named as the file, and its ModuleScripts, in name order, are the
	Base64 of the file's Zstd-compressed bytes. A StringValue in the folder is the map's sound: its name is the audio key ("<md5>.mp3") and its
	value the Roblox sound id; it is added to AimiaContent/AudioAssets before the map plays. The bytes are decoded, mounted at <UserFolder>/import/<folder name> in
	Util/FileSystem and handed to MapParser.BulkImport, which decodes and encodes them into <UserFolder>/maps and the map cache,
	as importing dropped files does upstream.

	Design Notes
		There is no list of the files: the folders found are the maps, so a map is added by adding a folder. Anything that is not a
		Folder in Maps, and anything that is not a ModuleScript in a folder, is ignored. Without a AimiaContent folder (or a Maps in
		it) there is nothing to import.
		Mount, not WriteAllBytes: the files are game data, so the FileSystem Changed signal (persistence) does not fire.
		Import yields only where MapParser does; call it once at start, after MapManager.Initialize.
]]

const EncodingService = game:GetService("EncodingService")
const ReplicatedStorage = game:GetService("ReplicatedStorage")

const Constants = require("../Constants")
const FileSystem = require("../Util/FileSystem")
const MapCache = require("../Map/MapCache")
const MapManager = require("../Map/MapManager")
const MapParser = require("../Map/MapParser")
const AudioAssets = require("../../AimiaContent/AudioAssets")
const AudioGains = require("../../AimiaContent/AudioGains")

-- The children of a container that are of a class, in name order.
const function ChildrenOf(Container: Instance, Class: string): { Instance }
	const Found: { Instance } = {}

	for _, Child in Container:GetChildren() do
		if Child:IsA(Class) then
			table.insert(Found, Child)
		end
	end

	table.sort(Found, function(A: Instance, B: Instance): boolean
		return A.Name < B.Name
	end)

	return Found
end

-- The Base64 text of a map's parts, in order.
const function EncodedOf(Folder: Instance): string
	const Parts: { string } = {}

	for _, Part in ChildrenOf(Folder, "ModuleScript") do
		const Text: unknown = require(Part :: ModuleScript)

		if type(Text) == "string" then
			table.insert(Parts, Text)
		end
	end

	return table.concat(Parts)
end

const function Import(): { string }
	const Paths: { string } = {}
	const Content = ReplicatedStorage:FindFirstChild("AimiaContent")
	const Maps = if Content then Content:FindFirstChild("Maps") else nil

	if Maps then
		for _, Folder in ChildrenOf(Maps, "Folder") do
			const Path = `{Constants.UserFolder}/import/{Folder.Name}`

			-- (a folder that doesn't open, like one whose parts are still being added, is skipped: it used to stop AIMIA from
			-- starting at all)
			const Opened, Problem = pcall(function()
				const Compressed = EncodingService:Base64Decode(buffer.fromstring(EncodedOf(Folder)))

				FileSystem.Mount(Path, EncodingService:DecompressBuffer(Compressed, Enum.CompressionAlgorithm.Zstd))
			end)

			if Opened then
				for _, Sound in ChildrenOf(Folder, "StringValue") do
					AudioAssets[Sound.Name] = (Sound :: StringValue).Value
				end

				-- A Sound can stand in for the StringValue: its name is the audio key, its SoundId the song, and its Volume how
				-- loud the song plays (1 = as uploaded, up to 10). Its PlaybackSpeed is not used: a song always plays at its own
				-- speed, which the notes are timed to.
				for _, Sound in ChildrenOf(Folder, "Sound") do
					const Id = (Sound :: Sound).SoundId

					if Id ~= "" then
						AudioAssets[Sound.Name] = Id
						AudioGains[Id] = math.clamp((Sound :: Sound).Volume, 0, 10)
					end
				end

				table.insert(Paths, Path)
			else
				warn(`[AIMIA] skipped the map folder {Folder.Name}: {Problem}`)
			end
		end
	end

	if #Paths > 0 then
		MapParser.BulkImport(Paths, false)

		-- The Play menu's list reloads the cache when an import finishes (MapList), but it does not exist yet at start.
		MapCache.Load(false)

		if MapManager.Selected.Value == nil and #MapManager.Maps > 0 then
			MapManager.Select(MapManager.Maps[1])
		end
	end

	return Paths
end

return Import
