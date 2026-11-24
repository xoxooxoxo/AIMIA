--!strict
--!optimize 2

--[[
	HSlider (Godot slider.cpp, not in reference/engine), drawn with Frames and ImageLabels: the track is the "slider"
	style box, the grabber area fills from the track start to the grabber ("grabber_area", or "grabber_area_highlight"
	while hovered or dragged), the grabber icon ("grabber", "grabber_highlight" while hovered or dragged,
	"grabber_disabled" when disabled) moves along the track, and tick_count "tick" icons mark the range. A press,
	a drag and a wheel tick set the value through UI/Controls/RangeMath.

	Design Notes
		The Instance is a TextButton without text, so it receives the mouse. A drag continues through UserInputService
		events until the button is released, wherever the pointer is.
		Signals: value_changed(value) when a user action or SetValue changes the value (not for SetValueNoSignal),
		drag_started(), and drag_ended(changed) when the drag ends.

	DEVIATION(unverified): the geometry is inferred (slider.cpp is not in reference/engine). The grabber is centered on
	its value along the track; the track is drawn at the control's full height; the grabber area ends at the grabber's
	center; the ticks are centered on the track at their positions; center_grabber, grabber_offset and tick_offset are
	ignored; ticks_position is treated as centered. The step default (0.01) and the wheel step are unverified too.
]]

const UserInputService = game:GetService("UserInputService")

const Items = require("../Item")
const Scale = require("../Scale")
const Style = require("../Style")
const Images = require("../Images")
const Input = require("../Input")
const RangeMath = require("./RangeMath")

type Item = Items.Item

const function MinOf(Item: Item): number
	return Items.Number(Item.Context.Properties, "min_value", 0)
end

const function MaxOf(Item: Item): number
	return Items.Number(Item.Context.Properties, "max_value", 100)
end

const function StepOf(Item: Item): number
	return Items.Number(Item.Context.Properties, "step", 0.01)
end

const function ValueOf(Item: Item): number
	return Items.Number(Item.Context.Properties, "value", 0)
end

-- The grabber icon's width (the size used for the grabber area and the travel), 0 when no grabber is baked.
const function GrabberSizeOf(Item: Item): vector
	const Path = Items.ThemeTexturePath(Item, "grabber")

	if not Path then
		return vector.zero
	end

	const Source = Images.GetSourceSize(Path)

	return vector.create(Source.X, Source.Y, 0)
end

