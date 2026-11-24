--!strict
--!optimize 2

--[[
	The option popup (scripts/ui/OptionPopup.cs and res://prefabs/option_popup.tscn), built from Roblox Instances under the
	main scene's root: a dimmed background, a 300 pixel panel with an uppercase header, a BBCode info text, and a row of option
	buttons. Show fades it in or out (0.1 seconds); Escape and a press on the background hide it.

	Design Notes
		Create names the popup from its header and parents it under Built.Root, above the settings menu and the scene. Its
		panel is the holder expanded by 8 pixels (the scene's StyleBox expand margins), and the holder is centered in the screen.
		The rows are VBox children with separation 8: header, info, buttons. The button row is an HBox with equal cells.
		Canceled is a Util/Signal fired when the popup is hidden, as its Godot custom signal is.
		DEVIATION: CallDeferred("add_child") and move_to_front run at once; the popup is above the scene by its ZIndex.
		DEVIATION: Escape is handled without consuming the event (no input is consumed here).
]]

const Input = require("./Input")
const Scale = require("./Scale")
const Items = require("./Item")
const SceneBuilder = require("./SceneBuilder")
const Signal = require("../Util/Signal")
const BBCode = require("./BBCode")
const Buttons = require("./Settings/Buttons")
const Draw = require("./Settings/Draw")
const Fade = require("./Settings/Fade")
const Geometry = require("./Settings/Geometry")
const Look = require("./Settings/Look")
const Motion = require("./Settings/Motion")
const Style = require("./Style")
const Text = require("./SettingsLogic/Text")
const TextField = require("./Settings/TextField")
const Tooltip = require("./Settings/Tooltip")

export type OptionPopup = {
	Item: Frame,
	Shown: boolean,
	Header: string,
	Info: string,
	Viewport: GuiBase2d,
	Overlay: Fade.Fade,
	Holder: Frame,
	Panel: Frame,
	HeaderLabel: TextLabel,
	InfoLabel: TextLabel,
	Field: TextField.TextField?,
	ButtonRow: Frame,
	Buttons: { Buttons.Button },
	Options: { [string]: Buttons.Button },
	Tip: Tooltip.Tooltip,
	Canceled: Signal.Signal<()>,
	Connections: { RBXScriptConnection | (() -> ()) },
}

-- The panel's width (the holder's minimum width), its expansion beyond the holder, and the row separation (VBox 8).
const PanelWidth = 300
const PanelExpand = Look.PopupPanelExpand
const Separation = Look.OptionPopupSeparation

-- The header's size (uppercase, 20) and the text size of the info and the buttons (16).
const HeaderSize = 20
const BodySize = Look.Sizes.Body

-- The fade of Show: 0.1 seconds, TRANS_QUAD with the default EASE_IN_OUT.
const FadeTime = 0.1

-- The height of a text (one line unless it wraps at Width), 0 for an empty text.
const function TextHeight(Value: string, Size: number, Width: number?, Rich: boolean): number
	if Value == "" then
		return 0
	end

	return math.round(Items.Measure(Value, Look.Fonts.Default, Size, Width, Rich).y)
end

-- The alignment of a label of the popup's info text: the first alignment tag of the BBCode, centered by default.
const function AlignmentOf(Alignment: string?): Enum.TextXAlignment
	if Alignment == "left" then
		return Enum.TextXAlignment.Left
	elseif Alignment == "right" then
		return Enum.TextXAlignment.Right
	end

	return Enum.TextXAlignment.Center
end

-- Sets the info text: the BBCode becomes rich text, aligned by its first alignment tag.
const function SetInfo(Popup: OptionPopup, Info: string)
	const Rich, Alignment = BBCode.ToRichText(Info, Style.TextSizeOf(Look.Fonts.Default, 1))

	Popup.Info = Info
	Popup.InfoLabel.Text = Rich
	Popup.InfoLabel.TextXAlignment = AlignmentOf(Alignment)
end

-- Places the panel's rows and the centered holder for the screen's size, and the buttons in their row.
const function Layout(Popup: OptionPopup)
	const Size = Scale.SizeOfViewport(Popup.Viewport)
	const HeaderHeight = TextHeight(string.upper(Popup.Header), HeaderSize, nil, false)
	const InfoHeight = TextHeight(BBCode.ToRichText(Popup.Info, Style.TextSizeOf(Look.Fonts.Default, 1)), BodySize, PanelWidth, true)
	const ButtonCount = #Popup.Buttons
	const ButtonHeight = if ButtonCount > 0 then TextHeight("W", BodySize, nil, false) + 14 else 0
	-- The field is one text line with the LineEdit's 4 pixel top and bottom margins.
	const FieldHeight = if Popup.Field then TextHeight("W", BodySize, nil, false) + 8 else 0
	const InfoTop = HeaderHeight + Separation
	const FieldTop = InfoTop + InfoHeight + Separation
	const ButtonTop = if Popup.Field then FieldTop + FieldHeight + Separation else InfoTop + InfoHeight + Separation
	const Height = ButtonTop + ButtonHeight
	const Left = math.round(Size.x / 2 - PanelWidth / 2)
	const Top = math.round(Size.y / 2 - Height / 2)

	Draw.Place(Popup.Holder, { X = Left, Y = Top, Width = PanelWidth, Height = Height })
	Draw.Place(Popup.Panel, { X = -PanelExpand, Y = -PanelExpand, Width = PanelWidth + 2 * PanelExpand, Height = Height + 2 * PanelExpand })
	Draw.Place(Popup.HeaderLabel, { X = 0, Y = 0, Width = PanelWidth, Height = HeaderHeight })
	Draw.Place(Popup.InfoLabel, { X = 0, Y = InfoTop, Width = PanelWidth, Height = InfoHeight })
	if Popup.Field then
		TextField.Place(Popup.Field, { X = 0, Y = FieldTop, Width = PanelWidth, Height = FieldHeight })
	end

	Draw.Place(Popup.ButtonRow, { X = 0, Y = ButtonTop, Width = PanelWidth, Height = ButtonHeight })

	const Cells = Geometry.ButtonCellsOf(PanelWidth, ButtonCount)

	for Index, Button in Popup.Buttons do
		const Cell = Cells[Index]

		Buttons.Place(Button, { X = Cell.X, Y = 0, Width = Cell.Width, Height = ButtonHeight })
	end
end

-- Shows or hides the popup: a hide runs Canceled, and the popup is hidden when the fade ends.
-- @src scripts/ui/OptionPopup.cs:Show L91-114
const function Show(Popup: OptionPopup, Visible: boolean?)
	const Shown = Visible ~= false

	Popup.Shown = Shown

	if Shown then
		Popup.Item.Visible = true
		Input.PushModal(Popup.Item)
	else
		Signal.Fire(Popup.Canceled)
	end

	Fade.Go(Popup.Overlay, if Shown then 1 else 0, FadeTime, Motion.EaseInOut, function()
		if not Popup.Shown then
			Popup.Item.Visible = false
			Input.PopModal(Popup.Item)
		end
	end)
end

-- @src scripts/ui/OptionPopup.cs:Hide L116-119
const function Hide(Popup: OptionPopup)
	Show(Popup, false)
end

-- Adds an option button: a press hides the popup and runs Callback.
-- @src scripts/ui/OptionPopup.cs:AddOption L74-89
const function AddOption(Popup: OptionPopup, Label: string, Callback: () -> (), Description: Tooltip.TipText?)
	const function PressOption()
		Hide(Popup)
		Callback()
	end
	const Button = Buttons.New(Popup.ButtonRow, {
		Name = Label,
		Rect = { X = 0, Y = 0, Width = 0, Height = 0 },
		ZIndex = 4,
		Style = Look.PopupButton,
		Text = Label,
		Font = Look.Fonts.Default,
		FontSize = BodySize,
		Align = Enum.TextXAlignment.Center,
		Overlay = Popup.Overlay,
		OnActivated = PressOption,
	})

	Tooltip.Attach(Popup.Tip, Button.Object, Description or "")
	table.insert(Popup.Buttons, Button)
	Popup.Options[Label] = Button
	Layout(Popup)
end

-- Adds the popup's copy field: a read-only text field between the info and the buttons, showing Text (the link popup's
-- field). A second call returns the same field with the new text.
-- @src scripts/ui/LinkPopupButton.cs:_EnterTree L14-31
const function AddField(Popup: OptionPopup, Text: string): TextField.TextField
	if not Popup.Field then
		Popup.Field = TextField.New(Popup.Holder, {
			Name = "CopyField",
			Rect = { X = 0, Y = 0, Width = 0, Height = 0 },
			ZIndex = 3,
			Flat = false,
			Editable = false,
			Font = Look.Fonts.Default,
			FontSize = BodySize,
			Placeholder = "",
			MaxLength = 0,
			Overlay = Popup.Overlay,
		})
	end

	const Field = Popup.Field :: TextField.TextField

	TextField.SetText(Field, Text)
	Layout(Popup)

	return Field
