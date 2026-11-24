--!strict
--!optimize 2

--[[
	The random pick button (scripts/ui/menu/play/RandomPickButton.cs) on "Menus/Play/SubTopBar/HBoxContainer/Random" of
	res://scenes/main_menu.tscn: a press, or Ctrl+F4, selects a random map of the list without playing it.

	Design Notes
		The source's _Pressed is BaseButton's pressed virtual, so it is the pressed signal here. The source's Random is
		unseeded, as math.random is. An empty list errors, as Random.Next(0) throws.
		The Ctrl+F4 subscription is dropped with the button's item (Item.Cleanup).
]]

const Nodes = require("../../Nodes")
const Input = require("../../Input")
const Items = require("../../Item")
const MapList = require("./MapList")

-- Selects a random map of the list without playing it (RandomPickButton.Pick).
-- @src scripts/ui/menu/play/RandomPickButton.cs:Pick L26-32
const function Pick()
	const List = MapList.GetInstance()
	const Index = math.random(#List.Maps)

	MapList.Select(List, List.Maps[Index], false)
end

-- @src scripts/ui/menu/play/RandomPickButton.cs:_Pressed L8-11
-- @src scripts/ui/menu/play/RandomPickButton.cs:_Input L13-24
const function New(Item: Items.Item)
	Nodes.Connect(Item, "pressed", function()
		Pick()
	end)

	-- Ctrl+F4 (Godot's Key.F4 name, which UI/Input does not list), while the button is on screen (not behind a song).
	table.insert(Item.Cleanup, Input.OnInput(function(Event: Input.InputEvent)
		if Event.Class == "InputEventKey" and Event.Pressed and Event.CtrlPressed and Event.Keycode == "F4" and not Nodes.HiddenInTree(Item) then
			Pick()
		end
	end))
end

return New
