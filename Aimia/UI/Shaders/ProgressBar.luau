--!strict
--!optimize 2

--[[
	The progress shader of the jukebox spectrum (scripts/shaders/jukebox_progress.gdshader) on a Panel, drawn: the panel's
	style box in color_fill left of the progress edge and in color_background right of it. Two clipped halves, each the box
	drawn in its tint, so a change of progress or margin moves two frames and redraws nothing (UI/Shaders/Progress gives
	the split).

	Paradigm
		Bars are keyed by the style host. Draw creates them, SetParameter redraws one when a tint changes, Flush (once per
		frame, from UI/Nodes) moves the split with the progress, the margin and the element's place on the screen, and
		Release frees one.

	Design Notes
		The shader's COLOR is the box's color times the tint, so each half is the box drawn with its tint as the modulate
		(Style.DrawStyleBox), and the modulate of self_modulate is multiplied in.
		The spectrum's bars (AudioSpectrum._Draw, DrawMultiline) are frames over the box; the shader tints each by the same split,
		by the side its center is on (a bar is 4 pixels wide, so the split never cuts one visibly).
]]

const Style = require("../Style")
const Scale = require("../Scale")
const Theme = require("../Theme")
const MaterialModule = require("./Material")
const FillColumns = require("./Progress")

-- (Not in the source: the values last written to a pooled bar frame, so a frame whose values did not change is not read
-- back from the instance on every frame)
type Written = { Visible: boolean, Left: number, Top: number, Width: number, Height: number, Color: Color3? }

-- A value no number equals, so the first placement of a new frame writes every property.
const Unset = 0 / 0

type Bar = {
	Gui: GuiObject,
	Viewport: GuiBase2d,
	Material: MaterialModule.Material,
	Box: Theme.Resource,
	Own: { number },
	Width: number,
	Height: number,
	FillClip: Frame,
	BackClip: Frame,
	BackBox: Frame,
	Columns: number,
	FillTint: { number },
	BackTint: { number },
	Layer: Frame?,
	Pool: { Frame },
	Written: { Written },
	Points: { vector },
	BarSize: number,
	BarColor: { number },
	BarsDirty: boolean,
}

const Bars: { [Frame]: Bar } = {}

-- A frame that clips what it holds (its own background is clear).
const function ClipFrame(Parent: Instance, Name: string): Frame
	const Clip = Instance.new("Frame")

	Clip.Name = Name
	Clip.BackgroundTransparency = 1
	Clip.BorderSizePixel = 0
	Clip.ClipsDescendants = true
	Clip.Position = UDim2.fromOffset(0, 0)
	Clip.Parent = Parent

	return Clip
end

-- A frame of the box's full size at Left (relative to its clip), with the box drawn in Tint.
const function BoxFrame(Parent: Frame, Box: Theme.Resource, Tint: { number }, Width: number, Height: number, Left: number): Frame
	const Holder = Instance.new("Frame")

	Holder.Name = "Box"
	Holder.BackgroundTransparency = 1
	Holder.BorderSizePixel = 0
	Holder.Parent = Parent

	Style.DrawStyleBox(Holder, Box, Tint, Width, Height)

	Holder.Position = UDim2.fromOffset(Left, 0)
	Holder.Size = UDim2.fromOffset(Width, Height)

	return Holder
end

-- The tint of a color parameter multiplied by self_modulate.
const function TintOf(Material: MaterialModule.Material, Name: string, Default: { number }, Own: { number }): { number }
	const Color = MaterialModule.ColorOf(MaterialModule.Parameter(Material, Name), Default)

	return { Color[1] * Own[1], Color[2] * Own[2], Color[3] * Own[3], Color[4] * Own[4] }
end

-- Destroys the bar of a style host, if it has one.
const function Release(Host: Frame)
	const Bar = Bars[Host]

	if Bar then
		Bar.FillClip:Destroy()
		Bar.BackClip:Destroy()

		if Bar.Layer then
			Bar.Layer:Destroy()
		end

		Bars[Host] = nil
	end
end

-- Draws the box of a spectrum's style host in its two tints; answers true (the split depends on the size).
const function Draw(Host: Frame, Gui: GuiObject, Viewport: GuiBase2d, Material: MaterialModule.Material, Box: Theme.Resource?, Own: { number }, Width: number, Height: number): boolean
	const Previous = Bars[Host] or { Points = {}, BarSize = 4, BarColor = { 1, 1, 1, 1 } }

	Release(Host)

	for _, Child in Host:GetChildren() do
		Child:Destroy()
	end

	if not Box then
		return false
	end

	const FillClip = ClipFrame(Host, "FillClip")
	const BackClip = ClipFrame(Host, "BackClip")
	const FillTint = TintOf(Material, "color_fill", { 1, 1, 1, 1 }, Own)
	const BackTint = TintOf(Material, "color_background", { 0, 0, 0, 1 }, Own)

	BoxFrame(FillClip, Box, FillTint, Width, Height, 0)
	const BackBox = BoxFrame(BackClip, Box, BackTint, Width, Height, 0)

	Bars[Host] = {
		Gui = Gui,
		Viewport = Viewport,
		Material = Material,
		Box = Box,
		Own = Own,
		Width = Width,
		Height = Height,
		FillClip = FillClip,
		BackClip = BackClip,
		BackBox = BackBox,
		Columns = -1,
		FillTint = FillTint,
		BackTint = BackTint,
		Layer = nil,
		Pool = {},
		Written = {},
		Points = Previous.Points,
		BarSize = Previous.BarSize,
		BarColor = Previous.BarColor,
		BarsDirty = true,
	}

	return true
