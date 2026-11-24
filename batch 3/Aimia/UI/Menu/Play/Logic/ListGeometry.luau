--!strict
--!optimize 2

--[[
	The geometry of MapList (scripts/ui/menu/play/MapList.cs): maps per row, scroll length, row positions and z order,
	scroll bar anchors, the scroll that brings a map into view, and the centering factor of MapButtonWide. Roblox-free:
	MapList and MapButtonWide apply the results to their nodes.

	Design Notes
		C# int divisions (maps per row, row index of a map) are TruncDiv32, which errors on a zero divisor as the source
		throws. The (int) cast of the grid's width is TruncInt32.
		Positions and sizes are doubles (DEVIATION(float)): the source's float32 rounding of a row position is below a pixel.
		ContainerTops writes into the table the caller reuses every frame, so the frame allocates nothing.
]]

const Numbers = require("../../../../Numbers")

-- MapList.ListLayout: List is one column of wide buttons, Grid is rows of square buttons.
const ListLayout = {
	List = 0,
	Grid = 1,
}

-- @src scripts/ui/menu/play/MapList.cs:_Process L170-357
const function ButtonsPerContainer(Layout: number, Width: number, MinimumSize: number, Spacing: number): number
	if Layout == ListLayout.List then
		return 1
	end

	return Numbers.TruncInt32(Width / (MinimumSize + Spacing))
end

-- @src scripts/ui/menu/play/MapList.cs:_Process L170-357
const function ScrollLength(
	Layout: number,
	Count: number,
	PerContainer: number,
	MinimumSize: number,
	Spacing: number,
	Height: number,
	HoverSize: number,
	SelectSize: number
): number
	const Rows = Numbers.TruncDiv32(Count, PerContainer)
	local Length = math.max(0, Rows * (MinimumSize + Spacing) - Spacing - Height) + HoverSize + SelectSize

	if Layout == ListLayout.Grid then
		Length += MinimumSize + HoverSize + SelectSize
	end

	return Length
end

-- The tops of the drawn rows (MapList._Process, second pass) into Tops, from their size offsets (the rows' height beyond
-- the minimum) and the index of the first drawn row. A row sits at its index on the scroll; half the offsets of the rows
-- above it and of the rows below it shift it, so a grown row pushes its neighbours apart evenly.
-- @src scripts/ui/menu/play/MapList.cs:_Process L170-357
const function ContainerTops(
	Tops: { number },
	SizeOffsets: { number },
	FirstIndex: number,
	MinimumSize: number,
	Spacing: number,
	HoverSize: number,
	SelectSize: number,
	Scroll: number
)
	local DownOffset = 0
	local UpOffset = 0

	for _, SizeOffset in SizeOffsets do
		DownOffset += SizeOffset
	end

	for Row, SizeOffset in SizeOffsets do
		const Index = Row - 1 + FirstIndex
		local Top = Index * (MinimumSize + Spacing) - Scroll + (MinimumSize + HoverSize + SelectSize) / 2

		DownOffset -= SizeOffset
		Top += (UpOffset - DownOffset) / 2
		UpOffset += SizeOffset
		Tops[Row] = Top
	end
end

-- The z order of a row: the first and the last row are on top (1), the others behind (0).
-- @src scripts/ui/menu/play/MapList.cs:_Process L170-357
const function ZIndex(Index: number, Count: number, PerContainer: number): number
	if Index == 0 or Index == math.ceil(Count / PerContainer) - 1 then
		return 1
	end

	return 0
end

-- The scroll bar's anchors (top, bottom): its top follows the scroll, its length is the visible share of the scroll.
-- @src scripts/ui/menu/play/MapList.cs:_Process L170-357
const function ScrollBarAnchors(TargetScroll: number, ElasticOffset: number, Length: number, Height: number): (number, number)
	const Top = math.max(0, (TargetScroll - ElasticOffset) / (Length + Height))

	return Top, math.min(1, Top + Height / (Length + Height))
end

-- The scroll that centers a map in the view (MapList.Focus): Index is its 0-based place in Maps, -1 when it is absent.
-- @src scripts/ui/menu/play/MapList.cs:Focus L442-451
const function FocusScroll(Index: number, PerContainer: number, MinimumSize: number, Spacing: number, Height: number): number
	return Numbers.TruncDiv32(Index, PerContainer) * (MinimumSize + Spacing) + MinimumSize / 2 - Height / 2
end

-- MapButtonWide's centering factor: cos(pi / 2 * d), where d is the button's centre distance from the list's middle over
-- half the list plus half the minimum size. 1 at the middle, falling toward the edges.
-- @src scripts/ui/menu/play/MapButtonWide.cs:_Process L27-41
const function CenterFactor(ButtonY: number, ButtonHeight: number, ListY: number, ListHeight: number, MinimumSize: number): number
	const HalfList = ListHeight / 2
	const Distance = math.abs((ButtonY - ListY + ButtonHeight / 2) - HalfList) / (HalfList + MinimumSize / 2)

	return math.cos(math.pi * Distance / 2)
end

return {
	ListLayout = ListLayout,
	ButtonsPerContainer = ButtonsPerContainer,
	ScrollLength = ScrollLength,
	ContainerTops = ContainerTops,
	ZIndex = ZIndex,
	ScrollBarAnchors = ScrollBarAnchors,
	FocusScroll = FocusScroll,
	CenterFactor = CenterFactor,
}
