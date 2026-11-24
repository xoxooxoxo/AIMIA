--!strict
--!optimize 2

--[[
	The map list of the play menu (scripts/ui/menu/play/MapList.cs) on "Menus/Play/MapList" of res://scenes/main_menu.tscn: the
	maps in one scrolling column (list) or in a grid. Virtualized: only the rows on screen have buttons, and buttons and rows
	that leave the view are cached and reused. Owns the map order, the search, the selection, the scroll and the skin.

	Paradigm
		MapList.GetInstance() is the list (Godot's static Instance): New sets it. The play menu's scripts read it (JukeboxPanel,
		LayoutButton, SortMenuButton, RandomPickButton, SearchPanel).

	Representation
		Maps is the displayed order (favorites first). Containers are the rows by 0-based index, MapButtons the buttons by map
		name, and ButtonByItem the button state of a button's Item (Godot casts the child node to MapButton).

	Design Notes
		New is attached by ScriptRegistry with the scene's Context. Space is Context.GetSpace() (SceneManager.Space, the menu's
		space). Focus shows the play menu through the scene's state: C# `SceneManager.Scene is MainMenu`, read as the list's
		Context.Scene.State, since the list lives only in the main menu and SceneManager cannot be required here (cycle).
		Subscriptions are dropped with the list's item (HomeLogic/Listen and Item.Cleanup).
		CallDeferred is task.defer. Task.Run(UpdateMaps) at ready runs in the calling thread.
		Export values are read from the scene (Nodes.Get), with the source's defaults.
		A wheel tick arrives as a press and a release (UI/Input), and both scroll, as the source's _UnhandledInput does.
		Setting a geometry value relays out the scene, so the per-frame sets skip values already set.
]]

const UserInputService = game:GetService("UserInputService")

const Nodes = require("../../Nodes")
const Input = require("../../Input")
const Items = require("../../Item")
const Tween = require("../../Tween")
const Listen = require("../HomeLogic/Listen")
const BaseScene = require("../../Scenes/BaseScene")
const MainMenu = require("../../Scenes/MainMenu")
const Bindable = require("../../../Util/Bindables/Bindable")
const Numbers = require("../../../Numbers")
const Signal = require("../../../Util/Signal")
const MapCache = require("../../../Map/MapCache")
const MapManager = require("../../../Map/MapManager")
const MapParser = require("../../../Map/MapParser")
const MapTypes = require("../../../Map/MapTypes")
const SkinManager = require("../../../Skinning/SkinManager")
const SkinProfile = require("../../../Skinning/SkinProfile")
const Lobby = require("../../../Multiplayer/Lobby")
const SoundManager = require("../../../Audio/SoundManager")
const Waves = require("../../../Spaces/Waves")
const ListGeometry = require("./Logic/ListGeometry")
const MapOrder = require("./Logic/MapOrder")
const GameStart = require("./GameStart")
const MapButton = require("./MapButton")
const NewSquareButton = require("./MapButtonSquare")
const NewWideButton = require("./MapButtonWide")

type Item = Items.Item
type Map = MapTypes.Map
type Button = MapButton.MapButton

export type MapListState = {
	Item: Item,
	Context: BaseScene.Context,
	Mask: Item,
	SelectionCursor: Item,
	ScrollBarMain: Item,
	ScrollBarMainTop: Item,
	ScrollBarMainMiddle: Item,
	ScrollBarMainBottom: Item,
	ScrollBarBackgroundTop: Item,
	ScrollBarBackgroundMiddle: Item,
	ScrollBarBackgroundBottom: Item,
	Layout: number,
	Spacing: number,
	WideButtonMinimumSize: number,
	WideButtonHoveredSize: number,
	WideButtonSelectedSize: number,
	SquareButtonMinimumSize: number,
	SquareButtonHoveredSize: number,
	SquareButtonSelectedSize: number,
	ScrollStep: number,
	ScrollFriction: number,
	ScrollElasticity: number,
	ScrollLength: number,
	ScrollMomentum: number,
	TargetScroll: number,
	Scroll: number,
	DragScroll: boolean,
	MouseScroll: boolean,
	DisplaySelectionCursor: boolean,
	SearchQuery: string,
	AuthorQuery: string,
	Ascending: Bindable.Bindable<boolean>,
	Sorting: Bindable.Bindable<number>,
	Maps: { Map },
	Containers: { [number]: Item },
	ContainerCache: { Item },
	MapButtons: { [string]: Button },
	MapButtonCache: { Button },
	ButtonByItem: { [Item]: Button },
	HoveredButton: Button?,
	SelectedMapId: string?,
	ResizedPending: boolean,
	ButtonMinSize: number,
	ButtonHoverSize: number,
	ButtonSelectSize: number,
	ButtonsPerContainer: number,
	LastMousePos: vector,
	DragDistance: number,
	DrawnContainers: { Item },
	SizeOffsets: { number },
	ContainerTops: { number },
}

