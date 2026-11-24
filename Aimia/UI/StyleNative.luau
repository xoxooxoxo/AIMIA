--!strict
--!optimize 2

--[[
	A StyleBoxFlat drawn with Roblox UI instead of an image: a Frame for the fill (UICorner for the corner radius, UIStroke for
	a border all around, a thin Frame for a border on the bottom only). A state change (hover, pressed) changes the properties
	of the same instances; nothing is destroyed or created, and nothing depends on the size, so a resize needs no redraw.

	Design Notes
		Only the boxes these instances can draw are native (Spec answers nil for the others, which Style draws as an image):
		any radius for each corner (UICorner has one per corner), no skew and no shadow, and a border that is absent, equal on all four sides, or on the
		bottom side alone (the theme's buttons: a 2 pixel line under the box). Every box of the theme and the scenes is one of
		these.
		A border of alpha 0 is no border (the fill shows under it, as Godot draws it). The expand margins grow the fill.
		DEVIATION(render): a bottom border follows the box's rounded corners in Godot (border_blend); here it is a line with
		rounded ends, inset by half the radius.
]]

const DefaultFill = { 0.6, 0.6, 0.6, 1 }
const DefaultBorder = { 0.8, 0.8, 0.8, 1 }

export type Spec = {
	Fill: { number },
	DrawCenter: boolean,
	Radii: { number },
	BorderMode: string,
	BorderWidth: number,
	BorderColor: { number },
	Expand: { number },
}

type Native = {
	Fill: Frame,
	Corner: UICorner,
	Stroke: UIStroke,
	Line: Frame,
	LineCorner: UICorner,
}

const Corners = { "corner_radius_top_left", "corner_radius_top_right", "corner_radius_bottom_right", "corner_radius_bottom_left" }

const function NumberOf(Properties: { [string]: unknown }, Key: string, Default: number): number
	const Value = Properties[Key]

	return if type(Value) == "number" then Value else Default
end

const function ColorOf(Properties: { [string]: unknown }, Key: string, Default: { number }): { number }
	const Value = Properties[Key]

	if type(Value) == "table" then
		const Components = (Value :: { Color: { number }? }).Color

		if Components then
			return Components
		end
	end

	return Default
end

-- The native drawing of a StyleBoxFlat's properties, or nil when they need an image.
const function Spec(Properties: { [string]: unknown }): Spec?
	const Skew = Properties["skew"]

	if type(Skew) == "table" then
		const Pair = (Skew :: { Vector2: { number }? }).Vector2

		if Pair and (Pair[1] ~= 0 or Pair[2] ~= 0) then
			return nil
		end
	end

	if NumberOf(Properties, "shadow_size", 0) > 0 then
		return nil
	end

	const Left = NumberOf(Properties, "border_width_left", 0)
	const Top = NumberOf(Properties, "border_width_top", 0)
	const Right = NumberOf(Properties, "border_width_right", 0)
	const Bottom = NumberOf(Properties, "border_width_bottom", 0)
	const BorderColor = ColorOf(Properties, "border_color", DefaultBorder)
	local Mode = "none"
	local Width = 0

	if (BorderColor[4] or 1) > 0 then
		if Left > 0 and Left == Top and Top == Right and Right == Bottom then
			Mode = "all"
			Width = Left
		elseif Bottom > 0 and Left == 0 and Top == 0 and Right == 0 then
			Mode = "bottom"
			Width = Bottom
		elseif Left > 0 or Top > 0 or Right > 0 or Bottom > 0 then
			return nil
		end
	end

	return {
		Fill = ColorOf(Properties, "bg_color", DefaultFill),
		DrawCenter = Properties["draw_center"] ~= false,
		Radii = {
			NumberOf(Properties, Corners[1], 0),
			NumberOf(Properties, Corners[2], 0),
			NumberOf(Properties, Corners[3], 0),
			NumberOf(Properties, Corners[4], 0),
		},
		BorderMode = Mode,
		BorderWidth = Width,
		BorderColor = BorderColor,
		Expand = {
			NumberOf(Properties, "expand_margin_left", 0),
			NumberOf(Properties, "expand_margin_top", 0),
			NumberOf(Properties, "expand_margin_right", 0),
			NumberOf(Properties, "expand_margin_bottom", 0),
		},
	}
end

-- The color and transparency of components multiplied by a modulate.
const function Tint(Components: { number }, Modulate: { number }?): (Color3, number)
	const Multiply = Modulate or { 1, 1, 1, 1 }
	const Color = Color3.new(
		math.clamp(Components[1] * Multiply[1], 0, 1),
		math.clamp(Components[2] * Multiply[2], 0, 1),
		math.clamp(Components[3] * Multiply[3], 0, 1)
	)

	return Color, 1 - math.clamp((Components[4] or 1) * (Multiply[4] or 1), 0, 1)
end

-- The instances of a native box under Host: made once, then reused.
const function InstancesOf(Host: Frame): Native
	const Existing = Host:FindFirstChild("Native")

	if Existing and Existing:IsA("Frame") then
		const ExistingLine = Existing:FindFirstChild("Line") :: Frame

		return {
			Fill = Existing,
			Corner = Existing:FindFirstChildOfClass("UICorner") :: UICorner,
			Stroke = Existing:FindFirstChildOfClass("UIStroke") :: UIStroke,
			Line = ExistingLine,
			LineCorner = ExistingLine:FindFirstChildOfClass("UICorner") :: UICorner,
		}
	end

	const Fill = Instance.new("Frame")
	const Corner = Instance.new("UICorner")
	const Stroke = Instance.new("UIStroke")
	const Line = Instance.new("Frame")
	const LineCorner = Instance.new("UICorner")

	Fill.Name = "Native"
	Fill.BorderSizePixel = 0
	Stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	Stroke.BorderStrokePosition = Enum.BorderStrokePosition.Inner
	Stroke.Enabled = false
	Line.Name = "Line"
	Line.BorderSizePixel = 0
	Line.AnchorPoint = Vector2.yAxis
	Line.Visible = false
	Corner.Parent = Fill
	Stroke.Parent = Fill
	LineCorner.Parent = Line
	Line.Parent = Fill
	Fill.Parent = Host

	return {
		Fill = Fill,
		Corner = Corner,
		Stroke = Stroke,
		Line = Line,
		LineCorner = LineCorner,
	}
end

-- The four corner radii of a UICorner: top left, top right, bottom right, bottom left.
const function SetRadii(Corner: UICorner, Radii: { number })
	Corner.TopLeftRadius = UDim.new(0, Radii[1])
	Corner.TopRightRadius = UDim.new(0, Radii[2])
	Corner.BottomRightRadius = UDim.new(0, Radii[3])
	Corner.BottomLeftRadius = UDim.new(0, Radii[4])
end

-- Draws Look into Host (the style host of a control): other children of the host are destroyed, and the native instances take
-- the box's look. Modulate is self_modulate.
const function Apply(Host: Frame, Look: Spec, Modulate: { number }?)
	for _, Child in Host:GetChildren() do
		if Child.Name ~= "Native" then
			Child:Destroy()
		end
	end

	const Native = InstancesOf(Host)
	const FillColor, FillTransparency = Tint(Look.Fill, Modulate)

	Native.Fill.Position = UDim2.fromOffset(-Look.Expand[1], -Look.Expand[2])
	Native.Fill.Size = UDim2.new(1, Look.Expand[1] + Look.Expand[3], 1, Look.Expand[2] + Look.Expand[4])
	Native.Fill.BackgroundColor3 = FillColor
	Native.Fill.BackgroundTransparency = if Look.DrawCenter then FillTransparency else 1
	SetRadii(Native.Corner, Look.Radii)

	const BorderColor, BorderTransparency = Tint(Look.BorderColor, Modulate)

	Native.Stroke.Enabled = Look.BorderMode == "all"

	if Look.BorderMode == "all" then
		Native.Stroke.Thickness = Look.BorderWidth
		Native.Stroke.Color = BorderColor
		Native.Stroke.Transparency = BorderTransparency
	end

	Native.Line.Visible = Look.BorderMode == "bottom"

	if Look.BorderMode == "bottom" then
		const Inset = (Look.Radii[3] + Look.Radii[4]) / 4

		Native.Line.Position = UDim2.new(0, Inset, 1, 0)
		Native.Line.Size = UDim2.new(1, -2 * Inset, 0, Look.BorderWidth)
		Native.Line.BackgroundColor3 = BorderColor
		Native.Line.BackgroundTransparency = BorderTransparency
		Native.LineCorner.CornerRadius = UDim.new(0, Look.BorderWidth / 2)
	end
end

return {
	Spec = Spec,
	Apply = Apply,
}
