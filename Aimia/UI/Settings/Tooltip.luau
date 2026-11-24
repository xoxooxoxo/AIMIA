--!strict
--!optimize 2

--[[
	The settings menu's tooltips (Godot's tooltip_text on a control, shown as a TooltipPanel): a text in a dark rounded box
	near the pointer after the pointer has rested on the control for 0.5 seconds. Leaving the control or pressing hides it.

	Design Notes
		One tooltip frame serves the whole menu, drawn in the menu's root above its holder. A text that is wider than the
		wrap width (300 pixels) wraps; the box stays inside the root.
		Each enter starts a new delay (a token): a leave or a newer enter makes an older delay do nothing.
		DEVIATION(unverified): the offset from the pointer (12, 12) is not in reference/engine.
]]

const Draw = require("./Draw")
const Scale = require("../Scale")
const Fade = require("./Fade")
const Look = require("./Look")
const Input = require("../Input")
const Items = require("../Item")

-- A tooltip text, or a getter read when the tooltip is shown (a text that changes, such as a link).
export type TipText = string | (() -> string)

export type Tooltip = {
	Frame: Frame,
	Label: TextLabel,
	Root: Frame,
	Token: number,
	Overlay: Fade.Fade,
}

const Offset = 12
-- The text is measured at its full size, but under a small window or Menu Scale it's drawn smaller, and small text comes out
-- a little wider than its share: the box gets that much more room, so a line never wraps early and loses its last words.
const WidthSlack = 1.1
const Font = Look.Fonts.Default
const FontSize = Look.Sizes.Body

-- The text box's size for a text, wrapped at the tooltip's wrap width.
const function BoxSize(Text: string): vector
	return Items.Measure(Text, Font, FontSize, Look.TooltipWrap)
end

-- Shows the tooltip with Text at the pointer, kept inside the root.
const function Show(Tip: Tooltip, Text: string)
	const Size = BoxSize(Text)
	const Width = math.ceil(Size.x * WidthSlack) + 2 * Look.TooltipMarginX
	const Height = math.round(Size.y) + 2 * Look.TooltipMarginY
	const Mouse = Input.GetGuiMousePosition()
	const Pointer = Mouse - Scale.PositionOf(Tip.Root)
	const RootSize = Scale.SizeOf(Tip.Root)
	const Left = math.clamp(math.round(Pointer.x) + Offset, 0, math.max(0, RootSize.x - Width))
	const Top = math.clamp(math.round(Pointer.y) + Offset, 0, math.max(0, RootSize.y - Height))

	Draw.Place(Tip.Frame, { X = Left, Y = Top, Width = Width, Height = Height })
	Draw.Place(Tip.Label, { X = Look.TooltipMarginX, Y = Look.TooltipMarginY, Width = Width - 2 * Look.TooltipMarginX, Height = Height - 2 * Look.TooltipMarginY })
	Tip.Label.Text = Text
	Tip.Frame.Visible = true
end

-- Hides the tooltip and ends any pending delay.
const function Hide(Tip: Tooltip)
	Tip.Token += 1
	Tip.Frame.Visible = false
end

-- The tooltip frame under Root, hidden.
const function New(Root: Frame, Overlay: Fade.Fade): Tooltip
	const Frame = Draw.Frame(Root, "Tooltip", { X = 0, Y = 0, Width = 0, Height = 0 }, 7, false)

	Frame.Visible = false
	Draw.Fill(Frame, Look.TooltipFill)
	Draw.Corner(Frame, Look.CornerSmall)

	const Label = Draw.Label(Frame, "Text", { X = 0, Y = 0, Width = 0, Height = 0 }, 8, "", Font, FontSize, Look.FontNormal, Enum.TextXAlignment.Left)

	Label.TextWrapped = true
	Label.TextTruncate = Enum.TextTruncate.None
	Label.TextYAlignment = Enum.TextYAlignment.Center

	const Tip = {
		Frame = Frame,
		Label = Label,
		Root = Root,
		Token = 0,
		Overlay = Overlay,
	} :: Tooltip

	Fade.Track(Overlay, Frame)

	return Tip
end

-- Shows Text over Target after the pointer has rested on it; leaving or pressing hides it. Empty text shows nothing.
const function Attach(Tip: Tooltip, Target: GuiObject, Text: TipText)
	Target.MouseEnter:Connect(function()
		if Input.Blocked(Target) then
			return
		end

		Tip.Token += 1

		const Token = Tip.Token

		task.delay(Look.TooltipDelay, function()
			const Current = if type(Text) == "string" then Text else Text()

			if Token == Tip.Token and Current ~= "" then
				Show(Tip, Current)
			end
		end)
	end)
	Target.MouseLeave:Connect(function()
		Hide(Tip)
	end)
	Target.InputBegan:Connect(function(Event: InputObject)
		if Event.UserInputType == Enum.UserInputType.MouseButton1 then
			Hide(Tip)
		end
	end)
end

return {
	New = New,
	Attach = Attach,
	Hide = Hide,
}
