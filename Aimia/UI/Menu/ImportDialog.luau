--!strict
--!optimize 2

--[[
	The import dialog's FilesSelected handler (scripts/ui/menu/ImportDialog.cs): the selected maps are imported in bulk.
	The dialog itself is excluded (Roblox has no file dialog), so nothing selects files to pass here yet.
]]

const MapParser = require("../../Map/MapParser")

-- @src scripts/ui/menu/ImportDialog.cs:_Ready L8-11
const function FilesSelected(Paths: { string })
	MapParser.BulkImport(Paths)
end

return FilesSelected
