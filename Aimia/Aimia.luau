--!strict
--!optimize 2

--[[
	Application state and startup, as scripts/Aimia.cs: the start order of the managers, the import of maps in other
	formats, the modifier list and the quit and window events.

	Design Notes
		Start is _Ready: FileInitializer first (SettingsManager's profile reads the meshes it mounts), then SettingsManager, the
		default profile, the settings load, the stats and the map import. SkinManager and KeybindsManager have no state to
		initialize, so they are not started here.
		Quit keeps the source's guard and order: a run is stopped unless it is a replay, the playtime is added, then the settings
		and stats are saved. The source's 0.5 s delay before the process quits is the host's: Hooks.Quit runs after the save.
		CloseRequested, ApplicationFocusIn and ApplicationFocusOut are the source's window notifications, called by the host.
		DEVIATION(platform): command-line parameters (--t, --a, --sp, --sf) do not exist, so TempMode is never set; the temporary
		map mode (TempMods, TempCam, the playtest parameters) is not ported.
		DEVIATION(platform): files dropped on the window have no Roblox equivalent; the files_dropped handler and FilesDropped
		are not ported.
		DEVIATION(platform): Engine.MaxFps is Hooks.SetMaxFps. Discord presence (util/Discord.cs) is not ported, so nothing is
		disposed on quit.
		DEVIATION(time): Quitting is logged when Quit runs, not after the source's 0.5 s tween.
		Not ported: RegisterCameraModes (CameraLock and CameraSpin are the camera packet's; that packet is not ported yet).
]]

const Constants = require("./Constants")
const FileInitializer = require("./FileInitializer")
const FileSystem = require("./Util/FileSystem")
const GodotString = require("./Godot/String")
const Logger = require("./Util/Logger")
const MapParser = require("./Map/MapParser")
const SettingsManager = require("./SettingsManager")
const SettingsProfile = require("./Database/Settings/SettingsProfile")
const Stats = require("./Database/Stats")
const Modifier = require("./Game/Modifiers/Modifier")
const AutoplayModifier = require("./Game/Modifiers/AutoplayModifier")
const ChaosModifier = require("./Game/Modifiers/ChaosModifier")
const EarthquakeModifier = require("./Game/Modifiers/EarthquakeModifier")
const GhostModifier = require("./Game/Modifiers/GhostModifier")
const HorizontalFlipModifier = require("./Game/Modifiers/HorizontalFlipModifier")
const NoFailModifier = require("./Game/Modifiers/NoFailModifier")
const StrobeModifier = require("./Game/Modifiers/StrobeModifier")
const VerticalFlipModifier = require("./Game/Modifiers/VerticalFlipModifier")
const VortexModifier = require("./Game/Modifiers/VortexModifier")

export type AimiaHooks = {
	IsGameScene: (() -> boolean)?,
	IsPlaying: (() -> boolean)?,
	StopRun: ((Results: boolean) -> ())?,
	SetMaxFps: ((Fps: number) -> ())?,
	Quit: (() -> ())?,
}

const Hooks: AimiaHooks = {}

-- Set once Start has finished; Quit saves only after that (the source's loaded flag).
local Loaded = false

const Aimia = {
	Quitting = false,
	Modifiers = {} :: { Modifier.Modifier },
	Hooks = Hooks,
}

-- The files under a folder, its subfolders included (Directory.EnumerateFiles with AllDirectories).
const function ListFiles(Folder: string, Found: { string })
	for _, FilePath in FileSystem.GetFiles(Folder) do
		table.insert(Found, FilePath)
	end

	for _, Child in FileSystem.GetDirectories(Folder) do
		ListFiles(Child, Found)
	end
end

-- @src scripts/Aimia.cs:_Ready L31-186
function Aimia.Start()
	FileInitializer()
	SettingsManager.Initialize()

	if not FileSystem.Exists(`{Constants.UserFolder}/profiles/default.json`) then
		-- (2026-11-22: a new player's first profile starts on the owner's settings, SettingsProfile.OwnerDefaults)
		SettingsProfile.ApplyOwnerDefaults(SettingsManager.Settings :: SettingsProfile.SettingsProfile, true)
		SettingsManager.Save("default")
	end

	const LoadSucceeded, LoadFailure = pcall(SettingsManager.Load, nil)

	if not LoadSucceeded then
		Logger.ErrorException(LoadFailure)
		SettingsManager.Save()
	end

	Stats.Initialize()
	Stats.Instance.GamesOpened += 1

	const Found: { string } = {}

	ListFiles(`{Constants.UserFolder}/maps`, Found)

	const NonConverted: { string } = {}

	for _, FilePath in Found do
		const Extension = string.lower(GodotString.GetExtension(FilePath))

		if Extension ~= Constants.DefaultMapExt and MapParser.IsValidExt(Extension) then
			table.insert(NonConverted, FilePath)
		end
	end

	MapParser.BulkImport(NonConverted, true)

	for _, FilePath in NonConverted do
		FileSystem.Delete(FilePath)
	end

	-- RegisterModifiers
	Aimia.Modifiers = {
		NoFailModifier(),
		AutoplayModifier(),
		GhostModifier(),
		StrobeModifier(),
		ChaosModifier(),
		VortexModifier(),
		EarthquakeModifier(),
		HorizontalFlipModifier(),
		VerticalFlipModifier(),
	}

	Loaded = true
end

-- @src scripts/Aimia.cs:Quit L209-247
function Aimia.Quit()
	if Aimia.Quitting then
		return
	end

	Aimia.Quitting = true

	Logger.Log("Attempting to quit...")

	if Hooks.IsPlaying and Hooks.IsPlaying() and Hooks.StopRun then
		Hooks.StopRun(false)
	end

	-- (Time.GetTicksUsec() - Constants.STARTED) / 1000000, whole seconds
	Stats.Instance.TotalPlaytime += (os.clock() - Constants.Started) // 1

	if Loaded then
		SettingsManager.Save()
		Stats.Save()
	end

	Logger.Log("Quitting")

	if Hooks.Quit then
		Hooks.Quit()
	end
end

-- The window close request (NotificationWMCloseRequest): a close during a run counts as a rage quit, then Quit.
-- @src scripts/Aimia.cs:_Notification L249-269
function Aimia.CloseRequested()
	if Hooks.IsGameScene and Hooks.IsGameScene() then
		Stats.Instance.RageQuits += 1
	end

	Aimia.Quit()
end

-- @src scripts/Aimia.cs:_Notification L249-269
function Aimia.ApplicationFocusOut()
	if Hooks.SetMaxFps then
		Hooks.SetMaxFps(30)
	end
end

-- @src scripts/Aimia.cs:_Notification L249-269
function Aimia.ApplicationFocusIn()
	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile

	if Hooks.SetMaxFps then
		Hooks.SetMaxFps(if Settings.LockFPS.Value then Settings.FPS.Value else 0)
	end
end

return Aimia
