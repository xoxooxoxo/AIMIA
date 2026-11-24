--!strict
--!optimize 2

--[[
	Godot input for the UI ports, from UserInputService: _Input and _UnhandledInput as Godot-shaped events
	(InputEventKey, InputEventMouseButton, InputEventMouseMotion), the global key events for KeybindsManager, Input.MouseMode
	and the mouse position.

	Paradigm
		An event is a table with Godot's property names: Class, Pressed, Echo, Keycode and PhysicalKeycode (Godot Key
		names as strings: Key.Escape is "Escape", the keypad Enter is "KpEnter"), ButtonIndex (MouseButton numbers),
		Position (vector), and the CtrlPressed, AltPressed, ShiftPressed and MetaPressed modifiers at the time of the event.
		KeyEvents is a Util/Signal fired with the InputEventKey of every key press and release, whether or not the GUI
		consumed it (Godot's _Input, which KeybindsManager uses). The bootstrap connects KeybindsManager.HandleKey to it;
		this module does not require KeybindsManager.
		OnInput's callback gets the Processed flag: _UnhandledInput is the callback that ignores Processed events.
		Modal layers (PushModal, PopModal) block the scene: its OnInput callbacks get no keys, buttons or wheel while a
		modal is shown (Modal true opts a callback out), and Blocked(Gui) tells a control that it is under the modal.

	Design Notes
		Godot key names are the C# Key enum names. The names used by the repository (Escape, Space, F1, F2, F11, O, M,
		Enter, KpEnter, Quoteleft, Ctrl) are confirmed by the upstream sources; the rest follow the same constants (KEY_*)
		and are unverified against the engine, which is not in reference/engine. A Roblox KeyCode with no Godot key
		(Unknown, Clear, KeypadEquals) gives Keycode nil.
		A mouse wheel tick arrives as a press and a release, as Godot sends it.
		DEVIATION: Xbutton1 and Xbutton2 (side buttons) have no Roblox UserInputType and never arrive.
		DEVIATION: the media keys (Mediaplay, Medianext, Mediaprevious) have no Roblox KeyCode and never arrive.
		Checked in Studio (2026-11-08): UserInputService:GetMouseLocation is in window pixels, while AbsolutePosition and an
		InputObject's Position are below the top bar's inset (GuiService:GetGuiInset, 58 pixels; the root, which ignores the
		inset, is at (0, -58)). GetMousePosition is the window's (Nodes' global positions, relative to the root);
		GetGuiMousePosition is AbsolutePosition's, for a control that compares the pointer with Scale.PositionOf (scroll bars,
		the dropdown's wheel, the tooltip). Both, and the events' positions, are in layout pixels (UI/Scale).
		Not in the source (smoothness): a mouse motion event takes the modifiers as they were at the last key press or release or
		focus change (Held), which is what IsKeyDown answers then; button, wheel and key events still ask the engine. A 1000 Hz
		mouse sends thousands of motion events a second, and each asked IsKeyDown 8 times for every subscriber. Nothing is built
		for motion while the host is shut (Deliver would drop it).
]]

const UserInputService = game:GetService("UserInputService")
const GuiService = game:GetService("GuiService")

const Scale = require("./Scale")
const Signal = require("../Util/Signal")

export type InputEvent = {
	Class: string,
	Pressed: boolean,
	Echo: boolean,
	Keycode: string?,
	PhysicalKeycode: string?,
	ButtonIndex: number?,
	Position: vector,
	CtrlPressed: boolean,
	AltPressed: boolean,
	ShiftPressed: boolean,
	MetaPressed: boolean,
}

const Key = {
	Escape = "Escape",
	Space = "Space",
	Enter = "Enter",
	KpEnter = "KpEnter",
	Up = "Up",
	Down = "Down",
	Ctrl = "Ctrl",
	Alt = "Alt",
	Shift = "Shift",
	Meta = "Meta",
	F1 = "F1",
	F2 = "F2",
	F11 = "F11",
	O = "O",
	M = "M",
	Quoteleft = "Quoteleft",
}

const MouseButton = {
	Left = 1,
	Right = 2,
	Middle = 3,
	WheelUp = 4,
	WheelDown = 5,
	WheelLeft = 6,
	WheelRight = 7,
	Xbutton1 = 8,
	Xbutton2 = 9,
}

