--!strict
--!optimize 2

--[[
	The outline shader (scripts/shaders/outline.gdshader) without Roblox: its parameters, the color of one pixel, and the
	geometry of the ring it colors (the strips that can hold ring pixels, and the nine-slice mapping of a style box's
	coverage onto an element). UI/Shaders/OutlineImage draws the ring with these.

	Design Notes
		Colors are the shader's values (Godot's source_color numbers, not converted: 2D canvas colors are drawn as stored).
		A mix is a * (1 - t) + b * t. The fragment's UV.x is the pixel center across the style box's UV rect: the element
		grown by the anti-aliasing size when the box is anti-aliased with rounded corners or skew (StyleBoxFlat::draw).
		A glow radius at or below zero makes both glows zero (the shader divides by it).
		Fill is compared at 1/1024 steps: an animated fill that rounds to the same step does not redraw the ring.
]]

const Material = require("./Material")

export type Parameters = {
	OutlineColor: { number },
	Opacity: number,
	LightColor: { number },
	CursorLightColor: { number },
	Fill: number,
	GlowRadius: number,
	GlowExponent: number,
	LightPosition: { number },
	CursorPosition: { number },
}

-- A band of the ring's drawing: the element's pixels from (X0, Y0) to (X1, Y1), exclusive.
export type Strip = {
	X0: number,
	Y0: number,
	X1: number,
	Y1: number,
}

const Names = {
	"outline_color",
	"outline_opacity",
	"light_color",
	"cursor_light_color",
	"fill",
	"glow_radius",
	"glow_exponent",
	"light_position",
	"cursor_position",
}

const FillSteps = 1024

const Corners = {
	"corner_radius_top_left",
	"corner_radius_top_right",
	"corner_radius_bottom_right",
	"corner_radius_bottom_left",
}

-- The uniform defaults of the shader (outline.gdshader L3-11).
const function Defaults(): Parameters
	return {
		OutlineColor = { 0.05, 0.05, 0.05, 1 },
		Opacity = 1,
		LightColor = { 0.79, 0, 0.27, 1 },
		CursorLightColor = { 0.15, 0.15, 0.15, 1 },
		Fill = 0,
		GlowRadius = 350,
		GlowExponent = 2,
		LightPosition = { 0, 0 },
		CursorPosition = { 0, 0 },
	}
end

-- Distance between two points.
const function Distance(AX: number, AY: number, BX: number, BY: number): number
	const DX = AX - BX
	const DY = AY - BY

	return math.sqrt(DX * DX + DY * DY)
end

-- The glow at a distance from the glow's center: 1 at the center, 0 at the radius and beyond.
const function Falloff(Radius: number, Gap: number): number
	if Radius <= 0 then
		return 0
	end

	return math.clamp((Radius - Gap) / Radius, 0, 1)
end

-- Distance from a point to a rect (0 inside it).
const function RectDistance(Point: { number }, Left: number, Top: number, Width: number, Height: number): number
	const DX = math.max(Left - Point[1], 0, Point[1] - (Left + Width))
	const DY = math.max(Top - Point[2], 0, Point[2] - (Top + Height))

	return math.sqrt(DX * DX + DY * DY)
end

-- Sets one parameter by its shader name from a Godot value. Answers "Color" when the drawn colors may change, "Point"
-- when only a position changed (the ring is recomputed when the position matters), and nil when nothing drawn changed.
const function Set(Parameters: Parameters, Name: string, Value: unknown): string?
	if Name == "outline_color" then
		return if Material.WriteColor(Value, Parameters.OutlineColor) then "Color" else nil
	elseif Name == "outline_opacity" then
		if type(Value) ~= "number" then
			return nil
		end

		Parameters.Opacity = Value

		return "Color"
	elseif Name == "light_color" then
		return if Material.WriteColor(Value, Parameters.LightColor) then "Color" else nil
	elseif Name == "cursor_light_color" then
		return if Material.WriteColor(Value, Parameters.CursorLightColor) then "Color" else nil
	elseif Name == "fill" then
		if type(Value) ~= "number" then
			return nil
		end

		const Previous = Parameters.Fill

		Parameters.Fill = Value

		if (Previous * FillSteps + 0.5) // 1 == (Value * FillSteps + 0.5) // 1 then
			return nil
		end

		return "Color"
	elseif Name == "glow_radius" then
		if type(Value) ~= "number" then
			return nil
		end

		Parameters.GlowRadius = Value

		return "Color"
	elseif Name == "glow_exponent" then
		if type(Value) ~= "number" then
			return nil
		end

		Parameters.GlowExponent = Value

		return "Color"
	elseif Name == "light_position" then
		return if Material.WriteVector2(Value, Parameters.LightPosition) then "Point" else nil
	elseif Name == "cursor_position" then
		return if Material.WriteVector2(Value, Parameters.CursorPosition) then "Point" else nil
	end

	return nil
