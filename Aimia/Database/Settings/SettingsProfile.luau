--!strict
--!optimize 2

--[[
	The settings profile, as scripts/database/settings/SettingsProfile.cs: every item, the section list and the hooks to
	the systems the items drive.

	Design Notes
		Items are fields of the profile; closures read them through it (Profile.FPS), as C# reads its properties.
		Order is the declaration order (what GetProperties and the [Order] line numbers give). It holds the property
		names, which are the keys of the settings file (NoteColors); an item's Id is separate (Colors).
		Hooks are set by the systems that own the work. An unset hook is not called. CurrentSettings (SettingsManager's
		profile) defaults to this profile.
		Not ported: SpaceToPause, VideoDim and VideoRenderScale (commented out upstream); ImportFromNightlySettings (it reads
		the nightly folder, an OS path that Constants does not port, and needs SoundManager.ComputeVolumeFromDb).
]]

const Numbers = require("../../Numbers")
const Constants = require("../../Constants")
const FileSystem = require("../../Util/FileSystem")
const NewButton = require("./SettingsButton")
const SettingsItem = require("./SettingsItem")
const NewList = require("./SettingsList")
const SettingsSection = require("./SettingsSection")
const NewSlider = require("./SettingsSlider")
const SkinSets = require("../../Skinning/SkinSets")

-- Items by property name: the names of Order index the profile (ItemNamed), so the table has an unknown indexer.
export type SettingsProfile = {
	[string]: unknown,
	Sensitivity: SettingsItem.SettingsItem<number>,
	AbsoluteSensitivity: SettingsItem.SettingsItem<number>,
	AbsoluteInput: SettingsItem.SettingsItem<boolean>,
	VerticalSensitivity: SettingsItem.SettingsItem<number>,
	CursorDrift: SettingsItem.SettingsItem<boolean>,
	EdgeOvershoot: SettingsItem.SettingsItem<number>,
	ApproachRate: SettingsItem.SettingsItem<number>,
	ApproachDistance: SettingsItem.SettingsItem<number>,
	ApproachTime: SettingsItem.SettingsItem<number>,
	FadeIn: SettingsItem.SettingsItem<number>,
	FadeOut: SettingsItem.SettingsItem<number>,
	Pushback: SettingsItem.SettingsItem<boolean>,
	CameraParallax: SettingsItem.SettingsItem<number>,
	HUDParallax: SettingsItem.SettingsItem<number>,
	FoV: SettingsItem.SettingsItem<number>,
	MenuScale: SettingsItem.SettingsItem<number>,
	HudScale: SettingsItem.SettingsItem<number>,
	Skin: SettingsItem.SettingsItem<string>,
	MenuSpace: SettingsItem.SettingsItem<string>,
	GameSpace: SettingsItem.SettingsItem<string>,
	SpaceColor: SettingsItem.SettingsItem<string>,
	SpaceHitEffects: SettingsItem.SettingsItem<boolean>,
	SpaceEffects: SettingsItem.SettingsItem<boolean>,
	NoteColors: SettingsItem.SettingsItem<string>,
	NoteOpacity: SettingsItem.SettingsItem<number>,
	NoteOpacityExponent: SettingsItem.SettingsItem<number>,
	NoteMesh: SettingsItem.SettingsItem<string>,
	NoteSize: SettingsItem.SettingsItem<number>,
	NoteGlow: SettingsItem.SettingsItem<boolean>,
	NoteGlowStrength: SettingsItem.SettingsItem<number>,
	NoteGlowFade: SettingsItem.SettingsItem<boolean>,
	CursorStyle: SettingsItem.SettingsItem<string>,
	CursorColor: SettingsItem.SettingsItem<string>,
	CursorScale: SettingsItem.SettingsItem<number>,
	CursorOpacity: SettingsItem.SettingsItem<number>,
	CursorRotation: SettingsItem.SettingsItem<number>,
	CursorTrail: SettingsItem.SettingsItem<boolean>,
	TrailTime: SettingsItem.SettingsItem<number>,
	TrailDetail: SettingsItem.SettingsItem<number>,
	TrailImage: SettingsItem.SettingsItem<string>,
	TrailSpacing: SettingsItem.SettingsItem<number>,
	TrailShrink: SettingsItem.SettingsItem<boolean>,
	TrailOpacity: SettingsItem.SettingsItem<number>,
	TrailColor: SettingsItem.SettingsItem<string>,
	TrailPreset: SettingsItem.SettingsItem<string>,
	UseCursorInMenus: SettingsItem.SettingsItem<boolean>,
	HPLerpValue: SettingsItem.SettingsItem<number>,
	GridGuides: SettingsItem.SettingsItem<boolean>,
	GridGuidesOff: SettingsItem.SettingsItem<boolean>,
	Border: SettingsItem.SettingsItem<string>,
	SimpleHUD: SettingsItem.SettingsItem<boolean>,
	SuperSimpleHUD: SettingsItem.SettingsItem<boolean>,
	AltComboCounter: SettingsItem.SettingsItem<boolean>,
	VisibilityAssist: SettingsItem.SettingsItem<boolean>,
	HitPopups: SettingsItem.SettingsItem<boolean>,
	MissPopups: SettingsItem.SettingsItem<boolean>,
	Popups: SettingsItem.SettingsItem<string>,
	Fullscreen: SettingsItem.SettingsItem<boolean>,
	BorderlessFullscreen: SettingsItem.SettingsItem<boolean>,
	LockFPS: SettingsItem.SettingsItem<boolean>,
	FPS: SettingsItem.SettingsItem<number>,
	VSyncMenus: SettingsItem.SettingsItem<boolean>,
	AntiAliasing: SettingsItem.SettingsItem<string>,
	VolumeMaster: SettingsItem.SettingsItem<number>,
	VolumeMusic: SettingsItem.SettingsItem<number>,
	VolumeSFX: SettingsItem.SettingsItem<number>,
	VolumeHitSound: SettingsItem.SettingsItem<number>,
	VolumeMissSound: SettingsItem.SettingsItem<number>,
	VolumeMenuMusic: SettingsItem.SettingsItem<number>,
	AlwaysPlayHitSound: SettingsItem.SettingsItem<boolean>,
	EnableHitSound: SettingsItem.SettingsItem<boolean>,
	EnableMissSound: SettingsItem.SettingsItem<boolean>,
	EnableMenuMusic: SettingsItem.SettingsItem<boolean>,
	AutoplayJukebox: SettingsItem.SettingsItem<boolean>,
	LocalOffset: SettingsItem.SettingsItem<number>,
	SetUserFolderPath: SettingsItem.SettingsItem<string>,
	SetUserFolderDialog: SettingsItem.SettingsItem<unknown>,
	DisplayFPS: SettingsItem.SettingsItem<boolean>,
	HideSpectators: SettingsItem.SettingsItem<boolean>,
	ImportNightlyProfile: SettingsItem.SettingsItem<unknown>,
	NightlyImportDialog: SettingsItem.SettingsItem<unknown>,
	ImportNightlyMeshes: SettingsItem.SettingsItem<unknown>,
	ImportNightlyColorsets: SettingsItem.SettingsItem<unknown>,
	RecordReplays: SettingsItem.SettingsItem<boolean>,
	OptionalPlaytestParameters: SettingsItem.SettingsItem<boolean>,
	ResetToDefaults: SettingsItem.SettingsItem<unknown>,
}

