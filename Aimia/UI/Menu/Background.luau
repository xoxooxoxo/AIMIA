--!strict
--!optimize 2

--[[
	The tiled background of a menu panel (scripts/ui/menu/Background.cs): the "Tile" texture takes the skin's background
	tile image and shader, and takes them again whenever the skin loads.

	Design Notes
		The tile's shader is the skin's source, as an inline Shader resource of the tile's ShaderMaterial (UI/Shaders draws
		a scrolling tile from "UV.x -= TIME"). Without a skin shader the tile has no material, which draws the same.
		The skin subscription goes with the item (Listen).
]]

const Images = require("../Images")
const Items = require("../Item")
const Listen = require("./HomeLogic/Listen")
const Nodes = require("../Nodes")
const SkinManager = require("../../Skinning/SkinManager")
const SkinProfile = require("../../Skinning/SkinProfile")
const SkinTexture = require("./HomeLogic/SkinTexture")

-- The tile's ShaderMaterial with the skin's shader source; nil without a shader.
const function TileMaterial(Shader: string?): { Type: string, Properties: { [string]: unknown } }?
	if not Shader then
		return nil
	end

	return {
		Type = "ShaderMaterial",
		Properties = {
			["shader"] = {
				Type = "Shader",
				Properties = { ["code"] = Shader },
			},
		},
	}
end

-- @src scripts/ui/menu/Background.cs:UpdateSkin L19-25
const function UpdateSkin(Tile: Items.Item, Skin: SkinProfile.SkinProfile?)
	const Source = Skin or SkinManager.Skin

	Nodes.Set(Tile, "texture", SkinTexture(Source.BackgroundTileImage, Images.Register))
	Nodes.Set(Tile, "material", TileMaterial(Source.BackgroundTileShader))
end

-- @src scripts/ui/menu/Background.cs:_Ready L9-17
const function New(Item: Items.Item)
	const Tile = Nodes.GetNode(Item, "Tile")

	Listen(Item, SkinManager.Loaded, function(Skin: SkinProfile.SkinProfile)
		UpdateSkin(Tile, Skin)
	end)

	UpdateSkin(Tile, nil)
end

return New