end

-- The parameters of a material: its values, and the shader's defaults for the ones it leaves out.
const function FromMaterial(Source: Material.Material): Parameters
	const Parameters = Defaults()

	for _, Name in Names do
		Set(Parameters, Name, Material.Parameter(Source, Name))
	end

	return Parameters
end

-- The color of the pixel at screen position (X, Y) of an element whose UV.x is UvX: the outline color, mixed toward the
-- cursor's light by the cursor's glow, toward the light color by the fill ramp, and toward the light color by the light's
-- glow (the shader's three mixes, in its order). Answers the rgb in 0..1.
-- @src scripts/shaders/outline.gdshader:fragment L13-24
const function Shade(Parameters: Parameters, X: number, Y: number, UvX: number): (number, number, number)
	const Radius = Parameters.GlowRadius
	const CursorLight = Parameters.CursorLightColor
	const LightColor = Parameters.LightColor
	const Outline = Parameters.OutlineColor

	const CursorGap = Distance(Parameters.CursorPosition[1], Parameters.CursorPosition[2], X, Y)
	const CursorWeight = CursorLight[4] * Falloff(Radius, CursorGap)
	local Red = Outline[1] * (1 - CursorWeight) + CursorLight[1] * CursorWeight
	local Green = Outline[2] * (1 - CursorWeight) + CursorLight[2] * CursorWeight
	local Blue = Outline[3] * (1 - CursorWeight) + CursorLight[3] * CursorWeight

	const FillWeight = math.clamp(1 - UvX + 2 * (Parameters.Fill - 0.5), 0, 1)

	Red = Red * (1 - FillWeight) + LightColor[1] * FillWeight
	Green = Green * (1 - FillWeight) + LightColor[2] * FillWeight
	Blue = Blue * (1 - FillWeight) + LightColor[3] * FillWeight

	const LightGap = Distance(Parameters.LightPosition[1], Parameters.LightPosition[2], X, Y)
	const SelectionWeight = Falloff(Radius, LightGap) ^ Parameters.GlowExponent

	Red = Red * (1 - SelectionWeight) + LightColor[1] * SelectionWeight
	Green = Green * (1 - SelectionWeight) + LightColor[2] * SelectionWeight
	Blue = Blue * (1 - SelectionWeight) + LightColor[3] * SelectionWeight

	return Red, Green, Blue
end

-- Whether a glow reaches an element at (Left, Top) of Width x Height: the cursor or a light is nearer than the radius.
-- An element out of reach keeps its ring while the glows move, since both are zero there.
const function Near(Parameters: Parameters, Left: number, Top: number, Width: number, Height: number): boolean
	const Radius = Parameters.GlowRadius

	if Radius <= 0 then
		return false
	end

	return RectDistance(Parameters.CursorPosition, Left, Top, Width, Height) < Radius
		or RectDistance(Parameters.LightPosition, Left, Top, Width, Height) < Radius
end

-- The anti-aliasing grow of a style box's UV rect: its anti-aliasing size when the box is anti-aliased and has rounded
-- corners or a skew, else 0 (StyleBoxFlat::draw, aa_on).
const function Grow(Properties: { [string]: unknown }): number
	local Rounded = false

	for _, Corner in Corners do
		if Material.NumberOf(Properties[Corner], 0) > 0 then
			Rounded = true
		end
	end

	const Skew = { 0, 0 }
	const Skewed = Material.WriteVector2(Properties["skew"], Skew) and (Skew[1] ~= 0 or Skew[2] ~= 0)

	if Properties["anti_aliasing"] == false or not (Rounded or Skewed) then
		return 0
	end

	return math.clamp(Material.NumberOf(Properties["anti_aliasing_size"], 1), 0.01, 10)
end

-- UV.x of every control column of a Width-pixel element (entry Column + 1), at the pixel centers, for a UV grow Margin.
const function UvTable(Width: number, Margin: number): { number }
	const Table = table.create(Width, 0)

	for Column = 0, Width - 1 do
		Table[Column + 1] = (Column + 0.5 + Margin) / (Width + 2 * Margin)
	end

	return Table
end

-- The strips that can hold ring pixels of a Width x Height element: the whole element when the box fills its center
-- (the shader then colors the fill too), else four strips reaching the border widths and corner radii. Every ring pixel
-- lies in one of them: a corner's arc stays within its radius of both edges.
const function Strips(Properties: { [string]: unknown }, Width: number, Height: number): { Strip }
	if Properties["draw_center"] ~= false then
		return { { X0 = 0, Y0 = 0, X1 = Width, Y1 = Height } }
	end

	const TopLeft = Material.NumberOf(Properties["corner_radius_top_left"], 0)
	const TopRight = Material.NumberOf(Properties["corner_radius_top_right"], 0)
	const BottomRight = Material.NumberOf(Properties["corner_radius_bottom_right"], 0)
	const BottomLeft = Material.NumberOf(Properties["corner_radius_bottom_left"], 0)
	const BorderLeft = Material.NumberOf(Properties["border_width_left"], 0)
	const BorderTop = Material.NumberOf(Properties["border_width_top"], 0)
	const BorderRight = Material.NumberOf(Properties["border_width_right"], 0)
	const BorderBottom = Material.NumberOf(Properties["border_width_bottom"], 0)

	-- Whole pixels: the bands index the element's image rows and columns, so a fractional edge would index nothing.
	const Top = math.ceil(math.min(Height, math.max(BorderTop, TopLeft, TopRight)))
	const Bottom = math.ceil(math.min(Height, math.max(BorderBottom, BottomLeft, BottomRight)))
	const Left = math.ceil(math.min(Width, math.max(BorderLeft, TopLeft, BottomLeft)))
	const Right = math.ceil(math.min(Width, math.max(BorderRight, TopRight, BottomRight)))

	return {
		{ X0 = 0, Y0 = 0, X1 = Width, Y1 = Top },
		{ X0 = 0, Y0 = Height - Bottom, X1 = Width, Y1 = Height },
		{ X0 = 0, Y0 = Top, X1 = Left, Y1 = Height - Bottom },
		{ X0 = Width - Right, Y0 = Top, X1 = Width, Y1 = Height - Bottom },
	}
end

-- One axis of the nine-slice mapping: for each element index 0..Count-1 (entry Index + 1), the index of the style box
-- image's row or column that covers it, or -1 outside the image. The image starts at Offset and is ImageSize pixels; its
-- column (or row) Center stretches by Stretch pixels: the part before keeps its pixels, the part after shifts by Stretch
-- (ScaleType.Slice). An unsliced image has Stretch 0 and a Center past its end.
const function AxisTable(Count: number, Offset: number, ImageSize: number, Center: number, Stretch: number): { number }
	const Table = table.create(Count, -1)
	const Length = ImageSize + Stretch

	for Index = 0, Count - 1 do
		const Local = Index - Offset

		if Local >= 0 and Local < Length then
			if Local < Center then
				Table[Index + 1] = Local
			elseif Local < Center + 1 + Stretch then
				Table[Index + 1] = Center
			else
				Table[Index + 1] = Local - Stretch
			end
		end
	end

	return Table
end

return {
	Defaults = Defaults,
	FromMaterial = FromMaterial,
	Set = Set,
	Shade = Shade,
	Near = Near,
	Grow = Grow,
	UvTable = UvTable,
	Strips = Strips,
	AxisTable = AxisTable,
}
