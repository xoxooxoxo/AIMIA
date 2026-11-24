--!strict
--!optimize 2

--[[
	The settings menu's buttons: Button (a Godot Button with a StyleBox per state) and Toggle (a CheckButton: a pill with a
	knob, and no box of its own).

	Design Notes
		Button state is Godot's BaseButton: pressed while the mouse is held down over it, hover while it is under the mouse,
		normal otherwise. Activated is the click (Godot emits pressed on release). A press released outside the button ends
		through the global input end, so the state never sticks.
		A state's fill alpha is the frame's base transparency in the fade (Fade.SetFrameBase), so the fade keeps working
		across hover changes. The button's text and underline colors are the state's.
		Toggle: the knob sits left when off and right when on, on a track of the toggle icon's size. The toggle has no hover or
		focus box (CheckButtonBox is an empty style). A click flips the state and calls OnToggled with the new state.
]]

const UserInputService = game:GetService("UserInputService")

const Draw = require("./Draw")
const Fade = require("./Fade")
const Geometry = require("./Geometry")
const Input = require("../Input")
const Look = require("./Look")
const Style = require("../Style")
const Signal = require("../../Util/Signal")

type Rect = Geometry.Rect

export type Button = {
	Object: TextButton,
	Padding: UIPadding,
	Underline: Frame?,
	Style: Look.ButtonStyle,
	Overlay: Fade.Fade,
	Hovered: boolean,
	Held: boolean,
	Suspended: boolean,
	Connections: { RBXScriptConnection },
}

export type ButtonOptions = {
	Name: string,
	Rect: Rect,
	ZIndex: number,
	Style: Look.ButtonStyle,
	Text: string,
	Font: Font,
	FontSize: number,
	Align: Enum.TextXAlignment,
	Overlay: Fade.Fade,
	OnActivated: (() -> ())?,
}

export type Toggle = {
	Object: TextButton,
	Track: Frame,
	Knob: Frame,
	Pressed: boolean,
	OnToggled: (Pressed: boolean) -> (),
}

-- The state a button shows: pressed while held over it, hover while under the mouse, normal otherwise.
const function ModeOf(Button: Button): Look.Mode
	if Button.Hovered and Button.Held then
		return Button.Style.Pressed
	end

	if Button.Hovered then
		return Button.Style.Hover
	end

	return Button.Style.Normal
end

-- Shows the current state: its fill (the base transparency in the fade), text color, underline and label margins.
const function Refresh(Button: Button)
	const Mode = ModeOf(Button)

	Button.Object.BackgroundColor3 = Mode.Fill.Color
	Button.Object.BackgroundTransparency = 1 - Mode.Fill.Alpha
	Fade.SetFrameBase(Button.Overlay, Button.Object, 1 - Mode.Fill.Alpha)
	Button.Object.TextColor3 = Mode.Text.Color
	Button.Padding.PaddingTop = UDim.new(0, Mode.MarginTop)
	Button.Padding.PaddingBottom = UDim.new(0, Mode.MarginBottom)

	if Button.Underline then
		const Line = Mode.Underline

		Button.Underline.Visible = Line ~= nil
		-- The padding insets the button's children too: the line is moved back out to the button's edges.
		Button.Underline.Position = UDim2.new(0, -Look.ButtonInset, 1, Mode.MarginBottom)
		Button.Underline.Size = UDim2.new(1, 2 * Look.ButtonInset, 0, Button.Style.UnderlineWidth)

		if Line then
			Button.Underline.BackgroundColor3 = Line.Color
			Fade.SetFrameBase(Button.Overlay, Button.Underline, 1 - Line.Alpha)
		end
	end
end

-- Every button made, for the modal's hover reset (Settle and ResetHover).
const Live: { Button } = {}

-- Input.ModalChanged: a button a modal covers loses its hover and press, and gets its hover back once the modal is gone
-- while the pointer is still over it (the engine sends no MouseEnter then: GuiObject.MouseEnter is geometric).
const function Settle(Button: Button)
	if Input.Blocked(Button.Object) then
		if Button.Hovered or Button.Held then
			Button.Hovered = false
			Button.Held = false
			Button.Suspended = true
			Refresh(Button)
		end
	elseif Button.Suspended then
		Button.Suspended = false
		Button.Hovered = Input.PointerOver(Button.Object)
		Refresh(Button)
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

-- Clears the hover and press of every button (the menu hides; a button under the pointer is hovered again on a move).
const function ResetHover()
	for _, Button in Live do
		Button.Hovered = false
		Button.Held = false
		Button.Suspended = false
		Refresh(Button)
	end
end

Signal.Connect(Input.ModalChanged, SettleAll)