-- The systems the items call. Each is set by its owner; an unset hook is not called.
export type ProfileHooks = {
	CurrentSettings: (() -> SettingsProfile)?,
	LoadSettings: (() -> ())?,
	LoadSkin: (() -> ())?,
	UpdateVolume: (() -> ())?,
	RefreshMenuMusicPlayback: (() -> ())?,
	ResetToDefaults: (() -> ())?,
	SetUserFolder: ((Path: string) -> ())?,
	IsGameScene: (() -> boolean)?,
	RefreshSettingsList: ((Item: SettingsItem.ISettingsItem) -> ())?,
	ShowSettingsMenu: (() -> ())?,
	HideSettingsMenu: (() -> ())?,
	ShowOptionPopup: ((Title: string, Text: string, Option: string, OnOption: () -> ()) -> ())?,
	OpenNightlyImportDialog: (() -> ())?,
	OpenUserFolderDialog: (() -> ())?,
	ShellOpen: ((Path: string) -> ())?,
	WindowSetMode: ((Mode: string) -> ())?,
	WindowSetVsyncMode: ((Mode: string) -> ())?,
	SetMaxFps: ((Fps: number) -> ())?,
	SetMsaa3D: ((Mode: string) -> ())?,
	ImportMeshesFromNightly: (() -> ())?,
	ImportColorsetsFromNightly: (() -> ())?,
}

-- The [Order] properties in declaration order (SettingsProfile.cs). ToOrderedSectionList and the file keys follow it.
const Order = {
	"Sensitivity",
	"VerticalSensitivity",
	"AbsoluteSensitivity",
	"AbsoluteInput",
	"CursorDrift",
	"EdgeOvershoot",
	"ApproachRate",
	"ApproachDistance",
	"ApproachTime",
	"FadeIn",
	"FadeOut",
	"Pushback",
	"CameraParallax",
	"HUDParallax",
	"FoV",
	"MenuScale",
	"HudScale",
	"Skin",
	"MenuSpace",
	"GameSpace",
	"SpaceColor",
	"SpaceHitEffects",
	"SpaceEffects",
	"NoteColors",
	"NoteOpacity",
	"NoteOpacityExponent",
	"NoteMesh",
	"NoteSize",
	"NoteGlow",
	"NoteGlowStrength",
	"NoteGlowFade",
	"CursorStyle",
	"CursorColor",
	"CursorScale",
	"CursorOpacity",
	"CursorRotation",
	"CursorTrail",
	"TrailPreset",
	"TrailImage",
	"TrailTime",
	"TrailSpacing",
	"TrailShrink",
	"TrailOpacity",
	"TrailColor",
	"TrailDetail",
	"UseCursorInMenus",
	"HPLerpValue",
	"GridGuides",
	"GridGuidesOff",
	"Border",
	"SimpleHUD",
	"SuperSimpleHUD",
	"AltComboCounter",
	"VisibilityAssist",
	"HitPopups",
	"MissPopups",
	"Popups",
	"Fullscreen",
	"BorderlessFullscreen",
	"LockFPS",
	"FPS",
	"VSyncMenus",
	"AntiAliasing",
	"VolumeMaster",
	"VolumeMusic",
	"VolumeSFX",
	"VolumeHitSound",
	"VolumeMissSound",
	"VolumeMenuMusic",
	"AlwaysPlayHitSound",
	"EnableHitSound",
	"EnableMissSound",
	"EnableMenuMusic",
	"AutoplayJukebox",
	"LocalOffset",
	"SetUserFolderPath",
	"SetUserFolderDialog",
	"DisplayFPS",
	"HideSpectators",
	"ImportNightlyProfile",
	"NightlyImportDialog",
	"ImportNightlyMeshes",
	"ImportNightlyColorsets",
	"RecordReplays",
	"OptionalPlaytestParameters",
	"ResetToDefaults",
}

-- Enum.GetValues<SettingsSection>() order.
const SectionOrder = {
	SettingsSection.None,
	SettingsSection.Gameplay,
	SettingsSection.Visual,
	SettingsSection.Audio,
	SettingsSection.Video,
	SettingsSection.Other,
}