end

-- Records a parameter of a bar's shader: a tint redraws the bar; progress and margin are read at the next flush.
const function SetParameter(Host: Frame, Name: string, Value: unknown)
	const Bar = Bars[Host]

	if Bar and (Name == "color_fill" or Name == "color_background") then
		Draw(Host, Bar.Gui, Bar.Viewport, Bar.Material, Bar.Box, Bar.Own, Bar.Width, Bar.Height)
	end
end

-- Sets the spectrum's bars of a bar's host: a start and an end point per bar (Spectrum.Segments), and their color.
const function SetBars(Host: Frame, Points: { vector }, BarSize: number, Color: { number })
	const Bar = Bars[Host]

	if Bar then
		Bar.Points = Points
		Bar.BarSize = BarSize
		Bar.BarColor = Color
		Bar.BarsDirty = true
	end
end

-- Places a bar's frames: one per segment, tinted by the side of the split its center is on.
const function PlaceBars(Bar: Bar, Host: Frame)
	const Layer = Bar.Layer or Instance.new("Frame")

	if Bar.Layer == nil then
		Layer.Name = "Bars"
		Layer.BackgroundTransparency = 1
		Layer.BorderSizePixel = 0
		Layer.Size = UDim2.fromScale(1, 1)
		Layer.Parent = Host
		Bar.Layer = Layer
	end

	const Count = #Bar.Points // 2
	const Pool = Bar.Pool
	const FillColor, FillTransparency = Style.ToColor({ Color = Bar.BarColor }, Bar.FillTint)
	const BackColor, BackTransparency = Style.ToColor({ Color = Bar.BarColor }, Bar.BackTint)

	for Index = 1, math.max(Count, #Pool) do
		local Piece = Pool[Index]

		if Index > Count then
			if Piece then
				const Last = Bar.Written[Index]

				if Last.Visible then
					Piece.Visible = false
					Last.Visible = false
				end
			end

			continue
		end

		if Piece == nil then
			Piece = Instance.new("Frame")
			Piece.BorderSizePixel = 0
			Piece.Parent = Layer
			Pool[Index] = Piece
			Bar.Written[Index] = { Visible = true, Left = Unset, Top = Unset, Width = Unset, Height = Unset, Color = nil }
		end

		const Last = Bar.Written[Index]
		const Start = Bar.Points[Index * 2 - 1]
		const Finish = Bar.Points[Index * 2]
		const Filled = Start.x < Bar.Columns

		-- Only the properties that changed are written: each write dirties the screen's draw. (Not in the source: they are
		-- compared with the values last written, kept here, instead of being read back from the frame)
		const Height = math.max(Finish.y - Start.y, 0)
		const Color = if Filled then FillColor else BackColor
		const Left = Start.x - Bar.BarSize / 2

		if not Last.Visible then
			Piece.Visible = true
			Last.Visible = true
		end

		if Last.Left ~= Left or Last.Top ~= Start.y then
			Piece.Position = UDim2.fromOffset(Left, Start.y)
			Last.Left = Left
			Last.Top = Start.y
		end

		if Last.Height ~= Height or Last.Width ~= Bar.BarSize then
			Piece.Size = UDim2.fromOffset(Bar.BarSize, Height)
			Last.Height = Height
			Last.Width = Bar.BarSize
		end

		if Last.Color ~= Color then
			Piece.BackgroundColor3 = Color
			Piece.BackgroundTransparency = if Filled then FillTransparency else BackTransparency
			Last.Color = Color
		end
	end
end

-- Moves each bar's split to the progress edge for the element's place and the viewport's width.
const function Flush()
	for Host, Bar in Bars do
		const Material = Bar.Material
		const Fraction = MaterialModule.NumberOf(MaterialModule.Parameter(Material, "progress"), 0)
		const Margin = MaterialModule.NumberOf(MaterialModule.Parameter(Material, "margin"), 0)
		const Columns = FillColumns(Fraction, Margin, Scale.SizeOfViewport(Bar.Viewport).x, Scale.PositionOf(Bar.Gui).x, Bar.Width)

		if Columns ~= Bar.Columns then
			Bar.BarsDirty = true
			Bar.Columns = Columns
			Bar.FillClip.Size = UDim2.fromOffset(Columns, Bar.Height)
			Bar.BackClip.Position = UDim2.fromOffset(Columns, 0)
			Bar.BackClip.Size = UDim2.fromOffset(Bar.Width - Columns, Bar.Height)
			Bar.BackBox.Position = UDim2.fromOffset(-Columns, 0)
		end

		if Bar.BarsDirty then
			Bar.BarsDirty = false
			PlaceBars(Bar, Host)
		end
	end
end

return {
	Draw = Draw,
	SetParameter = SetParameter,
	SetBars = SetBars,
	Release = Release,
	Flush = Flush,
}
