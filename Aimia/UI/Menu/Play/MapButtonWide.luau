--!strict
--!optimize 2

--[[
	The wide map button of the list layout (scripts/ui/menu/play/MapButtonWide.cs) on res://prefabs/map_button_wide.tscn: a
	row with the cover, the title and an extra line (length, difficulty, mappers). A selected row sticks out to the right,
	and every row bends its anchor toward the middle of the list.

	Representation
		Overrides UpdateInfo, UpdateSkin and Process of UI/Menu/Play/MapButton; the stick-out offset is a closure local.

	Design Notes
		The outline's "fill" is set in Process, as the source sets it. DEVIATION(shader): the cover shader is neither drawn
		nor reassigned on a skin change (MapButtonCoverShader).
]]

const Nodes = require("../../Nodes")
const Items = require("../../Item")
const Constants = require("../../../Constants")
const MapTypes = require("../../../Map/MapTypes")
const SkinProfile = require("../../../Skinning/SkinProfile")
const MapButton = require("./MapButton")
const ListGeometry = require("./Logic/ListGeometry")
const MapText = require("./Logic/MapText")

type Item = Items.Item

-- The skin's cover shader (user/skins/default/ui/play/map_button_cover.gdshader): COLOR.a = min(0.8, UV.x * 1.5), as a gradient on
-- the cover image: transparent at the left edge, 20% transparent from x = 0.8 / 1.5 on.
const CoverFade = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.8 / 1.5, 0.2),
	NumberSequenceKeypoint.new(1, 0.2),
})

-- The horizontal stick-out of a selected row (its anchor moves by it).
const StickoutSize = 0.05

-- @src scripts/ui/menu/play/MapButtonWide.cs:_Ready L15-25
const function New(Item: Item, Options: MapButton.Options): MapButton.MapButton
	const Button = MapButton.New(Item, Options)
	const Extra = Nodes.GetNode(Button.Holder, "Extra")
	const List = Options.List

	local StickoutOffset = 0
	local CoverFaded = false

	-- CustomMinimumSize = new(CustomMinimumSize.X, MinimumSize)
	MapButton.SetMinimumSize(Button, Button.CustomMinimumSize.Vector2[1], Options.MinimumSize)

	-- @src scripts/ui/menu/play/MapButtonWide.cs:_Process L27-41
	const function ProcessWide(Self: MapButton.MapButton, Delta: number)
		MapButton.Process(Self, Delta)

		-- The cover's image exists once a texture is set; the fade is added to it once.
		if not CoverFaded and Self.Cover.Texture then
			const Fade = Instance.new("UIGradient")

			Fade.Name = "CoverFade"
			Fade.Transparency = CoverFade
			Fade.Parent = Self.Cover.Texture
			CoverFaded = true
		end

		-- (the eases land within a hair of their target, or they set the button again every frame for seconds: MapList)
		const Stickout = if Self.Selected then StickoutSize else 0

		StickoutOffset = if math.abs(Stickout - StickoutOffset) < 0.0001 then Stickout else math.lerp(StickoutOffset, Stickout, math.min(1, 16 * Delta))

		Nodes.SetShaderParameter(Self.Outline, "fill", Self.OutlineFill)

		const ListHeight = (Nodes.Get(List, "size") :: vector).y
		const ListY = (Nodes.Get(List, "global_position") :: vector).y
		const Position = Nodes.Get(Item, "global_position") :: vector
		const Size = Nodes.Get(Item, "size") :: vector
		const CenterOffset = ListGeometry.CenterFactor(Position.y, Size.y, ListY, ListHeight, Options.MinimumSize)

		MapButton.SetNumber(Self.Holder, "anchor_left", 0.1 - CenterOffset / 20 - StickoutOffset)

		const Shown = Self.CustomMinimumSize.Vector2[2]
		const Wanted = Options.MinimumSize + Self.SizeOffset
		const Height = if math.abs(Wanted - Shown) < 0.01 then Wanted else math.lerp(Shown, Wanted, math.min(1, 16 * Delta))

		MapButton.SetMinimumSize(Self, Self.CustomMinimumSize.Vector2[1], Height)
	end

	-- @src scripts/ui/menu/play/MapButtonWide.cs:UpdateInfo L43-57
	const function UpdateInfoWide(Self: MapButton.MapButton, Map: MapTypes.Map, Selected: boolean?)
		MapButton.UpdateInfo(Self, Map, Selected)

		const DifficultyColor = MapText.ColorHtml(Constants.DifficultyColors[Map.Difficulty + 1])

		Nodes.Set(Extra, "text", MapText.ExtraText(Map.Length, DifficultyColor, Map.DifficultyName, Map.PrettyMappers))

		StickoutOffset = if Selected == true then StickoutSize else 0
	end

	-- @src scripts/ui/menu/play/MapButtonWide.cs:UpdateSkin L59-66
	const function UpdateSkinWide(Self: MapButton.MapButton, Skin: SkinProfile.SkinProfile?)
		MapButton.UpdateSkin(Self, Skin)

		-- DEVIATION(shader): the cover shader (Skin.MapButtonCoverShader) is not reassigned (MapButton).
	end

	Button.Process = ProcessWide
	Button.UpdateInfo = UpdateInfoWide
	Button.UpdateSkin = UpdateSkinWide

	Button.UpdateSkin(Button, nil)

	return Button
end

return New
