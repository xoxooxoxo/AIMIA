--!strict
--!optimize 2

--[[
	The texture value a node takes for a skin texture (SkinProfile.Texture): { Path } for a baked default-skin image, or
	{ Path = key } for a decoded image, registered with Images once per decoded image.

	Design Notes
		The registration is kept for the session: a skin load decodes new images, and the earlier ones are not
		unregistered (no owner releases them yet).
]]

const SkinProfile = require("../../../Skinning/SkinProfile")

export type Register = (Image: SkinProfile.Image) -> string

const Keys: { [SkinProfile.Image]: string } = {}

-- The texture value of a skin texture (nil for a missing one), registering a decoded image on first use.
const function Value(Texture: SkinProfile.Texture?, Register: Register): { Path: string }?
	if not Texture then
		return nil
	end

	if Texture.Path then
		return { Path = Texture.Path }
	end

	const Image = Texture.Image

	if not Image then
		return nil
	end

	local Key = Keys[Image]

	if not Key then
		Key = Register(Image)
		Keys[Image] = Key
	end

	return { Path = Key }
end

return Value
