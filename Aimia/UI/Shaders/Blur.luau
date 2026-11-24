--!strict
--!optimize 2

--[[
	The blur shader of the panels (scripts/shaders/ui_blur.gdshader) on a Panel: the screen behind the panel, blurred and
	scaled by its brightness, in the panel's fill. The screen is the backdrop's blurred copy (UI/Shaders/BlurSource, made by
	UI/SpaceView). Each panel shows its part of the copy in a label of its own rect, rounded by the style box's corner
	radius, so the copy lines up with the screen behind the panel.

	Paradigm
		Panels are keyed by the style host. Draw creates one, SetParameter sets its brightness, Flush (once per frame, from
		UI/Nodes) places the labels, Release frees one. SetSource and SetFade come from the backdrop.

	Design Notes
		COLOR.rgb = blur * brightness with the alpha kept: the label's ImageColor3 is the brightness times the backdrop's fade
		(at most 1; above 1 a brighter copy of the image is made per value), and its transparency is 1 - the fill alpha (the
		bg_color alpha times self_modulate's), which Draw sets once: UI/Item records that transparency after Draw and applies
		the chain's modulate alpha to it. Its color is not tinted (KeepColor), since the shader overwrites the color.
		DEVIATION(render): one corner radius for the four corners, the largest (the scene's Play and Extras backgrounds have
		left corners of 3 and right corners of 0: all four are rounded by 3 pixels at the screen's corners).
		DEVIATION(render): a host image without pixels (AimiaData/MenuBackground.Image only) has no known size, so it cannot
		be cropped: it is shown sharp in the screen's rect, clipped by the panel and not rounded. With pixels it is blurred.
		No blur panel has a border; a border would need a UIStroke.
		The label has the style host's ZIndex (-2), after it in the tree, so the fill is above the host and below the panel's
		text and child controls (ZIndex 0 and up). A ZIndex of 1, the default, hid the text of a test panel's label in Studio;
		the same happens to the controls of the TopBar and Jukebox blur panels (the likely cause of the "buttons under are
		wrong" report, not yet checked on the menu).
]]

const AssetService = game:GetService("AssetService")

const MaterialModule = require("./Material")
const Scale = require("../Scale")
const Theme = require("../Theme")

-- The style host's ZIndex (UI/SceneBuilder). The label shares it: the ScreenGui's ZIndexBehavior is Global, so the label's own
-- ZIndex is not inherited, and a higher one covers the text (ZIndex 0) and the child controls of the panel.
const StyleZIndex = -2

const CornerKeys = {
	"corner_radius_top_left",
	"corner_radius_top_right",
	"corner_radius_bottom_right",
	"corner_radius_bottom_left",
}

type Panel = {
	Gui: GuiObject,
	Host: Frame,
	Label: ImageLabel,
	Corner: UICorner,
	Radius: number,
	Brightness: number,
	Alpha: number,
	Cropped: boolean,
	Left: number,
	Top: number,
	Width: number,
	Height: number,
	ScreenWidth: number,
	ScreenHeight: number,
}

const Panels: { [Frame]: Panel } = {}

-- The backdrop the panels show: the screen's parent, the copy's content, its RGBA8 pixels (nil when the copy is not ours to
-- read: a host image shown sharp), its size, and the fade of the backdrop.
local Parent: GuiBase2d? = nil
local Source: Content? = nil
local Pixels: buffer? = nil
local SourceWidth = 0
local SourceHeight = 0
local Fade = 1

-- Brighter copies of the image, one per brightness above 1.
const Brighter: { [number]: Content } = {}
const BrighterImages: { EditableImage } = {}

-- The content a brightness shows and the tint of the label for it: the brightness itself at most 1, else a brighter copy.
const function ContentOf(Brightness: number): (Content?, number)
	const Copy = Pixels

	if Brightness <= 1 or not Copy then
		return Source, math.min(1, Brightness)
	end

	const Cached = Brighter[Brightness]

	if Cached then
		return Cached, 1
	end

	const Size = Vector2.new(SourceWidth, SourceHeight)
	const Image = AssetService:CreateEditableImage({ Size = Size })

	-- (the device is out of memory for pictures: the copy as it is, not brightened, until the backdrop changes)
	if not Image then
		Brighter[Brightness] = Source :: Content

		return Source, 1
	end

	const Scaled = buffer.create(SourceWidth * SourceHeight * 4)

	for Byte = 0, SourceWidth * SourceHeight * 4 - 1 do
		buffer.writeu8(Scaled, Byte, math.clamp((buffer.readu8(Copy, Byte) * Brightness + 0.5) // 1, 0, 255))
	end

	Image:WritePixelsBuffer(Vector2.zero, Size, Scaled)

	const Shown = Content.fromObject(Image)

	Brighter[Brightness] = Shown
	table.insert(BrighterImages, Image)

	return Shown, 1
end

-- The label's content and color for the panel's brightness and the backdrop's fade (its transparency is set by Draw).
const function Refresh(Panel: Panel)
	const Picture, Tint = ContentOf(Panel.Brightness)
	const Shade = Tint * Fade

	Panel.Label.Visible = Picture ~= nil

	if Picture then
		Panel.Label.ImageContent = Picture
	end

	Panel.Label.ImageColor3 = Color3.new(Shade, Shade, Shade)
end

-- Places a panel's label. With the copy: over the panel's own rect, showing the copy's crop of that rect and rounded by the
-- corner radius. Without it: over the screen's rect in the panel (not cropped, not rounded; the panel clips it).
const function Place(Panel: Panel)
	const Screen = Parent

	if not Screen then
		return
	end

	const Origin = Screen.AbsolutePosition
	const ScreenSize = Scale.ScreenSizeOf(Screen)
	const Gui = Panel.Gui
	const Cropped = Pixels ~= nil
	const Left = if Cropped then Gui.AbsolutePosition.X - Origin.X else Origin.X - Gui.AbsolutePosition.X
	const Top = if Cropped then Gui.AbsolutePosition.Y - Origin.Y else Origin.Y - Gui.AbsolutePosition.Y
	const Width = if Cropped then Gui.AbsoluteSize.X else ScreenSize.X
	const Height = if Cropped then Gui.AbsoluteSize.Y else ScreenSize.Y

	if Cropped == Panel.Cropped and Left == Panel.Left and Top == Panel.Top and Width == Panel.Width and Height == Panel.Height and ScreenSize.X == Panel.ScreenWidth and ScreenSize.Y == Panel.ScreenHeight then
		return
	end

	Panel.Cropped = Cropped
	Panel.Left = Left
	Panel.Top = Top
	Panel.Width = Width
	Panel.Height = Height
	Panel.ScreenWidth = ScreenSize.X
	Panel.ScreenHeight = ScreenSize.Y

	const Label = Panel.Label

	if Cropped then
		const ScaleX = SourceWidth / math.max(1, ScreenSize.X)
		const ScaleY = SourceHeight / math.max(1, ScreenSize.Y)

		Label.Position = UDim2.fromScale(0, 0)
		Label.Size = UDim2.fromScale(1, 1)
		Label.ImageRectOffset = Vector2.new(Left * ScaleX, Top * ScaleY)
		Label.ImageRectSize = Vector2.new(Width * ScaleX, Height * ScaleY)
		Panel.Corner.CornerRadius = UDim.new(0, Panel.Radius)
		Panel.Host.ClipsDescendants = false
	else
		-- The label is in the panel's layout pixels; the offsets above are screen pixels.
		const Factor = Scale.FactorOf(Gui)

		Label.Position = UDim2.fromOffset(Left / Factor, Top / Factor)
		Label.Size = UDim2.fromOffset(Width / Factor, Height / Factor)
		Label.ImageRectOffset = Vector2.zero
		Label.ImageRectSize = Vector2.zero
		Panel.Corner.CornerRadius = UDim.new(0, 0)
		Panel.Host.ClipsDescendants = true
	end
end

-- Destroys the blur of a style host, if it has one.
const function Release(Host: Frame)
	const Panel = Panels[Host]

	if Panel then
		Panel.Label:Destroy()
		Host.ClipsDescendants = false
		Panels[Host] = nil
	end
end

-- Shows the blur in a Panel's style host (its fill alpha and brightness); answers false: the label is placed per frame.
const function Draw(Host: Frame, Gui: GuiObject, Material: MaterialModule.Material, Box: Theme.Resource?, Own: { number }): boolean
	Release(Host)

	for _, Child in Host:GetChildren() do
		Child:Destroy()
	end

	if not Box or Box.Type ~= "StyleBoxFlat" or Box.Properties["draw_center"] == false then
		return false
	end

	const Background = MaterialModule.ColorOf(Box.Properties["bg_color"], { 0.6, 0.6, 0.6, 1 })
	const Label = Instance.new("ImageLabel")
	const Corner = Instance.new("UICorner")
	local Radius = 0

	for _, Key in CornerKeys do
		Radius = math.max(Radius, MaterialModule.NumberOf(Box.Properties[Key], 0))
	end

	Label.Name = "Blur"
	Label.BackgroundTransparency = 1
	Label.BorderSizePixel = 0
	Label.ZIndex = StyleZIndex
	Label.ScaleType = Enum.ScaleType.Stretch
	Label.ResampleMode = Enum.ResamplerMode.Default
	Label.ImageTransparency = 1 - Background[4] * Own[4]
	Label:SetAttribute("KeepColor", true)
	Corner.Parent = Label
	Label.Parent = Host

	const Panel = {
		Gui = Gui,
		Host = Host,
		Label = Label,
		Corner = Corner,
		Radius = Radius,
		Brightness = MaterialModule.NumberOf(MaterialModule.Parameter(Material, "brightness"), 1),
		Alpha = Background[4] * Own[4],
		Cropped = false,
		Left = -1,
		Top = -1,
		Width = -1,
		Height = -1,
		ScreenWidth = -1,
		ScreenHeight = -1,
	}

	Panels[Host] = Panel

	Refresh(Panel)
	Place(Panel)

	return false
end

-- Records a parameter of a blur panel's shader: its brightness.
const function SetParameter(Host: Frame, Name: string, Value: unknown)
	const Panel = Panels[Host]

	if Panel and Name == "brightness" then
		Panel.Brightness = MaterialModule.NumberOf(Value, 1)
		Refresh(Panel)
	end
end

-- Sets the backdrop the panels show: the screen's parent, the copy (content, and its RGBA8 pixels when they are readable)
-- and its size. Nil content shows nothing.
const function SetSource(NewParent: GuiBase2d?, NewSource: Content?, NewPixels: buffer?, Width: number, Height: number)
	Parent = NewParent
	Source = NewSource
	Pixels = NewPixels
	SourceWidth = Width
	SourceHeight = Height

	for _, Image in BrighterImages do
		Image:Destroy()
	end

	table.clear(BrighterImages)
	table.clear(Brighter)

	for _, Panel in Panels do
		Refresh(Panel)
		Place(Panel)
	end
end

-- Removes the backdrop when it is still the copy with these pixels (a scene that made its own copy leaves it: a newer copy stays).
const function ClearIf(Owner: buffer?)
	if Owner ~= nil and Pixels == Owner then
		SetSource(nil, nil, nil, 0, 0)
	end
end

-- Sets the fade of the backdrop (0 to 1): the panels' blur fades with the image it blurs.
const function SetFade(Value: number)
	if Fade == Value then
		return
	end

	Fade = Value

	for _, Panel in Panels do
		Refresh(Panel)
	end
end

-- Places every panel's label (once per frame, from UI/Nodes).
const function Flush()
	for _, Panel in Panels do
		Place(Panel)
	end
end

return {
	Draw = Draw,
	SetParameter = SetParameter,
	SetSource = SetSource,
	ClearIf = ClearIf,
	SetFade = SetFade,
	Release = Release,
	Flush = Flush,
}
