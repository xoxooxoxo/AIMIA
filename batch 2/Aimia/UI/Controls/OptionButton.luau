--!strict
--!optimize 2

--[[
	OptionButton (Godot option_button.cpp, not in reference/engine) with its PopupMenu. The button shows the selected
	item's text (Item.RawText) and an arrow at its right. A click opens the popup: the items as rows under the button,
	or above it when the viewport has no room below. Rows use the PopupMenu theme of the button (the panel and hover
	style boxes, font and hover colors, and the constants of the PopupMenu type), resolved through a context whose
	parent is the button's. Choosing a row selects it and emits item_selected(index); any other click closes the popup.

	Design Notes
		The item list and the selection (Item.Items, Item.Selected: 0-based, -1 for none) are the button's state. Every
		change goes through the caller's Refresh (SceneBuilder.Refresh), which redraws and relayouts the button.
		Select does not emit item_selected, as Godot's select() does not.

	DEVIATION(unverified): option_button.cpp and popup_menu.cpp are not in reference/engine. The arrow is a stand-in
	(Godot's arrow icon is generated and not baked), 10 x 6 pixels, tinted by the button's icon colors. The popup is as
	wide as the button (fit_to_longest_item is off in the scenes), has no scroll bar (a long list runs off the
	viewport), no separators and no keyboard navigation, and is not tinted by the modulate of the button's ancestors.
	Rows are padded by item_start_padding and item_end_padding, not Godot's icon and indent layout. A full-viewport
	backdrop swallows the click that closes the popup.
]]

const Items = require("../Item")
const Chevron = require("../Chevron")
const Scale = require("../Scale")
const Style = require("../Style")
const Theme = require("../Theme")

type Item = Items.Item

const ArrowWidth = Items.ArrowSize.x
const ArrowHeight = Items.ArrowSize.y

-- Godot's defaults for the PopupMenu constants (default_theme.cpp), used when the theme has no value.
const PopupDefaults = {
	["v_separation"] = 4,
	["item_start_padding"] = 2,
	["item_end_padding"] = 2,
}

const ArrowStroke = 1.5

-- The theme context of the popup: a PopupMenu whose parent is the button, so its lookups reach the button's themes.
const function PopupContextOf(Item: Item): Theme.Context
	return {
		Class = "PopupMenu",
		IsControl = true,
		File = Item.Context.File,
		Files = {},
		Properties = {},
		Parent = Item.Context,
	}
end

-- A PopupMenu constant from the popup's theme, or Godot's default.
const function PopupConstant(Context: Theme.Context, Name: string): number
	const Value = Theme.GetItem(Context, "constants", Name, Items.SceneIndex)

	if type(Value) == "number" then
		return Value
	end

	return (PopupDefaults :: { [string]: number })[Name]
end

-- A PopupMenu style box, resolved for the item (nil when the theme has none).
const function PopupStyle(Item: Item, Context: Theme.Context, Name: string): Theme.Resource?
	const Value, File = Theme.GetItem(Context, "styles", Name, Items.SceneIndex)

	return Items.ResolveValue(Value, File, Item)
end

const function Close(Item: Item)
	if Item.Menu then
		Item.Menu:Destroy()
		Item.Menu = nil
	end
end

-- The arrow at the right of the button, tinted by the icon color of the button's mode.
const function Draw(Item: Item)
	const Arrow = Item.Arrow

	if not Arrow then
		return
	end

	const Box = Items.GetStyle(Item, Item.Mode)
	const Right = Style.GetMargin(Box, "right")
	const IconColor = (Items.ModeIconColors :: { [string]: string })[Item.Mode] or "icon_normal_color"
	const Color, Transparency = Style.ToColor({ Color = Items.GetColor(Item, IconColor) }, Items.OwnModulate(Item))

	Chevron.SetColor(Arrow, Color, Transparency)
	Arrow.Position = UDim2.fromOffset(Item.Node.Size.x - Right - ArrowWidth, (Item.Node.Size.y - ArrowHeight) / 2)
	Arrow.Size = UDim2.fromOffset(ArrowWidth, ArrowHeight)
end

-- Adds the arrow to the button.
const function Build(Item: Item)
	const Arrow = Instance.new("ImageLabel")

	Arrow.Name = "Arrow"
	Arrow.BackgroundTransparency = 1
	Arrow.ImageTransparency = 1
	Arrow.ZIndex = 0
	Chevron.New(Arrow, ArrowWidth, ArrowHeight, ArrowStroke, Color3.new(1, 1, 1), 0)
	Arrow.Parent = Item.Instance
	Item.Arrow = Arrow
	table.insert(Item.Visuals, Arrow)
end

-- Opens the popup under the button, or above it when there is no room below, behind a full-viewport backdrop.
const function Open(Item: Item, Refresh: (Item) -> ())
	Close(Item)

	const Context = PopupContextOf(Item)
	const Font = Items.GetFont(Item)
	const FontSize = Items.GetFontSize(Item)
	const Separation = PopupConstant(Context, "v_separation")
	const StartPadding = PopupConstant(Context, "item_start_padding")
	const Viewport = Item.Scene.Viewport
	const PanelBox = PopupStyle(Item, Context, "panel")
	const HoverBox = PopupStyle(Item, Context, "hover")
	const Margins = Style.GetMinimumSize(PanelBox)
	const Origin = Items.GlobalPosition(Item)
	const Width = Item.Node.Size.x
	const RowHeight = Items.Measure("W", Font, FontSize).y + Separation
	const ListHeight = #Item.Items * RowHeight + Margins.y
	const Below = Origin.y + Item.Node.Size.y
	const ListTop = if Below + ListHeight > Scale.SizeOfViewport(Viewport).y and Origin.y - ListHeight >= 0 then Origin.y - ListHeight else Below
	const FontColor = Style.ToColor({ Color = Items.ColorComponents(Theme.GetItem(Context, "colors", "font_color", Items.SceneIndex)) })
	const HoverColor = Style.ToColor({ Color = Items.ColorComponents(Theme.GetItem(Context, "colors", "font_hover_color", Items.SceneIndex)) })

	const Backdrop = Instance.new("TextButton")

	Backdrop.Name = "PopupBackdrop"
	Backdrop.Text = ""
	Backdrop.AutoButtonColor = false
	Backdrop.BackgroundTransparency = 1
	Backdrop.BorderSizePixel = 0
	Backdrop.Size = UDim2.fromScale(1, 1)
	Backdrop.ZIndex = 99
	Backdrop.Parent = Viewport

	const List = Instance.new("Frame")

	List.Name = "PopupMenu"
	List.BackgroundTransparency = 1
	List.BorderSizePixel = 0
	List.Position = UDim2.fromOffset(Origin.x, ListTop)
	List.Size = UDim2.fromOffset(Width, ListHeight)
	List.ZIndex = 100
	List.Parent = Backdrop

	const Panel = Instance.new("Frame")

	Panel.Name = "Panel"
	Panel.BackgroundTransparency = 1
	Panel.BorderSizePixel = 0
	Panel.ZIndex = -2
	Panel.Parent = List
	Style.DrawStyleBox(Panel, PanelBox, nil, Width, ListHeight)
	Panel.Position = UDim2.fromOffset(0, 0)
	Panel.Size = UDim2.fromOffset(Width, ListHeight)

	const Hover = Instance.new("Frame")

	Hover.Name = "Hover"
	Hover.BackgroundTransparency = 1
	Hover.BorderSizePixel = 0
	Hover.Visible = false
	Hover.ZIndex = -1
	Hover.Parent = List
	Style.DrawStyleBox(Hover, HoverBox, nil, Width, RowHeight)
	Hover.Size = UDim2.fromOffset(Width, RowHeight)

	Backdrop.Activated:Connect(function()
		Close(Item)
	end)

	for Index = 1, #Item.Items do
		const Row = Instance.new("TextButton")
		const Inset = Instance.new("UIPadding")
		const RowTop = Margins.y / 2 + (Index - 1) * RowHeight

		Row.Name = `Item{Index - 1}`
		Row.Text = Item.Items[Index]
		Row.AutoButtonColor = false
		Row.BackgroundTransparency = 1
		Row.BorderSizePixel = 0
		Row.FontFace = Font
		Row.TextSize = Items.TextSizeOf(Font, FontSize)
		Row.TextXAlignment = Enum.TextXAlignment.Left
		Row.TextColor3 = FontColor
		Row.TextTransparency = 0
		Row.Position = UDim2.fromOffset(0, RowTop)
		Row.Size = UDim2.fromOffset(Width, RowHeight)
		Row.ZIndex = 1
		Row.Parent = List
		Inset.PaddingLeft = UDim.new(0, StartPadding)
		Inset.PaddingRight = UDim.new(0, PopupConstant(Context, "item_end_padding"))
		Inset.Parent = Row

		Row.MouseEnter:Connect(function()
			Hover.Position = UDim2.fromOffset(0, RowTop)
			Hover.Visible = true
			Row.TextColor3 = HoverColor
		end)
		Row.MouseLeave:Connect(function()
			Row.TextColor3 = FontColor
		end)
		Row.Activated:Connect(function()
			Close(Item)
			Item.Selected = Index - 1
			Refresh(Item)
			Items.Emit(Item, "item_selected", Index - 1)
		end)
	end

	Item.Menu = Backdrop
end

-- A click on the button opens the popup, or closes it when it is open.
const function Toggle(Item: Item, Refresh: (Item) -> ())
	if Item.Menu then
		Close(Item)
	else
		Open(Item, Refresh)
	end
end

const function AddItem(Item: Item, Text: string, Refresh: (Item) -> ())
	table.insert(Item.Items, Text)

	if Item.Selected < 0 then
		Item.Selected = 0
	end

	Refresh(Item)
end

const function RemoveItem(Item: Item, Index: number, Refresh: (Item) -> ())
	table.remove(Item.Items, Index + 1)

	if Item.Selected > Index then
		Item.Selected -= 1
	elseif Item.Selected == Index then
		Item.Selected = math.min(Index, #Item.Items - 1)
	end

	Refresh(Item)
end

const function Clear(Item: Item, Refresh: (Item) -> ())
	table.clear(Item.Items)
	Item.Selected = -1
	Refresh(Item)
end

-- Selects an item without emitting item_selected (Godot's select()).
const function Select(Item: Item, Index: number, Refresh: (Item) -> ())
	Item.Selected = math.clamp(Index, -1, #Item.Items - 1)
	Refresh(Item)
end

return {
	Build = Build,
	Draw = Draw,
	Close = Close,
	Toggle = Toggle,
	AddItem = AddItem,
	RemoveItem = RemoveItem,
	Clear = Clear,
	Select = Select,
}
