--!strict
--!optimize 2

--[[
	The text of a map button (scripts/ui/menu/play/MapButtonWide.cs, MapButtonSquare.cs): the length as m:ss, Godot's
	Color.ToHtml, and the BBCode line of the wide button. Roblox-free.

	Design Notes
		The length is Map.Length / 1000 in C# int division, so whole seconds (Map lengths are never negative).
		ToHtml writes lowercase hex: BBCode reads the color either way, so the case is not observable.
]]

const Numbers = require("../../../../Numbers")
const UtilString = require("../../../../Util/String")

type ColorTable = {
	R: number,
	G: number,
	B: number,
	A: number,
}

-- A channel as the byte ToHex32 writes: round(clamp(c * 255)), half to even (Mathf.RoundToInt).
const function ChannelHex(Channel: number): string
	return string.format("%02x", Numbers.RoundHalfEven(math.clamp(Channel * 255, 0, 255)))
end

-- Color.ToHtml(includeAlpha: true): the four channels in RGBA order.
-- @src engine/Color.cs:ToHtml L562-576
const function ColorHtml(Color: ColorTable): string
	return `{ChannelHex(Color.R)}{ChannelHex(Color.G)}{ChannelHex(Color.B)}{ChannelHex(Color.A)}`
end

-- The length of a map in m:ss (Util.String.FormatTime of Length / 1000).
-- @src scripts/ui/menu/play/MapButtonWide.cs:UpdateInfo L43-57
const function LengthText(LengthMs: number): string
	return UtilString.FormatTime(LengthMs // 1000)
end

-- The wide button's extra line: length, difficulty name in its color, mappers, with BBCode in the source's order.
-- @src scripts/ui/menu/play/MapButtonWide.cs:UpdateInfo L43-57
const function ExtraText(LengthMs: number, DifficultyColor: string, DifficultyName: string, PrettyMappers: string): string
	const Length = LengthText(LengthMs)
	const Name = UtilString.SanitizeBBCode(DifficultyName)
	const Mappers = UtilString.SanitizeBBCode(PrettyMappers)

	return `[outline_size=2][outline_color=000000][color=808080]{Length} — [color={DifficultyColor}]{Name} [color=808080]by [color=b0b0b0]{Mappers}`
end

return {
	ColorHtml = ColorHtml,
	LengthText = LengthText,
	ExtraText = ExtraText,
}
