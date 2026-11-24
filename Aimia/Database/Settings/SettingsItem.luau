--!strict
--!optimize 2

--[[
	One profile setting, as scripts/database/settings/SettingsItem.cs (generic SettingsItem<T>). The ISettingsItem interface
	is the export type of that name: its members that do not depend on T (its methods are the module functions).

	Design Notes
		Type is the C# type name ("double", "float", "int", "bool", "string", "Variant"); GetVariant and SetVariant convert
		as Variant.As<T> does for the values of the settings file. Value is a field: every write goes through SetValue,
		which runs the C# setter's steps in order. New stores the value before Id and UpdateAction are set (the C#
		constructor runs before the object initializer), so construction calls no UpdateAction and Initialized stays false.
		UpdateAction(Value, Initializing) receives Initializing = true on the first SetValue after construction, the
		argument C# passes as !init. Updated fires with the value itself.
]]

const Numbers = require("../../Numbers")
const Json = require("../../Godot/Json")
const Signal = require("../../Util/Signal")
const SettingsButton = require("./SettingsButton")
const SettingsList = require("./SettingsList")
const SettingsSection = require("./SettingsSection")
const SettingsSlider = require("./SettingsSlider")

export type ISettingsItem = {
	Id: string,
	Type: string,
	Title: string,
	Description: string,
	Placeholder: string,
	Buttons: { SettingsButton.SettingsButton },
	Slider: SettingsSlider.SettingsSlider?,
	Section: number,
	Editable: boolean,
	Visible: boolean,
	SaveToDisk: boolean,
}

export type SettingsItem<T> = {
	Value: T,
	DefaultValue: T,
	Type: string,
	Id: string,
	Title: string,
	Description: string,
	Placeholder: string,
	Buttons: { SettingsButton.SettingsButton },
	List: SettingsList.SettingsList<T>?,
	Slider: SettingsSlider.SettingsSlider?,
	Section: number,
	Editable: boolean,
	Visible: boolean,
	SaveToDisk: boolean,
	UpdateAction: ((T, boolean) -> ())?,
	Updated: Signal.Signal<T>,
	Initialized: boolean,
}

-- The object initializer's fields of a C# `new(value) { ... }`.
export type Initializer<T> = {
	Id: string?,
	Title: string?,
	Description: string?,
	Placeholder: string?,
	Buttons: { SettingsButton.SettingsButton }?,
	List: SettingsList.SettingsList<T>?,
	Slider: SettingsSlider.SettingsSlider?,
	Section: number?,
	Editable: boolean?,
	Visible: boolean?,
	SaveToDisk: boolean?,
	UpdateAction: ((T, boolean) -> ())?,
}

-- Variant.As<T> of a value read from the settings file (JSON number, boolean, string or null). A Variant item takes
-- any value, and null is nil. DEVIATION: Godot converts across types too (a string to a number, a number to a bool);
-- here a value of another type errors.
const function AsType(Type: string, Stored: unknown): unknown
	if Type == "Variant" then
		return if Stored == Json.Null then nil else Stored
	end

	const Kind = type(Stored)

	if (Type == "double" or Type == "float") and Kind == "number" then
		return Stored
	elseif Type == "int" and Kind == "number" then
		return Numbers.TruncInt32(Stored :: number)
	elseif Type == "bool" and Kind == "boolean" then
		return Stored
	elseif Type == "string" and Kind == "string" then
		return Stored
	end

	error(`Settings value of type {Kind} does not convert to {Type}`, 0)
end

-- @src scripts/database/settings/SettingsItem.cs:SettingsItem L9-13
const function New<T>(Type: string, Value: T, Fields: Initializer<T>): SettingsItem<T>
	const Item = {
		Value = Value,
		DefaultValue = Value,
		Type = Type,
		Id = "",
		Title = "",
		Description = "",
		Placeholder = "",
		Buttons = {},
		List = nil,
		Slider = nil,
		Section = SettingsSection.None,
		Editable = true,
		Visible = true,
		SaveToDisk = true,
		UpdateAction = nil,
		Updated = Signal.New(),
		Initialized = false,
	} :: SettingsItem<T>

	Item.Id = Fields.Id or Item.Id
	Item.Title = Fields.Title or Item.Title
	Item.Description = Fields.Description or Item.Description
	Item.Placeholder = Fields.Placeholder or Item.Placeholder
	Item.Buttons = Fields.Buttons or Item.Buttons
	Item.List = Fields.List
	Item.Slider = Fields.Slider
	Item.Section = Fields.Section or Item.Section
	Item.Editable = Fields.Editable ~= false
	Item.Visible = Fields.Visible ~= false
	Item.SaveToDisk = Fields.SaveToDisk ~= false
	Item.UpdateAction = Fields.UpdateAction

	return Item
end

-- @src scripts/database/settings/SettingsItem.cs:Value L43-60
const function SetValue<T>(Item: SettingsItem<T>, Value: T)
	Item.Value = Value

	if Item.List then
		Item.List.SelectedValue = Value
	end

	if Item.UpdateAction then
		Item.UpdateAction(Value, not Item.Initialized)
	end

	Signal.Fire(Item.Updated, Value)

	if not Item.Initialized and Item.Id ~= "" then
		Item.Initialized = true
	end
end

-- @src scripts/database/settings/SettingsItem.cs:GetVariant L62-62
const function GetVariant<T>(Item: SettingsItem<T>): unknown
	return Item.Value
end

-- @src scripts/database/settings/SettingsItem.cs:SetVariant L64-67
const function SetVariant<T>(Item: SettingsItem<T>, Stored: unknown)
	-- NaN and infinity never get in, and a number stays within its slider's limits. SetValue stays raw for replays.
	-- (float32, as the file keeps it: 1e39 is finite here and infinite once saved)
	if type(Stored) == "number" and not math.isfinite(Numbers.F32(Stored)) then
		return
	end

	local Value = AsType(Item.Type, Stored)
	const Slider = Item.Slider

	if Slider and type(Value) == "number" then
		Value = math.clamp(Value, Slider.Floor, Slider.Ceiling)
	end

	SetValue(Item, Value :: T)
end

-- Whether SetVariant can take a value read from the settings file.
const function Accepts<T>(Item: SettingsItem<T>, Stored: unknown): boolean
	if type(Stored) == "number" and not math.isfinite(Numbers.F32(Stored)) then
		return false
	end

	return (pcall(AsType, Item.Type, Stored))
end

-- @src scripts/database/settings/SettingsItem.cs:Reset L69-69
const function Reset<T>(Item: SettingsItem<T>)
	SetValue(Item, Item.DefaultValue)
end

return {
	New = New,
	SetValue = SetValue,
	GetVariant = GetVariant,
	SetVariant = SetVariant,
	Accepts = Accepts,
	Reset = Reset,
}
