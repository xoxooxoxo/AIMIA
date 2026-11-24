--!strict
--!optimize 2

--[[
	The Godot-shaped node API of ported scripts (docs/port/ui.md, "Node API"), over the items UI/SceneBuilder builds:
	the tree, properties, signals, the per-frame dispatch and the viewport.

	Paradigm
		A node is an Item. GetNode walks the children by name ("." is the node, ".." its parent), so it follows
		AddChild and QueueFree; SceneBuilder.Get reads the scene paths a built scene recorded.
		Properties use Godot's names. Values are the scene-data forms (numbers, strings, booleans, { Color = {...} },
		{ Path = "res://..." }, resource tables { Type, Properties }) and a vector for a Vector2 (Set also takes
		{ Vector2 = {...} }). Get answers geometry as vectors and resources resolved (Theme.Resource).

	Layout
		A layout change marks the top of the tree dirty. Dirty trees are laid out once per frame, in the PreRender
		dispatch, and at once when a geometry value is read (size, position, global_position).

	Process
		OnProcess (per item) and OnFrame (tweens) subscribe to one PreRender dispatch, which calls them in order, then
		flushes the layout and the shader passes (UI/Shaders.Flush). A subscription added during a dispatch runs from the
		next frame.

	Shader parameters
		SetShaderParameter stores the value on the item as Godot's "material:shader_parameter/<Name>" property and hands it
		to the item's shader (UI/Shaders), which redraws at the next flush. GetShaderParameter reads it back, or the material's
		value, or the shader's default.

	Design Notes
		Set keeps the value table it is given (a tween reuses its value tables, so colors and vectors are not allocated
		per frame). Set of a geometry value is Godot's: anchors push the opposite anchor and keep the rect, position
		and size compute the offsets from the parent's rect (Control::set_position, set_size).
		Signals are Godot's names; gui_input is connected on the first connect and carries the local position.
		DEVIATION: tooltip_text is stored but not drawn (Roblox has no tooltips).
		DEVIATION: SetInputAsHandled does nothing (a Roblox input connection cannot consume an event).
		DEVIATION: rotation and scale turn about the pivot (the AnchorPoint); scale is uniform (UIScale uses x).
]]

const RunService = game:GetService("RunService")

const Frames = require("./Frames")

const Items = require("./Item")
const Scale = require("./Scale")
const SceneBuilder = require("./SceneBuilder")
const Theme = require("./Theme")
const Shaders = require("./Shaders")
const Layout = require("./Layout")
const Input = require("./Input")
const NodePath = require("./NodePath")
const Slider = require("./Controls/Slider")
const OptionButton = require("./Controls/OptionButton")
const LineEdit = require("./Controls/LineEdit")
const Signal = require("../Util/Signal")

type Item = Items.Item
type Built = Items.Built

type Subscription = {
	Callback: (number) -> (),
	Dead: boolean,
}

const Subscriptions: { Subscription } = {}
local DeadCount = 0
local ActiveDispatches = 0

const OffsetNames = { "offset_left", "offset_top", "offset_right", "offset_bottom" }
const AnchorNames = { "anchor_left", "anchor_top", "anchor_right", "anchor_bottom" }

-- Godot's defaults for the Range properties a scene leaves out.
const RangeDefaults = {
	["value"] = 0,
	["min_value"] = 0,
	["max_value"] = 100,
	["step"] = 0.01,
}

-- Properties that hold a resource (a texture, a font, a LabelSettings, a material, a theme style, font or icon).
const ResourceProperties = {
	["texture"] = true,
	["texture_normal"] = true,
	["texture_pressed"] = true,
	["texture_hover"] = true,
	["texture_disabled"] = true,
	["texture_focused"] = true,
	["icon"] = true,
	["label_settings"] = true,
	["material"] = true,
}

-- Properties whose change redraws the item (the others only change its layout or its stored value).
-- The properties that only change how a control is painted: they redraw it and leave the layout alone.
const PaintProperties = {
	["self_modulate"] = true,
	["color"] = true,
}

const DrawProperties = {
	["self_modulate"] = true,
	["text"] = true,
	["placeholder_text"] = true,
	["uppercase"] = true,
	["autowrap_mode"] = true,
	["clip_text"] = true,
	["text_overrun_behavior"] = true,
	["horizontal_alignment"] = true,
	["vertical_alignment"] = true,
	["alignment"] = true,
	["icon_alignment"] = true,
	["vertical_icon_alignment"] = true,
	["expand_icon"] = true,
	["editable"] = true,
	["secret"] = true,
	["color"] = true,
	["flat"] = true,
	["label_settings"] = true,
	["material"] = true,
	["fit_content"] = true,
	["ignore_texture_size"] = true,
	["max_lines_visible"] = true,
	["visible_characters"] = true,
	["paragraph_separator"] = true,
	["tick_count"] = true,
	["ticks_on_borders"] = true,
	["ticks_position"] = true,
}

