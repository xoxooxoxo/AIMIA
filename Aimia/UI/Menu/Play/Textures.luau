--!strict
--!optimize 2

--[[
	The texture value a node takes (`texture`, `icon`, `material`) from what the port holds: a skin texture ({ Path } for a
	baked default image, { Image } for a decoded file), a map cover (a decoded image, or the default cover's res:// path).

	Design Notes
		A decoded image is registered with UI/Images once and keeps its key (Images.Register creates an EditableImage per call).
		The cache is keyed by the decoded table, so a skin reload that makes new tables registers them again.
]]

const ImageDecode = require("../../../Util/ImageDecode")
const Images = require("../../Images")
const SkinProfile = require("../../../Skinning/SkinProfile")

export type Source = SkinProfile.Texture | ImageDecode.Image | string

const Registered: { [ImageDecode.Image]: string } = {}

-- The key of a decoded image in UI/Images, registered on first use.
const function RegisteredKey(Image: ImageDecode.Image): string
	const Existing = Registered[Image]

	if Existing then
		return Existing
	end

	const Key = Images.Register(Image)

	Registered[Image] = Key

	return Key
end

-- The `{ Path = ... }` value of a texture source, or nil for none.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:Setup L456
const function Value(Source: Source?): { Path: string }?
	if Source == nil then
		return nil
	end

	if type(Source) == "string" then
		return { Path = Source }
	end

	const Decoded = Source :: ImageDecode.Image

	if Decoded.Pixels ~= nil then
		return { Path = RegisteredKey(Decoded) }
	end

	const Texture = Source :: SkinProfile.Texture

	if Texture.Image then
		return { Path = RegisteredKey(Texture.Image) }
	end

	if Texture.Path then
		return { Path = Texture.Path }
	end

	return nil
end

return Value
