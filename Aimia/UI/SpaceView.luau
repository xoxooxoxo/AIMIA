--!strict
--!native
--!optimize 2

--[[
	The Waves menu space on screen, as a still image: one frame of the space (Spaces/Shaders/WavesPass) drawn into a
	hidden image over a few frames within a CPU budget, then faded in once over a black backdrop. After that nothing
	runs per frame; the frame is drawn again only when the screen size changes.

	Design Notes
		DEVIATION(render): the user asked for a static background. The space is drawn once at its rest pose (Waves.RestCamera:
		the camera after the intro) and at StaticTime seconds of the sky's drift, so the intro tweens, the sky's drift,
		the mouse-driven sky rotation and the water ripple do not move. Waves.Process is not called.
		AimiaData/MenuBackground replaces the space with a host image (still, same fade) or disables the background.
		The image is at most MaxWidth pixels wide (EditableImage's limit is 1024), with the view's aspect, stretched with
		smooth resampling.
		The blur panels (UI/Shaders/Blur) show the blurred copy of the backdrop (UI/Shaders/BlurSource): the rows are added
		as they are drawn, then the copy is blurred and dithered in slices of BlurBudget. The copy is rebuilt on a size change.
		A host image with Pixels is blurred the same way (its rows are added from the pixels); without Pixels its panels show
		the image sharp (DEVIATION(render): an asset id cannot be read back).
]]

const AssetService = game:GetService("AssetService")
const RunService = game:GetService("RunService")

const Frames = require("./Frames")

const MenuBackground = require("../../AimiaData/MenuBackground")
const Waves = require("../Spaces/Waves")
const WavesPass = require("../Spaces/Shaders/WavesPass")
const BlurSource = require("./Shaders/BlurSource")
const Blur = require("./Shaders/Blur")

const MaxWidth = 960
const DefaultRatio = 16 / 9
const FrameBudget = 0.004
const BlurBudget = 0.003
-- (the budgets above are the most a frame spends; a frame spends at most these shares of an average frame, so drawing
-- never halves a high frame rate: Frames.Budget)
const FrameShare = 0.2
const BlurShare = 0.15
const MinBudget = 0.0003
const FadeDuration = 1
const StaticTime = 12

-- The label sits below every ZIndex the scene builder uses (its StyleBoxes are -2 inside their control); the backdrop
-- is below it.
const LabelZIndex = -1000
const BackdropZIndex = LabelZIndex - 1

export type View = {
	Space: Waves.Waves,
	Parent: GuiBase2d,
	Backdrop: Frame,
	Label: ImageLabel,
	Host: MenuBackground.Decoded?,
	Image: EditableImage?,
	Size: Vector2,
	Width: number,
	Height: number,
	RowBuffer: buffer,
	Shown: { number },
	Above: { number },
	Pass: WavesPass.Pass?,
	Feeding: boolean,
	NextRow: number,
	NextColumn: number,
	Fade: number,
	Connection: RBXScriptConnection?,
	SizeConnection: RBXScriptConnection?,
	Blur: BlurSource.BlurSource?,
	BlurImage: EditableImage?,
}

-- Hands the blurred copy to the blur panels (UI/Shaders/Blur); the previous copy is destroyed.
const function ShowBlur(View: View, Copy: BlurSource.BlurSource)
	const Size = Vector2.new(Copy.SmallWidth, Copy.SmallHeight)
	const Small = AssetService:CreateEditableImage({ Size = Size })

	-- (the device is out of memory for pictures: the panels keep what they show, and the copy is done with)
	if not Small then
		View.Blur = nil

		return
	end

	Small:WritePixelsBuffer(Vector2.zero, Size, Copy.Pixels)

	if View.BlurImage then
		View.BlurImage:Destroy()
	end

	View.BlurImage = Small
	View.Blur = nil

	Blur.SetSource(View.Parent, Content.fromObject(Small), Copy.Pixels, Copy.SmallWidth, Copy.SmallHeight)
end

-- The image size for a view of Size: at most MaxWidth wide, with Size's aspect.
const function ImageSize(Size: Vector2): (number, number)
	const Ratio = if Size.X > 0 and Size.Y > 0 then Size.X / Size.Y else DefaultRatio
	const Width = math.max(1, math.min(MaxWidth, Size.X // 1))

	return Width, math.max(1, math.round(Width / Ratio))
end

-- Draws rows of the hidden image under the frame budget, adding each to the copy; answers true once the image is complete.
const function DrawFrame(View: View): boolean
	const Deadline = os.clock() + Frames.Budget(FrameShare, MinBudget, FrameBudget)
	const Pass = View.Pass :: WavesPass.Pass
	-- (nil when the device was out of memory for it: the blurred copy is still made)
	const Image = View.Image
	const Copy = View.Blur :: BlurSource.BlurSource

	while os.clock() < Deadline do
		const Column = WavesPass.DrawSpan(Pass, View.RowBuffer, View.NextRow, View.NextColumn, Deadline)

		if Column < View.Width then
			View.NextColumn = Column

			return false
		end

		if Image then
			Image:WritePixelsBuffer(Vector2.new(0, View.NextRow), Vector2.new(View.Width, 1), View.RowBuffer)
		end

		BlurSource.AddRow(Copy, View.RowBuffer, View.NextRow)
		WavesPass.EndRow(Pass)
		View.NextRow += 1
		View.NextColumn = 0

		if View.NextRow >= View.Height then
			return true
		end
	end

	return false
end

-- Adds rows of the host image to the copy under the frame budget; answers true once all are added.
const function FeedHost(View: View): boolean
	const Deadline = os.clock() + Frames.Budget(FrameShare, MinBudget, FrameBudget)
	const Host = View.Host :: MenuBackground.Decoded
	const Copy = View.Blur :: BlurSource.BlurSource
	const RowBytes = View.Width * 4

	while View.NextRow < View.Height and os.clock() < Deadline do
		buffer.copy(View.RowBuffer, 0, Host.Pixels, View.NextRow * RowBytes, RowBytes)
		BlurSource.AddRow(Copy, View.RowBuffer, View.NextRow)
		View.NextRow += 1
	end

	return View.NextRow >= View.Height
end

-- Feeds the rows of the frame (or of the host image) to the copy; when they are all in, the fade starts and the copy is
-- blurred in slices of BlurBudget until it is shown.
const function Step(View: View, Delta: number)
	if View.Feeding then
		const Fed = if View.Pass then DrawFrame(View) else FeedHost(View)

		if Fed then
			View.Feeding = false
			View.Pass = nil

			if View.Image then
				View.Label.ImageContent = Content.fromObject(View.Image)
			end
		end

		return
	end

	const Copy = View.Blur

	if Copy and BlurSource.Process(Copy, os.clock() + Frames.Budget(BlurShare, MinBudget, BlurBudget)) then
		ShowBlur(View, Copy)
	end

	View.Fade = math.min(FadeDuration, View.Fade + Frames.UIStep())
	View.Label.ImageTransparency = 1 - View.Fade / FadeDuration
	Blur.SetFade(View.Fade / FadeDuration)

	if View.Fade >= FadeDuration and View.Blur == nil and View.Connection then
		View.Connection:Disconnect()
		View.Connection = nil
	end
end

-- Starts feeding the frame (or the host image) for the parent's current size, into a new copy and, for the frame, a new
-- hidden image.
const function Start(View: View)
	const Size = View.Parent.AbsoluteSize
	const Host = View.Host
	local Width = 0
	local Height = 0

	if Host then
		Width = Host.Width
		Height = Host.Height
	else
		Width, Height = ImageSize(Size)
	end

	View.Size = Size
	View.Width = Width
	View.Height = Height
	View.RowBuffer = buffer.create(Width * 4)
	View.Blur = BlurSource.New(Width, Height, Size.X, Size.Y)
	View.NextRow = 0
	View.NextColumn = 0
	View.Feeding = true

	if not Host then
		if View.Image then
			View.Image:Destroy()
		end

		View.Shown = table.create(Width, 0)
		View.Above = table.create(Width, 0)
		View.Image = AssetService:CreateEditableImage({ Size = Vector2.new(Width, Height) })
		View.Pass = WavesPass.Begin(View.Space, Width, Height, View.Shown, View.Above)
		View.Fade = 0
		View.Label.ImageTransparency = 1
		Blur.SetFade(0)
	end

	if View.Connection == nil then
		View.Connection = RunService.PreRender:Connect(function(Delta: number)
			Step(View, Delta)
		end)
	end
end

-- Mounts the view under Parent and draws it. Mount it before the scene is built: the label is drawn behind the scene's
-- controls.
const function Mount(Parent: GuiBase2d, Space: Waves.Waves): View
	const Backdrop = Instance.new("Frame")
	const Label = Instance.new("ImageLabel")

	Backdrop.Name = "SpaceBackdrop"
	Backdrop.Size = UDim2.fromScale(1, 1)
	Backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	Backdrop.BorderSizePixel = 0
	Backdrop.ZIndex = BackdropZIndex
	Backdrop.Parent = Parent

	Label.Name = "SpaceView"
	Label.Size = UDim2.fromScale(1, 1)
	Label.BackgroundTransparency = 1
	Label.BorderSizePixel = 0
	Label.ScaleType = Enum.ScaleType.Stretch
	Label.ResampleMode = Enum.ResamplerMode.Default
	Label.ImageTransparency = 1
	Label.ZIndex = LabelZIndex
	Label.Parent = Parent

	Space.Elapsed = StaticTime

	const View = {
		Space = Space,
		Parent = Parent,
		Backdrop = Backdrop,
		Label = Label,
		Host = nil,
		Image = nil,
		Size = Vector2.zero,
		Width = 0,
		Height = 0,
		RowBuffer = buffer.create(0),
		Shown = {},
		Above = {},
		Pass = nil,
		Feeding = false,
		NextRow = 0,
		NextColumn = 0,
		Fade = 0,
		Connection = nil,
		SizeConnection = nil,
		Blur = nil,
		BlurImage = nil,
	} :: View

	if MenuBackground.Disabled then
		return View
	end

	const Custom = MenuBackground.Image
	const Decoded = MenuBackground.Pixels

	if Custom and Decoded then
		View.Host = Decoded
		Label.Image = Custom
	elseif Custom then
		-- The host's own still image, which cannot be read: the panels show it sharp, and the fade is the same.
		Label.Image = Custom
		Label.ImageTransparency = 1
		Blur.SetSource(Parent, Content.fromUri(Custom), nil, 0, 0)
		Blur.SetFade(0)
		View.Connection = RunService.PreRender:Connect(function(Delta: number)
			Step(View, Delta)
		end)

		return View
	end

	Start(View)

	View.SizeConnection = Parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if Parent.AbsoluteSize ~= View.Size then
			Start(View)
		end
	end)

	return View
end

-- Stops drawing and removes the backdrop and the label.
const function Destroy(View: View)
	if View.Connection then
		View.Connection:Disconnect()
	end

	if View.SizeConnection then
		View.SizeConnection:Disconnect()
	end

	Blur.SetSource(nil, nil, nil, 0, 0)

	if View.BlurImage then
		View.BlurImage:Destroy()
	end

	if View.Image then
		View.Image:Destroy()
	end

	View.Label:Destroy()
	View.Backdrop:Destroy()
end

return {
	Mount = Mount,
	Destroy = Destroy,
}
