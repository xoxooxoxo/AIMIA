--!strict
--!optimize 2

--[[
	Builds Roblox Instances from converted Godot scenes (UI/SceneData, docs/port/ui.md) and keeps them laid out with
	Godot's layout (UI/Layout). The nodes are Items (UI/Item); the script API is UI/Nodes.

	Paradigm
		Every node becomes one Instance named after it: Folder for non-Control nodes, TextButton for buttons and
		sliders, ScrollingFrame for ScrollContainer, Frame otherwise. A control's own drawing lives in children behind
		its child controls: "StyleBox" (ZIndex -2), then "Text", "Input", "Texture", "Icon", "Arrow" and a control's
		parts (ZIndex 0); child controls have ZIndex 1 + z_index (show_behind_parent gives -1).
		Rects come from Layout.Update for the parent's size and are written as pixel offsets. Measuring text yields.

	Layout
		Changes mark the top of the item's tree dirty (Item.MarkDirty). Nodes flushes the dirty roots once per frame,
		and at once when a geometry value is read. Relayout measures the subtree, runs Layout.Update, writes the
		Instances, and emits resized on the controls whose size changed.

	Design Notes
		Instanced scenes are expanded inline: the instance node's properties override the sub-scene root's, and each
		overriding property remembers its own file so its resource ids resolve there (Theme.Context.Files).
		Button draw modes follow Godot's BaseButton: disabled, hover_pressed (when the theme has it), pressed, hover,
		normal; the style box and font color follow the mode. Toggle buttons (CheckButton, or toggle_mode) flip on a
		click; OptionButton opens its popup (UI/Controls/OptionButton).
		mouse_filter STOP and PASS are `Active = true`, IGNORE is `Active = false`: Godot gives a mouse event to the topmost control
		that is not IGNORE (a PASS control then also passes it on to its parents, and the controls behind it never get it), and a
		GuiButton with Active false fires no click at all. Godot class defaults: Label and RichTextLabel IGNORE, containers and
		TextureRect PASS, other controls STOP.
		modulate tints each visual by the product of the modulates up the tree (UI/Item), so fades need no CanvasGroup.
		Panels with the outline, blur or progress shader are drawn by UI/Shaders; other shaders are not (DEVIATION(shader)).
		DEVIATION: TextureRect flips and the KEEP_ASPECT
		top-left alignment (Roblox Fit centers) are not reproduced. Separators draw their line from the "separator"
		style box; VSeparator and HSeparator have no other behavior.
]]

const RunService = game:GetService("RunService")

const Frames = require("./Frames")

const Layout = require("./Layout")
const Scale = require("./Scale")
const Theme = require("./Theme")
const Style = require("./Style")
const Images = require("./Images")
const BBCode = require("./BBCode")
const Shaders = require("./Shaders")
const Input = require("./Input")
const Items = require("./Item")
const NodePath = require("./NodePath")
const TextMetrics = require("./TextMetrics")
const Slider = require("./Controls/Slider")
const CheckButton = require("./Controls/CheckButton")
const OptionButton = require("./Controls/OptionButton")
const LineEdit = require("./Controls/LineEdit")
const Signal = require("../Util/Signal")

export type Item = Items.Item
export type Built = Items.Built

-- A node of a converted scene, or of a tree copied from live items (Duplicate), ready to build.
export type Entry = {
	Path: string,
	Name: string,
	ParentPath: string?,
	Class: string,
	File: Theme.File,
	Files: { [string]: Theme.File },
	Properties: { [string]: unknown },
}

type SceneNode = {
	Name: string,
	Type: string?,
	Path: string,
	Parent: string?,
	Instance: { Ext: string }?,
	Properties: { [string]: unknown },
}

-- Godot's defaults for the class properties UI/Layout reads.
const ClassDefaults = {
	["BoxContainer"] = { ["alignment"] = 0, ["vertical"] = false },
	["HBoxContainer"] = { ["alignment"] = 0, ["vertical"] = false },
	["VBoxContainer"] = { ["alignment"] = 0, ["vertical"] = true },
	["AspectRatioContainer"] = { ["ratio"] = 1, ["stretch_mode"] = 2, ["alignment_horizontal"] = 1, ["alignment_vertical"] = 1 },
	["GridContainer"] = { ["columns"] = 1 },
	["ScrollContainer"] = { ["horizontal_scroll_mode"] = 1, ["vertical_scroll_mode"] = 1 },
	["CenterContainer"] = { ["use_top_left"] = false },
	["TextureRect"] = { ["expand_mode"] = 0 },
}

-- Spatial classes (Node3D and its kin, and SubViewports that only feed 3D surfaces) are not drawn as controls.
const function IsSpatial(Class: string): boolean
	return string.sub(Class, -2) == "3D" or Class == "SubViewport"
end

-- Collect: flattens a scene and the scenes it instances into entries in tree order. Spatial nodes are left out with their
-- subtrees (Skipped records them by path), except Keep, a spatial node whose subtree is built on its own (BuildSubtree).
const function Collect(File: Theme.File, Prefix: string, InstanceParent: string?, RootName: string?, RootOverrides: Entry?, Entries: { Entry }, ByPath: { [string]: Entry }, Keep: string?, Skipped: { [string]: boolean })
	for _, Raw in (File.Nodes or {}) :: { unknown } do
		const Node = Raw :: SceneNode
		const Path = NodePath.Join(Prefix, Node.Path)
		const ParentPath = if Node.Path == "." then InstanceParent elseif Node.Parent then NodePath.Join(Prefix, Node.Parent) else nil

		if Path ~= Keep and ((Node.Type ~= nil and IsSpatial(Node.Type)) or (ParentPath ~= nil and Skipped[ParentPath])) then
			Skipped[Path] = true

			continue
		end

		if Node.Instance then
			const External = File.External[Node.Instance.Ext]
			const Sub = if External then Items.SceneIndex[External.Path] else nil

			if not Sub then
				warn(`Aimia UI: instanced scene for {Path} is not converted`)
				continue
			end

			const Overrides = {
				Path = Path,
				Name = Node.Name,
				ParentPath = ParentPath,
				Class = "",
				File = File,
				Files = {},
				Properties = Node.Properties,
			} :: Entry

			Collect(Sub, Path, ParentPath, Node.Name, Overrides, Entries, ByPath, Keep, Skipped)
		elseif Node.Type == nil then
			const Existing = ByPath[Path]

			if Existing then
				for Key, Value in Node.Properties do
					Existing.Properties[Key] = Value
					Existing.Files[Key] = File
				end
			end
		else
			const Properties = table.clone(Node.Properties)
			const Files: { [string]: Theme.File } = {}

			if Node.Path == "." and RootOverrides then
				for Key, Value in RootOverrides.Properties do
					Properties[Key] = Value
					Files[Key] = RootOverrides.File
				end
			end

			const Entry = {
				Path = Path,
				Name = if Node.Path == "." and RootName then RootName else Node.Name,
				ParentPath = ParentPath,
				Class = Node.Type,
				File = File,
				Files = Files,
				Properties = Properties,
			} :: Entry

			table.insert(Entries, Entry)
			ByPath[Path] = Entry
		end
	end
end

