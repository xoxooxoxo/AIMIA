--!strict
--!optimize 2

--[[
	Roblox styling for converted Godot resources: the font mapping, colors, and StyleBox drawing and margins.

	Design Notes
		Fonts: the only mapping from Godot font files to Roblox families. Ubuntu, Roboto and Nunito map to their
		Roblox families by weight; Comfortaa Bold (one label) uses Nunito Bold; Godot's built-in default font
		(Open Sans SemiBold, not a Roblox family) uses Source Sans Pro SemiBold.
		Font height: Godot's line (ascent + descent) comes from the font file's metrics (Metrics below), not from Roblox,
		whose line is TextSize high; a family without metrics here keeps Roblox's line.
		Colors: { Color = { r, g, b, a } } values; components above 1 (Godot HDR colors) are clamped for Color3.
		StyleBoxFlat is rendered by Godot's own geometry (UI/StyleBoxRender) into an EditableImage shown by an
		ImageLabel: a 9-slice image rendered once per style at its slice size when the box is sliceable and the
		control is at least that big, otherwise an image rendered at the control's size (DrawStyleBox then answers
		true, and the caller redraws it when the size changes). Images are cached per style key (and size).
]]

const AssetService = game:GetService("AssetService")

const Theme = require("./Theme")
const StyleNative = require("./StyleNative")
const StyleBoxRender = require("./StyleBoxRender")
const TextMetrics = require("./TextMetrics")

export type ColorValue = { Color: { number } }

const SourceSans = "rbxasset://fonts/families/SourceSansPro.json"

const Families = {
	["res://fonts/Ubuntu/Ubuntu-Regular.ttf"] = { Family = "rbxasset://fonts/families/Ubuntu.json", Weight = Enum.FontWeight.Regular, Style = Enum.FontStyle.Normal },
	["res://fonts/Ubuntu/Ubuntu-Medium.ttf"] = { Family = "rbxasset://fonts/families/Ubuntu.json", Weight = Enum.FontWeight.Medium, Style = Enum.FontStyle.Normal },
	["res://fonts/Roboto/Roboto-Medium.ttf"] = { Family = "rbxasset://fonts/families/Roboto.json", Weight = Enum.FontWeight.Medium, Style = Enum.FontStyle.Normal },
	["res://fonts/Roboto/Roboto-Bold.ttf"] = { Family = "rbxasset://fonts/families/Roboto.json", Weight = Enum.FontWeight.Bold, Style = Enum.FontStyle.Normal },
	["res://fonts/Roboto/Roboto-Italic.ttf"] = { Family = "rbxasset://fonts/families/Roboto.json", Weight = Enum.FontWeight.Regular, Style = Enum.FontStyle.Italic },
	["res://fonts/Nunito/Nunito-SemiBold.ttf"] = { Family = "rbxasset://fonts/families/Nunito.json", Weight = Enum.FontWeight.SemiBold, Style = Enum.FontStyle.Normal },
	["res://fonts/Nunito/Nunito-Bold.ttf"] = { Family = "rbxasset://fonts/families/Nunito.json", Weight = Enum.FontWeight.Bold, Style = Enum.FontStyle.Normal },
	["res://fonts/Comfortaa/Comfortaa-Bold.ttf"] = { Family = "rbxasset://fonts/families/Nunito.json", Weight = Enum.FontWeight.Bold, Style = Enum.FontStyle.Normal },
}

const SystemFamilies = {
	Ubuntu = "rbxasset://fonts/families/Ubuntu.json",
	Roboto = "rbxasset://fonts/families/Roboto.json",
	Nunito = "rbxasset://fonts/families/Nunito.json",
}

