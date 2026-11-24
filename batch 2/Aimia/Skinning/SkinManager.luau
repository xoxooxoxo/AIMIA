--!strict
--!optimize 2

--[[
	The skin of the running game: loads its config, textures, shaders, sounds, note colors, note mesh and spaces from the
	user folder, with the default skin as the fallback, and saves its config, as scripts/skinning/SkinManager.cs.

	Design Notes
		Skin is one SkinProfile kept across loads, as the source keeps its object: NoteColors keeps its value when the colorset
		file is missing. Save and Load take the settings profile, and Load takes whether to toast: SettingsManager owns both
		(its HideNotifications flag is set while a reset changes the skin) and calls them.
		A texture is the skin folder's file, decoded (Util/ImageDecode). Without that file, the default skin's file is decoded
		when it is in the FileSystem; otherwise it is a baked image, { Path = "res://user/skins/default/..." }, for the UI to draw,
		because the default skin's PNGs are not in the FileSystem. The source returns nil for a missing default image; the UI
		draws nothing for a Path it does not have.
		Shaders are read without a fallback, as the source does: a skin without its shader file fails to load.
		DEVIATION(phase 3): the note mesh is { Path, MtlPath } for the OBJ parser, and the spaces are scene paths. Only the
		waves space is ported (PortedSpaces); any other space resolves to void.tscn, which is not ported either.
		DEVIATION(audio): the sounds are the file bytes; audio is deferred.
]]

const Constants = require("../Constants")
const Color = require("../Godot/Color")
const DotnetString = require("../Dotnet/String")
const FileSystem = require("../Util/FileSystem")
const GodotString = require("../Godot/String")
const ImageDecode = require("../Util/ImageDecode")
const Logger = require("../Util/Logger")
const Misc = require("../Util/Misc")
const Notify = require("../Util/Notify")
const Signal = require("../Util/Signal")
const SettingsProfile = require("../Database/Settings/SettingsProfile")
const SkinConfig = require("./SkinConfig")
const SkinProfile = require("./SkinProfile")
const SkinSets = require("./SkinSets")

const VoidSpace = "res://prefabs/spaces/void.tscn"

-- The spaces that have a port (Spaces/). Any other space resolves to VoidSpace.
const PortedSpaces = {
	["res://prefabs/spaces/waves.tscn"] = true,
}

const SkinManager = {
	Skin = SkinProfile(),
	Saved = Signal.New() :: Signal.Signal<()>,
	Loaded = Signal.New() :: Signal.Signal<SkinProfile.SkinProfile>,
}

-- The note mesh and colors the skin had before a listed run's replay put its player's look on (WearNoteLook), or nil.
local Worn: { Mesh: SkinProfile.Mesh, Colors: { Color.Color } }? = nil

-- The image of a file, or nil when the decoder does not read it (Image.LoadFromFile answers null).
const function DecodeFile(Path: string): SkinProfile.Texture?
	const Image = ImageDecode.Decode(FileSystem.ReadAllBytes(Path))

	if not Image then
		return nil
	end

	return { Image = Image }
end

-- @src scripts/skinning/SkinManager.cs:loadTexture L189-213
const function LoadTexture(SkinName: string, SkinPath: string): SkinProfile.Texture?
	const FullPath = `{Constants.UserFolder}/skins/{SkinName}/{SkinPath}`

	if FileSystem.Exists(FullPath) then
		return DecodeFile(FullPath)
	end

	const FallbackPath = `{Constants.UserFolder}/skins/default/{SkinPath}`

	if FileSystem.Exists(FallbackPath) then
		return DecodeFile(FallbackPath)
	end

	return { Path = `res://{FallbackPath}` }
end

-- @src scripts/skinning/SkinManager.cs:loadSound L215-229
const function LoadSound(SkinName: string, SkinPath: string): buffer
	const Path = `{Constants.UserFolder}/skins/{SkinName}/{SkinPath}`

	if FileSystem.Exists(Path) then
		return FileSystem.ReadAllBytes(Path)
	end

	return buffer.create(0)
end

-- @src scripts/skinning/SkinManager.cs:loadShader L231-237
const function LoadShader(SkinName: string, SkinPath: string): string
	return FileSystem.ReadAllText(`{Constants.UserFolder}/skins/{SkinName}/{SkinPath}`)
end

