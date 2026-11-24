--!strict
--!optimize 2

--[[
	The settings menu's OptionButton (Godot option_button.cpp with theme.tres) and its PopupMenu: a button that shows the
	selected item centered, with a down arrow at its right, and a list under it (or above it when there is no room below)
	that picks an item. Choosing an item selects it and calls OnItemSelected(index); a press outside the list closes it.

	Design Notes
		Items and the selection (0-based, -1 for none) are the button's state. Select does not call OnItemSelected, as Godot's
		select() does not. AddItem selects the first item when none is selected (Godot's add_item).
		An open list is a modal (Input.PushModal): the menu under it gets no hover, press or wheel, and the list takes the
		keys, as Godot's popup window does. Up and Down move the highlight, Enter, KpEnter and Space choose it. Escape is the
		menu's (SettingsMenu closes an open list first). The selected item has a radio mark, as Godot's OptionButton adds its
		items as radio check items. A list taller than the room on screen scrolls, with the wheel over it or with its scroll
		bar, and shows that it does: the panel gains a gutter at its left (the rows keep their width) for a pink bar at its
		right, set in from the border so it isn't taken for the settings menu's own white bar beside the list. The thumb's
		length is the visible share of the list; it turns hot pink under the pointer and while held. A press anywhere in the
		gutter takes the thumb (on it, where pressed; beside it, by its middle) and drags it. A fade with an arrow at the top
		and the bottom of the panel shows that more of the list is above or below. A list that fits shows none of these.
		A row is a transparent TextButton over the panel; the highlight is one hover frame that moves to the highlighted row
		(the PopupMenu hover style), and the highlighted row's text is the hover color.
		The list is a child of the screen's root, drawn above the menu's holder.
		DEVIATION(unverified): the arrow is an antialiased chevron image (as the real game draws it; Godot's
		option_button_arrow size is not in reference/engine); 10 x 6 pixels, 8 pixels from the right edge. The row height is the font's line
		height plus the PopupMenu v_separation (4), and the item padding is 2 on each side.
		DEVIATION(unverified): the radio mark is drawn as a 16 pixel ring with an 8 pixel dot (Godot's radio icons are generated
		by the default theme; their size is not in reference/engine), with the h_separation (4) after it.
		DEVIATION(unverified): the highlight wraps from the last row to the first and back (PopupMenu's keyboard navigation).
]]

const UserInputService = game:GetService("UserInputService")

const Buttons = require("./Buttons")
const Chevron = require("../Chevron")
const Scale = require("../Scale")
const Draw = require("./Draw")
const Fade = require("./Fade")
const Geometry = require("./Geometry")
const Input = require("../Input")
const Items = require("../Item")
const Look = require("./Look")
const Style = require("../Style")
const ScrollMath = require("./ScrollMath")

type Rect = Geometry.Rect

export type Dropdown = {
	Button: Buttons.Button,
	Arrow: Frame,
	Root: Frame,
	Overlay: Fade.Fade,
	Font: Font,
	FontSize: number,
	Items: { string },
	Selected: number,
	Popup: TextButton?,
	Panel: Frame?,
	Content: Frame?,
	Hover: Frame?,
	Rows: { TextButton },
	Highlight: number,
	RowHeight: number,
	Offset: number,
	Viewport: number,
	ContentHeight: number,
	-- the open list's scroll bar track and its thumb (only while the list is taller than its panel)
	Track: Frame?,
	Thumb: Frame?,
	-- how far below the thumb's top the pointer holds it, while the thumb is dragged
	DragGrab: number?,
	-- whether the pointer is over the bar's gutter (the thumb shows hot)
	BarHover: boolean,
	-- the fades with arrows at the list's ends, shown while more of it is above or below
	TopCue: Frame?,
	BottomCue: Frame?,
	Disconnect: (() -> ())?,
	OnItemSelected: (Index: number) -> (),
}

const ArrowStroke = 1.5

-- The scroll bar of a list taller than its panel (a player's report: the first one, the settings menu's 4 pixel white thumb
-- right inside the border, was taken for the menu's own white bar just outside it and was hard to take hold of). BarWidth
-- wide on a faint track, in a gutter of BarGutter the panel gains at its left, BarInset clear of the border: pink, the
-- sliders' color, hot pink under the pointer and while held. The thumb is never shorter than MinThumb.
const BarWidth = 8
const BarInset = 6
const BarGutter = BarWidth + BarInset
const BarTrack = Look.Rgba(1, 1, 1, 0.1)
const BarThumb = Look.Pink
const BarThumbHot = Look.SliderFillHot
const MinThumb = 24

-- The fades at the top and the bottom of a list that scrolls, each with an arrow, shown while more of the list is past them.
const CueHeight = 28
const CueArrowWidth = 18
const CueArrowHeight = 10
const CueArrowStroke = 2
const CueArrowInset = 4
const CueArrow = Look.SliderFillHot

-- The chevron at the button's right edge, the color of the font.
const function NewArrow(Parent: Instance, ZIndex: number): Frame
	const Arrow = Instance.new("Frame")

	Arrow.Name = "Arrow"
	Arrow.BackgroundTransparency = 1
	Arrow.BorderSizePixel = 0
	Arrow.ZIndex = ZIndex
	Arrow.Active = false
	Arrow.Size = UDim2.fromOffset(Look.ArrowWidth, Look.ArrowHeight)
	Arrow.AnchorPoint = Vector2.xAxis
	Arrow.Position = UDim2.new(1, -Look.ArrowMargin, 0.5, -Look.ArrowHeight // 2)
	Chevron.New(Arrow, Look.ArrowWidth, Look.ArrowHeight, ArrowStroke, Look.FontNormal.Color, 1 - Look.FontNormal.Alpha)
	Arrow.Parent = Parent

	return Arrow
end

-- The height of one line of the font (the "W" line height, as Godot's font height), whole pixels.
const function LineHeight(Font: Font, Size: number): number
	return math.round(Items.Measure("W", Font, Size).y)
end

-- Shows the selected item's text in the button (none when nothing is selected).
const function Refresh(Dropdown: Dropdown)
	Dropdown.Button.Object.Text = if Dropdown.Selected >= 0 then Dropdown.Items[Dropdown.Selected + 1] else ""
end

-- Whether a point (in Input.GetGuiMousePosition's space) is inside a GUI object's rectangle.
const function PointInside(Gui: GuiObject, Point: vector): boolean
	const Origin = Scale.PositionOf(Gui)
	const Size = Scale.SizeOf(Gui)

	return Point.x >= Origin.x and Point.x < Origin.x + Size.x and Point.y >= Origin.y and Point.y < Origin.y + Size.y
end

-- Shows the highlighted row: its text in the hover color, and the hover frame over it.
const function ShowHighlight(Dropdown: Dropdown)
	const Hover = Dropdown.Hover

	if not Hover then
		return
	end

	for Index, Row in Dropdown.Rows do
		const Lit = Index - 1 == Dropdown.Highlight

		Row.TextColor3 = if Lit then Look.FontWhite.Color else Look.FontNormal.Color

		if Lit then
			Hover.Position = UDim2.fromOffset(Look.PopupMargin, Row.Position.Y.Offset)
		end
	end

	Hover.Visible = Dropdown.Highlight >= 0
end

-- The thumb's length along a track of Track pixels: the visible share of the list, at least MinThumb (at most the track).
const function ThumbLengthOf(Dropdown: Dropdown, Track: number): number
	return math.min(Track, math.max(MinThumb, ScrollMath.ThumbLength(Track, Dropdown.ContentHeight, Dropdown.Viewport)))
end

-- Paints the thumb: hot pink while it is held or the pointer is over the bar, else pink (its color only: its transparency
-- belongs to the menu's fade).
const function PaintThumb(Dropdown: Dropdown)
	const Thumb = Dropdown.Thumb

	if Thumb then
		const Hot = Dropdown.DragGrab ~= nil or Dropdown.BarHover

		Thumb.BackgroundColor3 = if Hot then BarThumbHot.Color else BarThumb.Color
	end
end

-- A fade at the top of the panel (Down false) or at its bottom, Width wide (the rows' room), black at the panel's edge and
-- clear toward the rows, with an arrow at its middle pointing past the edge. Hidden until the list can scroll that way.
const function NewCue(Panel: Frame, Name: string, Y: number, Width: number, Down: boolean): Frame
	const Cue = Draw.Frame(Panel, Name, { X = 0, Y = Y, Width = Width, Height = CueHeight }, 4, false)
	const Gradient = Instance.new("UIGradient")

	Draw.Fill(Cue, Look.PopupFill)
	Draw.Corner(Cue, Look.Corner)
	Gradient.Rotation = 90
	Gradient.Transparency = if Down then NumberSequence.new(1, 0) else NumberSequence.new(0, 1)
	Gradient.Parent = Cue

	const Arrow = Instance.new("Frame")

	Arrow.Name = "Arrow"
	Arrow.BackgroundTransparency = 1
	Arrow.BorderSizePixel = 0
	Arrow.Active = false
	Arrow.Size = UDim2.fromOffset(CueArrowWidth, CueArrowHeight)
	Arrow.Position = UDim2.fromOffset((Width - CueArrowWidth) // 2, if Down then CueHeight - CueArrowInset - CueArrowHeight else CueArrowInset)
	Chevron.New(Arrow, CueArrowWidth, CueArrowHeight, CueArrowStroke, CueArrow.Color, 1 - CueArrow.Alpha)

	-- (Chevron draws a down arrow: its strokes turn the other way for an up one)
	if not Down then
		for _, Stroke in Arrow:GetChildren() do
			if Stroke:IsA("Frame") then
				Stroke.Rotation = -Stroke.Rotation
			end
		end
	end

	Arrow.Parent = Cue
	Cue.Visible = false

	return Cue
end

-- Shows the fade at each end of the list that has more of the list past it.
const function ShowCues(Dropdown: Dropdown)
	const TopCue = Dropdown.TopCue
	const BottomCue = Dropdown.BottomCue
	const Max = ScrollMath.MaxOffset(Dropdown.ContentHeight, Dropdown.Viewport)

	if TopCue then
		TopCue.Visible = Dropdown.Offset > 0.5
	end

	if BottomCue then
		BottomCue.Visible = Dropdown.Offset < Max - 0.5
	end
end

-- Moves the scroll bar's thumb to the list's offset, in whole pixels, and shows the fades of the ends with more past them
-- (a list that fits its panel has neither).
const function DrawBar(Dropdown: Dropdown)
	ShowCues(Dropdown)

	const Track = Dropdown.Track
	const Thumb = Dropdown.Thumb

	if not Track or not Thumb then
		return
	end

	const TrackLength = Track.Size.Y.Offset
	const Length = math.round(ThumbLengthOf(Dropdown, TrackLength))
	const Max = ScrollMath.MaxOffset(Dropdown.ContentHeight, Dropdown.Viewport)
	const Top = math.round(ScrollMath.ThumbTop(TrackLength, Length, Dropdown.Offset, Max))

	Draw.Place(Thumb, { X = 0, Y = Top, Width = BarWidth, Height = Length })
end

-- Scrolls the list to an offset, clamped to the list's content and drawn in whole pixels; the bar's thumb follows.
const function SetOffset(Dropdown: Dropdown, Offset: number)
	Dropdown.Offset = ScrollMath.ClampOffset(Offset, Dropdown.ContentHeight, Dropdown.Viewport)

	if Dropdown.Content then
		Dropdown.Content.Position = UDim2.fromOffset(0, -math.round(Dropdown.Offset))
	end

	DrawBar(Dropdown)
end

-- Scrolls the list so that the thumb's top is Top pixels down its track (the thumb follows the pointer while it is held).
const function DragTo(Dropdown: Dropdown, Top: number)
	const Track = Dropdown.Track

	if not Track then
		return
	end

	const TrackLength = Track.Size.Y.Offset
	const Length = math.round(ThumbLengthOf(Dropdown, TrackLength))
	const Max = ScrollMath.MaxOffset(Dropdown.ContentHeight, Dropdown.Viewport)

	SetOffset(Dropdown, math.round(ScrollMath.OffsetForThumb(TrackLength, Length, Top, Max)))
end

-- Scrolls the list just far enough that a row (0-based) is inside its panel, clear of the fades at its ends (at the very
-- top or bottom of the list the fade there is hidden, so the row shows whole there too).
const function ShowRow(Dropdown: Dropdown, Index: number)
	const Margin = Look.PopupMargin
	const Room = Margin + (if Dropdown.Track then CueHeight else 0)
	const RowTop = Margin + Index * Dropdown.RowHeight
	const RowBottom = RowTop + Dropdown.RowHeight - Look.PopupSeparation
	const Offset = Dropdown.Offset

	if RowTop - Room < Offset then
		SetOffset(Dropdown, RowTop - Room)
	elseif RowBottom + Room > Offset + Dropdown.Viewport then
		SetOffset(Dropdown, RowBottom + Room - Dropdown.Viewport)
	end
end

-- Moves the highlight by Step rows (wrapping at the ends) and scrolls it into view.
const function MoveHighlight(Dropdown: Dropdown, Step: number)
	const Count = #Dropdown.Items

	if Count == 0 then
		return
	end

	local Next = Dropdown.Highlight + Step

	if Next < 0 then
		Next = Count - 1
	elseif Next >= Count then
		Next = 0
	end

	Dropdown.Highlight = Next

	ShowHighlight(Dropdown)
	ShowRow(Dropdown, Next)
end

-- Closes the list, if it is open: its input and modal go, and its popup is destroyed.
const function Close(Dropdown: Dropdown)
	const Popup = Dropdown.Popup

	if not Popup then
		return
	end

	const Disconnect = Dropdown.Disconnect

	Dropdown.Popup = nil
	Dropdown.Panel = nil
	Dropdown.Content = nil
	Dropdown.Hover = nil
	Dropdown.Track = nil
	Dropdown.Thumb = nil
	Dropdown.DragGrab = nil
	Dropdown.BarHover = false
	Dropdown.TopCue = nil
	Dropdown.BottomCue = nil
	Dropdown.Disconnect = nil
	table.clear(Dropdown.Rows)

	if Disconnect then
		Disconnect()
	end

	Input.PopModal(Popup)
	Fade.Forget(Dropdown.Overlay, Popup)
	Popup:Destroy()
end

-- Selects an item (0-based) and closes the list: the choice of a row or of the keyboard.
const function Choose(Dropdown: Dropdown, Index: number)
	Close(Dropdown)

	Dropdown.Selected = Index
	Refresh(Dropdown)
	Dropdown.OnItemSelected(Index)
end

-- The open list's input (Input.OnInput, modal): Up and Down move the highlight, Enter, KpEnter and Space choose it, and
-- the wheel scrolls a list taller than its room while the pointer is over the panel.
const function HandleInput(Dropdown: Dropdown, Popup: TextButton, Event: Input.InputEvent)
	if not Event.Pressed or not Input.IsTopModal(Popup) then
		return
	end

	if Event.Class == "InputEventKey" then
		if Event.Keycode == Input.Key.Down then
			MoveHighlight(Dropdown, 1)
		elseif Event.Keycode == Input.Key.Up then
			MoveHighlight(Dropdown, -1)
		elseif Event.Keycode == Input.Key.Enter or Event.Keycode == Input.Key.KpEnter or Event.Keycode == Input.Key.Space then
			if Dropdown.Highlight >= 0 then
				Choose(Dropdown, Dropdown.Highlight)
			end
		end
	elseif Event.Class == "InputEventMouseButton" and (Event.ButtonIndex == Input.MouseButton.WheelUp or Event.ButtonIndex == Input.MouseButton.WheelDown) then
		const Panel = Dropdown.Panel

		if Panel and PointInside(Panel, Input.GetGuiMousePosition()) then
			const Direction = if Event.ButtonIndex == Input.MouseButton.WheelUp then 1 else -1

			SetOffset(Dropdown, ScrollMath.WheelOffset(Dropdown.Offset, Direction, Dropdown.ContentHeight, Dropdown.Viewport))
		end
	end
end

-- Opens the list under the button, or above it when it does not fit below and fits above. A list that fits neither takes
-- the larger room and scrolls. The list is a modal behind a full-root backdrop; a press on the backdrop closes it.
const function Open(Dropdown: Dropdown)
	Close(Dropdown)

	const Button = Dropdown.Button.Object
	const Margin = Look.PopupMargin
	const RowHeight = LineHeight(Look.Fonts.Default, Look.Sizes.Body) + Look.PopupSeparation
	const Origin = Scale.PositionOf(Button) - Scale.PositionOf(Dropdown.Root)
	const RootSize = Scale.SizeOf(Dropdown.Root)
	const Width = Scale.SizeOf(Button).x
	const ContentHeight = 2 * Margin + #Dropdown.Items * RowHeight - Look.PopupSeparation
	const BelowTop = Origin.y + Scale.SizeOf(Button).y
	const RoomBelow = RootSize.y - BelowTop
	const RoomAbove = Origin.y

	local Top = BelowTop
	local PanelHeight = ContentHeight

	if ContentHeight > RoomBelow and ContentHeight <= RoomAbove then
		Top = Origin.y - ContentHeight
	elseif ContentHeight > RoomBelow and RoomBelow >= RoomAbove then
		PanelHeight = RoomBelow
	elseif ContentHeight > RoomBelow then
		Top = 0
		PanelHeight = RoomAbove
	end

	PanelHeight = math.max(PanelHeight, 2 * Margin)

	-- (a list taller than its panel scrolls: the panel gains the bar's gutter at its left, so the rows keep their width and
	-- the bar is at the right, under the button's arrow)
	const Scrolls = ContentHeight - PanelHeight >= 1
	const Gutter = if Scrolls then BarGutter else 0
	const PanelWidth = Width + Gutter
	const PanelX = math.max(0, Origin.x - Gutter)
	const RowWidth = Width - 2 * Margin

	const Backdrop = Instance.new("TextButton")

	Backdrop.Name = "PopupBackdrop"
	Backdrop.Text = ""
	Backdrop.AutoButtonColor = false
	Backdrop.BackgroundTransparency = 1
	Backdrop.BorderSizePixel = 0
	Backdrop.ZIndex = 3
	Backdrop.Active = true
	Draw.Place(Backdrop, { X = 0, Y = 0, Width = RootSize.x, Height = RootSize.y })
	Backdrop.Parent = Dropdown.Root
	Backdrop.MouseButton1Down:Connect(function()
		Close(Dropdown)
	end)
	Backdrop.MouseButton2Down:Connect(function()
		Close(Dropdown)
	end)

	const Panel = Draw.Frame(Backdrop, "Panel", { X = PanelX, Y = Top, Width = PanelWidth, Height = PanelHeight }, 4, true)

	Panel.ClipsDescendants = true

	Draw.Fill(Panel, Look.PopupFill)
	Draw.Corner(Panel, Look.Corner)
	Draw.Stroke(Panel, Look.PopupBorder, Look.PopupBorderThickness)

	const Content = Draw.Frame(Panel, "Items", { X = 0, Y = 0, Width = Width, Height = ContentHeight }, 1, false)
	const Hover = Draw.Frame(Content, "Hover", { X = Margin, Y = 0, Width = RowWidth, Height = RowHeight - Look.PopupSeparation }, 1, false)

	Hover.Visible = false
	Draw.Fill(Hover, Look.PopupHoverFill)
	Draw.Corner(Hover, Look.Corner)

	const Rows: { TextButton } = {}
	const RowBodyHeight = RowHeight - Look.PopupSeparation

	for Index, Text in Dropdown.Items do
		const RowTop = Margin + (Index - 1) * RowHeight
		const Row = Instance.new("TextButton")

		Row.Name = `Item{Index - 1}`
		Row.Text = Text
		Row.FontFace = Look.Fonts.Default
		Row.TextSize = Style.TextSizeOf(Look.Fonts.Default, Look.Sizes.Body)
		Row.TextColor3 = Look.FontNormal.Color
		Row.TextXAlignment = Enum.TextXAlignment.Left
		Row.TextYAlignment = Enum.TextYAlignment.Center
		Row.TextTruncate = Enum.TextTruncate.AtEnd
		Row.AutoButtonColor = false
		Row.BackgroundTransparency = 1
		Row.BorderSizePixel = 0
		Row.ZIndex = 3
		Row.Active = true
		Draw.Place(Row, { X = Margin, Y = RowTop, Width = RowWidth, Height = RowBodyHeight })
		Row.Parent = Content

		const Inset = Instance.new("UIPadding")

		Inset.PaddingLeft = UDim.new(0, Look.PopupItemPadding + Look.PopupRadioSize + Look.PopupHSeparation)
		Inset.PaddingRight = UDim.new(0, Look.PopupItemPadding)
		Inset.Parent = Row

		const Ring = Draw.Frame(Content, `Radio{Index - 1}`, {
			X = Margin + Look.PopupItemPadding,
			Y = RowTop + (RowBodyHeight - Look.PopupRadioSize) // 2,
			Width = Look.PopupRadioSize,
			Height = Look.PopupRadioSize,
		}, 2, false)

		Draw.Corner(Ring, Look.PopupRadioSize // 2)
		Draw.Stroke(Ring, Look.FontNormal, Look.PopupRadioThickness)

		if Index - 1 == Dropdown.Selected then
			const DotInset = (Look.PopupRadioSize - Look.PopupRadioDot) // 2
			const Dot = Draw.Frame(Ring, "Dot", { X = DotInset, Y = DotInset, Width = Look.PopupRadioDot, Height = Look.PopupRadioDot }, 2, false)

			Draw.Fill(Dot, Look.FontNormal)
			Draw.Corner(Dot, Look.PopupRadioDot // 2)
		end

		table.insert(Rows, Row)

		Row.MouseEnter:Connect(function()
			Dropdown.Highlight = Index - 1
			ShowHighlight(Dropdown)
		end)
		Row.Activated:Connect(function()
			Choose(Dropdown, Index - 1)
		end)
	end

	-- The scroll bar of a list that scrolls, in the gutter at the panel's right, and the fades at its ends. The whole gutter,
	-- from the rows' edge to the border, takes presses: a press on the thumb holds it where pressed, a press beside it brings
	-- the thumb's middle to the pointer, and the thumb then follows the pointer until the press ends.
	local Hit: TextButton? = nil
	local Track: Frame? = nil
	local Thumb: Frame? = nil
	local TopCue: Frame? = nil
	local BottomCue: Frame? = nil

	if Scrolls then
		const Bar = Instance.new("TextButton")

		Bar.Name = "ScrollBar"
		Bar.Text = ""
		Bar.AutoButtonColor = false
		Bar.BackgroundTransparency = 1
		Bar.BorderSizePixel = 0
		Bar.ZIndex = 5
		Bar.Active = true
		Draw.Place(Bar, { X = Width - Margin, Y = 0, Width = PanelWidth - Width + Margin, Height = PanelHeight })
		Bar.Parent = Panel

		const Line = Draw.Frame(Bar, "Track", { X = Margin, Y = Margin, Width = BarWidth, Height = PanelHeight - 2 * Margin }, 1, false)

		Draw.Fill(Line, BarTrack)
		Draw.Corner(Line, BarWidth // 2)

		const Grabber = Draw.Frame(Line, "Thumb", { X = 0, Y = 0, Width = BarWidth, Height = 0 }, 1, false)

		Draw.Fill(Grabber, BarThumb)
		Draw.Corner(Grabber, BarWidth // 2)

		Hit = Bar
		Track = Line
		Thumb = Grabber
		TopCue = NewCue(Panel, "MoreAbove", 0, Width, false)
		BottomCue = NewCue(Panel, "MoreBelow", PanelHeight - CueHeight, Width, true)
	end

	Dropdown.Popup = Backdrop
	Dropdown.Panel = Panel
	Dropdown.Content = Content
	Dropdown.Hover = Hover
	Dropdown.Track = Track
	Dropdown.Thumb = Thumb
	Dropdown.DragGrab = nil
	Dropdown.BarHover = false
	Dropdown.TopCue = TopCue
	Dropdown.BottomCue = BottomCue
	Dropdown.Rows = Rows
	Dropdown.Highlight = Dropdown.Selected
	Dropdown.RowHeight = RowHeight
	Dropdown.Viewport = PanelHeight
	Dropdown.ContentHeight = ContentHeight

	SetOffset(Dropdown, 0)
	ShowHighlight(Dropdown)

	if Dropdown.Highlight >= 0 then
		ShowRow(Dropdown, Dropdown.Highlight)
	end

	Fade.Track(Dropdown.Overlay, Backdrop)

	const StopInput = Input.OnInput(function(Event: Input.InputEvent)
		HandleInput(Dropdown, Backdrop, Event)
	end, true)
	const Connections: { RBXScriptConnection } = {}

	if Hit then
		const Bar: TextButton = Hit

		table.insert(Connections, Bar.MouseButton1Down:Connect(function()
			const Line = Dropdown.Track
			const Grabber = Dropdown.Thumb

			if not Line or not Grabber or not Input.IsTopModal(Backdrop) then
				return
			end

			const Pointer = Input.GetGuiMousePosition().y - Scale.PositionOf(Line).y
			const Top = Grabber.Position.Y.Offset
			const Length = Grabber.Size.Y.Offset
			const Grab = if Pointer >= Top and Pointer < Top + Length then Pointer - Top else Length / 2

			Dropdown.DragGrab = Grab
			DragTo(Dropdown, Pointer - Grab)
			PaintThumb(Dropdown)
		end))
		table.insert(Connections, Bar.MouseEnter:Connect(function()
			Dropdown.BarHover = true
			PaintThumb(Dropdown)
		end))
		table.insert(Connections, Bar.MouseLeave:Connect(function()
			Dropdown.BarHover = false
			PaintThumb(Dropdown)
		end))
		table.insert(Connections, UserInputService.InputChanged:Connect(function(Event: InputObject)
			const Grab = Dropdown.DragGrab
			const Line = Dropdown.Track
			const Moved = Event.UserInputType == Enum.UserInputType.MouseMovement or Event.UserInputType == Enum.UserInputType.Touch

			if Grab and Line and Moved then
				DragTo(Dropdown, Input.GetGuiMousePosition().y - Scale.PositionOf(Line).y - Grab)
			end
		end))
		table.insert(Connections, UserInputService.InputEnded:Connect(function(Event: InputObject)
			const Ended = Event.UserInputType == Enum.UserInputType.MouseButton1 or Event.UserInputType == Enum.UserInputType.Touch

			if Dropdown.DragGrab and Ended then
				Dropdown.DragGrab = nil
				PaintThumb(Dropdown)
			end
		end))
	end

	Dropdown.Disconnect = function()
		StopInput()

		for _, Connection in Connections do
			Connection:Disconnect()
		end
	end

	Input.PushModal(Backdrop)
end

-- Creates the option button at Rect, with its arrow. Root is the screen's root the list is drawn in.
const function New(Parent: Instance, Name: string, Rect: Rect, ZIndex: number, Overlay: Fade.Fade, Root: Frame, Font: Font, FontSize: number, OnItemSelected: (Index: number) -> ()): Dropdown
	const Button = Buttons.New(Parent, {
		Name = Name,
		Rect = Rect,
		ZIndex = ZIndex,
		Style = Look.OptionButtonStyle,
		Text = "",
		Font = Font,
		FontSize = FontSize,
		Align = Enum.TextXAlignment.Center,
		Overlay = Overlay,
		OnActivated = nil,
	})

	-- The text is centered in the box left of the arrow.
	Button.Padding.PaddingRight = UDim.new(0, Look.ArrowMargin + Look.ArrowWidth)

	const Arrow = NewArrow(Button.Object, ZIndex + 1)
	Fade.Track(Overlay, Arrow)

	const Dropdown = {
		Button = Button,
		Arrow = Arrow,
		Root = Root,
		Overlay = Overlay,
		Font = Font,
		FontSize = FontSize,
		Items = {},
		Selected = -1,
		Popup = nil,
		Panel = nil,
		Content = nil,
		Hover = nil,
		Rows = {},
		Highlight = -1,
		RowHeight = 0,
		Offset = 0,
		Viewport = 0,
		ContentHeight = 0,
		Track = nil,
		Thumb = nil,
		DragGrab = nil,
		BarHover = false,
		TopCue = nil,
		BottomCue = nil,
		Disconnect = nil,
		OnItemSelected = OnItemSelected,
	} :: Dropdown

	Button.Object.Activated:Connect(function()
		if Dropdown.Popup then
			Close(Dropdown)
		else
			Open(Dropdown)
		end
	end)

	return Dropdown
end

-- Whether the list is open.
const function IsOpen(Dropdown: Dropdown): boolean
	return Dropdown.Popup ~= nil
end

-- Appends an item, selecting the first one when none is selected.
const function AddItem(Dropdown: Dropdown, Text: string)
	table.insert(Dropdown.Items, Text)

	if Dropdown.Selected < 0 then
		Dropdown.Selected = 0
	end

	Refresh(Dropdown)
end

-- Removes the item at Index (0-based). The selection follows the item that stays (Godot's remove_item).
const function RemoveItem(Dropdown: Dropdown, Index: number)
	table.remove(Dropdown.Items, Index + 1)

	if Dropdown.Selected > Index then
		Dropdown.Selected -= 1
	elseif Dropdown.Selected == Index then
		Dropdown.Selected = math.min(Index, #Dropdown.Items - 1)
	end

	Refresh(Dropdown)
end

-- Removes every item and clears the selection.
const function Clear(Dropdown: Dropdown)
	table.clear(Dropdown.Items)
	Dropdown.Selected = -1
	Refresh(Dropdown)
end

-- Selects the item at Index (0-based) without calling OnItemSelected. An index past the items is ignored.
const function Select(Dropdown: Dropdown, Index: number)
	if Index < 0 or Index >= #Dropdown.Items then
		return
	end

	Dropdown.Selected = Index
	Refresh(Dropdown)
end

-- The number of items.
const function ItemCount(Dropdown: Dropdown): number
	return #Dropdown.Items
end

-- The text of the item at Index (0-based).
const function ItemText(Dropdown: Dropdown, Index: number): string
	return Dropdown.Items[Index + 1]
end

-- The selected item's index (0-based), or -1.
const function Selected(Dropdown: Dropdown): number
	return Dropdown.Selected
end

-- Places the button at Rect (its row changed size); the arrow follows the button's right edge.
const function Place(Dropdown: Dropdown, Rect: Rect)
	Buttons.Place(Dropdown.Button, Rect)
end

return {
	New = New,
	Close = Close,
	IsOpen = IsOpen,
	AddItem = AddItem,
	RemoveItem = RemoveItem,
	Clear = Clear,
	Select = Select,
	ItemCount = ItemCount,
	ItemText = ItemText,
	Selected = Selected,
	Place = Place,
}
