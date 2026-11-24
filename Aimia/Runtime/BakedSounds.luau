--!strict
--!optimize 2

--[[
	Mounts the baked skin sounds (AimiaData/Sounds, from external/Bake/BakeSounds.mjs) in the default skin's folder of
	Util/FileSystem: each file's bytes are decoded (Base64, then Zstd) and mounted at <UserFolder>/skins/default/<name>, where
	SkinManager reads them (hit.mp3, miss.mp3, fail.mp3, menu.mp3).

	Design Notes
		Mount, not WriteAllBytes: the files are game data, so the FileSystem Changed signal (persistence) does not fire.
		Call it once at start, before the skin is loaded.
]]

const EncodingService = game:GetService("EncodingService")

const Constants = require("../Constants")
const FileSystem = require("../Util/FileSystem")
const SoundFiles = require("../../AimiaData/Sounds")

const function Mount()
	for _, File in SoundFiles do
		const Encoded = buffer.fromstring(table.concat(File.Parts))
		const Compressed = EncodingService:Base64Decode(Encoded)

		FileSystem.Mount(`{Constants.UserFolder}/skins/default/{File.Name}`, EncodingService:DecompressBuffer(Compressed, Enum.CompressionAlgorithm.Zstd))
	end
end

return Mount