-- The Instance of a node: a Folder for non-Controls, a TextButton for buttons and sliders, else a Frame or a
-- ScrollingFrame. Its mouse_filter sets Active.
const function NewInstance(Entry: Entry, IsControl: boolean): Instance
	if not IsControl then
		return Instance.new("Folder")
	end

	local Gui: GuiObject

	if Items.IsButton(Entry.Class) or Entry.Class == "HSlider" then
		const Button = Instance.new("TextButton")

		Button.Text = ""
		Button.AutoButtonColor = false
		Gui = Button
	elseif Entry.Class == "ScrollContainer" then
		const Scroll = Instance.new("ScrollingFrame")

		Items.StyleScrollBar(Scroll, Items.Number(Entry.Properties, "vertical_scroll_mode", 1))
		Scroll.CanvasSize = UDim2.new()
		Scroll.ScrollingDirection = if Items.Number(Entry.Properties, "horizontal_scroll_mode", 1) == 0 then Enum.ScrollingDirection.Y else Enum.ScrollingDirection.XY
		Gui = Scroll
	else
		Gui = Instance.new("Frame")
	end

	Gui.BackgroundTransparency = 1
	Gui.BorderSizePixel = 0
	Gui.Visible = Entry.Properties["visible"] ~= false
	Gui.ClipsDescendants = Entry.Properties["clip_contents"] == true or Entry.Class == "ScrollContainer"
	Gui.ZIndex = if Entry.Properties["show_behind_parent"] == true then -1 else 1 + Items.Number(Entry.Properties, "z_index", 0)

	const DefaultFilter = if Entry.Class == "Label" or Entry.Class == "RichTextLabel"
		then 2
		elseif Entry.Class == "TextureRect" or table.find(Theme.TypeChain({ Class = Entry.Class, IsControl = true, File = Entry.File, Files = {}, Properties = {} }), "Container")
		then 1
		else 0

	const Filter = Items.Number(Entry.Properties, "mouse_filter", DefaultFilter)

	Gui.Active = Filter ~= 2 or Entry.Class == "ScrollContainer"

	return Gui
end

const function AddChildFrame(Parent: Instance, Name: string, ZIndex: number): Frame
	const Frame = Instance.new("Frame")

	Frame.Name = Name
	Frame.BackgroundTransparency = 1
	Frame.BorderSizePixel = 0
	Frame.Size = UDim2.fromScale(1, 1)
	Frame.ZIndex = ZIndex
	Frame.Parent = Parent

	return Frame
end

