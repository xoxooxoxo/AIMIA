--!strict
--!optimize 2

--[[
	The square map button of the grid layout (scripts/ui/menu/play/MapButtonSquare.cs) on res://prefabs/map_button_square.tscn:
	a tile with the cover, the title, the difficulty, the author and the length. A hovered or selected tile grows: its holder's
	offsets move outward by half the size offset. The difficulty color tints the difficulty label and the cover background.

	Representation
		Overrides Hover, Select, UpdateInfo, UpdateSkin and Process of UI/Menu/Play/MapButton.

	Design Notes
		Each label gets its own LabelSettings copy (the source's Duplicate), so the difficulty's font color is its own.
]]

const Nodes = require("../../Nodes")
const Items = require("../../Item")
const Theme = require("../../Theme")
const Constants = require("../../../Constants")
const Color = require("../../../Godot/Color")
const MapTypes = require("../../../Map/MapTypes")
const SkinManager = require("../../../Skinning/SkinManager")
const SkinProfile = require("../../../Skinning/SkinProfile")
const MapButton = require("./MapButton")
const MapText = require("./Logic/MapText")

type Item = Items.Item

-- label.LabelSettings.FontColor = Color: the label's own settings copy takes the color.
const function SetFontColor(Label: Item, Value: Color.Color)
	const Settings = Nodes.DuplicateResource(Nodes.Get(Label, "label_settings") :: Theme.Resource)

	Settings.Properties["font_color"] = MapButton.SceneColor(Value)
	Nodes.Set(Label, "label_settings", Settings)
end

-- An ease that lands once it is within a hair of its target.
const function Ease(Current: number, Target: number, Alpha: number): number
	return if math.abs(Target - Current) < 0.01 then Target else math.lerp(Current, Target, Alpha)
end

-- The outline's colors by focus (the square's idleColor, hoverColor and selectColor fields).
const IdleOutline = MapButton.Color8Scene(13, 13, 13, 255)
const HoverOutline = MapButton.Color8Scene(26, 26, 26, 255)
const SelectOutline = MapButton.Color8Scene(201, 0, 69, 255)

-- updateFocus: the cover's alpha follows the hover and selection, and the outline's color follows the focus.
-- @src scripts/ui/menu/play/MapButtonSquare.cs:updateFocus L80-89
const function UpdateFocus(Button: MapButton.MapButton)
	const Alpha = if Button.Hovered or Button.Selected then 200 else 128

	Nodes.Set(Button.Cover, "modulate", MapButton.Color8Scene(255, 255, 255, Alpha))
	Nodes.SetShaderParameter(Button.Outline, "outline_color", if Button.Selected then SelectOutline elseif Button.Hovered then HoverOutline else IdleOutline)
end

-- @src scripts/ui/menu/play/MapButtonSquare.cs:_Ready L15-28
const function New(Item: Item, Options: MapButton.Options): MapButton.MapButton
	const Button = MapButton.New(Item, Options)
	const Holder = Button.Holder
	const Difficulty = Nodes.GetNode(Holder, "Difficulty")
	const Author = Nodes.GetNode(Holder, "Author")
	const Length = Nodes.GetNode(Holder, "Length")
	const CoverBackground = Nodes.GetNode(Holder, "CoverBackground")

	for _, Label in { Difficulty, Author, Length } do
		Nodes.Set(Label, "label_settings", Nodes.DuplicateResource(Nodes.Get(Label, "label_settings") :: Theme.Resource))
	end

	-- @src scripts/ui/menu/play/MapButtonSquare.cs:_Process L30-42
	const function ProcessSquare(Self: MapButton.MapButton, Delta: number)
		MapButton.Process(Self, Delta)

		const Half = Self.SizeOffset / 2
		const Alpha = math.min(1, 16 * Delta)

		-- (the grow lands within a hair of its target, as the list's eases do: MapList. Without it an un-hovered tile kept
		-- shrinking by a fraction of a pixel, and laying its holder out again, every frame for about 40 s, so scrolling the grid
		-- under a still cursor left dozens of tiles doing it at once.)
		MapButton.SetNumber(Holder, "offset_left", Ease(Nodes.Get(Holder, "offset_left") :: number, -Half, Alpha))
		MapButton.SetNumber(Holder, "offset_top", Ease(Nodes.Get(Holder, "offset_top") :: number, -Half, Alpha))
		MapButton.SetNumber(Holder, "offset_right", Ease(Nodes.Get(Holder, "offset_right") :: number, Half, Alpha))
		MapButton.SetNumber(Holder, "offset_bottom", Ease(Nodes.Get(Holder, "offset_bottom") :: number, Half, Alpha))

		MapButton.SetMinimumSize(Self, Options.MinimumSize, Options.MinimumSize)
	end

	-- @src scripts/ui/menu/play/MapButtonSquare.cs:Hover L44-49
	const function HoverSquare(Self: MapButton.MapButton, Hovered: boolean)
		MapButton.Hover(Self, Hovered)
		UpdateFocus(Self)
	end

	-- @src scripts/ui/menu/play/MapButtonSquare.cs:Select L51-56
	const function SelectSquare(Self: MapButton.MapButton, Value: boolean?)
		MapButton.Select(Self, Value)
		UpdateFocus(Self)
	end

	-- @src scripts/ui/menu/play/MapButtonSquare.cs:UpdateInfo L58-69
	const function UpdateInfoSquare(Self: MapButton.MapButton, Map: MapTypes.Map, Selected: boolean?)
		MapButton.UpdateInfo(Self, Map, Selected)

		const DifficultyColor = Constants.DifficultyColors[Map.Difficulty + 1]

		Nodes.Set(Difficulty, "text", Map.DifficultyName)
		Nodes.Set(Author, "text", Map.PrettyMappers)
		Nodes.Set(Length, "text", MapText.LengthText(Map.Length))
		SetFontColor(Difficulty, DifficultyColor)
		Nodes.Set(CoverBackground, "self_modulate", MapButton.SceneColor(DifficultyColor))
	end

	-- @src scripts/ui/menu/play/MapButtonSquare.cs:UpdateSkin L71-78
	const function UpdateSkinSquare(Self: MapButton.MapButton, Skin: SkinProfile.SkinProfile?)
		const Current = Skin or SkinManager.Skin

		MapButton.UpdateSkin(Self, Current)
		Nodes.Set(CoverBackground, "texture", MapButton.SkinTexture(Current.MapListGridCoverBackgroundImage))
	end

	Button.Process = ProcessSquare
	Button.Hover = HoverSquare
	Button.Select = SelectSquare
	Button.UpdateInfo = UpdateInfoSquare
	Button.UpdateSkin = UpdateSkinSquare

	Button.UpdateSkin(Button, nil)

	return Button
end

return New
