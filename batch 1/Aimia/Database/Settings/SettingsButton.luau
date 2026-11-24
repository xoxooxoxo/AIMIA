--!strict
--!optimize 2

--[[
	A button under a settings item, as scripts/database/settings/SettingsButton.cs.

	Design Notes
		OnPressed is the source's action; actions that drive other systems call SettingsProfile.Hooks.
]]

export type SettingsButton = {
	Title: string,
	Description: string,
	OnPressed: (() -> ())?,
}

-- @src scripts/database/settings/SettingsButton.cs:SettingsButton L3-10
const function New(Title: string, Description: string, OnPressed: (() -> ())?): SettingsButton
	return {
		Title = Title,
		Description = Description,
		OnPressed = OnPressed,
	}
end

return New
