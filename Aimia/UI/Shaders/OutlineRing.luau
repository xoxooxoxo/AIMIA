--!strict
--!optimize 2

--[[
	The outline shader (scripts/shaders/outline.gdshader) on a Panel, drawn with Roblox UI: the panel's ring is a UIStroke inside a
	rounded transparent Frame, and the shader's colors are a UIGradient on the stroke: the colors the shader computes along the
	element's width (UI/Shaders/Outline.Shade at a few points), moved with the cursor and the light.

	Paradigm
		Rings are keyed by the style host (the Frame that draws the style). Draw creates or keeps one, SetParameter records a
		parameter, Flush (once per frame, from UI/Nodes) updates the gradients of the rings a glow reaches, Release frees one.

	Design Notes
		DEVIATION(render): the shader colors each pixel by its own distance to the cursor and the light; a gradient colors the
		stroke by its x only. The stroke's top and bottom edges take the colors of the edge nearer to the cursor, and a side
		edge takes the gradient's value at its x. The glow is hundreds of pixels wide, so the ring looks the same at the
		scale of a card; the shader's per-pixel image (UI/Shaders/OutlineImage) costs an update of tens of thousands of pixels
		a frame. A box the stroke cannot draw (not a border on all four sides with no fill) is drawn by OutlineImage.
		The stroke's color is white, the gradient multiplies it, and a modulate tints it as it tints a style box.
]]

const Scale = require("../Scale")
const StyleNative = require("../StyleNative")
const Theme = require("../Theme")
const MaterialModule = require("./Material")
const Outline = require("./Outline")

-- Points of the gradient along the width (a ColorSequence takes at most 20).
const Points = 14

type Ring = {
	Gui: GuiObject,
	Frame: Frame,
	Stroke: UIStroke,
	Gradient: UIGradient,
	Width: number,
	Height: number,
	Parameters: Outline.Parameters,
	BorderAlpha: number,
	Dirty: boolean,
	Near: boolean,
	RenderedX: number,
	RenderedY: number,
	RenderedCursorX: number,
	RenderedCursorY: number,
	RenderedLightX: number,
	RenderedLightY: number,
}

const Rings: { [Frame]: Ring } = {}

-- Destroys the ring of a style host, if it has one.
const function Release(Host: Frame)
	const Ring = Rings[Host]

	if Ring then
		Ring.Frame:Destroy()
		Rings[Host] = nil
	end
end

-- Sets the gradient of a ring for the element at layout position (Left, Top): the shader's color at each point of the width.
const function Render(Ring: Ring, Left: number, Top: number, Near: boolean)
	const Parameters = Ring.Parameters
	const Cursor = Parameters.CursorPosition
	const Light = Parameters.LightPosition
	const Keypoints: { ColorSequenceKeypoint } = {}

	-- The edge nearer to the cursor (or to the light, when that is the nearer glow).
	const Middle = Top + Ring.Height / 2
	const NearestY = if math.min(math.abs(Cursor[2] - Middle), math.abs(Light[2] - Middle)) == math.abs(Cursor[2] - Middle) then Cursor[2] else Light[2]
	const Y = if NearestY < Middle then Top + 0.5 else Top + Ring.Height - 0.5

	for Index = 0, Points - 1 do
		const Ratio = Index / (Points - 1)
		const Red, Green, Blue = Outline.Shade(Parameters, Left + Ratio * Ring.Width, Y, Ratio)

		table.insert(Keypoints, ColorSequenceKeypoint.new(Ratio, Color3.new(math.clamp(Red, 0, 1), math.clamp(Green, 0, 1), math.clamp(Blue, 0, 1))))
	end

	Ring.Gradient.Color = ColorSequence.new(Keypoints)
	Ring.Dirty = false
	Ring.Near = Near
	Ring.RenderedX = Left
	Ring.RenderedY = Top
	Ring.RenderedCursorX = Cursor[1]
	Ring.RenderedCursorY = Cursor[2]
	Ring.RenderedLightX = Light[1]
	Ring.RenderedLightY = Light[2]
end

