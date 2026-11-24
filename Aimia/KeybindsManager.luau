--!strict
--!optimize 2

--[[
	The global key shortcuts, as scripts/KeybindsManager.cs: F1 opens the wiki popup outside a run, F11 and Alt+Enter toggle
	fullscreen, and Ctrl+M mutes the master volume.

	Design Notes
		The source has no InputMap actions and no file of bindings: they are the Bindings table, by Godot key name. UI/Input
		turns Roblox input into a KeyEvent with those names.
		VolumeBeforeMute is the master volume before the last mute, a float32, or -1 when nothing is muted.
		DEVIATION(platform): DisplayServer's window mode has no Roblox equivalent. The source sets Fullscreen to whether the
		window is windowed; here the window is taken to follow Fullscreen, so the toggle sets Fullscreen to its negation.
		The wiki popup is the UI's: ToggleWikiPopup runs when no run is on (IsPlaying unset means no run).
]]

const Numbers = require("./Numbers")
const SettingsItem = require("./Database/Settings/SettingsItem")
const SettingsManager = require("./SettingsManager")
const SettingsProfile = require("./Database/Settings/SettingsProfile")

export type KeyEvent = {
	Keycode: string?,
	Pressed: boolean,
	AltPressed: boolean,
	CtrlPressed: boolean,
}

export type Binding = {
	Key: string,
	Alt: boolean,
	Ctrl: boolean,
}

export type KeybindHooks = {
	IsPlaying: (() -> boolean)?,
	ToggleWikiPopup: (() -> ())?,
}

-- The bindings of each action, by Godot key name. A binding with Alt or Ctrl needs that modifier; without it, any
-- modifiers pass (F1 and F11 do not look at them upstream).
const Bindings = {
	Wiki = {
		{ Key = "F1", Alt = false, Ctrl = false },
	},
	Fullscreen = {
		{ Key = "F11", Alt = false, Ctrl = false },
		{ Key = "Enter", Alt = true, Ctrl = false },
		{ Key = "KpEnter", Alt = true, Ctrl = false },
	},
	Mute = {
		{ Key = "M", Alt = false, Ctrl = true },
	},
}

const WikiLink = ""

const Hooks: KeybindHooks = {}

-- The master volume before the last mute, a float32; -1 when nothing is muted.
local VolumeBeforeMute = -1

const KeybindsManager = {
	WikiLink = WikiLink,
	Bindings = Bindings,
	Hooks = Hooks,
}

const function Matches(Candidates: { Binding }, Event: KeyEvent): boolean
	for _, Candidate in Candidates do
		if Candidate.Key == Event.Keycode and (not Candidate.Alt or Event.AltPressed) and (not Candidate.Ctrl or Event.CtrlPressed) then
			return true
		end
	end

	return false
end

-- The mute of Ctrl+M: the master volume goes to 0 and its value is kept; the next press restores it. The volume is
-- updated after either step (SoundManager.UpdateVolume, the profile's UpdateVolume hook).
const function ToggleMute(Settings: SettingsProfile.SettingsProfile)
	if VolumeBeforeMute < 0 then
		VolumeBeforeMute = Numbers.F32(Settings.VolumeMaster.Value)
		SettingsItem.SetValue(Settings.VolumeMaster, 0)
	else
		SettingsItem.SetValue(Settings.VolumeMaster, VolumeBeforeMute)
		VolumeBeforeMute = -1
	end

	if SettingsProfile.Hooks.UpdateVolume then
		SettingsProfile.Hooks.UpdateVolume()
	end
end

-- @src scripts/KeybindsManager.cs:_Input L25-69
function KeybindsManager.HandleKey(Event: KeyEvent)
	if not Event.Pressed then
		return
	end

	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile

	if Matches(Bindings.Wiki, Event) then
		const Playing = if Hooks.IsPlaying then Hooks.IsPlaying() else false

		if not Playing and Hooks.ToggleWikiPopup then
			Hooks.ToggleWikiPopup()
		end
	elseif Matches(Bindings.Fullscreen, Event) then
		SettingsItem.SetValue(Settings.Fullscreen, not Settings.Fullscreen.Value)
	end

	if Matches(Bindings.Mute, Event) then
		ToggleMute(Settings)
	end
end

return KeybindsManager
