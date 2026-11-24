--!optimize 2

--[[
	The Cursor Style and Cursor Color settings: cursor pictures drawn in code, in place of the skin's cursor.png, and a tint.
	Looks only: the picture goes on the same quad at the same size (Cursor Scale), so where a note counts as hit is unchanged.

	Design Notes
		Each picture is made once, 256 x 256, from a signed distance (negative inside the shape) with a one-pixel soft edge,
		white so the tint colours it. Nil when the device won't make an editable image: the skin's cursor stays.
]]

local AssetService = game:GetService("AssetService")

local SkinSets = require("./SkinSets")

local CursorStyles = {}

-- The Cursor Style list ("skin" is the skin's own picture).
CursorStyles.Names = { "skin", "dot", "circle", "ring dot", "target", "cross", "square", "diamond", "triangle", "glow", "white glow", "pink orb", "star" }

-- Cursor pictures uploaded as images (the owner's picks, 2026-11-07), cropped round their middle and faded out at the edge so
-- no glow is cut off; drawn on the same quad as the code-drawn ones.
CursorStyles.Pictures = {
	["white glow"] = "rbxassetid://104753378716357",
	["pink orb"] = "rbxassetid://135760452331630",
	["star"] = "rbxassetid://106478950010607",
} :: { [string]: string }

local PictureContents: { [string]: Content } = {}

-- The Cursor Color list ("white" leaves the picture's own colours).
CursorStyles.Colors = {
	pink = Color3.fromRGB(255, 90, 170),
	red = Color3.fromRGB(255, 70, 70),
	orange = Color3.fromRGB(255, 150, 50),
	yellow = Color3.fromRGB(255, 230, 70),
	green = Color3.fromRGB(80, 255, 120),
	cyan = Color3.fromRGB(70, 230, 255),
	blue = Color3.fromRGB(80, 130, 255),
	purple = Color3.fromRGB(170, 100, 255),
}
CursorStyles.ColorNames = { "white", "pink", "red", "orange", "yellow", "green", "cyan", "blue", "purple" }

for _, Name in SkinSets.Names do
	table.insert(CursorStyles.Names, Name)
	table.insert(CursorStyles.ColorNames, Name)
end

local Side = 256

-- signed distances in the picture's own units (-1 to 1 across)
local function Circle(X: number, Y: number, R: number): number
	return math.sqrt(X * X + Y * Y) - R
end

local function Ring(X: number, Y: number, R: number, Half: number): number
	return math.abs(math.sqrt(X * X + Y * Y) - R) - Half
end

local function Box(X: number, Y: number, W: number, H: number): number
	local DX, DY = math.abs(X) - W, math.abs(Y) - H

	return math.sqrt(math.max(DX, 0) ^ 2 + math.max(DY, 0) ^ 2) + math.min(math.max(DX, DY), 0)
end

-- an equilateral triangle pointing up, R from its middle to an edge (screen Y grows down)
local function Triangle(X: number, Y: number, R: number): number
	local K = math.sqrt(3) / 2

	return math.max(Y, -0.5 * Y + K * X, -0.5 * Y - K * X) - R
end

local Shapes: { [string]: (number, number) -> (number, number?) } = {
	dot = function(X, Y)
		return Circle(X, Y, 0.42)
	end,
	circle = function(X, Y)
		return Ring(X, Y, 0.78, 0.09)
	end,
	["ring dot"] = function(X, Y)
		return math.min(Ring(X, Y, 0.78, 0.08), Circle(X, Y, 0.18))
	end,
	target = function(X, Y)
		return math.min(Ring(X, Y, 0.82, 0.06), Ring(X, Y, 0.48, 0.06), Circle(X, Y, 0.12))
	end,
	cross = function(X, Y)
		local Arms = math.min(Box(X, Y, 0.88, 0.07), Box(X, Y, 0.07, 0.88))

		-- (a gap in the middle shows the exact point)
		return math.max(Arms, -Box(X, Y, 0.2, 0.2))
	end,
	square = function(X, Y)
		return math.abs(Box(X, Y, 0.62, 0.62) - 0.1) - 0.08
	end,
	diamond = function(X, Y)
		local U, V = (X + Y) / math.sqrt(2), (X - Y) / math.sqrt(2)

		return math.abs(Box(U, V, 0.52, 0.52) - 0.06) - 0.08
	end,
	triangle = function(X, Y)
		return math.abs(Triangle(X, Y - 0.12, 0.4)) - 0.08
	end,
	-- Rhythia's built-in circle cursor, as the skin sets name it (not in the list on its own: picked through a set's name)
	["rhythia circle"] = function(X, Y)
		return Circle(X, Y, 0.8)
	end,
	-- a bright middle in a soft halo: the second value is the halo's own alpha
	glow = function(X, Y)
		local D = math.sqrt(X * X + Y * Y)

		return D - 0.22, math.clamp(1 - D, 0, 1) ^ 2.2 * 0.85
	end,
}

local Made: { [string]: Content | false } = {}

local function Draw(Name: string): Content?
	local Shape = Shapes[Name]

	if not Shape then
		return nil
	end

	local Created, Image = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(Side, Side) })
	end)

	if not Created or not Image then
		return nil
	end

	local Pixels = buffer.create(Side * Side * 4)
	local Pixel = 2 / Side

	for PY = 0, Side - 1 do
		for PX = 0, Side - 1 do
			local X, Y = (PX + 0.5) * Pixel - 1, (PY + 0.5) * Pixel - 1
			local Distance, Halo = Shape(X, Y)
			local Alpha = math.clamp(0.5 - Distance / Pixel, 0, 1)

			if Halo then
				Alpha = math.max(Alpha, Halo)
			end

			local At = (PY * Side + PX) * 4

			buffer.writeu8(Pixels, At, 255)
			buffer.writeu8(Pixels, At + 1, 255)
			buffer.writeu8(Pixels, At + 2, 255)
			buffer.writeu8(Pixels, At + 3, math.floor(Alpha * 255 + 0.5))
		end
	end

	local Written = pcall(function()
		Image:WritePixelsBuffer(Vector2.zero, Vector2.new(Side, Side), Pixels)
	end)

	if not Written then
		Image:Destroy()

		return nil
	end

	return Content.fromObject(Image)
