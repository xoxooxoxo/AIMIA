--!strict
--!optimize 2

--[[
	Godot 4.7.2 default theme at scale 1.0 (engine/theme/default_theme.cpp, fill_default_theme), as plain data for the
	theme types the project's scenes and scripts use. UI/Theme reads Types as Godot's default theme layer: an item
	missing here is nil there.

	Types
		Every control the scenes or scripts create (tscn types, classes made in code), the Godot base types whose items
		they inherit where the default theme sets them (Button for CheckButton and OptionButton; BoxContainer; Window and
		AcceptDialog for FileDialog), and the tooltip types (tooltip_text is set in scenes). Type variations keep only
		the items the C++ sets for them: TooltipLabel falls back to Label and TooltipPanel to PopupPanel through the
		node's class chain in UI/Theme.
		FontSizes is empty: none of these types sets a positive font size.

	Representation
		Colors: { Color = { r, g, b, a } }, float32 components written as their shortest decimal.
		Icons: Godot's generated icons by name. "<empty>" is an empty ImageTexture, "<solid>" a 2x2 white one.
		Fonts: { Base = "Default", VariationEmbolden?, VariationTransform? }. "Default" is the theme's default font
		(embedded Open Sans SemiBold). VariationTransform is Transform2D(xx, xy, yx, yy, ox, oy).
		Null fonts and font sizes of -1 are left out: Theme::has_font and has_font_size ignore them (theme.cpp L552, L670).
		A content margin of -1 is unset (style_box.cpp L144). Properties not listed take the class default. The defaults
		that show here are StyleBoxFlat border_color (0.8, 0.8, 0.8, 1) (style_box_flat.h L40), listed on boxes that have
		a border, and StyleBoxLine grow_begin and grow_end (1) (style_box_line.h L40-41), listed on lines.

	Helpers, evaluated at scale 1.0 (default_theme.cpp L57-90)
		make_flat_stylebox(color, margins 4, corner radius 3, draw_center true, border width 0): sets the color, the four
		content margins, the four corner radii, anti_aliasing true, the four border widths, and corner_detail to
		CLAMP(MIN(ceil(1.5 * radius), 6), 1, 20) (style_box_flat.cpp L133). Radius 0 therefore gives corner_detail 1.
		make_empty_stylebox(): content margins -1. sb_expand(box, l, t, r, b): expand margins l, t, r, b.

	Shared StyleBox tables: an item that the C++ builds from the same box points at the same table. Read only.
]]

export type StyleBox = {
	Type: string, -- "StyleBoxFlat" | "StyleBoxEmpty" | "StyleBoxLine" | "StyleBoxTexture"
	Properties: { [string]: unknown }, -- Godot property names and values
}

-- Color locals, default_theme.cpp L101-124. Products of colors are computed as the C++ operator* does.
const ControlFontColor = { 0.875, 0.875, 0.875, 1 }
const ControlFontHoverColor = { 0.95, 0.95, 0.95, 1 } -- also control_font_focus_color
const ControlFontPressedColor = { 1, 1, 1, 1 }
const ControlFontDisabledColor = { 0.875, 0.875, 0.875, 0.5 } -- control_font_color * Color(1, 1, 1, 0.5)
const ControlFontPlaceholderColor = { 0.875, 0.875, 0.875, 0.6 }
const ControlSelectionColor = { 0.5, 0.5, 0.5, 1 }
const StyleNormalColor = { 0.1, 0.1, 0.1, 0.6 }
const StyleHoverColor = { 0.225, 0.225, 0.225, 0.6 }
const StylePressedColor = { 0, 0, 0, 0.6 }
const StyleDisabledColor = { 0.1, 0.1, 0.1, 0.3 }
const StyleFocusColor = { 1, 1, 1, 0.75 }
const StylePopupColor = { 0.25, 0.25, 0.25, 1 }
const StylePopupBorderColor = { 0.175, 0.175, 0.175, 1 }
const StylePopupHoverColor = { 0.4, 0.4, 0.4, 1 }
const StyleProgressColor = { 1, 1, 1, 0.4 }
const StyleSeparatorColor = { 0.5, 0.5, 0.5, 1 }
const StyleScrollbarGrabberPressedColor = { 0.75, 0.75, 0.75, 0.75 } -- style_focus_color * Color(0.75, 0.75, 0.75)
const StyleLineEditReadOnlyBorderColor = { 0, 0, 0, 0.3 } -- style_pressed_color * Color(1, 1, 1, 0.5)
const StyleTooltipColor = { 0, 0, 0, 0.5 }
const StyleFallbackColor = { 1, 0.365, 0.365, 1 }
const WhiteColor = { 1, 1, 1, 1 }
const OutlineColor = { 0, 0, 0, 1 }
const DefaultBorderColor = { 0.8, 0.8, 0.8, 1 } -- StyleBoxFlat class default border_color (style_box_flat.h L40)

