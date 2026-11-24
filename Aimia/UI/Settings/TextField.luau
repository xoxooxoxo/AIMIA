--!strict
--!optimize 2

--[[
	The settings menu's LineEdit (Godot line_edit.cpp with theme.tres): a text box with a placeholder, whose box is drawn only
	while it has focus when the field is flat (the settings fields), or always in the normal style (the profile name, which
	has an opaque black box). The focus box is a 1 pixel pink outline on black, rounded by 4.

	Design Notes
		text_submitted is the Enter key, and focus_exited the loss of focus; Roblox's FocusLost reports both, so an Enter
		calls OnSubmitted and then OnFocusExited (Godot's Enter keeps the focus, and the settings release it on apply anyway).
		max_length counts characters: a longer text is cut to the limit.
		The field is one container Frame (the box, the placeholder and the text box), so its Visible hides all of it.
]]

const Draw = require("./Draw")
const Fade = require("./Fade")
const Geometry = require("./Geometry")
const Look = require("./Look")
const Style = require("../Style")

type Rect = Geometry.Rect

export type TextField = {
	Container: Frame,
	Object: TextBox,
	Placeholder: TextLabel,
	Normal: Frame?,
	Focus: Frame,
	MaxLength: number,
	Overlay: Fade.Fade,
	OnSubmitted: ((Text: string) -> ())?,
	OnFocusExited: ((Text: string) -> ())?,
	Connections: { RBXScriptConnection },
}

export type FieldOptions = {
	Name: string,
	Rect: Rect,
	ZIndex: number,
	Flat: boolean,
	Editable: boolean?,
	Font: Font,
	FontSize: number,
	Placeholder: string,
	MaxLength: number,
	Overlay: Fade.Fade,
	OnSubmitted: ((Text: string) -> ())?,
	OnFocusExited: ((Text: string) -> ())?,
}

-- Cuts a text to MaxLength characters (0 means no limit).
const function Clamp(Text: string, MaxLength: number): string
	const Length = utf8.len(Text)

	if MaxLength <= 0 or Length == nil or Length <= MaxLength then
		return Text
	end

	const Cut = utf8.offset(Text, MaxLength + 1)

	return if Cut then string.sub(Text, 1, Cut - 1) else Text
end

-- Shows the placeholder while the text is empty.
const function ShowPlaceholder(Field: TextField)
	Field.Placeholder.Visible = Field.Object.Text == ""
end

-- The field's box and text. The text box and placeholder fill the field; the focus box shows while the text box has focus.
const function New(Parent: Instance, Options: FieldOptions): TextField
	const Container = Draw.Frame(Parent, Options.Name, Options.Rect, Options.ZIndex, false)
	const Local = { X = 0, Y = 0, Width = Options.Rect.Width, Height = Options.Rect.Height }
	local Normal: Frame? = nil

	if not Options.Flat then
		Normal = Draw.Frame(Container, "Normal", Local, Options.ZIndex, false)
		Draw.Fill(Normal, Look.FieldNormal)
	end

	const Focus = Draw.Frame(Container, "Focus", Local, Options.ZIndex + 1, false)

	Focus.Visible = false
	Draw.Fill(Focus, Look.FieldFocusFill)
	Draw.Corner(Focus, Look.Corner)
	Draw.Stroke(Focus, Look.FieldFocusStroke, Look.FieldFocusThickness)

	const Object = Instance.new("TextBox")
	const Padding = Instance.new("UIPadding")

	Object.Name = "Text"
	Object.Text = ""
	Object.PlaceholderText = ""
	Object.ClearTextOnFocus = false
	Object.MultiLine = false
	Object.FontFace = Options.Font
	Object.TextSize = Style.TextSizeOf(Options.Font, Options.FontSize)
	Object.TextColor3 = Look.FontNormal.Color
	Object.TextTransparency = 1 - Look.FontNormal.Alpha
	Object.TextXAlignment = Enum.TextXAlignment.Left
	Object.TextYAlignment = Enum.TextYAlignment.Center
	Object.TextEditable = Options.Editable ~= false
	Object.BackgroundTransparency = 1
	Object.BorderSizePixel = 0
	Object.ZIndex = Options.ZIndex + 2
	Object.Active = true
	Object.Size = UDim2.fromScale(1, 1)
	Object.Parent = Container

	Padding.PaddingLeft = UDim.new(0, Look.FieldInset)
	Padding.PaddingRight = UDim.new(0, Look.FieldInset)
	Padding.Parent = Object

	const Placeholder = Draw.Label(Container, "Placeholder", Local, Options.ZIndex + 2, Options.Placeholder, Options.Font, Options.FontSize, Look.FontPlaceholder, Enum.TextXAlignment.Left)

	Placeholder.Active = false
	Placeholder.ZIndex = Options.ZIndex + 2

	const PlaceholderPadding = Instance.new("UIPadding")

	PlaceholderPadding.PaddingLeft = UDim.new(0, Look.FieldInset)
	PlaceholderPadding.PaddingRight = UDim.new(0, Look.FieldInset)
	PlaceholderPadding.Parent = Placeholder

	const Field = {
		Container = Container,
		Object = Object,
		Placeholder = Placeholder,
		Normal = Normal,
		Focus = Focus,
		MaxLength = Options.MaxLength,
		Overlay = Options.Overlay,
		OnSubmitted = Options.OnSubmitted,
		OnFocusExited = Options.OnFocusExited,
		Connections = {},
	} :: TextField

	ShowPlaceholder(Field)

	table.insert(Field.Connections, Object.Focused:Connect(function()
		Field.Focus.Visible = true
	end))
	table.insert(Field.Connections, Object.FocusLost:Connect(function(EnterPressed: boolean)
		Field.Focus.Visible = false

		if EnterPressed and Field.OnSubmitted then
			Field.OnSubmitted(Object.Text)
		end

		if Field.OnFocusExited then
			Field.OnFocusExited(Object.Text)
		end
	end))
	table.insert(Field.Connections, Object:GetPropertyChangedSignal("Text"):Connect(function()
		const Limited = Clamp(Object.Text, Field.MaxLength)

		if Limited ~= Object.Text then
			Object.Text = Limited
		end

		ShowPlaceholder(Field)
	end))

	Fade.Track(Options.Overlay, Container)

	return Field
end

-- The text the field shows.
const function GetText(Field: TextField): string
	return Field.Object.Text
end

-- Sets the text the field shows (no signal beyond the text change).
const function SetText(Field: TextField, Text: string)
	Field.Object.Text = Text
end

-- Sets the placeholder shown while the text is empty.
const function SetPlaceholder(Field: TextField, Text: string)
	Field.Placeholder.Text = Text
end

-- The placeholder shown while the text is empty.
const function GetPlaceholder(Field: TextField): string
	return Field.Placeholder.Text
end

-- Releases the focus when the field is in the tree (Godot's release_focus).
const function ReleaseFocus(Field: TextField)
	Field.Object:ReleaseFocus()
end

-- Gives the field the keyboard, so the player can type right away.
const function CaptureFocus(Field: TextField)
	Field.Object:CaptureFocus()
end

-- Shows or hides the whole field.
const function SetVisible(Field: TextField, Visible: boolean)
	Field.Container.Visible = Visible
end

-- Places the field at Rect (its row changed size).
const function Place(Field: TextField, Rect: Geometry.Rect)
	Draw.Place(Field.Container, Rect)

	const Local = { X = 0, Y = 0, Width = Rect.Width, Height = Rect.Height }

	Draw.Place(Field.Object, Local)
	Draw.Place(Field.Placeholder, Local)

	if Field.Normal then
		Draw.Place(Field.Normal, Local)
	end

	Draw.Place(Field.Focus, Local)
end

return {
	New = New,
	GetText = GetText,
	SetText = SetText,
	SetPlaceholder = SetPlaceholder,
	GetPlaceholder = GetPlaceholder,
	ReleaseFocus = ReleaseFocus,
	CaptureFocus = CaptureFocus,
	SetVisible = SetVisible,
	Place = Place,
}
