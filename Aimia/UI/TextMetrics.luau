--!strict
--!optimize 2

--[[
	Godot 4.7.2 text rules for Label, the Button family (Button, CheckBox, CheckButton, ...), LineEdit and the fit_content
	height of RichTextLabel: minimum sizes, and the text and icon rectangles inside the control, from plain numbers and a
	font measurer. Ported from reference/engine/gui/label.cpp, button.cpp and line_edit.cpp. No Roblox API.

	Measurer: Measure(Text, Size, Width?) returns TextWidth (the widest line), LineHeight (Godot's font height, Style.FontHeight)
	and LineCount (lines after breaks and, when Width is given, wrapping at Width; the builder counts them in Roblox lines, whose
	height is TextSize). Measure is never called with "": an empty Button or LineEdit text has no lines (0 x 0; assumed: a shaped empty
	string has no lines in Godot, text_paragraph.cpp is not fetched); an empty Label paragraph is one line of font height (Godot appends a zero-width space to
	every paragraph so that it has a line).

	Layout: Layout.Text is the box a Roblox TextLabel or TextBox uses with the alignment in Layout.Align, so each line lands
	where Godot draws it. A Label that does not wrap and is centered uses the full control width, because Godot centers
	there without the style margins.

	Integers: where the C++ stores a float in an int (Label's font height, wrap widths, text offsets, centering remainders)
	the value truncates toward zero. Button and LineEdit font heights keep their fraction, as their C++ does.

	Assumptions (sources not in reference/engine): StyleBox::get_minimum_size is Left + Right by Top + Bottom and
	StyleBox::get_offset is (Left, Top); a TextParagraph (Button text) is Lines * LineHeight plus Lines - 1 line spacings;
	a width of 0 or less breaks no line (TextServer breaks at a positive width only).

	DEVIATION: no glyph-level behavior: justification (FILL spacing), tab stops, autowrap trim flags, grapheme breaking
	(AUTOWRAP_ARBITRARY wraps at words, as the measurer does), language and bidi, visible characters after shaping, and the
	ellipsis of overrun trimming (drawn glyphs only; the minimums use 1 pixel, as Godot does).
	DEVIATION: Uppercase maps ASCII letters only (string.upper); Godot's string_to_upper maps all Unicode letters.
	outline_size changes no size: label.cpp, button.cpp and line_edit.cpp read it only when drawing.
	Label::get_desired_size is not ported: with no maximum width (Layout never sets one) it is zero.
	RichTextLabel's source is not in reference/engine, so RichTextFitHeight keeps only the minimal rule the builder used.
]]

const Numbers = require("../Numbers")

const AlignLeft = 0
const AlignCenter = 1
const AlignRight = 2
const AlignFill = 3
const AlignTop = 0
const AlignBottom = 2

const AutowrapOff = 0
const OverrunNoTrimming = 0
const VisibleCharsBeforeShaping = 0
const ExpandFitToText = 1
const ExpandFitToLineEdit = 2
const Epsilon = 0.00001
const SecretBullet = "\u{2022}"

export type Measurer = (Text: string, Size: number, Width: number?) -> (number, number, number)

-- Resolved content margins of a StyleBox (StyleBox::get_margin per side).
export type StyleMargins = { Left: number, Top: number, Right: number, Bottom: number }

export type Rect = { X: number, Y: number, Width: number, Height: number }

-- Text box and icon inside the control, in control pixels. Align is the horizontal alignment of the lines inside Text
-- (0 Left, 1 Center, 2 Right). LineCount and LineHeight describe the drawn lines; LineSpacing is the gap between lines
-- (line_spacing, plus the spread of VERTICAL_ALIGNMENT_FILL), ParagraphSpacing the gap between paragraphs.
export type Layout = {
	Text: Rect,
	Icon: Rect?,
	Align: number,
	LineCount: number,
	LineHeight: number,
	LineSpacing: number,
	ParagraphSpacing: number,
}

export type LabelParams = {
	Measure: Measurer,
	Text: string, -- xl_text: the translated text
	Uppercase: boolean,
	FontSize: number, -- whole pixels, as the theme or LabelSettings give it
	LineSpacing: number, -- line_spacing (the LabelSettings value when set)
	ParagraphSpacing: number, -- paragraph_spacing (same rule)
	ParagraphSeparator: string, -- after c_unescape: "\n" by default, never empty
	AutowrapMode: number, -- 0 Off, 1 Arbitrary, 2 Word, 3 Word (Smart)
	Clip: boolean, -- clip_text
	OverrunBehavior: number, -- 0 Trim Nothing, 1..6 trim or ellipsis
	HorizontalAlignment: number, -- 0 Left, 1 Center, 2 Right, 3 Fill
	VerticalAlignment: number, -- 0 Top, 1 Center, 2 Bottom, 3 Fill
	MaxLinesVisible: number, -- -1 unlimited
	LinesSkipped: number,
	VisibleChars: number, -- -1 all
	VisibleCharsBehavior: number, -- 0 Characters Before Shaping (the only one that changes the lines)
	MaximumWidth: number, -- get_combined_maximum_size().x, -1 when unset
	RectWidth: number, -- get_size().width: the width the lines break at (the minimum height depends on it)
	LayoutRtl: boolean, -- is_layout_rtl()
	Normal: StyleMargins, -- the "normal" style box
}

type LargestBox = {
	Margins: StyleMargins,
	Size: vector,
}

export type DrawMode = "normal" | "hover" | "pressed" | "disabled" | "hover_pressed"

-- The theme's style boxes of a Button: Normal, Pressed, Hover, Disabled are always present; HoverPressed is nil when the
-- theme has no "hover_pressed" (Button, CheckBox and CheckButton differ). The *Mirrored boxes are nil when absent.
export type ButtonStyles = {
	Normal: StyleMargins,
	Pressed: StyleMargins,
	Hover: StyleMargins,
	Disabled: StyleMargins,
	HoverPressed: StyleMargins?,
	NormalMirrored: StyleMargins?,
	PressedMirrored: StyleMargins?,
	HoverMirrored: StyleMargins?,
	DisabledMirrored: StyleMargins?,
	HoverPressedMirrored: StyleMargins?,
}

export type ButtonParams = {
	Measure: Measurer,
	Text: string, -- xl_text: the translated text
	FontSize: number,
	LineSpacing: number, -- line_spacing of the text paragraph
	HorizontalSeparation: number, -- h_separation
	IconMaxWidth: number, -- icon_max_width, 0 for no limit
	AlignToLargestStylebox: boolean, -- align_to_largest_stylebox
	Alignment: number, -- text_alignment: 0 Left, 1 Center, 2 Right, 3 Fill
	IconAlignment: number, -- icon_alignment (horizontal)
	VerticalIconAlignment: number, -- vertical_icon_alignment: 0 Top, 1 Center, 2 Bottom, 3 Fill
	ExpandIcon: boolean,
	ClipText: boolean, -- clip_text
	OverrunBehavior: number,
	AutowrapMode: number,
	LayoutRtl: boolean,
	Mode: DrawMode, -- get_draw_mode()
	Styles: ButtonStyles,
	IconSize: vector?, -- the icon texture's size (x, y); nil without an icon
	TextWidth: number?, -- the width the text paragraph was last laid out at (text_buf); nil before its first draw
	InternalLeft: number, -- _internal_margin set by derived classes (CheckBox's check icon); 0 when not modeled
	InternalRight: number,
}

export type LineEditParams = {
	Measure: Measurer,
	Text: string,
	Placeholder: string, -- placeholder_text, translated
	Secret: boolean, -- secret
	SecretCharacter: string, -- secret_character: "" for the bullet
	ImeText: string, -- IME preedit text: "" (Roblox has none)
	CaretColumn: number, -- caret column in code points, where ImeText is inserted
	FontSize: number,
	MinimumCharacterWidth: number, -- theme minimum_character_width
	CaretWidth: number, -- theme caret_width
	ExpandToTextLength: boolean,
	Editable: boolean, -- is_editable()
	ClearButtonEnabled: boolean,
	ClearIconSize: vector, -- the theme clear icon's size (x, y)
	RightIconSize: vector?, -- right_icon's size; nil without one
	IconExpandMode: number, -- 0 Original, 1 Fit to Text, 2 Fit to LineEdit
	RightIconScale: number, -- right_icon_scale (Fit to LineEdit only)
	Alignment: number, -- 0 Left, 1 Center, 2 Right, 3 Fill
	ScrollOffset: number, -- scroll_offset (the caret's scroll; 0 when the text fits)
	LayoutRtl: boolean,
	RectWidth: number, -- get_size().width (the icon sizes depend on it in Fit to LineEdit)
	RectHeight: number,
	Normal: StyleMargins, -- the "normal" style box
	ReadOnly: StyleMargins, -- the "read_only" style box
}

export type RichTextParams = {
	Measure: Measurer,
	Text: string, -- the text measured (the builder's BBCode conversion, if any)
	FontSize: number,
	Margins: StyleMargins, -- the "normal" style box
}

type Paragraph = {
	Lines: number,
	LineHeight: number,
	Width: number,
}

type LabelShape = {
	Paragraphs: { Paragraph },
	Lines: number,
	Width: number, -- minsize.width
	Height: number, -- minsize.height
	WrapWidth: number, -- Label::_shape's width (an int), the width of the lines when broken
	Wrap: number?, -- the width the lines were broken at; nil when they are not broken
}

type TextBlock = {
	Width: number,
	Height: number,
	Lines: number,
	LineHeight: number,
}

-- The font's line height (Godot's font->get_height): the measurer's LineHeight, which is Godot's font height.
const function FontHeightOf(Measure: Measurer, FontSize: number): number
	return (select(2, Measure("W", FontSize, nil)))
end

-- Godot's font height from the font's ascent and descent (em fractions, descent positive): each rounded up to whole
-- pixels, as FreeType's size metrics are. The Roblox line height is not used: it is TextSize.
const function FontHeight(Ascent: number, Descent: number, Size: number): number
	return math.ceil(Ascent * Size) + math.ceil(Descent * Size)
end

-- Godot's int font height (Label keeps it in an int).
const function LineHeightOf(Para: Paragraph, FontHeightWhole: number): number
	return math.max(FontHeightWhole, Para.LineHeight)
end

const function ParagraphHeight(Lines: number, LineHeight: number, LineSpacing: number): number
	if Lines == 0 then
		return 0
	end

	return Lines * LineHeight + (Lines - 1) * LineSpacing
end

-- Chooses the box of a style: the mirrored one under RTL when the theme has it.
const function Pick(Rtl: boolean, Mirrored: StyleMargins?, Plain: StyleMargins): StyleMargins
	if Rtl and Mirrored then
		return Mirrored
	end

	return Plain
end

-- Swaps Left and Right under RTL (Button's icon and text alignment, Label's layout direction).
const function Mirror(Align: number, Rtl: boolean): number
	if not Rtl then
		return Align
	elseif Align == AlignLeft then
		return AlignRight
	elseif Align == AlignRight then
		return AlignLeft
	end

	return Align
end

-- C round(): half away from zero.
const function RoundAway(Value: number): number
	if Value < 0 then
		return -Numbers.RoundHalfUp(-Value)
	end

	return Numbers.RoundHalfUp(Value)
end

-- Byte index of the code point at Column (0 based), or the end of the text.
const function ByteIndex(Text: string, Column: number): number
	return utf8.offset(Text, Column + 1) or #Text + 1
end

const function Prefix(Text: string, Column: number): string
	return string.sub(Text, 1, ByteIndex(Text, Column) - 1)
end

const function Suffix(Text: string, Column: number): string
	return string.sub(Text, ByteIndex(Text, Column))
end

-- Length in code points (Godot String.length()).
const function Length(Text: string): number
	return utf8.len(Text) or #Text
end

-- String.split(separator) with the empty entries kept (Godot's allow_empty default). An empty separator splits nothing.
const function SplitText(Text: string, Separator: string): { string }
	const Pieces: { string } = {}

	if Separator == "" then
		table.insert(Pieces, Text)

		return Pieces
	end

	local From = 1

	while true do
		const Start, Finish = string.find(Text, Separator, From, true)

		if Start == nil or Finish == nil then
			break
		end

		table.insert(Pieces, string.sub(Text, From, Start - 1))
		From = Finish + 1
	end

	table.insert(Pieces, string.sub(Text, From))

	return Pieces
end

-- A Button's text paragraph ends its last line at a final line break (Godot adds no line after it), so "X\n" is one line,
-- where a Label keeps it as an empty paragraph (SplitText). Removes one final "\n".
const function TrimFinalBreak(Text: string): string
	if string.sub(Text, -1) == "\n" then
		return string.sub(Text, 1, -2)
	end

	return Text
end

-- Godot's window of one paragraph (Lines lines from LineIndex) inside the drawn lines [Skipped, LastLine): the lines
-- Start..End-1 of the paragraph, and whether the paragraph is processed (it then adds its paragraph spacing).
const function Window(LineIndex: number, Lines: number, Skipped: number, LastLine: number): (number, number, boolean)
	if LineIndex + Lines <= Skipped then
		return 0, 0, false
	end

	const Start = if LineIndex < Skipped then Skipped - LineIndex else 0
	const End = if LineIndex + Lines < LastLine then Lines else LastLine - LineIndex

	if End <= 0 then
		return 0, 0, false
	end

	return Start, End, true
end

-- Label::_shape for one paragraph: an empty one is one line of font height; otherwise measured, broken at Wrap when
-- given. Width is the unwrapped width when it is needed (no wrapping, or wrapping at a maximum width), else 0.
-- @src engine/gui/label.cpp:Label::_shape L144-364
const function LabelParagraph(Params: LabelParams, Piece: string, Wrap: number?, WidthNeeded: boolean, FontHeight: number): Paragraph
	if Piece == "" then
		return { Lines = 1, LineHeight = FontHeight, Width = 0 }
	end

	if Wrap == nil then
		const Width, LineHeight, Lines = Params.Measure(Piece, Params.FontSize, nil)

		return { Lines = Lines, LineHeight = LineHeight, Width = Width }
	end

	const LineHeight, Lines = select(2, Params.Measure(Piece, Params.FontSize, Wrap))
	local Width = 0

	if WidthNeeded then
		Width = Params.Measure(Piece, Params.FontSize, nil)
	end

	return { Lines = Lines, LineHeight = LineHeight, Width = Width }
end

-- Label::_update_visible: the height of the lines from LinesSkipped on, up to MaxLinesVisible, with their spacing but
-- without the trailing spacing (no height limit applies).
-- @src engine/gui/label.cpp:Label::_update_visible L366-410
const function LabelVisibleHeight(Params: LabelParams, Paragraphs: { Paragraph }, Lines: number, FontHeightWhole: number): number
	local Visible = Lines

	if Params.MaxLinesVisible >= 0 and Visible > Params.MaxLinesVisible then
		Visible = Params.MaxLinesVisible
	end

	const LastLine = math.min(Lines, Visible + Params.LinesSkipped)
	local Height = 0
	local LineIndex = 0

	for _, Para in Paragraphs do
		const Start, End, Processed = Window(LineIndex, Para.Lines, Params.LinesSkipped, LastLine)

		if Processed then
			for _ = Start, End - 1 do
				Height += LineHeightOf(Para, FontHeightWhole) + Params.LineSpacing
			end

			Height += Params.ParagraphSpacing
		end

		LineIndex += Para.Lines
	end

	if Height > 0 then
		Height -= Params.LineSpacing + Params.ParagraphSpacing
	end

	return Height
end

-- Label::_shape: the paragraphs of the text, their lines, and minsize (the line breaks use the control's width).
-- @src engine/gui/label.cpp:Label::_shape L144-364
const function ShapeLabel(Params: LabelParams, RectWidth: number, FontHeight: number): LabelShape
	const FontHeightWhole = Numbers.TruncInt32(FontHeight)
	const StyleWidth = Params.Normal.Left + Params.Normal.Right
	const Wrapping = Params.AutowrapMode ~= AutowrapOff
	const WrapWithMaximum = Wrapping and Params.MaximumWidth > 0
	local WrapWidth = Numbers.TruncInt32(RectWidth - StyleWidth)

	if WrapWithMaximum then
		WrapWidth = Numbers.TruncInt32(Params.MaximumWidth - StyleWidth)

		if WrapWidth <= 0 then
			WrapWidth = 1
		end
	end

	const Wrap: number? = if Wrapping and WrapWidth > 0 then WrapWidth else nil
	local Text = Params.Text

	if Params.Uppercase then
		Text = string.upper(Text)
	end

	if Params.VisibleChars >= 0 and Params.VisibleCharsBehavior == VisibleCharsBeforeShaping then
		Text = Prefix(Text, Params.VisibleChars)
	end

	const WidthNeeded = not Wrapping or WrapWithMaximum
	const Paragraphs: { Paragraph } = {}
	local Lines = 0

	for _, Piece in SplitText(Text, Params.ParagraphSeparator) do
		const Para = LabelParagraph(Params, Piece, Wrap, WidthNeeded, FontHeight)

		table.insert(Paragraphs, Para)
		Lines += Para.Lines
	end

	if Params.Text == "" then
		return {
			Paragraphs = Paragraphs,
			Lines = Lines,
			Width = 1,
			Height = Numbers.TruncInt32(math.max(FontHeightWhole, FontHeight)),
			WrapWidth = WrapWidth,
			Wrap = Wrap,
		}
	end

	local MinWidth = 0

	if not Wrapping or WrapWithMaximum then
		for _, Para in Paragraphs do
			MinWidth = math.max(MinWidth, Para.Width)
		end
	end

	if WrapWithMaximum then
		MinWidth = math.min(MinWidth, WrapWidth)
	end

	return {
		Paragraphs = Paragraphs,
		Lines = Lines,
		Width = MinWidth,
		Height = LabelVisibleHeight(Params, Paragraphs, Lines, FontHeightWhole),
		WrapWidth = WrapWidth,
		Wrap = Wrap,
	}
end

-- Label::get_minimum_size: the minsize with the font height as a floor, 1 pixel when the text can be cut, and the
-- normal style box added. Autowrapping labels have a width of 1.
-- @src engine/gui/label.cpp:Label::get_minimum_size L991-1016
const function LabelMinimumSize(Params: LabelParams): vector
	const FontHeight = FontHeightOf(Params.Measure, Params.FontSize)
	const Shape = ShapeLabel(Params, Params.RectWidth, FontHeight)
	const Style = Params.Normal
	local MinWidth = Shape.Width
	local MinHeight = math.max(Shape.Height, FontHeight)
	const Trims = Params.OverrunBehavior ~= OverrunNoTrimming

	if Params.AutowrapMode ~= AutowrapOff then
		if not Params.Clip and Trims and Params.MaxLinesVisible > 0 then
			MinHeight = math.min(MinHeight, (FontHeight + Params.LineSpacing) * Params.MaxLinesVisible)
		elseif Params.Clip or Trims then
			MinHeight = 1
		end

		return vector.create(1 + Style.Left + Style.Right, MinHeight + Style.Top + Style.Bottom, 0)
	end

	if Params.Clip or Trims then
		MinWidth = 1
	end

	return vector.create(MinWidth + Style.Left + Style.Right, MinHeight + Style.Top + Style.Bottom, 0)
end

-- Label::get_layout_data (vertical) with Label::_get_line_rect (horizontal): the drawn lines inside the control's height
-- and their text box. Vertical alignment spreads the lines (FILL) or centers and bottoms the block as Godot does.
-- @src engine/gui/label.cpp:Label::get_layout_data L538-641
-- @src engine/gui/label.cpp:Label::_get_line_rect L488-536
const function LabelLayout(Params: LabelParams, RectWidth: number, RectHeight: number): Layout
	const FontHeight = FontHeightOf(Params.Measure, Params.FontSize)
	const FontHeightWhole = Numbers.TruncInt32(FontHeight)
	const Shape = ShapeLabel(Params, RectWidth, FontHeight)
	const Paragraphs = Shape.Paragraphs
	const Style = Params.Normal
	const Skipped = Params.LinesSkipped
	const LineSpacing = Params.LineSpacing
	const ParagraphSpacing = Params.ParagraphSpacing

	-- First pass: the lines that fit the height (the total grows with each line, so the first one that does not fit ends it).
	const Limit = math.ceil(RectHeight - (Style.Top + Style.Bottom) + LineSpacing)
	local Total = 0
	local Visible = 0
	local LineIndex = 0

	for _, Para in Paragraphs do
		const Start, End, Processed = Window(LineIndex, Para.Lines, Skipped, math.huge)

		if Processed then
			for _ = Start, End - 1 do
				Total += LineHeightOf(Para, FontHeightWhole) + LineSpacing

				if Total > Limit then
					break
				end

				Visible += 1
			end

			Total += ParagraphSpacing
		end

		LineIndex += Para.Lines
	end

	if Params.MaxLinesVisible >= 0 and Visible > Params.MaxLinesVisible then
		Visible = Params.MaxLinesVisible
	end

	const LastLine = math.min(Shape.Lines, Visible + Skipped)

	-- Second pass: the drawn lines and the height of the whole block.
	Total = 0
	LineIndex = 0

	local Drawn = 0
	local Segments = 0
	local LinesHeight = 0

	for _, Para in Paragraphs do
		const Start, End, Processed = Window(LineIndex, Para.Lines, Skipped, LastLine)

		if Processed then
			for _ = Start, End - 1 do
				Total += LineHeightOf(Para, FontHeightWhole) + LineSpacing
				LinesHeight += LineHeightOf(Para, FontHeightWhole)
				Drawn += 1
			end

			if End > Start then
				Segments += 1
			end

			Total += ParagraphSpacing
		end

		LineIndex += Para.Lines
	end

	Total += Style.Top + Style.Bottom

	local VBegin = 0
	local VSep = 0

	if Visible > 0 then
		const Content = Total - LineSpacing - ParagraphSpacing

		if Params.VerticalAlignment == AlignCenter then
			VBegin = Numbers.TruncInt32((RectHeight - Content) / 2)
		elseif Params.VerticalAlignment == AlignBottom then
			VBegin = Numbers.TruncInt32(RectHeight - Content)
		elseif Params.VerticalAlignment == AlignFill and Visible > 1 then
			VSep = Numbers.TruncInt32((RectHeight - Content) / (Visible - 1))
		end
	end

	const Effective = LineSpacing + VSep
	local Block = 0

	if Drawn > 0 then
		Block = LinesHeight + (Drawn - 1) * Effective + (Segments - 1) * ParagraphSpacing
	end

	-- Horizontal: Godot's line offsets are the style's left offset (left), the right margin's edge (right) or the centre of
	-- the full width (center, no wrapping). The box below gives Roblox the same edges with the same alignment.
	const Wraps = Params.AutowrapMode ~= AutowrapOff
	local Align = Mirror(Params.HorizontalAlignment, Params.LayoutRtl)

	if Align == AlignFill then
		Align = AlignLeft
	end

	local BoxX = Style.Left
	local BoxWidth = math.max(0, Shape.WrapWidth)

	if Align == AlignCenter and not Wraps then
		BoxX = 0
		BoxWidth = RectWidth
	end

	return {
		Text = { X = BoxX, Y = Style.Top + VBegin, Width = BoxWidth, Height = Block },
		Icon = nil,
		Align = Align,
		LineCount = Drawn,
		LineHeight = LineHeightOf(Paragraphs[1], FontHeightWhole),
		LineSpacing = Effective,
		ParagraphSpacing = ParagraphSpacing,
	}
end

-- The text paragraph of a Button (text_buf) at Width, broken only with autowrapping and a positive width.
-- @src engine/gui/button.cpp:Button::_shape L536-580
const function ButtonBlock(Params: ButtonParams, Width: number?): TextBlock
	const Shown = TrimFinalBreak(Params.Text)

	if Shown == "" then
		return { Width = 0, Height = 0, Lines = 0, LineHeight = 0 }
	end

	const Wrap: number? = if Params.AutowrapMode ~= AutowrapOff and Width ~= nil and Width > 0 then Width else nil
	const TextWidth, LineHeight, Lines = Params.Measure(Shown, Params.FontSize, Wrap)

	return {
		Width = TextWidth,
		Height = ParagraphHeight(Lines, LineHeight, Params.LineSpacing),
		Lines = Lines,
		LineHeight = LineHeight,
	}
end

-- Button::_get_current_stylebox: the box of the draw mode (hover_pressed falls back to pressed without its own box), mirrored
-- under RTL when the theme has the mirrored box.
-- @src engine/gui/button.cpp:Button::_get_current_stylebox L103-154
const function CurrentStyle(Params: ButtonParams): StyleMargins
	const Styles = Params.Styles
	const Rtl = Params.LayoutRtl
	const Mode = Params.Mode

	if Mode == "disabled" then
		return Pick(Rtl, Styles.DisabledMirrored, Styles.Disabled)
	elseif Mode == "hover" then
		return Pick(Rtl, Styles.HoverMirrored, Styles.Hover)
	elseif Mode == "hover_pressed" and Styles.HoverPressed then
		return Pick(Rtl, Styles.HoverPressedMirrored, Styles.HoverPressed)
	elseif Mode == "pressed" or Mode == "hover_pressed" then
		return Pick(Rtl, Styles.PressedMirrored, Styles.Pressed)
	end

	return Pick(Rtl, Styles.NormalMirrored, Styles.Normal)
end

-- Button::_update_theme_item_cache: the largest margin per side and the largest minimum size over the boxes a button
-- draws (normal, hover_pressed when the theme has it, pressed, hover, disabled). Focus is not one of them.
-- @src engine/gui/button.cpp:Button::_update_theme_item_cache L59-97
-- @src engine/gui/button.cpp:Button::_update_style_margins L696-702
const function LargestStyle(Params: ButtonParams): LargestBox
	const Styles = Params.Styles
	const Rtl = Params.LayoutRtl
	const HoverPressed = Styles.HoverPressed
	const Boxes: { StyleMargins } = {}

	table.insert(Boxes, Pick(Rtl, Styles.NormalMirrored, Styles.Normal))

	if HoverPressed then
		table.insert(Boxes, Pick(Rtl, Styles.HoverPressedMirrored, HoverPressed))
	end

	table.insert(Boxes, Pick(Rtl, Styles.PressedMirrored, Styles.Pressed))
	table.insert(Boxes, Pick(Rtl, Styles.HoverMirrored, Styles.Hover))
	table.insert(Boxes, Pick(Rtl, Styles.DisabledMirrored, Styles.Disabled))

	local Left = 0
	local Top = 0
	local Right = 0
	local Bottom = 0
	local SizeWidth = 0
	local SizeHeight = 0

	for _, Box in Boxes do
		Left = math.max(Left, Box.Left)
		Top = math.max(Top, Box.Top)
		Right = math.max(Right, Box.Right)
		Bottom = math.max(Bottom, Box.Bottom)
		SizeWidth = math.max(SizeWidth, Box.Left + Box.Right)
		SizeHeight = math.max(SizeHeight, Box.Top + Box.Bottom)
	end

	SizeWidth = math.max(SizeWidth, Left + Right)
	SizeHeight = math.max(SizeHeight, Top + Bottom)

	return {
		Margins = { Left = Left, Top = Top, Right = Right, Bottom = Bottom },
		Size = vector.create(SizeWidth, SizeHeight, 0),
	}
end

-- Button::_fit_icon_size: the icon limited by icon_max_width (0 for none), keeping its aspect ratio.
-- @src engine/gui/button.cpp:Button::_fit_icon_size L477-487
const function FitIcon(Width: number, Height: number, MaxWidth: number): (number, number)
	if MaxWidth > 0 and Width > MaxWidth then
		return MaxWidth, Height * MaxWidth / Width
	end

	return Width, Height
end

-- Button::get_minimum_size_for_text_and_icon, with the largest style box (align_to_largest_stylebox) or the current one.
-- @src engine/gui/button.cpp:Button::get_minimum_size_for_text_and_icon L489-534
const function ButtonMinimumSize(Params: ButtonParams): vector
	const FontHeight = FontHeightOf(Params.Measure, Params.FontSize)
	const Block = ButtonBlock(Params, Params.TextWidth)
	local Width = Block.Width
	local Height = Block.Height
	const Clipped = Params.ClipText or Params.OverrunBehavior ~= OverrunNoTrimming or Params.AutowrapMode ~= AutowrapOff

	if Clipped then
		Width = 0
	end

	const IconSize = Params.IconSize

	if not Params.ExpandIcon and IconSize then
		const IconWidth, IconHeight = FitIcon(IconSize.x, IconSize.y, Params.IconMaxWidth)

		if Params.VerticalIconAlignment == AlignCenter then
			Height = math.max(Height, IconHeight)
		else
			Height += IconHeight
		end

		if Params.IconAlignment ~= AlignCenter then
			Width += IconWidth

			if Params.Text ~= "" then
				Width += math.max(0, Params.HorizontalSeparation)
			end
		else
			Width = math.max(Width, IconWidth)
		end
	end

	if Params.Text ~= "" then
		if Params.VerticalIconAlignment == AlignCenter then
			Height = math.max(FontHeight, Height)
		else
			Height += FontHeight
		end
	end

	if Params.AlignToLargestStylebox then
		const Largest = LargestStyle(Params)

		return vector.create(Largest.Size.x + Width, Largest.Size.y + Height, 0)
	end

	const Current = CurrentStyle(Params)

	return vector.create(Current.Left + Current.Right + Width, Current.Top + Current.Bottom + Height, 0)
end

-- Button::_notification (NOTIFICATION_DRAW): the icon box and the text box inside the button, from the style margins
-- (the largest ones with align_to_largest_stylebox), the internal margins and the alignments.
-- @src engine/gui/button.cpp:Button::_notification L211-473
const function ButtonLayout(Params: ButtonParams, RectWidth: number, RectHeight: number): Layout
	const Largest = LargestStyle(Params).Margins
	const Current = CurrentStyle(Params)
	const Margins = if Params.AlignToLargestStylebox then Largest else Current
	const Rtl = Params.LayoutRtl
	const HSep = math.max(0, Params.HorizontalSeparation)
	local LeftWithSeparation = Params.InternalLeft
	local RightWithSeparation = Params.InternalRight

	if Params.InternalLeft > 0 then
		LeftWithSeparation += HSep
	end

	if Params.InternalRight > 0 then
		RightWithSeparation += HSep
	end

	local RemainWidth = RectWidth - (Margins.Left + Margins.Right) - (LeftWithSeparation + RightWithSeparation)
	local RemainHeight = RectHeight - (Margins.Top + Margins.Bottom)
	const CustomWidth = RemainWidth
	const CustomHeight = RemainHeight
	const IconAlign = Mirror(Params.IconAlignment, Rtl)
	const TextAlign = Mirror(Params.Alignment, Rtl)
	const Clipped = Params.ClipText or Params.OverrunBehavior ~= OverrunNoTrimming or Params.AutowrapMode ~= AutowrapOff
	local Icon: Rect? = nil
	local Lines = 0
	local LineHeight = 0

	if Params.IconSize then
		local IconWidth = Params.IconSize.x
		local IconHeight = Params.IconSize.y

		if Params.ExpandIcon then
			const Block = ButtonBlock(Params, Params.TextWidth)
			local SizeWidth = CustomWidth
			local SizeHeight = CustomHeight

			if not Clipped and IconAlign ~= AlignCenter and Block.Width > 0 then
				SizeWidth -= Block.Width + HSep
			end

			if Params.VerticalIconAlignment ~= AlignCenter then
				SizeHeight -= Block.Height
			end

			local FitWidth = IconWidth * SizeHeight / IconHeight
			local FitHeight = SizeHeight

			if FitWidth > SizeWidth then
				FitWidth = SizeWidth
				FitHeight = IconHeight * FitWidth / IconWidth
			end

			IconWidth = FitWidth
			IconHeight = FitHeight
		end

		IconWidth, IconHeight = FitIcon(IconWidth, IconHeight, Params.IconMaxWidth)
		IconWidth = RoundAway(IconWidth)
		IconHeight = RoundAway(IconHeight)

		if IconWidth > 0 then
			local OffsetX = 0
			local OffsetY = 0

			if IconAlign == AlignCenter then
				OffsetX = (CustomWidth - IconWidth) / 2 + Margins.Left + LeftWithSeparation
			elseif IconAlign == AlignRight then
				OffsetX = RectWidth - Margins.Right - RightWithSeparation - IconWidth
			else
				OffsetX = Margins.Left + LeftWithSeparation
			end

			if Params.VerticalIconAlignment == AlignCenter then
				OffsetY = (CustomHeight - IconHeight) / 2 + Margins.Top
			elseif Params.VerticalIconAlignment == AlignBottom then
				OffsetY = RectHeight - Margins.Bottom - IconHeight
			else
				OffsetY = Margins.Top
			end

			Icon = { X = OffsetX // 1, Y = OffsetY // 1, Width = IconWidth, Height = IconHeight }
		end

		if Params.Text ~= "" then
			if IconAlign ~= AlignCenter then
				RemainWidth -= IconWidth + HSep
			end

			if Params.VerticalIconAlignment ~= AlignCenter then
				RemainHeight -= IconHeight
			end
		end
	end

	local Text = { X = 0, Y = 0, Width = 0, Height = 0 }

	if Params.Text ~= "" then
		const TextBufWidth = math.ceil(math.max(1, RemainWidth))
		const Block = ButtonBlock(Params, TextBufWidth)
		local OffsetX = 0

		if TextAlign == AlignCenter then
			OffsetX = (RemainWidth - TextBufWidth) / 2
		end

		OffsetX += Margins.Left + LeftWithSeparation

		if IconAlign == AlignLeft then
			OffsetX += CustomWidth - RemainWidth
		end

		local OffsetY = (RemainHeight - Block.Height) / 2 + Margins.Top

		if Params.VerticalIconAlignment == AlignTop then
			OffsetY += CustomHeight - RemainHeight
		end

		Text = { X = OffsetX, Y = OffsetY, Width = TextBufWidth, Height = Block.Height }
		Lines = Block.Lines
		LineHeight = Block.LineHeight
	end

	return {
		Text = Text,
		Icon = Icon,
		Align = if TextAlign == AlignFill then AlignLeft else TextAlign,
		LineCount = Lines,
		LineHeight = LineHeight,
		LineSpacing = Params.LineSpacing,
		ParagraphSpacing = 0,
	}
end

-- The text drawn in a LineEdit (LineEdit::_shape): the placeholder when empty, bullets for secret text, the IME text inserted
-- at the caret, else the text.
-- @src engine/gui/line_edit.cpp:LineEdit::_shape L3095-3144
const function LineEditDisplay(Params: LineEditParams): string
	if Params.Text == "" and Params.ImeText == "" then
		return Params.Placeholder
	end

	if Params.Secret then
		local Mask = SecretBullet

		if Params.SecretCharacter ~= "" then
			Mask = string.sub(Params.SecretCharacter, 1, ByteIndex(Params.SecretCharacter, 1) - 1)
		end

		return string.rep(Mask, Length(Params.Text) + Length(Params.ImeText))
	end

	if Params.ImeText ~= "" then
		const Before = Prefix(Params.Text, Params.CaretColumn)
		const After = Suffix(Params.Text, Params.CaretColumn)

		return `{Before}{Params.ImeText}{After}`
	end

	return Params.Text
end

-- Width and height of the displayed text of a LineEdit (both 0 for no text).
const function DisplayBlock(Params: LineEditParams, Display: string): (number, number)
	if Display == "" then
		return 0, 0
	end

	const Width, LineHeight = Params.Measure(Display, Params.FontSize, nil)

	return Width, LineHeight
end

-- LineEdit::_get_right_icon_size: the icon size for its expand mode (Original, Fit to Text, Fit to LineEdit).
-- @src engine/gui/line_edit.cpp:LineEdit::_get_right_icon_size L379-411
const function IconSizeOf(IconWidth: number, IconHeight: number, Mode: number, Scale: number, FontHeight: number, RectWidth: number, RectHeight: number): (number, number)
	if Mode == ExpandFitToText then
		return FontHeight, FontHeight
	elseif Mode == ExpandFitToLineEdit then
		local Width = IconWidth * RectHeight / IconHeight
		local Height = RectHeight

		if Width > RectWidth then
			Width = RectWidth
			Height = IconHeight * Width / IconWidth
		end

		return Width * Scale, Height * Scale
	end

	return IconWidth, IconHeight
end

-- LineEdit::get_minimum_size: the minimum character width (of "W") or the text when it expands, the text or font height,
-- the icons' heights and widths, and the larger of the normal and read-only style boxes.
-- @src engine/gui/line_edit.cpp:LineEdit::get_minimum_size L2458-2492
const function LineEditMinimumSize(Params: LineEditParams): vector
	const CharWidth = Params.Measure("W", Params.FontSize, nil)
	const FontHeight = FontHeightOf(Params.Measure, Params.FontSize)
	const TextWidth, TextHeight = DisplayBlock(Params, LineEditDisplay(Params))
	local MinWidth = Params.MinimumCharacterWidth * CharWidth

	if Params.ExpandToTextLength then
		MinWidth = math.max(MinWidth, TextWidth + Params.CaretWidth)
	end

	local MinHeight = math.max(TextHeight, FontHeight)
	local IconMaxWidth = 0

	if Params.RightIconSize then
		const Width, Height = IconSizeOf(Params.RightIconSize.x, Params.RightIconSize.y, Params.IconExpandMode, Params.RightIconScale, FontHeight, Params.RectWidth, Params.RectHeight)

		MinHeight = math.max(MinHeight, Height)
		IconMaxWidth = Width
	end

	if Params.ClearButtonEnabled then
		const Width, Height = IconSizeOf(Params.ClearIconSize.x, Params.ClearIconSize.y, Params.IconExpandMode, Params.RightIconScale, FontHeight, Params.RectWidth, Params.RectHeight)

		MinHeight = math.max(MinHeight, Height)
		IconMaxWidth = math.max(IconMaxWidth, Width)
	end

	MinWidth += IconMaxWidth

	const Normal = Params.Normal
	const ReadOnly = Params.ReadOnly
	const StyleWidth = math.max(Normal.Left + Normal.Right, ReadOnly.Left + ReadOnly.Right)
	const StyleHeight = math.max(Normal.Top + Normal.Bottom, ReadOnly.Top + ReadOnly.Bottom)

	return vector.create(StyleWidth + MinWidth, StyleHeight + MinHeight, 0)
end

-- LineEdit's draw of the text, the right or clear icon, from the style box (read-only when not editable), the alignment
-- and the scroll offset. Integer positions truncate as Godot's int x_ofs and y_ofs do.
-- @src engine/gui/line_edit.cpp:LineEdit::_notification L1380-1675
const function LineEditLayout(Params: LineEditParams, RectWidth: number, RectHeight: number): Layout
	const FontHeight = FontHeightOf(Params.Measure, Params.FontSize)
	const Style = if Params.Editable then Params.Normal else Params.ReadOnly
	const Left = Style.Left
	const Right = Style.Right
	const Display = LineEditDisplay(Params)
	const TextWidth, TextHeight = DisplayBlock(Params, Display)
	const UsingPlaceholder = Params.Text == "" and Params.ImeText == ""
	const Width = Numbers.TruncInt32(RectWidth)
	const Height = Numbers.TruncInt32(RectHeight)
	const Rtl = Params.LayoutRtl
	const Align = Params.Alignment
	const Scrolled = math.abs(Params.ScrollOffset) >= Epsilon
	local OffsetX = 0

	if Align == AlignFill or Align == AlignLeft then
		if Rtl then
			OffsetX = Numbers.TruncInt32(math.max(Left, Numbers.TruncInt32(RectWidth - math.ceil(Right + TextWidth))))
		else
			OffsetX = Numbers.TruncInt32(Left)
		end
	elseif Align == AlignCenter then
		if Scrolled then
			OffsetX = Numbers.TruncInt32(Left)
		else
			const Centered = Numbers.TruncDiv32(Numbers.TruncInt32(RectWidth - (Left + Right) - TextWidth), 2)

			OffsetX = Numbers.TruncInt32(Left + math.max(0, Centered))
		end
	else
		if Rtl then
			OffsetX = Numbers.TruncInt32(Left)
		else
			OffsetX = Numbers.TruncInt32(math.max(Left, Numbers.TruncInt32(RectWidth - math.ceil(Right + TextWidth))))
		end
	end

	local IconSource: vector? = Params.RightIconSize

	if Params.ClearButtonEnabled and not UsingPlaceholder and Params.Editable then
		IconSource = Params.ClearIconSize
	end

	local Icon: Rect? = nil

	if IconSource then
		const IconWidth, IconHeight = IconSizeOf(IconSource.x, IconSource.y, Params.IconExpandMode, Params.RightIconScale, FontHeight, RectWidth, RectHeight)

		if Align == AlignCenter then
			if not Scrolled then
				const Centered = Numbers.TruncDiv32(Numbers.TruncInt32(RectWidth - (Left + Right) - TextWidth - IconWidth), 2)

				OffsetX = Numbers.TruncInt32(Left + math.max(0, Centered))
			end

			if Rtl then
				OffsetX = Numbers.TruncInt32(OffsetX + IconWidth)
			end
		elseif Rtl then
			OffsetX = Numbers.TruncInt32(math.max(Left + IconWidth, OffsetX))
		else
			OffsetX = Numbers.TruncInt32(math.max(Left, OffsetX - IconWidth - Right))
		end

		const IconX = if Rtl then Left else Width - IconWidth - Right
		const IconY = Height // 2 - IconHeight / 2

		Icon = { X = IconX, Y = IconY, Width = IconWidth, Height = IconHeight }
	end

	const YArea = Numbers.TruncInt32(Height - (Style.Top + Style.Bottom))
	const OffsetY = Numbers.TruncInt32(Style.Top + (YArea - TextHeight) / 2)

	return {
		Text = { X = OffsetX + Params.ScrollOffset, Y = OffsetY, Width = TextWidth, Height = TextHeight },
		Icon = Icon,
		Align = AlignLeft,
		LineCount = if Display == "" then 0 else 1,
		LineHeight = TextHeight,
		LineSpacing = 0,
		ParagraphSpacing = 0,
	}
end

-- RichTextLabel with fit_content: the text broken at the width less the side margins (at least 1), its lines times the
-- line height, and the top and bottom margins. The RichTextLabel source is not fetched; this is the minimal rule.
const function RichTextFitHeight(Params: RichTextParams, Width: number): number
	const Margins = Params.Margins
	const Vertical = Margins.Top + Margins.Bottom

	if Params.Text == "" then
		return Vertical
	end

	const LineHeight, Lines = select(2, Params.Measure(Params.Text, Params.FontSize, math.max(1, Width - (Margins.Left + Margins.Right))))

	return Lines * LineHeight + Vertical
end

return {
	FontHeight = FontHeight,
	TrimFinalBreak = TrimFinalBreak,
	LabelMinimumSize = LabelMinimumSize,
	LabelLayout = LabelLayout,
	ButtonMinimumSize = ButtonMinimumSize,
	ButtonLayout = ButtonLayout,
	LineEditMinimumSize = LineEditMinimumSize,
	LineEditLayout = LineEditLayout,
	RichTextFitHeight = RichTextFitHeight,
}