-- @src scripts/skinning/SkinManager.cs:loadMesh L239-246
const function LoadMesh(Path: string): SkinProfile.Mesh
	const MtlPath = `{GodotString.TrimSuffix(Path, ".obj")}.mtl`

	if FileSystem.Exists(Path) then
		return {
			Path = Path,
			MtlPath = if FileSystem.Exists(MtlPath) then MtlPath else nil,
		}
	end

	-- (not in the source: a skin set's flat note picture, drawn by Game/View/NoteRenderer on quads)
	const PictureName = FileSystem.GetFileNameWithoutExtension(Path)

	if SkinSets.NotePicture(PictureName) then
		return { Path = `picture://{PictureName}` }
	end

	return { Path = "res://user/meshes/squircle.obj" }
end

-- @src scripts/skinning/SkinManager.cs:loadSpace L248-251
const function LoadSpace(Path: string): string
	if PortedSpaces[Path] then
		return Path
	end

	return VoidSpace
end

-- The colors of a colorset file (SkinManager.Load): the text stripped, its line endings read as commas, then one
-- ParseColor per entry, with white for an entry that is not a color. The line endings are those of .NET's
-- ReplaceLineEndings (checked with external/Oracle/Cases/Managers.cs): CRLF is one comma; CR, LF, form feed, NEL, LS and PS
-- are one comma each; vertical tab is kept.
const function ParseColorset(Text: string): { Color.Color }
	const Stripped = GodotString.StripEdges(Text)
	const CrLf = string.gsub(Stripped, "\r\n", ",")
	const LineBreaks = string.gsub(CrLf, "[\r\n\f]", ",")
	const Separators = string.gsub(LineBreaks, "\u{85}", ",")
	const Joined = string.gsub(string.gsub(Separators, "\u{2028}", ","), "\u{2029}", ",")
	const Colors: { Color.Color } = {}

	for _, Entry in DotnetString.Split(Joined, ",") do
		table.insert(Colors, Misc.ParseColor(Entry, Color.New(1, 1, 1)))
	end

	return Colors
end

-- @src scripts/skinning/SkinManager.cs:Save L23-36
function SkinManager.Save(Settings: SettingsProfile.SettingsProfile)
	const Name = Settings.Skin.Value

	FileSystem.WriteAllText(`{Constants.UserFolder}/skins/{Name}/config.toml`, SkinConfig.Write(SkinManager.Skin.Config))
	Logger.Log(`Saved skin {Name}`)
	Signal.Fire(SkinManager.Saved)
end

-- @src scripts/skinning/SkinManager.cs:Load L38-181
function SkinManager.Load(Settings: SettingsProfile.SettingsProfile, ShowToast: boolean)
	const Skin = SkinManager.Skin

	-- (a load sets the mesh and colors afresh from the settings: a look worn before it has nothing left to put back)
	Worn = nil
	const Name = Settings.Skin.Value
	const ConfigPath = `{Constants.UserFolder}/skins/{Name}/config.toml`

	-- Config: a file that does not parse is replaced by the default config, as the source writes it back.
	Skin.Config = SkinConfig.New()

	const Parsed = if FileSystem.Exists(ConfigPath) then SkinConfig.Parse(FileSystem.ReadAllText(ConfigPath)) else nil

	if Parsed then
		Skin.Config = Parsed
	else
		FileSystem.WriteAllText(ConfigPath, SkinConfig.Write(Skin.Config))
	end

	-- Textures

	Skin.CursorImage = LoadTexture(Name, "game/cursor.png")
	Skin.GridImage = LoadTexture(Name, "game/grid.png")
	Skin.GridGuidesImage = LoadTexture(Name, "game/grid_guides.png")
	Skin.VisibilityAssistImage = LoadTexture(Name, "game/visibility_assist.png")
	Skin.PanelLeftBackgroundImage = LoadTexture(Name, "game/panel_left_background.png")
	Skin.PanelRightBackgroundImage = LoadTexture(Name, "game/panel_right_background.png")
	Skin.HealthImage = LoadTexture(Name, "game/health.png")
	Skin.HealthBackgroundImage = LoadTexture(Name, "game/health_background.png")
	Skin.ProgressImage = LoadTexture(Name, "game/progress.png")
	Skin.ProgressBackgroundImage = LoadTexture(Name, "game/progress_background.png")
	Skin.HitsImage = LoadTexture(Name, "game/hits.png")
	Skin.MissesImage = LoadTexture(Name, "game/misses.png")
	Skin.MissFeedbackImage = LoadTexture(Name, "game/miss_feedback.png")

	Skin.SettingsButtonImage = LoadTexture(Name, "ui/buttons/settings.png")
	Skin.OpenFolderButtonImage = LoadTexture(Name, "ui/buttons/open_folder.png")
	Skin.ImportButtonImage = LoadTexture(Name, "ui/buttons/import.png")
	Skin.RandomButtonImage = LoadTexture(Name, "ui/buttons/random.png")
	Skin.FilterButtonImage = LoadTexture(Name, "ui/buttons/filter.png")
	Skin.SortButtonImage = LoadTexture(Name, "ui/buttons/sort.png")
	Skin.SortAscendButtonImage = LoadTexture(Name, "ui/buttons/sort_ascend.png")
	Skin.AuthorButtonImage = LoadTexture(Name, "ui/buttons/author.png")
	Skin.SearchButtonImage = LoadTexture(Name, "ui/buttons/search.png")
	Skin.LayoutListButtonImage = LoadTexture(Name, "ui/buttons/layout_list.png")
	Skin.LayoutGridButtonImage = LoadTexture(Name, "ui/buttons/layout_grid.png")

	Skin.SpeedPresetMinusMinusButtonImage = LoadTexture(Name, "ui/buttons/speed_minus_minus.png")
	Skin.SpeedPresetMinusButtonImage = LoadTexture(Name, "ui/buttons/speed_minus.png")
	Skin.SpeedPresetMiddleButtonImage = LoadTexture(Name, "ui/buttons/speed_middle.png")
	Skin.SpeedPresetPlusButtonImage = LoadTexture(Name, "ui/buttons/speed_plus.png")
	Skin.SpeedPresetPlusPlusButtonImage = LoadTexture(Name, "ui/buttons/speed_plus_plus.png")

	Skin.PlayButtonImage = LoadTexture(Name, "ui/buttons/play.png")
	Skin.FavoriteButtonImage = LoadTexture(Name, "ui/buttons/favorite.png")
	Skin.UnfavoriteButtonImage = LoadTexture(Name, "ui/buttons/unfavorite.png")
	Skin.CopyButtonImage = LoadTexture(Name, "ui/buttons/copy.png")
	Skin.DeleteButtonImage = LoadTexture(Name, "ui/buttons/delete.png")
	Skin.AddVideoButtonImage = LoadTexture(Name, "ui/buttons/add_video.png")
	Skin.RemoveVideoButtonImage = LoadTexture(Name, "ui/buttons/remove_video.png")

	Skin.GrabberNormalImage = LoadTexture(Name, "ui/buttons/grabber_normal.png")
	Skin.GrabberPressedImage = LoadTexture(Name, "ui/buttons/grabber_pressed.png")
	Skin.GrabberTickImage = LoadTexture(Name, "ui/buttons/grabber_tick.png")

	Skin.JukeboxPlayImage = LoadTexture(Name, "ui/jukebox_play.png")
	Skin.JukeboxPauseImage = LoadTexture(Name, "ui/jukebox_pause.png")
	Skin.JukeboxSkipImage = LoadTexture(Name, "ui/jukebox_skip.png")
	Skin.BackgroundTileImage = LoadTexture(Name, "ui/background_tile.png")

	Skin.FavoriteImage = LoadTexture(Name, "ui/play/favorite.png")
	Skin.MapListMaskImage = LoadTexture(Name, "ui/play/maplist_mask.png")
	Skin.MapListSelectionCursorImage = LoadTexture(Name, "ui/play/maplist_selection_cursor.png")
	Skin.MapListScrollBarTopImage = LoadTexture(Name, "ui/play/scrollbar_top.png")
	Skin.MapListScrollBarMiddleImage = LoadTexture(Name, "ui/play/scrollbar_middle.png")
	Skin.MapListScrollBarBottomImage = LoadTexture(Name, "ui/play/scrollbar_bottom.png")
	Skin.MapListScrollBarBackgroundTopImage = LoadTexture(Name, "ui/play/scrollbar_background_top.png")
	Skin.MapListScrollBarBackgroundMiddleImage = LoadTexture(Name, "ui/play/scrollbar_background_middle.png")
	Skin.MapListScrollBarBackgroundBottomImage = LoadTexture(Name, "ui/play/scrollbar_background_bottom.png")
	Skin.MapListGridCoverBackgroundImage = LoadTexture(Name, "ui/play/grid_cover_background.png")

	Skin.MapInfoCoverBackgroundImage = LoadTexture(Name, "ui/play/mapinfo_cover_background.png")

	Skin.ModNoFailImage = LoadTexture(Name, "modifiers/nofail.png")
	Skin.ModAutoplayImage = LoadTexture(Name, "modifiers/autoplay.png")
	Skin.ModGhostImage = LoadTexture(Name, "modifiers/ghost.png")
	Skin.ModStrobeImage = LoadTexture(Name, "modifiers/strobe.png")
	Skin.ModChaosImage = LoadTexture(Name, "modifiers/chaos.png")
	Skin.ModVortexImage = LoadTexture(Name, "modifiers/vortex.png")
	Skin.ModEarthquakeImage = LoadTexture(Name, "modifiers/earthquake.png")
	Skin.ModHFlipImage = LoadTexture(Name, "modifiers/hflip.png")
	Skin.ModVFlipImage = LoadTexture(Name, "modifiers/vflip.png")

	-- Shaders

	Skin.BackgroundTileShader = LoadShader(Name, "ui/background_tile.gdshader")
	Skin.MapButtonCoverShader = LoadShader(Name, "ui/play/map_button_cover.gdshader")

	-- Sounds

	Skin.HitSoundBuffer = LoadSound(Name, "hit.mp3")
	Skin.MissSoundBuffer = LoadSound(Name, "miss.mp3")
	Skin.FailSoundBuffer = LoadSound(Name, "fail.mp3")
	Skin.MenuMusicBuffer = LoadSound(Name, "menu.mp3")

	-- Mesh

	const MeshName = if Settings.NoteMesh.Value == "skin" then Skin.Config.NoteMesh else Settings.NoteMesh.Value

	Skin.NoteMesh = LoadMesh(`{Constants.UserFolder}/meshes/{MeshName}.obj`)

	-- Colors: kept when the colorset file is missing, as the source keeps the previous NoteColors.

	const ColorsetName = if Settings.NoteColors.Value == "skin" then Skin.Config.NoteColors else Settings.NoteColors.Value
	const ColorsetPath = `{Constants.UserFolder}/colorsets/{ColorsetName}.txt`

	if FileSystem.Exists(ColorsetPath) then
		Skin.NoteColors = ParseColorset(FileSystem.ReadAllText(ColorsetPath))
	end

	-- Spaces

	const GameName = if Settings.GameSpace.Value == "skin" then Skin.Config.GameSpace else Settings.GameSpace.Value
	const MenuName = if Settings.MenuSpace.Value == "skin" then Skin.Config.MenuSpace else Settings.MenuSpace.Value

	Skin.GameSpace = LoadSpace(`res://prefabs/spaces/{GameName}.tscn`)
	Skin.MenuSpace = LoadSpace(`res://prefabs/spaces/{MenuName}.tscn`)

	if ShowToast then
		Notify.Notify(`Loaded skin [{Name}]`)
	end

	Logger.Log(`Loaded skin {Name}`)
	Signal.Fire(SkinManager.Loaded, Skin)
end

-- The note mesh and colors a profile asks for, without loading them into the skin (nil colors: the colorset file is missing).
function SkinManager.NoteLookOf(Settings: SettingsProfile.SettingsProfile): (SkinProfile.Mesh, { Color.Color }?)
	const Skin = SkinManager.Skin
	const MeshName = if Settings.NoteMesh.Value == "skin" then Skin.Config.NoteMesh else Settings.NoteMesh.Value
	const ColorsetName = if Settings.NoteColors.Value == "skin" then Skin.Config.NoteColors else Settings.NoteColors.Value
	const ColorsetPath = `{Constants.UserFolder}/colorsets/{ColorsetName}.txt`

	return LoadMesh(`{Constants.UserFolder}/meshes/{MeshName}.obj`), if FileSystem.Exists(ColorsetPath) then ParseColorset(FileSystem.ReadAllText(ColorsetPath)) else nil
end

-- A listed run's replay shows its player's note mesh and colors (Menu/LeaderboardsMenu), as watching a song live does; the
-- skin's own come back with TakeOffNoteLook. Wearing a second look keeps the first saved, so the skin's own always come back.
function SkinManager.WearNoteLook(Settings: SettingsProfile.SettingsProfile)
	const Skin = SkinManager.Skin
	const Mesh, Colors = SkinManager.NoteLookOf(Settings)

	if not Worn then
		Worn = { Mesh = Skin.NoteMesh, Colors = Skin.NoteColors }
	end

	Skin.NoteMesh = Mesh
	Skin.NoteColors = Colors or (Worn :: any).Colors
end

-- Puts the skin's own note mesh and colors back after WearNoteLook (nothing when no look is on).
function SkinManager.TakeOffNoteLook()
	const Was = Worn

	if Was then
		Worn = nil
		SkinManager.Skin.NoteMesh = Was.Mesh
		SkinManager.Skin.NoteColors = Was.Colors
	end
end

-- @src scripts/skinning/SkinManager.cs:Reload L183-187
function SkinManager.Reload(Settings: SettingsProfile.SettingsProfile, ShowToast: boolean)
	SkinManager.Save(Settings)
	SkinManager.Load(Settings, ShowToast)
end

return SkinManager