-- Shared StyleBoxes. Each is the helper call named in its comment; the arguments follow the C++ call sites.

-- @src engine/theme/default_theme.cpp:fill_default_theme L379
const EmptyBox = { Type = "StyleBoxEmpty", Properties = {} } -- memnew(StyleBoxEmpty): margins unset (-1), as Label and ScrollContainer use it

-- @src engine/theme/default_theme.cpp:make_empty_stylebox L86-90
const RichTextLabelBox = {
	Type = "StyleBoxEmpty",
	Properties = {
		["content_margin_left"] = 0, ["content_margin_top"] = 0, ["content_margin_right"] = 0, ["content_margin_bottom"] = 0,
	},
}

-- @src engine/theme/default_theme.cpp:fill_default_theme L317-318
const CheckButtonBox = {
	Type = "StyleBoxEmpty",
	Properties = {
		["content_margin_left"] = 6, ["content_margin_top"] = 4, ["content_margin_right"] = 6, ["content_margin_bottom"] = 4,
	},
}

-- make_flat_stylebox(StyleNormalColor, 0, 0, 0, 0): Panel and PanelContainer
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const PanelBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleNormalColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 0, ["content_margin_top"] = 0, ["content_margin_right"] = 0, ["content_margin_bottom"] = 0,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(StyleFocusColor, 4, 4, 4, 4, 3, false, 2), expand margins 2 (sb_expand in Button): shared focus ring
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const FocusBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleFocusColor }, ["draw_center"] = false, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 2, ["border_width_top"] = 2, ["border_width_right"] = 2, ["border_width_bottom"] = 2,
		["expand_margin_left"] = 2, ["expand_margin_top"] = 2, ["expand_margin_right"] = 2, ["expand_margin_bottom"] = 2,
		["border_color"] = { Color = DefaultBorderColor },
	},
}

-- make_flat_stylebox(color) with the default margins 4: Button normal, hover, pressed and disabled
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const ButtonNormalBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleNormalColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const ButtonHoverBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleHoverColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const ButtonPressedBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StylePressedColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const ButtonDisabledBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleDisabledColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(color, 2 * 4, 4, 2 * 4, 4): OptionButton normal, hover, pressed, disabled (and their _mirrored copies)
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const OptionNormalBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleNormalColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 8, ["content_margin_top"] = 4, ["content_margin_right"] = 8, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const OptionHoverBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleHoverColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 8, ["content_margin_top"] = 4, ["content_margin_right"] = 8, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const OptionPressedBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StylePressedColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 8, ["content_margin_top"] = 4, ["content_margin_right"] = 8, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const OptionDisabledBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleDisabledColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 8, ["content_margin_top"] = 4, ["content_margin_right"] = 8, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(StyleNormalColor), border bottom 2, border color StylePressedColor: LineEdit normal
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const LineEditBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleNormalColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 2,
		["border_color"] = { Color = StylePressedColor },
	},
}

-- make_flat_stylebox(StyleDisabledColor), border bottom 2, border color StyleLineEditReadOnlyBorderColor: LineEdit read_only
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const LineEditReadOnlyBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleDisabledColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 2,
		["border_color"] = { Color = StyleLineEditReadOnlyBorderColor },
	},
}

