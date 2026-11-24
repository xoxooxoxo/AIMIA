--!strict
--!native
--!optimize 2

--[[
	The screen behind the results scene's blur panels (res://scenes/results.tscn): what Godot's screen_texture holds when
	GraphBlur, the top bar and the footer draw, which is the scene's Background, CoverBackground and Cover. Their blur
	(UI/Shaders/Blur) shows a blurred copy of that picture, made here for the screen's size and handed to the panels.

	Design Notes
		The picture is composed in pixels, then blurred by UI/Shaders/BlurSource as the menu space is (UI/SpaceView): the layers
		of the scene in order, each blended over the one before with its alpha. Background is the ColorRect's color. CoverBackground
		is the cover scaled to cover the screen (stretch_mode 6) at the modulate alpha 0.14902. Cover is the cover fitted in the
		screen, centered (stretch_mode 5), with alpha_gradient.gdshader: alpha = (0.5 - abs(u - 0.5)) * 3 / 1.5 over its own width.
		The Holder's own drawing (texts, the graph) is not in the copy: the panels lie where there is none, apart from the graph's
		line and its labels, which are over the strip.
		The copy is made in slices of the frame budget, and again when the screen is resized. A scene without a cover is the
		Background alone.
]]

const AssetService = game:GetService("AssetService")
const RunService = game:GetService("RunService")

const Frames = require("./Frames")

const Blur = require("./Shaders/Blur")
const BlurSource = require("./Shaders/BlurSource")
const ImageDecode = require("../Util/ImageDecode")
const Items = require("./Item")

-- The copy is at most this wide, with the screen's aspect (as UI/SpaceView).
const MaxWidth = 960
const DefaultRatio = 16 / 9
const RowBudget = 0.004
const BlurBudget = 0.003
-- (the most a frame spends; a frame spends at most these shares of an average frame, as UI/SpaceView: Frames.Budget)
const RowShare = 0.2
const BlurShare = 0.15
const MinBudget = 0.0003

-- results.tscn: Background's color (0.050980393 of 255), and CoverBackground's modulate alpha.
const BackgroundByte = 13
const CoverBackgroundAlpha = 0.14902

type Backdrop = {
	Item: Items.Item,
	Image: ImageDecode.Image?,
	Screen: ScreenGui?,
	Size: Vector2,
	Width: number,
	Height: number,
	Row: number,
	RowBuffer: buffer,
	Copy: BlurSource.BlurSource?,
	Small: EditableImage?,
	Shown: buffer?,
	Connection: RBXScriptConnection?,
	CoverScale: number,
	FitScale: number,
	FitLeft: number,
	FitTop: number,
	FitWidth: number,
	FitHeight: number,
}