-- Godot's font metrics (ascent and descent as em fractions, descent positive) of the families above, from the hhea
-- tables of the Godot font files. Roboto's are the ones whose 16 px line is 19 px (the Sort buttons of the real menu:
-- 31 px rows, 4 px apart). SystemFont families without a row here keep Roblox's line height.
const Metrics = {
	["rbxasset://fonts/families/Roboto.json"] = { Ascent = 1900 / 2048, Descent = 500 / 2048 },
	["rbxasset://fonts/families/Ubuntu.json"] = { Ascent = 932 / 1000, Descent = 189 / 1000 },
	["rbxasset://fonts/families/Nunito.json"] = { Ascent = 1011 / 1000, Descent = 353 / 1000 },
	["rbxasset://fonts/families/SourceSansPro.json"] = { Ascent = 984 / 1000, Descent = 273 / 1000 },
}

-- The TextSize of a Roblox font whose glyphs are Godot's font_size Size: Godot's size is the em of the font, while a Roblox
-- TextSize is the height of the line (ascent + descent), so the em is TextSize over the line in ems (Roboto's digits are 0.48
-- of the TextSize in Roblox and 0.5615 em in the font file, 1 / 1.172 = 0.853). A family without metrics here keeps Size.
const function TextSizeOf(Font: Font, Size: number): number
	const Entry = (Metrics :: { [string]: { Ascent: number, Descent: number } })[Font.Family]

	if not Entry then
		return Size
	end

	return Size * (Entry.Ascent + Entry.Descent)
end

-- Godot's font height (font->get_height) of a Roblox font at Size pixels; nil when the family has no metrics here.
const function FontHeight(Font: Font, Size: number): number?
	const Entry = (Metrics :: { [string]: { Ascent: number, Descent: number } })[Font.Family]

	if not Entry then
		return nil
	end

	return TextMetrics.FontHeight(Entry.Ascent, Entry.Descent, Size)
end

const Weights = {
	[100] = Enum.FontWeight.Thin,
	[200] = Enum.FontWeight.ExtraLight,
	[300] = Enum.FontWeight.Light,
	[400] = Enum.FontWeight.Regular,
	[500] = Enum.FontWeight.Medium,
	[600] = Enum.FontWeight.SemiBold,
	[700] = Enum.FontWeight.Bold,
	[800] = Enum.FontWeight.ExtraBold,
	[900] = Enum.FontWeight.Heavy,
}