-- make_flat_stylebox(StyleFocusColor), sb_expand 4, border 2, draw_center false, border color StyleFocusColor: ScrollContainer focus
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const ScrollFocusBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleFocusColor }, ["draw_center"] = false, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 2, ["border_width_top"] = 2, ["border_width_right"] = 2, ["border_width_bottom"] = 2,
		["expand_margin_left"] = 4, ["expand_margin_top"] = 4, ["expand_margin_right"] = 4, ["expand_margin_bottom"] = 4,
		["border_color"] = { Color = StyleFocusColor },
	},
}

-- make_flat_stylebox(StyleNormalColor, 0, 4, 0, 4, 10): HScrollBar scroll
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const HScrollStyleBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleNormalColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 6,
		["corner_radius_top_left"] = 10, ["corner_radius_top_right"] = 10, ["corner_radius_bottom_right"] = 10, ["corner_radius_bottom_left"] = 10,
		["content_margin_left"] = 0, ["content_margin_top"] = 4, ["content_margin_right"] = 0, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(StyleNormalColor, 4, 0, 4, 0, 10): VScrollBar scroll
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const VScrollStyleBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleNormalColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 6,
		["corner_radius_top_left"] = 10, ["corner_radius_top_right"] = 10, ["corner_radius_bottom_right"] = 10, ["corner_radius_bottom_left"] = 10,
		["content_margin_left"] = 4, ["content_margin_top"] = 0, ["content_margin_right"] = 4, ["content_margin_bottom"] = 0,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(StyleProgressColor, 4, 4, 4, 4, 10): scrollbar grabber
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const ScrollGrabberBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleProgressColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 6,
		["corner_radius_top_left"] = 10, ["corner_radius_top_right"] = 10, ["corner_radius_bottom_right"] = 10, ["corner_radius_bottom_left"] = 10,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(StyleFocusColor, 4, 4, 4, 4, 10): scrollbar grabber_highlight
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const ScrollGrabberHighlightBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleFocusColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 6,
		["corner_radius_top_left"] = 10, ["corner_radius_top_right"] = 10, ["corner_radius_bottom_right"] = 10, ["corner_radius_bottom_left"] = 10,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(style_focus_color * Color(0.75, 0.75, 0.75), 4, 4, 4, 4, 10): scrollbar grabber_pressed
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const ScrollGrabberPressedBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleScrollbarGrabberPressedColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 6,
		["corner_radius_top_left"] = 10, ["corner_radius_top_right"] = 10, ["corner_radius_bottom_right"] = 10, ["corner_radius_bottom_left"] = 10,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(StyleNormalColor, 4, 4, 4, 4, 4): HSlider slider
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const SliderBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleNormalColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 6,
		["corner_radius_top_left"] = 4, ["corner_radius_top_right"] = 4, ["corner_radius_bottom_right"] = 4, ["corner_radius_bottom_left"] = 4,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(StyleProgressColor, 4, 4, 4, 4, 4): HSlider grabber_area
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const SliderGrabberBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleProgressColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 6,
		["corner_radius_top_left"] = 4, ["corner_radius_top_right"] = 4, ["corner_radius_bottom_right"] = 4, ["corner_radius_bottom_left"] = 4,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(StyleFocusColor, 4, 4, 4, 4, 4): HSlider grabber_area_highlight
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const SliderGrabberHighlightBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleFocusColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 6,
		["corner_radius_top_left"] = 4, ["corner_radius_top_right"] = 4, ["corner_radius_bottom_right"] = 4, ["corner_radius_bottom_left"] = 4,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(StylePopupColor, 8, 8, 8, 8, 0): AcceptDialog panel (radius 0, so corner_detail 1)
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const AcceptDialogBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StylePopupColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 1,
		["corner_radius_top_left"] = 0, ["corner_radius_top_right"] = 0, ["corner_radius_bottom_right"] = 0, ["corner_radius_bottom_left"] = 0,
		["content_margin_left"] = 8, ["content_margin_top"] = 8, ["content_margin_right"] = 8, ["content_margin_bottom"] = 8,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(StylePopupColor, 10, 28, 10, 8), sb_expand 8, 32, 8, 6: Window embedded_border
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const WindowBorderBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StylePopupColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 10, ["content_margin_top"] = 28, ["content_margin_right"] = 10, ["content_margin_bottom"] = 8,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
		["expand_margin_left"] = 8, ["expand_margin_top"] = 32, ["expand_margin_right"] = 8, ["expand_margin_bottom"] = 6,
	},
}