const WideTemplate = "res://prefabs/map_button_wide.tscn"
const SquareTemplate = "res://prefabs/map_button_square.tscn"
const ContainerTemplate = "res://prefabs/map_button_container.tscn"

const MapList = {
	ListLayout = ListGeometry.ListLayout,
	SortType = MapOrder.SortType,
}

-- The list of the scene (MapList.GetInstance), set by New.
local CurrentList: MapListState? = nil

-- An export value: the scene's override, else the source's default.
const function Export(Item: Item, Name: string, Default: number): number
	const Value = Nodes.Get(Item, Name)

	return if type(Value) == "number" then Value else Default
end

-- Godot's IsVisibleInTree: the item and every ancestor are visible.
const function IsVisibleInTree(Item: Item): boolean
	local Current: Item? = Item

	while Current do
		if Nodes.Get(Current, "visible") ~= true then
			return false
		end

		Current = Nodes.GetParent(Current)
	end

	return true
end

-- @src scripts/ui/menu/play/MapList.cs:toggleSelectionCursor L589-605
const function ToggleSelectionCursor(List: MapListState, Display: boolean)
	if List.DisplaySelectionCursor == Display then
		return
	end

	List.DisplaySelectionCursor = Display

	if Display and List.HoveredButton then
		const CursorPosition = Nodes.Get(List.SelectionCursor, "position") :: vector
		const HoverY = (Nodes.Get(List.HoveredButton.Item, "position") :: vector).y

		Nodes.Set(List.SelectionCursor, "position", vector.create(CursorPosition.x, HoverY, 0))
	end

	const Running = Tween.Create(List.Item)

	Tween.SetTrans(Running, Tween.TransitionType.Quad)
	Tween.SetParallel(Running)
	Tween.TweenProperty(
		Running,
		List.SelectionCursor,
		"modulate",
		MapButton.Color8Scene(255, 255, 255, if Display then 255 else 0),
		0.1
	)
end

-- Frees every button and row, and empties the caches (MapList.clear).
-- @src scripts/ui/menu/play/MapList.cs:clear L607-632
const function Clear(List: MapListState)
	List.HoveredButton = nil

	for _, Button in List.MapButtons do
		Nodes.QueueFree(Button.Item)
	end

	for _, Button in List.MapButtonCache do
		Nodes.QueueFree(Button.Item)
	end

	for _, Row in List.Containers do
		Nodes.QueueFree(Row)
	end

	for _, Row in List.ContainerCache do
		Nodes.QueueFree(Row)
	end

	table.clear(List.MapButtons)
	table.clear(List.MapButtonCache)
	table.clear(List.Containers)
	table.clear(List.ContainerCache)
	table.clear(List.ButtonByItem)
end

-- Takes a row that left the view out of the list: its buttons go to the cache, and the row to the container cache.
-- @src scripts/ui/menu/play/MapList.cs:_Process L170-357
const function RemoveRow(List: MapListState, RowIndex: number, Button: Button)
	const Row = Button.Container :: Item

	for _, Node in Nodes.GetChildren(Row) do
		const Sibling = List.ButtonByItem[Node]

		Sibling.Container = nil

		if Sibling == List.HoveredButton then
			List.HoveredButton = nil
		end

		List.MapButtons[(Sibling.Map :: Map).Name] = nil
		List.ButtonByItem[Node] = nil
		table.insert(List.MapButtonCache, Sibling)
		Nodes.RemoveChild(Row, Node)
		MapButton.Deselect(Sibling)
		MapButton.UpdateOutline(Sibling, 0, 0)
	end

	if Nodes.GetParent(Row) == List.Mask then
		Nodes.RemoveChild(List.Mask, Row)
	end

	List.Containers[RowIndex] = nil
	table.insert(List.ContainerCache, Row)
end