-- Roblox KeyCode names to Godot key names. A Roblox name not listed is the same Godot key (letters, F-keys, Escape,
-- Space, Tab, Backspace, Delete, Insert, Home, End, PageUp, PageDown, Pause, Up, Down, Left, Right, Menu).
-- Roblox names with no Godot key map to nil.
const GodotKeyNames = {
	["Return"] = "Enter",
	["KeypadEnter"] = "KpEnter",
	["KeypadPeriod"] = "KpPeriod",
	["KeypadDivide"] = "KpDivide",
	["KeypadMultiply"] = "KpMultiply",
	["KeypadMinus"] = "KpSubtract",
	["KeypadPlus"] = "KpAdd",
	["KeypadZero"] = "Kp0",
	["KeypadOne"] = "Kp1",
	["KeypadTwo"] = "Kp2",
	["KeypadThree"] = "Kp3",
	["KeypadFour"] = "Kp4",
	["KeypadFive"] = "Kp5",
	["KeypadSix"] = "Kp6",
	["KeypadSeven"] = "Kp7",
	["KeypadEight"] = "Kp8",
	["KeypadNine"] = "Kp9",
	["Zero"] = "Key0",
	["One"] = "Key1",
	["Two"] = "Key2",
	["Three"] = "Key3",
	["Four"] = "Key4",
	["Five"] = "Key5",
	["Six"] = "Key6",
	["Seven"] = "Key7",
	["Eight"] = "Key8",
	["Nine"] = "Key9",
	["QuotedDbl"] = "Quotedbl",
	["Hash"] = "Numbersign",
	["Dollar"] = "Dollar",
	["Percent"] = "Percent",
	["Ampersand"] = "Ampersand",
	["Quote"] = "Apostrophe",
	["LeftParenthesis"] = "Parenleft",
	["RightParenthesis"] = "Parenright",
	["Asterisk"] = "Asterisk",
	["Plus"] = "Plus",
	["Comma"] = "Comma",
	["Minus"] = "Minus",
	["Period"] = "Period",
	["Slash"] = "Slash",
	["Colon"] = "Colon",
	["Semicolon"] = "Semicolon",
	["LessThan"] = "Less",
	["Equals"] = "Equal",
	["GreaterThan"] = "Greater",
	["Question"] = "Question",
	["At"] = "At",
	["LeftBracket"] = "Bracketleft",
	["BackSlash"] = "Backslash",
	["RightBracket"] = "Bracketright",
	["Caret"] = "Asciicircum",
	["Underscore"] = "Underscore",
	["Backquote"] = "Quoteleft",
	["LeftShift"] = "Shift",
	["RightShift"] = "Shift",
	["LeftControl"] = "Ctrl",
	["RightControl"] = "Ctrl",
	["LeftAlt"] = "Alt",
	["RightAlt"] = "Alt",
	["LeftMeta"] = "Meta",
	["RightMeta"] = "Meta",
	["LeftSuper"] = "Meta",
	["RightSuper"] = "Meta",
	["CapsLock"] = "Capslock",
	["NumLock"] = "Numlock",
	["ScrollLock"] = "Scrolllock",
}

-- Roblox KeyCode names with no Godot key.
const NoGodotKeys = {
	["Unknown"] = true,
	["Clear"] = true,
	["KeypadEquals"] = true,
}

