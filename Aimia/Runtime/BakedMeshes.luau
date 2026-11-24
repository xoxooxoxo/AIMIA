--!strict
--!optimize 2

--[[
	Mounts the baked note meshes (AimiaData/Meshes, from external/Bake/BakeMeshes.mjs) in <UserFolder>/meshes of Util/FileSystem,
	where SkinManager looks for the skin's note mesh (squircle.obj by default).

	Design Notes
		Mount, not WriteAllBytes: the files are game data, so the FileSystem Changed signal (persistence) does not fire.
		Call it once at start, before the skin is loaded.
]]

const Constants = require("../Constants")
const FileSystem = require("../Util/FileSystem")
const MeshFiles = require("../../AimiaData/Meshes")

const function Mount()
	for Name, Text in MeshFiles do
		FileSystem.Mount(`{Constants.UserFolder}/meshes/{Name}`, buffer.fromstring(Text))
	end
end

return Mount
