--!strict
--!optimize 2

--[[
	The settings menu's HSlider (Godot slider.cpp with theme.tres): a 2 pixel pink track ring around a 4 pixel track, the pink
	grabber area filled from the track's start to the grabber, and the pale grabber icon. The grabber is the 12 pixel disc
	(grabber_normal.png) and, while hovered or dragged, the 24 pixel ring with a 10 pixel dot (grabber_pressed.png).

	Design Notes
		Geometry: the track's min height is the StyleBox's 2 + 2 border, expanded by 6 (sides) and 5 (top and bottom), so the
		ring is 14 pixels high and reaches 6 pixels past both ends. The grabber area ends at the grabber's center. center_grabber
		(theme.tres) centers the grabber on the value's position, so the value 0 sits at the track's start and the grabber
		overhangs it by half its width.
		Value rules: UI/Controls/RangeMath (Range::set_value). allow_greater and allow_lesser are set in the scene, so the
		value is only snapped to the step.
		Signals: OnChanged(value) runs on a user change (drag or click), as value_changed does; SetValueNoSignal does not.
		DEVIATION(unverified): the grabber's pixel positions come from the icon sizes and the inferred slider.cpp geometry
		above; the hover and drag highlight uses the grabber_highlight icon and the grabber_area_highlight color.
]]

const UserInputService = game:GetService("UserInputService")

const Draw = require("./Draw")
const Scale = require("../Scale")
const Fade = require("./Fade")
const Geometry = require("./Geometry")
const Input = require("../Input")
const Look = require("./Look")
const RangeMath = require("../Controls/RangeMath")
const Signal = require("../../Util/Signal")

type Rect = Geometry.Rect

