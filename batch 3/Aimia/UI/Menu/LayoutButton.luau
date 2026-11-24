--!strict
--!optimize 2

--[[
	The layout button of the map list (scripts/ui/menu/LayoutButton.cs): switches the list between the list and grid
	layouts, and shows the icon of the layout it switches to.
]]

const Images = require("../Images")
const Items = require("../Item")
const MapList = require("./Play/MapList")
const Nodes = require("../Nodes")
const SkinManager = require("../../Skinning/SkinManager")
const SkinTexture = require("./HomeLogic/SkinTexture")

-- @src scripts/ui/menu/LayoutButton.cs:_Pressed L6-13
const function Press(Item: Items.Item)
	const List = MapList.GetInstance()
	const Layout = if List.Layout == MapList.ListLayout.List then MapList.ListLayout.Grid else MapList.ListLayout.List
	const Skin = SkinManager.Skin
	const Icon = if Layout == MapList.ListLayout.List then Skin.LayoutListButtonImage else Skin.LayoutGridButtonImage

	Nodes.Set(Item, "icon", SkinTexture(Icon, Images.Register))
	MapList.UpdateLayout(List, Layout)
end

-- @src scripts/ui/menu/LayoutButton.cs:_Pressed L6-13
const function New(Item: Items.Item)
	Nodes.Connect(Item, "pressed", function()
		Press(Item)
	end)
end

return New