-- Properties a Range keeps within its bounds: a change reclamps the value (and may emit value_changed).
const RangeProperties = {
	["min_value"] = true,
	["max_value"] = true,
	["step"] = true,
	["rounded"] = true,
	["allow_greater"] = true,
	["allow_lesser"] = true,
}

-- Every signal Nodes.Connect accepts, by Godot name.
const SignalNames = {
	["pressed"] = true,
	["button_down"] = true,
	["button_up"] = true,
	["toggled"] = true,
	["mouse_entered"] = true,
	["mouse_exited"] = true,
	["text_changed"] = true,
	["text_submitted"] = true,
	["focus_entered"] = true,
	["focus_exited"] = true,
	["item_selected"] = true,
	["value_changed"] = true,
	["drag_started"] = true,
	["drag_ended"] = true,
	["resized"] = true,
	["visibility_changed"] = true,
	["gui_input"] = true,
}

const function StartsWith(Text: string, Prefix: string): boolean
	return string.sub(Text, 1, #Prefix) == Prefix
end

-- What a disconnected subscription calls (nothing), so its callback and everything that holds can be let go.
const function Noop(_: number) end

const function Subscribe(Callback: (number) -> ()): () -> ()
	const Subscription = { Callback = Callback, Dead = false } :: Subscription

	table.insert(Subscriptions, Subscription)

	return function()
		if not Subscription.Dead then
			Subscription.Dead = true
			Subscription.Callback = Noop
			DeadCount += 1
		end
	end
end

const function Compact()
	for Index = #Subscriptions, 1, -1 do
		if Subscriptions[Index].Dead then
			table.remove(Subscriptions, Index)
		end
	end

	DeadCount = 0
end

const Moved: { Item } = {}

-- Lays out the dirty trees, oldest first (a tree may be queued again by a callback), then the controls that only moved,
-- each alone unless its tree was just laid out whole.
const function FlushLayout()
	-- (rows of the play list with a change under them are laid out alone, after the dirty trees: Items.MarkDirty)
	while Items.HasDirty() or Items.HasDirtyLocal() do
		while Items.HasDirty() do
			const Top = Items.TakeDirty()

			if Top and not Top.Freed then
				SceneBuilder.Relayout(Top)
			end
		end

		const Local = Items.TakeDirtyLocal()

		if Local and not Local.Freed then
			SceneBuilder.RelayoutLocal(Local)
		end
	end

	Items.TakeMoved(Moved)

	for _, Item in Moved do
		SceneBuilder.RelayoutMoved(Item)
	end

	table.clear(Moved)
end


-- Runs this frame's callbacks (those subscribed during it start next frame).
const function RunSubscriptions(Delta: number)
	const Count = #Subscriptions

	for Index = 1, Count do
		const Subscription = Subscriptions[Index]

		if not Subscription.Dead then
			Subscription.Callback(Delta)
		end
	end
end

const function Dispatch(Delta: number)
	-- (the frame clock steps first, paused or not, so its time goes on as real time does; the callbacks get its step)
	Frames.Step(Delta)

	if Frames.Paused then
		return
	end

	ActiveDispatches += 1

	-- (a callback that errors still lets the count come back down, or Compact would never run again; the error is still
	-- reported, after the frame's layout)
	const Ran, Problem = pcall(RunSubscriptions, Frames.Delta)

	ActiveDispatches -= 1

	if DeadCount > 0 and ActiveDispatches == 0 then
		Compact()
	end

	FlushLayout()
	Shaders.Flush()

	if not Ran then
		error(Problem, 0)
	end
end

RunService.PreRender:Connect(Dispatch)

-- Calls Callback(delta) every frame, until the returned function is called.
const function OnFrame(Callback: (number) -> ()): () -> ()
	return Subscribe(Callback)
end

-- Calls Callback(delta) every frame while the item is alive (freed with it).
-- Godot calls _Process only on nodes in the tree: a scene that is not under the main scene (the cached menu while a game or
-- the results show) does not run its callbacks.
const function OnProcess(Item: Item, Callback: (number) -> ()): () -> ()
	const Disconnect = Subscribe(function(Delta: number)
		if Items.TopOf(Item).Instance.Parent ~= nil then
			Callback(Delta)
		end
	end)

	table.insert(Item.Cleanup, Disconnect)

	return Disconnect
end

-- Whether an item can't be seen: it or something above it is hidden, or it isn't on a screen. Work that only draws (a list
-- or a preview on a tab that isn't shown) can skip a frame when this is true.
const function HiddenInTree(Item: Item): boolean
	local Current: Instance? = Item.Instance

	while Current and not Current:IsA("LayerCollector") do
		if Current:IsA("GuiObject") and not Current.Visible then
			return true
		end

		Current = Current.Parent
	end

	return Current == nil
end

const function CheckAlive(Item: Item)
	if Item.Freed then
		error("Aimia UI: the node was freed", 3)
	end
end

const function ChildNamed(Item: Item, Name: string): Item?
	for _, Child in Item.Children do
		if Child.Name == Name then
			return Child
		end
	end

	return nil
end

const function FindIn(Item: Item, Name: string, Recursive: boolean): Item?
	const Direct = ChildNamed(Item, Name)

	if Direct or not Recursive then
		return Direct
	end

	for _, Child in Item.Children do
		const Found = FindIn(Child, Name, true)

		if Found then
			return Found
		end
	end

	return nil
end

const function GetNodeOrNull(Item: Item, Path: string): Item?
	local Current: Item? = Item

	for _, Segment in NodePath.Segments(Path) do
		if not Current then
			return nil
		end

		if Segment == ".." then
			Current = Current.Parent
		else
			Current = ChildNamed(Current, Segment)
		end
	end

	return Current
end

const function GetNode(Item: Item, Path: string): Item
	const Found = GetNodeOrNull(Item, Path)

	if not Found then
		error(`Aimia UI: node not found: "{Path}"`, 2)
	end

	return Found
end

-- Godot's Control::get_parent_anchorable_rect: a Control parent's size, or the viewport's for anything else.
const function AnchorSize(Item: Item): vector
	if Item.Parent and Item.Parent.IsControl and not Item.Node.TopLevel then
		return Item.Parent.Node.Size
	end

	return Scale.SizeOfViewport(Item.Scene.Viewport)
end

-- Offsets that place a rect (Position, Size) between the anchors (Control::_compute_offsets), stored on the item.
const function SetRectOffsets(Item: Item, Position: vector, Size: vector)
	const Anchors = Item.Node.Anchors
	const Offsets = Item.Node.Offsets
	const Reference = AnchorSize(Item)
	const Properties = Item.Context.Properties

	Offsets[1] = Position.x - Anchors[1] * Reference.x
	Offsets[2] = Position.y - Anchors[2] * Reference.y
	Offsets[3] = Position.x + Size.x - Anchors[3] * Reference.x
	Offsets[4] = Position.y + Size.y - Anchors[4] * Reference.y

	for Side = 1, 4 do
		Properties[OffsetNames[Side]] = Offsets[Side]
	end

	Items.MarkMoved(Item)
end

-- Control::_set_anchor (the anchor_* properties): set_anchor with keep_offset and push_opposite_anchor. The offsets stay as they
-- are, so the rect moves with the anchor.
const function SetAnchor(Item: Item, Side: number, Value: number)
	FlushLayout()

	const Anchors = Item.Node.Anchors
	const Opposite = (Side + 1) % 4 + 1
	const Properties = Item.Context.Properties

	Anchors[Side] = Value

	if (Side <= 2 and Anchors[Side] > Anchors[Opposite]) or (Side > 2 and Anchors[Side] < Anchors[Opposite]) then
		Anchors[Opposite] = Anchors[Side]
	end

	for Index = 1, 4 do
		Properties[AnchorNames[Index]] = Anchors[Index]
	end

	Items.MarkMoved(Item)
end

const function SetVisible(Item: Item, Visible: boolean)
	Item.Context.Properties["visible"] = Visible
	Item.Node.Visible = Visible

	if Item.Instance:IsA("GuiObject") then
		Item.Instance.Visible = Visible
	end

	Items.Emit(Item, "visibility_changed")
	Items.MarkDirty(Item)
end

const function SetModulateValue(Item: Item, Value: unknown)
	const Components = Items.ColorComponents(Value)

	Items.SetModulate(Item, Components[1], Components[2], Components[3], Components[4] or 1)
end

const function SetRangeValue(Item: Item, Value: unknown)
	Slider.SetValue(Item, if type(Value) == "number" then Value else 0, true)
end

const function SetThemeOverride(Item: Item, Name: string, Value: unknown)
	Item.Context.Properties[Name] = Value
	Item.Context.Files[Name] = nil

	if StartsWith(Name, "theme_override_constants/") then
		SceneBuilder.FillNode(Item)
	end

	SceneBuilder.Refresh(Item)
end

-- The one scroll offset of a ScrollingFrame (scroll_vertical and scroll_horizontal are Godot's pixel offsets).
const function SetScroll(Item: Item, Horizontal: boolean, Value: number)
	const Gui = Item.Instance

	if not Gui:IsA("ScrollingFrame") then
		return
	end

	const Position = Gui.CanvasPosition

	Gui.CanvasPosition = if Horizontal then Vector2.new(Value, Position.Y) else Vector2.new(Position.X, Value)
end

-- Godot's Node.get / set of "material:shader_parameter/<Name>" (the ShaderMaterial's parameter on the node's material).
const ShaderPrefix = "material:shader_parameter/"

-- Whether two property values are equal: primitives by value, the scene-data tables ({ Color = { ... } },
-- { Vector2 = { ... } }, arrays) by their contents.
const function SameValue(Left: unknown, Right: unknown, Depth: number): boolean
	if Left == Right then
		return true
	elseif type(Left) ~= "table" or type(Right) ~= "table" or Depth > 3 then
		return false
	end

	const LeftTable = Left :: { [unknown]: unknown }
	const RightTable = Right :: { [unknown]: unknown }

	for Key, Value in LeftTable do
		if not SameValue(Value, RightTable[Key], Depth + 1) then
			return false
		end
	end

	for Key in RightTable do
		if LeftTable[Key] == nil then
			return false
		end
	end

	return true
end

-- Godot's ShaderMaterial.set_shader_parameter on the node's material: the value is stored on the node (an override of
-- the material's own) and handed to the node's shader, which redraws at the next flush.
const function SetShaderParameter(Item: Item, Name: string, Value: unknown)
	CheckAlive(Item)

	const Key = Shaders.OverrideKey(Name)
	const Properties = Item.Context.Properties

	if SameValue(Properties[Key], Value, 0) then
		return
	end

	Properties[Key] = Value

	if Item.StyleHost then
		Shaders.SetParameter(Item.StyleHost, Name, Value)
	end
end

-- Godot's ShaderMaterial.get_shader_parameter: the node's override, else the material's value, else the shader's default.
const function GetShaderParameter(Item: Item, Name: string): unknown
	CheckAlive(Item)

	return Shaders.ParameterOf(Items.ShaderOf(Item), Name)
end

const function SetProperty(Item: Item, Name: string, Value: unknown)
	const Properties = Item.Context.Properties
	const Gui = Item.Instance

	if Name == "name" then
		Item.Name = if type(Value) == "string" then Value else Item.Name
		Gui.Name = Item.Name
	elseif Name == "visible" then
		SetVisible(Item, Value == true)
	elseif Name == "modulate" then
		SetModulateValue(Item, Value)
	elseif Name == "disabled" then
		Item.Disabled = Value == true
		Properties["disabled"] = Item.Disabled

		if Gui:IsA("GuiButton") then
			Gui.Interactable = not Item.Disabled
		end

		Item.Mode = SceneBuilder.ButtonMode(Item)
		SceneBuilder.Refresh(Item)
	elseif Name == "button_pressed" then
		Item.Toggled = Value == true
		Properties["button_pressed"] = Item.Toggled
		Item.Mode = SceneBuilder.ButtonMode(Item) -- (the look follows the mode: set from code, it has to change too)
		SceneBuilder.Refresh(Item)
		Items.Emit(Item, "toggled", Item.Toggled)
	elseif Name == "value" and Item.Class == "HSlider" then
		SetRangeValue(Item, Value)
	elseif Name == "caret_column" then
		LineEdit.SetCaretColumn(Item, if type(Value) == "number" then Value // 1 else 0)
	elseif Name == "selected" and Item.Class == "OptionButton" then
		OptionButton.Select(Item, if type(Value) == "number" then Value // 1 else -1, SceneBuilder.Refresh)
	elseif StartsWith(Name, "anchor_") then
		SetAnchor(Item, table.find(AnchorNames, Name) :: number, if type(Value) == "number" then Value else 0)
	elseif StartsWith(Name, "offset_") then
		const Side = table.find(OffsetNames, Name) :: number
		const Number = if type(Value) == "number" then Value else 0

		Item.Node.Offsets[Side] = Number
		Properties[Name] = Number
		Items.MarkMoved(Item)
	elseif Name == "position" then
		FlushLayout()
		SetRectOffsets(Item, Items.VectorOf(Value), Item.Node.Size)
	elseif Name == "size" then
		FlushLayout()

		const Minimum = Layout.GetCombinedMinimumSize(Item.Node)
		const Requested = Items.VectorOf(Value)

		SetRectOffsets(Item, Item.Node.Position, vector.create(math.max(Requested.x, Minimum.x), math.max(Requested.y, Minimum.y), 0))
	elseif Name == "pivot_offset" then
		Item.Pivot = Items.VectorOf(Value)
		Items.MarkDirty(Item)
	elseif Name == "scale" then
		const Factor = if type(Value) == "number" then Value else Items.VectorOf(Value).x

		Item.Scale = Factor

		if Gui:IsA("GuiObject") then
			const Scaling = Gui:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")

			Scaling.Scale = Factor
			Scaling.Parent = Gui
		end
	elseif Name == "rotation" then
		Item.Rotation = math.deg(if type(Value) == "number" then Value else 0)

		if Gui:IsA("GuiObject") then
			Gui.Rotation = Item.Rotation
		end
	elseif Name == "rotation_degrees" then
		Item.Rotation = if type(Value) == "number" then Value else 0

		if Gui:IsA("GuiObject") then
			Gui.Rotation = Item.Rotation
		end
	elseif Name == "mouse_filter" then
		Properties[Name] = Value

		if Gui:IsA("GuiObject") then
			Gui.Active = Value ~= 2 or Item.Class == "ScrollContainer"
		end
	elseif Name == "clip_contents" then
		Properties[Name] = Value

		if Gui:IsA("GuiObject") then
			Gui.ClipsDescendants = Value == true or Item.Class == "ScrollContainer"
		end
	elseif Name == "z_index" or Name == "show_behind_parent" then
		Properties[Name] = Value

		if Gui:IsA("GuiObject") then
			Gui.ZIndex = if Properties["show_behind_parent"] == true then -1 else 1 + Items.Number(Properties, "z_index", 0)
		end
	elseif (Name == "vertical_scroll_mode" or Name == "horizontal_scroll_mode") and Gui:IsA("ScrollingFrame") then
		-- ScrollContainer.ScrollMode: 0 disabled, 1 auto, 2 show always, 3 show never (the bar hidden, still scrollable).
		Properties[Name] = Value
		SceneBuilder.FillNode(Item)

		const Mode = Items.Number(Properties, Name, 1)

		Gui.ScrollingEnabled = Mode ~= 0
		Items.StyleScrollBar(Gui, Items.Number(Properties, "vertical_scroll_mode", 1))
		Items.MarkDirty(Item)
	elseif Name == "scroll_vertical" then
		SetScroll(Item, false, if type(Value) == "number" then Value else 0)
	elseif Name == "scroll_horizontal" then
		SetScroll(Item, true, if type(Value) == "number" then Value else 0)
	elseif StartsWith(Name, "theme_override_") then
		SetThemeOverride(Item, Name, Value)
	elseif StartsWith(Name, ShaderPrefix) then
		SetShaderParameter(Item, string.sub(Name, #ShaderPrefix + 1), Value)
	elseif Name == "stretch_mode" or Name == "expand_mode" or (ResourceProperties :: { [string]: boolean })[Name] then
		Properties[Name] = Value
		Item.Context.Files[Name] = nil
		SceneBuilder.RebuildVisuals(Item)
	else
		Properties[Name] = Value
		Item.Context.Files[Name] = nil
		SceneBuilder.FillNode(Item)

		if (RangeProperties :: { [string]: boolean })[Name] and Item.Class == "HSlider" then
			Slider.SetValue(Item, Items.Number(Properties, "value", 0), true)
		elseif (PaintProperties :: { [string]: boolean })[Name] then
			SceneBuilder.Draw(Item)
		elseif Name == "custom_minimum_size" then
			Items.MarkResized(Item)
		elseif (DrawProperties :: { [string]: boolean })[Name] then
			SceneBuilder.Refresh(Item)
		else
			Items.MarkDirty(Item)
		end
	end
end

const function GetProperty(Item: Item, Name: string): unknown
	const Properties = Item.Context.Properties
	const Gui = Item.Instance

	if Name == "position" then
		FlushLayout()

		return Item.Node.Position
	elseif Name == "size" then
		FlushLayout()

		return Item.Node.Size
	elseif Name == "global_position" then
		FlushLayout()

		return Items.GlobalPosition(Item)
	elseif Name == "visible" then
		return Properties["visible"] ~= false
	elseif Name == "modulate" then
		const Color = Item.Modulate

		return { Color = { Color[1], Color[2], Color[3], Color[4] } }
	elseif Name == "disabled" then
		return Item.Disabled
	elseif Name == "button_pressed" then
		return Item.Toggled
	elseif Name == "selected" then
		return Item.Selected
	elseif Name == "text" then
		return Items.RawText(Item)
	elseif Name == "caret_column" then
		return LineEdit.GetCaretColumn(Item)
	elseif Name == "name" then
		return Item.Name
	elseif StartsWith(Name, "anchor_") then
		return Item.Node.Anchors[table.find(AnchorNames, Name) :: number]
	elseif StartsWith(Name, "offset_") then
		return Item.Node.Offsets[table.find(OffsetNames, Name) :: number]
	elseif Name == "scale" then
		return vector.create(Item.Scale, Item.Scale, 0)
	elseif Name == "rotation" then
		return math.rad(Item.Rotation)
	elseif Name == "rotation_degrees" then
		return Item.Rotation
	elseif Name == "pivot_offset" then
		return Item.Pivot
	elseif Name == "scroll_vertical" or Name == "scroll_horizontal" then
		if Gui:IsA("ScrollingFrame") then
			return if Name == "scroll_vertical" then Gui.CanvasPosition.Y else Gui.CanvasPosition.X
		end

		return 0
	elseif StartsWith(Name, ShaderPrefix) then
		return GetShaderParameter(Item, string.sub(Name, #ShaderPrefix + 1))
	elseif (ResourceProperties :: { [string]: boolean })[Name] then
		return Items.ResolveValue(Properties[Name], Theme.FileOf(Item.Context, Name), Item)
	elseif StartsWith(Name, "theme_override_") then
		const Value = Properties[Name]

		if StartsWith(Name, "theme_override_styles/") or StartsWith(Name, "theme_override_fonts/") or StartsWith(Name, "theme_override_icons/") then
			return Items.ResolveValue(Value, Theme.FileOf(Item.Context, Name), Item)
		end

		return Value
	end

	const Value = Properties[Name]

	if Value == nil then
		return (RangeDefaults :: { [string]: number })[Name]
	end

	return Value
end

-- Godot's Node.get: the value of a property (see the header for the forms).
const function Get(Item: Item, Name: string): unknown
	CheckAlive(Item)

	return GetProperty(Item, Name)
end

-- Whether a modulate value is the item's modulate already.
const function SameModulate(Item: Item, Value: unknown): boolean
	const Components = Items.ColorComponents(Value)
	const Modulate = Item.Modulate

	return Components[1] == Modulate[1] and Components[2] == Modulate[2] and Components[3] == Modulate[3] and (Components[4] or 1) == Modulate[4]
end

-- Properties whose stored value is not what Set writes (derived from the layout, or kept elsewhere).
const DerivedProperties = {
	["position"] = true,
	["size"] = true,
	["global_position"] = true,
	["name"] = true,
}

-- Godot's Node.set: sets a property and redraws or relays out what it affects. Like Godot's setters it returns early
-- when the value does not change, which also keeps an unchanged Set from relaying out the tree every frame.
const function Set(Item: Item, Name: string, Value: unknown)
	CheckAlive(Item)

	-- (a modulate lives on the item, not in its properties, which keep the scene's value: compared with that, the last frame
	-- of a fade back to the scene's own modulate was skipped and the item stayed faintly drawn, such as the play list's pink
	-- square left at the side by the grid switch. A modulate is compared with the item's own.)
	if Name == "modulate" then
		if SameModulate(Item, Value) then
			return
		end

		SetProperty(Item, Name, Value)

		return
	end

	-- The same table object is never skipped: tweens mutate one value table in place and set it again every frame.
	const Current = Item.Context.Properties[Name]
	const SameObject = type(Value) == "table" and Current == Value

	if not SameObject and not (DerivedProperties :: { [string]: boolean })[Name] and SameValue(Current, Value, 0) then
		return
	end

	-- A position that is the node's already moves nothing: setting it would lay out the control's subtree again.
	if Name == "position" then
		FlushLayout()

		if Items.VectorOf(Value) == Item.Node.Position then
			return
		end
	end

	SetProperty(Item, Name, Value)
end

-- Godot's Node.connect: the signal (Godot's name) and a callback with its arguments. Answers the disconnect.
const function Connect(Item: Item, SignalName: string, Callback: (...unknown) -> ()): () -> ()
	CheckAlive(Item)

	if not (SignalNames :: { [string]: boolean })[SignalName] then
		error(`Aimia UI: no signal {SignalName} on {Item.Class}`, 2)
	end

	if SignalName == "gui_input" and not Item.Signals["gui_input"] then
		const Gui = Item.Instance

		if Gui:IsA("GuiObject") then
			const function Forward(Raw: InputObject)
				const Event = Input.FromInputObject(Raw)

				if Event and not Item.Freed and not Input.Blocked(Gui) then
					Event.Position -= Scale.PositionOf(Gui)
					Items.Emit(Item, "gui_input", Event)
				end
			end

			table.insert(Item.Connections, Gui.InputBegan:Connect(Forward))
			table.insert(Item.Connections, Gui.InputEnded:Connect(Forward))
			table.insert(Item.Connections, Gui.InputChanged:Connect(Forward))
		end
	end

	const Emitter = Items.GetSignal(Item, SignalName)

	Signal.Connect(Emitter, Callback)

	return function()
		Signal.Disconnect(Emitter, Callback)
	end
end

-- Godot's get_node: the node at a relative path ("A/B", "../C"), or an error when it is missing.
const function GetNodeChecked(Item: Item, Path: string): Item
	CheckAlive(Item)

	return GetNode(Item, Path)
end

-- Godot's get_node_or_null.
const function GetNodeFound(Item: Item, Path: string): Item?
	CheckAlive(Item)

	return GetNodeOrNull(Item, Path)
end

-- Godot's find_child (exact name; recursive by default).
const function FindChild(Item: Item, Name: string, Recursive: boolean?): Item?
	CheckAlive(Item)

	return FindIn(Item, Name, Recursive ~= false)
end

-- Godot's get_children: a copy of the children in tree order.
const function GetChildren(Item: Item): { Item }
	CheckAlive(Item)

	return table.clone(Item.Children)
end

const function GetParent(Item: Item): Item?
	CheckAlive(Item)

	return Item.Parent
end

-- Entries of an item and its subtree as they would be built, with their current properties (Duplicate).
const function EntriesOf(Item: Item, Path: string, ParentPath: string?, Entries: { SceneBuilder.Entry })
	table.insert(Entries, {
		Path = Path,
		Name = Item.Name,
		ParentPath = ParentPath,
		Class = Item.Class,
		File = Item.Context.File,
		Files = table.clone(Item.Context.Files),
		Properties = table.clone(Item.Context.Properties),
	})

	for _, Child in Item.Children do
		EntriesOf(Child, NodePath.Join(Path, Child.Name), Path, Entries)
	end
end

-- Godot's Duplicate: a new unparented copy of the subtree with the current property values.
const function Duplicate(Item: Item): Item
	CheckAlive(Item)

	const Entries: { SceneBuilder.Entry } = {}

	EntriesOf(Item, ".", nil, Entries)

	const Scene = SceneBuilder.BuildTree(Entries, Item.Scene.Viewport, nil)

	return Scene.Root :: Item
end

-- Godot's instantiation of a packed scene (unparented): the scene at a res:// path, laid out in the viewport of Built.
const function Instantiate(Built: Built, Path: string): Item
	return SceneBuilder.Instantiate(Path, Built.Viewport).Root :: Item
end

-- Godot's add_child (the child must be unparented).
const function AddChild(Parent: Item, Child: Item)
	CheckAlive(Parent)
	CheckAlive(Child)

	if Child.Parent then
		error(`Aimia UI: {Child.Name} already has a parent`, 2)
	end

	SceneBuilder.Attach(Parent, Child)
end

const function RemoveChild(Parent: Item, Child: Item)
	if Child.Parent ~= Parent then
		error(`Aimia UI: {Child.Name} is not a child of {Parent.Name}`, 2)
	end

	SceneBuilder.Detach(Child)
end

-- Godot's move_child: Index is 0-based.
const function MoveChild(Parent: Item, Child: Item, Index: number)
	if Child.Parent ~= Parent then
		error(`Aimia UI: {Child.Name} is not a child of {Parent.Name}`, 2)
	end

	SceneBuilder.Reorder(Child, Index + 1)
end

const function MoveToFront(Item: Item)
	const Parent = Item.Parent

	if Parent then
		SceneBuilder.Reorder(Item, #Parent.Children)
	end
end

-- Godot's queue_free: the item and its subtree are freed now (their signals, process callbacks and tweens disconnected).
const function QueueFree(Item: Item)
	if not Item.Freed then
		SceneBuilder.FreeTree(Item)
	end
end

const function IsInsideTree(Item: Item): boolean
	CheckAlive(Item)

	return Items.TopOf(Item).Instance.Parent ~= nil
end

const function IsInstanceValid(Item: Item?): boolean
	return Item ~= nil and not Item.Freed
end

-- Godot's Control.reset_size: the smallest size the minimum allows.
const function ResetSize(Item: Item)
	Set(Item, "size", vector.zero)
end

const function GetViewportRect(Item: Item): vector
	return Scale.SizeOfViewport(Item.Scene.Viewport)
end

const function GetMousePosition(Item: Item): vector
	return Input.GetMousePosition()
end

-- DEVIATION: a Roblox input connection cannot consume the event; this does nothing.
const function SetInputAsHandled(Item: Item) end

const function GetFocusOwner(Item: Item): Item?
	return LineEdit.GetFocusOwner()
end

const function GrabFocus(Item: Item)
	if Item.Input then
		Item.Input:CaptureFocus()
	elseif Item.Class == "HSlider" then
		Slider.SetFocus(Item, true)
	end
end

const function ReleaseFocus(Item: Item)
	if Item.Input then
		Item.Input:ReleaseFocus()
	elseif Item.Class == "HSlider" then
		Slider.SetFocus(Item, false)
	end
end

const function GetThemeFont(Item: Item, Name: string): Font
	return Items.GetFont(Item)
end

const function GetThemeFontSize(Item: Item, Name: string): number
	return Items.GetFontSize(Item)
end

-- Godot's Font.get_string_size: the width and height of a line of text in the font at a size.
const function GetStringSize(Font: Font, Text: string, Size: number): vector
	return Items.Measure(Text, Font, Size)
end

-- A copy of a resource (Godot's Resource.duplicate): its properties are copied one level deep.
const function DuplicateResource(Resource: Theme.Resource): Theme.Resource
	return {
		Type = Resource.Type,
		Path = Resource.Path,
		Properties = table.clone(Resource.Properties),
		File = Resource.File,
	}
end

-- OptionButton: the item list and the selection (Godot's add_item, remove_item, clear, select, get_item_text).
const function RequireOption(Item: Item)
	CheckAlive(Item)

	if Item.Class ~= "OptionButton" then
		error(`Aimia UI: {Item.Class} has no items`, 3)
	end
end

const function AddItem(Item: Item, Text: string)
	RequireOption(Item)
	OptionButton.AddItem(Item, Text, SceneBuilder.Refresh)
end

const function RemoveItem(Item: Item, Index: number)
	RequireOption(Item)
	OptionButton.RemoveItem(Item, Index, SceneBuilder.Refresh)
end

const function ClearItems(Item: Item)
	RequireOption(Item)
	OptionButton.Clear(Item, SceneBuilder.Refresh)
end

const function ItemCount(Item: Item): number
	RequireOption(Item)

	return #Item.Items
end

const function GetItemText(Item: Item, Index: number): string
	RequireOption(Item)

	return Item.Items[Index + 1]
end

const function SelectItem(Item: Item, Index: number)
	RequireOption(Item)
	OptionButton.Select(Item, Index, SceneBuilder.Refresh)
end

-- Godot's set_value_no_signal of a slider.
const function SetValueNoSignal(Item: Item, Value: number)
	CheckAlive(Item)

	if Item.Class ~= "HSlider" then
		error(`Aimia UI: {Item.Class} has no value`, 2)
	end

	Slider.SetValue(Item, Value, false)
end

return {
	OnFrame = OnFrame,
	OnProcess = OnProcess,
	Get = Get,
	Set = Set,
	Connect = Connect,
	GetNode = GetNodeChecked,
	GetNodeOrNull = GetNodeFound,
	FindChild = FindChild,
	GetChildren = GetChildren,
	GetParent = GetParent,
	Instantiate = Instantiate,
	Duplicate = Duplicate,
	AddChild = AddChild,
	RemoveChild = RemoveChild,
	MoveChild = MoveChild,
	MoveToFront = MoveToFront,
	QueueFree = QueueFree,
	IsInsideTree = IsInsideTree,
	IsInstanceValid = IsInstanceValid,
	ResetSize = ResetSize,
	GetViewportRect = GetViewportRect,
	HiddenInTree = HiddenInTree,
	GetMousePosition = GetMousePosition,
	SetInputAsHandled = SetInputAsHandled,
	GetFocusOwner = GetFocusOwner,
	GrabFocus = GrabFocus,
	ReleaseFocus = ReleaseFocus,
	GetThemeFont = GetThemeFont,
	GetThemeFontSize = GetThemeFontSize,
	GetStringSize = GetStringSize,
	DuplicateResource = DuplicateResource,
	AddItem = AddItem,
	RemoveItem = RemoveItem,
	ClearItems = ClearItems,
	ItemCount = ItemCount,
	GetItemText = GetItemText,
	SelectItem = SelectItem,
	SetValueNoSignal = SetValueNoSignal,
	SetShaderParameter = SetShaderParameter,
	GetShaderParameter = GetShaderParameter,
}
