--!strict
--!optimize 2

--[[
	The sort menu button (scripts/ui/menu/play/SortMenuButton.cs) on "Menus/Play/SubTopBar/HBoxContainer/Sort" of
	res://scenes/main_menu.tscn: a toggle that opens the sort panel. The panel holds the order button (ascending or
	descending, with its label) and the sort type buttons; a press outside the panel and the button closes it.

	Design Notes
		The exports (panel, order, orderLabel, buttons) are the scene's node paths. A sort type button's name is its sort type
		(MapOrder.ParseSortType). MapList must be created first (MapList.GetInstance).
		The skin and input subscriptions are dropped with the button's item (Item.Cleanup).
]]

const Nodes = require("../../Nodes")
const Input = require("../../Input")
const Items = require("../../Item")
const Bindable = require("../../../Util/Bindables/Bindable")
const Signal = require("../../../Util/Signal")
const SkinManager = require("../../../Skinning/SkinManager")
const SkinProfile = require("../../../Skinning/SkinProfile")
const MapButton = require("./MapButton")
const MapList = require("./MapList")
const MapOrder = require("./Logic/MapOrder")

type Item = Items.Item

type SortMenu = {
	Item: Item,
	Panel: Item,
	Order: Item,
	OrderLabel: Item,
	Buttons: Item,
	PreviousButton: Item?,
}

-- Godot's Rect2.HasPoint: the left and top edges are inside, the right and bottom edges are not.
const function HasPoint(Origin: vector, Size: vector, Point: vector): boolean
	return Point.x >= Origin.x and Point.x < Origin.x + Size.x and Point.y >= Origin.y and Point.y < Origin.y + Size.y
end

-- @src scripts/ui/menu/play/SortMenuButton.cs:UpdateSkin L51-55
const function UpdateSkin(Sort: SortMenu, Skin: SkinProfile.SkinProfile)
	const List = MapList.GetInstance()
	const Icon = MapButton.SkinTexture(if List.Ascending.Value then Skin.SortAscendButtonImage else Skin.SortButtonImage)

	Nodes.Set(Sort.Order, "icon", Icon)
	Nodes.Set(Sort.Item, "icon", Icon)
end

-- @src scripts/ui/menu/play/SortMenuButton.cs:toggle L57-60
const function Toggle(Sort: SortMenu, Toggled: boolean)
	Nodes.Set(Sort.Panel, "visible", Toggled)
end

-- @src scripts/ui/menu/play/SortMenuButton.cs:selectSort L62-72
const function SelectSort(Sort: SortMenu, Button: Item)
	const Result = MapOrder.ParseSortType(Button.Name)
	const List = MapList.GetInstance()

	if Result ~= nil and List.Sorting.Value ~= Result then
		if Sort.PreviousButton then
			Nodes.Set(Sort.PreviousButton, "disabled", false)
		end

		Nodes.Set(Button, "disabled", true)
		Sort.PreviousButton = Button

		Bindable.Set(List.Sorting, Result)
	end
end

-- @src scripts/ui/menu/play/SortMenuButton.cs:toggleOrder L74-83
const function ToggleOrder(Sort: SortMenu)
	const Skin = SkinManager.Skin
	const List = MapList.GetInstance()

	Bindable.Set(List.Ascending, not List.Ascending.Value)
	Nodes.Set(Sort.OrderLabel, "text", if List.Ascending.Value then "Ascending" else "Descending")

	const Icon = MapButton.SkinTexture(if List.Ascending.Value then Skin.SortAscendButtonImage else Skin.SortButtonImage)

	Nodes.Set(Sort.Order, "icon", Icon)
	Nodes.Set(Sort.Item, "icon", Icon)
end

-- @src scripts/ui/menu/play/SortMenuButton.cs:_Ready L21-35
-- @src scripts/ui/menu/play/SortMenuButton.cs:_Input L37-49
const function New(Item: Item)
	const Sort = {
		Item = Item,
		Panel = Nodes.GetNode(Item, "Panel"),
		Order = Nodes.GetNode(Item, "Panel/MarginContainer/VBoxContainer/HBoxContainer/Sort"),
		OrderLabel = Nodes.GetNode(Item, "Panel/MarginContainer/VBoxContainer/HBoxContainer/VBoxContainer/SortOrder"),
		Buttons = Nodes.GetNode(Item, "Panel/MarginContainer/VBoxContainer/SortTypeButtons"),
		PreviousButton = nil,
	} :: SortMenu

	Nodes.Connect(Item, "toggled", function(Toggled: unknown)
		Toggle(Sort, Toggled == true)
	end)
	Nodes.Connect(Sort.Order, "pressed", function()
		ToggleOrder(Sort)
	end)

	const function OnSkinLoaded(Skin: SkinProfile.SkinProfile)
		UpdateSkin(Sort, Skin)
	end

	Signal.Connect(SkinManager.Loaded, OnSkinLoaded)
	table.insert(Item.Cleanup, function()
		Signal.Disconnect(SkinManager.Loaded, OnSkinLoaded)
	end)

	-- DEVIATION(input): Godot's Panel stops the mouse, so a click on its empty space or its labels (the order's "Ascending")
	-- never reaches the song behind it. A Roblox Frame lets a click through to a button behind it (Active only keeps it from
	-- the 3D world), so a bare button under the panel's contents takes those clicks.
	const Blocker = Instance.new("TextButton")
	Blocker.Name = "ClickBlocker"
	Blocker.Text = ""
	Blocker.AutoButtonColor = false
	Blocker.Selectable = false
	Blocker.BackgroundTransparency = 1
	Blocker.BorderSizePixel = 0
	Blocker.Size = UDim2.fromScale(1, 1)
	Blocker.ZIndex = -3
	Blocker.Parent = Sort.Panel.Instance

	Sort.PreviousButton = Nodes.GetNode(Sort.Buttons, "Alphabetical")

	for _, Button in Nodes.GetChildren(Sort.Buttons) do
		Nodes.Connect(Button, "pressed", function()
			SelectSort(Sort, Button)
		end)
	end

	-- _Input: a press outside the panel and the button closes the panel (ButtonPressed = false).
	table.insert(Item.Cleanup, Input.OnInput(function(Event: Input.InputEvent)
		if Event.Class ~= "InputEventMouseButton" or not Event.Pressed then
			return
		end

		-- (the pointer in the window's space, as the global positions are: the event's position is below the top bar's inset)
		const Point = Input.GetMousePosition()
		const InPanel = HasPoint(
			Nodes.Get(Sort.Panel, "global_position") :: vector,
			Nodes.Get(Sort.Panel, "size") :: vector,
			Point
		)
		const InButton = HasPoint(Nodes.Get(Item, "global_position") :: vector, Nodes.Get(Item, "size") :: vector, Point)

		if not InPanel and not InButton then
			Nodes.Set(Item, "button_pressed", false)
		end
	end))

	UpdateSkin(Sort, SkinManager.Skin)
end

return New
