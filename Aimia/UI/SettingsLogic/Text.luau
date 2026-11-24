--!strict
--!optimize 2

--[[
	Text rules of the settings menu and its popups, Roblox-free: the placeholder and slider texts, the slider entry parse,
	the popup node names, the link popup text and the section names.

	Design Notes
		DoubleText is .NET's double.ToString(InvariantCulture): the shortest of %.15g, %.16g and %.17g that reads back the
		same value, with the exponent letter in capitals. Slider values are multiples of 0.001, so they never reach the
		exponent form (.NET switches at 1E-05 and 1E+15; %g switches at the same magnitudes for these values).
]]

const Numbers = require("../../Numbers")
const DotnetNumber = require("../../Dotnet/Number")
const SettingsSection = require("../../Database/Settings/SettingsSection")

-- LinkPopupButton.InfoTemplate; "{0}" is the link (string.Format).
const LinkInfoTemplate = "[center][color=dddddd]This will open the following link:\n[color=aaaaff][i][u]{0}[/u][/i]\n\n[color=dddddd]Are you sure?"

const SectionNames = {
	[SettingsSection.Gameplay] = "Gameplay",
	[SettingsSection.Visual] = "Visual",
	[SettingsSection.Audio] = "Audio",
	[SettingsSection.Video] = "Video",
	[SettingsSection.Other] = "Other",
}

-- ToString("F4", InvariantCulture): the placeholder of a slider's text field.
const function PlaceholderText(Value: number): string
	return string.format("%.4f", Value)
end

-- Math.Round(value * 1000) / 1000: a slider value rounded to three decimals, half to even.
const function SliderValue(Value: number): number
	return Numbers.RoundHalfEven(Value * 1000) / 1000
end

-- double.ToString(InvariantCulture): the shortest text that reads back the same double.
const function DoubleText(Value: number): string
	local Text = string.format("%.15g", Value)

	if tonumber(Text) ~= Value then
		Text = string.format("%.16g", Value)
	end

	if tonumber(Text) ~= Value then
		Text = string.format("%.17g", Value)
	end

	return (string.gsub(Text, "e", "E"))
end

-- A slider box's text: a comma is a decimal point, empty text is the default (the placeholder), anything unreadable keeps Current.
const function ParseSliderText(Text: string, Placeholder: string, Current: number): number
	const Spaceless = string.gsub(Text, "%s", "")
	const Cleaned = string.gsub(Spaceless, ",", ".")

	if Cleaned == "" then
		return DotnetNumber.ParseDouble(Placeholder)
	end

	if string.match(Cleaned, "^[-+]?%d*%.?%d*$") and string.find(Cleaned, "%d") then
		return tonumber(Cleaned) or Current
	end

	return Current
end

-- The node name of an OptionPopup: "OptionPopup" and the header's letters, digits, "_" and "-" (MyRegex).
const function PopupName(Header: string): string
	const Kept = string.gsub(Header, "[^a-zA-Z0-9_%-]", "")

	return `OptionPopup{Kept}`
end

-- LinkInfoTemplate with the link in place of "{0}".
const function LinkInfo(Link: string): string
	const Text = string.gsub(LinkInfoTemplate, "{0}", function(): string
		return Link
	end)

	return Text
end

-- SettingsSection.ToString() of a section (the sidebar button shows it upper-cased).
const function SectionName(Section: number): string
	return SectionNames[Section]
end

return {
	PlaceholderText = PlaceholderText,
	SliderValue = SliderValue,
	DoubleText = DoubleText,
	ParseSliderText = ParseSliderText,
	PopupName = PopupName,
	LinkInfo = LinkInfo,
	LinkInfoTemplate = LinkInfoTemplate,
	SectionName = SectionName,
}