-- Draws the ring of a panel's style box into Host. Answers nil when the box is not one a stroke draws (the caller draws the image
-- ring), else false: the ring does not depend on the size.
const function Draw(Host: Frame, Gui: GuiObject, Material: MaterialModule.Material, Box: Theme.Resource?, LayoutWidth: number, LayoutHeight: number): boolean?
	if not Box or Box.Type ~= "StyleBoxFlat" then
		return nil
	end

	const Look = StyleNative.Spec(Box.Properties)

	if not Look or Look.BorderMode ~= "all" or Look.DrawCenter and Look.Fill[4] > 0 then
		return nil
	end

	const Existing = Rings[Host]

	if Existing and Existing.Frame.Parent == Host then
		Existing.Gui = Gui
		Existing.Width = LayoutWidth
		Existing.Height = LayoutHeight
		Existing.Stroke.Thickness = Look.BorderWidth
		Existing.BorderAlpha = Look.BorderColor[4] or 1
		Existing.Dirty = true

		return false
	end

	Release(Host)

	for _, Child in Host:GetChildren() do
		Child:Destroy()
	end

	const Frame = Instance.new("Frame")
	const Round = Instance.new("UICorner")
	const Stroke = Instance.new("UIStroke")
	const Gradient = Instance.new("UIGradient")

	Frame.Name = "Outline"
	Frame.BackgroundTransparency = 1
	Frame.BorderSizePixel = 0
	Frame.Size = UDim2.fromScale(1, 1)
	Round.TopLeftRadius = UDim.new(0, Look.Radii[1])
	Round.TopRightRadius = UDim.new(0, Look.Radii[2])
	Round.BottomRightRadius = UDim.new(0, Look.Radii[3])
	Round.BottomLeftRadius = UDim.new(0, Look.Radii[4])
	Round.Parent = Frame
	Stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	Stroke.BorderStrokePosition = Enum.BorderStrokePosition.Inner
	Stroke.Thickness = Look.BorderWidth
	Stroke.Color = Color3.new(1, 1, 1)
	Stroke.Parent = Frame
	Gradient.Parent = Stroke
	Frame.Parent = Host

	const Parameters = Outline.FromMaterial(Material)

	Stroke.Transparency = 1 - math.clamp(Parameters.Opacity * (Look.BorderColor[4] or 1), 0, 1)

	Rings[Host] = {
		Gui = Gui,
		Frame = Frame,
		Stroke = Stroke,
		Gradient = Gradient,
		Width = LayoutWidth,
		Height = LayoutHeight,
		Parameters = Parameters,
		BorderAlpha = Look.BorderColor[4] or 1,
		Dirty = true,
		Near = false,
		RenderedX = 0,
		RenderedY = 0,
		RenderedCursorX = 0,
		RenderedCursorY = 0,
		RenderedLightX = 0,
		RenderedLightY = 0,
	}

	return false
end

-- Records a parameter of a ring's shader: a color or opacity change redraws it at the next flush.
const function SetParameter(Host: Frame, Name: string, Value: unknown)
	const Ring = Rings[Host]

	if Ring and Outline.Set(Ring.Parameters, Name, Value) == "Color" then
		Ring.Stroke.Transparency = 1 - math.clamp(Ring.Parameters.Opacity * Ring.BorderAlpha, 0, 1)
		Ring.Dirty = true
	end
end

-- Updates the gradients of the rings whose colors may have changed: a changed parameter, or a move while a glow reaches the
-- element now or reached it at the last update.
const function Flush()
	for _, Ring in Rings do
		const Position = Scale.PositionOf(Ring.Gui)
		const Parameters = Ring.Parameters
		const Cursor = Parameters.CursorPosition
		const Light = Parameters.LightPosition
		const Near = Outline.Near(Parameters, Position.x, Position.y, Ring.Width, Ring.Height)
		const Moved = Position.x ~= Ring.RenderedX
			or Position.y ~= Ring.RenderedY
			or Cursor[1] ~= Ring.RenderedCursorX
			or Cursor[2] ~= Ring.RenderedCursorY
			or Light[1] ~= Ring.RenderedLightX
			or Light[2] ~= Ring.RenderedLightY

		if Ring.Dirty or (Moved and (Near or Ring.Near)) then
			Render(Ring, Position.x, Position.y, Near)
		end
	end
end

return {
	Draw = Draw,
	SetParameter = SetParameter,
	Release = Release,
	Flush = Flush,
}