export type Slider = {
	Object: TextButton,
	Ring: Frame,
	Fill: Frame,
	Disc: Frame,
	HotRing: Frame,
	HotDot: Frame,
	Width: number,
	Height: number,
	Min: number,
	Max: number,
	Step: number,
	-- a logarithmic track (a setting's slider with Log): equal steps along it multiply the value
	Log: boolean,
	Value: number,
	Hovered: boolean,
	Dragging: boolean,
	Suspended: boolean,
	Overlay: Fade.Fade,
	OnChanged: (Value: number) -> (),
	Connections: { RBXScriptConnection },
}

-- The track's ring and its expansion (the slider style: 2 + 2 border, expand margins 6 sides and 5 top and bottom).
const TrackExpandX = 6
const TrackExpandY = 5

-- The value's rule: step snapping, no page, and both bounds allowed (the scene sets allow_greater and allow_lesser).
const function SnapTo(Slider: Slider, Requested: number): number
	return RangeMath.SetValue(Requested, Slider.Min, Slider.Max, Slider.Step, 0, false, true, true)
end

-- Whether the track is logarithmic: only for a range above 0.
const function IsLog(Slider: Slider): boolean
	return Slider.Log and Slider.Min > 0 and Slider.Max > Slider.Min
end

-- A value's share of the track (on a logarithmic track, by its ratio to the minimum).
const function RatioOf(Slider: Slider, Value: number): number
	if IsLog(Slider) then
		return math.clamp(math.log(math.max(Value, Slider.Min) / Slider.Min) / math.log(Slider.Max / Slider.Min), 0, 1)
	end

	return RangeMath.RatioOf(Value, Slider.Min, Slider.Max)
end

-- The grabber's center along the track: the value's share of the width.
const function CenterOf(Slider: Slider): number
	return math.round(RatioOf(Slider, Slider.Value) * Slider.Width)
end

-- Draws the track, fill and grabber for the current value and size (the grabber is hot while hovered or dragged).
const function Redraw(Slider: Slider)
	const Hot = Slider.Hovered or Slider.Dragging
	const Center = CenterOf(Slider)
	const TrackTop = (Slider.Height - Look.SliderTrackHeight) // 2
	const Middle = Slider.Height // 2

	Slider.Ring.Position = UDim2.fromOffset(-TrackExpandX, TrackTop - TrackExpandY)
	Slider.Ring.Size = UDim2.fromOffset(Slider.Width + 2 * TrackExpandX, Look.SliderTrackHeight + 2 * TrackExpandY)

	Slider.Fill.Position = UDim2.fromOffset(0, TrackTop)
	Slider.Fill.Size = UDim2.fromOffset(Center, Look.SliderTrackHeight)
	Slider.Fill.BackgroundColor3 = if Hot then Look.SliderFillHot.Color else Look.SliderFill.Color

	Slider.Disc.Visible = not Hot
	Slider.Disc.Position = UDim2.fromOffset(Center - Look.SliderGrabberSize // 2, Middle - Look.SliderGrabberSize // 2)

	Slider.HotRing.Visible = Hot
	Slider.HotRing.Position = UDim2.fromOffset(Center - Look.SliderHotRingSize // 2, Middle - Look.SliderHotRingSize // 2)

	Slider.HotDot.Visible = Hot
	Slider.HotDot.Position = UDim2.fromOffset(Center - Look.SliderHotDotSize // 2, Middle - Look.SliderHotDotSize // 2)
end

-- Sets the value through the range rules and redraws. Emit runs OnChanged when the value changes.
const function SetValueOf(Slider: Slider, Requested: number, Emit: boolean)
	const Previous = Slider.Value

	Slider.Value = SnapTo(Slider, Requested)
	Redraw(Slider)

	if Emit and Slider.Value ~= Previous then
		Slider.OnChanged(Slider.Value)
	end
end

-- The value under the pointer: the track's share of the pointer's position.
const function ValueUnderPointer(Slider: Slider): number
	const Pointer = Input.GetMousePosition()
	const Ratio = if Slider.Width > 0 then math.clamp((Pointer.x - Scale.PositionOf(Slider.Object).x) / Slider.Width, 0, 1) else 0

	if IsLog(Slider) then
		return Slider.Min * (Slider.Max / Slider.Min) ^ Ratio
	end

	return RangeMath.ValueAt(Ratio, Slider.Min, Slider.Max)
end

-- Every slider made, for the modal's hover reset (Settle and ResetHover).
const Live: { Slider } = {}

-- Input.ModalChanged: a slider a modal covers stops hovering and dragging, and gets its hover back once the modal is gone
-- while the pointer is still over it (as Buttons.Settle).
const function Settle(Slider: Slider)
	if Input.Blocked(Slider.Object) then
		if Slider.Hovered or Slider.Dragging then
			Slider.Hovered = false
			Slider.Dragging = false
			Slider.Suspended = true
			Redraw(Slider)
		end
	elseif Slider.Suspended then
		Slider.Suspended = false
		Slider.Hovered = Input.PointerOver(Slider.Object)
		Redraw(Slider)
	end
end

const function SettleAll()
	for Index = #Live, 1, -1 do
		if Live[Index].Object.Parent == nil then
			table.remove(Live, Index)
		else
			Settle(Live[Index])
		end
	end
end

-- Clears the hover and drag of every slider (the menu hides).
const function ResetHover()
	for _, Slider in Live do
		Slider.Hovered = false
		Slider.Dragging = false
		Slider.Suspended = false
		Redraw(Slider)
	end
end

Signal.Connect(Input.ModalChanged, SettleAll)

-- Creates the slider at Rect with the range Min to Max (in steps of Step), starting at 0 when it is in the range.
const function New(Parent: Instance, Name: string, Rect: Geometry.Rect, ZIndex: number, Overlay: Fade.Fade, OnChanged: (Value: number) -> ()): Slider
	const Object = Instance.new("TextButton")

	Object.Name = Name
	Object.Text = ""
	Object.AutoButtonColor = false
	Object.BorderSizePixel = 0
	Object.BackgroundTransparency = 1
	Object.ZIndex = ZIndex
	Object.Active = true
	Draw.Place(Object, Rect)
	Object.Parent = Parent

	const Ring = Draw.Frame(Object, "Ring", { X = 0, Y = 0, Width = 0, Height = 0 }, ZIndex + 1, false)

	Draw.Corner(Ring, 6)
	Draw.Stroke(Ring, Look.SliderRing, Look.SliderRingThickness)

	const Fill = Draw.Frame(Object, "Fill", { X = 0, Y = 0, Width = 0, Height = 0 }, ZIndex + 2, false)

	Draw.Corner(Fill, Look.SliderTrackHeight // 2)

	const Disc = Draw.Frame(Object, "Grabber", { X = 0, Y = 0, Width = Look.SliderGrabberSize, Height = Look.SliderGrabberSize }, ZIndex + 3, false)

	Draw.Fill(Disc, Look.SliderGrabber)
	Draw.Corner(Disc, Look.SliderGrabberSize // 2)

	const HotRing = Draw.Frame(Object, "GrabberRing", { X = 0, Y = 0, Width = Look.SliderHotRingSize, Height = Look.SliderHotRingSize }, ZIndex + 3, false)

	HotRing.Visible = false
	Draw.Corner(HotRing, Look.SliderHotRingSize // 2)
	Draw.Stroke(HotRing, Look.SliderGrabber, Look.SliderHotRingThickness)

	const HotDot = Draw.Frame(Object, "GrabberDot", { X = 0, Y = 0, Width = Look.SliderHotDotSize, Height = Look.SliderHotDotSize }, ZIndex + 3, false)

	HotDot.Visible = false
	Draw.Fill(HotDot, Look.SliderGrabber)
	Draw.Corner(HotDot, Look.SliderHotDotSize // 2)

	const Slider = {
		Object = Object,
		Ring = Ring,
		Fill = Fill,
		Disc = Disc,
		HotRing = HotRing,
		HotDot = HotDot,
		Width = Rect.Width,
		Height = Rect.Height,
		Min = 0,
		Max = 100,
		Step = 0.01,
		Log = false,
		Value = 0,
		Hovered = false,
		Dragging = false,
		Suspended = false,
		Overlay = Overlay,
		OnChanged = OnChanged,
		Connections = {},
	} :: Slider

	table.insert(Live, Slider)
	Redraw(Slider)

	table.insert(Slider.Connections, Object.MouseEnter:Connect(function()
		if Input.Blocked(Object) then
			return
		end

		Slider.Hovered = true
		Redraw(Slider)
	end))
	table.insert(Slider.Connections, Object.MouseLeave:Connect(function()
		Slider.Hovered = false
		Redraw(Slider)
	end))
	table.insert(Slider.Connections, Object.MouseButton1Down:Connect(function()
		if Input.Blocked(Object) then
			return
		end

		Slider.Dragging = true
		SetValueOf(Slider, ValueUnderPointer(Slider), true)
	end))
	table.insert(Slider.Connections, UserInputService.InputChanged:Connect(function(Event: InputObject)
		if Slider.Dragging and Event.UserInputType == Enum.UserInputType.MouseMovement then
			SetValueOf(Slider, ValueUnderPointer(Slider), true)
		end
	end))
	table.insert(Slider.Connections, UserInputService.InputEnded:Connect(function(Event: InputObject)
		if Slider.Dragging and Event.UserInputType == Enum.UserInputType.MouseButton1 then
			Slider.Dragging = false
			Redraw(Slider)
		end
	end))

	Fade.Track(Overlay, Object)

	return Slider
end

-- Sets the range and step (the setting's slider bounds), and the value within them, without a signal. Log makes the track
-- logarithmic (only for a range above 0).
const function Configure(Slider: Slider, Min: number, Max: number, Step: number, Log: boolean?)
	Slider.Min = Min
	Slider.Max = Max
	Slider.Step = Step
	Slider.Log = Log == true
	Slider.Value = SnapTo(Slider, Slider.Value)
	Redraw(Slider)
end

-- Sets the value without OnChanged (Godot's set_value_no_signal).
const function SetValueNoSignal(Slider: Slider, Value: number)
	Slider.Value = SnapTo(Slider, Value)
	Redraw(Slider)
end

-- The value now.
const function GetValue(Slider: Slider): number
	return Slider.Value
end

-- Places the slider at Rect (its row changed size).
const function Place(Slider: Slider, Rect: Geometry.Rect)
	Slider.Width = Rect.Width
	Slider.Height = Rect.Height
	Draw.Place(Slider.Object, Rect)
	Redraw(Slider)
end

return {
	New = New,
	Configure = Configure,
	SetValueNoSignal = SetValueNoSignal,
	GetValue = GetValue,
	Place = Place,
	ResetHover = ResetHover,
}
