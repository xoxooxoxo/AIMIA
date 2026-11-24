--!strict
--!optimize 2

--[[
	Settings sections, as scripts/database/settings/SettingsSection.cs. The values are the C# ones.
]]

export type SettingsSection = number

return {
	None = 0,
	Gameplay = 1,
	Visual = 2,
	Audio = 3,
	Video = 4,
	Other = 5,
}
