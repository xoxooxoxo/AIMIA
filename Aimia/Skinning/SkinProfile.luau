--!strict
--!optimize 2

--[[
	The loaded skin: its config, textures, shader sources, sounds, note colors, note mesh and spaces, as
	scripts/skinning/SkinProfile.cs.

	Representation
		A texture is { Path } for a baked default-skin image, which the UI draws from its res:// path, or { Image } for a file
		decoded by Util/ImageDecode. A shader is its source text. A sound is its file bytes (audio is deferred). The note mesh
		is the OBJ path and its MTL path for the OBJ parser (phase 3). A space is the path of its scene, which the space owner
		builds (phase 3).

	Design Notes
		Textures, shaders, sounds, the note mesh and the spaces are nil until SkinManager.Load assigns them: the C# default
		objects are empty and nothing reads them before a load. Config and NoteColors keep the C# defaults.
]]

const Color = require("../Godot/Color")
const SkinConfig = require("./SkinConfig")

export type Image = {
	Width: number,
	Height: number,
	Pixels: buffer,
}

export type Texture = {
	Path: string?,
	Image: Image?,
}

export type Mesh = {
	Path: string,
	MtlPath: string?,
}

export type SkinProfile = {
	Config: SkinConfig.SkinConfig,
	CursorImage: Texture?,
	GridImage: Texture?,
	GridGuidesImage: Texture?,
	VisibilityAssistImage: Texture?,
	PanelLeftBackgroundImage: Texture?,
	PanelRightBackgroundImage: Texture?,
	HealthImage: Texture?,
	HealthBackgroundImage: Texture?,
	ProgressImage: Texture?,
	ProgressBackgroundImage: Texture?,
	HitsImage: Texture?,
	MissesImage: Texture?,
	MissFeedbackImage: Texture?,
	SettingsButtonImage: Texture?,
	OpenFolderButtonImage: Texture?,
	ImportButtonImage: Texture?,
	RandomButtonImage: Texture?,
	FilterButtonImage: Texture?,
	SortButtonImage: Texture?,
	SortAscendButtonImage: Texture?,
	AuthorButtonImage: Texture?,
	SearchButtonImage: Texture?,
	LayoutListButtonImage: Texture?,
	LayoutGridButtonImage: Texture?,
	SpeedPresetMinusMinusButtonImage: Texture?,
	SpeedPresetMinusButtonImage: Texture?,
	SpeedPresetMiddleButtonImage: Texture?,
	SpeedPresetPlusButtonImage: Texture?,
	SpeedPresetPlusPlusButtonImage: Texture?,
	PlayButtonImage: Texture?,
	FavoriteButtonImage: Texture?,
	UnfavoriteButtonImage: Texture?,
	CopyButtonImage: Texture?,
	DeleteButtonImage: Texture?,
	AddVideoButtonImage: Texture?,
	RemoveVideoButtonImage: Texture?,
	GrabberNormalImage: Texture?,
	GrabberPressedImage: Texture?,
	GrabberTickImage: Texture?,
	JukeboxPlayImage: Texture?,
	JukeboxPauseImage: Texture?,
	JukeboxSkipImage: Texture?,
	FavoriteImage: Texture?,
	MapListMaskImage: Texture?,
	MapListSelectionCursorImage: Texture?,
	MapListScrollBarTopImage: Texture?,
	MapListScrollBarMiddleImage: Texture?,
	MapListScrollBarBottomImage: Texture?,
	MapListScrollBarBackgroundTopImage: Texture?,
	MapListScrollBarBackgroundMiddleImage: Texture?,
	MapListScrollBarBackgroundBottomImage: Texture?,
	MapListGridCoverBackgroundImage: Texture?,
	MapInfoCoverBackgroundImage: Texture?,
	ModNoFailImage: Texture?,
	ModAutoplayImage: Texture?,
	ModGhostImage: Texture?,
	ModStrobeImage: Texture?,
	ModChaosImage: Texture?,
	ModVortexImage: Texture?,
	ModEarthquakeImage: Texture?,
	ModHFlipImage: Texture?,
	ModVFlipImage: Texture?,
	BackgroundTileImage: Texture?,
	BackgroundTileShader: string?,
	MapButtonCoverShader: string?,
	HitSoundBuffer: buffer?,
	MissSoundBuffer: buffer?,
	FailSoundBuffer: buffer?,
	MenuMusicBuffer: buffer?,
	NoteColors: { Color.Color },
	NoteMesh: Mesh?,
	MenuSpace: string?,
	GameSpace: string?,
}

-- @src scripts/skinning/SkinProfile.cs:SkinProfile L4-153
const function New(): SkinProfile
	return {
		Config = SkinConfig.New(),
		NoteColors = {
			Color.FromRgba(0xff0059),
			Color.FromRgba(0xffd8e6),
		},
	}
end

return New
