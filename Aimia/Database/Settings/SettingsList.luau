--!strict
--!optimize 2

--[[
	The choices of a settings item, as scripts/database/settings/SettingsList.cs. ISettingsList is replaced by the
	SettingsList<T> type: its Variant members are the typed fields.

	Design Notes
		SelectedValue follows the item's Value (SettingsItem.SetValue). The C# constructor adds Value to Values and the
		object initializer then replaces Values, so New takes the replacement list and the first list is never built.
]]

export type SettingsList<T> = {
	SelectedValue: T,
	DefaultValue: T,
	Values: { T },
}

-- @src scripts/database/settings/SettingsList.cs:SettingsList L6-11
const function New<T>(Value: T, Values: { T }?): SettingsList<T>
	return {
		SelectedValue = Value,
		DefaultValue = Value,
		Values = Values or { Value },
	}
end

return New