-- make_flat_stylebox(StylePopupHoverColor, 10, 28, 10, 8), sb_expand 8, 32, 8, 6: Window embedded_unfocused_border
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const WindowUnfocusedBorderBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StylePopupHoverColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 10, ["content_margin_top"] = 28, ["content_margin_right"] = 10, ["content_margin_bottom"] = 8,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
		["expand_margin_left"] = 8, ["expand_margin_top"] = 32, ["expand_margin_right"] = 8, ["expand_margin_bottom"] = 6,
	},
}

-- make_flat_stylebox(StylePopupColor), border 2, border color StylePopupBorderColor: PopupMenu panel
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const PopupPanelBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StylePopupColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 2, ["border_width_top"] = 2, ["border_width_right"] = 2, ["border_width_bottom"] = 2,
		["border_color"] = { Color = StylePopupBorderColor },
	},
}

-- make_flat_stylebox(StylePopupHoverColor): PopupMenu hover
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const PopupHoverBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StylePopupHoverColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- make_flat_stylebox(StyleTooltipColor, 2 * 4, 0.5 * 4, 2 * 4, 0.5 * 4): TooltipPanel panel
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const TooltipBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleTooltipColor }, ["draw_center"] = true, ["anti_aliasing"] = true, ["corner_detail"] = 5,
		["corner_radius_top_left"] = 3, ["corner_radius_top_right"] = 3, ["corner_radius_bottom_right"] = 3, ["corner_radius_bottom_left"] = 3,
		["content_margin_left"] = 8, ["content_margin_top"] = 2, ["content_margin_right"] = 8, ["content_margin_bottom"] = 2,
		["border_width_left"] = 0, ["border_width_top"] = 0, ["border_width_right"] = 0, ["border_width_bottom"] = 0,
	},
}

-- Fallback box, default_theme.cpp L1378: make_flat_stylebox(Color(1, 0.365, 0.365), 4, 4, 4, 4, 0, false, 2). Radius 0, so corner_detail 1.
-- @src engine/theme/default_theme.cpp:make_flat_stylebox L57-71
const FallbackBox = {
	Type = "StyleBoxFlat",
	Properties = {
		["bg_color"] = { Color = StyleFallbackColor }, ["draw_center"] = false, ["anti_aliasing"] = true, ["corner_detail"] = 1,
		["corner_radius_top_left"] = 0, ["corner_radius_top_right"] = 0, ["corner_radius_bottom_right"] = 0, ["corner_radius_bottom_left"] = 0,
		["content_margin_left"] = 4, ["content_margin_top"] = 4, ["content_margin_right"] = 4, ["content_margin_bottom"] = 4,
		["border_width_left"] = 2, ["border_width_top"] = 2, ["border_width_right"] = 2, ["border_width_bottom"] = 2,
		["border_color"] = { Color = DefaultBorderColor },
	},
}

-- StyleBoxLine separator_horizontal, default_theme.cpp L752-755: thickness round(1), color StyleSeparatorColor, margins (4, 0, 4, 0)
-- @src engine/theme/default_theme.cpp:fill_default_theme L752-755
const PopupSeparatorBox = {
	Type = "StyleBoxLine",
	Properties = {
		["color"] = { Color = StyleSeparatorColor }, ["thickness"] = 1, ["vertical"] = false, ["grow_begin"] = 1, ["grow_end"] = 1,
		["content_margin_left"] = 4, ["content_margin_top"] = 0, ["content_margin_right"] = 4, ["content_margin_bottom"] = 0,
	},
}

-- StyleBoxLine separator_vertical, default_theme.cpp L756-758: a duplicate with vertical true and margins (0, 4, 0, 4)
-- @src engine/theme/default_theme.cpp:fill_default_theme L756-758
const PopupSeparatorVerticalBox = {
	Type = "StyleBoxLine",
	Properties = {
		["color"] = { Color = StyleSeparatorColor }, ["thickness"] = 1, ["vertical"] = true, ["grow_begin"] = 1, ["grow_end"] = 1,
		["content_margin_left"] = 0, ["content_margin_top"] = 4, ["content_margin_right"] = 0, ["content_margin_bottom"] = 4,
	},
}

