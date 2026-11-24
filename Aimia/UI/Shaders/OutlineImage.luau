--!strict
--!optimize 2

--[[
	The outline shader (scripts/shaders/outline.gdshader) on a Panel, drawn: the ring of the panel's style box in the colors
	the shader computes at each ring pixel (UI/Shaders/Outline), in an EditableImage the size of the element that holds only
	the ring's strips, shown by a label over the style host.

	Paradigm
		Rings are keyed by the style host (the Frame that draws the style). Draw creates or keeps one, SetParameter records a
		parameter, Flush redraws the rings whose colors may have changed (once per frame, from UI/Nodes), Release frees one.

	Design Notes
		The ring's alpha is the style box's coverage: a sliceable box is rendered once at its slice size and mapped onto the
		element by the nine-slice (Outline.AxisTable), so the shape is the one the style box draws.
		A ring is recomputed when a parameter changes, when the size changes (Draw), or when it moves while a glow reaches it
		now or did at its last redraw. A far element keeps its ring.
		The label's color is kept (KeepColor): the shader overwrites the color, so a modulate's color does not reach it; its
		alpha does, through UI/Item's tint.
		DEVIATION(size): an EditableImage is at most 1024 pixels a side; a larger element is drawn cropped to 1024.
]]

const AssetService = game:GetService("AssetService")

const StyleBoxRender = require("../StyleBoxRender")
const Scale = require("../Scale")
const Theme = require("../Theme")
const MaterialModule = require("./Material")
const Outline = require("./Outline")

type Band = {
	X0: number,
	Y0: number,
	X1: number,
	Y1: number,
	Buffer: buffer,
	Reds: { number },
	Greens: { number },
	Blues: { number },
}

type Ring = {
	Gui: GuiObject,
	Label: ImageLabel,
	Image: EditableImage,
	Key: string,
	Width: number,
	Height: number,
	Coverage: StyleBoxRender.Image,
	Columns: { number },
	Rows: { number },
	Uv: { number },
	Bands: { Band },
	Parameters: Outline.Parameters,
	Dirty: boolean,
	Near: boolean,
	NearNow: boolean,
	RenderedX: number,
	RenderedY: number,
	RenderedCursorX: number,
	RenderedCursorY: number,
	RenderedLightX: number,
	RenderedLightY: number,
	RenderedAt: number,
}

const SideLimit = 1024

-- The shader's colors vary over the glow's radius (hundreds of pixels), so a block of Cell x Cell ring pixels takes the color of
-- its center: a sixteenth of the shader's evaluations (the cost of a hovered list is these evaluations, every frame).
const Cell = 4

const Rings: { [Frame]: Ring } = {}