-- Creates the item's drawing Instances (Draw sets their content and colors). Rebuilt when a texture changes.
const function AddVisuals(Item: Item)
	const Class = Item.Class
	const Properties = Item.Context.Properties
	const Gui = Item.Instance
	const IsButton = Items.IsButton(Class)

	if Class == "Panel" or Class == "PanelContainer" or Class == "ScrollContainer" or Class == "ColorRect" or Class == "Label" or Class == "RichTextLabel" or Class == "LineEdit" or Class == "HSlider" or Class == "HSeparator" or Class == "VSeparator" or IsButton then
		const Host = AddChildFrame(Gui, "StyleBox", -2)

		Item.StyleHost = Host
		table.insert(Item.Visuals, Host)
	end

	if Class == "HSlider" then
		Slider.Build(Item)
	elseif Class == "CheckButton" then
		CheckButton.Build(Item)
	elseif IsButton and Class ~= "TextureButton" then
		const IconPath = Items.TexturePath(Item, "icon")

		if IconPath then
			const Icon = Instance.new("ImageLabel")
			const Source = Images.GetSourceSize(IconPath)

			Icon.Name = "Icon"
			Icon.BackgroundTransparency = 1
			Icon.Size = UDim2.fromOffset(Source.X, Source.Y)
			Icon.ScaleType = Enum.ScaleType.Fit
			Icon.ZIndex = 0
			Icon.Parent = Gui
			Item.IconSize = vector.create(Source.X, Source.Y, 0)
			Item.Icon = Icon
			table.insert(Item.Visuals, Icon)
		end

		if Class == "OptionButton" then
			OptionButton.Build(Item)
		end
	end

	if Class == "TextureButton" then
		const Texture = Instance.new("ImageLabel")
		const Mode = Items.Number(Properties, "stretch_mode", 0)

		Texture.Name = "Texture"
		Texture.BackgroundTransparency = 1
		Texture.ZIndex = 0
		Texture.Size = UDim2.fromScale(1, 1)
		Texture.ScaleType = if Mode == 1 then Enum.ScaleType.Tile elseif Mode == 4 or Mode == 5 then Enum.ScaleType.Fit elseif Mode == 6 then Enum.ScaleType.Crop else Enum.ScaleType.Stretch
		Texture.Parent = Gui
		Item.Texture = Texture
		table.insert(Item.Visuals, Texture)
	elseif Class == "Label" or Class == "RichTextLabel" or IsButton then
		const Text = Instance.new("TextLabel")

		Text.Name = "Text"
		Text.BackgroundTransparency = 1
		Text.ZIndex = 0
		Text.Parent = Gui
		Item.Text = Text
		table.insert(Item.Visuals, Text)
	elseif Class == "LineEdit" then
		LineEdit.Build(Item)
	elseif Class == "TextureRect" then
		-- DEVIATION: a clip_children mask (CLIP_CHILDREN_ONLY) is not drawn and does not fade its children; they are clipped to its rect.
		const Masks = Items.Number(Properties, "clip_children", 0) == 1
		const Path = if Masks then nil else Items.TexturePath(Item, "texture")

		if Path then
			const Texture = Instance.new("ImageLabel")
			const Source = Images.GetSourceSize(Path)
			const Mode = Items.Number(Properties, "stretch_mode", 0)

			Texture.Name = "Texture"
			Texture.BackgroundTransparency = 1
			Texture.ZIndex = 0
			Texture.ImageContent = Images.GetContent(Path)
			Texture:SetAttribute("SourceAspect", Source.X / math.max(Source.Y, 1))
			Texture.Size = UDim2.fromScale(1, 1)

			if Mode == 1 then
				Texture.ScaleType = Enum.ScaleType.Tile
				Texture.TileSize = UDim2.fromOffset(Source.X, Source.Y)

				if Shaders.IsScrollingTile(Items.ShaderOf(Item)) then
					-- One tile wider than the rect, slid right by the scroll offset (ConnectItem's PreRender).
					Texture.Size = UDim2.new(1, Source.X, 1, 0)
					Texture:SetAttribute("ScrollWidth", Source.X)
					const Clip = Gui :: GuiObject

					Clip.ClipsDescendants = true
				end
			elseif Mode == 2 then
				Texture.Size = UDim2.fromOffset(Source.X, Source.Y)
			elseif Mode == 3 then
				Texture.Size = UDim2.fromOffset(Source.X, Source.Y)
				Texture.AnchorPoint = Vector2.new(0.5, 0.5)
				Texture.Position = UDim2.fromScale(0.5, 0.5)
			elseif Mode == 4 then
				-- STRETCH_KEEP_ASPECT fits the texture at the top-left (Roblox Fit would center it): PlaceText sizes it.
				Texture.ScaleType = Enum.ScaleType.Stretch
				Texture:SetAttribute("KeepAspect", Source.X / math.max(Source.Y, 1))
			elseif Mode == 5 then
				Texture.ScaleType = Enum.ScaleType.Fit
			elseif Mode == 6 then
				Texture.ScaleType = Enum.ScaleType.Crop
			else
				Texture.ScaleType = Enum.ScaleType.Stretch
			end

			Texture.Parent = Gui
			Item.Texture = Texture
			table.insert(Item.Visuals, Texture)
		elseif not Masks and Properties["texture"] ~= nil then
			warn(`Aimia UI: texture of {Item.Path} is not baked`)
		end
	end
end

-- Places the text (and a button's icon) where Godot draws them, for the control's current size.
const function PlaceText(Item: Item)
	const Size = Item.Node.Size
	const Class = Item.Class
	const Text = Item.Text

	const Texture = Item.Texture
	const Aspect = if Texture and Class == "TextureRect" then Texture:GetAttribute("KeepAspect") else nil

	if Texture and type(Aspect) == "number" then
		-- TextureRect STRETCH_KEEP_ASPECT: the height fills the rect unless the width would overflow it; drawn at 0, 0.
		local Width = Size.y * Aspect
		local Height = Size.y

		if Width > Size.x then
			Width = Size.x
			Height = Width / Aspect
		end

		Texture.Position = UDim2.fromOffset(0, 0)
		Texture.Size = UDim2.fromOffset(Width, Height)
	end

	-- flip_h and flip_v: the texture is drawn mirrored (a negative size flips an ImageLabel and extends it from its position back
	-- toward the origin). A flipped label is placed by hand: Fit does not flip, so the fitted rect is computed (keep aspect: at the
	-- top left, centered: in the middle).
	if Texture and Aspect == nil then
		const FlipH = Item.Context.Properties["flip_h"] == true
		const FlipV = Item.Context.Properties["flip_v"] == true
		const Mode = Items.Number(Item.Context.Properties, "stretch_mode", 0)

		-- A gradient shader's UV spans the drawn texture, so the label is the fitted rect too.
		const Graded = Class == "TextureRect" and Shaders.IsGradient(Items.ShaderOf(Item))

		if (FlipH or FlipV or Graded) and (Class == "TextureButton" or (Class == "TextureRect" and (Mode == 0 or Mode == 5 or Mode == 6))) then
			const SourceAspect = Texture:GetAttribute("SourceAspect")
			local Left = 0
			local Top = 0
			local Width = Size.x
			local Height = Size.y

			if (Mode == 4 or Mode == 5) and type(SourceAspect) == "number" then
				Width = math.min(Size.x, Size.y * SourceAspect)
				Height = Width / SourceAspect

				if Mode == 5 then
					Left = (Size.x - Width) / 2
					Top = (Size.y - Height) / 2
				end
			end

			Texture.AnchorPoint = Vector2.zero

			if Mode ~= 6 then
				Texture.ScaleType = Enum.ScaleType.Stretch
			end

			Texture.Position = UDim2.fromOffset(if FlipH then Left + Width else Left, if FlipV then Top + Height else Top)
			Texture.Size = UDim2.fromOffset(if FlipH then -Width else Width, if FlipV then -Height else Height)
		end
	end

	if Class == "Label" and Text then
		const Placed = TextMetrics.LabelLayout(Items.LabelParamsOf(Item), Size.x, Size.y)

		Text.Position = UDim2.fromOffset(Placed.Text.X, Placed.Text.Y)
		Text.Size = UDim2.fromOffset(Placed.Text.Width, Placed.Text.Height)
		Text.TextXAlignment = Items.HorizontalAlignments[Placed.Align]
		Text.TextYAlignment = Enum.TextYAlignment.Top

		-- LineHeight multiplies the Roblox line, which is TextSize high; Placed.LineHeight is Godot's line.
		const RobloxLine = Items.Measure("W", Items.GetFont(Item), Items.GetFontSize(Item)).y

		Text.LineHeight = if Placed.LineHeight > 0 then (Placed.LineHeight + Placed.LineSpacing) / RobloxLine else 1
	elseif Class == "RichTextLabel" and Text then
		-- The text fills the content rect of the "normal" style box (the margins Godot's RichTextLabel draws inside).
		const Margins = Items.MarginsOf(Items.GetStyle(Item, "normal"))

		Text.Position = UDim2.fromOffset(Margins.Left, Margins.Top)
		Text.Size = UDim2.fromOffset(math.max(0, Size.x - Margins.Left - Margins.Right), math.max(0, Size.y - Margins.Top - Margins.Bottom))
		Text.TextYAlignment = Items.VerticalAlignments[Items.Number(Item.Context.Properties, "vertical_alignment", 0)]
	elseif Items.IsButton(Class) and Class ~= "TextureButton" and Text then
		const Placed = TextMetrics.ButtonLayout(Items.ButtonParamsOf(Item), Size.x, Size.y)

		Item.ButtonTextWidth = Placed.Text.Width
		Text.Position = UDim2.fromOffset(Placed.Text.X, Placed.Text.Y)
		Text.Size = UDim2.fromOffset(Placed.Text.Width, Placed.Text.Height)
		Text.TextXAlignment = Items.HorizontalAlignments[Placed.Align]
		Text.TextYAlignment = Enum.TextYAlignment.Top

		if Item.Icon and Placed.Icon then
			Item.Icon.AnchorPoint = Vector2.zero
			Item.Icon.Position = UDim2.fromOffset(Placed.Icon.X, Placed.Icon.Y)
			Item.Icon.Size = UDim2.fromOffset(Placed.Icon.Width, Placed.Icon.Height)
		end
	end
end

-- The draw mode of a button for its pressed, hovered and disabled state.
const function ButtonMode(Item: Item): string
	if Item.Disabled then
		return "disabled"
	end

	const Pressed = Item.Held or Item.Toggled

	if Pressed and Item.Hovered and Items.GetStyle(Item, "hover_pressed") ~= nil then
		return "hover_pressed"
	elseif Pressed then
		return "pressed"
	elseif Item.Hovered then
		return "hover"
	end

	return "normal"
end

-- Text content and text presentation of a Label, RichTextLabel or button, from its properties.
const function StyleText(Item: Item)
	const Text = Item.Text

	if not Text then
		return
	end

	const Properties = Item.Context.Properties
	const Class = Item.Class

	Text.TextWrapped = Items.Number(Properties, "autowrap_mode", 0) ~= 0 or Class == "RichTextLabel"
	Text.TextTruncate = if Items.Number(Properties, "text_overrun_behavior", 0) ~= 0 then Enum.TextTruncate.AtEnd else Enum.TextTruncate.None
	Text.ClipsDescendants = Properties["clip_text"] == true

	if Class == "RichTextLabel" then
		const Rich, Alignment = BBCode.ToRichText(Items.DisplayText(Item), Items.TextSizeOf(Items.GetFont(Item), 1))

		Text.RichText = true
		Text.Text = Rich
		-- The label's horizontal_alignment, unless the text sets its own with a [center] or [right] tag.
		Text.TextXAlignment = if Alignment == "center" then Enum.TextXAlignment.Center elseif Alignment == "right" then Enum.TextXAlignment.Right else Items.HorizontalAlignments[Items.Number(Properties, "horizontal_alignment", 0)]
		Text.TextYAlignment = Enum.TextYAlignment.Top
	elseif Class == "Label" then
		Text.Text = Items.DisplayText(Item)
		Text.TextXAlignment = Items.HorizontalAlignments[Items.Number(Properties, "horizontal_alignment", 0)]
		Text.TextYAlignment = Items.VerticalAlignments[Items.Number(Properties, "vertical_alignment", 0)]
	else
		Text.Text = TextMetrics.TrimFinalBreak(Items.DisplayText(Item))
		Text.TextXAlignment = Items.HorizontalAlignments[Items.Number(Properties, "alignment", 1)]
		Text.TextYAlignment = Enum.TextYAlignment.Center
	end
end

-- Draws the control's own visuals for its current state, then places and tints them.
const function Draw(Item: Item)
	const Properties = Item.Context.Properties
	const Class = Item.Class
	const Own = Items.OwnModulate(Item)
	const Host = Item.StyleHost
	local DrawnBySize = false

	if Host then
		if Class == "ColorRect" then
			Shaders.Release(Host)
			Shaders.ApplyGradient(Host, Items.ShaderOf(Item))
			Style.DrawStyleBox(Host, nil, nil)

			const Color, Transparency = Style.ToColor(Properties["color"] or { Color = Items.White }, Own)

			Host.BackgroundColor3 = Color
			Host.BackgroundTransparency = Transparency
		else
			Item.StyleSize = Item.Node.Size
			DrawnBySize = Shaders.Draw(Host, Item.Instance :: GuiObject, Item.Scene.Viewport, Items.ShaderOf(Item), Items.StyleFor(Item), Own, Item.Node.Size.x, Item.Node.Size.y)
		end
	end

	const Text = Item.Text

	if Text then
		const Settings = Items.LabelSettings(Item)
		local Components = Items.GetColor(Item, if Items.IsButton(Class) then (Items.ModeColors :: { [string]: string })[Item.Mode] else "default_color")

		if Class == "Label" then
			Components = Items.GetColor(Item, "font_color")
		end

		if Settings and Settings.Properties["font_color"] ~= nil then
			Components = Items.ColorComponents(Settings.Properties["font_color"])
		end

		const Color, Transparency = Style.ToColor({ Color = Components }, Own)

		StyleText(Item)
		Text.TextColor3 = Color
		Text.TextTransparency = Transparency
		Text.FontFace = Items.GetFont(Item)
		Text.TextSize = Items.TextSizeOf(Items.GetFont(Item), Items.GetFontSize(Item))

		const OutlineSize = if Settings and type(Settings.Properties["outline_size"]) == "number"
			then Settings.Properties["outline_size"] :: number
			else Items.GetConstant(Item, "outline_size", 0)
		-- (the label's own outline: an "InkEdge" stroke is the HUD's, UI/Game/UIComponent.InkText, and is left alone)
		local Stroke: UIStroke? = nil

		for _, Child in Text:GetChildren() do
			if Child:IsA("UIStroke") and Child.Name ~= "InkEdge" then
				Stroke = Child

				break
			end
		end

		if OutlineSize > 0 then
			const Outline = if Settings and Settings.Properties["outline_color"] ~= nil
				then Items.ColorComponents(Settings.Properties["outline_color"])
				else Items.GetColor(Item, "font_outline_color")
			const OutlineColor, OutlineTransparency = Style.ToColor({ Color = Outline }, Own)
			const Target = Stroke or Instance.new("UIStroke")

			Target.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
			Target.Thickness = OutlineSize / 2
			Target.Color = OutlineColor
			Target.Transparency = OutlineTransparency
			Target.Parent = Text
		elseif Stroke then
			Stroke:Destroy()
		end
	end

	if Item.Input then
		LineEdit.Draw(Item)
	end

	const Icon = Item.Icon

	if Icon and Class ~= "CheckButton" then
		const IconColor = (Items.ModeIconColors :: { [string]: string })[Item.Mode] or "icon_normal_color"
		const Color, Transparency = Style.ToColor({ Color = Items.GetColor(Item, IconColor) }, Own)

		Icon.ImageColor3 = Color
		Icon.ImageTransparency = Transparency

		const IconPath = Items.TexturePath(Item, "icon")

		if IconPath then
			Icon.ImageContent = Images.GetContent(IconPath)
		end
	end

	const Texture = Item.Texture

	if Texture then
		const Color, Transparency = Style.ToColor({ Color = Items.White }, Own)

		Texture.ImageColor3 = Color
		Texture.ImageTransparency = Transparency

		if Class == "TextureRect" then
			Shaders.ApplyGradient(Texture, Items.ShaderOf(Item))
		end

		if Class == "TextureButton" then
			-- TextureButton::_notification(DRAW): the mode's texture when it has one, else texture_normal.
			const Key = if Item.Mode == "disabled" then "texture_disabled"
				elseif Item.Mode == "pressed" or Item.Mode == "hover_pressed" then "texture_pressed"
				elseif Item.Mode == "hover" then "texture_hover"
				else "texture_normal"
			const Path = Items.TexturePath(Item, Key) or Items.TexturePath(Item, "texture_normal")

			Texture.Visible = Path ~= nil

			if Path then
				const Source = Images.GetSourceSize(Path)

				Texture.ImageContent = Images.GetContent(Path)
				Texture:SetAttribute("SourceAspect", Source.X / math.max(Source.Y, 1))
			end
		end
	end

	PlaceText(Item)

	if Class == "HSlider" then
		Slider.Draw(Item)
	elseif Class == "CheckButton" then
		CheckButton.Draw(Item)
	elseif Class == "OptionButton" then
		OptionButton.Draw(Item)
	end

	Item.SizeDrawn = DrawnBySize or Class == "HSlider" or Class == "OptionButton" or Class == "LineEdit"
	Items.CollectTints(Item)
	Items.TintItem(Item, Items.Inherited(Item))
end

-- Redraws an item and queues its layout (its text or style may change its minimum size).
const function Refresh(Item: Item)
	Draw(Item)
	Items.MarkDirty(Item)
end

-- A scrolling tile slides one tile to the right per second (background_tile's UV.x -= TIME), on the frame clock (UI/Frames)
-- so it steps evenly.
const function ConnectScrollingTile(Item: Item)
	-- (one handler per tile: RebuildVisuals connects it again, and the slide carries on from the tile's first start)
	const Holder = Item :: any
	const Started = Holder.TileStarted or Frames.Time

	Holder.TileStarted = Started

	if Holder.TileConnection then
		Holder.TileConnection:Disconnect()
	end

	Holder.TileConnection = RunService.PreRender:Connect(function()
		const Texture = Item.Texture

		if not Texture or Frames.Paused then
			return
		end

		const Width = Texture:GetAttribute("ScrollWidth")

		if type(Width) ~= "number" then
			return
		end

		Texture.Position = UDim2.fromOffset((((Frames.Time - Started) % 1) - 1) * Width, 0)
	end)

	table.insert(Item.Connections, Holder.TileConnection)
end

-- Destroys the item's drawing Instances and creates them again (texture, icon and mode changes), then redraws.
const function RebuildVisuals(Item: Item)
	if Item.StyleHost then
		Shaders.Release(Item.StyleHost)
	end

	for _, Visual in Item.Visuals do
		Visual:Destroy()
	end

	table.clear(Item.Visuals)
	Item.StyleHost = nil
	Item.Text = nil
	Item.Input = nil
	Item.Texture = nil
	Item.Icon = nil
	Item.Arrow = nil
	Item.GrabberArea = nil
	Item.Grabber = nil
	table.clear(Item.Ticks)
	Item.IconSize = nil

	AddVisuals(Item)
	Draw(Item)

	if Item.Texture and Item.Texture:GetAttribute("ScrollWidth") then
		ConnectScrollingTile(Item)
	end

	Items.MarkDirty(Item)
end

-- The class's own minimum size (Godot get_minimum_size of the leaf classes), in pixels.
const function ContentMinimumSize(Item: Item): vector
	const Properties = Item.Context.Properties
	const Class = Item.Class

	if Class == "Label" then
		return TextMetrics.LabelMinimumSize(Items.LabelParamsOf(Item))
	elseif Class == "TextureButton" then
		if Properties["ignore_texture_size"] == true then
			return vector.zero
		end

		-- TextureButton::get_minimum_size: the first of the normal, pressed and hover textures.
		const Path = Items.TexturePath(Item, "texture_normal") or Items.TexturePath(Item, "texture_pressed") or Items.TexturePath(Item, "texture_hover")

		if not Path then
			return vector.zero
		end

		const Source = Images.GetSourceSize(Path)

		return vector.create(Source.X, Source.Y, 0)
	elseif Items.IsButton(Class) then
		return TextMetrics.ButtonMinimumSize(Items.ButtonParamsOf(Item))
	elseif Class == "LineEdit" then
		return TextMetrics.LineEditMinimumSize(Items.LineEditParamsOf(Item))
	elseif Class == "HSlider" then
		return Slider.MinimumSize(Item)
	elseif Class == "HSeparator" or Class == "VSeparator" then
		-- StyleBoxLine minimum: the line's thickness across its axis, plus the content margins.
		const Box = Items.StyleFor(Item)
		const Thickness = if Box then Items.Number(Box.Properties, "thickness", 1) else 0
		const Left = if Box then Items.Number(Box.Properties, "content_margin_left", 0) else 0
		const Top = if Box then Items.Number(Box.Properties, "content_margin_top", 0) else 0
		const Right = if Box then Items.Number(Box.Properties, "content_margin_right", 0) else 0
		const Bottom = if Box then Items.Number(Box.Properties, "content_margin_bottom", 0) else 0

		if Class == "VSeparator" then
			return vector.create(Left + Right + Thickness, Top + Bottom, 0)
		end

		return vector.create(Left + Right, Top + Bottom + Thickness, 0)
	elseif Class == "TextureRect" then
		const Path = Items.TexturePath(Item, "texture")

		if not Path then
			return vector.zero
		end

		const Source = Images.GetSourceSize(Path)
		const Mode = Items.Number(Properties, "expand_mode", 0)
		const Current = Item.Node.Size

		if Mode == 0 then
			return vector.create(Source.X, Source.Y, 0)
		elseif Mode == 2 or Mode == 3 then
			return vector.create(Current.y * Source.X / Source.Y, 0, 0)
		elseif Mode == 4 or Mode == 5 then
			return vector.create(0, Current.x * Source.Y / Source.X, 0)
		end

		return vector.zero
	elseif Class == "RichTextLabel" and Properties["fit_content"] == true then
		const Height = TextMetrics.RichTextFitHeight({
			Measure = Items.MeasurerFor(Item),
			Text = BBCode.StripTags(Items.DisplayText(Item)),
			FontSize = Items.GetFontSize(Item),
			Margins = Items.MarginsOf(Items.StyleFor(Item)),
		}, Item.Node.Size.x)

		return vector.create(0, Height, 0)
	end

	return vector.zero
end

-- Writes every resolved property of the item into its layout Node (build time, and when a node's class changes).
const function FillNode(Item: Item)
	const Node = Item.Node
	const Properties = Item.Context.Properties
	const Class = Item.Class

	Node.Visible = Properties["visible"] ~= false
	Node.TopLevel = Properties["top_level"] == true
	Node.LayoutMode = Items.Number(Properties, "layout_mode", 0)
	Node.Anchors = {
		Items.Number(Properties, "anchor_left", 0),
		Items.Number(Properties, "anchor_top", 0),
		Items.Number(Properties, "anchor_right", 0),
		Items.Number(Properties, "anchor_bottom", 0),
	}
	Node.Offsets = {
		Items.Number(Properties, "offset_left", 0),
		Items.Number(Properties, "offset_top", 0),
		Items.Number(Properties, "offset_right", 0),
		Items.Number(Properties, "offset_bottom", 0),
	}
	Node.GrowHorizontal = Items.Number(Properties, "grow_horizontal", 1)
	Node.GrowVertical = Items.Number(Properties, "grow_vertical", 1)
	Node.CustomMinimumSize = Items.VectorOf(Properties["custom_minimum_size"])
	Node.SizeFlagsHorizontal = Items.Number(Properties, "size_flags_horizontal", 1)
	Node.SizeFlagsVertical = Items.Number(Properties, "size_flags_vertical", 1)
	Node.StretchRatio = Items.Number(Properties, "size_flags_stretch_ratio", 1)
	Node.IsControl = Item.IsControl

	-- The class properties Layout reads, with Godot's defaults where the scene leaves them out.
	const Resolved = table.clone(Properties)

	for Key, Default in ((ClassDefaults :: { [string]: { [string]: unknown } })[Class] or {}) do
		if Resolved[Key] == nil then
			Resolved[Key] = Default
		end
	end

	Node.Properties = Resolved

	const Chain = Theme.TypeChain(Item.Context)

	if table.find(Chain, "BoxContainer") then
		Node.Constants["separation"] = Items.GetConstant(Item, "separation", 4)
	elseif Class == "MarginContainer" then
		for _, Side in { "left", "top", "right", "bottom" } do
			Node.Constants[`margin_{Side}`] = Items.GetConstant(Item, `margin_{Side}`, 0)
		end
	elseif Class == "GridContainer" or table.find(Chain, "FlowContainer") then
		Node.Constants["h_separation"] = Items.GetConstant(Item, "h_separation", 4)
		Node.Constants["v_separation"] = Items.GetConstant(Item, "v_separation", 4)
	elseif Class == "PanelContainer" or Class == "ScrollContainer" then
		const Box = Items.GetStyle(Item, "panel")

		for _, Side in { "left", "top", "right", "bottom" } do
			Resolved[`content_margin_{Side}`] = Style.GetMargin(Box, Side)
		end

		Node.StyleMinimumSize = Style.GetMinimumSize(Box)
	end
end

-- Appends the items of a subtree to List, in tree order.
const function Gather(Item: Item, List: { Item })
	table.insert(List, Item)

	for _, Child in Item.Children do
		Gather(Child, List)
	end
end

-- Writes the geometry and draw of one control (ApplyItem without its subtree); collects it if its size changed.
const function ApplyOne(Item: Item, Resized: { Item })
	const Gui = Item.Instance

	if Item.IsControl and Gui:IsA("GuiObject") then
		const Node = Item.Node
		const Pivot = Item.Pivot


		if Pivot.x ~= 0 or Pivot.y ~= 0 then
			Gui.AnchorPoint = Vector2.new(if Node.Size.x > 0 then Pivot.x / Node.Size.x else 0, if Node.Size.y > 0 then Pivot.y / Node.Size.y else 0)
		else
			Gui.AnchorPoint = Vector2.zero
		end

		Gui.Position = UDim2.fromOffset(Node.Position.x + Pivot.x, Node.Position.y + Pivot.y)

		if Item.SizeDrawn and Item.StyleSize ~= Node.Size then
			Draw(Item)
		else
			PlaceText(Item)
		end

		Gui.Size = UDim2.fromOffset(Node.Size.x, Node.Size.y)

		if Gui:IsA("ScrollingFrame") then
			local Extent = vector.zero

			for _, Child in Item.Children do
				if Child.IsControl and Child.Node.Visible then
					Extent = vector.max(Extent, Child.Node.Position + Child.Node.Size)
				end
			end

			Gui.CanvasSize = UDim2.fromOffset(if Extent.x > Node.Size.x then Extent.x else 0, if Extent.y > Node.Size.y then Extent.y else 0)
		end

		if Node.Size ~= Item.LastSize then
			Item.LastSize = Node.Size
			table.insert(Resized, Item)
		end
	end
end

-- Writes the geometry and draws of a subtree; collects the controls whose size changed (resized is emitted after).
const function ApplyItem(Item: Item, Resized: { Item })
	if Item.Freed then
		return
	end

	ApplyOne(Item, Resized)

	for _, Child in Item.Children do
		ApplyItem(Child, Resized)
	end
end

-- Whether Child is a SlideOnly control (a row of the play list) under a parent that is not a container: its parent's layout
-- does not follow it, so it is laid out alone (Items.MarkDirty, RelayoutLocal).
const function SlidesAlone(Parent: Item, Child: Item): boolean
	const Held: any = Child

	return Held.SlideOnly == true and not string.find(Parent.Class, "Container", 1, true)
end

-- How many times a SlideOnly control was laid out alone (RelayoutLocal): Relayout sees whether one ran while it measured.
local LocalRuns = 0

-- Lays out the tree under Root: measures the minimum sizes, runs Layout.Update (twice when a minimum depends on the
-- laid-out size), writes the Instances, and emits resized. Yields while measuring text; a newer run supersedes it: the newer run
-- writes the Instances, and this one only lays the nodes out with the sizes they hold, so that its caller (which read or set
-- a geometry value and waited for this) never continues with the sizes of an earlier layout.
const function Relayout(Root: Item)
	Root.Generation += 1

	const LocalRunsAtStart = LocalRuns

	const Generation = Root.Generation
	const Subtree: { Item } = {}

	Gather(Root, Subtree)

	const Minimums: { vector } = {}

	for Index, Item in Subtree do
		Minimums[Index] = if Item.IsControl then ContentMinimumSize(Item) else vector.zero
	end

	-- A root that was attached while it measured is laid out as part of its new tree (a scene built and added at once): laying it out
	-- here as a root would size it to the viewport.
	if Root.Freed or Root.Parent ~= nil then
		return
	end

	if Root.Generation ~= Generation then
		Layout.Update(Root.Node, Scale.SizeOfViewport(Root.Scene.Viewport))

		return
	end

	for Index, Item in Subtree do
		Item.Node.ContentMinimumSize = Minimums[Index]
	end

	const Viewport = Scale.SizeOfViewport(Root.Scene.Viewport)

	Layout.Update(Root.Node, Viewport)


	-- Minimum sizes that depend on the laid-out size (TextureRect fit modes, RichTextLabel fit_content).
	local Changed = false

	for _, Item in Subtree do
		if Item.Class == "TextureRect" or Item.Class == "RichTextLabel" then
			const Dependent = ContentMinimumSize(Item)

			if Dependent ~= Item.Node.ContentMinimumSize then
				Item.Node.ContentMinimumSize = Dependent
				Changed = true
			end
		end
	end

	if Root.Freed or Root.Parent ~= nil then
		return
	end

	if Root.Generation ~= Generation then
		Layout.Update(Root.Node, Viewport)

		return
	end

	if Changed then
		Layout.Update(Root.Node, Viewport)
	end

	const Resized: { Item } = {}

	ApplyItem(Root, Resized)

	for _, Item in Resized do
		Items.Emit(Item, "resized")
	end

	-- (a row laid out alone while this run measured may have changed after this run measured it: it is laid out again)
	if LocalRuns ~= LocalRunsAtStart then
		for _, Item in Subtree do
			const Parent = Item.Parent

			if Parent and not Item.Freed and SlidesAlone(Parent, Item) then
				Items.MarkDirty(Item)
			end
		end
	end
end

-- Lays out a SlideOnly control (a row of the play list) and its subtree in place, measuring them: what a change under it
-- needs, as its parent is not a container and does not follow it (Items.MarkDirty). Relayout's steps, on that subtree.
const function RelayoutLocal(Root: Item)
	if Root.Freed or not Root.Parent then
		return
	end

	LocalRuns += 1

	const Held: any = Root

	Held.LocalGeneration = (Held.LocalGeneration or 0) + 1

	const Generation = Held.LocalGeneration
	const Subtree: { Item } = {}

	Gather(Root, Subtree)

	const Minimums: { vector } = {}

	for Index, Item in Subtree do
		Minimums[Index] = if Item.IsControl then ContentMinimumSize(Item) else vector.zero
	end

	-- (taken out of the list while it measured: it is laid out again when it is added back)
	if Root.Freed or not Root.Parent then
		return
	end

	const Viewport = Scale.SizeOfViewport(Items.TopOf(Root).Scene.Viewport)

	if Held.LocalGeneration ~= Generation then
		Layout.UpdateSubtree(Root.Node, Viewport)

		return
	end

	for Index, Item in Subtree do
		Item.Node.ContentMinimumSize = Minimums[Index]
	end

	Layout.UpdateSubtree(Root.Node, Viewport)

	-- Minimum sizes that depend on the laid-out size (TextureRect fit modes, RichTextLabel fit_content).
	local Changed = false

	for _, Item in Subtree do
		if Item.Class == "TextureRect" or Item.Class == "RichTextLabel" then
			const Dependent = ContentMinimumSize(Item)

			if Dependent ~= Item.Node.ContentMinimumSize then
				Item.Node.ContentMinimumSize = Dependent
				Changed = true
			end
		end
	end

	if Root.Freed or not Root.Parent then
		return
	end

	if Held.LocalGeneration ~= Generation then
		Layout.UpdateSubtree(Root.Node, Viewport)

		return
	end

	if Changed then
		Layout.UpdateSubtree(Root.Node, Viewport)
	end

	const Resized: { Item } = {}

	ApplyItem(Root, Resized)

	-- (its layout is written: a move may slide it alone again, RelayoutMoved. Only the newest run, with no change queued
	-- since, says so: writing can wait on text too)
	if Held.LocalGeneration == Generation and not Held.DirtyLocal then
		Held.LocalPending = nil
	end

	for _, Item in Resized do
		Items.Emit(Item, "resized")
	end
end

-- Lays out a control that moved by its own offsets and its subtree, and writes their rects (no measuring: a move does
-- not change minimum sizes).
const function RelayoutMoved(Item: Item)
	if Item.Freed then
		return
	end


	const Top = Items.TopOf(Item)
	const Viewport = Scale.SizeOfViewport(Top.Scene.Viewport)
	const Resized: { Item } = {}
	const Moved = Item :: any
	const Resizing = Moved.ResizedPending == true

	Moved.ResizedPending = nil

	-- (A control marked SlideOnly, the play list's rows, which move every frame while the list scrolls: when it only slid,
	-- its size the same and no minimum size changed under it, its subtree keeps its layout, as children sit relative to
	-- it. Only its own rect is laid out and written; laying out and writing its whole row of buttons every frame was most
	-- of the cost of scrolling the grid.)
	if Moved.SlideOnly and not Resizing and not Moved.LocalPending then
		const Before = Item.Node.Size

		Layout.UpdateRect(Item.Node, Viewport)

		if Item.Node.Size == Before then
			ApplyOne(Item, Resized)

			return
		end
	end

	Layout.UpdateSubtree(Item.Node, Viewport)

	ApplyItem(Item, Resized)

	for _, Changed in Resized do
		Items.Emit(Changed, "resized")
	end

end

-- Button presses: hover and held drive the draw mode; a click toggles toggle buttons, opens an OptionButton's popup,
-- and emits pressed (after toggled).
const function IsToggle(Item: Item): boolean
	return Item.Class == "CheckButton" or Item.Class == "CheckBox" or Item.Context.Properties["toggle_mode"] == true
end

-- Buttons that are hovered or held. GuiObject.MouseEnter is not sunk by an Active object over it (only the input
-- events are), so a modal blocks hover and press through Input.Blocked, and ReleasePointers resets the buttons under it.
const Pointed: { [Item]: boolean } = {}

-- Buttons a modal took the hover from; they get it back once the modal no longer covers them (ReleasePointers).
const Suspended: { [Item]: boolean } = {}

const function ConnectButton(Item: Item)
	const Button = Item.Instance :: TextButton

	const function UpdateMode()
		const Mode = ButtonMode(Item)

		if Mode ~= Item.Mode then
			Item.Mode = Mode
			Draw(Item)
		end
	end

	table.insert(Item.Connections, Button.MouseEnter:Connect(function()
		if Input.Blocked(Button) then
			-- (a pointer-only layer over it, the owner panel: the engine can send this just before that layer lets the pointer
			-- go, and ReleasePointers then gives the hover back while the pointer is still on this button)
			if Input.PointerTaken(Button) then
				Suspended[Item] = true
			end

			return
		end

		Item.Hovered = true
		Pointed[Item] = true
		UpdateMode()
		Items.Emit(Item, "mouse_entered")
	end))
	table.insert(Item.Connections, Button.MouseLeave:Connect(function()
		Item.Hovered = false
		Item.Held = false
		Pointed[Item] = nil
		UpdateMode()
		Items.Emit(Item, "mouse_exited")
	end))
	table.insert(Item.Connections, Button.MouseButton1Down:Connect(function()
		if Input.Blocked(Button) then
			return
		end

		Item.Held = true
		Pointed[Item] = true
		UpdateMode()
		Items.Emit(Item, "button_down")
	end))
	table.insert(Item.Connections, Button.MouseButton1Up:Connect(function()
		Item.Held = false

		if not Item.Hovered then
			Pointed[Item] = nil
		end

		UpdateMode()
		Items.Emit(Item, "button_up")
	end))
	table.insert(Item.Connections, Button.Activated:Connect(function()
		if Item.Disabled or Input.Blocked(Button) then
			return
		end

		if Item.Class == "OptionButton" then
			OptionButton.Toggle(Item, Refresh)
		elseif IsToggle(Item) then
			Item.Toggled = not Item.Toggled
			-- (the stored value follows, as SetProperty keeps it: Nodes.Set skips a value equal to the stored one, so a click that
			-- left it behind made code that sets the button back do nothing, e.g. the sort panel stayed open on an outside click)
			Item.Context.Properties["button_pressed"] = Item.Toggled
			UpdateMode()
			Draw(Item)
			Items.Emit(Item, "toggled", Item.Toggled)
		end

		Items.Emit(Item, "pressed")
	end))
end

-- Input.ModalChanged: a button a modal now covers loses its hover and press (as a pointer that leaves it does), and a
-- button it covered gets its hover back when the pointer is still over it. GuiObject.MouseEnter is geometric, so the
-- engine sends no MouseEnter for a pointer that is already over a button once the modal is gone.
const function ReleasePointers()
	const Covered: { Item } = {}
	const Returning: { Item } = {}

	for Item in Pointed do
		table.insert(Covered, Item)
	end

	for Item in Suspended do
		table.insert(Returning, Item)
	end

	for _, Item in Covered do
		if Item.Freed then
			Pointed[Item] = nil
		elseif Input.Blocked(Item.Instance :: GuiObject) then
			const WasHovered = Item.Hovered

			Pointed[Item] = nil

			Item.Hovered = false
			Item.Held = false
			Suspended[Item] = true

			const Mode = ButtonMode(Item)

			if Mode ~= Item.Mode then
				Item.Mode = Mode
				Draw(Item)
			end

			if WasHovered then
				Items.Emit(Item, "mouse_exited")
			end
		end
	end

	for _, Item in Returning do
		Suspended[Item] = nil

		if not Item.Freed and not Input.Blocked(Item.Instance :: GuiObject) and Input.PointerOver(Item.Instance :: GuiObject) then
			Item.Hovered = true
			Pointed[Item] = true

			const Mode = ButtonMode(Item)

			if Mode ~= Item.Mode then
				Item.Mode = Mode
				Draw(Item)
			end

			Items.Emit(Item, "mouse_entered")
		end
	end
end

Signal.Connect(Input.ModalChanged, ReleasePointers)

const function ConnectItem(Item: Item)
	if Items.IsButton(Item.Class) then
		ConnectButton(Item)
	elseif Item.Class == "HSlider" then
		Slider.Connect(Item)
	end

	if Item.Texture and Item.Texture:GetAttribute("ScrollWidth") then
		ConnectScrollingTile(Item)
	end
end

-- Attaches a built item (or an unparented one) under Parent at Index (1-based; the end when nil). The Instance
-- parenting is the caller's.
const function Attach(Parent: Item, Child: Item, Index: number?)
	Child.Parent = Parent
	Child.Context.Parent = Parent.Context
	Child.Node.Parent = Parent.Node

	if Index then
		table.insert(Parent.Children, Index, Child)
		table.insert(Parent.Node.Children, Index, Child.Node)
	else
		table.insert(Parent.Children, Child)
		table.insert(Parent.Node.Children, Child.Node)
	end

	Child.Instance.Parent = Parent.Instance

	-- (a SlideOnly control, a row of the play list, added under a parent that is not a container leaves that parent's
	-- layout as it is: only the row is laid out, Items.MarkDirty)
	if SlidesAlone(Parent, Child) then
		Items.MarkDirty(Child)
	else
		Items.MarkDirty(Parent)
	end

	const Modulate = Child.Modulate

	Items.SetModulate(Child, Modulate[1], Modulate[2], Modulate[3], Modulate[4])
end

-- Detaches an item from its parent (its Instance leaves the tree; it stays alive).
const function Detach(Child: Item)
	const Parent = Child.Parent

	if not Parent then
		return
	end

	if not SlidesAlone(Parent, Child) then
		Items.MarkDirty(Parent)
	end

	table.remove(Parent.Children, table.find(Parent.Children, Child) :: number)
	table.remove(Parent.Node.Children, table.find(Parent.Node.Children, Child.Node) :: number)
	Child.Parent = nil
	Child.Context.Parent = nil
	Child.Node.Parent = nil
	Child.Instance.Parent = nil

	const Modulate = Child.Modulate

	Items.SetModulate(Child, Modulate[1], Modulate[2], Modulate[3], Modulate[4])
	Items.MarkDirty(Child)
end

-- Moves an attached item to Index (1-based) among its siblings, re-parenting the siblings from there on so the
-- Instance order follows.
const function Reorder(Child: Item, Index: number)
	const Parent = Child.Parent

	if not Parent then
		return
	end

	const Current = table.find(Parent.Children, Child) :: number

	table.remove(Parent.Children, Current)
	table.remove(Parent.Node.Children, Current)

	const Position = math.clamp(Index, 1, #Parent.Children + 1)

	table.insert(Parent.Children, Position, Child)
	table.insert(Parent.Node.Children, Position, Child.Node)

	for Sibling = Position, #Parent.Children do
		const Other = Parent.Children[Sibling]

		Other.Instance.Parent = nil
		Other.Instance.Parent = Parent.Instance
	end

	Items.MarkDirty(Parent)
end

-- Frees an item's subtree bookkeeping: disconnects its signals, process callbacks and tweens, and drops it from its
-- Built's map.
const function FreeNodes(Item: Item)
	for _, Child in Item.Children do
		FreeNodes(Child)
	end

	if Item.StyleHost then
		Shaders.Release(Item.StyleHost)
	end

	Item.Freed = true
	Pointed[Item] = nil
	Suspended[Item] = nil

	for _, Connection in Item.Connections do
		Connection:Disconnect()
	end

	table.clear(Item.Connections)

	if Item.Class == "OptionButton" then
		OptionButton.Close(Item)
	end

	for _, Cleanup in Item.Cleanup do
		Cleanup()
	end

	table.clear(Item.Cleanup)
	table.clear(Item.Signals)

	if Item.Scene.Items[Item.Path] == Item then
		Item.Scene.Items[Item.Path] = nil
	end
end

-- Frees an item and its subtree: removes it from the tree and destroys its Instance (its children's go with it).
const function FreeTree(Item: Item)
	Detach(Item)
	FreeNodes(Item)
	Item.Instance:Destroy()
end

-- Creates the items of the entries (in order, parents first) under Parent (nil: unparented), and lays them out.
-- Yields while text is measured.
const function BuildTree(Entries: { Entry }, Viewport: GuiBase2d, Parent: GuiBase2d?): Built
	const Scene = {
		Root = nil,
		Items = {},
		Order = {},
		Viewport = Viewport,
	} :: Built

	for _, Entry in Entries do
		const ParentItem = if Entry.ParentPath then Scene.Items[Entry.ParentPath] else nil
		const IsControl = Theme.IsControlClass(Entry.Class)
		const Gui = NewInstance(Entry, IsControl)
		const Context = {
			Class = Entry.Class,
			IsControl = IsControl,
			File = Entry.File,
			Files = Entry.Files,
			Properties = Entry.Properties,
			Parent = if ParentItem then ParentItem.Context else nil,
		} :: Theme.Context
		const Item = {
			Path = Entry.Path,
			Name = Entry.Name,
			Class = Entry.Class,
			IsControl = IsControl,
			Instance = Gui,
			Context = Context,
			Node = Layout.NewNode(Entry.Class),
			Children = {},
			Parent = nil,
			Scene = Scene,
			Freed = false,
			Dirty = false,
			Generation = 0,
			Mode = "normal",
			Hovered = false,
			Held = false,
			Toggled = Entry.Properties["button_pressed"] == true,
			Disabled = Entry.Properties["disabled"] == true,
			Modulate = table.clone(Items.ColorComponents(Entry.Properties["modulate"])),
			Visuals = {},
			TintTargets = {},
			TintColors = {},
			TintTransparencies = {},
			Ticks = {},
			SizeDrawn = false,
			StyleSize = vector.zero,
			LastSize = vector.zero,
			Pivot = vector.zero,
			Scale = 1,
			Rotation = 0,
			Items = {},
			Selected = -1,
			Signals = {},
			Connections = {},
			Cleanup = {},
		} :: Item

		Gui.Name = Entry.Name
		FillNode(Item)
		AddVisuals(Item)
		Item.Mode = if Items.IsButton(Item.Class) then ButtonMode(Item) else "normal"
		Draw(Item)

		if ParentItem then
			Attach(ParentItem, Item)
		else
			Gui.Parent = Parent

			if not Scene.Root then
				Scene.Root = Item
			end
		end

		Scene.Items[Entry.Path] = Item
		table.insert(Scene.Order, Item)
	end

	for _, Item in Scene.Order do
		ConnectItem(Item)
	end

	if Scene.Root then
		Relayout(Scene.Root)
	end

	return Scene
end

-- Builds the scene at a res:// path under Parent (a ScreenGui or a GuiObject). Yields.
const function Build(Path: string, Parent: GuiBase2d): Built
	const File = Items.SceneIndex[Path]

	if not File then
		error(`Aimia UI: no converted scene {Path}`, 2)
	end

	const Entries: { Entry } = {}
	const ByPath: { [string]: Entry } = {}

	Collect(File, ".", nil, nil, nil, Entries, ByPath, nil, {})

	const Scene = BuildTree(Entries, Parent, Parent)
	const Root = Scene.Root

	-- A window resize lays the scene out again, as Godot's root control follows its viewport.
	if Root then
		table.insert(Root.Connections, Parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			Items.MarkDirty(Root)
		end))

		-- So does a new scale (the root keeps the screen's size, so its AbsoluteSize doesn't change).
		const function OnScale()
			Items.MarkDirty(Root)
		end

		Signal.Connect(Scale.Changed, OnScale)
		table.insert(Root.Cleanup, function()
			Signal.Disconnect(Scale.Changed, OnScale)
		end)
	end

	return Scene
end

-- Builds the subtree at Under (a node path of a converted scene, a spatial node kept as its root) under Parent, laid out
-- in Viewport. Its root is a Folder when it is a SubViewport, so its controls anchor to the viewport. Yields.
const function BuildSubtree(Path: string, Under: string, Viewport: GuiBase2d, Parent: GuiBase2d): Built
	const File = Items.SceneIndex[Path]

	if not File then
		error(`Aimia UI: no converted scene {Path}`, 2)
	end

	const Entries: { Entry } = {}
	const ByPath: { [string]: Entry } = {}
	const Subtree: { Entry } = {}

	Collect(File, ".", nil, nil, nil, Entries, ByPath, Under, {})

	for _, Entry in Entries do
		if Entry.Path == Under or string.sub(Entry.Path, 1, #Under + 1) == `{Under}/` then
			table.insert(Subtree, Entry)
		end
	end

	return BuildTree(Subtree, Viewport, Parent)
end

-- Builds the scene at a res:// path unparented, with the viewport of Viewport for its layout. Yields.
const function Instantiate(Path: string, Viewport: GuiBase2d): Built
	const File = Items.SceneIndex[Path]

	if not File then
		error(`Aimia UI: no converted scene {Path}`, 2)
	end

	const Entries: { Entry } = {}
	const ByPath: { [string]: Entry } = {}

	Collect(File, ".", nil, nil, nil, Entries, ByPath, nil, {})

	return BuildTree(Entries, Viewport, nil)
end

-- The item at a scene path of a built scene.
const function Get(Built: Built, Path: string): Item
	const Item = Built.Items[Path]

	if not Item then
		error(`Aimia UI: no node {Path}`, 2)
	end

	return Item
end

return {
	Build = Build,
	BuildSubtree = BuildSubtree,
	BuildTree = BuildTree,
	Get = Get,
	Draw = Draw,
	Refresh = Refresh,
	ButtonMode = ButtonMode,
	FillNode = FillNode,
	Instantiate = Instantiate,
	RebuildVisuals = RebuildVisuals,
	ContentMinimumSize = ContentMinimumSize,
	Relayout = Relayout,
	RelayoutMoved = RelayoutMoved,
	RelayoutLocal = RelayoutLocal,
	Attach = Attach,
	Detach = Detach,
	Reorder = Reorder,
	FreeTree = FreeTree,
}
