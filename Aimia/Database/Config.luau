--!strict
--!optimize 2

--[[
	Startup config, as scripts/database/Config.cs: the ID of the selected settings profile.

	Design Notes
		Config is not stored, upstream or here: Instance is the object of the session. The source's private init()
		builds the same object as New, and nothing calls it upstream, so it is not ported separately.
]]

export type Config = {
	SettingsProfileID: string?,
}

-- @src scripts/database/Config.cs:init L15-18
const function New(): Config
	return {
		SettingsProfileID = nil,
	}
end

-- @src scripts/database/Config.cs:Instance L8-8
-- @src scripts/database/Config.cs:DefaultId L6-6
const Config = {
	DefaultId = "_CONFIG",
	Instance = New(),
	New = New,
}

return Config
