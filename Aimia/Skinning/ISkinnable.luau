--!strict
--!optimize 2

--[[
	ISkinnable as a type: an object that takes the loaded skin again when it changes (UpdateSkin). The audio, menu and map
	button UI implement it (SoundManager, Background, JukeboxPanel, MapButton); none is ported in this module.

	Representation
		The interface method is an optional field, as the other interfaces are (`x is ISkinnable` is `x.UpdateSkin ~= nil`).
]]

const SkinProfile = require("./SkinProfile")

export type ISkinnable = {
	UpdateSkin: ((Skin: SkinProfile.SkinProfile) -> ())?,
}

return {}
