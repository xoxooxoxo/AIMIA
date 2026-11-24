--!strict
--!optimize 2

--[[
	A scroll area of the settings menu (Godot ScrollContainer with a themed VScrollBar): a clipping frame over its content,
	and a thin vertical bar at its right edge that shows only when the content is taller than the area.

	Design Notes
		The bar is 4 pixels wide (the scroll style's minimum width). Its track is black at 86%; its thumb is white with rounded
		right corners only (grabber_highlight and grabber_pressed are the same style, so there is no hover tint). The thumb is
		a rounded frame 8 pixels wide, clipped to its right 4 pixels, so its left corners stay square.
		The wheel scrolls by ScrollMath.WheelStep while the pointer is over the area and the menu is shown. A press on the track
		outside the thumb pages toward the press; a press on the thumb drags it.
		The area's position is set by Layout: the inner rectangle (inside the 4 pixel content margin) is the clip, so the
		bar sits inside the margin, and the content takes the bar's width away when it scrolls.
		DEVIATION(unverified): the bar's placement inside the margin and the page step on a track press are inferred from
		ScrollContainer; the wheel step is ScrollMath's.
]]

const UserInputService = game:GetService("UserInputService")

const Draw = require("./Draw")
const Scale = require("../Scale")
const Fade = require("./Fade")
const Geometry = require("./Geometry")
const Input = require("../Input")
const Look = require("./Look")
const ScrollMath = require("./ScrollMath")
const Signal = require("../../Util/Signal")

type Rect = Geometry.Rect

export type ScrollArea = {
	Frame: Frame,
	Content: Frame,
	Track: TextButton,
	Thumb: Frame,
	ThumbFill: Frame,
	Padding: number,
	Overlay: Fade.Fade,
	IsShown: () -> boolean,
	Offset: number,
	ContentHeight: number,
	Viewport: number,
	Dragging: boolean,
	DragGrab: number,
	Connections: { RBXScriptConnection },
}

-- The bar's width is the scroll bar's (Geometry.ScrollBarWidth); the thumb's rounded frame is twice that.
const ThumbWidth = Geometry.ScrollBarWidth * 2

-- The bar's thumb position and length for the area's current state.
const function Redraw(Area: ScrollArea)
	const Max = ScrollMath.MaxOffset(Area.ContentHeight, Area.Viewport)
	const Showing = Max > 0
	const Bar = Geometry.ScrollBarOf({ X = 0, Y = 0, Width = Area.Frame.Size.X.Offset, Height = Area.Viewport })
	const Length = ScrollMath.ThumbLength(Area.Viewport, Area.ContentHeight, Area.Viewport)
	const Top = ScrollMath.ThumbTop(Area.Viewport, Length, Area.Offset, Max)

	Area.Content.Position = UDim2.fromOffset(0, -math.round(Area.Offset))
	Area.Track.Visible = Showing
	Area.Thumb.Visible = Showing

	Draw.Place(Area.Track, Bar)
	Draw.Place(Area.Thumb, { X = Bar.X, Y = Top, Width = Bar.Width, Height = Length })
	Area.ThumbFill.Position = UDim2.fromOffset(-Geometry.ScrollBarWidth, 0)
	Area.ThumbFill.Size = UDim2.fromOffset(ThumbWidth, Length)
end

-- Sets the offset (clamped), and redraws the content and the thumb.
const function SetOffset(Area: ScrollArea, Offset: number)
	Area.Offset = ScrollMath.ClampOffset(Offset, Area.ContentHeight, Area.Viewport)
	Redraw(Area)
end

-- Whether the pointer is over the area's frame.
const function PointerInside(Area: ScrollArea): boolean
	const Pointer = Input.GetGuiMousePosition()
	const Origin = Scale.PositionOf(Area.Frame)
	const Size = Scale.SizeOf(Area.Frame)

	return Pointer.x >= Origin.x and Pointer.x < Origin.x + Size.x and Pointer.y >= Origin.y and Pointer.y < Origin.y + Size.y
end

-- Every area made, for the modal's drag reset (Settle and ResetHover).
const Live: { ScrollArea } = {}

-- Input.ModalChanged: a thumb drag ends when a modal covers the area (its wheel and drag are blocked too).
const function SettleAll()
	for Index = #Live, 1, -1 do
		const Area = Live[Index]

		if Area.Frame.Parent == nil then
			table.remove(Live, Index)
		elseif Area.Dragging and Input.Blocked(Area.Frame) then
			Area.Dragging = false
		end
	end
end

-- Ends every thumb drag (the menu hides).
const function ResetHover()
	for _, Area in Live do
		Area.Dragging = false
	end
end

Signal.Connect(Input.ModalChanged, SettleAll)

-- A scroll area under Parent. Overlay tracks its visuals for the fade, and IsShown says whether the menu takes input.
const function New(Parent: Instance, Name: string, ZIndex: number, Overlay: Fade.Fade, Padding: number, IsShown: () -> boolean): ScrollArea
	const Frame = Instance.new("Frame")

	Frame.Name = Name
	Frame.BackgroundTransparency = 1
	Frame.BorderSizePixel = 0
	Frame.ClipsDescendants = true
	Frame.Active = true
	Frame.ZIndex = ZIndex
	Frame.Parent = Parent

	const Content = Draw.Frame(Frame, "Content", { X = 0, Y = 0, Width = 0, Height = 0 }, ZIndex + 1, false)
	const Track = Instance.new("TextButton")

	Track.Name = "Bar"
	Track.Text = ""
	Track.AutoButtonColor = false
	Track.BorderSizePixel = 0
	Track.ZIndex = ZIndex + 2
	Track.Active = true
	Track.Parent = Frame
	Draw.Fill(Track, Look.ScrollTrack)

	const Thumb = Draw.Frame(Frame, "Thumb", { X = 0, Y = 0, Width = 0, Height = 0 }, ZIndex + 3, false)

	Thumb.ClipsDescendants = true

	const ThumbFill = Draw.Frame(Thumb, "Grabber", { X = 0, Y = 0, Width = ThumbWidth, Height = 0 }, ZIndex + 3, false)

	Draw.Fill(ThumbFill, Look.ScrollThumb)
	Draw.Corner(ThumbFill, Look.ScrollThumbRadius)

	const Area = {
		Frame = Frame,
		Content = Content,
		Track = Track,
		Thumb = Thumb,
		ThumbFill = ThumbFill,
		Padding = Padding,
		Overlay = Overlay,
		IsShown = IsShown,
		Offset = 0,
		ContentHeight = 0,
		Viewport = 0,
		Dragging = false,
		DragGrab = 0,
		Connections = {},
	} :: ScrollArea

	Fade.Track(Overlay, Frame)

	table.insert(Area.Connections, UserInputService.InputChanged:Connect(function(Event: InputObject)
		if Event.UserInputType == Enum.UserInputType.MouseWheel and IsShown() and Area.Frame.Visible and PointerInside(Area) and not Input.Blocked(Area.Frame) then
			const Direction = if Event.Position.Z > 0 then 1 else -1

			SetOffset(Area, ScrollMath.WheelOffset(Area.Offset, Direction, Area.ContentHeight, Area.Viewport))
		end

		if Area.Dragging and Event.UserInputType == Enum.UserInputType.MouseMovement then
			const Pointer = Input.GetGuiMousePosition()

			const Length = ScrollMath.ThumbLength(Area.Viewport, Area.ContentHeight, Area.Viewport)
			const Max = ScrollMath.MaxOffset(Area.ContentHeight, Area.Viewport)
			const Top = Pointer.y - Scale.PositionOf(Track).y - Area.DragGrab

			SetOffset(Area, ScrollMath.OffsetForThumb(Area.Viewport, Length, Top, Max))
		end
	end))
	table.insert(Area.Connections, UserInputService.InputEnded:Connect(function(Event: InputObject)
		if Event.UserInputType == Enum.UserInputType.MouseButton1 then
			Area.Dragging = false
		end
	end))
	table.insert(Area.Connections, Track.MouseButton1Down:Connect(function()
		if Input.Blocked(Track) then
			return
		end

		const Pointer = Input.GetGuiMousePosition()
		const ThumbTop = Scale.PositionOf(Track).y + Area.Thumb.Position.Y.Offset
		const Max = ScrollMath.MaxOffset(Area.ContentHeight, Area.Viewport)

		if Pointer.y >= ThumbTop and Pointer.y < ThumbTop + Area.Thumb.Size.Y.Offset then
			Area.Dragging = true
			Area.DragGrab = Pointer.y - ThumbTop
		elseif Pointer.y < ThumbTop then
			SetOffset(Area, Area.Offset - Area.Viewport)
		else
			SetOffset(Area, math.min(Max, Area.Offset + Area.Viewport))
		end
	end))

	table.insert(Live, Area)

	return Area
end

-- Lays the area out in its parent's space at Rect, for content of ContentHeight pixels. Answers the width the content gets
-- (the bar's width is taken from it when the content scrolls); the caller lays the content's children out at that width.
const function Layout(Area: ScrollArea, Rect: Rect, ContentHeight: number): number
	const Inner = Geometry.ScrollInner(Rect, Area.Padding)

	Draw.Place(Area.Frame, { X = Rect.X + Area.Padding, Y = Rect.Y + Area.Padding, Width = Inner.Width, Height = Inner.Height })

	Area.ContentHeight = ContentHeight
	Area.Viewport = Inner.Height

	Area.Content.Size = UDim2.fromOffset(Geometry.ScrollContentWidth(Inner, ContentHeight), ContentHeight)
	SetOffset(Area, Area.Offset)

	return Geometry.ScrollContentWidth(Inner, ContentHeight)
end

-- Shows or hides the area (its frame, with its content and bar).
const function SetVisible(Area: ScrollArea, Visible: boolean)
	Area.Frame.Visible = Visible
end

-- Scrolls back to the top (a new category or a rebuilt list).
const function Reset(Area: ScrollArea)
	SetOffset(Area, 0)
end

return {
	New = New,
	Layout = Layout,
	SetVisible = SetVisible,
	Reset = Reset,
	ResetHover = ResetHover,
}