-- A button with its text and a state style. The caller's fade tracks it, and OnActivated runs on each click.
const function New(Parent: Instance, Options: ButtonOptions): Button
	const Object = Instance.new("TextButton")
	const Padding = Instance.new("UIPadding")

	Object.Name = Options.Name
	Object.Text = Options.Text
	Object.FontFace = Options.Font
	Object.TextSize = Style.TextSizeOf(Options.Font, Options.FontSize)
	Object.TextXAlignment = Options.Align
	Object.TextYAlignment = Enum.TextYAlignment.Center
	Object.TextTruncate = Enum.TextTruncate.AtEnd
	Object.AutoButtonColor = false
	Object.BorderSizePixel = 0
	Object.ZIndex = Options.ZIndex
	Object.Active = true
	Draw.Place(Object, Options.Rect)
	Object.Parent = Parent

	Padding.PaddingLeft = UDim.new(0, Look.ButtonInset)
	Padding.PaddingRight = UDim.new(0, Look.ButtonInset)
	Padding.Parent = Object

	Draw.Corner(Object, Options.Style.Radius)

	const Button = {
		Object = Object,
		Padding = Padding,
		Underline = nil,
		Style = Options.Style,
		Overlay = Options.Overlay,
		Hovered = false,
		Held = false,
		Suspended = false,
		Connections = {},
	} :: Button

	table.insert(Live, Button)

	if Options.Style.UnderlineWidth > 0 then
		const Line = Instance.new("Frame")

		Line.Name = "Underline"
		Line.BorderSizePixel = 0
		Line.ZIndex = Options.ZIndex + 1
		Line.Active = false
		Line.AnchorPoint = Vector2.yAxis
		Line.Position = UDim2.new(0, 0, 1, 0)
		Line.Size = UDim2.new(1, 0, 0, Options.Style.UnderlineWidth)
		Line.Parent = Object
		Button.Underline = Line
	end

	Refresh(Button)

	table.insert(Button.Connections, Object.MouseEnter:Connect(function()
		if Input.Blocked(Object) then
			return
		end

		Button.Hovered = true
		Refresh(Button)
	end))
	table.insert(Button.Connections, Object.MouseLeave:Connect(function()
		Button.Hovered = false
		Refresh(Button)
	end))
	table.insert(Button.Connections, Object.MouseButton1Down:Connect(function()
		if Input.Blocked(Object) then
			return
		end

		Button.Held = true
		Refresh(Button)
	end))
	table.insert(Button.Connections, Object.MouseButton1Up:Connect(function()
		Button.Held = false
		Refresh(Button)
	end))
	table.insert(Button.Connections, UserInputService.InputEnded:Connect(function(Input: InputObject)
		if Button.Held and Input.UserInputType == Enum.UserInputType.MouseButton1 then
			Button.Held = false
			Refresh(Button)
		end
	end))
	if Options.OnActivated then
		const OnActivated = Options.OnActivated

		table.insert(Button.Connections, Object.Activated:Connect(function()
			if Input.Blocked(Object) then
				return
			end

			OnActivated()
		end))
	end

	Fade.Track(Options.Overlay, Object)

	return Button
end

-- Places the knob for the toggle's state: inset from the track's ends, on the left when off and on the right when on.
const function ShowKnob(Toggle: Toggle)
	const IconTop = (Toggle.Object.Size.Y.Offset - Geometry.ToggleIconHeight) // 2
	const Inset = (Geometry.ToggleIconHeight - Look.ToggleKnobSize) // 2
	const Left = if Toggle.Pressed then Geometry.ToggleIconWidth - Inset - Look.ToggleKnobSize else Inset

	Toggle.Knob.Position = UDim2.fromOffset(Geometry.ToggleMarginX + Left, IconTop + Inset)
end

-- Places a toggle at Rect (its row's size): the track sits at the toggle icon's place, and the knob follows the state.
const function PlaceToggle(Toggle: Toggle, Rect: Rect)
	Draw.Place(Toggle.Object, Rect)
	Toggle.Track.Position = UDim2.fromOffset(Geometry.ToggleMarginX, (Rect.Height - Geometry.ToggleIconHeight) // 2)
	ShowKnob(Toggle)
end

-- A check button: its track and knob, and a click that flips it and calls OnToggled. Its place is set by PlaceToggle.
const function NewToggle(Parent: Instance, Name: string, ZIndex: number, Overlay: Fade.Fade, OnToggled: (Pressed: boolean) -> ()): Toggle
	const Object = Instance.new("TextButton")

	Object.Name = Name
	Object.Text = ""
	Object.AutoButtonColor = false
	Object.BorderSizePixel = 0
	Object.BackgroundTransparency = 1
	Object.ZIndex = ZIndex
	Object.Active = true
	Object.Parent = Parent

	const TrackFrame = Draw.Frame(Object, "Track", { X = 0, Y = 0, Width = Geometry.ToggleIconWidth, Height = Geometry.ToggleIconHeight }, ZIndex + 1, false)

	Draw.Fill(TrackFrame, Look.ToggleTrack)
	Draw.Corner(TrackFrame, Geometry.ToggleIconHeight // 2)

	const KnobFrame = Draw.Frame(Object, "Knob", { X = 0, Y = 0, Width = Look.ToggleKnobSize, Height = Look.ToggleKnobSize }, ZIndex + 2, false)

	Draw.Fill(KnobFrame, Look.ToggleKnob)
	Draw.Corner(KnobFrame, Look.ToggleKnobSize // 2)

	const Toggle = {
		Object = Object,
		Track = TrackFrame,
		Knob = KnobFrame,
		Pressed = false,
		OnToggled = OnToggled,
	} :: Toggle

	Object.Activated:Connect(function()
		if Input.Blocked(Object) then
			return
		end

		Toggle.Pressed = not Toggle.Pressed
		ShowKnob(Toggle)
		Toggle.OnToggled(Toggle.Pressed)
	end)

	Fade.Track(Overlay, Object)

	return Toggle
end

-- Sets the state without calling OnToggled (Godot's button_pressed).
const function SetPressed(Toggle: Toggle, Pressed: boolean)
	Toggle.Pressed = Pressed
	ShowKnob(Toggle)
end

-- Sets a button's text.
const function SetText(Button: Button, Text: string)
	Button.Object.Text = Text
end

-- Places a button at Rect (its row changed size).
const function Place(Button: Button, Rect: Rect)
	Draw.Place(Button.Object, Rect)
end

return {
	New = New,
	SetText = SetText,
	Place = Place,
	NewToggle = NewToggle,
	PlaceToggle = PlaceToggle,
	SetPressed = SetPressed,
	ResetHover = ResetHover,
}