end

-- An uploaded copy of each code-drawn picture and of the default skin's cursor.png (tools/aimia/cursor_twins.ps1 draws them with
-- the same shapes): a trail piece is a Beam, and a Beam can't show an EditableImage (it drew plain squares), so the cursor
-- trail's pieces use these.
CursorStyles.Twins = {
	-- (the default skin's cursor.png, pixel for pixel; the drawn ones below match CursorStyles' pictures pixel for pixel too)
	skin = "rbxassetid://94477455631186",
	dot = "rbxassetid://138135548636838",
	circle = "rbxassetid://77298318704389",
	["ring dot"] = "rbxassetid://77824655368623",
	target = "rbxassetid://78235596428658",
	cross = "rbxassetid://124104886196175",
	square = "rbxassetid://93407179825631",
	diamond = "rbxassetid://73105178434507",
	triangle = "rbxassetid://90194287988695",
	glow = "rbxassetid://113391759168152",
	["rhythia circle"] = "rbxassetid://111949111518168",
} :: { [string]: string }

-- The uploaded picture a cursor style's trail pieces show: the style's own picture, its twin, or a set's cursor.
function CursorStyles.TrailContentOf(Name: string?): Content
	local Set = SkinSets.Get(Name)
	local Key = if Set then Set.Cursor else (Name or "skin")
	local Uri = CursorStyles.Pictures[Key] or CursorStyles.Twins[Key]

	if Uri == nil and string.sub(Key, 1, 13) == "rbxassetid://" then
		Uri = Key
	end

	return SkinSets.ContentOf(Uri or CursorStyles.Twins.skin)
end

-- How wide a cursor picture's body is, as a share of its quad: the smooth trail line starts that wide, so it matches the cursor
-- whatever its picture and Cursor Scale (a glow's halo or a ring's hollow middle doesn't count as body).
local Cores: { [string]: number } = {
	skin = 0.55,
	dot = 0.42,
	circle = 0.6,
	["ring dot"] = 0.55,
	target = 0.55,
	cross = 0.4,
	square = 0.55,
	diamond = 0.5,
	triangle = 0.5,
	glow = 0.35,
	["white glow"] = 0.45,
	["pink orb"] = 0.42,
	star = 0.6,
	["rhythia circle"] = 0.8,
	-- the skin sets' own cursor pictures, by image
	["rbxassetid://139950628821895"] = 0.6,
	["rbxassetid://127012157032803"] = 0.55,
	["rbxassetid://110920133133678"] = 0.65,
}

function CursorStyles.CoreOf(Name: string?): number
	local Set = SkinSets.Get(Name)
	local Key = if Set then Set.Cursor else Name

	return if Key then Cores[Key] or 0.55 else 0.55
end

-- How far a hollow cursor's open middle reaches from its centre, as a share of its quad (measured from the drawn shapes and
-- the default skin's cursor.png, a rounded square outline; a square's middle reaches to its inner corners). The smooth trail
-- line starts that far back and the cursor's copies are laid further apart, so the trail doesn't show inside. Solid: 0.
local Holes: { [string]: number } = {
	skin = 0.52,
	circle = 0.35,
	["ring dot"] = 0.35,
	target = 0.38,
	cross = 0.15,
	square = 0.45,
	diamond = 0.36,
	-- (its middle is off centre: a little of it shows toward the bottom corners, and a hair of gap toward the sides)
	triangle = 0.28,
}

function CursorStyles.HoleOf(Name: string?): number
	local Set = SkinSets.Get(Name)
	local Key = if Set then Set.Cursor else Name

	return if Key then Holes[Key] or 0 else 0
end

-- The picture of a style, or nil for the skin's (and when it can't be made).
function CursorStyles.ContentOf(Name: string?): Content?
	-- a skin set's name: the set's own cursor (an uploaded picture, or a style it names)
	local Set = SkinSets.Get(Name)

	if Set then
		if string.sub(Set.Cursor, 1, 13) == "rbxassetid://" then
			return SkinSets.ContentOf(Set.Cursor)
		end

		return CursorStyles.ContentOf(Set.Cursor)
	end

	local Picture = if Name then CursorStyles.Pictures[Name] else nil

	if Picture then
		local Made = PictureContents[Picture]

		if not Made then
			Made = Content.fromUri(Picture)
			PictureContents[Picture] = Made
		end

		return Made
	end

	if Name == nil or Name == "skin" or not Shapes[Name] then
		return nil
	end

	local Cached = Made[Name]

	if not Cached then
		Cached = Draw(Name)

		if Cached then
			Made[Name] = Cached
		end
	end

	return Cached or nil
end

-- The tint of a colour name, or nil for none.
function CursorStyles.ColorOf(Name: string?): Color3?
	local Set = SkinSets.Get(Name)

	if Set then
		return Set.CursorColor
	end

	return if Name then CursorStyles.Colors[Name] else nil
end

return CursorStyles