end

-- @src scripts/ui/OptionPopup.cs:UpdateHeader L121-125
const function UpdateHeader(Popup: OptionPopup, Header: string)
	Popup.Header = Header
	Popup.HeaderLabel.Text = string.upper(Header)
	Layout(Popup)
end

-- @src scripts/ui/OptionPopup.cs:UpdateInfo L127-131
const function UpdateInfo(Popup: OptionPopup, Info: string)
	SetInfo(Popup, Info)
	Layout(Popup)
end

-- The popup's frames, its state and its input: a full-screen background and a hide button, the centered panel, and Escape.
-- @src scripts/ui/OptionPopup.cs:_Ready L47-58
const function Create(Built: SceneBuilder.Built, Header: string, Info: string): OptionPopup
	const Parent = (Built.Root or error("Aimia UI: the main scene has no root")).Instance
	const Root = Draw.Frame(Parent, Text.PopupName(Header), { X = 0, Y = 0, Width = 0, Height = 0 }, 4, false)

	Root.Size = UDim2.fromScale(1, 1)
	Root.Visible = false

	const Background = Draw.Frame(Root, "Background", { X = 0, Y = 0, Width = 0, Height = 0 }, 1, false)

	Background.Size = UDim2.fromScale(1, 1)
	Draw.Fill(Background, Look.PopupScrim)

	const HideButton = Instance.new("TextButton")

	HideButton.Name = "Hide"
	HideButton.Text = ""
	HideButton.AutoButtonColor = false
	HideButton.BackgroundTransparency = 1
	HideButton.BorderSizePixel = 0
	HideButton.Size = UDim2.fromScale(1, 1)
	HideButton.ZIndex = 1
	HideButton.Active = true
	HideButton.Parent = Root

	const Holder = Draw.Frame(Root, "Holder", { X = 0, Y = 0, Width = 0, Height = 0 }, 2, true)
	const Panel = Draw.Frame(Holder, "Panel", { X = 0, Y = 0, Width = 0, Height = 0 }, 1, false)

	Draw.Fill(Panel, Look.PopupPanelFill)
	Draw.Corner(Panel, Look.Corner)

	const HeaderLabel = Draw.Label(Holder, "Header", { X = 0, Y = 0, Width = 0, Height = 0 }, 3, string.upper(Header), Look.Fonts.Default, HeaderSize, Look.FontWhite, Enum.TextXAlignment.Left)
	const InfoLabel = Draw.Label(Holder, "Info", { X = 0, Y = 0, Width = 0, Height = 0 }, 3, "", Look.Fonts.Default, BodySize, Look.FontWhite, Enum.TextXAlignment.Center)

	InfoLabel.RichText = true
	InfoLabel.TextWrapped = true
	InfoLabel.TextTruncate = Enum.TextTruncate.None
	InfoLabel.TextYAlignment = Enum.TextYAlignment.Top

	const ButtonRow = Draw.Frame(Holder, "Buttons", { X = 0, Y = 0, Width = 0, Height = 0 }, 3, false)
	const Overlay = Fade.New(function() end)

	Fade.Set(Overlay, 0)

	const Popup = {
		Item = Root,
		Shown = false,
		Header = Header,
		Info = Info,
		Viewport = Built.Viewport,
		Overlay = Overlay,
		Holder = Holder,
		Panel = Panel,
		HeaderLabel = HeaderLabel,
		InfoLabel = InfoLabel,
		ButtonRow = ButtonRow,
		Buttons = {},
		Options = {},
		Tip = Tooltip.New(Root, Overlay),
		Canceled = Signal.New(),
		Connections = {},
	} :: OptionPopup

	SetInfo(Popup, Info)

	const function OnHide()
		Hide(Popup)
	end

	table.insert(Popup.Connections, HideButton.MouseButton1Down:Connect(OnHide))
	table.insert(Popup.Connections, HideButton.MouseButton2Down:Connect(OnHide))
	table.insert(Popup.Connections, Built.Viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		Layout(Popup)
	end))

	const function OnScale()
		Layout(Popup)
	end

	Signal.Connect(Scale.Changed, OnScale)
	table.insert(Popup.Connections, function()
		Signal.Disconnect(Scale.Changed, OnScale)
	end)
	table.insert(Popup.Connections, Input.OnInput(function(Event: Input.InputEvent, _: boolean)
		if Popup.Shown and Event.Class == "InputEventKey" and Event.Pressed and Event.Keycode == Input.Key.Escape then
			Hide(Popup)
		end
	end, true))

	Fade.Track(Overlay, Root)
	Layout(Popup)

	return Popup
end

-- Disconnects the popup's input and frees its node.
-- @src scripts/ui/OptionPopup.cs:_ExitTree L1-1
const function Destroy(Popup: OptionPopup)
	for _, Button in Popup.Buttons do
		for _, Connection in Button.Connections do
			Connection:Disconnect()
		end
	end

	Fade.Forget(Popup.Overlay, Popup.Item)

	for _, Link in Popup.Connections do
		if typeof(Link) == "RBXScriptConnection" then
			(Link :: RBXScriptConnection):Disconnect()
		else
			(Link :: () -> ())()
		end
	end

	table.clear(Popup.Connections)
	Input.PopModal(Popup.Item)
	Popup.Item:Destroy()
end

return {
	Create = Create,
	Show = Show,
	Hide = Hide,
	AddOption = AddOption,
	UpdateHeader = UpdateHeader,
	UpdateInfo = UpdateInfo,
	AddField = AddField,
	Destroy = Destroy,
}
