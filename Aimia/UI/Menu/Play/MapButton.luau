--!strict
--!optimize 2

--[[
	The map button of MapList (scripts/ui/menu/play/MapButton.cs) on a prefab that MapButtonWide or MapButtonSquare builds:
	the state the two share (hover and selection tweens, the size offset, the cover, the favorite star, the mouse and press
	signals) and the skin textures the buttons draw.

	Representation
		One table per button, with the C# public fields. Hover, Select, UpdateInfo, UpdateSkin and Process are the virtual
		methods: New sets them to the functions here, and a variant replaces each with a function that calls these (the C#
		base.X). A variant's own state lives in the closures it creates.

	Design Notes
		The outline's parameters are set as the source sets them: the cursor and light positions here (Process), the fill in
		the wide variant, the color in the square variant. DEVIATION(shader): the cover's shader is not drawn (UI/Shaders).
		DEVIATION(resource): textures and materials are shared, not duplicated per node (Favorited.Texture.Duplicate and the
		outline material's Duplicate).
		Skin textures go through HomeLogic/SkinTexture (a decoded image is registered once, and a replaced skin keeps its images).
		Process runs while the button is in the tree, as Godot's _Process does: a cached button is not processed.
		Every Set of a geometry value relays out the scene, so the per-frame sets here skip values already set.
]]

const Nodes = require("../../Nodes")
const Frames = require("../../Frames")
const Items = require("../../Item")
const Tween = require("../../Tween")
const Images = require("../../Images")
const SkinTextureValue = require("../HomeLogic/SkinTexture")
const TextureValue = require("./Textures")
const Color = require("../../../Godot/Color")
const Constants = require("../../../Constants")
const MapModule = require("../../../Map/Map")
const MapTypes = require("../../../Map/MapTypes")
const Numbers = require("../../../Numbers")
const SkinManager = require("../../../Skinning/SkinManager")
const SkinProfile = require("../../../Skinning/SkinProfile")
const Signal = require("../../../Util/Signal")

type Item = Items.Item
type Map = MapTypes.Map

export type Options = {
	MinimumSize: number,
	HoveredSizeOffset: number,
	SelectedSizeOffset: number,
	List: Item,
}

export type MapButton = {
	Item: Item,
	Holder: Item,
	Title: Item,
	Cover: Item,
	Favorited: Item,
	Outline: Item,
	Container: Item?,
	Map: Map?,
	ListIndex: number,
	MinimumSize: number,
	HoveredSizeOffset: number,
	SelectedSizeOffset: number,
	SizeOffset: number,
	Hovered: boolean,
	Selected: boolean,
	OutlineFill: number,
	TargetOutlineFill: number,
	LightPosition: vector,
	CustomMinimumSize: { Vector2: { number } },
	Modulate: { Color: { number } },
	MouseHovered: Signal.Signal<boolean>,
	Pressed: Signal.Signal<()>,
	Hover: (MapButton, boolean) -> (),
	Select: (MapButton, boolean?) -> (),
	UpdateInfo: (MapButton, Map, boolean?) -> (),
	UpdateSkin: (MapButton, SkinProfile.SkinProfile?) -> (),
	Process: (MapButton, number) -> (),
}

-- A Godot color as a scene-data value (a modulate or self_modulate).
const function SceneColor(Value: Color.Color): unknown
	return { Color = { Value.R, Value.G, Value.B, Value.A } }
end

-- Godot's Color.Color8 as a scene-data value.
const function Color8Scene(R8: number, G8: number, B8: number, A8: number): unknown
	return SceneColor(Color.Color8(R8, G8, B8, A8))
end

const HoverTint = Color8Scene(26, 6, 13, 224)
const IdleTint = Color8Scene(0, 0, 0, 224)

-- A skin texture as a texture value (HomeLogic/SkinTexture, registering decoded images with Images.Register).
const function SkinTexture(Texture: SkinProfile.Texture?): unknown
	return SkinTextureValue(Texture, Images.Register)
end

-- A map's cover as a texture value: Map.GetCover answers a res:// path or a decoded image (registered by Textures).
const function CoverTexture(Map: Map): unknown
	return TextureValue(MapModule.GetCover(Map))
end

-- The custom minimum size of a node as the table SetMinimumSize keeps (the scene's Vector2, zero when it has none).
const function MinimumValueOf(Item: Item): { Vector2: { number } }
	const Current = Nodes.Get(Item, "custom_minimum_size")

	if type(Current) == "table" then
		const Pair = (Current :: { Vector2: { number }? }).Vector2

		if Pair then
			return { Vector2 = { Pair[1], Pair[2] } }
		end
	end

	return { Vector2 = { 0, 0 } }
end

-- A number property (an offset, an anchor, a position component) set when it changes: every set relays out the scene.
const function SetNumber(Item: Item, Name: string, Value: number)
	if Nodes.Get(Item, Name) ~= Value then
		Nodes.Set(Item, Name, Value)
	end
end

-- Godot's Control.CustomMinimumSize, set when it changes (every set relays out the scene).
const function SetMinimumSize(Button: MapButton, Width: number, Height: number)
	const Pair = Button.CustomMinimumSize.Vector2

	if Pair[1] == Width and Pair[2] == Height then
		return
	end

	Pair[1] = Width
	Pair[2] = Height

	Nodes.Set(Button.Item, "custom_minimum_size", Button.CustomMinimumSize)
end

-- @src scripts/ui/menu/play/MapButton.cs:computeSizeOffset L171-174
const function ComputeSizeOffset(Button: MapButton): number
	return (if Button.Hovered then Button.HoveredSizeOffset else 0) + (if Button.Selected then Button.SelectedSizeOffset else 0)
end

-- @src scripts/ui/menu/play/MapButton.cs:UpdateOutline L151-159
const function UpdateOutline(Button: MapButton, TargetFill: number, Fill: number?)
	Button.TargetOutlineFill = TargetFill

	if Fill ~= nil then
		Button.OutlineFill = Fill
	end
end

-- @src scripts/ui/menu/play/MapButton.cs:Hover L101-114
const function Hover(Button: MapButton, Hovered: boolean)
	if Button.Hovered == Hovered then
		return
	end

	Button.Hovered = Hovered
	Button.SizeOffset = ComputeSizeOffset(Button)

	Signal.Fire(Button.MouseHovered, Hovered)

	const Running = Tween.Create(Button.Item)

	Tween.SetTrans(Running, Tween.TransitionType.Quad)
	Tween.TweenProperty(Running, Button.Holder, "self_modulate", if Hovered then HoverTint else IdleTint, 0.15)
end

-- @src scripts/ui/menu/play/MapButton.cs:Select L116-127
const function Select(Button: MapButton, Value: boolean?)
	const Selected = if Value == nil then true else Value

	if Button.Selected == Selected then
		return
	end

	Button.Selected = Selected
	Button.SizeOffset = ComputeSizeOffset(Button)

	const Running = Tween.Create(Button.Item)

	Tween.SetTrans(Running, Tween.TransitionType.Quad)
	Tween.TweenProperty(Running, Button.Cover, "modulate", Color8Scene(255, 255, 255, if Selected then 255 else 128), 0.1)
end

-- @src scripts/ui/menu/play/MapButton.cs:Deselect L129-132
const function Deselect(Button: MapButton)
	Button.Select(Button, false)
end

-- @src scripts/ui/menu/play/MapButton.cs:UpdateInfo L134-149
const function UpdateInfo(Button: MapButton, Map: Map, Selected: boolean?)
	const Difficulty = math.clamp(Map.Difficulty, 0, #Constants.DifficultyColors - 1)

	Button.Map = Map

	Nodes.Set(Button.Item, "name", Map.Name)
	Nodes.Set(Button.Title, "text", Map.PrettyTitle)
	Nodes.Set(Button.Favorited, "visible", Map.Favorite)
	Nodes.Set(Button.Cover, "texture", CoverTexture(Map))
	Nodes.Set(Button.Favorited, "self_modulate", SceneColor(Constants.DifficultyColors[Difficulty + 1]))

	if Selected == true then
		Button.Select(Button, true)
		UpdateOutline(Button, 1, 0)
	end
end

-- @src scripts/ui/menu/play/MapButton.cs:UpdateSkin L161-169
const function UpdateSkin(Button: MapButton, Skin: SkinProfile.SkinProfile?)
	const Current = Skin or SkinManager.Skin

	if Nodes.IsInstanceValid(Button.Favorited) and Nodes.IsInsideTree(Button.Favorited) then
		Nodes.Set(Button.Favorited, "texture", SkinTexture(Current.FavoriteImage))
	end
end

-- @src scripts/ui/menu/play/MapButton.cs:_Process L88-99
const function Process(Button: MapButton, Delta: number)
	-- (lands within a hair of its target, as the list's eases do: MapList)
	Button.OutlineFill = if math.abs(Button.TargetOutlineFill - Button.OutlineFill) < 0.001 then Button.TargetOutlineFill else math.lerp(Button.OutlineFill, Button.TargetOutlineFill, math.min(1, 10 * Delta))

	-- (the frame clock, UI/Frames, so the spin and the pulse step evenly)
	const Now = Frames.Time * 1000

	-- (only a shown star spins and pulses: Favorited is visible only for a favourite, UpdateInfo, and each write to a hidden
	-- star still re-tinted it, for every tile on screen every frame)
	if Button.Map and Button.Map.Favorite then
		Nodes.Set(Button.Favorited, "rotation_degrees", Button.ListIndex * -10 + Now / 20)

		const Alpha = (225 + 30 * math.sin(math.pi * Now / 2000 + Button.ListIndex)) // 1

		Button.Modulate.Color[4] = Numbers.F32(Alpha / 255)
		Nodes.Set(Button.Favorited, "modulate", Button.Modulate)
	end

	-- The outline's cursor and light, as the source sets them every frame.
	Nodes.SetShaderParameter(Button.Outline, "cursor_position", Nodes.GetMousePosition(Button.Item))
	Nodes.SetShaderParameter(Button.Outline, "light_position", Button.LightPosition)
end

-- Creates the state of a map button on Item (its _Ready): the prefab's Holder, Title, Cover and Favorited, the button's
-- mouse and press signals, and the Process and skin callbacks. The variants replace the virtual methods after this.
-- @src scripts/ui/menu/play/MapButton.cs:_Ready L58-86
const function New(Item: Item, Options: Options): MapButton
	const Holder = Nodes.GetNode(Item, "Holder")
	const Button = {
		Item = Item,
		Holder = Holder,
		Title = Nodes.GetNode(Holder, "Title"),
		Cover = Nodes.GetNode(Holder, "Cover"),
		Favorited = Nodes.GetNode(Holder, "Favorited"),
		Outline = Nodes.GetNode(Holder, "Outline"),
		Container = nil,
		Map = nil,
		ListIndex = 0,
		MinimumSize = Options.MinimumSize,
		HoveredSizeOffset = Options.HoveredSizeOffset,
		SelectedSizeOffset = Options.SelectedSizeOffset,
		SizeOffset = 0,
		Hovered = false,
		Selected = false,
		OutlineFill = 0,
		TargetOutlineFill = 0,
		LightPosition = vector.zero,
		CustomMinimumSize = MinimumValueOf(Item),
		Modulate = { Color = { 1, 1, 1, 1 } },
		MouseHovered = Signal.New() :: Signal.Signal<boolean>,
		Pressed = Signal.New() :: Signal.Signal<()>,
		Hover = Hover,
		Select = Select,
		UpdateInfo = UpdateInfo,
		UpdateSkin = UpdateSkin,
		Process = Process,
	} :: MapButton

	const Area = Nodes.GetNode(Holder, "Button")

	Nodes.Connect(Area, "mouse_entered", function()
		Button.Hover(Button, true)
	end)
	Nodes.Connect(Area, "mouse_exited", function()
		Button.Hover(Button, false)
	end)
	Nodes.Connect(Area, "pressed", function()
		Signal.Fire(Button.Pressed)
	end)

	Nodes.OnProcess(Item, function(Delta: number)
		if Nodes.IsInsideTree(Item) and not Nodes.HiddenInTree(Item) then
			Button.Process(Button, Delta)
		end
	end)

	const function OnSkinLoaded(Skin: SkinProfile.SkinProfile)
		Button.UpdateSkin(Button, Skin)
	end

	Signal.Connect(SkinManager.Loaded, OnSkinLoaded)
	table.insert(Item.Cleanup, function()
		Signal.Disconnect(SkinManager.Loaded, OnSkinLoaded)
	end)

	return Button
end

return {
	New = New,
	Hover = Hover,
	Select = Select,
	Deselect = Deselect,
	UpdateInfo = UpdateInfo,
	UpdateOutline = UpdateOutline,
	UpdateSkin = UpdateSkin,
	Process = Process,
	SetNumber = SetNumber,
	SetMinimumSize = SetMinimumSize,
	SkinTexture = SkinTexture,
	SceneColor = SceneColor,
	Color8Scene = Color8Scene,
}