-- Connected by the bootstrap to KeybindsManager.HandleKey (Godot's _Input for the global shortcuts).
const KeyEvents: Signal.Signal<InputEvent> = Signal.New()

-- The Godot key name of a Roblox KeyCode, or nil when Godot has none.
const function GodotKeyName(Code: Enum.KeyCode): string?
	const Name = Code.Name

	if (NoGodotKeys :: { [string]: boolean })[Name] then
		return nil
	end

	return (GodotKeyNames :: { [string]: string })[Name] or Name
end

const function Modifier(Code: Enum.KeyCode, Other: Enum.KeyCode): boolean
	return UserInputService:IsKeyDown(Code) or UserInputService:IsKeyDown(Other)
end

const function NewEvent(Class: string, Pressed: boolean, Position: vector): InputEvent
	return {
		Class = Class,
		Pressed = Pressed,
		Echo = false,
		Keycode = nil,
		PhysicalKeycode = nil,
		ButtonIndex = nil,
		Position = Position,
		CtrlPressed = Modifier(Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl),
		AltPressed = Modifier(Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt),
		ShiftPressed = Modifier(Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift),
		MetaPressed = Modifier(Enum.KeyCode.LeftMeta, Enum.KeyCode.RightMeta),
	}
end

-- The modifiers held as of the last key press or release or focus change (read again then, below): mouse motion's.
const Held = { Ctrl = false, Alt = false, Shift = false, Meta = false }

const function ReadHeld()
	Held.Ctrl = Modifier(Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl)
	Held.Alt = Modifier(Enum.KeyCode.LeftAlt, Enum.KeyCode.RightAlt)
	Held.Shift = Modifier(Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)
	Held.Meta = Modifier(Enum.KeyCode.LeftMeta, Enum.KeyCode.RightMeta)
end

-- A mouse motion event at Position, with the held modifiers.
const function NewMotion(Position: vector): InputEvent
	return {
		Class = "InputEventMouseMotion",
		Pressed = false,
		Echo = false,
		Keycode = nil,
		PhysicalKeycode = nil,
		ButtonIndex = nil,
		Position = Position,
		CtrlPressed = Held.Ctrl,
		AltPressed = Held.Alt,
		ShiftPressed = Held.Shift,
		MetaPressed = Held.Meta,
	}
end

const function PositionOf(Input: InputObject): vector
	return Scale.ToLayout(vector.create(Input.Position.X, Input.Position.Y, 0))
end

-- The Godot event of a key or mouse button press or release, or nil for other input. A key while a TextBox has focus is
-- the text's (Godot's LineEdit takes it in gui_input), so it is nil: no shortcut or KeyEvents sees it.
const function ButtonEvent(Input: InputObject, Pressed: boolean): InputEvent?
	if Input.UserInputType == Enum.UserInputType.Keyboard then
		if UserInputService:GetFocusedTextBox() or game:GetService("TextChatService").ChatInputBarConfiguration.IsFocused then
			return nil
		end

		const Result = NewEvent("InputEventKey", Pressed, vector.zero)
		const Name = GodotKeyName(Input.KeyCode)

		Result.Keycode = Name
		Result.PhysicalKeycode = Name

		return Result
	elseif Input.UserInputType == Enum.UserInputType.MouseButton1 then
		const Result = NewEvent("InputEventMouseButton", Pressed, PositionOf(Input))

		Result.ButtonIndex = MouseButton.Left

		return Result
	elseif Input.UserInputType == Enum.UserInputType.MouseButton2 then
		const Result = NewEvent("InputEventMouseButton", Pressed, PositionOf(Input))

		Result.ButtonIndex = MouseButton.Right

		return Result
	elseif Input.UserInputType == Enum.UserInputType.MouseButton3 then
		const Result = NewEvent("InputEventMouseButton", Pressed, PositionOf(Input))

		Result.ButtonIndex = MouseButton.Middle

		return Result
	end

	return nil
end

-- The Godot event of an InputObject as a control receives it (gui_input): presses and releases, motion, and a wheel
-- tick as one press. Nil for other input.
const function FromInputObject(Input: InputObject): InputEvent?
	if Input.UserInputType == Enum.UserInputType.MouseMovement then
		return NewMotion(PositionOf(Input))
	elseif Input.UserInputType == Enum.UserInputType.MouseWheel then
		const Wheel = NewEvent("InputEventMouseButton", true, PositionOf(Input))

		Wheel.ButtonIndex = if Input.Position.Z > 0 then MouseButton.WheelUp else MouseButton.WheelDown

		return Wheel
	end

	return ButtonEvent(Input, Input.UserInputState == Enum.UserInputState.Begin)
end