-- Shows the map's place on the scroll and marks the play menu (MapList.Focus).
-- @src scripts/ui/menu/play/MapList.cs:Focus L442-451
const function Focus(List: MapListState, Map: Map)
	const Height = (Nodes.Get(List.Item, "size") :: vector).y
	const Index = MapOrder.IndexOf(List.Maps, Map.Name)

	List.TargetScroll = ListGeometry.FocusScroll(Index, List.ButtonsPerContainer, List.ButtonMinSize, List.Spacing, Height)

	-- SceneManager.Scene is MainMenu: mainMenu.Transition(mainMenu.PlayMenu).
	const Menu = List.Context.Scene.State :: MainMenu.MainMenu?

	if Menu then
		MainMenu.Transition(Menu, Menu.PlayMenu)
	end
end

-- Game.Play of the lobby's map, speed, start time, camera and modifiers.
-- @src scripts/ui/menu/play/MapList.cs:Select L430-433
const function PlayLobby()
	GameStart.Play(Lobby.Map :: Map, Lobby.Speed, Lobby.StartFrom, Lobby.CameraMode, Lobby.Modifiers, nil)
end

-- Selects a map (MapList.Select). Answers whether the selection changed.
-- @src scripts/ui/menu/play/MapList.cs:Select L413-440
const function Select(List: MapListState, Map: Map, PlayIfPreSelected: boolean?): boolean
	const Changed = List.SelectedMapId ~= Map.Name

	if Changed then
		MapManager.Select(Map)

		const Space = List.Context.GetSpace()

		if Space then
			Waves.UpdateMap(Space, Map)
		end

		SoundManager.StartMapSelectionPlayback(Map)

		if List.SelectedMapId ~= nil then
			const OldButton = List.MapButtons[List.SelectedMapId]

			if OldButton then
				MapButton.Deselect(OldButton)
				MapButton.UpdateOutline(OldButton, 0)
			end
		end
	end

	if not Changed and PlayIfPreSelected ~= false then
		PlayLobby()
	end

	List.SelectedMapId = Map.Name
	Focus(List, Map)

	return Changed
end

-- @src scripts/ui/menu/play/MapList.cs:Sort L453-488
const function Sort(List: MapListState)
	List.Maps = MapOrder.Order(List.Maps, List.Sorting.Value, List.Ascending.Value)

	Clear(List)
end

-- @src scripts/ui/menu/play/MapList.cs:UpdateMaps L498-523
const function UpdateMaps(List: MapListState)
	List.Maps = MapOrder.Filter(MapManager.Maps, List.SearchQuery, List.AuthorQuery)

	Sort(List)
end

-- @src scripts/ui/menu/play/MapList.cs:Search L490-496
const function Search(List: MapListState, Query: string?, Author: string?)
	if Query ~= nil then
		List.SearchQuery = Query
	end

	if Author ~= nil then
		List.AuthorQuery = Author
	end

	UpdateMaps(List)
end

-- @src scripts/ui/menu/play/MapList.cs:shuffle L634-639
const function Shuffle(List: MapListState)
	List.Maps = MapOrder.Shuffle(List.Maps, math.random)

	Clear(List)
end

-- The order each visit starts with (Handheld calls this): the songs mixed with artists kept apart (MapOrder.Spread), from
-- the top. The search and the sort buttons order the list as before once used.
const function Mix(List: MapListState)
	List.Maps = MapOrder.Spread(MapOrder.Filter(MapManager.Maps, List.SearchQuery, List.AuthorQuery), math.random)
	List.Scroll = 0
	List.TargetScroll = 0

	Clear(List)
end

-- @src scripts/ui/menu/play/MapList.cs:UpdateLayout L525-539
const function UpdateLayout(List: MapListState, Layout: number)
	if List.Layout ~= Layout then
		List.Layout = Layout
		List.Scroll = 0
		List.TargetScroll = 0
	end

	const IsList = Layout == ListGeometry.ListLayout.List

	List.ButtonMinSize = if IsList then List.WideButtonMinimumSize else List.SquareButtonMinimumSize
	List.ButtonHoverSize = if IsList then List.WideButtonHoveredSize else List.SquareButtonHoveredSize
	List.ButtonSelectSize = if IsList then List.WideButtonSelectedSize else List.SquareButtonSelectedSize

	-- (the selection cursor, the pink square, belongs to the list layout: it fades out for the grid, where it had stayed
	-- at the left edge when the mouse never left the list before the switch, and shows again on the next hover in the list)
	if not IsList then
		ToggleSelectionCursor(List, false)
	end

	Clear(List)
end