return {
	DefaultFontSize = 16, -- round(default_font_size * scale), L50, L97
	DefaultBaseScale = 1, -- set_default_base_scale(scale), L98
	FallbackIcon = "error_icon", -- default_icon, L1376
	FallbackStyleBox = FallbackBox, -- default_style, L1378
	Types = {
		-- @src engine/theme/default_theme.cpp:fill_default_theme L134
		["Panel"] = {
			Colors = {},
			Constants = {},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["panel"] = PanelBox,
			},
			Icons = {},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L138-174
		["Button"] = {
			Colors = {
				["font_color"] = { Color = ControlFontColor },
				["font_pressed_color"] = { Color = ControlFontPressedColor },
				["font_hover_color"] = { Color = ControlFontHoverColor },
				["font_focus_color"] = { Color = ControlFontHoverColor },
				["font_hover_pressed_color"] = { Color = ControlFontPressedColor },
				["font_disabled_color"] = { Color = ControlFontDisabledColor },
				["font_outline_color"] = { Color = OutlineColor },
				["icon_normal_color"] = { Color = WhiteColor },
				["icon_pressed_color"] = { Color = WhiteColor },
				["icon_hover_color"] = { Color = WhiteColor },
				["icon_hover_pressed_color"] = { Color = WhiteColor },
				["icon_focus_color"] = { Color = WhiteColor },
				["icon_disabled_color"] = { Color = { 1, 1, 1, 0.4 } },
			},
			Constants = {
				["outline_size"] = 0,
				["h_separation"] = 4,
				["icon_max_width"] = 0,
				["align_to_largest_stylebox"] = 0,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["normal"] = ButtonNormalBox,
				["hover"] = ButtonHoverBox,
				["pressed"] = ButtonPressedBox,
				["disabled"] = ButtonDisabledBox,
				["focus"] = FocusBox,
			},
			Icons = {},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L212-251
		["OptionButton"] = {
			Colors = {
				["font_color"] = { Color = ControlFontColor },
				["font_pressed_color"] = { Color = ControlFontPressedColor },
				["font_hover_color"] = { Color = ControlFontHoverColor },
				["font_hover_pressed_color"] = { Color = ControlFontPressedColor },
				["font_focus_color"] = { Color = ControlFontHoverColor },
				["font_disabled_color"] = { Color = ControlFontDisabledColor },
				["font_outline_color"] = { Color = OutlineColor },
			},
			Constants = {
				["h_separation"] = 4,
				["arrow_margin"] = 4,
				["outline_size"] = 0,
				["modulate_arrow"] = 0,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["normal"] = OptionNormalBox,
				["hover"] = OptionHoverBox,
				["pressed"] = OptionPressedBox,
				["disabled"] = OptionDisabledBox,
				["normal_mirrored"] = OptionNormalBox,
				["hover_mirrored"] = OptionHoverBox,
				["pressed_mirrored"] = OptionPressedBox,
				["disabled_mirrored"] = OptionDisabledBox,
				["focus"] = FocusBox,
			},
			Icons = {
				["arrow"] = "option_button_arrow",
			},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L315-353
		["CheckButton"] = {
			Colors = {
				["font_color"] = { Color = ControlFontColor },
				["font_pressed_color"] = { Color = ControlFontPressedColor },
				["font_hover_color"] = { Color = ControlFontHoverColor },
				["font_hover_pressed_color"] = { Color = ControlFontPressedColor },
				["font_focus_color"] = { Color = ControlFontHoverColor },
				["font_disabled_color"] = { Color = ControlFontDisabledColor },
				["font_outline_color"] = { Color = OutlineColor },
				["button_checked_color"] = { Color = WhiteColor },
				["button_unchecked_color"] = { Color = WhiteColor },
			},
			Constants = {
				["h_separation"] = 4,
				["check_v_offset"] = 0,
				["outline_size"] = 0,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["normal"] = CheckButtonBox,
				["pressed"] = CheckButtonBox,
				["disabled"] = CheckButtonBox,
				["hover"] = CheckButtonBox,
				["hover_pressed"] = CheckButtonBox,
				["focus"] = FocusBox,
			},
			Icons = {
				["checked"] = "toggle_on",
				["checked_disabled"] = "toggle_on_disabled",
				["unchecked"] = "toggle_off",
				["unchecked_disabled"] = "toggle_off_disabled",
				["checked_mirrored"] = "toggle_on_mirrored",
				["checked_disabled_mirrored"] = "toggle_on_disabled_mirrored",
				["unchecked_mirrored"] = "toggle_off_mirrored",
				["unchecked_disabled_mirrored"] = "toggle_off_disabled_mirrored",
			},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L377-392
		["Label"] = {
			Colors = {
				["font_color"] = { Color = WhiteColor },
				["font_shadow_color"] = { Color = { 0, 0, 0, 0 } },
				["font_outline_color"] = { Color = OutlineColor },
			},
			Constants = {
				["shadow_offset_x"] = 1,
				["shadow_offset_y"] = 1,
				["outline_size"] = 0,
				["shadow_outline_size"] = 1,
				["line_spacing"] = 3,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["normal"] = EmptyBox,
				["focus"] = FocusBox,
			},
			Icons = {},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L1205-1254
		["RichTextLabel"] = {
			Colors = {
				["default_color"] = { Color = WhiteColor },
				["font_selected_color"] = { Color = { 0, 0, 0, 0 } },
				["selection_color"] = { Color = { 0.1, 0.1, 1, 0.8 } },
				["font_shadow_color"] = { Color = { 0, 0, 0, 0 } },
				["font_outline_color"] = { Color = OutlineColor },
				["table_odd_row_bg"] = { Color = { 0, 0, 0, 0 } },
				["table_even_row_bg"] = { Color = { 0, 0, 0, 0 } },
				["table_border"] = { Color = { 0, 0, 0, 0 } },
			},
			Constants = {
				["shadow_offset_x"] = 1,
				["shadow_offset_y"] = 1,
				["shadow_outline_size"] = 1,
				["line_separation"] = 0,
				["paragraph_separation"] = 0,
				["table_h_separation"] = 3,
				["table_v_separation"] = 3,
				["outline_size"] = 0,
				["text_highlight_h_padding"] = 3,
				["text_highlight_v_padding"] = 3,
				["underline_alpha"] = 50,
				["strikethrough_alpha"] = 50,
			},
			FontSizes = {},
			Fonts = {
				-- bold_font, italics_font, bold_italics_font: default_theme.cpp L1413-1426 (make_default_theme)
				["bold_font"] = { Base = "Default", VariationEmbolden = 1.2 },
				["italics_font"] = { Base = "Default", VariationTransform = { 1, 0.2, 0, 1, 0, 0 } },
				["bold_italics_font"] = { Base = "Default", VariationEmbolden = 1.2, VariationTransform = { 1, 0.2, 0, 1, 0, 0 } },
			},
			StyleBoxes = {
				["normal"] = RichTextLabelBox,
				["focus"] = FocusBox,
			},
			Icons = {
				["horizontal_rule"] = "<solid>",
			},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L403-436
		["LineEdit"] = {
			Colors = {
				["font_color"] = { Color = ControlFontColor },
				["font_selected_color"] = { Color = ControlFontPressedColor },
				["font_uneditable_color"] = { Color = ControlFontDisabledColor },
				["font_placeholder_color"] = { Color = ControlFontPlaceholderColor },
				["font_outline_color"] = { Color = OutlineColor },
				["caret_color"] = { Color = ControlFontHoverColor },
				["selection_color"] = { Color = ControlSelectionColor },
				["clear_button_color"] = { Color = ControlFontColor },
				["clear_button_color_pressed"] = { Color = ControlFontPressedColor },
			},
			Constants = {
				["minimum_character_width"] = 4,
				["outline_size"] = 0,
				["caret_width"] = 1,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["normal"] = LineEditBox,
				["focus"] = FocusBox,
				["read_only"] = LineEditReadOnlyBox,
			},
			Icons = {
				["clear"] = "line_edit_clear",
			},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L653-670
		["ScrollContainer"] = {
			Colors = {
				["scroll_hint_vertical_color"] = { Color = OutlineColor },
				["scroll_hint_horizontal_color"] = { Color = OutlineColor },
			},
			Constants = {},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["panel"] = EmptyBox,
				["focus"] = ScrollFocusBox,
			},
			Icons = {
				["scroll_hint_vertical"] = "scroll_hint_vertical",
				["scroll_hint_horizontal"] = "scroll_hint_horizontal",
			},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L549-562
		["HScrollBar"] = {
			Colors = {},
			Constants = {},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["scroll"] = HScrollStyleBox,
				["scroll_focus"] = FocusBox,
				["grabber"] = ScrollGrabberBox,
				["grabber_highlight"] = ScrollGrabberHighlightBox,
				["grabber_pressed"] = ScrollGrabberPressedBox,
			},
			Icons = {
				["increment"] = "<empty>",
				["increment_highlight"] = "<empty>",
				["increment_pressed"] = "<empty>",
				["decrement"] = "<empty>",
				["decrement_highlight"] = "<empty>",
				["decrement_pressed"] = "<empty>",
			},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L564-577
		["VScrollBar"] = {
			Colors = {},
			Constants = {},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["scroll"] = VScrollStyleBox,
				["scroll_focus"] = FocusBox,
				["grabber"] = ScrollGrabberBox,
				["grabber_highlight"] = ScrollGrabberHighlightBox,
				["grabber_pressed"] = ScrollGrabberPressedBox,
			},
			Icons = {
				["increment"] = "<empty>",
				["increment_highlight"] = "<empty>",
				["increment_pressed"] = "<empty>",
				["decrement"] = "<empty>",
				["decrement_highlight"] = "<empty>",
				["decrement_pressed"] = "<empty>",
			},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L583-596
		["HSlider"] = {
			Colors = {},
			Constants = {
				["center_grabber"] = 0,
				["grabber_offset"] = 0,
				["tick_offset"] = 0,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["slider"] = SliderBox,
				["grabber_area"] = SliderGrabberBox,
				["grabber_area_highlight"] = SliderGrabberHighlightBox,
			},
			Icons = {
				["grabber"] = "slider_grabber",
				["grabber_highlight"] = "slider_grabber_hl",
				["grabber_disabled"] = "slider_grabber_disabled",
				["tick"] = "hslider_tick",
			},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L686-699
		["Window"] = {
			Colors = {
				["title_color"] = { Color = ControlFontColor },
				["title_outline_modulate"] = { Color = OutlineColor },
			},
			Constants = {
				["title_outline_size"] = 0,
				["title_height"] = 36,
				["resize_margin"] = 4,
				["close_h_offset"] = 18,
				["close_v_offset"] = 24,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["embedded_border"] = WindowBorderBox,
				["embedded_unfocused_border"] = WindowUnfocusedBorderBox,
			},
			Icons = {
				["close"] = "close",
				["close_pressed"] = "close_hl",
			},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L705-706
		["AcceptDialog"] = {
			Colors = {},
			Constants = {
				["buttons_separation"] = 10,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["panel"] = AcceptDialogBox,
			},
			Icons = {},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L710-740
		["FileDialog"] = {
			Colors = {
				["folder_icon_color"] = { Color = WhiteColor },
				["file_icon_color"] = { Color = WhiteColor },
				["file_disabled_color"] = { Color = { 1, 1, 1, 0.25 } },
			},
			Constants = {
				["thumbnail_size"] = 64,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {},
			Icons = {
				["load"] = "load",
				["save"] = "save",
				["clear"] = "clear",
				["parent_folder"] = "folder_up",
				["back_folder"] = "arrow_left",
				["forward_folder"] = "arrow_right",
				["reload"] = "reload",
				["favorite"] = "favorite",
				["toggle_hidden"] = "visibility_visible",
				["toggle_filename_filter"] = "toggle_filename_filter",
				["folder"] = "folder",
				["file"] = "file",
				["thumbnail_mode"] = "file_mode_thumbnail",
				["list_mode"] = "file_mode_list",
				["create_folder"] = "folder_create",
				["sort"] = "sort",
				["favorite_up"] = "move_up",
				["favorite_down"] = "move_down",
				["file_thumbnail"] = "file_thumbnail",
				["folder_thumbnail"] = "folder_thumbnail",
				["menu_copy_path"] = "<empty>",
				["menu_delete"] = "<empty>",
				["menu_new_folder"] = "<empty>",
				["menu_refresh"] = "<empty>",
				["menu_show_in_file_manager"] = "<empty>",
				["menu_open_bundle"] = "<empty>",
			},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L750-805
		["PopupMenu"] = {
			Colors = {
				["font_color"] = { Color = ControlFontColor },
				["font_accelerator_color"] = { Color = { 0.7, 0.7, 0.7, 0.8 } },
				["font_disabled_color"] = { Color = { 0.4, 0.4, 0.4, 0.8 } },
				["font_hover_color"] = { Color = ControlFontColor },
				["font_separator_color"] = { Color = ControlFontColor },
				["font_outline_color"] = { Color = OutlineColor },
				["font_separator_outline_color"] = { Color = OutlineColor },
			},
			Constants = {
				["indent"] = 10,
				["h_separation"] = 4,
				["v_separation"] = 4,
				["search_bar_separation"] = 4,
				["outline_size"] = 0,
				["separator_outline_size"] = 0,
				["item_start_padding"] = 2,
				["item_end_padding"] = 2,
				["icon_max_width"] = 0,
				["gutter_compact"] = 1,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["panel"] = PopupPanelBox,
				["hover"] = PopupHoverBox,
				["separator"] = PopupSeparatorBox,
				["labeled_separator_left"] = PopupSeparatorBox,
				["labeled_separator_right"] = PopupSeparatorBox,
			},
			Icons = {
				["checked"] = "checked",
				["checked_disabled"] = "checked_disabled",
				["unchecked"] = "unchecked",
				["unchecked_disabled"] = "unchecked_disabled",
				["radio_checked"] = "radio_checked",
				["radio_checked_disabled"] = "radio_checked_disabled",
				["radio_unchecked"] = "radio_unchecked",
				["radio_unchecked_disabled"] = "radio_unchecked_disabled",
				["submenu"] = "popup_menu_arrow_right",
				["submenu_mirrored"] = "popup_menu_arrow_left",
				["search"] = "search",
			},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L1189-1191
		["TooltipPanel"] = {
			Colors = {},
			Constants = {},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["panel"] = TooltipBox,
			},
			Icons = {},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L1193-1203
		["TooltipLabel"] = {
			Colors = {
				["font_color"] = { Color = ControlFontColor },
				["font_shadow_color"] = { Color = { 0, 0, 0, 0 } },
				["font_outline_color"] = { Color = OutlineColor },
			},
			Constants = {
				["shadow_offset_x"] = 1,
				["shadow_offset_y"] = 1,
				["outline_size"] = 0,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {},
			Icons = {},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L1085-1090
		["VSeparator"] = {
			Colors = {},
			Constants = {
				["separation"] = 4,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["separator"] = PopupSeparatorVerticalBox,
			},
			Icons = {},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L1271
		["BoxContainer"] = {
			Colors = {},
			Constants = {
				["separation"] = 4,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {},
			Icons = {},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L1272
		["HBoxContainer"] = {
			Colors = {},
			Constants = {
				["separation"] = 4,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {},
			Icons = {},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L1273
		["VBoxContainer"] = {
			Colors = {},
			Constants = {
				["separation"] = 4,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {},
			Icons = {},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L1274-1277
		["MarginContainer"] = {
			Colors = {},
			Constants = {
				["margin_left"] = 0,
				["margin_top"] = 0,
				["margin_right"] = 0,
				["margin_bottom"] = 0,
			},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {},
			Icons = {},
		},

		-- @src engine/theme/default_theme.cpp:fill_default_theme L1296
		["PanelContainer"] = {
			Colors = {},
			Constants = {},
			FontSizes = {},
			Fonts = {},
			StyleBoxes = {
				["panel"] = PanelBox,
			},
			Icons = {},
		},
	},
}