-- Rendered style boxes by StyleBoxRender.Key (plus the size when rendered at a control's size).
const Rendered: { [string]: { Image: EditableImage, Render: StyleBoxRender.Image, Center: Rect? } } = {}

const DefaultFont = Font.new(SourceSans, Enum.FontWeight.SemiBold, Enum.FontStyle.Normal)

-- A font resource (an ExtResource FontFile, or a SystemFont sub-resource) as a Roblox Font.
const function GetFont(Resource: Theme.Resource?): Font
	if not Resource then
		return DefaultFont
	end

	if Resource.Path then
		const Family = (Families :: { [string]: { Family: string, Weight: Enum.FontWeight, Style: Enum.FontStyle } })[Resource.Path]

		if Family then
			return Font.new(Family.Family, Family.Weight, Family.Style)
		end

		warn(`Aimia UI: no Roblox font for {Resource.Path}`)
		return DefaultFont
	end

	if Resource.Type == "SystemFont" then
		const Names = Resource.Properties["font_names"] :: { Values: { string } }?
		const Name = if Names then Names.Values[1] else nil
		const Family = if Name then (SystemFamilies :: { [string]: string })[Name] else nil
		const Weight = (Weights :: { [number]: Enum.FontWeight })[(Resource.Properties["font_weight"] :: number?) or 400]
		const Italic = Resource.Properties["font_italic"] == true

		return Font.new(Family or SourceSans, Weight or Enum.FontWeight.Regular, if Italic then Enum.FontStyle.Italic else Enum.FontStyle.Normal)
	end

	return DefaultFont
end

-- Color3, transparency and the raw components of a { Color = ... } value multiplied by a modulate color.
const function ToColor(Value: unknown, Modulate: { number }?): (Color3, number)
	const Components = if type(Value) == "table" then (Value :: ColorValue).Color else { 1, 1, 1, 1 }
	const Multiply = Modulate or { 1, 1, 1, 1 }
	const R = math.clamp(Components[1] * Multiply[1], 0, 1)
	const G = math.clamp(Components[2] * Multiply[2], 0, 1)
	const B = math.clamp(Components[3] * Multiply[3], 0, 1)
	const A = math.clamp((Components[4] or 1) * (Multiply[4] or 1), 0, 1)

	return Color3.new(R, G, B), 1 - A
end

const function Number(Properties: { [string]: unknown }, Key: string, Default: number): number
	const Value = Properties[Key]

	return if type(Value) == "number" then Value else Default
end

-- StyleBox::get_margin: the content margin when set (>= 0), otherwise the box's own style margin.
const function GetMargin(Box: Theme.Resource?, Side: string): number
	if not Box then
		return 0
	end

	const Content = Number(Box.Properties, `content_margin_{Side}`, -1)

	if Content >= 0 then
		return Content
	end

	if Box.Type == "StyleBoxFlat" then
		return Number(Box.Properties, `border_width_{Side}`, 0)
	elseif Box.Type == "StyleBoxTexture" then
		return Number(Box.Properties, `texture_margin_{Side}`, 0)
	elseif Box.Type == "StyleBoxLine" then
		const Thickness = Number(Box.Properties, "thickness", 1)
		const Vertical = Box.Properties["vertical"] == true

		if Vertical and (Side == "left" or Side == "right") then
			return Thickness / 2
		elseif not Vertical and (Side == "top" or Side == "bottom") then
			return Thickness / 2
		end
	end

	return 0
end

const function GetMinimumSize(Box: Theme.Resource?): vector
	return vector.create(GetMargin(Box, "left") + GetMargin(Box, "right"), GetMargin(Box, "top") + GetMargin(Box, "bottom"), 0)
end

-- Resets the host's own look; the drawing it holds is destroyed by the caller once the new one is in place.
const function ResetHost(Host: Frame)
	Host.BackgroundTransparency = 1
	Host.Position = UDim2.fromScale(0, 0)
	Host.Size = UDim2.fromScale(1, 1)
end

-- The rendered box, kept by Key; nil when the device is out of memory for pictures (nothing is kept, so a later draw tries
-- again).
const function RenderImage(Key: string, Render: StyleBoxRender.Image, Center: Rect?)
	const Image = AssetService:CreateEditableImage({ Size = Vector2.new(math.max(Render.Width, 1), math.max(Render.Height, 1)) })

	if not Image then
		return nil
	end

	if Render.Width > 0 and Render.Height > 0 then
		Image:WritePixelsBuffer(Vector2.zero, Vector2.new(Render.Width, Render.Height), Render.Pixels)
	end

	const Entry = {
		Image = Image,
		Render = Render,
		Center = Center,
	}

	Rendered[Key] = Entry

	return Entry
end

-- Draws a style box into Host (a Frame covering the control); nil or StyleBoxEmpty draws nothing. Answers whether the
-- drawing depends on the control's size (Width x Height), so the caller redraws it on resize.
const function DrawNewStyleBox(Host: Frame, Box: Theme.Resource?, Modulate: { number }?, Width: number?, Height: number?): boolean
	ResetHost(Host)

	if not Box then
		return false
	end

	const Properties = Box.Properties

	if Box.Type == "StyleBoxFlat" then
		const ControlWidth = Width or 0
		const ControlHeight = Height or 0
		const SliceWidth, SliceHeight = StyleBoxRender.SliceSize(Properties)
		const Sliced = SliceWidth ~= nil and SliceHeight ~= nil and ControlWidth >= SliceWidth and ControlHeight >= SliceHeight
		const BaseKey = StyleBoxRender.Key(Properties, nil)
		const Label = Instance.new("ImageLabel")
		local Entry

		if Sliced then
			const Key = `{BaseKey}|slice`

			Entry = Rendered[Key]

			if not Entry then
				const Render = StyleBoxRender.Render(Properties, SliceWidth :: number, SliceHeight :: number, nil)
				const X, Y, CenterWidth, CenterHeight = StyleBoxRender.SliceCenter(Properties, Render)

				Entry = RenderImage(Key, Render, Rect.new(X, Y, X + CenterWidth, Y + CenterHeight))
			end
		else
			const Key = `{BaseKey}|{ControlWidth}x{ControlHeight}`

			Entry = Rendered[Key] or RenderImage(Key, StyleBoxRender.Render(Properties, ControlWidth, ControlHeight, nil), nil)
		end

		-- (out of memory for its picture: the box isn't drawn, and a redraw tries again)
		if not Entry then
			Label:Destroy()

			return not Sliced
		end

		const Render = Entry.Render
		const ExtraWidth = Render.Width - (if Sliced then SliceWidth :: number else ControlWidth)
		const ExtraHeight = Render.Height - (if Sliced then SliceHeight :: number else ControlHeight)

		Label.Name = "Box"
		Label.BackgroundTransparency = 1
		Label.BorderSizePixel = 0
		Label.ImageContent = Content.fromObject(Entry.Image)
		Label.Position = UDim2.fromOffset(Render.OffsetX, Render.OffsetY)
		Label.Size = UDim2.new(1, ExtraWidth, 1, ExtraHeight)
		Label.ResampleMode = Enum.ResamplerMode.Pixelated

		-- The image is rendered once, unmodulated, and the modulate tints the label: a tween of self_modulate would otherwise
		-- render a new image for every color it passes through (a hitch, and the box blank until the image is ready).
		const TintColor, TintTransparency = ToColor(nil, Modulate)

		Label.ImageColor3 = TintColor
		Label.ImageTransparency = TintTransparency

		if Sliced and Entry.Center then
			Label.ScaleType = Enum.ScaleType.Slice
			Label.SliceCenter = Entry.Center
		end

		Label.Parent = Host

		return not Sliced
	elseif Box.Type == "StyleBoxLine" then
		const Color, Transparency = ToColor(Properties["color"] or { Color = { 0, 0, 0, 1 } }, Modulate)
		const Thickness = Number(Properties, "thickness", 1)
		const Begin = Number(Properties, "grow_begin", 1)
		const Finish = Number(Properties, "grow_end", 1)
		const Line = Instance.new("Frame")

		Line.Name = "Line"
		Line.BorderSizePixel = 0
		Line.BackgroundColor3 = Color
		Line.BackgroundTransparency = Transparency

		if Properties["vertical"] == true then
			Line.Position = UDim2.new(0.5, -Thickness / 2, 0, -Begin)
			Line.Size = UDim2.new(0, Thickness, 1, Begin + Finish)
		else
			Line.Position = UDim2.new(0, -Begin, 0.5, -Thickness / 2)
			Line.Size = UDim2.new(1, Begin + Finish, 0, Thickness)
		end

		Line.Parent = Host
	elseif Box.Type == "StyleBoxTexture" then
		warn("Aimia UI: StyleBoxTexture is not drawn yet")
	end

	return false
end

-- The new drawing is parented before the old one is destroyed, so a state change never shows the box blank.
const function DrawStyleBox(Host: Frame, Box: Theme.Resource?, Modulate: { number }?, Width: number?, Height: number?): boolean
	-- A box Roblox UI can draw is drawn by it, and kept: a state change sets the instances properties.
	const Native = if Box and Box.Type == "StyleBoxFlat" then StyleNative.Spec(Box.Properties) else nil

	if Native then
		ResetHost(Host)
		StyleNative.Apply(Host, Native, Modulate)

		return false
	end

	const Previous = Host:GetChildren()
	const DependsOnSize = DrawNewStyleBox(Host, Box, Modulate, Width, Height)

	for _, Child in Previous do
		Child:Destroy()
	end

	return DependsOnSize
end

return {
	DefaultFont = DefaultFont,
	GetFont = GetFont,
	FontHeight = FontHeight,
	TextSizeOf = TextSizeOf,
	ToColor = ToColor,
	GetMargin = GetMargin,
	GetMinimumSize = GetMinimumSize,
	DrawStyleBox = DrawStyleBox,
}