-- @src scripts/ui/menu/play/MapList.cs:UpdateSkin L541-553
const function UpdateSkin(List: MapListState, Skin: SkinProfile.SkinProfile?)
	const Current = Skin or SkinManager.Skin

	Nodes.Set(List.Mask, "texture", MapButton.SkinTexture(Current.MapListMaskImage))
	Nodes.Set(List.SelectionCursor, "texture", MapButton.SkinTexture(Current.MapListSelectionCursorImage))
	Nodes.Set(List.ScrollBarMainTop, "texture", MapButton.SkinTexture(Current.MapListScrollBarTopImage))
	Nodes.Set(List.ScrollBarMainMiddle, "texture", MapButton.SkinTexture(Current.MapListScrollBarMiddleImage))
	Nodes.Set(List.ScrollBarMainBottom, "texture", MapButton.SkinTexture(Current.MapListScrollBarBottomImage))
	Nodes.Set(List.ScrollBarBackgroundTop, "texture", MapButton.SkinTexture(Current.MapListScrollBarBackgroundTopImage))
	Nodes.Set(List.ScrollBarBackgroundMiddle, "texture", MapButton.SkinTexture(Current.MapListScrollBarBackgroundMiddleImage))
	Nodes.Set(List.ScrollBarBackgroundBottom, "texture", MapButton.SkinTexture(Current.MapListScrollBarBackgroundBottomImage))
end

-- A button of the list's layout, built from its prefab in a row (MapList.setupButton): the prefab is added to the row,
-- then the button's script runs (its _Ready), then its mouse and press signals are connected.
-- @src scripts/ui/menu/play/MapList.cs:setupButton L555-587
const function CreateButton(List: MapListState, Row: Item): Button
	const IsWide = List.Layout == ListGeometry.ListLayout.List
	const Node = Nodes.Instantiate(List.Item.Scene, if IsWide then WideTemplate else SquareTemplate)

	Nodes.AddChild(Row, Node)

	const Options = {
		MinimumSize = List.ButtonMinSize,
		HoveredSizeOffset = List.ButtonHoverSize,
		SelectedSizeOffset = List.ButtonSelectSize,
		List = List.Item,
	}
	const Button = if IsWide then NewWideButton(Node, Options) else NewSquareButton(Node, Options)

	Signal.Connect(Button.MouseHovered, function(Hovered: boolean)
		if Hovered then
			List.HoveredButton = Button

			if List.Layout == ListGeometry.ListLayout.List then
				ToggleSelectionCursor(List, true)
			end
		end

		if (Button.Map :: Map).Name ~= List.SelectedMapId then
			MapButton.UpdateOutline(Button, if Hovered then 0.5 else 0)
		end
	end)

	Signal.Connect(Button.Pressed, function()
		if List.DragDistance < 500 and Select(List, Button.Map :: Map) then
			Button.Select(Button, true)
			MapButton.UpdateOutline(Button, 1)
		end
	end)

	return Button
end

-- A row for a visible index: a cached container, or a new one, added to the mask.
-- @src scripts/ui/menu/play/MapList.cs:_Process L170-357
const function AddRow(List: MapListState, RowIndex: number): Item
	const Row = if #List.ContainerCache > 0
		then table.remove(List.ContainerCache) :: Item
		else Nodes.Instantiate(List.Item.Scene, ContainerTemplate)

	Nodes.Set(Row, "theme_override_constants/separation", Numbers.TruncInt32(List.Spacing))

	-- (a row that only slides is moved alone, its buttons left as they are: SceneBuilder.RelayoutMoved)
	const Sliding: any = Row

	Sliding.SlideOnly = true
	List.Containers[RowIndex] = Row
	Nodes.AddChild(List.Mask, Row)

	return Row
end

-- The button of a map in a row: a cached button, or a new one; it is set to show the map.
-- @src scripts/ui/menu/play/MapList.cs:_Process L170-357
const function AddButton(List: MapListState, Row: Item, Position: number, Map: Map): Button
	local Button: Button

	if #List.MapButtonCache > 0 then
		-- (a cached button that last showed this map is taken first: scrolling back then sets nothing that changed, so no
		-- text, cover or colour is laid out or rebuilt again)
		local Taken = #List.MapButtonCache

		for CacheIndex, Cached in List.MapButtonCache do
			if (Cached :: Button).Map == Map then
				Taken = CacheIndex
				break
			end
		end

		Button = table.remove(List.MapButtonCache, Taken) :: Button
		Nodes.AddChild(Row, Button.Item)
	else
		Button = CreateButton(List, Row)
	end

	Button.ListIndex = Position
	Button.Container = Row
	List.MapButtons[Map.Name] = Button
	List.ButtonByItem[Button.Item] = Button

	Button.UpdateInfo(Button, Map, Map.Name == List.SelectedMapId)

	return Button
