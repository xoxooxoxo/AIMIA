--!strict
--!optimize 2

--[[
	IRenderer.cs and Renderer.cs as types: a renderer draws the attempt's objects each frame. Renderer is the base of the note
	and trail renderers (Setup takes the settings and skin, Process draws one frame); ObjectRenderer<T> is IRenderer<T>.

	Representation
		A renderer is a table whose Setup and Process the view sets. Settings is the value a view's Setup stores, as the source's
		base.Setup does; the skin is only passed to Setup, and a renderer's own state is the view's.

	Design Notes
		Types only: nothing here runs. Every key of the type is present in a renderer's table (Settings is `nil :: ...` until Setup).
]]

const Attempt = require("../Attempt")
const SettingsProfile = require("../../Database/Settings/SettingsProfile")
const SkinProfile = require("../../Skinning/SkinProfile")

export type Renderer = {
	Setup: (SettingsProfile.SettingsProfile, SkinProfile.SkinProfile) -> (),
	Process: (number, Attempt.Attempt) -> (),
	Settings: SettingsProfile.SettingsProfile?,
}

-- @src scripts/game/renderers/IRenderer.cs:IRenderer L3-6
export type ObjectRenderer<T> = {
	Render: (Time: number, Delta: number, Objects: { T }) -> (),
}

-- @src scripts/game/renderers/Renderer.cs:Renderer L4-16
return {}
