--!strict
--!optimize 2

--[[
	Images by path: upstream PNGs by Godot path ("res://textures/empty.png") and images made at runtime (map covers,
	custom skin textures decoded by Util/ImageDecode) by the "runtime://N" key Register answers. Scripts and the
	builder use either kind the same way, as a texture `{ Path = Key }`.

	Design Notes
		A res:// image is the uploaded Roblox image when AimiaData/ImageAssets has its id, otherwise the baked RGBA8
		pixels of AimiaData/Images (Base64, then Zstd) written into an EditableImage on first use.
		A runtime image larger than 1024 a side is downscaled (box filter) to fit EditableImage's limit when
		registered; GetSourceSize keeps its decoded size, as for baked images, so layout uses the image's own size.
		EditableImages are cached and shared by every label showing that texture; Unregister frees a runtime one.
		Roblox gives each device a budget for EditableImages (a smaller computer or a phone gets less), and a device out of it
		gets nil from CreateEditableImage: the texture then shows nothing (Content.none) instead of breaking what draws it
		(2026-11-08: AIMIA's menu stayed black on a player's computer). A baked image that didn't fit is tried again at its
		next use; a runtime one is registered without its image.
		A few baked images are drawn far smaller than they are; they're made at a smaller side (Smaller), so they hold less of
		that budget and look the same.
]]

const AssetService = game:GetService("AssetService")
const EncodingService = game:GetService("EncodingService")

const ImageData = require("../../AimiaData/Images")
const ImageAssets = require("../../AimiaData/ImageAssets")

export type Decoded = {
	Width: number,
	Height: number,
	Pixels: buffer,
}

type Runtime = {
	Image: EditableImage?,
	SourceWidth: number,
	SourceHeight: number,
}

const MaxSide = 1024

-- Baked images shown far smaller than they are, made at most this many pixels a side: the HUD's hit and miss icons
-- (512 x 512, drawn about 19 pixels wide).
const Smaller: { [string]: number } = {
	["res://user/skins/default/game/hits.png"] = 128,
	["res://user/skins/default/game/misses.png"] = 128,
}

const Cache: { [string]: EditableImage } = {}
const Runtimes: { [string]: Runtime } = {}
local NextRuntime = 0

const function GetData(Path: string): ImageData.Image
	const Image = ImageData[Path]

	if not Image then
		error(`No baked image {Path}`, 2)
	end

	return Image
end

const function Has(Path: string): boolean
	return ImageData[Path] ~= nil or Runtimes[Path] ~= nil
end

-- Defined below (Load shrinks the Smaller images with it).
local Downscale: (Source: Decoded, Width: number, Height: number) -> buffer

-- The image of Path, or nil when the device is out of memory for pictures.
const function Load(Path: string): EditableImage?
	const Runtime = Runtimes[Path]

	if Runtime then
		return Runtime.Image
	end

	const Cached = Cache[Path]

	if Cached then
		return Cached
	end

	const Image = GetData(Path)
	const Side = Smaller[Path]
	const Scale = if Side then math.min(1, Side / math.max(Image.Width, Image.Height, 1)) else 1
	const Width = math.max(1, math.round(Image.Width * Scale))
	const Height = math.max(1, math.round(Image.Height * Scale))
	const Size = Vector2.new(Width, Height)
	const Editable = AssetService:CreateEditableImage({ Size = Size })

	if not Editable then
		return nil
	end

	const Compressed = EncodingService:Base64Decode(buffer.fromstring(table.concat(Image.Parts)))
	const Pixels = EncodingService:DecompressBuffer(Compressed, Enum.CompressionAlgorithm.Zstd)

	Editable:WritePixelsBuffer(Vector2.zero, Size, if Scale < 1 then Downscale({ Width = Image.Width, Height = Image.Height, Pixels = Pixels }, Width, Height) else Pixels)
	Cache[Path] = Editable

	return Editable
end

-- Box-filter downscale of RGBA8 pixels by an integer-free ratio, averaging every source pixel a target pixel covers.
function Downscale(Source: Decoded, Width: number, Height: number): buffer
	const Pixels = buffer.create(Width * Height * 4)
	const ScaleX = Source.Width / Width
	const ScaleY = Source.Height / Height

	for Y = 0, Height - 1 do
		const Top = (Y * ScaleY) // 1
		const Bottom = math.max(Top + 1, ((Y + 1) * ScaleY) // 1)

		for X = 0, Width - 1 do
			const Left = (X * ScaleX) // 1
			const Right = math.max(Left + 1, ((X + 1) * ScaleX) // 1)
			local R, G, B, A, Count = 0, 0, 0, 0, 0

			for SourceY = Top, math.min(Bottom, Source.Height) - 1 do
				for SourceX = Left, math.min(Right, Source.Width) - 1 do
					const Offset = (SourceY * Source.Width + SourceX) * 4

					R += buffer.readu8(Source.Pixels, Offset)
					G += buffer.readu8(Source.Pixels, Offset + 1)
					B += buffer.readu8(Source.Pixels, Offset + 2)
					A += buffer.readu8(Source.Pixels, Offset + 3)
					Count += 1
				end
			end

			const Target = (Y * Width + X) * 4

			buffer.writeu8(Pixels, Target, math.round(R / Count))
			buffer.writeu8(Pixels, Target + 1, math.round(G / Count))
			buffer.writeu8(Pixels, Target + 2, math.round(B / Count))
			buffer.writeu8(Pixels, Target + 3, math.round(A / Count))
		end
	end

	return Pixels
end

-- Registers a decoded image and answers its key ("runtime://N") for `{ Path = Key }` textures.
const function Register(Image: Decoded): string
	const Scale = math.min(1, MaxSide / math.max(Image.Width, Image.Height, 1))
	const Width = math.max(1, math.round(Image.Width * Scale))
	const Height = math.max(1, math.round(Image.Height * Scale))
	const Pixels = if Scale < 1 then Downscale(Image, Width, Height) else Image.Pixels
	const Size = Vector2.new(Width, Height)
	const Editable = AssetService:CreateEditableImage({ Size = Size })

	-- (nil: the device is out of memory for pictures, and the key shows nothing)
	if Editable then
		Editable:WritePixelsBuffer(Vector2.zero, Size, Pixels)
	end

	NextRuntime += 1

	const Key = `runtime://{NextRuntime}`

	Runtimes[Key] = {
		Image = Editable,
		SourceWidth = Image.Width,
		SourceHeight = Image.Height,
	}

	return Key
end

const function Unregister(Key: string)
	const Runtime = Runtimes[Key]

	if Runtime then
		if Runtime.Image then
			Runtime.Image:Destroy()
		end

		Runtimes[Key] = nil
	end
end

const function GetContent(Path: string): Content
	const Asset = ImageAssets[Path]

	if Asset then
		return Content.fromUri(Asset)
	end

	const Image = Load(Path)

	return if Image then Content.fromObject(Image) else Content.none
end

const function GetSourceSize(Path: string): Vector2
	const Runtime = Runtimes[Path]

	if Runtime then
		return Vector2.new(Runtime.SourceWidth, Runtime.SourceHeight)
	end

	const Image = GetData(Path)

	return Vector2.new(Image.SourceWidth, Image.SourceHeight)
end

return {
	Has = Has,
	Load = Load,
	Register = Register,
	Unregister = Unregister,
	GetContent = GetContent,
	GetSourceSize = GetSourceSize,
}
