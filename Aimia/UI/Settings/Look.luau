--!strict
--!optimize 2

--[[
	The look of the settings menu's controls: the colors, fonts and sizes of res://themes/theme.tres, the Settings subtree of
	res://scenes/main.tscn and Godot 4.7's default theme for the states the scene does not set (UI/DefaultTheme).

	Design Notes
		A Tint is a color with its alpha: Color3 and Alpha (1 opaque). The widgets draw tints with vector Frames (UICorner,
		UIStroke, Frame colors), so edges are antialiased by the renderer; no baked images are used except the add icon.
		Corner radii are Godot's corner_radius values; a stroke is a StyleBoxFlat border drawn inside the frame.
		Both are read in the scene's own terms: Fonts are the theme's default font (Roboto Medium) and the two Ubuntu
		weights the scene names; the Roblox families are the ones UI/Style maps those files to.
		DEVIATION(unverified): the outline stroke of the holder is a shader in Godot (outline.gdshader) that paints the
		border near the cursor position; the menu never sets the shader's cursor position, so the border is the shader's
		outline color everywhere but near the screen's origin, and it is drawn here as that flat color.
]]

export type Tint = { Color: Color3, Alpha: number }

export type Mode = {
	Fill: Tint,
	Text: Tint,
	Underline: Tint?,
	-- Content margins above and below the label (a pressed or hovered button's text shifts down by one pixel).
	MarginTop: number,
	MarginBottom: number,
}

export type ButtonStyle = {
	Normal: Mode,
	Hover: Mode,
	Pressed: Mode,
	Radius: number,
	UnderlineWidth: number,
}

const function Rgba(Red: number, Green: number, Blue: number, Alpha: number): Tint
	return { Color = Color3.new(Red, Green, Blue), Alpha = Alpha }
end

const function ModeOf(Fill: Tint, Text: Tint, Underline: Tint?, MarginTop: number, MarginBottom: number): Mode
	return { Fill = Fill, Text = Text, Underline = Underline, MarginTop = MarginTop, MarginBottom = MarginBottom }
end

-- Godot's font colors (ControlFontColor and its hover and pressed variants, default_theme.cpp L101-110).
const FontNormal = Rgba(0.875, 0.875, 0.875, 1)
const FontHover = Rgba(0.95, 0.95, 0.95, 1)
const FontPressed = Rgba(1, 1, 1, 1)
const FontWhite = Rgba(1, 1, 1, 1)
const FontPlaceholder = Rgba(0.875, 0.875, 0.875, 0.6)

-- Shared colors: the holder's pink (StyleBoxFlat border of theme.tres), the pale grabber, and the stroke of the outline.
const Pink = Rgba(0.7882353, 0, 0.27058825, 1)
const White = Rgba(1, 1, 1, 1)
const Black = Rgba(0, 0, 0, 1)
const Clear = Rgba(0, 0, 0, 0)

-- The fonts. The default font is res://fonts/Roboto/Roboto-Medium.ttf (theme.tres default_font); Ubuntu is the scene's.
const RobotoFamily = "rbxasset://fonts/families/Roboto.json"
const UbuntuFamily = "rbxasset://fonts/families/Ubuntu.json"

const Fonts = {
	Default = Font.new(RobotoFamily, Enum.FontWeight.Medium, Enum.FontStyle.Normal),
	UbuntuRegular = Font.new(UbuntuFamily, Enum.FontWeight.Regular, Enum.FontStyle.Normal),
	UbuntuMedium = Font.new(UbuntuFamily, Enum.FontWeight.Medium, Enum.FontStyle.Normal),
}

-- Font sizes: the Godot values (LabelSettings, the theme's font_size overrides and the default 16).
const Sizes = {
	Body = 16,
	Option = 14,
	Header = 24,
	Popup = 20,
}

-- The holder and the panels around it: rounded black panels, with the dim column's separator.
const Corner = 4
const CornerSmall = 3
const HolderFill = Rgba(0, 0, 0, 0.8784314)
const PanelFill = Rgba(0, 0, 0, 0.98039216)
const ScrimFill = Rgba(0, 0, 0, 0.5019608)
const SeparatorFill = Rgba(0.050980393, 0.050980393, 0.050980393, 1)
const OutlineStroke = Rgba(0.05, 0.05, 0.05, 1)
const OutlineThickness = 2

-- The sidebar: a transparent button with a faint highlight on the selected category.
const SidebarSelected = Rgba(1, 1, 1, 0.031372549)
const SidebarButton = {
	Normal = ModeOf(Clear, FontNormal, nil, 0, 0),
	Hover = ModeOf(Rgba(0.0360807, 0.0300716, 0.0527505, 1), FontHover, nil, 0, 0),
	Pressed = ModeOf(Rgba(0.076273, 0.0667037, 0.100363, 1), FontPressed, nil, 0, 0),
	Radius = 0,
	UnderlineWidth = 0,
}

-- The setting buttons of a row: black with a pink underline; hovered is grey with a white underline; pressed is grey.
const PressedFill = Rgba(0.1254902, 0.1254902, 0.1254902, 1)
const HoverFill = Rgba(0.09411765, 0.09411765, 0.09411765, 1)
const PressedUnderline = Rgba(0.8, 0.8, 0.8, 1)
const RowButton = {
	Normal = ModeOf(Black, FontWhite, Pink, 6, 6),
	Hover = ModeOf(HoverFill, FontWhite, White, 7, 5),
	Pressed = ModeOf(PressedFill, FontWhite, PressedUnderline, 7, 5),
	Radius = Corner,
	UnderlineWidth = 2,
}

-- The buttons of a popup (the option popup's row): the setting button look, with the default font colors.
const PopupButton = {
	Normal = ModeOf(Black, FontNormal, Pink, 6, 6),
	Hover = ModeOf(HoverFill, FontHover, White, 7, 5),
	Pressed = ModeOf(PressedFill, FontPressed, PressedUnderline, 7, 5),
	Radius = Corner,
	UnderlineWidth = 2,
}

-- The create-profile button: a square with no border (its hover is a grey square).
const IconButton = {
	Normal = ModeOf(Black, FontWhite, nil, 0, 0),
	Hover = ModeOf(Rgba(0.117647, 0.117647, 0.117647, 1), FontWhite, nil, 0, 0),
	Pressed = ModeOf(Rgba(0.117647, 0.117647, 0.117647, 1), FontWhite, nil, 0, 0),
	Radius = 0,
	UnderlineWidth = 0,
}

-- The option buttons (OptionButton): the theme has no OptionButton styles, so they take the Button styles (the setting buttons').
const OptionButtonStyle = RowButton

-- A text field (LineEdit): the normal box is opaque black (profile name) and the focus box a pink outline.
const FieldNormal = Rgba(0, 0, 0, 1)
const FieldFocusFill = Rgba(0, 0, 0, 0.8627451)
const FieldFocusStroke = Pink
const FieldFocusThickness = 1

-- The sliders: a pink track ring (2 pixels, 14 high over the 4 pixel track), the pink fill, and the pale grabber.
const SliderRing = Pink
const SliderRingThickness = 2
const SliderTrackHeight = 4
const SliderFill = Pink
const SliderFillHot = Rgba(1, 0, 0.3803922, 1)
const SliderGrabber = Rgba(1, 0.8980392, 0.9333333, 1)
const SliderGrabberSize = 12
const SliderHotRingSize = 24
const SliderHotRingThickness = 4
const SliderHotDotSize = 10

-- The vertical scroll bar: a 4 pixel black track and a white thumb with rounded right corners.
const ScrollTrack = Rgba(0, 0, 0, 0.8627451)
const ScrollThumb = Rgba(1, 1, 1, 1)
const ScrollThumbRadius = 4

-- The check button (toggle): a white track at 35% with a white knob.
const ToggleTrack = Rgba(1, 1, 1, 0.35)
const ToggleKnob = Rgba(1, 1, 1, 1)
const ToggleKnobSize = 12

-- Tooltips (TooltipPanel) and the popup list of an option button (PopupMenu).
const TooltipFill = Rgba(0, 0, 0, 0.5)
const TooltipMarginX = 8
const TooltipMarginY = 2
const TooltipWrap = 300
const TooltipDelay = 0.5
const PopupFill = Rgba(0, 0, 0, 1)
const PopupBorder = Pink
const PopupBorderThickness = 1
const PopupMargin = 4
const PopupHoverFill = Rgba(0.078431375, 0.078431375, 0.078431375, 1)
const PopupItemPadding = 2
const PopupSeparation = 4
const PopupHSeparation = 4
const PopupRadioSize = 16
const PopupRadioDot = 8
const PopupRadioThickness = 1

-- The option popup (OptionPopup.tscn): a dim background, and a centered black panel with 8 pixels of expansion.
const PopupScrim = Rgba(0, 0, 0, 0.47058824)
const PopupPanelFill = Rgba(0, 0, 0, 0.8627451)
const PopupPanelExpand = 8

-- The separation of the option popup's rows (VBoxContainer separation 8).
const OptionPopupSeparation = 8
const PopupMinimumWidth = 300

-- The arrow of an option button: a down-pointing triangle, 10 x 6 pixels (not in the engine's sources: unverified).
const ArrowWidth = 10
const ArrowHeight = 6
const ArrowMargin = 8

-- The add icon of the create-profile button (16 pixels, icon_max_width 18 keeps it).
const CreateIconSize = 16

-- The text inset of a field and a button (their content margins).
const FieldInset = 8
const ButtonInset = 8

return {
	Rgba = Rgba,
	Fonts = Fonts,
	Sizes = Sizes,
	FontNormal = FontNormal,
	FontHover = FontHover,
	FontPressed = FontPressed,
	FontWhite = FontWhite,
	FontPlaceholder = FontPlaceholder,
	Pink = Pink,
	White = White,
	Black = Black,
	Clear = Clear,
	Corner = Corner,
	CornerSmall = CornerSmall,
	HolderFill = HolderFill,
	PanelFill = PanelFill,
	ScrimFill = ScrimFill,
	SeparatorFill = SeparatorFill,
	OutlineStroke = OutlineStroke,
	OutlineThickness = OutlineThickness,
	SidebarSelected = SidebarSelected,
	SidebarButton = SidebarButton,
	RowButton = RowButton,
	IconButton = IconButton,
	PopupButton = PopupButton,
	OptionButtonStyle = OptionButtonStyle,
	FieldNormal = FieldNormal,
	FieldFocusFill = FieldFocusFill,
	FieldFocusStroke = FieldFocusStroke,
	FieldFocusThickness = FieldFocusThickness,
	SliderRing = SliderRing,
	SliderRingThickness = SliderRingThickness,
	SliderTrackHeight = SliderTrackHeight,
	SliderFill = SliderFill,
	SliderFillHot = SliderFillHot,
	SliderGrabber = SliderGrabber,
	SliderGrabberSize = SliderGrabberSize,
	SliderHotRingSize = SliderHotRingSize,
	SliderHotRingThickness = SliderHotRingThickness,
	SliderHotDotSize = SliderHotDotSize,
	ScrollTrack = ScrollTrack,
	ScrollThumb = ScrollThumb,
	ScrollThumbRadius = ScrollThumbRadius,
	ToggleTrack = ToggleTrack,
	ToggleKnob = ToggleKnob,
	ToggleKnobSize = ToggleKnobSize,
	TooltipFill = TooltipFill,
	TooltipMarginX = TooltipMarginX,
	TooltipMarginY = TooltipMarginY,
	TooltipWrap = TooltipWrap,
	TooltipDelay = TooltipDelay,
	PopupFill = PopupFill,
	PopupBorder = PopupBorder,
	PopupBorderThickness = PopupBorderThickness,
	PopupMargin = PopupMargin,
	PopupHoverFill = PopupHoverFill,
	PopupItemPadding = PopupItemPadding,
	PopupSeparation = PopupSeparation,
	PopupHSeparation = PopupHSeparation,
	PopupRadioSize = PopupRadioSize,
	PopupRadioDot = PopupRadioDot,
	PopupRadioThickness = PopupRadioThickness,
	PopupScrim = PopupScrim,
	PopupPanelFill = PopupPanelFill,
	PopupPanelExpand = PopupPanelExpand,
	OptionPopupSeparation = OptionPopupSeparation,
	PopupMinimumWidth = PopupMinimumWidth,
	ArrowWidth = ArrowWidth,
	ArrowHeight = ArrowHeight,
	ArrowMargin = ArrowMargin,
	CreateIconSize = CreateIconSize,
	FieldInset = FieldInset,
	ButtonInset = ButtonInset,
}
