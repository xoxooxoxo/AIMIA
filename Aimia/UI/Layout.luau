--!strict
--!optimize 2

--[[
	Godot 4.7.2 Control layout on the layout node of docs/port/ui.md: anchors and offsets, grow directions, minimum and
	desired sizes, and the sorting of the containers (HBox/VBox, Margin, Panel, Scroll, AspectRatio, Grid, Center).
	Ported from reference/engine/gui: control, container, box_container, margin_container, panel_container,
	scroll_container, aspect_ratio_container, grid_container, center_container (.cpp). No Roblox API.

	Order: minimum and desired sizes bubble up from the children (MeasureNode, memoized per Update in a map passed
	down), so they are known before any rect. Rects are then computed top-down: a Control's rect comes from its
	anchoring rect (the parent's size, or the viewport), its anchors, offsets, minimum size and grow directions. A
	container fits its sortable children, then every child takes its anchored rect and its own subtree is laid out.
	Godot reaches the same final rects with deferred sorts and a _size_changed cascade; for a static tree the pass
	order does not change the values. A fitted child has its anchors set to 0 and its offsets to its rect
	(Control::set_rect), as Godot stores them.

	Float32: every C++ float operation is rounded with Numbers.F32 per operation. Integer arithmetic (counts,
	separations, ceiled minimums, Size2i) stays integer; float-to-int casts are Numbers.TruncInt32.

	Visibility: sorting uses VISIBLE_IN_TREE (the default of Container::as_sortable_control in Godot 4.7.2 container.h),
	minimum sizes use VISIBLE (own flag). Top-level children are never sorted. Visible-in-tree walks the Parent chain.

	Not modeled (no field in the Node type; the reference scenes use none of them, checked by grep):
	- Maximum size (custom_maximum_size, _get_maximum_size, parent maximum propagation): the combined maximum is -1
	  (unset), so the maximum clamps drop out. Grid still caps columns at the container width, as Godot does when unset.
	- layout_direction: always left to right (is_layout_rtl false).
	- Rotation and scale that fit_child_in_rect resets on a child are transforms, not layout: the builder applies them.
	- Grid's accumulated sizes feed only the propagated maximum cache, so they are not ported.
	- grow_to_desired_size: a desired size never exceeds the minimum here (leaves report zero), so it never grows.
	- Desired sizes: the containers' get_desired_size is ported; other Controls report zero (Godot's base Control).

	Builder supplies, resolved (Layout does not read the default theme):
	- Constants: separation (BoxContainer), margin_left/top/right/bottom (MarginContainer), h_separation and
	  v_separation (GridContainer).
	- Properties: vertical (BoxContainer only; VBoxContainer and HBoxContainer are set by Class), alignment (box),
	  ratio, stretch_mode, alignment_horizontal, alignment_vertical (AspectRatioContainer), expand_mode (TextureRect),
	  columns (GridContainer), use_top_left (CenterContainer), horizontal_scroll_mode and vertical_scroll_mode
	  (ScrollContainer, Godot default AUTO = 1), content_margin_left and content_margin_top (PanelContainer and
	  ScrollContainer: StyleBox get_offset of the panel style, which is the content margins; 0 when there is none).
	- StyleMinimumSize: StyleBox get_minimum_size of the panel style (PanelContainer, ScrollContainer); 0 when none.
	- ContentMinimumSize: the class's own get_minimum_size for every other Control (text, texture, icon).
	- LayoutMode is not read: rects come from the anchors, offsets and grow directions as stored. For a layout_mode 0
	  node Godot resets anchors to 0 and grow directions to begin when the property is set at load
	  (Control::_set_layout_mode); the builder applies that before the stored values.
	- Non-Control classes (Node, the 2D and 3D families, WorldEnvironment, SubViewport, FileDialog) pass the viewport to
	  their Control children; any other Class is a Control. Other Godot containers (not in the scenes) get plain layout.

	DEVIATION(platform): ScrollContainer scroll bars (internal HScrollBar/VScrollBar, focus panel, scroll hints) are not
	nodes here; their minimum sizes and separators count as 0 and no space is reserved (the builder draws a
	ScrollingFrame's own bars). Scroll offsets are 0 and draw_focus_border is off (Godot defaults).
]]

const Numbers = require("../Numbers")

const GrowBegin = 0
const GrowEnd = 1
const GrowBoth = 2
const SizeFill = 1
const SizeExpand = 2
const SizeShrinkCenter = 4
const SizeShrinkEnd = 8
const AlignmentBegin = 0
const AlignmentCenter = 1
const AlignmentEnd = 2
const ScrollDisabled = 0
const ScrollMaximizeFirst = 5
const StretchWidthControlsHeight = 0
const StretchHeightControlsWidth = 1
const StretchFit = 2
const StretchCover = 3
const ExpandFitWidthProportional = 3
const ExpandFitHeightProportional = 5

export type Node = {
	Class: string,
	IsControl: boolean, -- set by NewNode from the class; the builder overrides it with the theme's class chain
	Parent: Node?,
	Children: { Node },
	Visible: boolean,
	TopLevel: boolean,
	LayoutMode: number,
	Anchors: { number },
	Offsets: { number },
	GrowHorizontal: number,
	GrowVertical: number,
	CustomMinimumSize: vector,
	SizeFlagsHorizontal: number,
	SizeFlagsVertical: number,
	StretchRatio: number,
	Constants: { [string]: number },
	Properties: { [string]: unknown },
	ContentMinimumSize: vector,
	StyleMinimumSize: vector,
	Position: vector,
	Size: vector,
}

-- Minimum: get_combined_minimum_size (class minimum, bounded below by the custom minimum). Desired: get_desired_size.
type Measured = {
	Minimum: vector,
	Desired: vector,
}

type MeasureMap = { [Node]: Measured }

type BoxEntry = {
	Child: Node,
	MinSize: number,
	WillStretch: boolean,
	Ratio: number,
	FinalSize: number,
}

const function Property(Target: Node, Name: string): number
	const Value = Target.Properties[Name]

	if type(Value) ~= "number" then
		error(`{Target.Class} needs the resolved number property {Name}`, 2)
	end

	return Value
end

const function Flag(Target: Node, Name: string): boolean
	const Value = Target.Properties[Name]

	if type(Value) ~= "boolean" then
		error(`{Target.Class} needs the resolved boolean property {Name}`, 2)
	end

	return Value
end

const function Constant(Target: Node, Name: string): number
	const Value = Target.Constants[Name]

	if Value == nil then
		error(`{Target.Class} needs the resolved constant {Name}`, 2)
	end

	return Value
end

-- Alignment enum (begin, center, end) as the fraction used by AspectRatioContainer; Godot's default is center.
const function AlignmentFraction(Alignment: number): number
	if Alignment == AlignmentBegin then
		return 0
	elseif Alignment == AlignmentCenter then
		return 0.5
	elseif Alignment == AlignmentEnd then
		return 1
	end

	return 0.5
end

-- Number of true entries among keys 0 .. Limit - 1.
const function CountFlags(Flags: { [number]: boolean }, Limit: number): number
	local Count = 0

	for Index = 0, Limit - 1 do
		if Flags[Index] then
			Count += 1
		end
	end

	return Count
end

-- Smallest key in 0 .. Limit - 1 that is true, or -1 (RBSet::front).
const function FirstFlag(Flags: { [number]: boolean }, Limit: number): number
	for Index = 0, Limit - 1 do
		if Flags[Index] then
			return Index
		end
	end

	return -1
end

-- Godot classes that are not Control: the Node, 2D and 3D families, WorldEnvironment, SubViewport, FileDialog (Window).
const function IsControlClass(Class: string): boolean
	const Suffix = string.sub(Class, -2)

	if Suffix == "2D" or Suffix == "3D" then
		return false
	end

	return not (Class == "Node" or Class == "WorldEnvironment" or Class == "SubViewport" or Class == "FileDialog")
end

const function IsControl(Target: Node): boolean
	return Target.IsControl
end

-- @src engine/gui/control.cpp:Control::get_bound_desired_size L2023-2038
const function BoundDesired(Sizes: Measured): vector
	return vector.create(math.max(Sizes.Desired.x, Sizes.Minimum.x), math.max(Sizes.Desired.y, Sizes.Minimum.y), 0)
end

const function NewNode(Class: string): Node
	return {
		Class = Class,
		IsControl = IsControlClass(Class),
		Parent = nil,
		Children = {},
		Visible = true,
		TopLevel = false,
		LayoutMode = 1,
		Anchors = { 0, 0, 0, 0 },
		Offsets = { 0, 0, 0, 0 },
		GrowHorizontal = GrowEnd,
		GrowVertical = GrowEnd,
		CustomMinimumSize = vector.zero,
		SizeFlagsHorizontal = SizeFill,
		SizeFlagsVertical = SizeFill,
		StretchRatio = 1,
		Constants = {},
		Properties = {},
		ContentMinimumSize = vector.zero,
		StyleMinimumSize = vector.zero,
		Position = vector.zero,
		Size = vector.zero,
	}
end

-- Node.Visible of the node and every ancestor.
const function IsVisibleInTree(Target: Node): boolean
	local Current: Node? = Target

	while Current do
		if not Current.Visible then
			return false
		end

		Current = Current.Parent
	end

	return true
end

-- @src engine/gui/container.cpp:Container::as_sortable_control L170-182
const function IsSortable(Target: Node, InTree: boolean): boolean
	if not IsControl(Target) or Target.TopLevel then
		return false
	end

	if InTree then
		return IsVisibleInTree(Target)
	end

	return Target.Visible
end

const function IsVertical(Target: Node): boolean
	if Target.Class == "VBoxContainer" then
		return true
	elseif Target.Class == "HBoxContainer" then
		return false
	end

	return Flag(Target, "vertical")
end

-- @src engine/gui/control.cpp:Control::get_parent_anchorable_rect L708-734
const function AnchorRectSize(Parent: Node, Child: Node, ViewportSize: vector): vector
	if IsControl(Parent) and not Child.TopLevel then
		return Parent.Size
	end

	return ViewportSize
end

-- @src engine/gui/box_container.cpp:BoxContainer::_get_minimum_size L291-327
const function BoxMinimum(Target: Node, UseDesired: boolean, Measures: MeasureMap): vector
	const Vertical = IsVertical(Target)
	const Separation = Constant(Target, "separation")
	local MinWidth = 0
	local MinHeight = 0
	local First = true

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if not IsSortable(Child, false) then
			continue
		end

		const Sizes = Measures[Child]
		const Size = if UseDesired then BoundDesired(Sizes) else Sizes.Minimum
		const Width = math.ceil(Size.x)
		const Height = math.ceil(Size.y)

		if Vertical then
			MinWidth = math.max(MinWidth, Width)
			MinHeight += Height + (if First then 0 else Separation)
		else
			MinHeight = math.max(MinHeight, Height)
			MinWidth += Width + (if First then 0 else Separation)
		end

		First = false
	end

	return vector.create(MinWidth, MinHeight, 0)
end

-- @src engine/gui/margin_container.cpp:MarginContainer::get_minimum_size L35-52
const function MarginMinimum(Target: Node, Measures: MeasureMap): vector
	local MaxWidth = 0
	local MaxHeight = 0

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if IsSortable(Child, false) then
			const Minimum = Measures[Child].Minimum

			MaxWidth = math.max(MaxWidth, Minimum.x)
			MaxHeight = math.max(MaxHeight, Minimum.y)
		end
	end

	const HorizontalMargin = Constant(Target, "margin_left") + Constant(Target, "margin_right")
	const VerticalMargin = Constant(Target, "margin_top") + Constant(Target, "margin_bottom")

	return vector.create(Numbers.F32(MaxWidth + HorizontalMargin), Numbers.F32(MaxHeight + VerticalMargin), 0)
end

-- @src engine/gui/margin_container.cpp:MarginContainer::get_desired_size L54-71
const function MarginDesired(Target: Node, Measures: MeasureMap): vector
	local MaxWidth = 0
	local MaxHeight = 0

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if IsSortable(Child, false) then
			const Desired = Measures[Child].Desired

			MaxWidth = math.max(MaxWidth, Desired.x)
			MaxHeight = math.max(MaxHeight, Desired.y)
		end
	end

	const HorizontalMargin = Constant(Target, "margin_left") + Constant(Target, "margin_right")
	const VerticalMargin = Constant(Target, "margin_top") + Constant(Target, "margin_bottom")

	return vector.create(Numbers.F32(MaxWidth + HorizontalMargin), Numbers.F32(MaxHeight + VerticalMargin), 0)
end

-- @src engine/gui/panel_container.cpp:PanelContainer::get_minimum_size L35-51
const function PanelMinimum(Target: Node, Measures: MeasureMap): vector
	local MaxWidth = 0
	local MaxHeight = 0

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if IsSortable(Child, false) then
			const Minimum = Measures[Child].Minimum

			MaxWidth = math.max(MaxWidth, Minimum.x)
			MaxHeight = math.max(MaxHeight, Minimum.y)
		end
	end

	const Style = Target.StyleMinimumSize

	return vector.create(Numbers.F32(MaxWidth + Style.x), Numbers.F32(MaxHeight + Style.y), 0)
end

-- @src engine/gui/panel_container.cpp:PanelContainer::get_desired_size L53-69
const function PanelDesired(Target: Node, Measures: MeasureMap): vector
	local MaxWidth = 0
	local MaxHeight = 0

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if IsSortable(Child, false) then
			const Desired = Measures[Child].Desired

			MaxWidth = math.max(MaxWidth, Desired.x)
			MaxHeight = math.max(MaxHeight, Desired.y)
		end
	end

	const Style = Target.StyleMinimumSize

	return vector.create(Numbers.F32(MaxWidth + Style.x), Numbers.F32(MaxHeight + Style.y), 0)
end

-- DEVIATION(platform): scroll bars are not nodes here, so their minimum sizes and separators count as 0.
-- @src engine/gui/scroll_container.cpp:ScrollContainer::_get_minimum_size L43-94
const function ScrollMinimum(Target: Node, UseDesired: boolean, Measures: MeasureMap): vector
	local LargestWidth = 0
	local LargestHeight = 0

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if IsSortable(Child, false) then
			const Sizes = Measures[Child]
			const ChildSize = if UseDesired then BoundDesired(Sizes) else Sizes.Minimum

			LargestWidth = math.max(LargestWidth, ChildSize.x)
			LargestHeight = math.max(LargestHeight, ChildSize.y)
		end
	end

	local MinWidth = 0
	local MinHeight = 0
	const HorizontalMode = Property(Target, "horizontal_scroll_mode")
	const VerticalMode = Property(Target, "vertical_scroll_mode")

	if HorizontalMode == ScrollDisabled or HorizontalMode == ScrollMaximizeFirst then
		MinWidth = LargestWidth
	end

	if VerticalMode == ScrollDisabled or VerticalMode == ScrollMaximizeFirst then
		MinHeight = LargestHeight
	end

	const Style = Target.StyleMinimumSize

	return vector.create(Numbers.F32(MinWidth + Style.x), Numbers.F32(MinHeight + Style.y), 0)
end

-- @src engine/gui/aspect_ratio_container.cpp:AspectRatioContainer::get_minimum_size L36-47
const function AspectMinimum(Target: Node, Measures: MeasureMap): vector
	local MaxWidth = 0
	local MaxHeight = 0

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if IsSortable(Child, false) then
			const Minimum = Measures[Child].Minimum

			MaxWidth = math.max(MaxWidth, Minimum.x)
			MaxHeight = math.max(MaxHeight, Minimum.y)
		end
	end

	return vector.create(MaxWidth, MaxHeight, 0)
end

-- @src engine/gui/grid_container.cpp:GridContainer::_get_minimum_size L381-428
const function GridMinimum(Target: Node, UseDesired: boolean, Measures: MeasureMap): vector
	const Columns = Property(Target, "columns")
	const HorizontalSeparation = Constant(Target, "h_separation")
	const VerticalSeparation = Constant(Target, "v_separation")

	const ColumnMinWidth: { [number]: number } = {}
	const RowMinHeight: { [number]: number } = {}
	local MaxRow = 0
	local MaxColumn = 0
	local ValidCount = 0

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if not IsSortable(Child, false) then
			continue
		end

		const Row = ValidCount // Columns
		const Column = ValidCount % Columns

		ValidCount += 1

		const Sizes = Measures[Child]
		const Size = if UseDesired then BoundDesired(Sizes) else Sizes.Minimum
		const Width = Numbers.TruncInt32(Size.x)
		const Height = Numbers.TruncInt32(Size.y)

		ColumnMinWidth[Column] = math.max(ColumnMinWidth[Column] or Width, Width)
		RowMinHeight[Row] = math.max(RowMinHeight[Row] or Height, Height)
		MaxColumn = math.max(Column, MaxColumn)
		MaxRow = math.max(Row, MaxRow)
	end

	local SumWidth = 0
	local SumHeight = 0

	for Column = 0, MaxColumn do
		if ColumnMinWidth[Column] ~= nil then
			SumWidth += ColumnMinWidth[Column]
		end
	end

	for Row = 0, MaxRow do
		if RowMinHeight[Row] ~= nil then
			SumHeight += RowMinHeight[Row]
		end
	end

	SumHeight += VerticalSeparation * MaxRow
	SumWidth += HorizontalSeparation * MaxColumn

	return vector.create(SumWidth, SumHeight, 0)
end

-- @src engine/gui/center_container.cpp:CenterContainer::get_minimum_size L35-50
const function CenterMinimum(Target: Node, Measures: MeasureMap): vector
	if Flag(Target, "use_top_left") then
		return vector.zero
	end

	local MaxWidth = 0
	local MaxHeight = 0

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if IsSortable(Child, false) then
			const Minimum = Measures[Child].Minimum

			MaxWidth = math.max(MaxWidth, Minimum.x)
			MaxHeight = math.max(MaxHeight, Minimum.y)
		end
	end

	return vector.create(MaxWidth, MaxHeight, 0)
end

-- @src engine/gui/center_container.cpp:CenterContainer::get_desired_size L52-67
const function CenterDesired(Target: Node, Measures: MeasureMap): vector
	if Flag(Target, "use_top_left") then
		return vector.zero
	end

	local MaxWidth = 0
	local MaxHeight = 0

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if IsSortable(Child, false) then
			const Desired = BoundDesired(Measures[Child])

			MaxWidth = math.max(MaxWidth, Desired.x)
			MaxHeight = math.max(MaxHeight, Desired.y)
		end
	end

	return vector.create(MaxWidth, MaxHeight, 0)
end

-- Control::get_minimum_size: the container's own minimum for container classes, ContentMinimumSize otherwise.
const function GetMinimumSize(Target: Node, Measures: MeasureMap): vector
	const Class = Target.Class

	if Class == "VBoxContainer" or Class == "HBoxContainer" or Class == "BoxContainer" then
		return BoxMinimum(Target, false, Measures)
	elseif Class == "MarginContainer" then
		return MarginMinimum(Target, Measures)
	elseif Class == "PanelContainer" then
		return PanelMinimum(Target, Measures)
	elseif Class == "ScrollContainer" then
		return ScrollMinimum(Target, false, Measures)
	elseif Class == "AspectRatioContainer" then
		return AspectMinimum(Target, Measures)
	elseif Class == "GridContainer" then
		return GridMinimum(Target, false, Measures)
	elseif Class == "CenterContainer" then
		return CenterMinimum(Target, Measures)
	end

	return Target.ContentMinimumSize
end

-- Control::get_desired_size: containers report their desired sizes; every other Control reports zero.
const function GetDesiredSize(Target: Node, Measures: MeasureMap): vector
	const Class = Target.Class

	if Class == "VBoxContainer" or Class == "HBoxContainer" or Class == "BoxContainer" then
		return BoxMinimum(Target, true, Measures)
	elseif Class == "MarginContainer" then
		return MarginDesired(Target, Measures)
	elseif Class == "PanelContainer" then
		return PanelDesired(Target, Measures)
	elseif Class == "ScrollContainer" then
		return ScrollMinimum(Target, true, Measures)
	elseif Class == "GridContainer" then
		return GridMinimum(Target, true, Measures)
	elseif Class == "CenterContainer" then
		return CenterDesired(Target, Measures)
	end

	return vector.zero
end

-- Bubbles the sizes up: every Control child is measured before its parent (the children's Measured entries are read
-- by the class functions above). Results are memoized in Measures for the tree of one Update.
-- @src engine/gui/control.cpp:Control::get_combined_minimum_size L2142-2148
const function MeasureNode(Target: Node, Measures: MeasureMap): Measured
	const Known: Measured? = Measures[Target]

	if Known then
		return Known
	end

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if IsControl(Child) then
			MeasureNode(Child, Measures)
		end
	end

	const Minimum = GetMinimumSize(Target, Measures)
	const Custom = Target.CustomMinimumSize
	const Result = {
		Minimum = vector.create(math.max(Minimum.x, Custom.x), math.max(Minimum.y, Custom.y), 0),
		Desired = GetDesiredSize(Target, Measures),
	}

	Measures[Target] = Result

	return Result
end

-- Control::get_combined_minimum_size for a single node, measuring its subtree.
const function GetCombinedMinimumSize(Target: Node): vector
	const Measures: MeasureMap = {}

	return MeasureNode(Target, Measures).Minimum
end

-- @src engine/gui/control.cpp:Control::_compute_offsets L936-947
const function ComputeOffsets(Target: Node, Position: vector, Size: vector, AnchorSize: vector)
	const Anchors = Target.Anchors
	const Offsets = Target.Offsets

	Offsets[1] = Numbers.F32(Position.x - Numbers.F32(Anchors[1] * AnchorSize.x))
	Offsets[2] = Numbers.F32(Position.y - Numbers.F32(Anchors[2] * AnchorSize.y))
	Offsets[3] = Numbers.F32(Numbers.F32(Position.x + Size.x) - Numbers.F32(Anchors[3] * AnchorSize.x))
	Offsets[4] = Numbers.F32(Numbers.F32(Position.y + Size.y) - Numbers.F32(Anchors[4] * AnchorSize.y))
end

-- @src engine/gui/control.cpp:Control::_size_changed L2165-2258
const function SizeChanged(Target: Node, AnchorSize: vector, Measures: MeasureMap)
	const Anchors = Target.Anchors
	const Offsets = Target.Offsets
	const Left = Numbers.F32(Offsets[1] + Numbers.F32(Anchors[1] * AnchorSize.x))
	const Top = Numbers.F32(Offsets[2] + Numbers.F32(Anchors[2] * AnchorSize.y))
	const Right = Numbers.F32(Offsets[3] + Numbers.F32(Anchors[3] * AnchorSize.x))
	const Bottom = Numbers.F32(Offsets[4] + Numbers.F32(Anchors[4] * AnchorSize.y))

	local PositionX = Left
	local PositionY = Top
	local SizeX = Numbers.F32(Right - Left)
	local SizeY = Numbers.F32(Bottom - Top)

	const Minimum = MeasureNode(Target, Measures).Minimum

	if Minimum.x > SizeX then
		if Target.GrowHorizontal == GrowBegin then
			PositionX = Numbers.F32(PositionX + Numbers.F32(SizeX - Minimum.x))
		elseif Target.GrowHorizontal == GrowBoth then
			PositionX = Numbers.F32(PositionX + 0.5 * Numbers.F32(SizeX - Minimum.x))
		end

		SizeX = Minimum.x
	end

	if Minimum.y > SizeY then
		if Target.GrowVertical == GrowBegin then
			PositionY = Numbers.F32(PositionY + Numbers.F32(SizeY - Minimum.y))
		elseif Target.GrowVertical == GrowBoth then
			PositionY = Numbers.F32(PositionY + 0.5 * Numbers.F32(SizeY - Minimum.y))
		end

		SizeY = Minimum.y
	end

	Target.Position = vector.create(PositionX, PositionY, 0)
	Target.Size = vector.create(SizeX, SizeY, 0)
end

-- @src engine/gui/control.cpp:Control::set_rect L1573-1583
const function SetRect(Target: Node, Position: vector, Size: vector, AnchorSize: vector, Measures: MeasureMap)
	for Side = 1, 4 do
		Target.Anchors[Side] = 0
	end

	ComputeOffsets(Target, Position, Size, AnchorSize)
	SizeChanged(Target, AnchorSize, Measures)
end

-- @src engine/gui/container.cpp:Container::fit_child_in_rect L109-154
const function FitChildInRect(Parent: Node, Child: Node, RectPosition: vector, RectSize: vector, Measures: MeasureMap)
	const Sizes = MeasureNode(Child, Measures)
	const MinSize = Sizes.Minimum
	const DesiredSize = BoundDesired(Sizes)
	const HorizontalFlags = Child.SizeFlagsHorizontal
	const VerticalFlags = Child.SizeFlagsVertical
	local PositionX = RectPosition.x
	local PositionY = RectPosition.y
	local Width = RectSize.x
	local Height = RectSize.y

	if not bit32.btest(HorizontalFlags, SizeFill) then
		local FinalWidth = MinSize.x

		FinalWidth = math.max(math.min(DesiredSize.x, RectSize.x), FinalWidth)
		Width = FinalWidth

		if bit32.btest(HorizontalFlags, SizeShrinkEnd) then
			PositionX = Numbers.F32(PositionX + Numbers.F32(RectSize.x - FinalWidth))
		elseif bit32.btest(HorizontalFlags, SizeShrinkCenter) then
			PositionX = Numbers.F32(PositionX + (Numbers.F32(RectSize.x - FinalWidth) / 2) // 1)
		end
	end

	if not bit32.btest(VerticalFlags, SizeFill) then
		local FinalHeight = MinSize.y

		FinalHeight = math.max(math.min(DesiredSize.y, RectSize.y), FinalHeight)
		Height = FinalHeight

		if bit32.btest(VerticalFlags, SizeShrinkEnd) then
			PositionY = Numbers.F32(PositionY + Numbers.F32(RectSize.y - FinalHeight))
		elseif bit32.btest(VerticalFlags, SizeShrinkCenter) then
			PositionY = Numbers.F32(PositionY + (Numbers.F32(RectSize.y - FinalHeight) / 2) // 1)
		end
	end

	SetRect(Child, vector.create(PositionX, PositionY, 0), vector.create(Width, Height, 0), Parent.Size, Measures)
end

-- @src engine/gui/box_container.cpp:BoxContainer::_resort L45-289
const function SortBox(Target: Node, Measures: MeasureMap)
	const Vertical = IsVertical(Target)
	const Separation = Constant(Target, "separation")
	const Alignment = Property(Target, "alignment")
	const ContainerWidth = Numbers.TruncInt32(Target.Size.x)
	const ContainerHeight = Numbers.TruncInt32(Target.Size.y)

	const Entries: { BoxEntry } = {}
	local StretchMin = 0
	local StretchAvail = 0
	local StretchRatioTotal = 0

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if not IsSortable(Child, true) then
			continue
		end

		const MinSize = MeasureNode(Child, Measures).Minimum
		const WillStretch = if Vertical then bit32.btest(Child.SizeFlagsVertical, SizeExpand) else bit32.btest(Child.SizeFlagsHorizontal, SizeExpand)
		const MinimumSize = if Vertical then math.ceil(MinSize.y) else math.ceil(MinSize.x)
		const Ratio = Numbers.F32(Child.StretchRatio)

		StretchMin += MinimumSize

		if WillStretch then
			StretchAvail += MinimumSize
			StretchRatioTotal = Numbers.F32(StretchRatioTotal + Ratio)
		end

		table.insert(Entries, { Child = Child, MinSize = MinimumSize, WillStretch = WillStretch, Ratio = Ratio, FinalSize = MinimumSize })
	end

	const ChildrenCount = #Entries

	if ChildrenCount == 0 then
		return
	end

	const StretchMax = (if Vertical then ContainerHeight else ContainerWidth) - (ChildrenCount - 1) * Separation
	local StretchDiff = StretchMax - StretchMin

	if StretchDiff < 0 then
		StretchDiff = 0
	end

	StretchAvail += StretchDiff

	while StretchRatioTotal > 0 do
		local RefitSuccessful = true
		local Fraction = 0

		for Index = 1, ChildrenCount do
			const Entry = Entries[Index]

			if Entry.WillStretch then
				const FinalPixelSize = Numbers.F32(Numbers.F32(StretchAvail * Entry.Ratio) / StretchRatioTotal)

				Fraction = Numbers.F32(Fraction + Numbers.F32(FinalPixelSize - Numbers.TruncInt32(FinalPixelSize)))

				if FinalPixelSize < Entry.MinSize then
					Entry.WillStretch = false
					StretchRatioTotal = Numbers.F32(StretchRatioTotal - Entry.Ratio)
					RefitSuccessful = false
					StretchAvail -= Entry.MinSize
					Entry.FinalSize = Entry.MinSize

					break
				end

				Entry.FinalSize = Numbers.TruncInt32(FinalPixelSize)

				if Fraction >= 1 then
					Entry.FinalSize += 1
					Fraction = Numbers.F32(Fraction - 1)
				end
			end
		end

		if RefitSuccessful then
			break
		end
	end

	local FinalStretchDiff = StretchMax - StretchMin

	for Index = 1, ChildrenCount do
		FinalStretchDiff -= Entries[Index].FinalSize - Entries[Index].MinSize
	end

	if FinalStretchDiff < 0 then
		FinalStretchDiff = 0
	end

	-- Offset of the first child: center takes half the free space, end takes all of it (left to right; begin is 0).
	local Position = 0

	if Alignment == AlignmentCenter then
		Position = FinalStretchDiff // 2
	elseif Alignment == AlignmentEnd then
		Position = FinalStretchDiff
	end

	for Index = 1, ChildrenCount do
		const Entry = Entries[Index]

		if Index > 1 then
			Position += Separation
		end

		const From = Position
		local To = Position + Entry.FinalSize

		if Entry.WillStretch and Index == ChildrenCount then
			To = if Vertical then ContainerHeight else ContainerWidth
		end

		const Length = To - From

		if Vertical then
			FitChildInRect(Target, Entry.Child, vector.create(0, From, 0), vector.create(ContainerWidth, Length, 0), Measures)
		else
			FitChildInRect(Target, Entry.Child, vector.create(From, 0, 0), vector.create(Length, ContainerHeight, 0), Measures)
		end

		Position = To
	end
end

-- @src engine/gui/margin_container.cpp:MarginContainer::_notification L117-138
const function SortMargin(Target: Node, Measures: MeasureMap)
	const Left = Constant(Target, "margin_left")
	const Top = Constant(Target, "margin_top")
	const Right = Constant(Target, "margin_right")
	const Bottom = Constant(Target, "margin_bottom")
	const Size = Target.Size

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if IsSortable(Child, true) then
			const Width = Numbers.TruncInt32(Numbers.F32(Numbers.F32(Size.x - Left) - Right))
			const Height = Numbers.TruncInt32(Numbers.F32(Numbers.F32(Size.y - Top) - Bottom))

			FitChildInRect(Target, Child, vector.create(Left, Top, 0), vector.create(Width, Height, 0), Measures)
		end
	end
end

-- @src engine/gui/panel_container.cpp:PanelContainer::_notification L99-124
const function SortPanel(Target: Node, Measures: MeasureMap)
	const Style = Target.StyleMinimumSize
	const Width = Numbers.F32(Target.Size.x - Style.x)
	const Height = Numbers.F32(Target.Size.y - Style.y)
	const OffsetX = Numbers.F32(Property(Target, "content_margin_left"))
	const OffsetY = Numbers.F32(Property(Target, "content_margin_top"))

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if IsSortable(Child, true) then
			FitChildInRect(Target, Child, vector.create(OffsetX, OffsetY, 0), vector.create(Width, Height, 0), Measures)
		end
	end
end

-- DEVIATION(platform): scroll bars are not nodes here, so no space is reserved for them; scroll offsets are 0.
-- @src engine/gui/scroll_container.cpp:ScrollContainer::_reposition_children L384-443
const function SortScroll(Target: Node, Measures: MeasureMap)
	const Style = Target.StyleMinimumSize
	const Width = Numbers.F32(Target.Size.x - Style.x)
	const Height = Numbers.F32(Target.Size.y - Style.y)
	const OffsetX = Numbers.F32(Property(Target, "content_margin_left"))
	const OffsetY = Numbers.F32(Property(Target, "content_margin_top"))

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if not IsSortable(Child, true) then
			continue
		end

		const MinSize = MeasureNode(Child, Measures).Minimum
		local RectWidth = MinSize.x
		local RectHeight = MinSize.y

		if bit32.btest(Child.SizeFlagsHorizontal, SizeExpand) then
			RectWidth = math.max(Width, MinSize.x)
		end

		if bit32.btest(Child.SizeFlagsVertical, SizeExpand) then
			RectHeight = math.max(Height, MinSize.y)
		end

		-- Rect2(-(scroll offset), minsize) plus the content offset, floored (scroll offset is 0).
		FitChildInRect(Target, Child, vector.create(OffsetX // 1, OffsetY // 1, 0), vector.create(RectWidth, RectHeight, 0), Measures)
	end
end

-- @src engine/gui/aspect_ratio_container.cpp:AspectRatioContainer::_notification L99-174
const function SortAspect(Target: Node, Measures: MeasureMap)
	const Size = Target.Size
	const Ratio = Numbers.F32(Property(Target, "ratio"))
	const StretchMode = Property(Target, "stretch_mode")
	const AlignX = AlignmentFraction(Property(Target, "alignment_horizontal"))
	const AlignY = AlignmentFraction(Property(Target, "alignment_vertical"))

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if not IsSortable(Child, true) then
			continue
		end

		-- Proportional TextureRect expand modes are not supported by Godot here: the child is left where it is.
		if Child.Class == "TextureRect" then
			const ExpandMode = Property(Child, "expand_mode")

			if ExpandMode == ExpandFitWidthProportional or ExpandMode == ExpandFitHeightProportional then
				continue
			end
		end

		const ChildMinimum = MeasureNode(Child, Measures).Minimum
		const ChildRatioWidth = Ratio
		const ChildRatioHeight = 1

		local ScaleFactor = 1

		if StretchMode == StretchWidthControlsHeight then
			ScaleFactor = Numbers.F32(Size.x / ChildRatioWidth)
		elseif StretchMode == StretchHeightControlsWidth then
			ScaleFactor = Numbers.F32(Size.y / ChildRatioHeight)
		elseif StretchMode == StretchFit then
			ScaleFactor = math.min(Numbers.F32(Size.x / ChildRatioWidth), Numbers.F32(Size.y / ChildRatioHeight))
		elseif StretchMode == StretchCover then
			ScaleFactor = math.max(Numbers.F32(Size.x / ChildRatioWidth), Numbers.F32(Size.y / ChildRatioHeight))
		end

		local ChildWidth = Numbers.F32(ChildRatioWidth * ScaleFactor)
		local ChildHeight = Numbers.F32(ChildRatioHeight * ScaleFactor)

		ChildWidth = math.max(ChildWidth, ChildMinimum.x)
		ChildHeight = math.max(ChildHeight, ChildMinimum.y)

		const OffsetX = Numbers.F32(Numbers.F32(Size.x - ChildWidth) * AlignX)
		const OffsetY = Numbers.F32(Numbers.F32(Size.y - ChildHeight) * AlignY)

		FitChildInRect(Target, Child, vector.create(OffsetX, OffsetY, 0), vector.create(ChildWidth, ChildHeight, 0), Measures)
	end
end

-- @src engine/gui/grid_container.cpp:GridContainer::_resort L38-331
const function SortGrid(Target: Node, Measures: MeasureMap)
	const Columns = Property(Target, "columns")
	const HorizontalSeparation = Constant(Target, "h_separation")
	const VerticalSeparation = Constant(Target, "v_separation")
	const ContainerWidth = Numbers.TruncInt32(Target.Size.x)
	const ContainerHeight = Numbers.TruncInt32(Target.Size.y)

	const ColumnMinWidth: { [number]: number } = {}
	const RowMinHeight: { [number]: number } = {}
	const ColumnMaxWidth: { [number]: number } = {}
	const RowMaxHeight: { [number]: number } = {}
	const ColumnFixedWidth: { [number]: number } = {}
	const RowFixedHeight: { [number]: number } = {}
	const ColumnExpanded: { [number]: boolean } = {}
	const RowExpanded: { [number]: boolean } = {}
	local ValidCount = 0

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if not IsSortable(Child, true) then
			continue
		end

		const Row = ValidCount // Columns
		const Column = ValidCount % Columns

		ValidCount += 1

		const MinSize = MeasureNode(Child, Measures).Minimum
		const MinWidth = Numbers.TruncInt32(MinSize.x)
		const MinHeight = Numbers.TruncInt32(MinSize.y)

		ColumnMinWidth[Column] = math.max(ColumnMinWidth[Column] or MinWidth, MinWidth)
		RowMinHeight[Row] = math.max(RowMinHeight[Row] or MinHeight, MinHeight)
		ColumnMaxWidth[Column] = math.max(ColumnMaxWidth[Column] or ContainerWidth, ContainerWidth)
		RowMaxHeight[Row] = math.max(RowMaxHeight[Row] or ContainerHeight, ContainerHeight)

		if bit32.btest(Child.SizeFlagsHorizontal, SizeExpand) then
			ColumnExpanded[Column] = true
		end

		if bit32.btest(Child.SizeFlagsVertical, SizeExpand) then
			RowExpanded[Row] = true
		end
	end

	const NumRows = (ValidCount + Columns - 1) // Columns
	const UsedColumns = math.min(ValidCount, Columns)

	for Column = 0, Columns - 1 do
		if ColumnMaxWidth[Column] ~= nil and ColumnMaxWidth[Column] < ColumnMinWidth[Column] then
			ColumnMaxWidth[Column] = ColumnMinWidth[Column]
		end
	end

	for Row = 0, NumRows - 1 do
		if RowMaxHeight[Row] ~= nil and RowMaxHeight[Row] < RowMinHeight[Row] then
			RowMaxHeight[Row] = RowMinHeight[Row]
		end
	end

	-- Empty columns count as expanded.
	for Column = ValidCount, Columns - 1 do
		ColumnExpanded[Column] = true
	end

	local RemainingWidth = Target.Size.x
	local RemainingHeight = Target.Size.y

	for Column = 0, Columns - 1 do
		if ColumnMinWidth[Column] ~= nil and not ColumnExpanded[Column] then
			RemainingWidth = Numbers.F32(RemainingWidth - ColumnMinWidth[Column])
		end
	end

	for Row = 0, NumRows - 1 do
		if RowMinHeight[Row] ~= nil and not RowExpanded[Row] then
			RemainingHeight = Numbers.F32(RemainingHeight - RowMinHeight[Row])
		end
	end

	RemainingHeight = Numbers.F32(RemainingHeight - VerticalSeparation * math.max(NumRows - 1, 0))
	RemainingWidth = Numbers.F32(RemainingWidth - HorizontalSeparation * math.max(UsedColumns - 1, 0))

	-- Drop expanded columns whose minimum does not fit their share, the widest minimum first.
	local CanFit = false

	while not CanFit and CountFlags(ColumnExpanded, Columns) > 0 do
		CanFit = true

		const Count = CountFlags(ColumnExpanded, Columns)
		local MaxIndex = FirstFlag(ColumnExpanded, Columns)

		for Column = 0, Columns - 1 do
			if ColumnExpanded[Column] then
				if (ColumnMinWidth[Column] or 0) > (ColumnMinWidth[MaxIndex] or 0) then
					MaxIndex = Column
				end

				if CanFit and Numbers.F32(RemainingWidth / Count) < (ColumnMinWidth[Column] or 0) then
					CanFit = false
				end
			end
		end

		if not CanFit then
			ColumnExpanded[MaxIndex] = nil
			RemainingWidth = Numbers.F32(RemainingWidth - (ColumnMinWidth[MaxIndex] or 0))
			ColumnFixedWidth[MaxIndex] = ColumnMinWidth[MaxIndex] or 0
		end
	end

	CanFit = false

	while not CanFit and CountFlags(RowExpanded, NumRows) > 0 do
		CanFit = true

		const Count = CountFlags(RowExpanded, NumRows)
		local MaxIndex = FirstFlag(RowExpanded, NumRows)

		for Row = 0, NumRows - 1 do
			if RowExpanded[Row] then
				if (RowMinHeight[Row] or 0) > (RowMinHeight[MaxIndex] or 0) then
					MaxIndex = Row
				end

				if CanFit and Numbers.F32(RemainingHeight / Count) < (RowMinHeight[Row] or 0) then
					CanFit = false
				end
			end
		end

		if not CanFit then
			RowExpanded[MaxIndex] = nil
			RemainingHeight = Numbers.F32(RemainingHeight - (RowMinHeight[MaxIndex] or 0))
			RowFixedHeight[MaxIndex] = RowMinHeight[MaxIndex] or 0
		end
	end

	-- Cap expanded columns whose share exceeds their maximum (the container width when unset).
	local MaxFit = false

	while not MaxFit and CountFlags(ColumnExpanded, Columns) > 0 do
		MaxFit = true

		const Count = CountFlags(ColumnExpanded, Columns)
		local CappedColumn = -1

		for Column = 0, Columns - 1 do
			if ColumnExpanded[Column] and ColumnMaxWidth[Column] ~= nil and Numbers.F32(RemainingWidth / Count) > ColumnMaxWidth[Column] then
				CappedColumn = Column
				MaxFit = false

				break
			end
		end

		if CappedColumn >= 0 then
			ColumnExpanded[CappedColumn] = nil
			RemainingWidth = Numbers.F32(RemainingWidth - ColumnMaxWidth[CappedColumn])
			ColumnFixedWidth[CappedColumn] = ColumnMaxWidth[CappedColumn]
		end
	end

	MaxFit = false

	while not MaxFit and CountFlags(RowExpanded, NumRows) > 0 do
		MaxFit = true

		const Count = CountFlags(RowExpanded, NumRows)
		local CappedRow = -1

		for Row = 0, NumRows - 1 do
			if RowExpanded[Row] and RowMaxHeight[Row] ~= nil and Numbers.F32(RemainingHeight / Count) > RowMaxHeight[Row] then
				CappedRow = Row
				MaxFit = false

				break
			end
		end

		if CappedRow >= 0 then
			RowExpanded[CappedRow] = nil
			RemainingHeight = Numbers.F32(RemainingHeight - RowMaxHeight[CappedRow])
			RowFixedHeight[CappedRow] = RowMaxHeight[CappedRow]
		end
	end

	const ColumnCount = CountFlags(ColumnExpanded, Columns)
	local ColumnExpand = 0
	local ColumnRemainingPixel = 0

	if ColumnCount > 0 then
		ColumnExpand = Numbers.TruncInt32(Numbers.F32(RemainingWidth / ColumnCount))
		ColumnRemainingPixel = Numbers.TruncInt32(Numbers.F32(RemainingWidth - Numbers.F32(ColumnCount * ColumnExpand)))
	end

	const RowCount = CountFlags(RowExpanded, NumRows)
	local RowExpand = 0
	local RowRemainingPixel = 0

	if RowCount > 0 then
		RowExpand = Numbers.TruncInt32(Numbers.F32(RemainingHeight / RowCount))
		RowRemainingPixel = Numbers.TruncInt32(Numbers.F32(RemainingHeight - Numbers.F32(RowCount * RowExpand)))
	end

	-- The leftover pixels go to the first expanded columns and rows.
	local ColumnRemainingIndex = 0

	for Column = 0, UsedColumns - 1 do
		if ColumnRemainingPixel == 0 then
			break
		end

		if ColumnExpanded[Column] then
			ColumnRemainingIndex = Column + 1
			ColumnRemainingPixel -= 1
		end
	end

	local RowRemainingIndex = 0

	for Row = 0, NumRows - 1 do
		if RowRemainingPixel == 0 then
			break
		end

		if RowExpanded[Row] then
			RowRemainingIndex = Row + 1
			RowRemainingPixel -= 1
		end
	end

	local ColumnOffset = 0
	local RowOffset = 0

	ValidCount = 0

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if not IsSortable(Child, true) then
			continue
		end

		const Row = ValidCount // Columns
		const Column = ValidCount % Columns

		ValidCount += 1

		if Column == 0 then
			ColumnOffset = 0

			if Row > 0 then
				RowOffset += (if RowExpanded[Row - 1] then RowExpand else RowMinHeight[Row - 1]) + VerticalSeparation

				if RowExpanded[Row - 1] and Row - 1 < RowRemainingIndex then
					RowOffset += 1
				end
			end
		end

		local Width = if ColumnExpanded[Column] then ColumnExpand elseif ColumnFixedWidth[Column] ~= nil then ColumnFixedWidth[Column] else ColumnMinWidth[Column]
		local Height = if RowExpanded[Row] then RowExpand elseif RowFixedHeight[Row] ~= nil then RowFixedHeight[Row] else RowMinHeight[Row]

		if ColumnExpanded[Column] and Column < ColumnRemainingIndex then
			Width += 1
		end

		if RowExpanded[Row] and Row < RowRemainingIndex then
			Height += 1
		end

		FitChildInRect(Target, Child, vector.create(ColumnOffset, RowOffset, 0), vector.create(Width, Height, 0), Measures)

		ColumnOffset += Width + HorizontalSeparation
	end
end

-- @src engine/gui/center_container.cpp:CenterContainer::_notification L92-107
const function SortCenter(Target: Node, Measures: MeasureMap)
	const UseTopLeft = Flag(Target, "use_top_left")
	const Size = Target.Size

	for Index = 1, #Target.Children do
		const Child = Target.Children[Index]

		if not IsSortable(Child, true) then
			continue
		end

		const MinSize = MeasureNode(Child, Measures).Minimum
		local OffsetX = (Numbers.F32(Size.x - MinSize.x) / 2) // 1
		local OffsetY = (Numbers.F32(Size.y - MinSize.y) / 2) // 1

		if UseTopLeft then
			OffsetX = Numbers.F32(-MinSize.x * 0.5) // 1
			OffsetY = Numbers.F32(-MinSize.y * 0.5) // 1
		end

		FitChildInRect(Target, Child, vector.create(OffsetX, OffsetY, 0), MinSize, Measures)
	end
end

-- Sorts the children of a container Control; other classes have no sort.
const function SortContainer(Target: Node, Measures: MeasureMap)
	const Class = Target.Class

	if Class == "VBoxContainer" or Class == "HBoxContainer" or Class == "BoxContainer" then
		SortBox(Target, Measures)
	elseif Class == "MarginContainer" then
		SortMargin(Target, Measures)
	elseif Class == "PanelContainer" then
		SortPanel(Target, Measures)
	elseif Class == "ScrollContainer" then
		SortScroll(Target, Measures)
	elseif Class == "AspectRatioContainer" then
		SortAspect(Target, Measures)
	elseif Class == "GridContainer" then
		SortGrid(Target, Measures)
	elseif Class == "CenterContainer" then
		SortCenter(Target, Measures)
	end
end

-- Tree pass: a container sorts its children, then each Control child takes its anchored rect (fitted children already
-- hold theirs: their anchors are 0, so the same rect comes back), then the child's own subtree is laid out.
const function LayoutChildren(Parent: Node, ViewportSize: vector, Measures: MeasureMap)
	if IsControl(Parent) then
		SortContainer(Parent, Measures)
	end

	for Index = 1, #Parent.Children do
		const Child = Parent.Children[Index]

		if IsControl(Child) then
			SizeChanged(Child, AnchorRectSize(Parent, Child, ViewportSize), Measures)
		end

		LayoutChildren(Child, ViewportSize, Measures)
	end
end

-- Lays out the whole tree under a root viewport of ViewportSize (the root anchors to the viewport).
const function Update(Root: Node, ViewportSize: vector)
	const Measures: MeasureMap = {}

	if IsControl(Root) then
		SizeChanged(Root, ViewportSize, Measures)
	end

	LayoutChildren(Root, ViewportSize, Measures)
end

-- Lays out one control's own rect in place (UpdateSubtree without its children): for a control that only slid, its size the
-- same, whose subtree keeps its layout (children sit relative to their parent).
const function UpdateRect(Target: Node, ViewportSize: vector)
	if IsControl(Target) then
		const Parent = Target.Parent

		SizeChanged(Target, if Parent then AnchorRectSize(Parent, Target, ViewportSize) else ViewportSize, {})
	end
end

-- Lays out one control and its subtree in place: its rect from its anchors and offsets in its parent's anchor rect,
-- then its children. Valid when nothing else depends on it: its parent is not a container that sorts it, and its
-- combined minimum size did not change (Godot's set_position / set_offset only re-sizes that control).
const function UpdateSubtree(Target: Node, ViewportSize: vector)
	const Measures: MeasureMap = {}
	const Parent = Target.Parent

	if IsControl(Target) then
		SizeChanged(Target, if Parent then AnchorRectSize(Parent, Target, ViewportSize) else ViewportSize, Measures)
	end

	LayoutChildren(Target, ViewportSize, Measures)
end

return {
	NewNode = NewNode,
	GetCombinedMinimumSize = GetCombinedMinimumSize,
	Update = Update,
	UpdateSubtree = UpdateSubtree,
	UpdateRect = UpdateRect,
}
