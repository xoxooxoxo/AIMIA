--!strict
--!optimize 2

--[[
	The item model of a built Godot tree, shared by SceneBuilder, the controls in UI/Controls and Nodes: one Item per
	node with its Instance, its layout Node, its theme Context, the Instances it draws (Visuals), its Godot signals and
	its cleanup. Also the Roblox helpers the items use: theme values, text measurement, modulate tinting, and the queue
	of dirty layout roots that Nodes flushes once per frame.

	Design Notes
		Visuals: the Instances an item draws (its style box, text, input, texture, icon, and a control's own parts).
		Each visual keeps its own color and transparency (TintTargets), and is tinted by the product of the modulates up
		the tree, so fades need no CanvasGroup. Child items are not visuals of their parent.
		Signals: Godot signal names map to Util/Signal objects, created on first connect.
		Dirty layout: MarkDirty queues the top of the item's tree; Nodes flushes the queue once per frame.
]]

const TextService = game:GetService("TextService")

const Layout = require("./Layout")
const Theme = require("./Theme")
const Style = require("./Style")
const Images = require("./Images")
const Material = require("./Shaders/Material")
const TextMetrics = require("./TextMetrics")
const Scenes = require("./SceneData")
const DefaultTheme = require("./DefaultTheme")
const Signal = require("../Util/Signal")

const SceneIndex = (Scenes :: unknown) :: { [string]: Theme.File }

const ButtonClasses = {
	["Button"] = true,
	["CheckBox"] = true,
	["CheckButton"] = true,
	["OptionButton"] = true,
	["MenuButton"] = true,
	["LinkButton"] = true,
	["TextureButton"] = true,
	["ColorPickerButton"] = true,
}

const IgnoreClasses = {
	["Label"] = true,
	["RichTextLabel"] = true,
}

const ModeColors = {
	["normal"] = "font_color",
	["hover"] = "font_hover_color",
	["pressed"] = "font_pressed_color",
	["disabled"] = "font_disabled_color",
	["hover_pressed"] = "font_hover_pressed_color",
}

const ModeIconColors = {
	["normal"] = "icon_normal_color",
	["hover"] = "icon_hover_color",
	["pressed"] = "icon_pressed_color",
	["disabled"] = "icon_disabled_color",
	["hover_pressed"] = "icon_hover_pressed_color",
}

const HorizontalAlignments = {
	[0] = Enum.TextXAlignment.Left,
	[1] = Enum.TextXAlignment.Center,
	[2] = Enum.TextXAlignment.Right,
	[3] = Enum.TextXAlignment.Left,
}

const VerticalAlignments = {
	[0] = Enum.TextYAlignment.Top,
	[1] = Enum.TextYAlignment.Center,
	[2] = Enum.TextYAlignment.Bottom,
	[3] = Enum.TextYAlignment.Top,
}

const White = { 1, 1, 1, 1 }

-- The OptionButton arrow (a stand-in drawn by UI/Controls/OptionButton: the default theme arrow is not baked), in pixels.
const ArrowSize = vector.create(10, 6, 0)

-- Text bounds by text, font, size, wrap width and rich text (TextService measurements yield).
const Measurements: { [string]: vector } = {}
-- (emptied when it gets big: every new score text is measured, and measuring again is all a clear costs)
local MeasurementCount = 0

export type Item = {
	Path: string,
	Name: string,
	Class: string,
	IsControl: boolean,
	Instance: Instance,
	Context: Theme.Context,
	Node: Layout.Node,
	Children: { Item },
	Parent: Item?,
	Scene: Built,
	Freed: boolean,
	Dirty: boolean,
	Moved: boolean,
	Generation: number,
	Mode: string,
	Hovered: boolean,
	Held: boolean,
	Toggled: boolean,
	Disabled: boolean,
	Modulate: { number },
	Visuals: { Instance },
	StyleHost: Frame?,
	Text: TextLabel?,
	Input: TextBox?,
	Texture: ImageLabel?,
	Icon: ImageLabel?,
	Arrow: ImageLabel?,
	GrabberArea: Frame?,
	Grabber: ImageLabel?,
	Ticks: { ImageLabel },
	TintTargets: { Instance },
	TintColors: { Color3 },
	TintTransparencies: { number },
	IconSize: vector?,
	ButtonTextWidth: number?,
	SizeDrawn: boolean,
	StyleSize: vector,
	LastSize: vector,
	Pivot: vector,
	Scale: number,
	Rotation: number,
	Items: { string },
	Selected: number,
	Menu: GuiObject?,
	Signals: { [string]: Signal.Signal<...unknown> },
	Connections: { RBXScriptConnection },
	Cleanup: { () -> () },
}

export type Built = {
	Root: Item?,
	Items: { [string]: Item },
	Order: { Item },
	Viewport: GuiBase2d,
}

const DirtyRoots: { Item } = {}
-- SlideOnly controls (the play list's rows) with a change under them, laid out alone (SceneBuilder.RelayoutLocal).
const DirtyLocals: { Item } = {}
-- Controls moved or resized by their own offsets, laid out alone (Layout.UpdateSubtree) unless their tree is dirty.
const MovedItems: { Item } = {}

const function Number(Properties: { [string]: unknown }, Key: string, Default: number): number
	const Value = Properties[Key]

	return if type(Value) == "number" then Value else Default
end

-- The bar of a ScrollContainer's ScrollingFrame as the theme's VScrollBar draws it: a white grabber 4 pixels wide (the scroll
-- style's width), shown for the scroll modes auto and show always (1, 2), hidden for the others.
const ScrollBarWidth = 4

const function StyleScrollBar(Gui: ScrollingFrame, Mode: number)
	Gui.ScrollBarThickness = if Mode == 1 or Mode == 2 then ScrollBarWidth else 0
	Gui.ScrollBarImageColor3 = Color3.new(1, 1, 1)
	Gui.ScrollBarImageTransparency = 0
	Gui.VerticalScrollBarInset = Enum.ScrollBarInset.None
end

const function VectorOf(Value: unknown): vector
	if type(Value) == "vector" then
		return Value :: vector
	end

	if type(Value) == "table" then
		const Pair = (Value :: { Vector2: { number }? }).Vector2

		if Pair then
			return vector.create(Pair[1], Pair[2], 0)
		end
	end

	return vector.zero
end

const function ColorComponents(Value: unknown): { number }
	if type(Value) == "table" then
		const Components = (Value :: { Color: { number }? }).Color

		if Components then
			return Components
		end
	end

	return White
end

-- Answers a theme or property value and the file its references resolve in.
const function GetItem(Item: Item, Kind: string, Name: string): (unknown, Theme.File?)
	return Theme.GetItem(Item.Context, Kind, Name, SceneIndex)
end

-- Resolves a value naming a resource. Inline resources ({ Type, Properties }, as scripts set them) and texture paths
-- ({ Path = "res://..." }) resolve without a file; default-theme style boxes are inline tables too.
const function ResolveValue(Value: unknown, File: Theme.File?, Item: Item): Theme.Resource?
	if type(Value) ~= "table" then
		return nil
	end

	const Inline = Value :: { Type: string?, Properties: { [string]: unknown }?, File: Theme.File?, Path: string?, Ext: string?, Sub: string? }

	if Inline.Type and Inline.Properties then
		return {
			Type = Inline.Type,
			Path = Inline.Path,
			Properties = Inline.Properties,
			File = Inline.File or Item.Context.File,
		}
	end

	if Inline.Path and not Inline.Ext and not Inline.Sub then
		return {
			Type = "Texture2D",
			Path = Inline.Path,
			Properties = {},
			File = Item.Context.File,
		}
	end

	return Theme.ResolveResource(File or Item.Context.File, Value, SceneIndex)
end

const function GetStyle(Item: Item, Name: string): Theme.Resource?
	const Value, File = GetItem(Item, "styles", Name)

	return ResolveValue(Value, File, Item)
end

const function GetColor(Item: Item, Name: string): { number }
	return ColorComponents((GetItem(Item, "colors", Name)))
end

const function GetConstant(Item: Item, Name: string, Default: number): number
	const Value = GetItem(Item, "constants", Name)

	return if type(Value) == "number" then Value else Default
end

const function LabelSettings(Item: Item): Theme.Resource?
	const Properties = Item.Context.Properties

	return ResolveValue(Properties["label_settings"], Theme.FileOf(Item.Context, "label_settings"), Item)
end

const function GetFont(Item: Item): Font
	const Settings = LabelSettings(Item)

	if Settings and Settings.Properties["font"] ~= nil then
		return Style.GetFont(Theme.ResolveResource(Settings.File, Settings.Properties["font"], SceneIndex))
	end

	const Value, File = GetItem(Item, "fonts", if Item.Class == "RichTextLabel" then "normal_font" else "font")

	return Style.GetFont(ResolveValue(Value, File, Item))
end

const function GetFontSize(Item: Item): number
	const Settings = LabelSettings(Item)

	if Settings and type(Settings.Properties["font_size"]) == "number" then
		return Settings.Properties["font_size"] :: number
	end

	const Value = GetItem(Item, "font_sizes", if Item.Class == "RichTextLabel" then "normal_font_size" else "font_size")

	return if type(Value) == "number" then Value else 16
end

-- The text an item shows: a Label's or button's text property, or an OptionButton's selected item.
const function RawText(Item: Item): string
	if Item.Class == "OptionButton" then
		return Item.Items[Item.Selected + 1] or ""
	end

	const Value = Item.Context.Properties["text"]

	return if type(Value) == "string" then Value else ""
end

const function DisplayText(Item: Item): string
	const Value = RawText(Item)

	if Item.Context.Properties["uppercase"] == true then
		return string.upper(Value)
	end

	return Value
end

-- Text bounds (width, height) by text, font, Godot font size and wrap width (nil: no wrap); cached per key. The text is measured
-- at the Roblox TextSize of the font size (Style.TextSizeOf), as it is drawn.
const function Measure(Text: string, Font: Font, Size: number, Width: number?, RichText: boolean?): vector
	const Key = `{Text}\0{Font.Family}\0{Font.Weight.Name}\0{Font.Style.Name}\0{Size}\0{Width or 0}\0{RichText == true}`
	const Cached = Measurements[Key]

	if Cached then
		return Cached
	end

	const Parameters = Instance.new("GetTextBoundsParams")

	Parameters.Text = if #Text > 0 then Text else " "
	Parameters.Font = Font
	Parameters.Size = Style.TextSizeOf(Font, Size)
	Parameters.Width = Width or math.huge
	Parameters.RichText = RichText == true

	const Success, Bounds = pcall(TextService.GetTextBoundsAsync, TextService, Parameters)

	if not Success then
		warn(`Aimia UI: text measure failed: {Bounds}`)

		return vector.create(0, Size, 0)
	end

	const Result = Bounds :: Vector2
	const Measured = vector.create(if #Text > 0 then Result.X else 0, Result.Y, 0)

	if MeasurementCount >= 4096 then
		table.clear(Measurements)
		MeasurementCount = 0
	end

	Measurements[Key] = Measured
	MeasurementCount += 1

	return Measured
end

-- Godot's font measurements through Roblox: the widest line, Godot's font height (Style.FontHeight; Roblox's line of "W"
-- when the family has no metrics) and the line count (after wrapping at Width, in Roblox lines of TextSize).
const function MeasurerFor(Item: Item): TextMetrics.Measurer
	const Font = GetFont(Item)

	return function(Text: string, Size: number, Width: number?): (number, number, number)
		const Line = Measure("W", Font, Size)
		const Bounds = Measure(Text, Font, Size, if Width and Width > 0 then Width else nil)
		const Lines = math.max(1, math.round(Bounds.y / math.max(Line.y, 1)))

		return Bounds.x, Style.FontHeight(Font, Size) or Line.y, Lines
	end
end

const function MarginsOf(Box: Theme.Resource?): TextMetrics.StyleMargins
	return {
		Left = Style.GetMargin(Box, "left"),
		Top = Style.GetMargin(Box, "top"),
		Right = Style.GetMargin(Box, "right"),
		Bottom = Style.GetMargin(Box, "bottom"),
	}
end

const function SettingsNumber(Item: Item, Key: string, Constant: string, Default: number): number
	const Settings = LabelSettings(Item)

	if Settings and type(Settings.Properties[Key]) == "number" then
		return Settings.Properties[Key] :: number
	end

	return GetConstant(Item, Constant, Default)
end

const function LabelParamsOf(Item: Item): TextMetrics.LabelParams
	const Properties = Item.Context.Properties
	const Separator = Properties["paragraph_separator"]

	return {
		Measure = MeasurerFor(Item),
		Text = RawText(Item),
		Uppercase = Properties["uppercase"] == true,
		FontSize = GetFontSize(Item),
		LineSpacing = SettingsNumber(Item, "line_spacing", "line_spacing", 3),
		ParagraphSpacing = SettingsNumber(Item, "paragraph_spacing", "paragraph_spacing", 0),
		ParagraphSeparator = if type(Separator) == "string" and #Separator > 0 then (string.gsub(Separator, "\\n", "\n")) else "\n",
		AutowrapMode = Number(Properties, "autowrap_mode", 0),
		Clip = Properties["clip_text"] == true,
		OverrunBehavior = Number(Properties, "text_overrun_behavior", 0),
		HorizontalAlignment = Number(Properties, "horizontal_alignment", 0),
		VerticalAlignment = Number(Properties, "vertical_alignment", 0),
		MaxLinesVisible = Number(Properties, "max_lines_visible", -1),
		LinesSkipped = Number(Properties, "lines_skipped", 0),
		VisibleChars = Number(Properties, "visible_characters", -1),
		VisibleCharsBehavior = Number(Properties, "visible_characters_behavior", 0),
		MaximumWidth = -1,
		RectWidth = Item.Node.Size.x,
		LayoutRtl = false,
		Normal = MarginsOf(GetStyle(Item, "normal")),
	}
end

const function ButtonParamsOf(Item: Item): TextMetrics.ButtonParams
	const Properties = Item.Context.Properties
	const HoverPressed = GetStyle(Item, "hover_pressed")

	return {
		Measure = MeasurerFor(Item),
		Text = RawText(Item),
		FontSize = GetFontSize(Item),
		LineSpacing = GetConstant(Item, "line_spacing", 0),
		HorizontalSeparation = GetConstant(Item, "h_separation", 4),
		IconMaxWidth = GetConstant(Item, "icon_max_width", 0),
		AlignToLargestStylebox = GetConstant(Item, "align_to_largest_stylebox", 0) ~= 0,
		Alignment = Number(Properties, "alignment", 1),
		IconAlignment = Number(Properties, "icon_alignment", 0),
		VerticalIconAlignment = Number(Properties, "vertical_icon_alignment", 1),
		ExpandIcon = Properties["expand_icon"] == true,
		ClipText = Properties["clip_text"] == true,
		OverrunBehavior = Number(Properties, "text_overrun_behavior", 0),
		AutowrapMode = Number(Properties, "autowrap_mode", 0),
		LayoutRtl = false,
		Mode = Item.Mode :: TextMetrics.DrawMode,
		Styles = {
			Normal = MarginsOf(GetStyle(Item, "normal")),
			Pressed = MarginsOf(GetStyle(Item, "pressed")),
			Hover = MarginsOf(GetStyle(Item, "hover")),
			Disabled = MarginsOf(GetStyle(Item, "disabled")),
			HoverPressed = if HoverPressed then MarginsOf(HoverPressed) else nil,
		},
		IconSize = Item.IconSize,
		TextWidth = Item.ButtonTextWidth,
		InternalLeft = 0,
		InternalRight = if Item.Class == "OptionButton" then ArrowSize.x + GetConstant(Item, "arrow_margin", 4) else 0,
	}
end

const function LineEditParamsOf(Item: Item): TextMetrics.LineEditParams
	const Properties = Item.Context.Properties
	const Placeholder = Properties["placeholder_text"]

	return {
		Measure = MeasurerFor(Item),
		Text = RawText(Item),
		Placeholder = if type(Placeholder) == "string" then Placeholder else "",
		Secret = Properties["secret"] == true,
		SecretCharacter = "",
		ImeText = "",
		CaretColumn = 0,
		FontSize = GetFontSize(Item),
		MinimumCharacterWidth = GetConstant(Item, "minimum_character_width", 4),
		CaretWidth = GetConstant(Item, "caret_width", 1),
		ExpandToTextLength = Properties["expand_to_text_length"] == true,
		Editable = Properties["editable"] ~= false,
		ClearButtonEnabled = Properties["clear_button_enabled"] == true,
		ClearIconSize = vector.zero,
		RightIconSize = nil,
		IconExpandMode = Number(Properties, "icon_expand_mode", 0),
		RightIconScale = Number(Properties, "right_icon_scale", 1),
		Alignment = Number(Properties, "alignment", 0),
		ScrollOffset = 0,
		LayoutRtl = false,
		RectWidth = Item.Node.Size.x,
		RectHeight = Item.Node.Size.y,
		Normal = MarginsOf(GetStyle(Item, "normal")),
		ReadOnly = MarginsOf(GetStyle(Item, "read_only")),
	}
end

const function OwnModulate(Item: Item): { number }
	return ColorComponents(Item.Context.Properties["self_modulate"])
end

-- The node's shader material (its shader path or inline code, its material parameters and the node's overrides), or nil.
const function ShaderOf(Item: Item): Material.Material?
	const Resource = ResolveValue(Item.Context.Properties["material"], Theme.FileOf(Item.Context, "material"), Item)

	if not Resource or Resource.Type ~= "ShaderMaterial" then
		return nil
	end

	const Shader = ResolveValue(Resource.Properties["shader"], Resource.File, Item)

	if not Shader then
		return nil
	end

	const Code = Shader.Properties["code"]

	return {
		Path = Shader.Path,
		Code = if type(Code) == "string" then Code else nil,
		Parameters = Resource.Properties,
		Overrides = Item.Context.Properties,
	}
end

-- The separator line of an HSeparator or VSeparator. The default theme has no HSeparator type (default_theme.cpp L1084
-- sets separator_horizontal, the same box as the PopupMenu separator in DefaultTheme), which stands in when the theme
-- has no separator of its own.
const function SeparatorStyle(Item: Item): Theme.Resource?
	const Value, File = GetItem(Item, "styles", "separator")

	if Value ~= nil then
		return ResolveValue(Value, File, Item)
	end

	const Fallback = (DefaultTheme.Types :: { [string]: { StyleBoxes: { [string]: unknown } } })["PopupMenu"].StyleBoxes["separator"]

	return ResolveValue(Fallback, nil, Item)
end

-- The style box an item's StyleHost draws for its current mode and class.
const function StyleFor(Item: Item): Theme.Resource?
	const Class = Item.Class

	if (ButtonClasses :: { [string]: boolean })[Class] then
		if Item.Context.Properties["flat"] == true then
			return nil
		end

		return GetStyle(Item, Item.Mode)
	elseif Class == "Panel" or Class == "PanelContainer" or Class == "ScrollContainer" then
		return GetStyle(Item, "panel")
	elseif Class == "Label" or Class == "RichTextLabel" or Class == "LineEdit" then
		return GetStyle(Item, "normal")
	elseif Class == "HSlider" then
		return GetStyle(Item, "slider")
	elseif Class == "HSeparator" or Class == "VSeparator" then
		return SeparatorStyle(Item)
	end

	return nil
end

-- A texture property (a resource reference or { Path }) when its image is baked, else nil.
const function TexturePath(Item: Item, Key: string): string?
	const Resource = ResolveValue(Item.Context.Properties[Key], Theme.FileOf(Item.Context, Key), Item)

	if Resource and Resource.Path and Images.Has(Resource.Path) then
		return Resource.Path
	end

	return nil
end

-- A theme icon (a texture resource in the theme) when its image is baked, else nil.
const function ThemeTexturePath(Item: Item, Name: string): string?
	const Value, File = GetItem(Item, "icons", Name)
	const Resource = ResolveValue(Value, File, Item)

	if Resource and Resource.Path and Images.Has(Resource.Path) then
		return Resource.Path
	end

	return nil
end

const function IsButton(Class: string): boolean
	return (ButtonClasses :: { [string]: boolean })[Class] == true
end

-- The item's position in viewport pixels: its layout position plus those of its Control ancestors (a parent that is not
-- a Control, or a top-level item, ends the chain: Layout anchors those to the viewport).
const function GlobalPosition(Item: Item): vector
	local Position = Item.Node.Position
	local Current = Item

	while Current.Parent and Current.Parent.IsControl and not Current.Node.TopLevel do
		Current = Current.Parent
		Position += Current.Node.Position
	end

	return Position
end

-- Records each visual's own color and transparency, so modulate can tint them later.
const function CollectTints(Item: Item)
	table.clear(Item.TintTargets)
	table.clear(Item.TintColors)
	table.clear(Item.TintTransparencies)

	const Visuals: { Instance } = {}

	for _, Visual in Item.Visuals do
		table.insert(Visuals, Visual)

		for _, Descendant in Visual:GetDescendants() do
			table.insert(Visuals, Descendant)
		end
	end

	for _, Visual in Visuals do
		local Color: Color3? = nil
		local Transparency: number? = nil

		if Visual:IsA("TextLabel") or Visual:IsA("TextBox") then
			Color = Visual.TextColor3
			Transparency = Visual.TextTransparency
		elseif Visual:IsA("ImageLabel") then
			Color = Visual.ImageColor3
			Transparency = Visual.ImageTransparency
		elseif Visual:IsA("Frame") then
			Color = Visual.BackgroundColor3
			Transparency = Visual.BackgroundTransparency
		elseif Visual:IsA("UIStroke") and Visual.Name ~= "InkEdge" then -- (the HUD's own edge keeps its colour: UIComponent.InkText)
			Color = Visual.Color
			Transparency = Visual.Transparency
		end

		if Color and Transparency then
			table.insert(Item.TintTargets, Visual)
			table.insert(Item.TintColors, Color)
			table.insert(Item.TintTransparencies, Transparency)
		end
	end
end

-- Tints the item's visuals by a modulate product (R, G, B, A).
const function TintItem(Item: Item, R: number, G: number, B: number, A: number)
	const Colors = Item.TintColors
	const Transparencies = Item.TintTransparencies

	for Index, Visual in Item.TintTargets do
		const Base = Colors[Index]
		const Color = Color3.new(math.clamp(Base.R * R, 0, 1), math.clamp(Base.G * G, 0, 1), math.clamp(Base.B * B, 0, 1))
		const Transparency = 1 - (1 - Transparencies[Index]) * math.clamp(A, 0, 1)

		if Visual:IsA("TextLabel") or Visual:IsA("TextBox") then
			Visual.TextColor3 = Color
			Visual.TextTransparency = Transparency
		elseif Visual:IsA("ImageLabel") then
			-- A shader's label keeps the color its shader sets (a modulate's color does not reach it): only its alpha follows.
			if not Visual:GetAttribute("KeepColor") then
				Visual.ImageColor3 = Color
			end

			Visual.ImageTransparency = Transparency
		elseif Visual:IsA("Frame") then
			Visual.BackgroundColor3 = Color
			Visual.BackgroundTransparency = Transparency
		elseif Visual:IsA("UIStroke") then
			Visual.Color = Color
			Visual.Transparency = Transparency
		end
	end
end

-- The product of the modulates of the item and its ancestors.
const function Inherited(Item: Item): (number, number, number, number)
	local R, G, B, A = 1, 1, 1, 1
	local Current: Item? = Item

	while Current do
		const Modulate = Current.Modulate

		R *= Modulate[1]
		G *= Modulate[2]
		B *= Modulate[3]
		A *= Modulate[4]
		Current = Current.Parent
	end

	return R, G, B, A
end

-- Re-tints a subtree after a modulate change; R, G, B, A is the product above Item (its parent's).
const function RetintTree(Item: Item, R: number, G: number, B: number, A: number)
	const Modulate = Item.Modulate
	const ItemR = R * Modulate[1]
	const ItemG = G * Modulate[2]
	const ItemB = B * Modulate[3]
	const ItemA = A * Modulate[4]

	TintItem(Item, ItemR, ItemG, ItemB, ItemA)

	for _, Child in Item.Children do
		RetintTree(Child, ItemR, ItemG, ItemB, ItemA)
	end
end

-- Sets an item's modulate and tints its subtree by the product above it.
const function SetModulate(Item: Item, R: number, G: number, B: number, A: number)
	const Modulate = Item.Modulate

	Modulate[1] = R
	Modulate[2] = G
	Modulate[3] = B
	Modulate[4] = A

	if Item.Parent then
		RetintTree(Item, Inherited(Item.Parent))
	else
		RetintTree(Item, 1, 1, 1, 1)
	end
end

-- The Util/Signal of a Godot signal name, created on first use.
const function GetSignal(Item: Item, Name: string): Signal.Signal<...unknown>
	const Existing = Item.Signals[Name]

	if Existing then
		return Existing
	end

	const Created: Signal.Signal<...unknown> = Signal.New()

	Item.Signals[Name] = Created

	return Created
end

-- Emits a Godot signal of an item (synchronously, in connection order).
const function Emit(Item: Item, Name: string, ...: unknown)
	const Existing = Item.Signals[Name]

	if Existing then
		Signal.Fire(Existing, ...)
	end
end

-- The top of an item's tree (the item itself when it has no parent).
const function TopOf(Item: Item): Item
	local Current = Item

	while Current.Parent do
		Current = Current.Parent
	end

	return Current
end

-- Queues the top of the item's tree for a layout pass (once until it is taken). A change under an attached SlideOnly control
-- (the play list's rows) queues that control alone instead: its parent is not a container, so nothing outside it follows its
-- size, and laying the whole menu out for each row of songs the list scrolled in was the stutter of the grid
-- (SceneBuilder.RelayoutLocal).
const function MarkDirty(Item: Item)
	local Current = Item

	while Current.Parent do
		const Held: any = Current

		if Held.SlideOnly and not string.find(Current.Parent.Class, "Container", 1, true) then
			-- (and until that layout has been written, the row isn't only slid: SceneBuilder.RelayoutMoved lays it out whole)
			Held.LocalPending = true

			if not Held.DirtyLocal then
				Held.DirtyLocal = true
				table.insert(DirtyLocals, Current)
			end

			return
		end

		Current = Current.Parent
	end

	if not Current.Dirty then
		Current.Dirty = true
		table.insert(DirtyRoots, Current)
	end
end

-- Queues a control whose own rect changed (position, offsets, anchors). A control inside a container is sorted by
-- that container, and its tree is queued whole instead.
const function MarkMoved(Item: Item)
	const Parent = Item.Parent

	if Parent and Parent.IsControl and string.find(Parent.Class, "Container", 1, true) then
		MarkDirty(Item)
	elseif not Item.Moved then
		Item.Moved = true
		table.insert(MovedItems, Item)
	end
end

-- Queues the layout of a control whose own minimum size changed. Containers above it sort it, so the control that no container sorts
-- (the first ancestor whose parent is not a container) is laid out again with its subtree, and nothing else: a card growing on
-- hover costs its row, not the scene.
const function MarkResized(Item: Item)
	local Top = Item

	while Top.Parent and Top.Parent.IsControl and string.find(Top.Parent.Class, "Container", 1, true) do
		Top = Top.Parent
	end

	-- (a minimum size changed under it: its subtree is laid out again, even for a control that otherwise only slides,
	-- SceneBuilder.RelayoutMoved)
	const Resizing: any = Top

	Resizing.ResizedPending = true
	MarkMoved(Top)
end

-- Takes the queued moved controls, oldest first (the list is reused).
const function TakeMoved(Into: { Item })
	table.clear(Into)

	for Index, Item in MovedItems do
		Into[Index] = Item
		Item.Moved = false
	end

	table.clear(MovedItems)
end

const function HasDirty(): boolean
	return #DirtyRoots > 0
end

const function HasDirtyLocal(): boolean
	return #DirtyLocals > 0
end

-- Takes the oldest queued SlideOnly control (clearing its flag), or nil when none is queued.
const function TakeDirtyLocal(): Item?
	if #DirtyLocals == 0 then
		return nil
	end

	const Local = table.remove(DirtyLocals, 1) :: Item
	const Held: any = Local

	Held.DirtyLocal = false

	return Local
end

-- Takes the oldest dirty root (clearing its flag), or nil when none is queued.
const function TakeDirty(): Item?
	if #DirtyRoots == 0 then
		return nil
	end

	const Top = table.remove(DirtyRoots, 1) :: Item

	Top.Dirty = false

	return Top
end

return {
	StyleScrollBar = StyleScrollBar,
	ButtonClasses = ButtonClasses,
	IgnoreClasses = IgnoreClasses,
	ModeColors = ModeColors,
	ModeIconColors = ModeIconColors,
	HorizontalAlignments = HorizontalAlignments,
	VerticalAlignments = VerticalAlignments,
	White = White,
	SceneIndex = SceneIndex,
	Number = Number,
	VectorOf = VectorOf,
	ColorComponents = ColorComponents,
	GetItem = GetItem,
	ResolveValue = ResolveValue,
	GetStyle = GetStyle,
	GetColor = GetColor,
	GetConstant = GetConstant,
	LabelSettings = LabelSettings,
	GetFont = GetFont,
	GetFontSize = GetFontSize,
	TextSizeOf = Style.TextSizeOf,
	RawText = RawText,
	DisplayText = DisplayText,
	Measure = Measure,
	MeasurerFor = MeasurerFor,
	MarginsOf = MarginsOf,
	LabelParamsOf = LabelParamsOf,
	ButtonParamsOf = ButtonParamsOf,
	LineEditParamsOf = LineEditParamsOf,
	OwnModulate = OwnModulate,
	StyleFor = StyleFor,
	TexturePath = TexturePath,
	ThemeTexturePath = ThemeTexturePath,
	ShaderOf = ShaderOf,
	ArrowSize = ArrowSize,
	GlobalPosition = GlobalPosition,
	IsButton = IsButton,
	CollectTints = CollectTints,
	TintItem = TintItem,
	Inherited = Inherited,
	SetModulate = SetModulate,
	GetSignal = GetSignal,
	Emit = Emit,
	TopOf = TopOf,
	MarkDirty = MarkDirty,
	MarkMoved = MarkMoved,
	MarkResized = MarkResized,
	TakeMoved = TakeMoved,
	HasDirty = HasDirty,
	TakeDirty = TakeDirty,
	HasDirtyLocal = HasDirtyLocal,
	TakeDirtyLocal = TakeDirtyLocal,
}
