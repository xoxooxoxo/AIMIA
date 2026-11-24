--!strict
--!optimize 2

--[[
	Instance builders of the settings menu: frames with fills, corners and strokes, labels and icons, all placed in whole
	pixels. Every builder parents its Instance last and answers it; the caller tracks it with UI/Settings/Fade.

	Design Notes
		Rounded corners and borders are UICorner and UIStroke (vector, antialiased), not baked nine-slices. A stroke is drawn
		inside the frame (ApplyStrokeMode Border), as a StyleBoxFlat border is. Labels are not wrapped and clip with an
		ellipsis (Godot's overrun trim). Frames are transparent unless filled.
]]

const Geometry = require("./Geometry")
const Look = require("./Look")
const Style = require("../Style")

type Rect = Geometry.Rect

-- Positions and sizes an instance at a whole-pixel rectangle (negative sizes are empty).
const function Place(Object: GuiObject, Rect: Rect)
	Object.Position = UDim2.fromOffset(Rect.X, Rect.Y)
	Object.Size = UDim2.fromOffset(math.max(0, Rect.Width), math.max(0, Rect.Height))
end

-- A transparent frame at a rectangle of its parent's space.
const function Frame(Parent: Instance, Name: string, Rect: Rect, ZIndex: number, Active: boolean): Frame
	const Object = Instance.new("Frame")

	Object.Name = Name
	Object.BackgroundTransparency = 1
	Object.BorderSizePixel = 0
	Object.ZIndex = ZIndex
	Object.Active = Active
	Place(Object, Rect)
	Object.Parent = Parent

	return Object
end

-- Fills a GuiObject with a tint: its color, and its transparency from the tint's alpha.
const function Fill(Object: GuiObject, Tint: Look.Tint)
	Object.BackgroundColor3 = Tint.Color
	Object.BackgroundTransparency = 1 - Tint.Alpha
end

-- Rounds the corners of a GuiObject with a radius (Godot's corner_radius; 0 keeps them square).
const function Corner(Object: GuiObject, Radius: number)
	if Radius <= 0 then
		return
	end

	const Round = Instance.new("UICorner")

	Round.CornerRadius = UDim.new(0, Radius)
	Round.Parent = Object
end

-- A border drawn inside a GuiObject (a StyleBoxFlat border).
const function Stroke(Object: GuiObject, Tint: Look.Tint, Thickness: number): UIStroke
	const Line = Instance.new("UIStroke")

	Line.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	Line.Color = Tint.Color
	Line.Thickness = Thickness
	Line.Transparency = 1 - Tint.Alpha
	Line.Parent = Object

	return Line
end

-- A single-line label. Text that does not fit is cut with an ellipsis, as Godot's text_overrun_behavior does.
const function Label(Parent: Instance, Name: string, Rect: Rect, ZIndex: number, Text: string, Font: Font, Size: number, Tint: Look.Tint, Align: Enum.TextXAlignment): TextLabel
	const Object = Instance.new("TextLabel")

	Object.Name = Name
	Object.BackgroundTransparency = 1
	Object.BorderSizePixel = 0
	Object.ZIndex = ZIndex
	Object.Active = false
	Object.Text = Text
	Object.FontFace = Font
	Object.TextSize = Style.TextSizeOf(Font, Size)
	Object.TextColor3 = Tint.Color
	Object.TextTransparency = 1 - Tint.Alpha
	Object.TextXAlignment = Align
	Object.TextYAlignment = Enum.TextYAlignment.Center
	Object.TextTruncate = Enum.TextTruncate.AtEnd
	Place(Object, Rect)
	Object.Parent = Parent

	return Object
end

-- An icon: the image is a baked texture's content, tinted and placed at a rectangle.
const function Icon(Parent: Instance, Name: string, Rect: Rect, ZIndex: number, Image: Content, Tint: Look.Tint): ImageLabel
	const Object = Instance.new("ImageLabel")

	Object.Name = Name
	Object.BackgroundTransparency = 1
	Object.BorderSizePixel = 0
	Object.ZIndex = ZIndex
	Object.Active = false
	Object.ScaleType = Enum.ScaleType.Fit
	Object.ImageContent = Image
	Object.ImageColor3 = Tint.Color
	Object.ImageTransparency = 1 - Tint.Alpha
	Place(Object, Rect)
	Object.Parent = Parent

	return Object
end

return {
	Place = Place,
	Frame = Frame,
	Fill = Fill,
	Corner = Corner,
	Stroke = Stroke,
	Label = Label,
	Icon = Icon,
}
