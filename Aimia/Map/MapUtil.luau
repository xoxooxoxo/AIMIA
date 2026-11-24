--!strict
--!optimize 2

--[[
	MapUtil.cs: the map folders under the user folder. Paths are in-memory file system paths (Util/FileSystem).
]]

const Constants = require("../Constants")

-- @src scripts/map/MapUtil.cs:MapsFolder L3-3
const MapsFolder = `{Constants.UserFolder}/maps`

-- @src scripts/map/MapUtil.cs:MapsCacheFolder L5-5
const MapsCacheFolder = `{Constants.UserFolder}/cache/maps`

return {
	MapsFolder = MapsFolder,
	MapsCacheFolder = MapsCacheFolder,
}