-- The MSAA mode of each Anti Aliasing choice; the other choices are Disabled (the C# switch default).
const MsaaModes = {
	["2x (rough)"] = "Msaa2X",
	["4x (smooth)"] = "Msaa4X",
	["8x (smoothest)"] = "Msaa8X",
}

const Hooks: ProfileHooks = {}

-- A list's options followed by the skin sets' names (Skinning/SkinSets): a set's pieces carry its name in every list.
const function WithSets(Options: { string }, Names: { string }?): { string }
	const All = table.clone(Options)

	for _, Name in Names or SkinSets.Names do
		table.insert(All, Name)
	end

	return All
end

-- (2026-11-07) The Menu Space and Game Space backgrounds that were taken out (Spaces/Backgrounds): a profile, a replay or a
-- spectated player that still names one shows the skin's space instead.
const RetiredSpaces: { [string]: boolean } = { tunnel = true, vortex = true, warp = true, spectrum = true, prism = true, pulse = true }

-- (2026-11-22) The owner's settings (their profile on that day, only the settings that differ from the ones declared below):
-- a new player's first profile starts on them (Aimia.Start) and Reset to Defaults goes back to them (SettingsManager), through
-- ApplyOwnerDefaults. New() keeps the declared values: a saved file that lacks a setting (one added after it was written) still
-- gets the declared one, so a player who already has settings keeps every value they had, and watched looks and replays
-- that lack a setting show it as before.
const OwnerDefaults: { [string]: unknown } = {
	CursorStyle = "dot",
	CursorTrail = true,
	FadeOut = 100,
	GameSpace = "Katana",
	MenuSpace = "Katana",
	NoteColors = "Solid White",
	NoteGlowFade = true,
	NoteGlowStrength = 0.45,
	NoteSize = 0.8,
	Sensitivity = 1.78,
	TrailColor = "Katana",
	TrailImage = "cursor",
	TrailSpacing = 0.6,
	TrailTime = 0.065,
}

-- Also the UpdateAction of MenuSpace, GameSpace, SpaceColor, NoteColors and NoteMesh (same body).
-- @src scripts/database/settings/SettingsProfile.cs:Skin L631-637
const function LoadSkinOnChange(_: string, Initializing: boolean)
	if not Initializing and Hooks.LoadSkin then
		Hooks.LoadSkin()
	end
end

-- Also the UpdateAction of VolumeMusic, VolumeSFX, VolumeHitSound, VolumeMissSound and VolumeMenuMusic (same body).
-- @src scripts/database/settings/SettingsProfile.cs:VolumeMaster L1148-1154
const function UpdateVolumeOnChange(_: number, Initializing: boolean)
	if not Initializing and Hooks.UpdateVolume then
		Hooks.UpdateVolume()
	end
end

-- @src scripts/database/settings/SettingsProfile.cs:EnableMenuMusic L1133-1139
const function RefreshMenuMusicOnChange(_: boolean, Initializing: boolean)
	if not Initializing and Hooks.RefreshMenuMusicPlayback then
		Hooks.RefreshMenuMusicPlayback()
	end
end

-- @src scripts/database/settings/SettingsProfile.cs:SetUserFolderPath L1370-1373
const function SetUserFolderOnChange(Value: string)
	if Hooks.SetUserFolder then
		Hooks.SetUserFolder(Value)
	end
end

-- @src scripts/database/settings/SettingsProfile.cs:VSyncMenus L1047-1053
const function OnVSyncMenusChanged(Value: boolean)
	const InGame = if Hooks.IsGameScene then Hooks.IsGameScene() else false

	if not InGame then
		-- DEVIATION: DisplayServer V-Sync has no Roblox equivalent; no implementation will be set.
		if Hooks.WindowSetVsyncMode then
			Hooks.WindowSetVsyncMode(if Value then "Adaptive" else "Disabled")
		end
	end
end

-- @src scripts/database/settings/SettingsProfile.cs:AntiAliasing L1062-1073
const function OnAntiAliasingChanged(Value: string)
	-- DEVIATION: MSAA on the SceneTree root has no Roblox equivalent; no implementation will be set.
	if Hooks.SetMsaa3D then
		Hooks.SetMsaa3D(MsaaModes[Value] or "Disabled")
	end
end

-- @src scripts/database/settings/SettingsProfile.cs:getAvailableMeshes L1522-1537
const function GetAvailableMeshes(): { string }
	const Meshes = { "skin" }
	const MeshFolder = `{Constants.UserFolder}/meshes`

	if FileSystem.DirectoryExists(MeshFolder) then
		for _, FilePath in FileSystem.GetFiles(MeshFolder, ".obj") do
			table.insert(Meshes, FileSystem.GetFileNameWithoutExtension(FilePath))
		end
	end

	-- (the skin sets' flat note pictures, Skinning/SkinSets)
	for _, Name in SkinSets.NotePictureNames do
		table.insert(Meshes, Name)
	end

	return Meshes
end

-- The item of a property name (Order and the file keys are property names).
const function ItemNamed(Profile: SettingsProfile, Name: string): SettingsItem.SettingsItem<unknown>
	return Profile[Name] :: SettingsItem.SettingsItem<unknown>
end

-- SettingsManager.Instance.Settings: the manager's current profile, this profile until the manager sets CurrentSettings.
const function CurrentSettings(Profile: SettingsProfile): SettingsProfile
	if Hooks.CurrentSettings then
		return Hooks.CurrentSettings()
	end

	return Profile
end

-- @src scripts/database/settings/SettingsProfile.cs:ToOrderedSectionList L1483-1506
const function ToOrderedSectionList(Profile: SettingsProfile): { [number]: { SettingsItem.ISettingsItem } }
	const Sections: { [number]: { SettingsItem.ISettingsItem } } = {}

	for _, Section in SectionOrder do
		Sections[Section] = {}
	end

	for _, Name in Order do
		const Item = ItemNamed(Profile, Name)

		table.insert(Sections[Item.Section], Item)
	end

	return Sections
end

-- @src scripts/database/settings/SettingsProfile.cs:ConfigureSetUserFolderPath L1671-1674
const function ConfigureSetUserFolderPath(UserFolderPath: string)
	if Hooks.CurrentSettings then
		SettingsItem.SetValue(Hooks.CurrentSettings().SetUserFolderPath, UserFolderPath)
	end
end

-- @src scripts/database/settings/SettingsProfile.cs:SettingsProfile L447-1474
const function New(): SettingsProfile
	const Profile = {} :: SettingsProfile

	-- @src scripts/database/settings/SettingsProfile.cs:updateApproachTime L1508-1511
	const function UpdateApproachTime()
		SettingsItem.SetValue(Profile.ApproachTime, Profile.ApproachDistance.Value / Profile.ApproachRate.Value)
	end

	-- @src scripts/database/settings/SettingsProfile.cs:updateWindowMode L1513-1520
	const function UpdateWindowMode()
		const Mode = if Profile.Fullscreen.Value
			then (if Profile.BorderlessFullscreen.Value then "Fullscreen" else "ExclusiveFullscreen")
			else "Windowed"

		-- DEVIATION: DisplayServer window modes have no Roblox equivalent; no implementation will be set.
		if Hooks.WindowSetMode then
			Hooks.WindowSetMode(Mode)
		end
	end

	-- @src scripts/database/settings/SettingsProfile.cs:LockFPS L1023-1024
	const function OnLockFpsChanged(Value: boolean)
		-- DEVIATION: Engine.MaxFps caps the Godot frame rate; no Roblox implementation will be set.
		if Hooks.SetMaxFps then
			Hooks.SetMaxFps(if Value then Profile.FPS.Value else 0)
		end
	end

	-- @src scripts/database/settings/SettingsProfile.cs:FPS L1038-1039
	const function OnFpsChanged(Value: number)
		-- DEVIATION: Engine.MaxFps caps the Godot frame rate; no Roblox implementation will be set.
		if Hooks.SetMaxFps then
			Hooks.SetMaxFps(if Profile.LockFPS.Value then Value else 0)
		end
	end

	-- Gameplay

	-- @src scripts/database/settings/SettingsProfile.cs:Sensitivity L451-463
	Profile.Sensitivity = SettingsItem.New("double", Numbers.F32(0.5), {
		Id = "Sensitivity",
		Title = "Sensitivity",
		Description = "How fast the cursor moves with your mouse. Higher means less hand movement to cross the grid; Absolute Input uses Absolute Sensitivity instead.",
		Section = SettingsSection.Gameplay,
		-- (up to 30, the owner's ask 2026-11-07; spread evenly by ratio, so 0.3 to 2 keeps most of the track and stays easy to set)
		Slider = NewSlider(0.01, 0.01, 30, { Floor = 0.001, Ceiling = 30, Log = true }),
	})

	-- Not in the source: applied to the input in Game.MouseMove, so replays and watchers never see it.
	Profile.VerticalSensitivity = SettingsItem.New("double", 1, {
		Id = "VerticalSensitivity",
		Title = "Vertical Sensitivity",
		Description = "How fast the cursor moves up and down compared to side to side. 1 is the same; lower makes up and down slower, higher makes it faster.",
		Section = SettingsSection.Gameplay,
		Slider = NewSlider(0.05, 0.25, 2),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:AbsoluteSensitivity L465-477
	Profile.AbsoluteSensitivity = SettingsItem.New("double", Numbers.F32(1.0), {
		Id = "AbsoluteSensitivity",
		Title = "Absolute Sensitivity",
		Description = "Only with Absolute Input on: how far the cursor moves when your mouse or pen moves. Higher means a smaller part of the screen covers the whole grid.",
		Section = SettingsSection.Gameplay,
		-- (up to 30, as Sensitivity)
		Slider = NewSlider(0.01, 0.01, 30, { Ceiling = 30, Log = true }),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:AbsoluteInput L479-485
	Profile.AbsoluteInput = SettingsItem.New("bool", false, {
		Id = "AbsoluteInput",
		Title = "Absolute Input",
		Description = "On: where your mouse or pen is on the screen sets where the cursor is, like a drawing tablet. Off: your mouse is locked and its movement pushes the cursor.",
		Section = SettingsSection.Gameplay,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:ApproachRate L487-500
	Profile.ApproachRate = SettingsItem.New("double", 30, {
		Id = "ApproachRate",
		Title = "Approach Rate",
		Description = "How fast notes fly toward you. Higher gives you less time to see each note coming; lower gives more time but puts more notes on screen at once.",
		Section = SettingsSection.Gameplay,
		UpdateAction = UpdateApproachTime,
		Slider = NewSlider(0.5, 0.5, 100, { Ceiling = 1000 }),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:ApproachDistance L502-515
	Profile.ApproachDistance = SettingsItem.New("double", 15, {
		Id = "ApproachDistance",
		Title = "Approach Distance",
		Description = "How far away notes appear. Farther means you see each note for longer before it reaches the grid, at the same Approach Rate.",
		Section = SettingsSection.Gameplay,
		UpdateAction = UpdateApproachTime,
		Slider = NewSlider(0.5, 0.5, 100, { Ceiling = 1000 }),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:ApproachTime L517-525
	Profile.ApproachTime = SettingsItem.New("double", 0, {
		Id = "ApproachTime",
		Title = "Approach Time",
		Description = "Approach time of hit objects",
		Section = SettingsSection.Gameplay,
		Visible = false,
		SaveToDisk = false,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:CursorDrift L527-533
	Profile.CursorDrift = SettingsItem.New("bool", true, {
		Id = "CursorDrift",
		Title = "Cursor Drift",
		Description = "On: past the edge the cursor stops and moves back the moment you do. Off: the game keeps tracking your hand past the edge, so the cursor stays stuck on the border until your hand comes back (Spin and Absolute Input always do this).",
		Section = SettingsSection.Gameplay,
	})

	-- Not in the source: read by CameraLock and CameraSpin for live play. Replays and watchers carry the resulting position.
	Profile.EdgeOvershoot = SettingsItem.New("double", 0.5, {
		Id = "EdgeOvershoot",
		Title = "Edge Overshoot",
		Description = "With Cursor Drift off, or in Spin: how far past the edge your hand can go (in notes) before the game stops tracking it. More means stickier borders (not with Absolute Input).",
		Section = SettingsSection.Gameplay,
		Slider = NewSlider(0.05, 0, 3),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:FadeIn L535-547
	Profile.FadeIn = SettingsItem.New("double", 10, {
		Id = "FadeIn",
		Title = "Fade In",
		Description = "Notes fade in after they appear in the distance. This is how much of their trip (in %) the fade-in takes; 0 makes them pop in fully solid.",
		Section = SettingsSection.Gameplay,
		Slider = NewSlider(1, 0, 100),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:FadeOut L549-561
	Profile.FadeOut = SettingsItem.New("double", 75, {
		Id = "FadeOut",
		Title = "Fade Out",
		Description = "Notes fade away as they get close, so you can see the ones behind them. This is how much of their trip (in %) the fade-out takes; 0 keeps them solid, and F in a song switches it off and on.",
		Section = SettingsSection.Gameplay,
		Slider = NewSlider(1, 0, 100),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:Pushback L563-569
	Profile.Pushback = SettingsItem.New("bool", true, {
		Id = "Pushback",
		Title = "Pushback",
		Description = "On: notes keep flying past the grid until it's too late to hit them. Off: they vanish at the grid, though you can still hit them for a moment (P in a song switches it).",
		Section = SettingsSection.Gameplay,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:CameraParallax L571-583
	Profile.CameraParallax = SettingsItem.New("double", Numbers.F32(0.25), {
		Id = "CameraParallax",
		Title = "Camera Parallax",
		Description = "How much the camera slides along with your cursor. 0 keeps the camera in place; higher makes the grid shift more on screen as you aim.",
		Section = SettingsSection.Gameplay,
		Slider = NewSlider(0.05, 0, 1),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:HUDParallax L585-597
	Profile.HUDParallax = SettingsItem.New("double", 0, {
		Id = "HUDParallax",
		Visible = false,
		Title = "HUD Parallax",
		Description = "(Not implemented) Adjusts the HUD parallax",
		Section = SettingsSection.Gameplay,
		Slider = NewSlider(0.05, 0, 1),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:FoV L607-619
	Profile.FoV = SettingsItem.New("double", 70, {
		Id = "FoV",
		Title = "Field of View",
		Description = "How wide the camera sees. Higher makes the grid look smaller and lets your cursor cross it with less hand movement; lower zooms in.",
		Section = SettingsSection.Gameplay,
		Slider = NewSlider(1, 60, 120, { Floor = 20 }),
	})

	-- Visual

	-- Not in the source: the menus' size on top of fitting the window (AimiaApp applies it when the mouse button is up).
	Profile.MenuScale = SettingsItem.New("double", 1, {
		Id = "MenuScale",
		Title = "Menu Scale",
		Description = "How big the menus are. 1 fits them to your window; the new size shows once you let go of the slider.",
		Section = SettingsSection.Visual,
		Slider = NewSlider(0.05, 0.6, 1.5),
	})

	-- Not in the source: the song's panels, bars and text around the grid (UI/Game/HudManager). Each player's own: watchers keep
	-- theirs.
	Profile.HudScale = SettingsItem.New("double", 1, {
		Id = "HudScale",
		Title = "HUD Scale",
		Description = "How big the panels, bars and text around the grid are in a song. The grid and notes keep their size.",
		Section = SettingsSection.Visual,
		-- (past 1.25 the bars run into the grid's corners)
		Slider = NewSlider(0.05, 0.5, 1.25),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:Skin L625-651
	Profile.Skin = SettingsItem.New("string", "default", {
		Id = "Skin",
		Visible = false,
		Title = "Skin",
		Description = "Selected skin for the game",
		Section = SettingsSection.Visual,
		UpdateAction = LoadSkinOnChange,
		Buttons = {
			NewButton("Skin Folder", "Open the skin folder", function()
				-- DEVIATION: OS.ShellOpen opens a desktop folder; no Roblox implementation will be set.
				if Hooks.ShellOpen then
					Hooks.ShellOpen(`{Constants.UserFolder}/skins/{CurrentSettings(Profile).Skin.Value}`)
				end
			end),
		},
		List = NewList("default", { "default" }),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:MenuSpace L653-685
	Profile.MenuSpace = SettingsItem.New("string", "skin", {
		Id = "MenuSpace",
		Title = "Menu Skins",
		Description = "The background behind the menus: a moving one, the plain void, or a map skin's picture (pick the skin's name).",
		Section = SettingsSection.Visual,
		UpdateAction = LoadSkinOnChange,
		List = NewList("skin", WithSets({ "skin", "void", "waves", "aurora", "horizon", "drift" })),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:GameSpace L687-719
	Profile.GameSpace = SettingsItem.New("string", "skin", {
		Id = "GameSpace",
		Title = "Custom Map Skins",
		Description = "The background while you play: the grid, the plain void, a moving one, or a map skin's picture. Pick the same skin name in other lists to match its cursor, trail and more.",
		Section = SettingsSection.Visual,
		UpdateAction = LoadSkinOnChange,
		List = NewList("skin", WithSets({ "skin", "void", "grid", "aurora", "horizon", "drift" })),
	})

	-- Not in the source: the color of the grid's fog and of the void, in the menu and in the game (Spaces/SpaceColor).
	Profile.SpaceColor = SettingsItem.New("string", "default", {
		Id = "SpaceColor",
		Title = "Space Color",
		Description = "Tints the space behind the grid and the menus: the grid's fog, the void, moving backgrounds and map skin pictures. Default keeps their own colors.",
		Section = SettingsSection.Visual,
		UpdateAction = LoadSkinOnChange,
		List = NewList("default", { "default", "black", "gray", "red", "crimson", "orange", "yellow", "lime", "green", "mint", "teal", "cyan", "blue", "navy", "indigo", "violet", "purple", "magenta", "pink" }),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:SpaceHitEffects L721-727
	Profile.SpaceHitEffects = SettingsItem.New("bool", true, {
		Id = "SpaceHitEffects",
		Title = "Space Hit Effects",
		Description = "On: the background in a song takes the color of each note you hit (map skin pictures stay as they are). Off: it keeps its own color.",
		Section = SettingsSection.Visual,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:SpaceEffects L729-735
	Profile.SpaceEffects = SettingsItem.New("bool", true, {
		Id = "SpaceEffects",
		Visible = false,
		Title = "Space Effects",
		Description = "Toggles non-hit effects for the game space",
		Section = SettingsSection.Visual,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:NoteColors L737-751
	Profile.NoteColors = SettingsItem.New("string", "skin", {
		Id = "Colors",
		Title = "Colors",
		Description = "The colors your notes take turns using: the skin's own set, a ready-made set, or a map skin's colors (pick the skin's name).",
		Section = SettingsSection.Visual,
		UpdateAction = LoadSkinOnChange,
		List = NewList("skin", { "skin", "default" }),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:NoteOpacity L753-765
	Profile.NoteOpacity = SettingsItem.New("double", 1, {
		Id = "NoteOpacity",
		Title = "Note Opacity",
		Description = "How solid notes are at their most. 1 is fully solid; lower makes every note see-through.",
		Section = SettingsSection.Visual,
		Slider = NewSlider(0.05, 0, 1),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:NoteOpacityExponent L767-779
	Profile.NoteOpacityExponent = SettingsItem.New("double", 1.25, {
		Id = "NoteOpacityExponent",
		Title = "Note Opacity Exponent",
		Description = "Shapes how notes fade. Higher keeps fading notes see-through for longer, so they pop in later and fade out sooner; 1 is an even fade.",
		Section = SettingsSection.Visual,
		Slider = NewSlider(0.05, 1, 2),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:NoteMesh L781-795
	Profile.NoteMesh = SettingsItem.New("string", "skin", {
		Id = "NoteMesh",
		Title = "Note Mesh",
		Description = "The shape of your notes: the skin's own, a shape like cube or square, or a map skin's flat note picture. It only changes how notes look.",
		Section = SettingsSection.Visual,
		UpdateAction = LoadSkinOnChange,
		List = NewList("skin", GetAvailableMeshes()),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:NoteSize L797-809
	Profile.NoteSize = SettingsItem.New("double", Numbers.F32(0.875), {
		Id = "NoteSize",
		Title = "Note Size",
		Description = "How big notes look. It doesn't change where you have to aim to hit them.",
		Section = SettingsSection.Visual,
		Slider = NewSlider(0.025, 0, 2),
	})

	-- Not in the source (2026-11-10): Roblox's own glow round the Neon notes, on or off (Game/View/NoteGlow). Roblox only
	-- draws it on 3 graphics bars and up; off draws the notes flat, as lower graphics do. Spectators see it the player's way.
	Profile.NoteGlow = SettingsItem.New("bool", true, {
		Id = "NoteGlow",
		Title = "Note Glow",
		Description = "On: notes glow (only on Roblox graphics of 3 bars or more). Off: flat notes with no glow. Anyone spectating you sees it your way.",
		Section = SettingsSection.Visual,
	})

	-- Not in the source (2026-11-10, the owner found the glow too bright): how strong the glow is. It caps the notes' colour,
	-- which is what Roblox's glow goes by (Game/View/NoteGlow.Tint); 1 leaves the notes exactly as they were.
	Profile.NoteGlowStrength = SettingsItem.New("double", 1, {
		Id = "NoteGlowStrength",
		Title = "Note Glow Strength",
		Description = "How bright the glow around notes is, with Note Glow on. 1 is the full glow, 0 is none.",
		Section = SettingsSection.Visual,
		Slider = NewSlider(0.05, 0, 1),
	})

	-- Not in the source (2026-11-10): Roblox stops drawing the glow as soon as a note is a little see-through, so with Fade
	-- Out the glow went out while the note was still plain to see. Off (the default) keeps the glow for as long as the note
	-- shows (Game/View/NoteRenderer's halo); on is Roblox's own early cut.
	Profile.NoteGlowFade = SettingsItem.New("bool", false, {
		Id = "NoteGlowFade",
		Title = "Note Glow Fades Early",
		Description = "Off: a fading note keeps its glow until the note itself is gone. On: the glow goes out as soon as a note starts to fade.",
		Section = SettingsSection.Visual,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:GridGuides L811-817
	Profile.GridGuides = SettingsItem.New("bool", false, {
		Id = "GridGuides",
		Title = "Grid Guides",
		Description = "Shows little + marks on the grid as aiming guides.",
		Section = SettingsSection.Visual,
	})

	-- Not in the source (2026-11-07): the grid's + marks were turned off for everyone once (SettingsManager.Load); this remembers
	-- it was done, so anyone who turns them back on keeps them.
	Profile.GridGuidesOff = SettingsItem.New("bool", false, {
		Id = "GridGuidesOff",
		Visible = false,
		Title = "Grid Guides Off",
		Description = "The grid guides were turned off once for everyone",
		Section = SettingsSection.Visual,
	})

	-- Not in the source: a frame round the playfield from the skin sets (Skinning/SkinSets). Looks only.
	Profile.Border = SettingsItem.New("string", "none", {
		Id = "Border",
		Title = "Border",
		Description = "Adds a frame around the grid from a map skin (pick the skin's name). It's only for looks.",
		Section = SettingsSection.Visual,
		List = NewList("none", SkinSets.BorderNames),
	})

	-- Not in the source: the cursor's picture and tint (Skinning/CursorStyles). Looks only, the hitbox is the same.
	Profile.CursorStyle = SettingsItem.New("string", "skin", {
		Id = "CursorStyle",
		Title = "Custom Cursors",
		Description = "How your cursor looks: a shape, a picture, or a map skin's cursor (pick the skin's name). It only changes the look, not where notes count as hit.",
		Section = SettingsSection.Visual,
		List = NewList("skin", WithSets({ "skin", "dot", "circle", "ring dot", "target", "cross", "square", "diamond", "triangle", "glow", "white glow", "pink orb", "star" })),
	})

	Profile.CursorColor = SettingsItem.New("string", "white", {
		Id = "CursorColor",
		Title = "Cursor Color",
		Description = "Tints your cursor, and its trail when Trail Color is set to cursor. White keeps the picture's own colors; a map skin's name uses that skin's cursor color.",
		Section = SettingsSection.Visual,
		List = NewList("white", WithSets({ "white", "pink", "red", "orange", "yellow", "green", "cyan", "blue", "purple" })),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:CursorScale L819-831
	Profile.CursorScale = SettingsItem.New("double", 1, {
		Id = "CursorScale",
		Title = "Cursor Scale",
		Description = "How big your cursor looks (the menu cursor too). It doesn't change where notes count as hit.",
		Section = SettingsSection.Visual,
		Slider = NewSlider(0.025, 0, 4),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:CursorOpacity L833-845
	Profile.CursorOpacity = SettingsItem.New("double", 1, {
		Id = "CursorOpacity",
		Title = "Cursor Opacity",
		Description = "How solid your cursor is in songs. 1 is fully solid, 0 is invisible.",
		Section = SettingsSection.Visual,
		Slider = NewSlider(0.05, 0, 1),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:CursorRotation L847-859
	Profile.CursorRotation = SettingsItem.New("double", 0, {
		Id = "CursorRotation",
		Title = "Cursor Rotation",
		Description = "Spins your cursor while you play, in degrees per second. Negative spins the other way; 0 keeps it still.",
		Section = SettingsSection.Visual,
		Slider = NewSlider(1, -360, 360),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:CursorTrail L861-867
	Profile.CursorTrail = SettingsItem.New("bool", false, {
		Id = "CursorTrail",
		Title = "Cursor Trail",
		Description = "Leaves a trail behind your cursor in songs. The trail settings below change how it looks.",
		Section = SettingsSection.Visual,
	})

	-- Not in the source: Rhythia's newer Cursor Trail settings (its Settings > Cursor > Cursor Trail) and the map preview's line;
	-- Game/View/TrailRenderer draws them. Trail Spacing replaces Trail Detail, which stays hidden so old profiles still load.
	-- (picking a map skin's name loads that skin's trail into the trail settings below, as Rhythia's skin import does;
	-- they can be changed after. Loading a profile doesn't run it.)
	Profile.TrailPreset = SettingsItem.New("string", "your own", {
		Id = "TrailPreset",
		-- (not saved: a profile load would run the preset again and undo trail changes made after it)
		SaveToDisk = false,
		Title = "Custom Trails",
		Description = "Pick a map skin's name to copy its trail into the trail settings below and turn the trail on. You can still change them after.",
		Section = SettingsSection.Visual,
		UpdateAction = function(Value: string, _: boolean)
			const Set = SkinSets.Get(Value)

			-- (never loaded from a file, so even the first pick of a session is the player's own: no Initializing guard)
			if not Set then
				return
			end

			SettingsItem.SetValue(Profile.CursorTrail, true)
			SettingsItem.SetValue(Profile.TrailImage, "cursor")
			SettingsItem.SetValue(Profile.TrailTime, Numbers.F32(Set.Trail.Fade))
			SettingsItem.SetValue(Profile.TrailSpacing, Numbers.F32(Set.Trail.Spacing))
			SettingsItem.SetValue(Profile.TrailShrink, Set.Trail.Shrink)
			SettingsItem.SetValue(Profile.TrailOpacity, Numbers.F32(Set.Trail.Opacity))
			SettingsItem.SetValue(Profile.TrailColor, Set.Name)

			-- (a one-shot copy: the list goes back to "your own", so a skin can be picked again, in this profile or another)
			Profile.TrailPreset.Value = "your own"
			;(Profile.TrailPreset.List :: any).SelectedValue = "your own"
		end,
		List = NewList("your own", SkinSets.TrailPresetNames),
	})

	Profile.TrailImage = SettingsItem.New("string", "smooth line", {
		Id = "TrailImage",
		Title = "Trail Image",
		Description = "What the trail is made of: one smooth line, copies of your cursor's picture, or a map skin's trail picture.",
		Section = SettingsSection.Visual,
		List = NewList("smooth line", SkinSets.TrailImageNames),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:TrailTime L869-881 (renamed as Rhythia's Trail Fade Time, its 0.005-2 s range)
	Profile.TrailTime = SettingsItem.New("double", Numbers.F32(0.1), {
		Id = "TrailTime",
		Title = "Trail Fade Time",
		Description = "How long each part of the trail lasts before it fades away, in seconds. Longer makes a longer trail.",
		Section = SettingsSection.Visual,
		Slider = NewSlider(0.005, 0.005, 2, { Log = true }),
	})

	Profile.TrailSpacing = SettingsItem.New("double", Numbers.F32(0.4), {
		Id = "TrailSpacing",
		Title = "Trail Spacing",
		Description = "How far apart the trail's pictures are, in cursor sizes. Smaller looks smoother; the smooth line ignores it.",
		Section = SettingsSection.Visual,
		Slider = NewSlider(0.05, 0.05, 2),
	})

	Profile.TrailShrink = SettingsItem.New("bool", true, {
		Id = "TrailShrink",
		Title = "Shrink Over Time",
		Description = "On: the trail gets thinner toward its end. Off: it stays the same width while it fades.",
		Section = SettingsSection.Visual,
	})

	Profile.TrailOpacity = SettingsItem.New("double", Numbers.F32(0.9), {
		Id = "TrailOpacity",
		Title = "Trail Opacity",
		Description = "How solid the trail is. 1 is fully solid, 0 is invisible.",
		Section = SettingsSection.Visual,
		Slider = NewSlider(0.05, 0, 1),
	})

	Profile.TrailColor = SettingsItem.New("string", "cursor", {
		Id = "TrailColor",
		Title = "Trail Color",
		Description = "The trail's color: your cursor's color, white, a rainbow, or a map skin's trail colors (pick the skin's name).",
		Section = SettingsSection.Visual,
		List = NewList("cursor", SkinSets.TrailColorNames),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:TrailDetail L883-895 (hidden: Trail Spacing does its job now)
	Profile.TrailDetail = SettingsItem.New("double", 100, {
		Id = "TrailDetail",
		Visible = false,
		Title = "Cursor Trail Detail",
		Description = "Adjusts the detail for the trail, a high value may impact performance",
		Section = SettingsSection.Visual,
		Slider = NewSlider(1, 0, 500),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:UseCursorInMenus L897-903
	Profile.UseCursorInMenus = SettingsItem.New("bool", false, {
		Id = "UseCursorInMenus",
		Title = "Use Cursor in Menus",
		Description = "On: the menus show the game's own cursor picture (not your Custom Cursor) instead of your normal mouse pointer.",
		Section = SettingsSection.Visual,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:HPLerpValue L905-917
	Profile.HPLerpValue = SettingsItem.New("double", Numbers.F32(60), {
		Id = "HPLerpValue",
		-- (hidden at its default since 2026-11-07, the owner's call)
		Visible = false,
		SaveToDisk = false,
		Title = "HP Bar Easing Value",
		Description = "Adjusts how smooth, or harsh, the HP Bar eases in while it updates",
		Section = SettingsSection.Visual,
		Slider = NewSlider(1, 10, 100),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:SimpleHUD L951-957
	Profile.SimpleHUD = SettingsItem.New("bool", false, {
		Id = "SimpleHUD",
		Title = "Simple HUD",
		Description = "Hides the score and accuracy panels beside the grid and shows just a miss counter on the right instead.",
		Section = SettingsSection.Visual,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:SuperSimpleHUD L959-965
	Profile.SuperSimpleHUD = SettingsItem.New("bool", false, {
		Id = "SuperSimpleHUD",
		Title = "Super Simple HUD",
		Description = "Hides everything Simple HUD does, plus the health bar, the song's name and time, and the combo number. The miss counter stays.",
		Section = SettingsSection.Visual,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:AltComboCounter L967-973
	Profile.AltComboCounter = SettingsItem.New("bool", false, {
		Id = "AltComboCounter",
		Title = "Alt. Combo Counter",
		Description = "Moves your combo number from the big see-through one behind the grid into the score panel on the left (Simple HUD then hides it).",
		Section = SettingsSection.Visual,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:VisibilityAssist L975-981
	Profile.VisibilityAssist = SettingsItem.New("bool", false, {
		Id = "VisibilityAssist",
		Title = "Visibility Assist",
		Description = "Adds a dark, round fade far behind the grid to help notes stand out on bright or busy backgrounds.",
		Section = SettingsSection.Visual,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:HitPopups L983-989
	Profile.HitPopups = SettingsItem.New("bool", true, {
		Id = "HitPopups",
		Visible = false,
		Title = "Hit Score Popups",
		Description = "Toggles a popup on a hit",
		Section = SettingsSection.Visual,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:MissPopups L991-997
	Profile.MissPopups = SettingsItem.New("bool", true, {
		Id = "MissPopups",
		Visible = false,
		Title = "Miss Popups",
		Description = "Toggles a popup on a miss",
		Section = SettingsSection.Visual,
	})

	-- Not in the source (2026-11-07): one list for Hit Score Popups and Miss Popups, which stay (hidden) as what the HUD reads;
	-- SettingsManager.Load sets it from them, so it always shows what they are.
	Profile.Popups = SettingsItem.New("string", "both", {
		Id = "Popups",
		-- (not saved: the two popup switches are what's kept, and SettingsManager.Load shows them here)
		SaveToDisk = false,
		Title = "Popups",
		Description = "Little popups at the bottom of the grid: the points you got on a hit and a mark on a miss. Show both, just one kind, or none.",
		Section = SettingsSection.Visual,
		UpdateAction = function(Value: string, Initializing: boolean)
			if Initializing then
				return
			end

			SettingsItem.SetValue(Profile.HitPopups, Value == "both" or Value == "hits only")
			SettingsItem.SetValue(Profile.MissPopups, Value == "both" or Value == "misses only")
		end,
		List = NewList("both", { "both", "hits only", "misses only", "off" }),
	})

	-- Video

	-- @src scripts/database/settings/SettingsProfile.cs:Fullscreen L999-1006
	Profile.Fullscreen = SettingsItem.New("bool", true, {
		Id = "Fullscreen",
		Visible = false,
		Title = "Fullscreen",
		Description = "Toggles the window to fullscreen",
		Section = SettingsSection.Video,
		UpdateAction = UpdateWindowMode,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:BorderlessFullscreen L1008-1015
	Profile.BorderlessFullscreen = SettingsItem.New("bool", false, {
		Id = "BorderlessFullscreen",
		Visible = false,
		Title = "Borderless Fullscreen",
		Description = "Alters the Fullscreen toggle to use Borderless fullscreen instead of Exclusive, may fix some issues with drawing tablets",
		Section = SettingsSection.Video,
		UpdateAction = UpdateWindowMode,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:LockFPS L1017-1024
	Profile.LockFPS = SettingsItem.New("bool", false, {
		Id = "LockFPS",
		Visible = false,
		Title = "Lock FPS",
		Description = "Locks maximum frames per second",
		Section = SettingsSection.Video,
		UpdateAction = OnLockFpsChanged,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:FPS L1026-1039
	Profile.FPS = SettingsItem.New("int", 240, {
		Id = "FPS",
		Visible = false,
		Title = "FPS",
		Description = "Adjusts maximum frames per second, we recommend this being 2x your refresh rate",
		Section = SettingsSection.Video,
		Slider = NewSlider(5, 30, 1000),
		UpdateAction = OnFpsChanged,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:VSyncMenus L1041-1054
	Profile.VSyncMenus = SettingsItem.New("bool", true, {
		Id = "VSyncMenus",
		Visible = false,
		Title = "V-Sync in Menus",
		Description = "Toggles V-Sync when in menus",
		Section = SettingsSection.Video,
		UpdateAction = OnVSyncMenusChanged,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:AntiAliasing L1056-1075
	Profile.AntiAliasing = SettingsItem.New("string", "Off (roughest)", {
		Id = "AntiAliasing",
		Visible = false,
		Title = "Anti Aliasing",
		Description = "Smoothes edges, at the cost of performance",
		Section = SettingsSection.Video,
		UpdateAction = OnAntiAliasingChanged,
		List = NewList("Off (roughest)", { "Off (roughest)", "2x (rough)", "4x (smooth)", "8x (smoothest)" }),
	})

	-- Audio

	-- @src scripts/database/settings/SettingsProfile.cs:AutoplayJukebox L1081-1087
	Profile.AutoplayJukebox = SettingsItem.New("bool", true, {
		Id = "AutoplayJukebox",
		Title = "Autoplay Jukebox",
		Description = "On: the menu keeps playing random songs from the song list, and the jukebox's skip and back buttons work. Off: you only hear the song you pick.",
		Section = SettingsSection.Audio,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:LocalOffset L1089-1101
	Profile.LocalOffset = SettingsItem.New("double", 0, {
		Id = "LocalOffset",
		Title = "Local Offset",
		Description = "Lines the music up with the notes, in milliseconds. If you hear the beat after notes reach the grid, lower it; if you hear it before, raise it.",
		Section = SettingsSection.Audio,
		Slider = NewSlider(1, -500, 500),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:AlwaysPlayHitSound L1103-1109
	Profile.AlwaysPlayHitSound = SettingsItem.New("bool", false, {
		Id = "AlwaysPlayHitSound",
		Title = "Always Play Hit Sound",
		Description = "On: the hit sound plays on the beat of every note, even ones you miss, so you can hear the rhythm.",
		Section = SettingsSection.Audio,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:EnableHitSound L1111-1117
	Profile.EnableHitSound = SettingsItem.New("bool", true, {
		Id = "EnableHitSound",
		-- (hidden and always on since 2026-11-07, the owner's call: its volume at 0 turns it off)
		Visible = false,
		SaveToDisk = false,
		Title = "Enable Hit Sound",
		Description = "Enables hit sound playback",
		Section = SettingsSection.Audio,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:EnableMissSound L1119-1125
	Profile.EnableMissSound = SettingsItem.New("bool", true, {
		Id = "EnableMissSound",
		-- (hidden and always on since 2026-11-07, the owner's call: its volume at 0 turns it off)
		Visible = false,
		SaveToDisk = false,
		Title = "Enable Miss Sound",
		Description = "Enables miss sound playback",
		Section = SettingsSection.Audio,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:EnableMenuMusic L1127-1140
	Profile.EnableMenuMusic = SettingsItem.New("bool", true, {
		Id = "EnableMenuMusic",
		-- (hidden and always on since 2026-11-07, the owner's call: its volume at 0 turns it off)
		Visible = false,
		SaveToDisk = false,
		Title = "Enable Menu Music",
		Description = "Enables menu music playback when the menu is quiet",
		Section = SettingsSection.Audio,
		UpdateAction = RefreshMenuMusicOnChange,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:VolumeMaster L1142-1161
	Profile.VolumeMaster = SettingsItem.New("double", 100, {
		Id = "VolumeMaster",
		Title = "Master Volume",
		Description = "Turns all of AIMIA's sounds up or down at once. 0 mutes everything.",
		Section = SettingsSection.Audio,
		UpdateAction = UpdateVolumeOnChange,
		Slider = NewSlider(1, 0, 100),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:VolumeMusic L1163-1182
	Profile.VolumeMusic = SettingsItem.New("double", 100, {
		Id = "VolumeMusic",
		Title = "Music Volume",
		Description = "How loud the songs are, both while you play and in the menus.",
		Section = SettingsSection.Audio,
		UpdateAction = UpdateVolumeOnChange,
		Slider = NewSlider(1, 0, 100),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:VolumeSFX L1184-1203
	Profile.VolumeSFX = SettingsItem.New("double", 100, {
		Id = "VolumeSFX",
		Title = "SFX Volume",
		Description = "How loud the fail sound is. It plays when you fail, quit or restart a song.",
		Section = SettingsSection.Audio,
		UpdateAction = UpdateVolumeOnChange,
		Slider = NewSlider(1, 0, 100),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:VolumeHitSound L1205-1224
	Profile.VolumeHitSound = SettingsItem.New("double", 100, {
		Id = "VolumeHitSound",
		Title = "Hit Sound Volume",
		Description = "How loud the sound is when you hit a note. 0 turns it off.",
		Section = SettingsSection.Audio,
		UpdateAction = UpdateVolumeOnChange,
		Slider = NewSlider(1, 0, 100),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:VolumeMissSound L1226-1245
	Profile.VolumeMissSound = SettingsItem.New("double", 100, {
		Id = "VolumeMissSound",
		Title = "Miss Sound Volume",
		Description = "How loud the sound is when you miss a note. 0 turns it off.",
		Section = SettingsSection.Audio,
		UpdateAction = UpdateVolumeOnChange,
		Slider = NewSlider(1, 0, 100),
	})

	-- @src scripts/database/settings/SettingsProfile.cs:VolumeMenuMusic L1247-1266
	Profile.VolumeMenuMusic = SettingsItem.New("double", 100, {
		Id = "VolumeMenuMusic",
		Title = "Menu Music Volume",
		Description = "How loud the menu theme is. It plays in the main menu when no song is playing; 0 turns it off.",
		Section = SettingsSection.Audio,
		UpdateAction = UpdateVolumeOnChange,
		Slider = NewSlider(1, 0, 100),
	})

	-- Other

	-- @src scripts/database/settings/SettingsProfile.cs:ImportNightlyProfile L1272-1294
	Profile.ImportNightlyProfile = SettingsItem.New("Variant", nil :: unknown, {
		Id = "ImportNightlyProfile",
		Visible = false,
		Title = "Import Nightly Settings",
		Description = "Imports settings from the nightly client",
		Section = SettingsSection.Other,
		Buttons = {
			-- DEVIATION: NIGHTLY_FOLDER is an OS path that Constants does not port, so no nightly folder exists here and the
			-- import never runs. ImportFromNightlySettings is excluded (it needs SoundManager.ComputeVolumeFromDb).
			NewButton("Import", "Automatically import settings from nightly", nil),
		},
		SaveToDisk = false,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:NightlyImportDialog L1296-1315
	Profile.NightlyImportDialog = SettingsItem.New("Variant", nil :: unknown, {
		Id = "NightlyImportDialog",
		Visible = false,
		Title = "",
		Description = "",
		Section = SettingsSection.Other,
		Buttons = {
			NewButton("Choose file", "Import manually from a nightly settings file", function()
				-- DEVIATION: a file dialog has no Roblox equivalent; no implementation will be set.
				if Hooks.OpenNightlyImportDialog then
					Hooks.OpenNightlyImportDialog()
				end
			end),
		},
		SaveToDisk = false,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:ImportNightlyMeshes L1317-1338
	Profile.ImportNightlyMeshes = SettingsItem.New("Variant", nil :: unknown, {
		Id = "ImportNightlyMeshes",
		Visible = false,
		Title = "Import Nightly Meshes",
		Description = "Imports meshes from the nightly folder",
		Section = SettingsSection.Other,
		Buttons = {
			NewButton("Import Nightly Meshes", "Imports meshes from the nightly folder", function()
				-- DEVIATION: the nightly folder is an OS path; no Roblox implementation will be set.
				if Hooks.ImportMeshesFromNightly then
					Hooks.ImportMeshesFromNightly()
				end

				const Mesh = CurrentSettings(Profile).NoteMesh
				const MeshList = Mesh.List :: NewList.SettingsList<string>

				MeshList.Values = GetAvailableMeshes()

				if Hooks.RefreshSettingsList then
					Hooks.RefreshSettingsList(Mesh)
				end
			end),
		},
		SaveToDisk = false,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:ImportNightlyColorsets L1340-1361
	Profile.ImportNightlyColorsets = SettingsItem.New("Variant", nil :: unknown, {
		Id = "ImportNightlyColorsets",
		Visible = false,
		Title = "Import Nightly Colorsets",
		Description = "Imports colorsets from the nightly folder",
		Section = SettingsSection.Other,
		Buttons = {
			NewButton("Import Nightly Colorsets", "Imports colorsets from the nightly folder", function()
				-- DEVIATION: the nightly folder is an OS path; no Roblox implementation will be set.
				if Hooks.ImportColorsetsFromNightly then
					Hooks.ImportColorsetsFromNightly()
				end

				if Hooks.LoadSettings then
					Hooks.LoadSettings()
				end

				if Hooks.RefreshSettingsList then
					Hooks.RefreshSettingsList(CurrentSettings(Profile).NoteColors)
				end
			end),
		},
		SaveToDisk = false,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:SetUserFolderPath L1363-1375
	Profile.SetUserFolderPath = SettingsItem.New("string", Constants.UserFolder, {
		Id = "SetUserFolderPath",
		Visible = false,
		Title = "Path To User Folder",
		Description = "Set the path where Aimia stores it's files",
		Section = SettingsSection.Other,
		Placeholder = Constants.UserFolder,
		UpdateAction = SetUserFolderOnChange,
		SaveToDisk = false,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:SetUserFolderDialog L1377-1425
	Profile.SetUserFolderDialog = SettingsItem.New("Variant", nil :: unknown, {
		Id = "SetUserFolderDialog",
		Visible = false,
		Title = "",
		Description = "",
		Section = SettingsSection.Other,
		Buttons = {
			NewButton("Open Previous User Folder", "Open the path to the previously used User Folder", function()
				-- DEVIATION: PREVIOUS_USER_FOLDER is an OS path that Constants does not port, so it is always empty here and only
				-- the popup branch runs; OS.ShellShowInFileManager has no Roblox equivalent.
				if Hooks.HideSettingsMenu then
					Hooks.HideSettingsMenu()
				end

				if Hooks.ShowOptionPopup then
					Hooks.ShowOptionPopup(
						"No Previous User Folder Found",
						"You have no previous user folder. Either you didn't change your User Folder (and that's fine) or the record of it got deleted.",
						"Ok",
						function()
							if Hooks.ShowSettingsMenu then
								Hooks.ShowSettingsMenu()
							end
						end
					)
				end
			end),
			NewButton("Set User Folder Path", "Choose the path to the User Folder", function()
				-- DEVIATION: a file dialog has no Roblox equivalent; no implementation will be set.
				if Hooks.OpenUserFolderDialog then
					Hooks.OpenUserFolderDialog()
				end
			end),
		},
	})

	-- @src scripts/database/settings/SettingsProfile.cs:DisplayFPS L1427-1433
	Profile.DisplayFPS = SettingsItem.New("bool", true, {
		Id = "DisplayFPS",
		Title = "Display FPS",
		Description = "Shows how many frames per second the game runs at, in the bottom-left corner. Handy for spotting lag.",
		Section = SettingsSection.Other,
	})

	-- Not in the source (2026-11-22, the owner's ask): the list of who's spectating you stays off your screen during your songs
	-- (Client.Controllers.Handheld, spectatorsHidden). Only your screen changes: they still watch, and the server still counts them.
	Profile.HideSpectators = SettingsItem.New("bool", false, {
		Id = "HideSpectators",
		Title = "Hide Spectators",
		Description = "Hides the list of who's spectating you from the top left of your songs. They can still watch you; only your screen changes.",
		Section = SettingsSection.Other,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:RecordReplays L1435-1441
	-- (2026-11-10, the owner's rule: no longer a choice. Every run is recorded, so a run that makes a song's leaderboard can
	-- always be watched back to check it. The row is hidden and SettingsManager.Load turns a saved "off" back on. The value
	-- stays, because a replay's own copy of the settings sets it false so that watching one records nothing: Game/Attempt.)
	Profile.RecordReplays = SettingsItem.New("bool", true, {
		Id = "RecordReplays",
		Visible = false,
		Title = "Record Replays",
		Description = "Records each run so you can rewatch it until you leave the game, and so other players can watch your runs that make a song's leaderboard.",
		Section = SettingsSection.Other,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:OptionalPlaytestParameters L1443-1449
	Profile.OptionalPlaytestParameters = SettingsItem.New("bool", true, {
		Id = "OptionalPlaytestParameters",
		Visible = false,
		Title = "Use Editor Playtest Settings",
		Description = "Takes \"Start From\" and \"Speed\" from external editors like the SSQE when using the \"Playtest\" button",
		Section = SettingsSection.Other,
	})

	-- @src scripts/database/settings/SettingsProfile.cs:ResetToDefaults L1451-1469
	Profile.ResetToDefaults = SettingsItem.New("Variant", nil :: unknown, {
		Id = "ResetToDefaults",
		Title = "Reset to Defaults",
		Description = "Puts every setting in this profile back to how it started. You'll be asked to confirm first.",
		Section = SettingsSection.Other,
		Buttons = {
			NewButton("Reset", "WARNING: THIS RESETS YOUR CURRENT PROFILE", function()
				if Hooks.ResetToDefaults then
					Hooks.ResetToDefaults()
				end
			end),
		},
	})

	UpdateApproachTime()

	return Profile
end

-- The owner's settings (OwnerDefaults) on a profile made from nothing: a new player's first one and Reset to Defaults' copy.
-- Written as SettingsItem.New writes values: no update action runs and nothing is told. With AsDefault they are its defaults too
-- (an emptied slider box goes back to them). An entry that doesn't name a setting of its type is skipped.
const function ApplyOwnerDefaults(Profile: SettingsProfile, AsDefault: boolean?)
	for Name, Value in OwnerDefaults do
		const Item: any = (Profile :: any)[Name]

		if type(Item) == "table" and type(Item.DefaultValue) == type(Value) then
			Item.Value = Value

			if AsDefault then
				Item.DefaultValue = Value
			end

			if Item.List then
				Item.List.SelectedValue = Value

				if AsDefault then
					Item.List.DefaultValue = Value
				end
			end
		end
	end
end

return {
	New = New,
	ApplyOwnerDefaults = ApplyOwnerDefaults,
	Hooks = Hooks,
	Order = Order,
	ItemNamed = ItemNamed,
	ToOrderedSectionList = ToOrderedSectionList,
	ConfigureSetUserFolderPath = ConfigureSetUserFolderPath,
	LoadSkinOnChange = LoadSkinOnChange,
	RetiredSpaces = RetiredSpaces,
}
