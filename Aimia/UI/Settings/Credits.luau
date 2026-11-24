--!strict
--!optimize 2

--[[
	The CREDITS tab of the settings menu (AIMIA's own, after the sections): the blocks of UI/SettingsLogic/CreditsText as
	wrapped text, stacked in the tab's scroll area.

	Paradigm
		New(Area) fills a scroll area made by UI/SettingsMenu; Layout(Page, Rect) places the area and its text for the
		menu's size, as PlaceRow does for a section's rows.

	Design Notes
		Every block is a wrapped TextLabel that takes its own height (AutomaticSize), and a UIListLayout stacks them, so the
		text never overlaps, whatever the width or the font's state. The scroll area needs the content's height in layout
		pixels: Layout reads it from the list (screen pixels over the scale), and the list's size signal lays the area out
		again when a font finishes loading or a new width changes the wrapping.
		The labels don't localize (AutoLocalize off), so the license text stays word for word.
		Looks: titles and headings are white Ubuntu Medium, as the sidebar's buttons; the text is the rows' grey Ubuntu,
		and the license is one size smaller (the option size).
]]

const Scale = require("../Scale")
const Style = require("../Style")
const Geometry = require("./Geometry")
const Look = require("./Look")
const ScrollArea = require("./ScrollArea")
const CreditsText = require("../SettingsLogic/CreditsText")

type Rect = Geometry.Rect

export type Page = {
	Area: ScrollArea.ScrollArea,
	List: UIListLayout,
	Rect: Rect?,
	Height: number,
}

type Kind = { Font: Font, Size: number, Tint: Look.Tint, Gap: number }

-- The tab's name (its sidebar button shows it in capitals).
const Name = "Credits"

-- The look of each kind of block: its font, its Godot size, its tint, and the space above it in pixels.
const Kinds: { [string]: Kind } = {
	Title = { Font = Look.Fonts.UbuntuMedium, Size = Look.Sizes.Header, Tint = Look.FontWhite, Gap = 0 },
	Heading = { Font = Look.Fonts.UbuntuMedium, Size = Look.Sizes.Body, Tint = Look.FontWhite, Gap = 24 },
	Body = { Font = Look.Fonts.UbuntuRegular, Size = Look.Sizes.Body, Tint = Look.FontNormal, Gap = 8 },
	SmallHeading = { Font = Look.Fonts.UbuntuMedium, Size = Look.Sizes.Option, Tint = Look.FontWhite, Gap = 18 },
	Small = { Font = Look.Fonts.UbuntuRegular, Size = Look.Sizes.Option, Tint = Look.FontNormal, Gap = 8 },
}

-- Before the text has been measured it is taken as taller than any area (it is long), so the width leaves the bar its room.
const Unmeasured = 100000

-- The space between the text and the scroll bar, and below the last block, in pixels.
const RightMargin = 10
const BottomMargin = 16

-- The content's height in layout pixels, or nil while the list hasn't been measured yet.
const function Measure(Page: Page): number?
	const Screen = Page.List.AbsoluteContentSize.Y

	if Screen <= 0 then
		return nil
	end

	return math.ceil(Screen / Scale.FactorOf(Page.Area.Content)) + BottomMargin
end

-- Lays the area out again when the measured height has changed (the list's size signal and Layout).
const function Refit(Page: Page)
	const Rect = Page.Rect
	const Height = Measure(Page)

	if Rect and Height and Height ~= Page.Height then
		Page.Height = Height
		ScrollArea.Layout(Page.Area, Rect, Height)
	end
end

-- Fills Area's content with the credits' text blocks, in order.
const function New(Area: ScrollArea.ScrollArea): Page
	const Content = Area.Content
	const List = Instance.new("UIListLayout")

	List.Name = "Stack"
	List.FillDirection = Enum.FillDirection.Vertical
	List.SortOrder = Enum.SortOrder.LayoutOrder
	List.HorizontalAlignment = Enum.HorizontalAlignment.Left
	List.VerticalAlignment = Enum.VerticalAlignment.Top
	List.Padding = UDim.new(0, 0)
	List.Parent = Content

	for Index, Block in CreditsText.Blocks do
		const Kind = Kinds[Block.Kind] or Kinds.Body
		const Label = Instance.new("TextLabel")
		const Padding = Instance.new("UIPadding")

		Label.Name = `{Block.Kind}{Index}`
		Label.BackgroundTransparency = 1
		Label.BorderSizePixel = 0
		Label.ZIndex = 1
		Label.Active = false
		Label.AutoLocalize = false
		Label.RichText = false
		Label.Text = Block.Text
		Label.FontFace = Kind.Font
		Label.TextSize = Style.TextSizeOf(Kind.Font, Kind.Size)
		Label.TextColor3 = Kind.Tint.Color
		Label.TextTransparency = 1 - Kind.Tint.Alpha
		Label.TextWrapped = true
		Label.TextXAlignment = Enum.TextXAlignment.Left
		Label.TextYAlignment = Enum.TextYAlignment.Top
		Label.Size = UDim2.fromScale(1, 0)
		Label.AutomaticSize = Enum.AutomaticSize.Y
		Label.LayoutOrder = Index

		Padding.PaddingTop = UDim.new(0, if Index == 1 then 0 else Kind.Gap)
		Padding.PaddingRight = UDim.new(0, RightMargin)
		Padding.Parent = Label

		Label.Parent = Content
	end

	const Page = {
		Area = Area,
		List = List,
		Rect = nil,
		Height = Unmeasured,
	} :: Page

	-- (the connection goes with the list when the menu is destroyed)
	List:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		Refit(Page)
	end)

	return Page
end

-- Places the page's area at Rect (in the holder's space) for the text's height, the last one measured.
const function Layout(Page: Page, Rect: Rect)
	Page.Rect = Rect
	ScrollArea.Layout(Page.Area, Rect, Page.Height)
	Refit(Page)
end

return {
	Name = Name,
	New = New,
	Layout = Layout,
}
