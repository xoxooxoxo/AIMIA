--!strict
--!optimize 2

--[[
	The Godot canvas shaders the menus use, on Roblox: the drawing of a panel's style box by its shader, the shader parameters
	a node sets (Nodes.SetShaderParameter), and the per-frame passes of the shaders that need one. The modules beside this
	file are the shaders; this file dispatches to them.

	Design Notes
		outline.gdshader: OutlineRing (the ring: a stroke with a gradient; OutlineImage, per-pixel, for a box a stroke cannot draw). ui_blur.gdshader: Blur (the backdrop's copy in the panel).
		jukebox_progress.gdshader: ProgressBar (the box and the spectrum's bars in two tints, split at the progress).
		Any other shader, or none, draws its style box with Style.DrawStyleBox (DEVIATION(shader): the other shaders of the
		menus are not drawn; the alpha gradients of a ColorRect are Gradient).
		The scrolling tile ("UV.x -= TIME": the default skin's background_tile and the menu's inline shader) is the scene
		builder's scroll: IsScrollingTile.
		A parameter a node does not set reads the material's value, else the shader's uniform default (UniformDefaults).
]]

const Style = require("./Style")
const MaterialModule = require("@self/Material")
const OutlineImage = require("@self/OutlineImage")
const OutlineRing = require("@self/OutlineRing")
const ProgressBar = require("@self/ProgressBar")
const Blur = require("@self/Blur")
const Gradient = require("@self/Gradient")
const Theme = require("./Theme")

export type Material = MaterialModule.Material

const OutlinePath = "res://scripts/shaders/outline.gdshader"
const BlurPath = "res://scripts/shaders/ui_blur.gdshader"
const ProgressPath = "res://scripts/shaders/jukebox_progress.gdshader"
const TilePath = "res://user/skins/default/ui/background_tile.gdshader"

-- The uniform defaults that the menus' parameters rely on (the shaders' declarations).
const UniformDefaults = {
	[OutlinePath] = { ["outline_opacity"] = 1, ["fill"] = 0, ["glow_radius"] = 350, ["glow_exponent"] = 2 },
	[BlurPath] = { ["brightness"] = 1 },
	[ProgressPath] = {
		["progress"] = 0,
		["margin"] = 0,
		["color_fill"] = { Color = { 1, 1, 1, 1 } },
		["color_background"] = { Color = { 0, 0, 0, 1 } },
	},
}

-- Whether a material is the scrolling tile's shader (its path, or inline code that slides the UV).
const function IsScrollingTile(Material: Material?): boolean
	if not Material then
		return false
	end

	return Material.Path == TilePath or (Material.Code ~= nil and string.find(Material.Code, "UV.x -= TIME", 1, true) ~= nil)
end

-- A parameter's value for a material: the node's override or the material's value, else the shader's default, else nil.
const function ParameterOf(Material: Material?, Name: string): unknown
	if not Material then
		return nil
	end

	const Value = MaterialModule.Parameter(Material, Name)

	if Value ~= nil then
		return Value
	end

	const Path = Material.Path

	if not Path then
		return nil
	end

	const Defaults = UniformDefaults[Path]

	return if Defaults then Defaults[Name] else nil
end

-- Destroys the shader drawing of a style host (before its children are cleared or it is freed).
const function Release(Host: Frame)
	OutlineImage.Release(Host)
	OutlineRing.Release(Host)
	ProgressBar.Release(Host)
	Blur.Release(Host)
end

-- Draws a panel's style box in Host (Gui is the panel, Viewport the screen; Own is self_modulate): by the shader of the
-- material, else as Style.DrawStyleBox does. Answers whether the drawing depends on the size.
const function Draw(Host: Frame, Gui: GuiObject, Viewport: GuiBase2d, Material: Material?, Box: Theme.Resource?, Own: { number }, Width: number, Height: number): boolean
	if Material and Material.Path == OutlinePath then
		const Ring = OutlineRing.Draw(Host, Gui, Material, Box, Width, Height)

		if Ring ~= nil then
			OutlineImage.Release(Host)

			return Ring
		end

		OutlineRing.Release(Host)

		const Drawn = OutlineImage.Draw(Host, Gui, Material, Box, Own, Width, Height)

		-- (nil: the device is out of memory for the ring's picture, and the box is drawn without its glow)
		if Drawn ~= nil then
			return Drawn
		end

		return Style.DrawStyleBox(Host, Box, Own, Width, Height)
	elseif Material and Material.Path == BlurPath then
		return Blur.Draw(Host, Gui, Material, Box, Own)
	elseif Material and Material.Path == ProgressPath then
		return ProgressBar.Draw(Host, Gui, Viewport, Material, Box, Own, Width, Height)
	end

	Release(Host)

	return Style.DrawStyleBox(Host, Box, Own, Width, Height)
end

-- A shader parameter of a style host changed (the node's override is already stored).
const function SetParameter(Host: Frame, Name: string, Value: unknown)
	OutlineImage.SetParameter(Host, Name, Value)
	OutlineRing.SetParameter(Host, Name, Value)
	ProgressBar.SetParameter(Host, Name, Value)
	Blur.SetParameter(Host, Name, Value)
end

-- The spectrum's bars of a progress-shaded panel's style host (UI/AudioSpectrum), drawn with the shader's split.
const function SetBars(Host: Frame, Points: { vector }, BarSize: number, Color: { number })
	ProgressBar.SetBars(Host, Points, BarSize, Color)
end

-- The per-frame pass of the shaders that keep state on the screen (from UI/Nodes, after the layout).
const function Flush()
	OutlineImage.Flush()
	OutlineRing.Flush()
	ProgressBar.Flush()
	Blur.Flush()
end

return {
	OverrideKey = MaterialModule.OverrideKey,
	IsScrollingTile = IsScrollingTile,
	ParameterOf = ParameterOf,
	Draw = Draw,
	ApplyGradient = Gradient.Apply,
	IsGradient = Gradient.Is,
	Release = Release,
	SetParameter = SetParameter,
	SetBars = SetBars,
	Flush = Flush,
}
