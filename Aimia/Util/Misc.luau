--!strict
--!optimize 2

--[[
	Color, number and file helpers of scripts/util/Misc.cs that need no Godot node, skin or image decoder.

	Design Notes
		CopyProperties, CopyReference and OBJParser need Godot nodes or the OBJ parser: not ported here.
		GetModIcon takes the skin as an argument: SkinManager requires this module, so it cannot require SkinManager back.
		BinarySearch keeps the source's 0-based result over the 1-based Luau array.
		Float parameters and results are float32 values.
]]

const Color = require("../Godot/Color")
const DotnetNumber = require("../Dotnet/Number")
const DotnetString = require("../Dotnet/String")
const FileSystem = require("./FileSystem")
const ImageDecode = require("./ImageDecode")
const Logger = require("./Logger")
const Md5 = require("./Md5")
const SkinProfile = require("../Skinning/SkinProfile")

-- @src scripts/util/Misc.cs:ParseColor L153-174
const function ParseColor(Hex: string?, Fallback: Color.Color): Color.Color
	if Hex == nil or DotnetString.IsNullOrWhiteSpace(Hex) then
		return Color.New(Fallback.R, Fallback.G, Fallback.B, Fallback.A)
	end

	const Trimmed = DotnetString.Trim(Hex)
	const Prefixed = if DotnetString.StartsWith(Trimmed, "#") then Trimmed else `#{Trimmed}`
	const Success, Parsed = pcall(Color.FromHtml, Prefixed)

	if Success then
		return Parsed
	end

	Logger.Log(`Invalid color: {Prefixed} (reset to default value)`)

	return Color.New(Fallback.R, Fallback.G, Fallback.B, Fallback.A)
end

-- @src scripts/util/Misc.cs:ParseFloatInput L176-190
const function ParseFloatInput(Input: string?, Fallback: number?): number
	if Input == nil or DotnetString.IsNullOrWhiteSpace(Input) then
		return Fallback or 0
	end

	const Normalized = DotnetString.Replace(Input, ",", ".")
	const Success, Result = DotnetNumber.TryParseSingle(Normalized, DotnetNumber.Styles.Any)

	if Success then
		return Result
	end

	return Fallback or 0
end

-- @src scripts/util/Misc.cs:BinarySearch L192-212
const function BinarySearch(Values: { number }, Time: number): number
	local Left = 0
	local Right = #Values

	while Left < Right do
		const Middle = (Left + Right) // 2

		if Time < Values[Middle + 1] then
			Right = Middle
		else
			Left = Middle + 1
		end
	end

	return Left - 1
end

-- @src scripts/util/Misc.cs:HashFiles L71-84
const function HashFiles(Paths: { string }): buffer
	const Contents: { buffer } = {}

	for _, Path in Paths do
		table.insert(Contents, FileSystem.ReadAllBytes(Path))
	end

	return Md5.Hash(Contents)
end

-- @src scripts/util/Misc.cs:LoadImageFromBuffer L94-151
const function LoadImageFromBuffer(Buffer: buffer?): ImageDecode.Image?
	if Buffer == nil or buffer.len(Buffer) < 4 then
		return nil
	end

	const Decoded = ImageDecode.Decode(Buffer)

	if Decoded ~= nil then
		return Decoded
	end

	const Length = buffer.len(Buffer)
	const IsPng = buffer.readu8(Buffer, 0) == 137 and buffer.readu8(Buffer, 1) == 80 and buffer.readu8(Buffer, 2) == 78 and buffer.readu8(Buffer, 3) == 71
	const IsJpeg = Length >= 3 and buffer.readu8(Buffer, 0) == 0xFF and buffer.readu8(Buffer, 1) == 0xD8 and buffer.readu8(Buffer, 2) == 0xFF
	const IsBmp = Length >= 2 and buffer.readu8(Buffer, 0) == 0x42 and buffer.readu8(Buffer, 1) == 0x4D
	const IsWebp = Length >= 12 and buffer.readstring(Buffer, 0, 4) == "RIFF" and buffer.readstring(Buffer, 8, 4) == "WEBP"
	const TypeName = if IsPng then "PNG" elseif IsJpeg then "JPG" elseif IsBmp then "BMP" elseif IsWebp then "WEBP" else "Unknown"

	Logger.Log(`Couldn't load image from buffer\n    Type: {TypeName};\n    Size: {Length}`)

	return nil
end

-- The icon of a modifier by name, from the skin. Any other name is the source's PlaceholderTexture2D (32 x 32, which the
-- port has no image for), answered as nil.
-- @src scripts/util/Misc.cs:GetModIcon L14-50
const function GetModIcon(Mod: string, Skin: SkinProfile.SkinProfile): SkinProfile.Texture?
	if Mod == "NoFail" then
		return Skin.ModNoFailImage
	elseif Mod == "Autoplay" then
		return Skin.ModAutoplayImage
	elseif Mod == "Ghost" then
		return Skin.ModGhostImage
	elseif Mod == "Strobe" then
		return Skin.ModStrobeImage
	elseif Mod == "Chaos" then
		return Skin.ModChaosImage
	elseif Mod == "Vortex" then
		return Skin.ModVortexImage
	elseif Mod == "Earthquake" then
		return Skin.ModEarthquakeImage
	elseif Mod == "HFlip" then
		return Skin.ModHFlipImage
	elseif Mod == "VFlip" then
		return Skin.ModVFlipImage
	end

	return nil
end

return {
	GetModIcon = GetModIcon,
	ParseColor = ParseColor,
	ParseFloatInput = ParseFloatInput,
	BinarySearch = BinarySearch,
	HashFiles = HashFiles,
	LoadImageFromBuffer = LoadImageFromBuffer,
}
