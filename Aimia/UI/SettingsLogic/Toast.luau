--!strict
--!optimize 2

--[[
	Toast rules, Roblox-free: the severity color and the wrap of a message to the toast width (ToastNotification.cs).

	Design Notes
		WrapText keeps the source's joins: every word is followed by a space, and a line break replaces the space that ends
		the line. A first word wider than the toast throws, as upstream's list index does; the toast is then left in the scene
		without its text.
]]

const Color = require("../../Godot/Color")
const DotnetString = require("../../Dotnet/String")
const Numbers = require("../../Numbers")

-- ToastNotification.Notify: green, yellow or red for severity 0, 1 or 2 (clamped).
const function SeverityColor(Severity: number): Color.Color
	const Clamped = math.clamp(Severity, 0, 2)

	if Clamped == 0 then
		return Color.Color8(0, 255, 0)
	elseif Clamped == 1 then
		return Color.Color8(255, 255, 0)
	end

	return Color.Color8(255, 0, 0)
end

-- calculateMultilineWrap: the text with a line break wherever a word would pass MaxWidth. MeasureWidth is the width of one
-- word on one line; the widths and the sums are float32, as in the source.
const function WrapText(MaxWidth: number, Text: string, MeasureWidth: (string) -> number): string
	const Words = DotnetString.Split(Text, " ")
	const Normalized: { string } = {}

	local LineWidth = 0

	for _, Word in Words do
		const WordWidth = Numbers.F32(MeasureWidth(Word))

		if Numbers.F32(LineWidth + WordWidth) > MaxWidth then
			if #Normalized == 0 then
				error("Index was out of range. Must be non-negative and less than the size of the collection. (Parameter 'index')", 0)
			end

			Normalized[#Normalized] = "\n"
			LineWidth = 0
		end

		LineWidth = Numbers.F32(LineWidth + WordWidth)

		table.insert(Normalized, Word)
		table.insert(Normalized, " ")
	end

	return table.concat(Normalized)
end

return {
	SeverityColor = SeverityColor,
	WrapText = WrapText,
}
