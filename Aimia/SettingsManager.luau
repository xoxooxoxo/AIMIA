--!strict
--!optimize 2

--[[
	Profiles, the current profile, the user folder pointer and the running settings, as scripts/SettingsManager.cs.

	Design Notes
		Settings is created by Initialize: the C# field initializer runs when the autoload is constructed, after
		FileInitializer has mounted the meshes that the note mesh list reads. Initialize also sets the SettingsProfile hooks
		this module owns. Saved and Loaded are Util/Signal events. Menu is the settings menu, set by the UI; its Hide runs
		when the user folder changes, and UserFolderChanged fires with the new path for the UI's restart prompt.
		DEVIATION(platform): the user folder pointer is the file user_folder_path.txt at the root of the FileSystem, outside
		the user folder as the OS data folder is upstream. Constants.UserFolder is fixed ("user"), so a pointer change is
		stored but does not move the files, and GetUserFolder is not read at start.
		DEVIATION(platform): restarting the process (OS.CreateProcess) and the copy of the user folder are not ported.
		DEVIATION(platform): DEFAULT_USER_FOLDER is Constants.UserFolder, since the OS data folder does not exist here.
]]

const Constants = require("./Constants")
const DotnetString = require("./Dotnet/String")
const FileSystem = require("./Util/FileSystem")
const GodotString = require("./Godot/String")
const Logger = require("./Util/Logger")
const Notify = require("./Util/Notify")
const Signal = require("./Util/Signal")
const SettingsItem = require("./Database/Settings/SettingsItem")
const SettingsProfile = require("./Database/Settings/SettingsProfile")
const SettingsProfileConverter = require("./Database/Settings/SettingsProfileConverter")
const SkinManager = require("./Skinning/SkinManager")
const SkinSets = require("./Skinning/SkinSets")

-- The user folder pointer (outside the user folder, as Constants.USER_FOLDER_POINTER) and its default folder.
const UserFolderPointer = "user_folder_path.txt"
const DefaultUserFolder = Constants.UserFolder

-- Settings that keep their value on a reset (excludeFromReset).
const ResetExcluded = {
	SetUserFolderPath = true,
	SetUserFolderDialog = true,
}

