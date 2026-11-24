--!strict
--!optimize 2

--[[
	Creates the user folder with its folders and default files at start, as scripts/FileInitializer.cs (the copy of
	res://user in _Ready).

	Design Notes
		Only missing files are copied, as the source does, so a file the host restored before this runs is kept. The defaults
		are mounted without a Changed event: they are rebuilt on every start, so the host does not need to persist them.
		DEVIATION(platform): skin PNGs are not copied; SkinManager resolves them from their baked res:// paths. Audio
		(skins/default/*.mp3, ui/menu.mp3) is not copied: audio is deferred. The OBJExporter script is not needed: the
		meshes are copied as their OBJ text, and the source only saves ArrayMesh resources it could not copy.
]]

const Constants = require("./Constants")
const FileInitializerData = require("./FileInitializerData") :: { [string]: string }
const FileSystem = require("./Util/FileSystem")

-- The folders of res://user below the user folder, parents before children (the empty ones keep a .gitkeep upstream).
const Folders = {
	"cache",
	"cache/maps",
	"colorsets",
	"maps",
	"maps/default",
	"meshes",
	"pbs",
	"profiles",
	"replays",
	"screenshots",
	"skins",
	"skins/default",
	"skins/default/game",
	"skins/default/modifiers",
	"skins/default/ui",
	"skins/default/ui/buttons",
	"skins/default/ui/play",
	"spaces",
}

-- @src scripts/FileInitializer.cs:_Ready L9-24
-- @src scripts/FileInitializer.cs:deepCopy L26-92
const function Initialize()
	const Squircle = FileSystem.Combine(Constants.UserFolder, "meshes/squircle.obj")

	-- Temporary for 0.1.2 as the mesh's faces were fixed
	if FileSystem.Exists(Squircle) then
		FileSystem.Delete(Squircle)
	end

	FileSystem.CreateDirectory(Constants.UserFolder)

	for _, Folder in Folders do
		FileSystem.CreateDirectory(FileSystem.Combine(Constants.UserFolder, Folder))
	end

	for Relative, Text in FileInitializerData do
		const Path = FileSystem.Combine(Constants.UserFolder, Relative)

		if not FileSystem.Exists(Path) then
			FileSystem.Mount(Path, buffer.fromstring(Text))
		end
	end
end

return Initialize
