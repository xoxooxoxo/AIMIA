--!strict
--!optimize 2

--[[
	The search panel (scripts/ui/menu/play/SearchPanel.cs) on "Menus/Play/SubTopBar/HBoxContainer/Search" and "SearchAuthor" of
	res://scenes/main_menu.tscn: a line edit that searches the list by title, or by author when the export SearchAuthor is set.
	A key press (not Space or Escape, not with Ctrl or Alt) moves focus to this one. A press outside it releases the focus in
	the TextBox itself, and keys typed while a text box has focus are not delivered here (UI/Input).

	Design Notes
		SearchAuthor is the scene's export: the panel's own property (Nodes.Get), false when the scene leaves it out.
		The input subscription is dropped with the panel's item (Item.Cleanup).
]]

const Nodes = require("../../Nodes")
const Input = require("../../Input")
const Items = require("../../Item")
const MapList = require("./MapList")

-- @src scripts/ui/menu/play/SearchPanel.cs:_Ready L11-22
-- @src scripts/ui/menu/play/SearchPanel.cs:_Input L24-39
const function New(Item: Items.Item)
	const LineEdit = Nodes.GetNode(Item, "LineEdit")
	const SearchIcon = Nodes.GetNode(Item, "TextureRect")
	const SearchAuthor = Nodes.Get(Item, "SearchAuthor") == true

	Nodes.Connect(LineEdit, "text_changed", function(Text: unknown)
		const Query = Text :: string
		const List = MapList.GetInstance()

		Nodes.Set(SearchIcon, "self_modulate", { Color = { 1, 1, 1, if Query == "" then 0.5 else 1 } })
		MapList.Search(List, if SearchAuthor then nil else Query, if SearchAuthor then Query else nil)
	end)

	-- (only while the panel is on screen: behind a song a hidden box taking the keyboard would stop the song's keys)
	table.insert(Item.Cleanup, Input.OnInput(function(Event: Input.InputEvent)
		if Event.Class == "InputEventKey" and Event.Pressed and not Event.CtrlPressed and not Event.AltPressed and not Nodes.HiddenInTree(Item) then
			-- (Slash opens chat, which needs the keyboard itself)
			if Event.Keycode ~= Input.Key.Space and Event.Keycode ~= Input.Key.Escape and Event.Keycode ~= "Slash" then
				Nodes.GrabFocus(LineEdit)
			end
		end
	end))
end

return New