-- The color (0 to 255) of one pixel of the picture: the layers blended in order.
const function Compose(Backdrop: Backdrop, X: number, Y: number): (number, number, number)
	local Red = BackgroundByte
	local Green = BackgroundByte
	local Blue = BackgroundByte
	const Image = Backdrop.Image

	if not Image then
		return Red, Green, Blue
	end

	const Pixels = Image.Pixels
	const ImageWidth = Image.Width
	const ImageHeight = Image.Height
	const CenterX = X + 0.5
	const CenterY = Y + 0.5
	-- CoverBackground: the cover scaled to cover the screen, centered.
	const CoverX = math.clamp((((CenterX - Backdrop.Width / 2) / Backdrop.CoverScale) + ImageWidth / 2) // 1, 0, ImageWidth - 1)
	const CoverY = math.clamp((((CenterY - Backdrop.Height / 2) / Backdrop.CoverScale) + ImageHeight / 2) // 1, 0, ImageHeight - 1)
	const CoverOffset = (CoverY * ImageWidth + CoverX) * 4
	const CoverAlpha = CoverBackgroundAlpha * buffer.readu8(Pixels, CoverOffset + 3) / 255

	Red += (buffer.readu8(Pixels, CoverOffset) - Red) * CoverAlpha
	Green += (buffer.readu8(Pixels, CoverOffset + 1) - Green) * CoverAlpha
	Blue += (buffer.readu8(Pixels, CoverOffset + 2) - Blue) * CoverAlpha

	-- Cover: fitted and centered, faded toward its left and right edges.
	const U = (CenterX - Backdrop.FitLeft) / Backdrop.FitWidth
	const V = (CenterY - Backdrop.FitTop) / Backdrop.FitHeight

	if U >= 0 and U < 1 and V >= 0 and V < 1 then
		const FitOffset = ((V * ImageHeight) // 1 * ImageWidth + (U * ImageWidth) // 1) * 4
		const FitAlpha = (0.5 - math.abs(U - 0.5)) * 2 * buffer.readu8(Pixels, FitOffset + 3) / 255

		Red += (buffer.readu8(Pixels, FitOffset) - Red) * FitAlpha
		Green += (buffer.readu8(Pixels, FitOffset + 1) - Green) * FitAlpha
		Blue += (buffer.readu8(Pixels, FitOffset + 2) - Blue) * FitAlpha
	end

	return Red, Green, Blue
end

-- Hands the blurred copy to the blur panels; the previous one is destroyed.
const function Show(Backdrop: Backdrop, Copy: BlurSource.BlurSource)
	const Screen = Backdrop.Screen :: ScreenGui
	const Size = Vector2.new(Copy.SmallWidth, Copy.SmallHeight)
	const Small = AssetService:CreateEditableImage({ Size = Size })

	-- (the device is out of memory for pictures: the panels keep what they show, and the copy is done with)
	if not Small then
		Backdrop.Copy = nil

		return
	end

	Small:WritePixelsBuffer(Vector2.zero, Size, Copy.Pixels)

	if Backdrop.Small then
		Backdrop.Small:Destroy()
	end

	Backdrop.Small = Small
	Backdrop.Shown = Copy.Pixels
	Backdrop.Copy = nil
	Blur.SetSource(Screen, Content.fromObject(Small), Copy.Pixels, Copy.SmallWidth, Copy.SmallHeight)
	Blur.SetFade(1)
end

-- Starts the copy for the screen's current size.
const function Begin(Backdrop: Backdrop, Screen: ScreenGui)
	const Size = Screen.AbsoluteSize
	const Ratio = if Size.X > 0 and Size.Y > 0 then Size.X / Size.Y else DefaultRatio
	const Width = math.max(1, math.min(MaxWidth, Size.X // 1))
	const Height = math.max(1, math.round(Width / Ratio))
	const Image = Backdrop.Image

	Backdrop.Screen = Screen
	Backdrop.Size = Size
	Backdrop.Width = Width
	Backdrop.Height = Height
	Backdrop.Row = 0
	Backdrop.RowBuffer = buffer.create(Width * 4)
	Backdrop.Copy = BlurSource.New(Width, Height, Size.X, Size.Y)

	if Image then
		Backdrop.CoverScale = math.max(Width / Image.Width, Height / Image.Height)
		Backdrop.FitScale = math.min(Width / Image.Width, Height / Image.Height)
		Backdrop.FitWidth = Image.Width * Backdrop.FitScale
		Backdrop.FitHeight = Image.Height * Backdrop.FitScale
		Backdrop.FitLeft = (Width - Backdrop.FitWidth) / 2
		Backdrop.FitTop = (Height - Backdrop.FitHeight) / 2
	end
end

-- Composes rows under the frame budget, then blurs in slices until the copy is shown.
const function Step(Backdrop: Backdrop)
	const Host = Backdrop.Item.Instance :: Instance?
	const Screen = if Host then Host:FindFirstAncestorOfClass("ScreenGui") else nil

	if not Screen then
		return
	end

	if Backdrop.Screen ~= Screen or Backdrop.Size ~= Screen.AbsoluteSize then
		if Screen.AbsoluteSize.X < 1 or Screen.AbsoluteSize.Y < 1 then
			return
		end

		Begin(Backdrop, Screen)
	end

	const Copy = Backdrop.Copy

	if not Copy then
		return
	end

	const Deadline = os.clock() + Frames.Budget(RowShare, MinBudget, RowBudget)
	const Row = Backdrop.RowBuffer
	-- (the blur starts the frame after the last rows, never in the same frame)
	local Composed = false

	while Backdrop.Row < Backdrop.Height and os.clock() < Deadline do
		Composed = true

		const Y = Backdrop.Row

		for X = 0, Backdrop.Width - 1 do
			const Red, Green, Blue = Compose(Backdrop, X, Y)

			buffer.writeu8(Row, X * 4, math.clamp((Red + 0.5) // 1, 0, 255))
			buffer.writeu8(Row, X * 4 + 1, math.clamp((Green + 0.5) // 1, 0, 255))
			buffer.writeu8(Row, X * 4 + 2, math.clamp((Blue + 0.5) // 1, 0, 255))
			buffer.writeu8(Row, X * 4 + 3, 255)
		end

		BlurSource.AddRow(Copy, Row, Y)
		Backdrop.Row += 1
	end

	if Backdrop.Row >= Backdrop.Height and not Composed and BlurSource.Process(Copy, os.clock() + Frames.Budget(BlurShare, MinBudget, BlurBudget)) then
		Show(Backdrop, Copy)
	end
end

-- Starts the backdrop of a results scene item for the cover (nil: none). Answers the function that stops it.
const function Start(Item: Items.Item, Image: ImageDecode.Image?): () -> ()
	const Backdrop = {
		Item = Item,
		Image = Image,
		Screen = nil,
		Size = Vector2.zero,
		Width = 0,
		Height = 0,
		Row = 0,
		RowBuffer = buffer.create(4),
		Copy = nil,
		Small = nil,
		Shown = nil,
		Connection = nil,
		CoverScale = 1,
		FitScale = 1,
		FitLeft = 0,
		FitTop = 0,
		FitWidth = 1,
		FitHeight = 1,
	} :: Backdrop

	Backdrop.Connection = RunService.PreRender:Connect(function()
		if not Frames.Paused then
			Step(Backdrop)
		end
	end)

	return function()
		if Backdrop.Connection then
			Backdrop.Connection:Disconnect()
			Backdrop.Connection = nil
		end

		Blur.ClearIf(Backdrop.Shown)

		-- (the decoded cover is the biggest thing here: it goes with the screen)
		Backdrop.Image = nil
		Backdrop.Shown = nil
		Backdrop.Copy = nil

		if Backdrop.Small then
			Backdrop.Small:Destroy()
			Backdrop.Small = nil
		end
	end
end

return Start