-- A channel value (0..1) as a byte.
const function ToByte(Value: number): number
	return math.clamp((Value * 255 + 0.5) // 1, 0, 255)
end

-- Destroys the ring of a style host, if it has one.
const function Release(Host: Frame)
	const Ring = Rings[Host]

	if Ring then
		Ring.Label:Destroy()
		Ring.Image:Destroy()
		Rings[Host] = nil
	end
end

-- The style box's coverage at a Width x Height element, with the image's column and row of each element column and row.
-- A sliceable box is rendered once at its slice size and stretched by the nine-slice; otherwise it is rendered at the size.
const function CoverageOf(Properties: { [string]: unknown }, Modulate: { number }, Width: number, Height: number): (StyleBoxRender.Image, { number }, { number })
	const SliceWidth, SliceHeight = StyleBoxRender.SliceSize(Properties)

	-- The slice is a whole number of pixels, and so is its stretchable column and row (their indices into the image).
	if SliceWidth and SliceHeight and Width >= math.ceil(SliceWidth) and Height >= math.ceil(SliceHeight) then
		const WholeWidth = math.ceil(SliceWidth)
		const WholeHeight = math.ceil(SliceHeight)
		const Coverage = StyleBoxRender.Render(Properties, WholeWidth, WholeHeight, Modulate)
		const CenterX, CenterY = StyleBoxRender.SliceCenter(Properties, Coverage)

		return Coverage, Outline.AxisTable(Width, Coverage.OffsetX, Coverage.Width, CenterX // 1, Width - WholeWidth), Outline.AxisTable(Height, Coverage.OffsetY, Coverage.Height, CenterY // 1, Height - WholeHeight)
	end

	const Coverage = StyleBoxRender.Render(Properties, Width, Height, Modulate)

	return Coverage, Outline.AxisTable(Width, Coverage.OffsetX, Coverage.Width, Coverage.Width, 0), Outline.AxisTable(Height, Coverage.OffsetY, Coverage.Height, Coverage.Height, 0)
end

-- Writes the ring's colors for the element at screen position (Left, Top): each ring pixel takes the shader's color and
-- the coverage's alpha times the opacity; the other pixels of the strips are clear.
const function Render(Ring: Ring, Left: number, Top: number, Near: boolean)
	const Parameters = Ring.Parameters
	const Pixels = Ring.Coverage.Pixels
	const Stride = Ring.Coverage.Width
	const Opacity = Parameters.Opacity
	const Columns = Ring.Columns
	const Rows = Ring.Rows
	const Uv = Ring.Uv

	for _, Band in Ring.Bands do
		local Index = 0
		local ShadedRow = -1

		for Y = Band.Y0, Band.Y1 - 1 do
			const Row = Rows[Y + 1]
			const CellRow = (Y - Band.Y0) // Cell

			-- The colors of this block row, at the blocks' centers.
			if CellRow ~= ShadedRow then
				ShadedRow = CellRow

				const CenterY = math.min(Band.Y0 + CellRow * Cell + Cell // 2, Band.Y1 - 1)

				for Block = 0, (Band.X1 - Band.X0 - 1) // Cell do
					const CenterX = math.min(Band.X0 + Block * Cell + Cell // 2, Band.X1 - 1)

					Band.Reds[Block + 1], Band.Greens[Block + 1], Band.Blues[Block + 1] = Outline.Shade(Parameters, Left + CenterX + 0.5, Top + CenterY + 0.5, Uv[CenterX + 1])
				end
			end

			for X = Band.X0, Band.X1 - 1 do
				const Column = Columns[X + 1]
				local Alpha = 0
				local Red = 0
				local Green = 0
				local Blue = 0

				if Row >= 0 and Column >= 0 then
					Alpha = buffer.readu8(Pixels, (Row * Stride + Column) * 4 + 3)
				end

				if Alpha > 0 then
					const Block = (X - Band.X0) // Cell + 1

					Red = Band.Reds[Block]
					Green = Band.Greens[Block]
					Blue = Band.Blues[Block]
					Alpha = math.clamp((Alpha * Opacity + 0.5) // 1, 0, 255)
				end

				buffer.writeu8(Band.Buffer, Index, ToByte(Red))
				buffer.writeu8(Band.Buffer, Index + 1, ToByte(Green))
				buffer.writeu8(Band.Buffer, Index + 2, ToByte(Blue))
				buffer.writeu8(Band.Buffer, Index + 3, Alpha)

				Index += 4
			end
		end

		Ring.Image:WritePixelsBuffer(Vector2.new(Band.X0, Band.Y0), Vector2.new(Band.X1 - Band.X0, Band.Y1 - Band.Y0), Band.Buffer)
	end

	const Cursor = Ring.Parameters.CursorPosition
	const Light = Ring.Parameters.LightPosition

	Ring.Dirty = false
	Ring.Near = Near
	Ring.RenderedX = Left
	Ring.RenderedY = Top
	Ring.RenderedCursorX = Cursor[1]
	Ring.RenderedCursorY = Cursor[2]
	Ring.RenderedLightX = Light[1]
	Ring.RenderedLightY = Light[2]
end

-- Draws the ring of a panel's style box into Host (its size Width x Height), in the colors of the material's parameters.
-- Answers true: the ring depends on the size. A box that is not a StyleBoxFlat leaves no ring. Answers nil when the device is
-- out of memory for the ring's picture (the caller draws the box without it).
const function Draw(Host: Frame, Gui: GuiObject, Material: MaterialModule.Material, Box: Theme.Resource?, Modulate: { number }, LayoutWidth: number, LayoutHeight: number): boolean?
	-- The layout gives fractional sizes; the ring is drawn on the element's whole pixels, rounded to the nearest.
	const Width = math.round(LayoutWidth)
	const Height = math.round(LayoutHeight)

	if not Box or Box.Type ~= "StyleBoxFlat" then
		Release(Host)

		return false
	end

	const Properties = Box.Properties
	const Key = StyleBoxRender.Key(Properties, Modulate)
	const Existing = Rings[Host]

	if Existing and Existing.Key == Key and Existing.Width == Width and Existing.Height == Height then
		Existing.Gui = Gui
		Existing.Dirty = true

		return true
	end

	Release(Host)

	for _, Child in Host:GetChildren() do
		Child:Destroy()
	end

	const Coverage, Columns, Rows = CoverageOf(Properties, Modulate, Width, Height)
	const Size = Vector2.new(math.clamp(Width, 1, SideLimit), math.clamp(Height, 1, SideLimit))
	const Image = AssetService:CreateEditableImage({ Size = Size })

	if not Image then
		return nil
	end

	const Label = Instance.new("ImageLabel")

	Label.Name = "Outline"
	Label.BackgroundTransparency = 1
	Label.BorderSizePixel = 0
	Label.Size = UDim2.fromOffset(Size.X, Size.Y)
	Label.ScaleType = Enum.ScaleType.Stretch
	Label.ResampleMode = Enum.ResamplerMode.Pixelated
	Label.ImageContent = Content.fromObject(Image)
	Label:SetAttribute("KeepColor", true)
	Label.Parent = Host

	const Bands: { Band } = {}

	for _, Strip in Outline.Strips(Properties, Width, Height) do
		const X1 = math.min(Strip.X1, SideLimit)
		const Y1 = math.min(Strip.Y1, SideLimit)

		if X1 > Strip.X0 and Y1 > Strip.Y0 then
			table.insert(Bands, {
				X0 = Strip.X0,
				Y0 = Strip.Y0,
				X1 = X1,
				Y1 = Y1,
				Buffer = buffer.create((X1 - Strip.X0) * (Y1 - Strip.Y0) * 4),
				Reds = table.create((X1 - Strip.X0) // Cell + 1, 0),
				Greens = table.create((X1 - Strip.X0) // Cell + 1, 0),
				Blues = table.create((X1 - Strip.X0) // Cell + 1, 0),
			})
		end
	end

	Rings[Host] = {
		Gui = Gui,
		Label = Label,
		Image = Image,
		Key = Key,
		Width = Width,
		Height = Height,
		Coverage = Coverage,
		Columns = Columns,
		Rows = Rows,
		Uv = Outline.UvTable(Width, Outline.Grow(Properties)),
		Bands = Bands,
		Parameters = Outline.FromMaterial(Material),
		Dirty = true,
		Near = false,
		NearNow = false,
		RenderedX = 0,
		RenderedY = 0,
		RenderedCursorX = 0,
		RenderedCursorY = 0,
		RenderedLightX = 0,
		RenderedLightY = 0,
		RenderedAt = 0,
	}

	return true
end

-- Records a parameter of a ring's shader (Name is the shader's name): a color change redraws it at the next flush.
const function SetParameter(Host: Frame, Name: string, Value: unknown)
	const Ring = Rings[Host]

	if Ring and Outline.Set(Ring.Parameters, Name, Value) == "Color" then
		Ring.Dirty = true
	end
end

-- The time a frame may spend redrawing rings (seconds). The rings that are left wait for the next frame, the oldest first, so a hover
-- over many rings costs a bounded part of a frame instead of all of it.
const FlushBudget = 0.003

const Pending: { Ring } = {}

const function OlderFirst(A: Ring, B: Ring): boolean
	return A.RenderedAt < B.RenderedAt
end

-- Redraws the rings whose colors may have changed: a changed parameter, or a move while a glow reaches the element now
-- or reached it at the last redraw.
const function Flush()
	table.clear(Pending)

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
			Ring.NearNow = Near
			table.insert(Pending, Ring)
		end
	end

	if #Pending == 0 then
		return
	end

	table.sort(Pending, OlderFirst)

	const Start = os.clock()

	for Index, Ring in Pending do
		if Index > 1 and os.clock() - Start > FlushBudget then
			break
		end

		const Position = Scale.PositionOf(Ring.Gui)

		Render(Ring, Position.x, Position.y, Ring.NearNow)
		Ring.RenderedAt = Start
	end
end

return {
	Draw = Draw,
	SetParameter = SetParameter,
	Release = Release,
	Flush = Flush,
}
