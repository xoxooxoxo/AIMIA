--!strict
--!optimize 2

--[[
	The settings button (scripts/ui/menu/SettingsMenuButton.cs): shows the settings menu, SettingsMenu.Instance (the menu the
	settings UI sets in New).

	Design Notes
		DEVIATION(hook): SettingsManager.Menu carries only Hide (SettingsMenu sets it so), so ShowMenu is called on the instance.
]]

const Items = require("../Item")
const Nodes = require("../Nodes")
const SettingsMenu = require("../SettingsMenu")

-- @src scripts/ui/menu/SettingsMenuButton.cs:_Pressed L6-9
const function New(Item: Items.Item)
	Nodes.Connect(Item, "pressed", function()
		SettingsMenu.ShowMenu(SettingsMenu.Instance :: SettingsMenu.SettingsMenu)
	end)
end

return New
