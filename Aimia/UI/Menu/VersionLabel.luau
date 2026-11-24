--!strict
--!optimize 2

--[[
	The version label of the title bar (scripts/ui/menu/VersionLabel.cs): the "{0}" of its text is the application version.
]]

const Items = require("../Item")
const Nodes = require("../Nodes")
const Format = require("./HomeLogic/Format")
const Version = require("./HomeLogic/Version")

-- @src scripts/ui/menu/VersionLabel.cs:_Ready L6-11
const function New(Item: Items.Item)
	Nodes.Set(Item, "text", Format.Format(Nodes.Get(Item, "text") :: string, { Version.Version }))
end

return New
