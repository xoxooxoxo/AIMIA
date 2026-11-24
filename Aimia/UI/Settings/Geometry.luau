--!strict
--!optimize 2

--[[
	Pixel rectangles of the settings menu (the anchors and offsets of res://scenes/main.tscn's Settings subtree), Roblox-free.

	Paradigm
		A rectangle is { X, Y, Width, Height } in whole pixels. Anchored takes Godot's anchors ({ Left, Top, Right, Bottom },
		fractions of the parent's size) and offsets (pixels), and answers the rectangle in the parent's space: every edge is
		round(anchor * size + offset), so two controls that share an edge agree on it.

	Design Notes
		Positions are relative to the parent (the holder, a row, a scroll area's content), so the holder's fade slide moves
		only the holder. The row and button rules are Godot's containers: an HBoxContainer splits its width equally between
		expanding children, and a Control smaller than its minimum size grows to it from its begin edge (grow END).
		The toggle's minimum size is its icon plus the CheckButton style margins (6 and 4).
		DEVIATION(unverified): the toggle icon's native size is not in reference/engine. 36 x 20 is assumed and scaled to the
		28 pixel icon_max_width of theme.tres, keeping the aspect ratio and rounding.
]]

export type Rect = { X: number, Y: number, Width: number, Height: number }

-- Godot anchors or offsets in the order Left, Top, Right, Bottom.
export type Edges = { number }

-- The holder is anchored to the middle half of the screen.
const HolderAnchors = { 0.25, 0.25, 0.75, 0.75 }
const NoOffsets = { 0, 0, 0, 0 }

-- A setting row's height, and the gap between rows (the category container's separation).
const RowHeight = 32
const RowGap = 2

-- A sidebar button's height (the sidebar category's minimum height).
const SidebarRowHeight = 50

-- The header bar at the top of the holder; the sidebar and the dimmed column start under it.
const HeaderHeight = 40