-- Draws the track, grabber area, grabber and ticks for the current value and size.
const function Draw(Item: Item)
	const Properties = Item.Context.Properties
	const Own = Items.OwnModulate(Item)
	const Width = Item.Node.Size.x
	const Height = Item.Node.Size.y
	const Hot = Item.Hovered or Item.Held
	const Ratio = math.clamp(RangeMath.RatioOf(ValueOf(Item), MinOf(Item), MaxOf(Item)), 0, 1)

	local GrabberPath = Items.ThemeTexturePath(Item, "grabber")

	if Item.Disabled and Items.ThemeTexturePath(Item, "grabber_disabled") then
		GrabberPath = Items.ThemeTexturePath(Item, "grabber_disabled")
	elseif Hot and Items.ThemeTexturePath(Item, "grabber_highlight") then
		GrabberPath = Items.ThemeTexturePath(Item, "grabber_highlight")
	end

	const GrabberSize = GrabberSizeOf(Item)
	const Travel = math.max(0, Width - GrabberSize.x)
	const Left = Ratio * Travel
	const Grabber = Item.Grabber

	if Grabber then
		Grabber.Visible = GrabberPath ~= nil

		if GrabberPath then
			const Source = Images.GetSourceSize(GrabberPath)
			const Color, Transparency = Style.ToColor({ Color = Items.White }, Own)

			Grabber.ImageContent = Images.GetContent(GrabberPath)
			Grabber.ImageColor3 = Color
			Grabber.ImageTransparency = Transparency
			Grabber.Position = UDim2.fromOffset(Left, (Height - Source.Y) / 2)
			Grabber.Size = UDim2.fromOffset(Source.X, Source.Y)
		end
	end

	-- The track and the grabber area are drawn as tall as the track style's minimum, centered on the slider (Godot's HSlider draw);
	-- the style's expand margins make the track's ring taller than that.
	const TrackHeight = Style.GetMinimumSize(Items.GetStyle(Item, "slider")).y
	const TrackTop = (Height - TrackHeight) / 2
	const Host = Item.StyleHost

	if Host then
		Host.Position = UDim2.fromOffset(0, TrackTop)
		Host.Size = UDim2.fromOffset(Width, TrackHeight)
	end

	const Area = Item.GrabberArea
	const AreaWidth = math.max(0, Left + GrabberSize.x / 2)

	if Area then
		Style.DrawStyleBox(Area, Items.GetStyle(Item, if Hot then "grabber_area_highlight" else "grabber_area"), Own, AreaWidth, TrackHeight)
		Area.Position = UDim2.fromOffset(0, TrackTop)
		Area.Size = UDim2.fromOffset(AreaWidth, TrackHeight)
		Area.Visible = AreaWidth > 0
	end

	const TickPath = Items.ThemeTexturePath(Item, "tick")
	const Ticks = Item.Ticks
	const Wanted = if TickPath then Items.Number(Properties, "tick_count", 0) else 0

	while #Ticks > Wanted do
		const Tick = table.remove(Ticks) :: ImageLabel

		table.remove(Item.Visuals, table.find(Item.Visuals, Tick) :: number)
		Tick:Destroy()
	end

	while #Ticks < Wanted do
		const Tick = Instance.new("ImageLabel")

		Tick.Name = "Tick"
		Tick.BackgroundTransparency = 1
		Tick.ZIndex = 0
		Tick.Parent = Item.Instance
		table.insert(Ticks, Tick)
		table.insert(Item.Visuals, Tick)
	end

	if TickPath then
		const Source = Images.GetSourceSize(TickPath)
		const Content = Images.GetContent(TickPath)
		const OnBorders = Properties["ticks_on_borders"] == true
		const Color, Transparency = Style.ToColor({ Color = Items.White }, Own)

		for Index = 1, #Ticks do
			const Tick = Ticks[Index]
			const Center = GrabberSize.x / 2 + RangeMath.TickRatio(Index - 1, Wanted, OnBorders) * Travel

			Tick.ImageContent = Content
			Tick.ImageColor3 = Color
			Tick.ImageTransparency = Transparency
			Tick.Position = UDim2.fromOffset(Center - Source.X / 2, (Height - Source.Y) / 2)
			Tick.Size = UDim2.fromOffset(Source.X, Source.Y)
		end
	end
end

-- Sets the value through Range's rules and redraws; answers whether it changed. Emit fires value_changed on a change.
const function SetValue(Item: Item, Requested: number, Emit: boolean): boolean
	const Properties = Item.Context.Properties
	const Previous = ValueOf(Item)
	const Value = RangeMath.SetValue(
		Requested,
		MinOf(Item),
		MaxOf(Item),
		StepOf(Item),
		0,
		Properties["rounded"] == true,
		Properties["allow_greater"] == true,
		Properties["allow_lesser"] == true
	)

	Properties["value"] = Value
	Draw(Item)

	const Changed = Value ~= Previous

	if Emit and Changed then
		Items.Emit(Item, "value_changed", Value)
	end

	return Changed
end

const function Build(Item: Item)
	const Area = Instance.new("Frame")
	const Grabber = Instance.new("ImageLabel")

	Area.Name = "GrabberArea"
	Area.BackgroundTransparency = 1
	Area.BorderSizePixel = 0
	Area.ZIndex = -1
	Area.Parent = Item.Instance

	Grabber.Name = "Grabber"
	Grabber.BackgroundTransparency = 1
	Grabber.ZIndex = 0
	Grabber.Parent = Item.Instance

	Item.GrabberArea = Area
	Item.Grabber = Grabber
	table.insert(Item.Visuals, Area)
	table.insert(Item.Visuals, Grabber)
