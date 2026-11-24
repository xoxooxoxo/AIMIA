--!strict
--!optimize 2

--[[
	The settings file of a profile, as scripts/database/settings/SettingsProfileConverter.cs.

	Design Notes
		Keys are the item property names (NoteColors, not its Id Colors) and the "_Version" key. Only SaveToDisk items
		are written; a Variant item with no value is written as null (Json.Null), so its key exists on read.
		Float items are written rounded to 4 digits: Math.Round((float)value, 4), the float32 value (Numbers.F32) rounded
		by Round4. The JSON text uses Godot/Json's format, a DEVIATION from Godot's number text (see its header).
]]

const Numbers = require("../../Numbers")
const Json = require("../../Godot/Json")
const FileSystem = require("../../Util/FileSystem")
const SettingsItem = require("./SettingsItem")
const SettingsProfile = require("./SettingsProfile")

const Version = 1

-- Math.Round(double, 4), .NET's default ToEven: scale by 10^4, round half to even, unscale. Values of 1e16 or more
-- (and NaN) are returned as they are. Checked against the .NET oracle (external/Oracle/Cases/Settings.cs).
const function Round4(Value: number): number
	if math.abs(Value) < 1e16 then
		return Numbers.RoundHalfEven(Value * 10000) / 10000
	end

	return Value
end

-- @src scripts/database/settings/SettingsProfileConverter.cs:Serialize L12-40
const function Serialize(Profile: SettingsProfile.SettingsProfile): string
	const Data: { [string]: unknown } = {}

	Data["_Version"] = Version

	for _, Name in SettingsProfile.Order do
		const Item = SettingsProfile.ItemNamed(Profile, Name)

		if Item.SaveToDisk then
			local Value = SettingsItem.GetVariant(Item)

			-- JSON has no NaN or infinity: one would make the whole file unreadable.
			if type(Value) == "number" and not math.isfinite(Numbers.F32(Value)) then
				Value = Item.DefaultValue
			end

			if Value == nil then
				Data[Name] = Json.Null
			elseif Item.Type == "double" or Item.Type == "float" then
				Data[Name] = Round4(Numbers.F32(Value :: number))
			else
				Data[Name] = Value
			end
		end
	end

	return Json.Stringify(Data, "\t")
end

-- @src scripts/database/settings/SettingsProfileConverter.cs:Deserialize L42-70
const function Deserialize(Path: string, Profile: SettingsProfile.SettingsProfile)
	const Parsed = Json.Parse(FileSystem.ReadAllText(Path))

	-- The C# cast to Dictionary fails for any other JSON value (a parse error gives nil there too).
	if type(Parsed) ~= "table" or #(Parsed :: { unknown }) > 0 then
		error("Unable to cast the settings file to a Dictionary.", 0)
	end

	const Data = Parsed :: { [string]: unknown }

	for _, Name in SettingsProfile.Order do
		const Item = SettingsProfile.ItemNamed(Profile, Name)

		if not Item.SaveToDisk then
			continue
		end

		const Entry = Data[Name]

		-- A bad value resets its own item and the rest of the file still loads.
		if Entry ~= nil and SettingsItem.Accepts(Item, Entry) then
			SettingsItem.SetVariant(Item, Entry)
		else
			SettingsItem.Reset(Item)
		end
	end
end

return {
	Round4 = Round4,
	Serialize = Serialize,
	Deserialize = Deserialize,
}