const SettingsManager = {
	Settings = nil :: SettingsProfile.SettingsProfile?,
	Shown = false,
	HideNotifications = false,
	-- True while a load writes the settings: the skin is loaded once at its end, not once per skin setting.
	Loading = false,
	-- The default profile and 10 more (AIMIA_PROFILES_MAX in the server's Social says the same).
	MaxProfiles = 11,
	Menu = nil :: { Hide: () -> (), ShowMenu: (Show: boolean?) -> () }?,
	Saved = Signal.New() :: Signal.Signal<()>,
	Loaded = Signal.New() :: Signal.Signal<()>,
	UserFolderChanged = Signal.New() :: Signal.Signal<string>,
}

-- Whether a name can be a profile's file. 101 bytes is what the server's 120 byte path limit leaves.
const function SafeProfileName(Name: string): boolean
	return Name ~= "" and #Name <= 101 and not string.find(Name, "[/\\%c]")
end

-- Adds the base name of each user file to the choices of a list item (addUserContentToSettingsList).
const function AddUserContent(Item: SettingsItem.SettingsItem<string>, Options: { string })
	const Values = (Item.List :: { Values: { string } }).Values

	for _, Option in Options do
		const Name = GodotString.GetBaseName(GodotString.GetFile(Option))

		if table.find(Values, Name) == nil then
			table.insert(Values, Name)
		end
	end
end

-- The SettingsProfile hooks this module implements (SettingsProfile.Hooks), set by Initialize.
const function CurrentSettingsHook(): SettingsProfile.SettingsProfile
	return SettingsManager.Settings :: SettingsProfile.SettingsProfile
end

const function LoadSettingsHook()
	SettingsManager.Load(nil)
end

-- What the skin was last loaded from: the values of the settings that load it when they change.
local LoadedSkin: string? = nil

const function SkinValues(Settings: SettingsProfile.SettingsProfile): string
	const Values: { string } = {}

	for _, Name in SettingsProfile.Order do
		const Item: any = SettingsProfile.ItemNamed(Settings, Name)

		if Item.UpdateAction == SettingsProfile.LoadSkinOnChange then
			table.insert(Values, tostring(Item.Value))
		end
	end

	return table.concat(Values, "\n")
end

const function LoadSkin(Settings: SettingsProfile.SettingsProfile, ShowToast: boolean)
	LoadedSkin = SkinValues(Settings)
	SkinManager.Load(Settings, ShowToast)
end

const function LoadSkinHook()
	if SettingsManager.Loading then
		return
	end

	LoadSkin(SettingsManager.Settings :: SettingsProfile.SettingsProfile, not SettingsManager.HideNotifications)
end

-- @src scripts/SettingsManager.cs:Save L36-49
function SettingsManager.Save(ProfileName: string?)
	const Name = ProfileName or SettingsManager.GetCurrentProfile()
	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile
	const Data = SettingsProfileConverter.Serialize(Settings)

	FileSystem.WriteAllText(`{Constants.UserFolder}/profiles/{Name}.json`, Data)
	Logger.Log(`Saved settings {Name}`)
	Signal.Fire(SettingsManager.Saved)
	SkinManager.Save(Settings)
end

-- @src scripts/SettingsManager.cs:Load L51-94
function SettingsManager.Load(ProfileName: string?)
	const Name = ProfileName or SettingsManager.GetCurrentProfile()
	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile
	const Path = `{Constants.UserFolder}/profiles/{Name}.json`

	SettingsManager.Loading = true

	const Success, Failure = pcall(SettingsProfileConverter.Deserialize, Path, Settings)

	SettingsManager.Loading = false

	if Success then
		Notify.Notify(`Loaded profile [{Name}]`)
	else
		Notify.Notify("Settings file corrupted", 2)
		Logger.ErrorException(Failure)

		-- Leave a file that can't be read, so no later save writes over it.
		if Name ~= "default" then
			SettingsManager.SetCurrentProfile("default")
			SettingsManager.Load("default")

			return
		end
	end

	const SkinFolder = `{Constants.UserFolder}/skins/{Settings.Skin.Value}`

	if not FileSystem.DirectoryExists(SkinFolder) then
		SettingsItem.SetValue(Settings.Skin, "default")

		-- Kept from the source: the message reads the skin after the reset, so it names "default".
		Notify.Notify(`Could not find skin {Settings.Skin.Value}`, 1)
	end

	AddUserContent(Settings.Skin, FileSystem.GetDirectories(`{Constants.UserFolder}/skins`))
	AddUserContent(Settings.NoteColors, FileSystem.GetFiles(`{Constants.UserFolder}/colorsets`))

	-- (not in the source, 2026-11-07: the grid's + marks start off for everyone, once; whoever turns them back on keeps them)
	if not Settings.GridGuidesOff.Value then
		SettingsItem.SetValue(Settings.GridGuides, false)
		SettingsItem.SetValue(Settings.GridGuidesOff, true)
	end

	-- (not in the source, 2026-11-10: Record Replays is no longer a choice, so a profile saved with it off turns it back on.
	-- Every run is recorded: a run on a song's leaderboard can always be watched back.)
	if not Settings.RecordReplays.Value then
		SettingsItem.SetValue(Settings.RecordReplays, true)
	end

	-- (the Popups list shows what the two popup switches are)
	const Hits, Misses = Settings.HitPopups.Value, Settings.MissPopups.Value

	SettingsItem.SetValue(Settings.Popups, if Hits and Misses then "both" elseif Hits then "hits only" elseif Misses then "misses only" else "off")

	-- (2026-11-07: a background that was taken out turns back to the skin's. Set as a load sets values, so the menu's row shows
	-- it too; the skin loads once, below)
	SettingsManager.Loading = true

	for _, Item in { Settings.MenuSpace, Settings.GameSpace } do
		if SettingsProfile.RetiredSpaces[Item.Value] then
			SettingsItem.SetValue(Item, "skin")
		end
	end

	-- (a map skin set that was renamed shows under its new name, so the menu's rows find it)
	for _, Item in { Settings.GameSpace, Settings.MenuSpace, Settings.Border, Settings.CursorStyle, Settings.CursorColor, Settings.NoteColors, Settings.NoteMesh, Settings.TrailColor, Settings.TrailImage } do
		const NewName = SkinSets.Renamed[Item.Value :: string]

		if NewName then
			SettingsItem.SetValue(Item, NewName)
		end
	end

	SettingsManager.Loading = false

	Logger.Log(`Loaded settings {Name}`)
	Signal.Fire(SettingsManager.Loaded)

	-- (a skin load restarts the menu music, so a switch only does one when the new profile needs it)
	if SkinValues(Settings) ~= LoadedSkin then
		LoadSkin(Settings, false)
	end
end

-- @src scripts/SettingsManager.cs:Reload L96-100
function SettingsManager.Reload()
	SettingsManager.Save()
	SettingsManager.Load()
end

-- @src scripts/SettingsManager.cs:SetCurrentProfile L102-107
function SettingsManager.SetCurrentProfile(ProfileName: string?)
	const Name = ProfileName or SettingsManager.GetCurrentProfile()

	FileSystem.WriteAllText(`{Constants.UserFolder}/current_profile.txt`, Name)
end

-- @src scripts/SettingsManager.cs:GetCurrentProfile L109-119
function SettingsManager.GetCurrentProfile(): string
	const Path = `{Constants.UserFolder}/current_profile.txt`

	if FileSystem.Exists(Path) then
		const Name = FileSystem.ReadAllText(Path)

		-- (a name no file can have means default: nothing could ever save under it)
		if SafeProfileName(Name) then
			return Name
		end
	end

	return "default"
end

-- What's wrong with a name typed for a new profile, or nil.
function SettingsManager.ProfileProblem(Name: string): string?
	if #Name > 32 then
		return "That name is too long"
	end

	if not SafeProfileName(Name) then
		return "Profile names can't use / or \\"
	end

	return nil
end

-- Deletes a profile's file (never default's). The current one moves to default first, so no pending save can bring it back.
function SettingsManager.DeleteProfile(Name: string)
	if Name == "default" then
		return
	end

	if Name == SettingsManager.GetCurrentProfile() then
		SettingsManager.SetCurrentProfile("default")
		SettingsManager.Load()
	end

	FileSystem.Delete(`{Constants.UserFolder}/profiles/{Name}.json`)
end

-- @src scripts/SettingsManager.cs:GetUserFolderPointerContent L121-155
function SettingsManager.GetUserFolderPointerContent(): (string, string)
	local CurrentDir = ""
	local PreviousDir = ""

	if not FileSystem.Exists(UserFolderPointer) or DotnetString.IsNullOrWhiteSpace(FileSystem.ReadAllText(UserFolderPointer)) then
		FileSystem.WriteAllText(UserFolderPointer, `CurrentDir:{DefaultUserFolder}\nPreviousDir:`)

		return DefaultUserFolder, ""
	end

	const PointerContent = DotnetString.Trim(FileSystem.ReadAllText(UserFolderPointer))

	for _, Line in DotnetString.Split(PointerContent, "\n") do
		-- TrimEnd('\r')
		const NormalLine = DotnetString.TrimBytes(Line, { [13] = true }, false, true)

		if DotnetString.StartsWith(NormalLine, "CurrentDir:") then
			CurrentDir = GodotString.TrimPrefix(NormalLine, "CurrentDir:")
		elseif DotnetString.StartsWith(NormalLine, "PreviousDir:") then
			PreviousDir = GodotString.TrimPrefix(NormalLine, "PreviousDir:")
		else
			Logger.Error("Unexpected line in user pointer file.")
		end
	end

	return CurrentDir, PreviousDir
end

-- @src scripts/SettingsManager.cs:GetUserFolder L157-175
function SettingsManager.GetUserFolder(): string
	const CurrentDir, PreviousDir = SettingsManager.GetUserFolderPointerContent()
	const Success, Failure = pcall(FileSystem.GetFiles, CurrentDir, nil)

	if not Success then
		FileSystem.WriteAllText(UserFolderPointer, `CurrentDir:{DefaultUserFolder}\nPreviousDir:{PreviousDir}`)
		Logger.ErrorException(Failure)

		return DefaultUserFolder
	end

	return CurrentDir
end

-- @src scripts/SettingsManager.cs:GetPreviousUserFolder L177-198
function SettingsManager.GetPreviousUserFolder(): string
	const PreviousDir = select(2, SettingsManager.GetUserFolderPointerContent())

	if DotnetString.IsNullOrWhiteSpace(PreviousDir) then
		return ""
	end

	const Success, Failure = pcall(FileSystem.GetFiles, PreviousDir, nil)

	if not Success then
		Logger.ErrorException(Failure)

		return ""
	end

	return PreviousDir
end

-- @src scripts/SettingsManager.cs:SetUserFolder L200-230
function SettingsManager.SetUserFolder(Path: string)
	const Success, Failure = pcall(FileSystem.GetFiles, Path, nil)

	if not Success then
		Notify.Notify("Invalid User Path. Setting has not been changed.", 2)
		Logger.ErrorException(Failure)

		return
	end

	FileSystem.WriteAllText(UserFolderPointer, `CurrentDir:{Path}\nPreviousDir:{Constants.UserFolder}`)

	if SettingsManager.Menu then
		SettingsManager.Menu.Hide()
	end

	Signal.Fire(SettingsManager.UserFolderChanged, Path)
end

-- @src scripts/SettingsManager.cs:ResetToDefaults L234-259
function SettingsManager.ResetToDefaults()
	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile
	const Defaults = SettingsProfile.New()

	-- (2026-11-22: the defaults are the owner's settings, SettingsProfile.OwnerDefaults)
	SettingsProfile.ApplyOwnerDefaults(Defaults)
	SettingsManager.HideNotifications = true

	for _, Name in SettingsProfile.Order do
		if ResetExcluded[Name] then
			continue
		end

		const Current = SettingsProfile.ItemNamed(Settings, Name)
		const Default = SettingsProfile.ItemNamed(Defaults, Name)

		SettingsItem.SetVariant(Current, SettingsItem.GetVariant(Default))
	end

	SettingsManager.Save()
	SettingsManager.HideNotifications = false

	Notify.Notify("Settings reset to default successfully!")
end

-- The profile is built here (the source builds it in the field initializer, after FileInitializer), then the hooks the
-- profile calls are set. The platform and UI hooks stay unset.
-- @src scripts/SettingsManager.cs:_Ready L29-34
function SettingsManager.Initialize()
	SettingsManager.Settings = SettingsProfile.New()

	const Hooks = SettingsProfile.Hooks

	Hooks.CurrentSettings = CurrentSettingsHook
	Hooks.LoadSettings = LoadSettingsHook
	Hooks.LoadSkin = LoadSkinHook
	Hooks.ResetToDefaults = SettingsManager.ResetToDefaults
	Hooks.SetUserFolder = SettingsManager.SetUserFolder
end

return SettingsManager