end

-- The minimum height is the larger of the track's margins and the grabber icon; the width is free (0).
const function MinimumSize(Item: Item): vector
	const Margins = Style.GetMinimumSize(Items.GetStyle(Item, "slider"))

	return vector.create(0, math.max(Margins.y, GrabberSizeOf(Item).y), 0)
end

-- The sliders that have focus (a slider takes it when pressed, as Godot's HSlider does: focus_mode is all).
const Focused: { [Item]: boolean } = {}

-- Gives or takes the slider's focus, emitting focus_entered or focus_exited when it changes.
const function SetFocus(Item: Item, Focus: boolean)
	if (Focused[Item] == true) == Focus then
		return
	end

	Focused[Item] = if Focus then true else nil
	Items.Emit(Item, if Focus then "focus_entered" else "focus_exited")
end

-- Mouse press, drag and wheel on the slider (the Instance is a TextButton).
const function Connect(Item: Item)
	const Button = Item.Instance :: TextButton
	local Dragging = false
	local Changed = false

	-- The value under the pointer: the grabber center follows the pointer across the travel.
	const function ValueUnderPointer(): number
		const Pointer = Input.GetMousePosition()
		const GrabberWidth = GrabberSizeOf(Item).x
		const Travel = math.max(0, Item.Node.Size.x - GrabberWidth)
		const Along = Pointer.x - Scale.PositionOf(Button).x - GrabberWidth / 2
		const Ratio = if Travel > 0 then math.clamp(Along / Travel, 0, 1) else 0

		return RangeMath.ValueAt(Ratio, MinOf(Item), MaxOf(Item))
	end

	table.insert(Item.Connections, Button.MouseEnter:Connect(function()
		if Input.Blocked(Button) then
			return
		end

		Item.Hovered = true
		Draw(Item)
	end))
	table.insert(Item.Connections, Button.MouseLeave:Connect(function()
		Item.Hovered = false
		Draw(Item)
	end))
	table.insert(Item.Connections, Button.MouseButton1Down:Connect(function()
		if Item.Disabled then
			return
		end

		Dragging = true
		Changed = false
		Item.Held = true
		SetFocus(Item, true)
		Items.Emit(Item, "drag_started")

		if SetValue(Item, ValueUnderPointer(), true) then
			Changed = true
		end
	end))
	table.insert(Item.Connections, UserInputService.InputChanged:Connect(function(Event: InputObject)
		if Dragging and Event.UserInputType == Enum.UserInputType.MouseMovement then
			if SetValue(Item, ValueUnderPointer(), true) then
				Changed = true
			end
		elseif Item.Hovered and not Item.Disabled and not Input.Blocked(Button) and Event.UserInputType == Enum.UserInputType.MouseWheel and Item.Context.Properties["scrollable"] ~= false then
			const Direction = if Event.Position.Z > 0 then 1 else -1
			const Step = RangeMath.WheelStep(StepOf(Item), MinOf(Item), MaxOf(Item))

			SetValue(Item, ValueOf(Item) + Direction * Step, true)
		end
	end))
	table.insert(Item.Connections, UserInputService.InputEnded:Connect(function(Event: InputObject)
		if Dragging and Event.UserInputType == Enum.UserInputType.MouseButton1 then
			Dragging = false
			Item.Held = false
			Items.Emit(Item, "drag_ended", Changed)
			Draw(Item)
		end
	end))
end

return {
	Build = Build,
	Draw = Draw,
	MinimumSize = MinimumSize,
	Connect = Connect,
	SetFocus = SetFocus,
	SetValue = SetValue,
}
