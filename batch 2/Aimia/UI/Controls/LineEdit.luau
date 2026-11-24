--!strict
--!optimize 2

--[[
	LineEdit (Godot line_edit.cpp, with the theme items of theme.tres and the default theme) on a Roblox TextBox. The TextBox
	takes the keyboard, the caret, the selection, the clipboard and the placeholder. The style boxes are drawn behind it:
	"normal" always, and "focus" on top while the field has focus, as Godot's draw does.

	Paradigm
		The Instance tree of a LineEdit: "StyleBox" (ZIndex -2, SceneBuilder), "Focus" (ZIndex -1, the focus box, shown while
		the field has focus) and "Input" (the TextBox, ZIndex 0). The TextBox fills the content rect of the normal style box
		(its margins), so its width is the field's width and typing never resizes it.

	Owned State
		FocusOwner: the line edit that has focus (Nodes.GetFocusOwner). Set by the TextBox's Focused, cleared by FocusLost.

	Design Notes
		text_changed is the user's edit. A write of the text property (Nodes.Set) already matches the TextBox, so it emits
		nothing. Typing relayouts nothing unless expand_to_text_length makes the minimum size depend on the text.
		Enter emits text_submitted and keeps the focus, as Godot's unedit does: Roblox's TextBox loses focus on Enter, so
		the field takes it back, without focus_exited.
		Escape releases the focus (the field's behavior the brief asks for). The key is not delivered to other input while a
		TextBox has focus (UI/Input), so no shortcut sees Escape, Space or the letters typed into the field.
		A press outside the field releases its focus, which the TextBox does itself.

	DEVIATION(secret): a Roblox TextBox cannot mask its text; secret is ignored.
	DEVIATION(selection): the selection and caret colors are Roblox's (font_selected_color, caret_color, caret_width are not applied).
	DEVIATION(placeholder): PlaceholderColor3 has no alpha, so the placeholder color is blended over black by its alpha.
	DEVIATION(read_only): the read_only style box is not drawn (UI/Item's StyleFor gives normal); no scene sets editable = false.
	DEVIATION(icons): clear_button_enabled and right_icon are not drawn; no scene sets them.
	DEVIATION(caret_column): the Roblox cursor exists only while the TextBox has focus; caret_column reads 0 and ignores sets otherwise.
]]

const UserInputService = game:GetService("UserInputService")

const Items = require("../Item")
const Style = require("../Style")
const TextLimit = require("./TextLimit")

type Item = Items.Item

-- The line edit with keyboard focus (Nodes.GetFocusOwner), or nil.
local FocusOwner: Item? = nil

-- The focus box of a LineEdit's Instance, or nil.
const function FocusBoxOf(Item: Item): Frame?
	const Box = Item.Instance:FindFirstChild("Focus")

	if Box and Box:IsA("Frame") then
		return Box
	end

	return nil
end

-- Shows or hides the focus box (Godot draws the focus style box while the field has focus).
const function ShowFocusBox(Item: Item, Shown: boolean)
	const Box = FocusBoxOf(Item)

	if Box then
		Box.Visible = Shown
	end
end

-- The TextBox's text, placeholder, font and colors from the item, and its place in the normal box's content rect. The focus
-- box is drawn for the current size.
const function Draw(Item: Item)
	const Input = Item.Input :: TextBox
	const Properties = Item.Context.Properties
	const Own = Items.OwnModulate(Item)
	const Editable = Properties["editable"] ~= false
	const Content = Items.RawText(Item)
	const Placeholder = Properties["placeholder_text"]
	const Size = Item.Node.Size
	const Margins = Items.MarginsOf(Items.GetStyle(Item, "normal"))

	if Input.Text ~= Content then
		Input.Text = Content
	end

	Input.PlaceholderText = if type(Placeholder) == "string" then Placeholder else ""
	Input.TextEditable = Editable
	Input.FontFace = Items.GetFont(Item)
	Input.TextSize = Items.TextSizeOf(Items.GetFont(Item), Items.GetFontSize(Item))
	Input.TextXAlignment = Items.HorizontalAlignments[Items.Number(Properties, "alignment", 0)]

	const TextColor, TextTransparency = Style.ToColor({ Color = Items.GetColor(Item, if Editable then "font_color" else "font_uneditable_color") }, Own)

	Input.TextColor3 = TextColor
	Input.TextTransparency = TextTransparency

	const PlaceholderColor, PlaceholderTransparency = Style.ToColor({ Color = Items.GetColor(Item, "font_placeholder_color") }, Own)

	Input.PlaceholderColor3 = PlaceholderColor:Lerp(Color3.new(0, 0, 0), PlaceholderTransparency)

	Input.Position = UDim2.fromOffset(Margins.Left, Margins.Top)
	Input.Size = UDim2.fromOffset(math.max(0, Size.x - Margins.Left - Margins.Right), math.max(0, Size.y - Margins.Top - Margins.Bottom))

	const Box = FocusBoxOf(Item)

	if Box then
		Style.DrawStyleBox(Box, Items.GetStyle(Item, "focus"), Own, Size.x, Size.y)
	end
end

-- Adds the focus box and the TextBox, and connects the TextBox: text edits, focus, Enter, and Escape (which releases the
-- focus once the key has reached the other input handlers, so they all see the field as focused).
const function Build(Item: Item)
	const Gui = Item.Instance
	const Box = Instance.new("Frame")
	const Input = Instance.new("TextBox")

	Box.Name = "Focus"
	Box.BackgroundTransparency = 1
	Box.BorderSizePixel = 0
	Box.Size = UDim2.fromScale(1, 1)
	Box.Visible = false
	Box.ZIndex = -1
	Box.Parent = Gui

	Input.Name = "Input"
	Input.BackgroundTransparency = 1
	Input.BorderSizePixel = 0
	Input.ClearTextOnFocus = false
	Input.ClipsDescendants = true
	Input.MultiLine = false
	Input.TextWrapped = false
	Input.TextYAlignment = Enum.TextYAlignment.Center
	Input.ZIndex = 0
	Input.Parent = Gui

	Item.Input = Input
	table.insert(Item.Visuals, Box)
	table.insert(Item.Visuals, Input)

	table.insert(Item.Connections, Input.Changed:Connect(function(Property: string)
		if Property ~= "Text" then
			return
		end

		local Text = Input.Text
		const Limited = TextLimit(Text, Items.Number(Item.Context.Properties, "max_length", 0))

		if Limited ~= Text then
			Input.Text = Limited
			Text = Limited
		end

		if Text ~= Items.RawText(Item) then
			Item.Context.Properties["text"] = Text
			Items.Emit(Item, "text_changed", Text)
		end
	end))

	table.insert(Item.Connections, Input.Focused:Connect(function()
		ShowFocusBox(Item, true)

		-- typing replaces what is there, rather than adding to it
		Input.SelectionStart = 1
		Input.CursorPosition = #Input.Text + 1

		if FocusOwner ~= Item then
			FocusOwner = Item
			Items.Emit(Item, "focus_entered")
		end
	end))

	table.insert(Item.Connections, Input.FocusLost:Connect(function(EnterPressed: boolean)
		if EnterPressed then
			Items.Emit(Item, "text_submitted", Input.Text)

			if not Item.Freed and not (Item :: any).ReleaseOnSubmit then
				Input:CaptureFocus()

				return
			end
		end

		ShowFocusBox(Item, false)

		if FocusOwner == Item then
			FocusOwner = nil
		end

		Items.Emit(Item, "focus_exited")
	end))

	table.insert(Item.Connections, UserInputService.InputBegan:Connect(function(Raw: InputObject)
		if FocusOwner == Item and Raw.KeyCode == Enum.KeyCode.Escape then
			task.defer(function()
				Input:ReleaseFocus()
			end)
		end
	end))
end

-- Godot's caret_column: the caret's column in characters. The Roblox cursor exists only while the TextBox has focus.
const function GetCaretColumn(Item: Item): number
	const Input = Item.Input

	if not Input then
		return 0
	end

	return math.max(Input.CursorPosition - 1, 0)
end

-- Moves the caret to a column (characters), while the TextBox has focus.
const function SetCaretColumn(Item: Item, Column: number)
	const Input = Item.Input

	if Input then
		Input.CursorPosition = math.max(Column, 0) + 1
	end
end

-- The line edit with keyboard focus, or nil.
const function GetFocusOwner(): Item?
	return FocusOwner
end

return {
	Build = Build,
	Draw = Draw,
	GetCaretColumn = GetCaretColumn,
	SetCaretColumn = SetCaretColumn,
	GetFocusOwner = GetFocusOwner,
}
