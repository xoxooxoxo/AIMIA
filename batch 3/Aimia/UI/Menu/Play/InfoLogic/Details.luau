--!strict
--!optimize 2

--[[
	The map info's labels and link text: the difficulty color and the BBCode text of the title, difficulty, mappers, length,
	notes and name, as MapInfoContainer.Setup formats them from the scene's label texts.

	Design Notes
		Every BBCode field is sanitized ("[" becomes "[lb]"). The length is Map.Length / 1000 in integer division, as the source.
]]

const Constants = require("../../../../Constants")
const Color = require("../../../../Godot/Color")
const MapTypes = require("../../../../Map/MapTypes")
const UtilString = require("../../../../Util/String")
const Format = require("./Format")

-- The difficulty's color (Constants.DIFFICULTY_COLORS, the index clamped to its range).
-- @src scripts/ui/menu/play/MapInfoContainer.cs:Setup L436
const function DifficultyColor(Difficulty: number): Color.Color
	const Index = math.clamp(Difficulty, 0, #Constants.DifficultyColors - 1)

	return Constants.DifficultyColors[Index + 1]
end

-- The main label: the title, the difficulty color, the difficulty name and the mappers.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:Setup L438-445
const function MainText(Map: MapTypes.Map, Template: string): string
	return Format.Template(Template, {
		UtilString.SanitizeBBCode(Map.PrettyTitle),
		Format.ToHtml(DifficultyColor(Map.Difficulty)),
		UtilString.SanitizeBBCode(Map.DifficultyName),
		UtilString.SanitizeBBCode(Map.PrettyMappers),
	})
end

-- The extra label: the length, the note count and the folder name.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:Setup L447-453
const function ExtraText(Map: MapTypes.Map, Template: string, NoteCount: number): string
	return Format.Template(Template, {
		UtilString.FormatTime(Map.Length // 1000),
		tostring(NoteCount),
		UtilString.SanitizeBBCode(Map.Name),
	})
end

-- The artist link's text: the platform name in the scene's format.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:Setup L460-461
const function ArtistText(Template: string, Platform: string): string
	return Format.Template(Template, { Platform })
end

return {
	DifficultyColor = DifficultyColor,
	MainText = MainText,
	ExtraText = ExtraText,
	ArtistText = ArtistText,
}
