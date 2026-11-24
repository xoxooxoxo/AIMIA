--!strict
--!optimize 2

--[[
	The settings menu (scripts/ui/SettingsMenu.cs), built from Roblox Instances under the main scene: a dimmed screen, a
	holder with a header (the title, the profile list, the create-profile field and the delete button), a sidebar of sections, and one scroll
	area per section of setting rows. SceneManager mounts it with New.

	Paradigm
		New(Built) builds the menu once and keeps it in Module.Instance (SettingsMenu.Instance upstream). The other functions
		take the menu as their first argument. Layout (UI/Settings/Geometry) follows the screen's size, and the fade
		(UI/Settings/Fade) drives every visual's transparency and the holder's slide from one value.

	Design Notes
		Rows bind to their SettingsItem as before: a control's change calls SetVariant when the value differs, and the item's
		Updated signal refreshes the control without signalling it (Godot's no-signal forms).
		ShowMenu and HideMenu fade; SettingsManager.Menu.Hide and the hooks HideSettingsMenu and ShowSettingsMenu are Godot's
		Visible toggles, as the source calls them.
		The holder's slide is a fade of its own (Slide): a show snaps it 25 pixels down and slides it up while the alpha fades
		in, as upstream does, and a hide slides it down from where it is.
		DEVIATION: the file dialogs (Import Nightly Settings, Set User Folder Path) open nothing: a file dialog has no Roblox
		equivalent, and the nightly folder is an OS path.
		DEVIATION(platform): the restart prompt of SettingsManager.SetUserFolder offers Cancel only: restarting the process
		and copying the user folder have no Roblox equivalent. The prompt keeps its text.
		The category fade of the sidebar is not upstream: a category switch is instant, as in SelectCategory.
		Not in the source (2026-11-10, the owner's ask): a search field in the header. What is typed is looked for in each
		setting's title, description and button names and in its section's name; Relayout shows only the rows that match, closed
		up with no gaps, and the section shown moves to the first one with a match. Hiding the menu clears it.
]]

const UserInputService = game:GetService("UserInputService")

const Constants = require("../Constants")
const Scale = require("./Scale")
const FileSystem = require("../Util/FileSystem")
const DotnetString = require("../Dotnet/String")
const GodotString = require("../Godot/String")
const Images = require("./Images")
const Style = require("./Style")
const Input = require("./Input")
const Logger = require("../Util/Logger")
const Notify = require("../Util/Notify")
const OptionPopup = require("./OptionPopup")
const SceneBuilder = require("./SceneBuilder")
const Signal = require("../Util/Signal")
const SettingsManager = require("../SettingsManager")
const SettingsItem = require("../Database/Settings/SettingsItem")
const SettingsProfile = require("../Database/Settings/SettingsProfile")
const SettingsSection = require("../Database/Settings/SettingsSection")
const Buttons = require("./Settings/Buttons")
const Controls = require("./SettingsLogic/Controls")
const Dropdown = require("./Settings/Dropdown")
const Draw = require("./Settings/Draw")
const Fade = require("./Settings/Fade")
const Geometry = require("./Settings/Geometry")
const Look = require("./Settings/Look")
const Motion = require("./Settings/Motion")
const ScrollArea = require("./Settings/ScrollArea")
const Slider = require("./Settings/Slider")
const Text = require("./SettingsLogic/Text")
const TextField = require("./Settings/TextField")
const Tooltip = require("./Settings/Tooltip")
const SettingsPreview = require("./SettingsPreview")
const Credits = require("./Settings/Credits")

type SettingItem = SettingsItem.SettingsItem<unknown>

-- The slider bounds of a setting (SettingsSlider's fields).
type SliderBounds = { Step: number, MinValue: number, MaxValue: number, Log: boolean? }

-- The entries of a setting's List, read through the list object (its Values can be replaced by an import).
type ChoiceList = { Values: { unknown }, SelectedValue: unknown }

-- A SettingsButton row (Title, Description and the action).
type ButtonEntry = { Title: string, Description: string, OnPressed: (() -> ())? }

-- A setting row: its controls (the ones its type shows) and its place in the category.
export type Row = {
	Setting: SettingItem,
	Frame: Frame,
	Title: TextButton,
	Slider: Slider.Slider?,
	SliderEdit: TextField.TextField?,
	TextEdit: TextField.TextField?,
	Toggle: Buttons.Toggle?,
	Option: Dropdown.Dropdown?,
	Buttons: { Buttons.Button },
}

-- A section: its sidebar button and highlight, and its scroll area of rows (the CREDITS tab: of its text, with no rows).
export type Category = {
	Name: string,
	Index: number,
	Area: ScrollArea.ScrollArea,
	Rows: { Row },
	SidebarRow: Frame,
	SidebarButton: Buttons.Button,
	Credits: Credits.Page?,
	-- how many of its rows the search shows (every row when nothing is searched)
	Found: number?,
}

export type SettingsMenu = {
	Item: Frame,
	Viewport: GuiBase2d,
	Built: SceneBuilder.Built,
	Shown: boolean,
	Overlay: Fade.Fade,
	Slide: Fade.Fade,
	Rest: { X: number, Y: number },
	HideButton: TextButton,
	Holder: Frame,
	Dim: Frame,
	DimSeparator: Frame,
	Header: Frame,
	Title: TextLabel,
	ProfilesDropdown: Dropdown.Dropdown,
	CreateProfile: Buttons.Button,
	CreateIcon: ImageLabel,
	DeleteProfile: Buttons.Button,
	DeleteIcon: ImageLabel,
	ProfileEdit: TextField.TextField,
	-- the search: its field, what is searched (lower case, trimmed; "" for nothing), and the line shown when nothing matches
	SearchEdit: TextField.TextField,
	Search: string,
	SearchTyped: string,
	Empty: TextLabel,
	Question: OptionPopup.OptionPopup?,
	Outline: Frame,
	Sidebar: ScrollArea.ScrollArea,
	Categories: { Category },
	SelectedCategory: Category?,
	SettingPanels: { [string]: Row },
	Dropdowns: { Dropdown.Dropdown },
	Tooltip: Tooltip.Tooltip,
	Connections: { RBXScriptConnection | (() -> ()) },
}

export type SettingsMenuModule = {
	Instance: SettingsMenu?,
	New: (Built: SceneBuilder.Built) -> (),
	Destroy: (Menu: SettingsMenu) -> (),
	ShowMenu: (Menu: SettingsMenu, Show: boolean?) -> (),
	HideMenu: (Menu: SettingsMenu) -> (),
	SelectCategory: (Menu: SettingsMenu, Category: Category) -> (),
	UpdateProfileSelection: (Menu: SettingsMenu) -> (),
	RefreshList: (Menu: SettingsMenu, Setting: SettingItem) -> (),
}

-- The holder's offset while the menu is hidden (it slides up to its rest position when shown), in pixels.
const HiddenOffset = 25

-- The show and hide fades (Godot's tweens of 0.25 seconds, TRANS_QUAD with EASE_OUT).
const FadeTime = 0.25

-- A zero rectangle, for controls that the layout places.
const Zero = { X = 0, Y = 0, Width = 0, Height = 0 }

-- The menu table; Instance is the menu set by New (SettingsMenu.Instance upstream).
const Module = {} :: SettingsMenuModule

-- The holder's slide for a fade alpha: HiddenOffset at 0, none at 1.
const function Slide(Alpha: number): number
	return math.round(HiddenOffset * (1 - Alpha))
end

-- Moves the holder to its rest position, pushed down by the slide of the fade's alpha.
const function MoveHolder(Holder: Frame, Rest: { X: number, Y: number }, Alpha: number)
	Holder.Position = UDim2.fromOffset(Rest.X, Rest.Y + Slide(Alpha))
end

-- Places a setting row's controls for a row of Width, at its place (Index) in the category's content.
const function PlaceRow(Row: Row, Index: number, Width: number)
	const Rects = Geometry.RowControlsOf(Width)

	Draw.Place(Row.Frame, { X = 0, Y = Geometry.RowTop(Index), Width = Width, Height = Geometry.RowHeight })
	Draw.Place(Row.Title, Rects.Title)

	if Row.Slider then
		Slider.Place(Row.Slider, Rects.Slider)
	end

	if Row.SliderEdit then
		TextField.Place(Row.SliderEdit, Rects.SliderEdit)
	end

	if Row.TextEdit then
		TextField.Place(Row.TextEdit, Rects.TextEdit)
	end

	if Row.Toggle then
		Buttons.PlaceToggle(Row.Toggle, Rects.Toggle)
	end

	if Row.Option then
		Dropdown.Place(Row.Option, Rects.Option)
	end

	const Cells = Geometry.ButtonCellsOf(Rects.ButtonRow.Width, #Row.Buttons)

	for CellIndex, Button in Row.Buttons do
		const Cell = Cells[CellIndex]

		Buttons.Place(Button, { X = Rects.ButtonRow.X + Cell.X, Y = Rects.ButtonRow.Y, Width = Cell.Width, Height = Rects.ButtonRow.Height })
	end
end

-- Whether the search shows a row: nothing searched, or the words are in its title, its description, a button of its, or
-- its section's name.
const function Matches(Search: string, Category: Category, Row: Row): boolean
	if Search == "" then
		return true
	end

	const Setting = Row.Setting

	if string.find(string.lower(Setting.Title), Search, 1, true) or string.find(string.lower(Setting.Description), Search, 1, true) then
		return true
	end

	if string.find(string.lower(Category.Name), Search, 1, true) then
		return true
	end

	const Entries = if Setting.Type == "Variant" then (Setting :: any).Buttons else nil

	if type(Entries) == "table" then
		for _, Entry in Entries do
			if type(Entry) == "table" and type(Entry.Title) == "string" and string.find(string.lower(Entry.Title), Search, 1, true) then
				return true
			end
		end
	end

	return false
end

-- The line under the header when the section shown has nothing the search matches.
const function UpdateEmpty(Menu: SettingsMenu)
	const Selected = Menu.SelectedCategory
	const Nothing = Menu.Search ~= "" and Selected ~= nil and Selected.Credits == nil and (Selected.Found or 0) == 0

	if Nothing and Selected then
		local Any = false

		for _, Category in Menu.Categories do
			if (Category.Found or 0) > 0 then
				Any = true
			end
		end

		Menu.Empty.Text = if Any then `Nothing in {Selected.Name} matches "{Menu.SearchTyped}"` else `No setting matches "{Menu.SearchTyped}"`
	end

	Menu.Empty.Visible = Nothing
end

-- Lays out the whole menu for the screen's size: the holder and its panels, the sidebar, every category's rows.
const function Relayout(Menu: SettingsMenu)
	const Size = Scale.SizeOfViewport(Menu.Viewport)
	const Holder = Geometry.HolderOf(Size.x, Size.y)
	const Panels = Geometry.PanelsOf(Holder.Width, Holder.Height)

	Menu.Rest.X = Holder.X
	Menu.Rest.Y = Holder.Y
	Menu.Holder.Size = UDim2.fromOffset(Holder.Width, Holder.Height)
	MoveHolder(Menu.Holder, Menu.Rest, Menu.Slide.Alpha)

	Draw.Place(Menu.Dim, Panels.Dim)
	Draw.Place(Menu.DimSeparator, Panels.DimSeparator)
	Draw.Place(Menu.Header, { X = 0, Y = 0, Width = Holder.Width, Height = Geometry.HeaderHeight })
	Draw.Place(Menu.Title, Panels.Title)
	Dropdown.Place(Menu.ProfilesDropdown, Panels.Profiles)
	Buttons.Place(Menu.CreateProfile, Panels.CreateProfile)
	-- (a button's side padding insets its children too, so the icon is moved back by it to sit in the middle)
	Draw.Place(Menu.CreateIcon, {
		X = (Panels.CreateProfile.Width - Look.CreateIconSize) // 2 - Look.ButtonInset,
		Y = (Panels.CreateProfile.Height - Look.CreateIconSize) // 2,
		Width = Look.CreateIconSize,
		Height = Look.CreateIconSize,
	})
	Buttons.Place(Menu.DeleteProfile, Panels.DeleteProfile)
	Draw.Place(Menu.DeleteIcon, {
		X = (Panels.DeleteProfile.Width - Look.CreateIconSize) // 2 - Look.ButtonInset,
		Y = (Panels.DeleteProfile.Height - Look.CreateIconSize) // 2,
		Width = Look.CreateIconSize,
		Height = Look.CreateIconSize,
	})
	TextField.Place(Menu.ProfileEdit, Panels.ProfileEdit)
	TextField.Place(Menu.SearchEdit, Panels.Search)
	Draw.Place(Menu.Empty, { X = Panels.Categories.X + 8, Y = Panels.Categories.Y + 4, Width = math.max(Panels.Categories.Width - 16, 0), Height = Geometry.RowHeight })
	Draw.Place(Menu.Outline, Panels.Outline)

	const SidebarWidth = ScrollArea.Layout(Menu.Sidebar, Panels.Sidebar, #Menu.Categories * Geometry.SidebarRowHeight)

	for _, Category in Menu.Categories do
		Draw.Place(Category.SidebarRow, { X = 0, Y = Geometry.SidebarRowTop(Category.Index), Width = SidebarWidth, Height = Geometry.SidebarRowHeight })
		Buttons.Place(Category.SidebarButton, { X = 0, Y = 0, Width = SidebarWidth, Height = Geometry.SidebarRowHeight })
	end

	for _, Category in Menu.Categories do
		if Category.Credits then
			Credits.Layout(Category.Credits, Panels.Categories)
			-- (its page has no rows to match: it is found by its own name)
			Category.Found = if Menu.Search == "" or string.find(string.lower(Category.Name), Menu.Search, 1, true) then 1 else 0

			continue
		end

		-- (only the rows the search shows, closed up)
		local Found = 0

		for _, Row in Category.Rows do
			if Matches(Menu.Search, Category, Row) then
				Found += 1
			end
		end

		Category.Found = Found

		const Width = ScrollArea.Layout(Category.Area, Panels.Categories, Geometry.ContentHeight(Found))
		local Index = 0

		for _, Row in Category.Rows do
			const Shown = Matches(Menu.Search, Category, Row)

			if Row.Frame.Visible ~= Shown then
				Row.Frame.Visible = Shown
			end

			if Shown then
				PlaceRow(Row, Index, Width)
				Index += 1
			end
		end
	end

	UpdateEmpty(Menu)
end

-- Shows the category (the sidebar highlight and its scroll area) and hides the one shown before.
-- @src scripts/ui/SettingsMenu.cs:SelectCategory L278-290
const function SelectCategory(Menu: SettingsMenu, Category: Category)
	const Previous = Menu.SelectedCategory

	if Previous then
		Fade.SetFrameBase(Menu.Overlay, Previous.SidebarRow, 1)
		ScrollArea.SetVisible(Previous.Area, false)
	end

	Menu.SelectedCategory = Category

	ScrollArea.SetVisible(Category.Area, true)
	Fade.SetFrameBase(Menu.Overlay, Category.SidebarRow, 1 - Look.SidebarSelected.Alpha)
	UpdateEmpty(Menu)
end

-- The search changed: the rows are laid out again, and a section left with nothing moves on to the first one with a match.
const function ApplySearch(Menu: SettingsMenu, Typed: string)
	const Trimmed = DotnetString.Trim(Typed)
	const Search = string.lower(Trimmed)

	if Search == Menu.Search then
		return
	end

	Menu.Search = Search
	Menu.SearchTyped = Trimmed
	Tooltip.Hide(Menu.Tooltip)

	for _, DropdownControl in Menu.Dropdowns do
		if Dropdown.IsOpen(DropdownControl) then
			Dropdown.Close(DropdownControl)
		end
	end

	Relayout(Menu)

	-- (the matches from the top: a section left scrolled down would open on its last ones)
	for _, Category in Menu.Categories do
		if not Category.Credits then
			ScrollArea.Reset(Category.Area)
		end
	end

	const Selected = Menu.SelectedCategory

	if Search ~= "" and (Selected == nil or (Selected.Found or 0) == 0) then
		for _, Category in Menu.Categories do
			if (Category.Found or 0) > 0 then
				SelectCategory(Menu, Category)

				break
			end
		end
	end
end

-- The profile list: the custom profiles of the profiles folder (not "default"), then the current one selected.
-- @src scripts/ui/SettingsMenu.cs:UpdateProfileSelection L292-324
const function UpdateProfileSelection(Menu: SettingsMenu)
	const Profiles = Menu.ProfilesDropdown

	while Dropdown.ItemCount(Profiles) > 1 do
		Dropdown.RemoveItem(Profiles, 1)
	end

	const Current = SettingsManager.GetCurrentProfile()

	for _, File in FileSystem.GetFiles(`{Constants.UserFolder}/profiles`) do
		const Name = GodotString.GetBaseName(GodotString.GetFile(File))

		if Name ~= "default" then
			Dropdown.AddItem(Profiles, Name)
		end
	end

	-- item indices don't always match file order
	for Choice = 0, Dropdown.ItemCount(Profiles) - 1 do
		if Dropdown.ItemText(Profiles, Choice) == Current then
			Dropdown.Select(Profiles, Choice)
		end
	end

	Menu.DeleteProfile.Object.Visible = Current ~= "default"
end

-- Shows a slider value: rounded to three decimals, as its text and as the slider's value (without a signal).
-- @src scripts/ui/SettingsMenu.cs:updateSlider L398-409
const function UpdateSlider(SliderControl: Slider.Slider, Edit: TextField.TextField, Value: number)
	const Rounded = Text.SliderValue(Value)

	TextField.SetText(Edit, Text.DoubleText(Rounded))
	TextField.ReleaseFocus(Edit)
	Slider.SetValueNoSignal(SliderControl, Rounded)
end

-- Shows a text value in the field and releases its focus.
-- @src scripts/ui/SettingsMenu.cs:updateInput L442-450
const function UpdateInput(Edit: TextField.TextField, Value: string)
	TextField.SetText(Edit, Value)
	TextField.ReleaseFocus(Edit)
end

-- Selects an option by index (Godot's select ignores an index past the items).
-- @src scripts/ui/SettingsMenu.cs:updateList L495-498
const function UpdateList(DropdownControl: Dropdown.Dropdown, Index: number)
	Dropdown.Select(DropdownControl, Index)
end

-- The slider's text is applied when the field loses focus or is submitted: an unparsable text keeps the value.
-- @src scripts/ui/SettingsMenu.cs:setupSlider L346-396
const function ApplySliderText(Setting: SettingItem, PlaceholderText: string, Typed: string)
	const Current = SettingsItem.GetVariant(Setting) :: number
	const Value = Text.ParseSliderText(Typed, PlaceholderText, Current)

	-- (the box shows three decimals: leaving it unchanged keeps the value)
	if Text.SliderValue(Current) ~= Value then
		SettingsItem.SetVariant(Setting, Value)
	end

	-- A refused or clamped entry may change nothing, so the box is put right here.
	Signal.Fire(Setting.Updated, Setting.Value)
end

-- The placeholder of a slider's text: the default value of a number setting (0 otherwise), to four decimals.
const function SliderPlaceholderOf(Setting: SettingItem): string
	const Placeholder = if Setting.Type == "double" or Setting.Type == "int" then (Setting.DefaultValue :: number) else 0

	return Text.PlaceholderText(Placeholder)
end

-- The slider and its text field: the slider follows the setting, and the setting's value is shown in the field.
-- @src scripts/ui/SettingsMenu.cs:setupSlider L346-396
const function SetupSlider(Setting: SettingItem, SliderControl: Slider.Slider, Edit: TextField.TextField, Bounds: SliderBounds)
	Slider.Configure(SliderControl, Bounds.MinValue, Bounds.MaxValue, Bounds.Step, Bounds.Log == true)

	Signal.Connect(Setting.Updated, function(Value: unknown)
		UpdateSlider(SliderControl, Edit, Value :: number)
	end)

	UpdateSlider(SliderControl, Edit, SettingsItem.GetVariant(Setting) :: number)
end

-- The text field of a string setting: an empty text applies the placeholder.
-- @src scripts/ui/SettingsMenu.cs:setupInput L411-440
const function ApplyInputText(Setting: SettingItem, Placeholder: string, Typed: string)
	const Value = if Typed == "" then Placeholder else Typed

	if SettingsItem.GetVariant(Setting) ~= Value then
		SettingsItem.SetVariant(Setting, Value)
	end
end

-- The text field shows the setting and follows it.
-- @src scripts/ui/SettingsMenu.cs:setupInput L411-440
const function SetupInput(Setting: SettingItem, Edit: TextField.TextField)
	Signal.Connect(Setting.Updated, function(Value: unknown)
		UpdateInput(Edit, Value :: string)
	end)

	UpdateInput(Edit, SettingsItem.GetVariant(Setting) :: string)
end

-- The option button of a list setting: its items are the list's values, and the value's index follows the setting.
-- @src scripts/ui/SettingsMenu.cs:setupList L452-493
const function SetupList(Setting: SettingItem, DropdownControl: Dropdown.Dropdown)
	const List = Setting.List :: ChoiceList

	for _, Value in List.Values do
		Dropdown.AddItem(DropdownControl, Value :: string)
	end

	const function IndexOfValue(): number
		return Controls.ListIndex(List.Values, List.SelectedValue)
	end

	Signal.Connect(Setting.Updated, function()
		UpdateList(DropdownControl, IndexOfValue())
	end)

	UpdateList(DropdownControl, IndexOfValue())
end

-- The check button shows the setting and follows it.
-- @src scripts/ui/SettingsMenu.cs:setupToggle L326-339
const function SetupToggle(Setting: SettingItem, Toggle: Buttons.Toggle)
	Signal.Connect(Setting.Updated, function(Value: unknown)
		Buttons.SetPressed(Toggle, Value :: boolean)
	end)

	Buttons.SetPressed(Toggle, SettingsItem.GetVariant(Setting) :: boolean)
end

-- A profile's name in a popup's text, which is BBCode.
const function NameForPopup(Profile: string): string
	return (string.gsub(Profile, "%[", "[lb]"))
end

-- Asks before something that can't be undone; Cancel, Escape or a click outside does nothing. The popup is freed after its
-- 0.1 s fade, so asking again leaves nothing behind.
const function Confirm(Menu: SettingsMenu, Heading: string, Body: string, Option: string, OnOption: () -> ())
	const Popup = OptionPopup.Create(Menu.Built, Heading, Body)
	local Closing = false

	OptionPopup.AddOption(Popup, Option, OnOption)
	OptionPopup.AddOption(Popup, "Cancel", function() end)
	Signal.Connect(Popup.Canceled, function()
		if Closing then
			return
		end

		Closing = true

		if Menu.Question == Popup then
			Menu.Question = nil
		end

		task.delay(0.25, OptionPopup.Destroy, Popup)
	end)

	Menu.Question = Popup
	OptionPopup.Show(Popup)
end

-- The restart prompt of SettingsManager.SetUserFolder (scripts/SettingsManager.cs), shown on SettingsManager.UserFolderChanged.
const function ShowRestartPrompt(Built: SceneBuilder.Built)
	const Popup = OptionPopup.Create(Built, "Restart required.", "Would you like to restart the game?")

	-- DEVIATION(platform): "Restart" and "Restart And Copy" need OS.CreateProcess and a folder copy: only Cancel is offered.
	OptionPopup.AddOption(Popup, "Cancel", function() end)
	OptionPopup.Show(Popup)
end

-- Creates a setting row under a category's content: its title, and the controls its type shows (a check button, a slider
-- with its field, a text field, an option button), then its buttons (Variant settings).
-- @src scripts/ui/SettingsMenu.cs:_Ready L156-202
const function BuildRow(Menu: SettingsMenu, Category: Category, Setting: SettingItem, Root: Frame)
	const Frame = Draw.Frame(Category.Area.Content, Setting.Id, Zero, 1, false)
	const Title = Instance.new("TextButton")

	Title.Name = "Title"
	Title.Text = Setting.Title
	Title.FontFace = Look.Fonts.UbuntuRegular
	Title.TextSize = Style.TextSizeOf(Look.Fonts.UbuntuRegular, Look.Sizes.Body)
	Title.TextColor3 = Look.FontWhite.Color
	Title.TextXAlignment = Enum.TextXAlignment.Left
	Title.TextYAlignment = Enum.TextYAlignment.Center
	Title.TextTruncate = Enum.TextTruncate.AtEnd
	Title.AutoButtonColor = false
	Title.BackgroundTransparency = 1
	Title.BorderSizePixel = 0
	Title.ZIndex = 1
	Title.Parent = Frame

	Tooltip.Attach(Menu.Tooltip, Title, Setting.Description)

	const Row = {
		Setting = Setting,
		Frame = Frame,
		Title = Title,
		Buttons = {},
	} :: Row

	if Setting.Type == "bool" then
		const Toggle = Buttons.NewToggle(Frame, "CheckButton", 2, Menu.Overlay, function(Pressed: boolean)
			if SettingsItem.GetVariant(Setting) ~= Pressed then
				SettingsItem.SetVariant(Setting, Pressed)
			end
		end)

		Row.Toggle = Toggle
		SetupToggle(Setting, Toggle)
	elseif Setting.Slider then
		const Bounds = Setting.Slider :: SliderBounds
		const PlaceholderText = SliderPlaceholderOf(Setting)
		const SliderControl = Slider.New(Frame, "Slider", Zero, 2, Menu.Overlay, function(Value: number)
			if SettingsItem.GetVariant(Setting) ~= Value then
				SettingsItem.SetVariant(Setting, Value)
			end
		end)
		const function ApplySliderEntry(Typed: string)
			ApplySliderText(Setting, PlaceholderText, Typed)
		end
		const Edit = TextField.New(Frame, {
			Name = "SliderLineEdit",
			Rect = Zero,
			ZIndex = 2,
			Flat = true,
			Font = Look.Fonts.Default,
			FontSize = Look.Sizes.Body,
			Placeholder = PlaceholderText,
			MaxLength = 5,
			Overlay = Menu.Overlay,
			OnSubmitted = ApplySliderEntry,
			OnFocusExited = ApplySliderEntry,
		})

		Row.Slider = SliderControl
		Row.SliderEdit = Edit
		TextField.SetPlaceholder(Edit, PlaceholderText)
		SetupSlider(Setting, SliderControl, Edit, Bounds)
	elseif Setting.Type == "string" and Setting.List == nil then
		const Placeholder = if Setting.Placeholder ~= "" then Setting.Placeholder else "input"
		const function ApplyInputEntry(Typed: string)
			ApplyInputText(Setting, Placeholder, Typed)
		end
		const Edit = TextField.New(Frame, {
			Name = "LineEdit",
			Rect = Zero,
			ZIndex = 2,
			Flat = true,
			Font = Look.Fonts.Default,
			FontSize = Look.Sizes.Body,
			Placeholder = Placeholder,
			MaxLength = 0,
			Overlay = Menu.Overlay,
			OnSubmitted = ApplyInputEntry,
			OnFocusExited = ApplyInputEntry,
		})

		Row.TextEdit = Edit
		SetupInput(Setting, Edit)
	elseif Setting.List then
		const DropdownControl = Dropdown.New(Frame, "OptionButton", Zero, 2, Menu.Overlay, Root, Look.Fonts.Default, Look.Sizes.Option, function(Index: number)
			const List = Setting.List :: ChoiceList
			const OldValue = SettingsItem.GetVariant(Setting)
			const NewValue = List.Values[Index + 1]

			if OldValue ~= NewValue then
				SettingsItem.SetVariant(Setting, NewValue)
			end
		end)

		Row.Option = DropdownControl
		table.insert(Menu.Dropdowns, DropdownControl)
		SetupList(Setting, DropdownControl)
	end

	if Setting.Type == "Variant" then
		for _, SettingButton in Setting.Buttons do
			const Entry = SettingButton :: ButtonEntry
			local LastPressedAt = 0

			const function PressButton()
				const Now = os.clock() * 1000

				if not Controls.PressAllowed(Now, LastPressedAt) then
					return
				end

				LastPressedAt = Now

				if Entry.OnPressed then
					Entry.OnPressed()
				end
			end

			const Button = Buttons.New(Frame, {
				Name = "Button",
				Rect = Zero,
				ZIndex = 2,
				Style = Look.RowButton,
				Text = Entry.Title,
				Font = Look.Fonts.Default,
				FontSize = Look.Sizes.Body,
				Align = Enum.TextXAlignment.Center,
				Overlay = Menu.Overlay,
				OnActivated = PressButton,
			})

			Tooltip.Attach(Menu.Tooltip, Button.Object, Entry.Description)
			table.insert(Row.Buttons, Button)
		end
	end

	Fade.Track(Menu.Overlay, Frame)
	table.insert(Category.Rows, Row)
	Menu.SettingPanels[Setting.Id] = Row
end

-- Closes the open option lists (a hiding menu closes them; Escape closes one before it closes the menu). Answers
-- whether one was open.
const function CloseLists(Menu: SettingsMenu): boolean
	local Closed = false

	for _, DropdownControl in Menu.Dropdowns do
		if Dropdown.IsOpen(DropdownControl) then
			Dropdown.Close(DropdownControl)

			Closed = true
		end
	end

	return Closed
end

-- The hover and press of every control are cleared when the menu hides: no control stays hovered or pressed under it.
const function ClearPointers()
	Buttons.ResetHover()
	Slider.ResetHover()
	ScrollArea.ResetHover()
end

-- Takes the keyboard focus from the menu's text fields: the ones a modal covers (onlyCovered), or all of them.
const function ReleaseFocus(Menu: SettingsMenu, OnlyCovered: boolean)
	const Fields = { Menu.ProfileEdit, Menu.SearchEdit }

	for _, Row in Menu.SettingPanels do
		if Row.SliderEdit then
			table.insert(Fields, Row.SliderEdit)
		end

		if Row.TextEdit then
			table.insert(Fields, Row.TextEdit)
		end
	end

	for _, Field in Fields do
		if not OnlyCovered or Input.Blocked(Field.Object) then
			TextField.ReleaseFocus(Field)
		end
	end
end

-- The menu is gone once its fade is done: its root hides and its modal is popped (the scene under it is free again).
const function Hidden(Menu: SettingsMenu)
	Menu.Item.Visible = false
	Input.PopModal(Menu.Item)

	-- (the next visit starts with every setting showing; cleared here, once nothing of the menu is on screen)
	if TextField.GetText(Menu.SearchEdit) ~= "" then
		TextField.SetText(Menu.SearchEdit, "")
	end
end

-- ShowMenu: fades the menu in (its holder slides up from HiddenOffset) or out over 0.25 s, then hides it when it is not shown.
-- Input to the hide button follows the shown state at once. The menu is a modal while it is visible, so a hide keeps
-- the scene blocked until the fade is done.
-- @src scripts/ui/SettingsMenu.cs:ShowMenu L245-271
const function ShowMenu(Menu: SettingsMenu, Show: boolean?)
	const Shown = Show ~= false

	Menu.Shown = Shown
	Menu.HideButton.Active = Shown

	if Shown then
		Menu.Item.Visible = true
		Input.PushModal(Menu.Item)

		-- upstream shows the holder 25 pixels down at once, so a show during a hide snaps the slide back to its start.
		Fade.Set(Menu.Slide, 0)
	else
		-- (a question still open goes unanswered)
		if Menu.Question then
			OptionPopup.Hide(Menu.Question)
		end

		Tooltip.Hide(Menu.Tooltip)
		CloseLists(Menu)
		ClearPointers()
		ReleaseFocus(Menu, false)
	end

	Fade.Go(Menu.Slide, if Shown then 1 else 0, FadeTime, Motion.EaseOut, nil)
	Fade.Go(Menu.Overlay, if Shown then 1 else 0, FadeTime, Motion.EaseOut, function()
		if not Menu.Shown then
			Hidden(Menu)
		end
	end)
end

-- @src scripts/ui/SettingsMenu.cs:HideMenu L273-276
const function HideMenu(Menu: SettingsMenu)
	ShowMenu(Menu, false)
end

-- Builds the menu under the main scene's root, with the rows of every section, and installs the SettingsManager.Menu
-- and SettingsProfile hooks that belong to it. SettingsManager.Initialize runs before this.
-- @src scripts/ui/SettingsMenu.cs:_Ready L33-218
function Module.New(Built: SceneBuilder.Built)
	const Parent = (Built.Root or error("Aimia UI: the main scene has no root")).Instance
	const Root = Draw.Frame(Parent, "Settings", Zero, 2, false)
	const Start = os.clock()

	Root.Size = UDim2.fromScale(1, 1)
	Root.Visible = false
	Draw.Fill(Root, Look.ScrimFill)

	const Hide = Instance.new("TextButton")

	Hide.Name = "Hide"
	Hide.Text = ""
	Hide.AutoButtonColor = false
	Hide.BackgroundTransparency = 1
	Hide.BorderSizePixel = 0
	Hide.Size = UDim2.fromScale(1, 1)
	Hide.ZIndex = 1
	Hide.Active = false
	Hide.Parent = Root

	const Holder = Draw.Frame(Root, "Holder", Zero, 2, true)
	const Rest = { X = 0, Y = 0 }

	Draw.Fill(Holder, Look.HolderFill)
	Draw.Corner(Holder, Look.Corner)

	const Overlay = Fade.New(function() end)
	const SlideFade = Fade.New(function(Alpha: number)
		MoveHolder(Holder, Rest, Alpha)
	end)

	Fade.Set(Overlay, 0)
	Fade.Set(SlideFade, 0)

	local Menu: SettingsMenu

	const function IsShown(): boolean
		return Menu.Shown
	end

	const Dim = Draw.Frame(Holder, "Dim", Zero, 1, true)

	Draw.Fill(Dim, Look.PanelFill)
	Draw.Corner(Dim, Look.Corner)

	const DimSeparator = Draw.Frame(Holder, "Separator", Zero, 1, false)

	Draw.Fill(DimSeparator, Look.SeparatorFill)

	const Sidebar = ScrollArea.New(Holder, "Sidebar", 2, Overlay, 0, IsShown)
	const Header = Draw.Frame(Holder, "Header", Zero, 3, true)

	Draw.Fill(Header, Look.PanelFill)
	Draw.Corner(Header, Look.Corner)

	const Title = Draw.Label(Header, "Title", Zero, 4, "SETTINGS", Look.Fonts.Default, Look.Sizes.Header, Look.FontWhite, Enum.TextXAlignment.Left)
	const Tip = Tooltip.New(Root, Overlay)
	const Dropdowns: { Dropdown.Dropdown } = {}

	const ProfilesDropdown = Dropdown.New(Header, "Profiles", Zero, 4, Overlay, Root, Look.Fonts.Default, Look.Sizes.Option, function(Index: number)
		const Profile = Dropdown.ItemText(Menu.ProfilesDropdown, Index)

		if Profile == SettingsManager.GetCurrentProfile() then
			return
		end

		SettingsManager.Save()
		SettingsManager.SetCurrentProfile(Profile)
		SettingsManager.Load()
		-- (a file that can't be read sends them back to default: the label follows)
		UpdateProfileSelection(Menu)
	end)

	table.insert(Dropdowns, ProfilesDropdown)
	Dropdown.AddItem(ProfilesDropdown, "default")

	-- When the name field last gave up its focus. A click on + or the delete button takes the focus first, so that press has
	-- already been answered by the time it lands.
	local LastSubmit = -math.huge

	-- Runs when the name field loses its focus: Enter, a click elsewhere, closing the menu and leaving AIMIA all create the
	-- profile. Escape cancels, an empty field closes, and a refused name stays in the field to be fixed.
	const function SubmitProfile(Typed: string)
		LastSubmit = os.clock()

		const Profile = DotnetString.Trim(Typed)

		if Profile == "" or UserInputService:IsKeyDown(Enum.KeyCode.Escape) then
			TextField.SetText(Menu.ProfileEdit, "")
			TextField.SetVisible(Menu.ProfileEdit, false)

			return
		end

		const Problem = SettingsManager.ProfileProblem(Profile)

		if Problem then
			Notify.Notify(Problem, 1)

			return
		end

		const Folder = `{Constants.UserFolder}/profiles`

		if FileSystem.Exists(`{Folder}/{Profile}.json`) then
			Notify.Notify("You already have a profile with that name", 1)

			return
		end

		if #FileSystem.GetFiles(Folder) >= SettingsManager.MaxProfiles then
			Notify.Notify(`You can have {SettingsManager.MaxProfiles - 1} profiles. Delete one first`, 1)

			return
		end

		TextField.SetText(Menu.ProfileEdit, "")
		TextField.SetVisible(Menu.ProfileEdit, false)

		-- The new file goes before the pointer, so the pointer never names a missing file.
		SettingsManager.Save()
		SettingsManager.Save(Profile)
		SettingsManager.SetCurrentProfile(Profile)
		SettingsManager.Load()

		UpdateProfileSelection(Menu)
	end

	const ProfileEdit = TextField.New(Header, {
		Name = "ProfileEdit",
		Rect = Zero,
		ZIndex = 4,
		Flat = false,
		Font = Look.Fonts.Default,
		FontSize = Look.Sizes.Body,
		Placeholder = "profile name",
		MaxLength = 32,
		Overlay = Overlay,
		OnSubmitted = nil,
		OnFocusExited = SubmitProfile,
	})

	TextField.SetVisible(ProfileEdit, false)
	Tooltip.Attach(Tip, ProfileEdit.Object, "Enter or click away to create. Esc to cancel")

	-- The search field, in the profile name field's look, and the line shown when nothing matches (ApplySearch).
	const SearchEdit = TextField.New(Header, {
		Name = "Search",
		Rect = Zero,
		ZIndex = 4,
		Flat = false,
		Font = Look.Fonts.Default,
		FontSize = Look.Sizes.Body,
		Placeholder = "search settings",
		MaxLength = 40,
		Overlay = Overlay,
		OnSubmitted = nil,
		OnFocusExited = nil,
	})

	Tooltip.Attach(Tip, SearchEdit.Object, "Type part of a setting's name, or of what it does")

	-- (a pink line under it, as under the profile list beside it: on the black header the field's own black box doesn't show)
	const SearchLine = Instance.new("Frame")

	SearchLine.Name = "Underline"
	SearchLine.AnchorPoint = Vector2.new(0, 1)
	SearchLine.Position = UDim2.fromScale(0, 1)
	SearchLine.Size = UDim2.new(1, 0, 0, Look.RowButton.UnderlineWidth)
	SearchLine.BorderSizePixel = 0
	SearchLine.ZIndex = 5
	Draw.Fill(SearchLine, Look.Pink)
	SearchLine.Parent = SearchEdit.Container
	Fade.Track(Overlay, SearchLine)

	const Empty = Draw.Label(Holder, "NoMatch", Zero, 2, "", Look.Fonts.UbuntuRegular, Look.Sizes.Body, Look.FontPlaceholder, Enum.TextXAlignment.Left)

	Empty.Visible = false

	const function ToggleProfileEdit()
		if os.clock() - LastSubmit < 1 then
			return
		end

		if Menu.ProfileEdit.Container.Visible then
			SubmitProfile(TextField.GetText(Menu.ProfileEdit))
		else
			TextField.SetVisible(Menu.ProfileEdit, true)
			TextField.CaptureFocus(Menu.ProfileEdit)
		end
	end
	const CreateProfile = Buttons.New(Header, {
		Name = "CreateProfile",
		Rect = Zero,
		ZIndex = 4,
		Style = Look.IconButton,
		Text = "",
		Font = Look.Fonts.Default,
		FontSize = Look.Sizes.Body,
		Align = Enum.TextXAlignment.Center,
		Overlay = Overlay,
		OnActivated = ToggleProfileEdit,
	})

	const CreateIcon = Draw.Icon(CreateProfile.Object, "Icon", Zero, 5, Images.GetContent("res://textures/ui/add.png"), Look.FontWhite)

	Fade.Track(Overlay, CreateIcon)
	Tooltip.Attach(Tip, CreateProfile.Object, "Create Profile")

	const function AskDeleteProfile()
		if os.clock() - LastSubmit < 1 then
			return
		end

		const Profile = SettingsManager.GetCurrentProfile()

		Confirm(Menu, "Delete profile", `Delete "{NameForPopup(Profile)}"? You can't get it back.`, "Delete", function()
			SettingsManager.DeleteProfile(Profile)
			UpdateProfileSelection(Menu)
		end)
	end
	const DeleteProfile = Buttons.New(Header, {
		Name = "DeleteProfile",
		Rect = Zero,
		ZIndex = 4,
		Style = Look.IconButton,
		Text = "",
		Font = Look.Fonts.Default,
		FontSize = Look.Sizes.Body,
		Align = Enum.TextXAlignment.Center,
		Overlay = Overlay,
		OnActivated = AskDeleteProfile,
	})

	const DeleteIcon = Draw.Icon(DeleteProfile.Object, "Icon", Zero, 5, Images.GetContent("res://user/skins/default/ui/buttons/delete.png"), Look.FontWhite)

	Fade.Track(Overlay, DeleteIcon)
	Tooltip.Attach(Tip, DeleteProfile.Object, "Delete Profile")

	const Outline = Draw.Frame(Holder, "Outline", Zero, 5, false)

	Draw.Stroke(Outline, Look.OutlineStroke, Look.OutlineThickness)
	Draw.Corner(Outline, Look.Corner)

	Menu = {
		Item = Root,
		Viewport = Built.Viewport,
		Built = Built,
		Shown = false,
		Overlay = Overlay,
		Slide = SlideFade,
		Rest = Rest,
		HideButton = Hide,
		Holder = Holder,
		Dim = Dim,
		DimSeparator = DimSeparator,
		Header = Header,
		Title = Title,
		ProfilesDropdown = ProfilesDropdown,
		CreateProfile = CreateProfile,
		CreateIcon = CreateIcon,
		DeleteProfile = DeleteProfile,
		DeleteIcon = DeleteIcon,
		ProfileEdit = ProfileEdit,
		SearchEdit = SearchEdit,
		Search = "",
		SearchTyped = "",
		Empty = Empty,
		Question = nil,
		Outline = Outline,
		Sidebar = Sidebar,
		Categories = {},
		SelectedCategory = nil,
		SettingPanels = {},
		Dropdowns = Dropdowns,
		Tooltip = Tip,
		Connections = {},
	} :: SettingsMenu

	Module.Instance = Menu

	table.insert(Menu.Connections, SearchEdit.Object:GetPropertyChangedSignal("Text"):Connect(function()
		ApplySearch(Menu, SearchEdit.Object.Text)
	end))

	const Sections = SettingsProfile.ToOrderedSectionList(SettingsManager.Settings :: SettingsProfile.SettingsProfile)

	for Section = SettingsSection.Gameplay, SettingsSection.Other do
		-- a section with nothing to show gets no tab
		local HasRows = false

		for _, Entry in Sections[Section] do
			if (Entry :: SettingItem).Visible then
				HasRows = true
			end
		end

		if not HasRows then
			continue
		end

		const SectionName = Text.SectionName(Section)
		const Index = #Menu.Categories
		const Area = ScrollArea.New(Holder, SectionName, 1, Overlay, Geometry.CategoryPadding, IsShown)
		const SidebarRow = Draw.Frame(Sidebar.Content, SectionName, Zero, 1, false)

		Draw.Fill(SidebarRow, Look.SidebarSelected)
		SidebarRow.BackgroundTransparency = 1

		const function ChooseCategory()
			SelectCategory(Menu, Menu.Categories[Index + 1])
		end
		const SidebarButton = Buttons.New(SidebarRow, {
			Name = "Button",
			Rect = Zero,
			ZIndex = 2,
			Style = Look.SidebarButton,
			Text = string.upper(SectionName),
			Font = Look.Fonts.UbuntuMedium,
			FontSize = Look.Sizes.Body,
			Align = Enum.TextXAlignment.Left,
			Overlay = Overlay,
			OnActivated = ChooseCategory,
		})

		Fade.Track(Overlay, SidebarRow)
		ScrollArea.SetVisible(Area, false)

		const Category = {
			Name = SectionName,
			Index = Index,
			Area = Area,
			Rows = {},
			SidebarRow = SidebarRow,
			SidebarButton = SidebarButton,
		} :: Category

		table.insert(Menu.Categories, Category)

		for _, Entry in Sections[Section] do
			const Setting = Entry :: SettingItem

			if Setting.Visible then
				BuildRow(Menu, Category, Setting, Root)
			end
		end

		if not Menu.SelectedCategory then
			SelectCategory(Menu, Category)
		end
	end

	-- The CREDITS tab, last in the sidebar (AIMIA's own): who made AIMIA and what it uses, its license notices and the
	-- license text (UI/Settings/Credits). It is a category with no rows, so it is chosen, hidden and faded as a section is.
	do
		const Index = #Menu.Categories
		const Area = ScrollArea.New(Holder, Credits.Name, 1, Overlay, Geometry.CategoryPadding, IsShown)
		const SidebarRow = Draw.Frame(Sidebar.Content, Credits.Name, Zero, 1, false)

		Draw.Fill(SidebarRow, Look.SidebarSelected)
		SidebarRow.BackgroundTransparency = 1

		const function ChooseCredits()
			SelectCategory(Menu, Menu.Categories[Index + 1])
		end
		const SidebarButton = Buttons.New(SidebarRow, {
			Name = "Button",
			Rect = Zero,
			ZIndex = 2,
			Style = Look.SidebarButton,
			Text = string.upper(Credits.Name),
			Font = Look.Fonts.UbuntuMedium,
			FontSize = Look.Sizes.Body,
			Align = Enum.TextXAlignment.Left,
			Overlay = Overlay,
			OnActivated = ChooseCredits,
		})

		Fade.Track(Overlay, SidebarRow)
		ScrollArea.SetVisible(Area, false)

		table.insert(Menu.Categories, {
			Name = Credits.Name,
			Index = Index,
			Area = Area,
			Rows = {},
			SidebarRow = SidebarRow,
			SidebarButton = SidebarButton,
			Credits = Credits.New(Area),
		} :: Category)
	end

	Fade.Track(Overlay, Root)
	Logger.Log(`SETTINGS MENU: {(os.clock() - Start) * 1000}ms`)

	-- The Visual section's preview card and its Preview button (UI/SettingsPreview). It is made after the fade has tracked the
	-- menu, so the fade never writes the card's moving pieces, and it goes with the menu. Nil when it couldn't be made: the menu
	-- works on without it.
	const function SectionShown(): string?
		const Selected = Menu.SelectedCategory

		return if Selected then Selected.Name else nil
	end

	const function SectionCount(): number
		return #Menu.Categories
	end

	const Preview = SettingsPreview.New({
		Root = Root,
		Holder = Holder,
		Overlay = Overlay,
		Tooltip = Tip,
		Section = SectionShown,
		Sections = SectionCount,
	})

	if Preview then
		table.insert(Menu.Connections, function()
			SettingsPreview.Destroy(Preview)
		end)
	end

	UpdateProfileSelection(Menu)
	Relayout(Menu)
	ShowMenu(Menu, false)

	Menu.Item.Visible = false

	const function OnHide()
		HideMenu(Menu)
	end

	-- The dimmed area hides the menu on a click, as Godot's Hide button does (its pressed signal: on release).
	table.insert(Menu.Connections, Hide.Activated:Connect(OnHide))

	const Viewport = Built.Viewport
	const ViewportConnection = Viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		Relayout(Menu)
	end)

	table.insert(Menu.Connections, ViewportConnection)

	-- A new scale moves every row: a tooltip or an open list would point at the old place.
	const function OnScaleChanged()
		Tooltip.Hide(Menu.Tooltip)
		CloseLists(Menu)
		Relayout(Menu)
	end

	Signal.Connect(Scale.Changed, OnScaleChanged)
	table.insert(Menu.Connections, function()
		Signal.Disconnect(Scale.Changed, OnScaleChanged)
	end)
	-- Modal keys (Input.OnInput with Modal): Ctrl+O toggles the menu, and Escape closes an open option list first, then the
	-- menu (not when another modal is on top of it).
	table.insert(Menu.Connections, Input.OnInput(function(Event: Input.InputEvent, _: boolean)
		if Event.Class ~= "InputEventKey" or not Event.Pressed then
			return
		end

		if Event.Keycode == Input.Key.O then
			if Event.CtrlPressed then
				ShowMenu(Menu, not Menu.Shown)
			end
		elseif Event.Keycode == Input.Key.Escape and Menu.Shown then
			if CloseLists(Menu) then
				return
			end

			if Input.IsTopModal(Menu.Item) then
				ShowMenu(Menu, false)
			end
		end
	end, true))

	-- SettingsManager.Menu and the SettingsProfile hooks that belong to the menu. Hide and the hooks' Show are Godot's
	-- CanvasItem hide and show (no fade, at once); ShowMenu is the faded one that the settings button calls.
	const function HideCanvas()
		Fade.Stop(Menu.Slide)
		Fade.Stop(Menu.Overlay)
		Menu.Shown = false
		Menu.HideButton.Active = false
		Tooltip.Hide(Menu.Tooltip)
		CloseLists(Menu)
		ClearPointers()
		ReleaseFocus(Menu, false)
		Hidden(Menu)
	end

	const function ShowCanvas()
		Fade.Set(Menu.Slide, 1)
		Fade.Set(Menu.Overlay, 1)
		Menu.Shown = true
		Menu.HideButton.Active = true
		Menu.Item.Visible = true
		Input.PushModal(Menu.Item)
	end

	const function ShowFaded(Show: boolean?)
		ShowMenu(Menu, Show)
	end

	const function RefreshHook(Setting: SettingsItem.ISettingsItem)
		Module.RefreshList(Menu, Setting :: SettingItem)
	end

	const function ShowPopupHook(Heading: string, Body: string, Option: string, OnOption: () -> ())
		const Popup = OptionPopup.Create(Built, Heading, Body)

		OptionPopup.AddOption(Popup, Option, OnOption)
		OptionPopup.Show(Popup)
	end

	const function AskReset()
		const Profile = NameForPopup(SettingsManager.GetCurrentProfile())

		Confirm(Menu, "Reset settings", `Put every setting in "{Profile}" back to its default?`, "Reset", SettingsManager.ResetToDefaults)
	end

	const function OnUserFolderChanged()
		ShowRestartPrompt(Built)
	end

	const Hooks = SettingsProfile.Hooks

	SettingsManager.Menu = { Hide = HideCanvas, ShowMenu = ShowFaded }
	Hooks.RefreshSettingsList = RefreshHook
	Hooks.ShowSettingsMenu = ShowCanvas
	Hooks.HideSettingsMenu = HideCanvas
	Hooks.ShowOptionPopup = ShowPopupHook
	Hooks.ResetToDefaults = AskReset

	Signal.Connect(SettingsManager.UserFolderChanged, OnUserFolderChanged)
	table.insert(Menu.Connections, function()
		Signal.Disconnect(SettingsManager.UserFolderChanged, OnUserFolderChanged)
	end)

	-- A modal coming or going: the tooltip goes, and a text field the modal covers gives up its focus.
	const function OnModalChanged()
		Tooltip.Hide(Menu.Tooltip)
		ReleaseFocus(Menu, true)
	end

	Signal.Connect(Input.ModalChanged, OnModalChanged)
	table.insert(Menu.Connections, function()
		Signal.Disconnect(Input.ModalChanged, OnModalChanged)
	end)

	Module.Instance = Menu
end

-- Disconnects the menu's input and signal connections, clears the hooks it set, and frees the menu.
-- @src scripts/ui/SettingsMenu.cs:_ExitTree L1-1
function Module.Destroy(Menu: SettingsMenu)
	for _, Link in Menu.Connections do
		if typeof(Link) == "RBXScriptConnection" then
			(Link :: RBXScriptConnection):Disconnect()
		else
			(Link :: () -> ())()
		end
	end

	table.clear(Menu.Connections)

	const Hooks = SettingsProfile.Hooks

	Hooks.RefreshSettingsList = nil
	Hooks.ShowSettingsMenu = nil
	Hooks.HideSettingsMenu = nil
	Hooks.ShowOptionPopup = nil
	Hooks.ResetToDefaults = SettingsManager.ResetToDefaults
	SettingsManager.Menu = nil

	if Module.Instance == Menu then
		Module.Instance = nil
	end

	Input.PopModal(Menu.Item)
	Menu.Item:Destroy()
end

-- The option list of a setting is rebuilt from its current values.
-- @src scripts/ui/SettingsMenu.cs:RefreshList L521-530
function Module.RefreshList(Menu: SettingsMenu, Setting: SettingItem)
	const Row = Menu.SettingPanels[Setting.Id] or error(`Aimia UI: no settings row for {Setting.Id}`, 2)
	const DropdownControl = Row.Option or error(`Aimia UI: no option list for {Setting.Id}`, 2)
	const List = Setting.List :: ChoiceList

	Dropdown.Clear(DropdownControl)

	for _, Value in List.Values do
		Dropdown.AddItem(DropdownControl, Value :: string)
	end
end

Module.ShowMenu = ShowMenu
Module.HideMenu = HideMenu
Module.SelectCategory = SelectCategory
Module.UpdateProfileSelection = UpdateProfileSelection

return Module