end

-- Godot's _Process: the scroll, the visible rows and their buttons, the selection cursor and the row positions.
-- @src scripts/ui/menu/play/MapList.cs:_Process L170-357
const function Process(List: MapListState, Delta: number)
	if List.ResizedPending then
		List.ResizedPending = false

		Clear(List)
	end

	-- A button released outside the window sends no release to Roblox: the drag and the mouse scroll end when the button is up.
	if List.DragScroll and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
		List.DragScroll = false
	end

	if List.MouseScroll and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
		List.MouseScroll = false
	end

	const Node = List.Item
	const Size = Nodes.Get(Node, "size") :: vector
	const Maps = List.Maps
	const Spacing = List.Spacing
	const MinSize = List.ButtonMinSize

	List.ButtonsPerContainer = ListGeometry.ButtonsPerContainer(List.Layout, Size.x, MinSize, Spacing)

	const PerContainer = List.ButtonsPerContainer

	local ElasticOffset = 0

	if (List.TargetScroll <= 0 and List.ScrollMomentum < 0) or (List.TargetScroll >= List.ScrollLength and List.ScrollMomentum > 0) then
		ElasticOffset = List.ScrollMomentum * List.ScrollElasticity
	end

	List.ScrollLength = ListGeometry.ScrollLength(
		List.Layout,
		#Maps,
		PerContainer,
		MinSize,
		Spacing,
		Size.y,
		List.ButtonHoverSize,
		List.ButtonSelectSize
	)
	List.ScrollMomentum = math.lerp(List.ScrollMomentum, 0, math.min(1, List.ScrollFriction * Delta))

	-- (Not in the source: the eases land once they are within a hair of their target. They never quite arrive on their own,
	-- and every frame they kept moving the rows by a fraction of a pixel, each move laying the rows out again, for about two
	-- seconds after the list had visibly stopped.)
	if math.abs(List.ScrollMomentum) < 0.05 then
		List.ScrollMomentum = 0
	end

	const Mouse = Nodes.GetMousePosition(Node)

	if List.DragScroll and IsVisibleInTree(Node) then
		const DragDelta = (List.LastMousePos.y - Mouse.y) * 30

		List.ScrollMomentum += DragDelta
		List.DragDistance += math.abs(DragDelta)
	end

	List.LastMousePos = Mouse

	if List.MouseScroll then
		const Top = (Nodes.Get(Node, "position") :: vector).y + (Nodes.Get(List.ScrollBarMain, "size") :: vector).y / 2
		const Bottom = (Nodes.Get(Node, "position") :: vector).y + Size.y - (Nodes.Get(List.ScrollBarMain, "size") :: vector).y / 2
		const Fraction = (Mouse.y - Top) / (Bottom - Top)

		const Wanted = List.ScrollLength * math.clamp(Fraction, 0, 1)

		List.TargetScroll = if math.abs(Wanted - List.TargetScroll) < 0.01 then Wanted else math.lerp(List.TargetScroll, Wanted, math.min(1, 24 * Delta))
	else
		List.TargetScroll = math.clamp(List.TargetScroll + List.ScrollMomentum * Delta, 0, List.ScrollLength) + ElasticOffset
	end

	List.Scroll = if math.abs(List.TargetScroll - List.Scroll) < 0.01 then List.TargetScroll else math.lerp(List.Scroll, List.TargetScroll, math.min(1, 12 * Delta))

	const AnchorTop, AnchorBottom = ListGeometry.ScrollBarAnchors(List.TargetScroll, ElasticOffset, List.ScrollLength, Size.y)

	MapButton.SetNumber(List.ScrollBarMain, "anchor_top", AnchorTop)
	MapButton.SetNumber(List.ScrollBarMain, "anchor_bottom", AnchorBottom)

	const DrawnContainers = List.DrawnContainers
	const SizeOffsets = List.SizeOffsets

	table.clear(DrawnContainers)
	table.clear(SizeOffsets)

	local LastContainer: Item? = nil
	local FirstIndex = -1

	for Index, Map in Maps do
		const Position = Index - 1
		const RowIndex = Numbers.TruncDiv32(Position, PerContainer)
		const Top = RowIndex * (MinSize + Spacing) - List.Scroll
		const Bottom = Top + MinSize
		const Display = Top < Size.y and Bottom > 0
		local Button = List.MapButtons[Map.Name]

		-- Cache what is outside the list.
		if not Display then
			if Button then
				RemoveRow(List, RowIndex, Button)
			end

			continue
		end

		-- Everything below is drawn.
		const Row = List.Containers[RowIndex] or AddRow(List, RowIndex)

		if Button == nil then
			Button = AddButton(List, Row, Position, Map)
		end

		if Row ~= LastContainer then
			table.insert(DrawnContainers, Row)

			if FirstIndex == -1 then
				FirstIndex = RowIndex
			end

			LastContainer = Row
		end
	end

	-- (the rows' heights are read once every row is added and removed: a size read lays the scene out, and reading it
	-- inside the loop above laid it out again after each row change. Rows are separate under Mask, so the heights are the
	-- same.)
	for _, Row in DrawnContainers do
		const RowHeight = (Nodes.Get(Row, "size") :: vector).y

		table.insert(SizeOffsets, if RowHeight > 0 then RowHeight - MinSize else 0)
	end

	-- (no selection cursor in the grid, whatever showed it: see UpdateLayout)
	if List.DisplaySelectionCursor and List.Layout ~= ListGeometry.ListLayout.List then
		ToggleSelectionCursor(List, false)
	end

	-- The selection cursor follows the hovered button, or rests at the left edge.
	const Cursor = List.SelectionCursor
	const CursorPosition = Nodes.Get(Cursor, "position") :: vector
	const Hovered = List.HoveredButton

	local Target = vector.create(-80, CursorPosition.y, 0)

	if Hovered and Nodes.IsInstanceValid(Hovered.Item) and Nodes.IsInsideTree(Hovered.Item) then
		const HolderX = (Nodes.Get(Hovered.Holder, "position") :: vector).x
		const RowY = (Nodes.Get(Hovered.Container :: Item, "position") :: vector).y
		const ButtonHeight = (Nodes.Get(Hovered.Item, "size") :: vector).y
		const CursorHeight = (Nodes.Get(Cursor, "size") :: vector).y
		const TargetX = if List.DisplaySelectionCursor then HolderX - 60 else -80

		Target = vector.create(TargetX, math.clamp(RowY + ButtonHeight / 2 - CursorHeight / 2, 0, Size.y), 0)
	end

	const Next = if vector.magnitude(Target - CursorPosition) < 0.01 then Target else CursorPosition + (Target - CursorPosition) * math.min(1, 8 * Delta)

	Nodes.Set(Cursor, "position", Next)
	Nodes.Set(Cursor, "rotation", -Next.y / 60)

	-- The drawn rows: their tops, z order and the position of their buttons' light.
	ListGeometry.ContainerTops(
		List.ContainerTops,
		SizeOffsets,
		FirstIndex,
		MinSize,
		Spacing,
		List.ButtonHoverSize,
		List.ButtonSelectSize,
		List.Scroll
	)

	const Count = #Maps

	for Row, Container in DrawnContainers do
		const Index = Row - 1 + FirstIndex
		const Current = Nodes.Get(Container, "position") :: vector
		const Top = List.ContainerTops[Row]

		Nodes.Set(Container, "z_index", ListGeometry.ZIndex(Index, Count, PerContainer))

		-- (A row is placed by its offsets: top and bottom both at Top, left and right at 0, and the layout grows it to its
		-- height around that line. Its position is the grown one, so it never equals Top, and placing a row that was already
		-- there laid the whole row out again every frame, even with the list at rest. A row whose offsets are already these is
		-- left as it is: placing it again would give the same offsets and the same layout. Placing stores Top as the position
		-- vector holds it, a float32, so that is what's compared.)
		const PlacedTop = Numbers.F32(Top)
		const Placed = Nodes.Get(Container, "offset_top") == PlacedTop
			and Nodes.Get(Container, "offset_bottom") == PlacedTop
			and Nodes.Get(Container, "offset_left") == 0
			and Nodes.Get(Container, "offset_right") == 0

		if not Placed then
			if Current.y ~= Top then
				Nodes.Set(Container, "position", vector.create(Current.x, Top, 0))
			end

			MapButton.SetNumber(Container, "offset_bottom", Nodes.Get(Container, "offset_top") :: number)
			MapButton.SetNumber(Container, "offset_left", 0)
			MapButton.SetNumber(Container, "offset_right", 0)
		end
	end

	const Light = if List.DisplaySelectionCursor
		then Nodes.Get(Cursor, "global_position") :: vector
		else vector.create(-10000, Size.y / 2, 0)

	for _, Button in List.MapButtons do
		Button.LightPosition = Light
	end
end

-- Godot's _Ready: the list's nodes, its export values, its signals and the map order, then the layout and the skin.
-- Attached by ScriptRegistry with the scene's Context. Sets the instance (GetInstance).
-- @src scripts/ui/menu/play/MapList.cs:_Ready L106-168
const function New(Item: Item, Context: BaseScene.Context)
	const List = {
		Item = Item,
		Context = Context,
		Mask = Nodes.GetNode(Item, "Mask"),
		SelectionCursor = Nodes.GetNode(Item, "SelectionCursor"),
		ScrollBarMain = Nodes.GetNode(Item, "ScrollBar/Main"),
		ScrollBarMainTop = Nodes.GetNode(Item, "ScrollBar/Main/Top"),
		ScrollBarMainMiddle = Nodes.GetNode(Item, "ScrollBar/Main/Middle"),
		ScrollBarMainBottom = Nodes.GetNode(Item, "ScrollBar/Main/Bottom"),
		ScrollBarBackgroundTop = Nodes.GetNode(Item, "ScrollBar/Background/Top"),
		ScrollBarBackgroundMiddle = Nodes.GetNode(Item, "ScrollBar/Background/Middle"),
		ScrollBarBackgroundBottom = Nodes.GetNode(Item, "ScrollBar/Background/Bottom"),
		Layout = Export(Item, "Layout", ListGeometry.ListLayout.List),
		Spacing = Export(Item, "Spacing", 10),
		WideButtonMinimumSize = Export(Item, "WideButtonMinimumSize", 90),
		WideButtonHoveredSize = Export(Item, "WideButtonHoveredSize", 10),
		WideButtonSelectedSize = Export(Item, "WideButtonSelectedSize", 20),
		SquareButtonMinimumSize = Export(Item, "SquareButtonMinimumSize", 140),
		SquareButtonHoveredSize = Export(Item, "SquareButtonHoveredSize", 5),
		SquareButtonSelectedSize = Export(Item, "SquareButtonSelectedSize", 10),
		ScrollStep = Export(Item, "ScrollStep", 1500),
		ScrollFriction = Export(Item, "ScrollFriction", 20),
		ScrollElasticity = Export(Item, "ScrollElasticity", Numbers.F32(0.02)),
		ScrollLength = 0,
		ScrollMomentum = 0,
		TargetScroll = 0,
		Scroll = 0,
		DragScroll = false,
		MouseScroll = false,
		DisplaySelectionCursor = false,
		SearchQuery = "",
		AuthorQuery = "",
		Ascending = Bindable.New(true, "Ascending"),
		Sorting = Bindable.New(MapOrder.SortType.Alphabetical, "Sorting"),
		Maps = {},
		Containers = {},
		ContainerCache = {},
		MapButtons = {},
		MapButtonCache = {},
		ButtonByItem = {},
		HoveredButton = nil,
		SelectedMapId = nil,
		ResizedPending = false,
		ButtonMinSize = 0,
		ButtonHoverSize = 0,
		ButtonSelectSize = 0,
		ButtonsPerContainer = 1,
		LastMousePos = vector.zero,
		DragDistance = 0,
		DrawnContainers = {},
		SizeOffsets = {},
		ContainerTops = {},
	} :: MapListState

	CurrentList = List

	Listen(Item, List.Sorting.ValueChanged, function()
		Sort(List)
	end)
	Listen(Item, List.Ascending.ValueChanged, function()
		Sort(List)
	end)

	Nodes.Connect(Item, "mouse_exited", function()
		ToggleSelectionCursor(List, false)
	end)
	-- The resize is signalled while Process reads the list (its geometry reads lay the scene out), so the rows are cleared at
	-- the start of the next Process, as Godot's deferred free does.
	Nodes.Connect(Item, "resized", function()
		List.ResizedPending = true
	end)

	Listen(Item, SkinManager.Loaded, function(Skin: SkinProfile.SkinProfile)
		UpdateSkin(List, Skin)
	end)

	Listen(Item, MapParser.MapsImportFinished, function(Imported: { Map })
		if #Imported > 0 then
			MapCache.Load(false)
			UpdateMaps(List)
			Select(List, Imported[1])
		end
	end)

	Listen(Item, MapManager.MapsInitialized, function()
		UpdateMaps(List)
	end)
	Listen(Item, MapManager.MapUpdated, function()
		UpdateMaps(List)
	end)
	Listen(Item, MapManager.MapDeleted, function(Deleted: Map)
		if List.SelectedMapId == Deleted.Name then
			List.SelectedMapId = nil

			if #MapManager.Maps > 0 then
				task.defer(function()
					Select(List, MapManager.Maps[1], false)
				end)
			end
		end

		task.defer(function()
			Clear(List)
			UpdateMaps(List)
		end)
	end)

	-- The list's frame is Active, so Roblox marks every wheel tick over it as handled (Processed) and none reached the scroll
	-- below: while the mouse is over the list a wheel tick scrolls it anyway, as the Leaderboards list does. Presses keep
	-- the old rule, so clicking a song is unchanged.
	local Hovered = false
	const Frame = Item.Instance

	if Frame and Frame:IsA("GuiObject") then
		const Entered = Frame.MouseEnter:Connect(function()
			Hovered = true
		end)
		const Left = Frame.MouseLeave:Connect(function()
			Hovered = false
		end)

		table.insert(Item.Cleanup, function()
			Entered:Disconnect()
			Left:Disconnect()
		end)
	end

	-- _UnhandledInput: the mouse drags and scrolls the list (a press without Ctrl, Alt or Shift).
	table.insert(Item.Cleanup, Input.OnInput(function(Event: Input.InputEvent, Processed: boolean)
		-- (not while the list can't be seen: wheel turns on other pages piled up and flung it when Play showed)
		if Event.Class ~= "InputEventMouseButton" or Nodes.HiddenInTree(Item) then
			return
		end

		const Wheel = Event.ButtonIndex == Input.MouseButton.WheelUp or Event.ButtonIndex == Input.MouseButton.WheelDown

		if Processed and not (Wheel and Hovered) then
			return
		end

		if Event.CtrlPressed or Event.AltPressed or Event.ShiftPressed then
			return
		end

		if Event.ButtonIndex == Input.MouseButton.Left then
			List.DragScroll = Event.Pressed

			if List.DragScroll then
				List.DragDistance = 0
			end
		elseif Event.ButtonIndex == Input.MouseButton.Right then
			List.MouseScroll = Event.Pressed

			if List.MouseScroll then
				List.DragDistance = 0
			end
		elseif Event.ButtonIndex == Input.MouseButton.WheelDown then
			List.ScrollMomentum += List.ScrollStep
		elseif Event.ButtonIndex == Input.MouseButton.WheelUp then
			List.ScrollMomentum -= List.ScrollStep
		end
	end))

	-- _Input: F2 shuffles. The Space key plays the lobby's map while the list is shown and no line edit has focus.
	-- Shown means on screen: the menus stay loaded behind a song, where Space is the song's skip and must never start the
	-- song again (that threw the run away).
	table.insert(Item.Cleanup, Input.OnInput(function(Event: Input.InputEvent)
		if Event.Class ~= "InputEventKey" or not Event.Pressed or Nodes.HiddenInTree(Item) then
			return
		end

		if Event.Keycode == Input.Key.F2 then
			Shuffle(List)
		elseif Event.Keycode == Input.Key.Space then
			if Lobby.Map ~= nil and IsVisibleInTree(Item) and Nodes.GetFocusOwner(Item) == nil then
				PlayLobby()
			end
		end
	end))

	-- (nothing to draw while the Play tab is hidden: the list picks up where it was when it shows again)
	Nodes.OnProcess(Item, function(Delta: number)
		if not Nodes.HiddenInTree(Item) then
			Process(List, Delta)
		end
	end)

	UpdateMaps(List)
	UpdateLayout(List, List.Layout)
	UpdateSkin(List, nil)
end

-- The list of the scene (MapList.Instance in the source): an error before New has run.
const function GetInstance(): MapListState
	if CurrentList == nil then
		error("Aimia UI: MapList has not been created", 2)
	end

	return CurrentList
end

MapList.GetInstance = GetInstance
MapList.New = New
MapList.Select = Select
MapList.Focus = Focus
MapList.Sort = Sort
MapList.Search = Search
MapList.Mix = Mix
MapList.UpdateMaps = UpdateMaps
MapList.UpdateLayout = UpdateLayout
MapList.UpdateSkin = UpdateSkin

return MapList
