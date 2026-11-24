--!strict
--!optimize 2

--[[
	Modifier.cs and the interfaces IModifier, IMapModifier, IObjectRenderModifier, IFailModifier and IHealthModifier as one
	type: a modifier is a table whose optional function fields are the interface methods (`mod is IMapModifier` is
	`Mod.ModifyMap ~= nil`).

	Representation
		Note, Map and Attempt are the fields the modifiers read or write, not the whole port types; the port's Note, Map
		and Attempt satisfy them structurally. Settings items are { Value } (SettingsItem<double>).

	Design Notes
		New is the base constructor: it sets the overridden fields and the Modifier.cs defaults, and a concrete module sets
		its own overrides on the table it answers. Activate takes the modifier as its first argument because the base
		writes Active (base.Activate(attempt)); the concrete modules call it as Modifier.Activate(Mod, Attempt).
]]

const Color = require("../../Godot/Color")
const Math = require("../../Godot/Math")

export type Note = {
	Index: number,
	X: number,
	Y: number,
	Opacity: number,
	Transform: Math.Transform3D,
}

export type Map = {
	Notes: { Note },
}

export type Attempt = {
	Progress: number,
	Speed: number,
	Settings: {
		ApproachDistance: { Value: number },
		ApproachTime: { Value: number },
	},
	Qualifies: boolean,
	UseFadeOut: boolean,
}

export type Modifier = {
	Name: string,
	Color: Color.Color,
	Active: boolean,
	Rankable: boolean,
	ScoreMultiplier: number,
	IncompatibleMods: { string },
	Activate: (Modifier, Attempt) -> (),
	ModifyMap: ((Map, Attempt) -> ())?,
	ModifyRenderObject: ((Note, Attempt) -> ())?,
	IsFail: boolean?,
	CheckFailCondition: ((boolean, number) -> boolean)?,
	ApplyHealthResult: ((boolean, number) -> number)?,
}

-- @src scripts/game/modifiers/Modifier.cs:Activate L36-39
const function Activate(Mod: Modifier, Attempt: Attempt)
	Mod.Active = true
end

-- @src scripts/game/modifiers/Modifier.cs:Modifier L7-40
const function New(Name: string, Accent: Color.Color): Modifier
	return {
		Name = Name,
		Color = Accent,
		Active = false,
		Rankable = false,
		ScoreMultiplier = 1,
		IncompatibleMods = {},
		Activate = Activate,
	}
end

return {
	New = New,
	Activate = Activate,
}