-- A category's content margin (StyleBoxEmpty_epys8) and the vertical scroll bar's width (the scroll style's minimum width).
const CategoryPadding = 4
const ScrollBarWidth = 4

-- The toggle's icon size after icon_max_width (28), and its style margins (CheckButtonBox).
const ToggleIconWidth = 28
const ToggleIconHeight = 16
const ToggleMarginX = 6
const ToggleMarginY = 4

-- The separation of the buttons in a row (ButtonHBoxContainer).
const ButtonSeparation = 8

-- Rounds half away from zero, to whole pixels.
const function Round(Value: number): number
	return math.round(Value)
end

-- A control at Anchors and Offsets inside Parent, with whole-pixel edges. The result is in Parent's space.
const function Anchored(Parent: Rect, Anchors: Edges, Offsets: Edges): Rect
	const Left = Round(Anchors[1] * Parent.Width + Offsets[1])
	const Top = Round(Anchors[2] * Parent.Height + Offsets[2])
	const Right = Round(Anchors[3] * Parent.Width + Offsets[3])
	const Bottom = Round(Anchors[4] * Parent.Height + Offsets[4])

	return {
		X = Parent.X + Left,
		Y = Parent.Y + Top,
		Width = Right - Left,
		Height = Bottom - Top,
	}
end

-- The holder: the middle half of the screen, or its 1080p size (960 x 540) while that fits in three quarters of it, so a big
-- Menu Scale (a small layout screen) doesn't squeeze the rows and cut their values off.
-- @src scenes/main.tscn:Holder L159-167
const function HolderOf(ScreenWidth: number, ScreenHeight: number): Rect
	if ScreenWidth >= 1920 and ScreenHeight >= 1080 then
		return Anchored({ X = 0, Y = 0, Width = ScreenWidth, Height = ScreenHeight }, HolderAnchors, NoOffsets)
	end

	const Width = Round(math.max(0.5 * ScreenWidth, math.min(960, 0.75 * ScreenWidth)))
	const Height = Round(math.max(0.5 * ScreenHeight, math.min(540, 0.75 * ScreenHeight)))

	return {
		X = Round((ScreenWidth - Width) / 2),
		Y = Round((ScreenHeight - Height) / 2),
		Width = Width,
		Height = Height,
	}
end

-- The holder's panels, in the holder's space: the dim column and its separator, the sidebar, the header with its
-- title and profile controls, the categories, and the outline.
-- @src scenes/main.tscn:Holder L169-450
const function PanelsOf(HolderWidth: number, HolderHeight: number)
	const Holder = { X = 0, Y = 0, Width = HolderWidth, Height = HolderHeight }
	const Dim = Anchored(Holder, { 0, 0, 0.2, 1 }, { 0, HeaderHeight, 0, 0 })
	const Header = Anchored(Holder, { 0, 0, 1, 0 }, { 0, 0, 0, HeaderHeight })

	return {
		Dim = Dim,
		DimSeparator = Anchored(Dim, { 1, 0, 1, 1 }, { 0, 0, 1, 0 }),
		Sidebar = Anchored(Holder, { 0, 0, 0.2, 1 }, { 0, HeaderHeight, 0, 0 }),
		Categories = Anchored(Holder, { 0.2, 0, 1, 1 }, { 8, 48, -8, -8 }),
		Header = Header,
		Title = Anchored(Header, { 0, 0, 0.6, 1 }, { 8, 2, -8, 0 }),
		Profiles = Anchored(Header, { 0.75, 0, 1, 1 }, { 0, 8, -56, -8 }),
		DeleteProfile = Anchored(Header, { 1, 0, 1, 1 }, { -52, 10, -32, -10 }),
		CreateProfile = Anchored(Header, { 1, 0, 1, 1 }, { -28, 10, -8, -10 }),
		-- Godot has this edit just outside the holder, where a click beside it would close the menu: it sits in the header, left of the list.
		ProfileEdit = Anchored(Header, { 0.75, 0, 0.75, 1 }, { -136, 8, -8, -8 }),
		-- Not in the source (2026-11-10): the search field, in the header over the settings column (it starts where the rows do)
		-- and ends short of the profile name field.
		Search = Anchored(Header, { 0.2, 0, 0.75, 1 }, { 8, 8, -144, -8 }),
		Outline = Anchored(Holder, { 0, 0, 1, 1 }, NoOffsets),
	}
end

-- A setting row's controls, in the row's space (the row is RowWidth wide and RowHeight high).
-- @src scenes/main.tscn:SettingTemplate L220-319
const function RowControlsOf(RowWidth: number)
	const Row = { X = 0, Y = 0, Width = RowWidth, Height = RowHeight }
	const Toggle = Anchored(Row, { 0.9, 0, 0.9, 1 }, { 8, 0, 0, 0 })

	return {
		Title = Anchored(Row, { 0, 0, 0.3, 1 }, NoOffsets),
		Slider = Anchored(Row, { 0.3, 0, 0.9, 1 }, NoOffsets),
		SliderEdit = Anchored(Row, { 0.9, 0, 1, 1 }, { 8, 0, 0, 0 }),
		TextEdit = Anchored(Row, { 0.3, 0, 1, 1 }, NoOffsets),
		-- The toggle grows from its left edge to its minimum width; its height is the row's.
		Toggle = {
			X = Toggle.X,
			Y = 0,
			Width = math.max(Toggle.Width, ToggleIconWidth + 2 * ToggleMarginX),
			Height = RowHeight,
		},
		Option = Anchored(Row, { 0.8, 0, 1, 1 }, { 8, 4, 0, -4 }),
		ButtonRow = Anchored(Row, { 0.7, 0, 1, 1 }, { 0, 4, -4, -4 }),
	}
end

-- The cells of Count buttons across a row of Width (HBoxContainer children that expand equally), in the row's space.
-- Each cell's X and Width are whole pixels; the height is the row's.
-- @src scenes/main.tscn:ButtonHBoxContainer L309-319
const function ButtonCellsOf(Width: number, Count: number): { Rect }
	const Cells: { Rect } = {}
	const CellWidth = (Width - ButtonSeparation * (Count - 1)) / Count

	for Index = 0, Count - 1 do
		const Left = Round(Index * (CellWidth + ButtonSeparation))
		const Right = Round(Index * (CellWidth + ButtonSeparation) + CellWidth)

		table.insert(Cells, { X = Left, Y = 0, Width = Right - Left, Height = 0 })
	end

	return Cells
end

-- The top of setting row Index (0-based) inside a category's content.
const function RowTop(Index: number): number
	return Index * (RowHeight + RowGap)
end

-- The height of a category's content with Count setting rows (the VBoxContainer of rows, separated by RowGap).
const function ContentHeight(Count: number): number
	if Count <= 0 then
		return 0
	end

	return Count * RowHeight + (Count - 1) * RowGap
end

-- The top of sidebar button Index (0-based).
const function SidebarRowTop(Index: number): number
	return Index * SidebarRowHeight
end

-- A scroll area's inner rectangle: its content margin is inset on every side (the area is in its parent's space).
const function ScrollInner(Area: Rect, Padding: number): Rect
	return {
		X = Padding,
		Y = Padding,
		Width = math.max(0, Area.Width - 2 * Padding),
		Height = math.max(0, Area.Height - 2 * Padding),
	}
end

-- The vertical scroll bar's rectangle at the right edge of a scroll area's inner rectangle.
const function ScrollBarOf(Inner: Rect): Rect
	return {
		X = Inner.X + Inner.Width - ScrollBarWidth,
		Y = Inner.Y,
		Width = ScrollBarWidth,
		Height = Inner.Height,
	}
end

-- The width the content of a scroll area gets: the bar's width is taken when the content is taller than the inner area.
const function ScrollContentWidth(Inner: Rect, ContentHeightValue: number): number
	if ContentHeightValue > Inner.Height then
		return Inner.Width - ScrollBarWidth
	end

	return Inner.Width
end

return {
	Round = Round,
	Anchored = Anchored,
	HolderOf = HolderOf,
	PanelsOf = PanelsOf,
	RowControlsOf = RowControlsOf,
	ButtonCellsOf = ButtonCellsOf,
	RowTop = RowTop,
	ContentHeight = ContentHeight,
	SidebarRowTop = SidebarRowTop,
	ScrollInner = ScrollInner,
	ScrollBarOf = ScrollBarOf,
	ScrollContentWidth = ScrollContentWidth,
	ScrollBarWidth = ScrollBarWidth,
	CategoryPadding = CategoryPadding,
	RowHeight = RowHeight,
	SidebarRowHeight = SidebarRowHeight,
	HeaderHeight = HeaderHeight,
	ToggleIconWidth = ToggleIconWidth,
	ToggleIconHeight = ToggleIconHeight,
	ToggleMarginX = ToggleMarginX,
	ToggleMarginY = ToggleMarginY,
}