-- While the game is closed (the host's Open is false) it hears nothing: its menus stay loaded behind the world, and a key
-- press reaching them would, say, focus the hidden search box and take the keyboard from the player.
const Host = { Open = true }

-- Every key press and release goes to KeyEvents, whether or not the GUI consumed it.
UserInputService.InputBegan:Connect(function(Raw: InputObject)
	if Host.Open and Raw.UserInputType == Enum.UserInputType.Keyboard then
		const Result = ButtonEvent(Raw, true)

		if Result then
			Signal.Fire(KeyEvents, Result)
		end
	end
end)

UserInputService.InputEnded:Connect(function(Raw: InputObject)
	if Host.Open and Raw.UserInputType == Enum.UserInputType.Keyboard then
		const Result = ButtonEvent(Raw, false)

		if Result then
			Signal.Fire(KeyEvents, Result)
		end
	end
end)

-- (the held modifiers are read again on every key press and release, open or shut, and when the window gains or loses focus:
-- a key let go of in another window sends no release)
ReadHeld()

UserInputService.InputBegan:Connect(function(Raw: InputObject)
	if Raw.UserInputType == Enum.UserInputType.Keyboard then
		ReadHeld()
	end
end)

UserInputService.InputEnded:Connect(function(Raw: InputObject)
	if Raw.UserInputType == Enum.UserInputType.Keyboard then
		ReadHeld()
	end
end)

UserInputService.WindowFocused:Connect(ReadHeld)
UserInputService.WindowFocusReleased:Connect(ReadHeld)

-- The modal layers, bottom to top. While one is shown, the scene under it gets no pointer hover or press, no wheel and
-- no OnInput callbacks (see OnInput), and the controls under it lose their hover and press (ModalChanged).
const Modals: { GuiObject } = {}

-- Fired after a modal is pushed or popped (the controls under the new state reset their hover and press).
const ModalChanged: Signal.Signal<...unknown> = Signal.New()

-- The shown layers that take only the pointer (PushModal's KeysPass): the scene under one still gets the keys.
const PointerOnly: { [GuiObject]: boolean } = {}

-- Shows Layer as the top modal (a layer already shown stays where it is). KeysPass true makes it a pointer-only layer, for
-- a panel with no text box (the owner panel): while it is the top modal, the scene's OnInput callbacks still get the keys,
-- so the menu's shortcuts and typing keep working with the mouse resting on it.
const function PushModal(Layer: GuiObject, KeysPass: boolean?)
	if table.find(Modals, Layer) then
		return
	end

	PointerOnly[Layer] = if KeysPass == true then true else nil
	table.insert(Modals, Layer)
	Signal.Fire(ModalChanged)
end

-- Removes Layer from the modals (a hidden or destroyed layer; nothing when it is not shown).
const function PopModal(Layer: GuiObject)
	const Index = table.find(Modals, Layer)

	if Index then
		table.remove(Modals, Index)
		PointerOnly[Layer] = nil
		Signal.Fire(ModalChanged)
	end
end

const function ModalActive(): boolean
	return #Modals > 0
end

const function IsTopModal(Layer: GuiObject): boolean
	return Modals[#Modals] == Layer
end

-- Whether the top modal is a pointer-only layer (PushModal's KeysPass).
const function TopIsPointerOnly(): boolean
	const Top: GuiObject? = Modals[#Modals]

	return Top ~= nil and PointerOnly[Top] == true
end

-- Whether the top modal blocks a GUI object: a modal is shown and the object is neither it nor inside it. GuiObject
-- events do not show this (a GuiObject's MouseEnter and MouseLeave are not sunk by an Active object above it), so
-- the controls check it wherever they take hover, press or wheel.
const function Blocked(Gui: GuiObject): boolean
	const Top: GuiObject? = Modals[#Modals]

	return Top ~= nil and Gui ~= Top and not Gui:IsDescendantOf(Top)
end

-- Whether a pointer-only top modal blocks a GUI object (Blocked, for that kind of layer only). A list that keeps its own
-- hover (Spectate's and Leaderboards' cards) goes on following the pointer under such a layer and shows no hover while the
-- layer has the pointer, so a card lights again the moment the pointer comes off the layer onto it.
const function PointerTaken(Gui: GuiObject): boolean
	return TopIsPointerOnly() and Blocked(Gui)
end

-- Whether the pointer is over a GUI object that is visible: inside its rectangle, with every GuiObject above it visible.
-- A control a modal released uses it to take its hover back (the engine sends no MouseEnter to a pointer it already has).
const function PointerOver(Gui: GuiObject): boolean
	-- (in AbsolutePosition's space: the window position less the top bar's inset)
	const Pointer = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
	const Origin = Gui.AbsolutePosition
	const Size = Gui.AbsoluteSize

	if Pointer.X < Origin.X or Pointer.X >= Origin.X + Size.X or Pointer.Y < Origin.Y or Pointer.Y >= Origin.Y + Size.Y then
		return false
	end

	local Current: Instance? = Gui

	while Current do
		if Current:IsA("GuiObject") and not Current.Visible then
			return false
		end

		Current = Current.Parent
	end

	return true
end

-- Connects Callback(Event, Processed) to the input as Godot's _Input; Processed is the GUI flag, so _UnhandledInput
-- is a callback that ignores Processed events. While a modal is shown, a scene callback gets no keys, mouse buttons
-- or wheel ticks (keys still come under a pointer-only layer: PushModal's KeysPass); Modal true marks the modal's own
-- callbacks, which keep getting them. Pointer motion always comes
-- through (the menu cursor follows the pointer). Answers the function that disconnects everything.
const function OnInput(Callback: (InputEvent, boolean) -> (), Modal: boolean?): () -> ()
	const Gated = Modal ~= true

	const function Deliver(Event: InputEvent, Processed: boolean)
		if not Host.Open then
			return
		end

		if Gated and Event.Class ~= "InputEventMouseMotion" and ModalActive() and not (Event.Class == "InputEventKey" and TopIsPointerOnly()) then
			return
		end

		Callback(Event, Processed)
	end

	const Began = UserInputService.InputBegan:Connect(function(Raw: InputObject, Processed: boolean)
		const Result = ButtonEvent(Raw, true)

		if Result then
			Deliver(Result, Processed)
		end
	end)
	const Ended = UserInputService.InputEnded:Connect(function(Raw: InputObject, Processed: boolean)
		const Result = ButtonEvent(Raw, false)

		if Result then
			Deliver(Result, Processed)
		end
	end)
	const Changed = UserInputService.InputChanged:Connect(function(Raw: InputObject, Processed: boolean)
		if Raw.UserInputType == Enum.UserInputType.MouseWheel then
			const Button = if Raw.Position.Z > 0 then MouseButton.WheelUp else MouseButton.WheelDown
			const Wheel = NewEvent("InputEventMouseButton", true, PositionOf(Raw))
			const Release = NewEvent("InputEventMouseButton", false, PositionOf(Raw))

			Wheel.ButtonIndex = Button
			Release.ButtonIndex = Button
			Deliver(Wheel, Processed)
			Deliver(Release, Processed)
		elseif Raw.UserInputType == Enum.UserInputType.MouseMovement and Host.Open then
			Deliver(NewMotion(PositionOf(Raw)), Processed)
		end
	end)

	return function()
		Began:Disconnect()
		Ended:Disconnect()
		Changed:Disconnect()
	end
end

const function SetMouseMode(Mode: string)
	-- (while the host is shut the mouse is its own: a scene finishing late doesn't hide it)
	if Host.Open then
		UserInputService.MouseIconEnabled = Mode == "Visible"
	end
end

const function GetMouseMode(): string
	return if UserInputService.MouseIconEnabled then "Visible" else "Hidden"
end

-- The mouse position in layout pixels, from the window's top left (Nodes' global positions, relative to the root).
const function GetMousePosition(): vector
	const Location = UserInputService:GetMouseLocation()

	return Scale.ToLayout(vector.create(Location.X, Location.Y, 0))
end

-- The mouse position in layout pixels in Scale.PositionOf's space (AbsolutePosition, below the top bar's inset): what a
-- control compares with its own position.
const function GetGuiMousePosition(): vector
	const Location = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()

	return Scale.ToLayout(vector.create(Location.X, Location.Y, 0))
end

return {
	Key = Key,
	MouseButton = MouseButton,
	KeyEvents = KeyEvents,
	GodotKeyName = GodotKeyName,
	OnInput = OnInput,
	ModalChanged = ModalChanged,
	PushModal = PushModal,
	PopModal = PopModal,
	ModalActive = ModalActive,
	IsTopModal = IsTopModal,
	TopIsPointerOnly = TopIsPointerOnly,
	Blocked = Blocked,
	PointerTaken = PointerTaken,
	PointerOver = PointerOver,
	FromInputObject = FromInputObject,
	SetMouseMode = SetMouseMode,
	GetMouseMode = GetMouseMode,
	GetMousePosition = GetMousePosition,
	GetGuiMousePosition = GetGuiMousePosition,
	Host = Host,
}
