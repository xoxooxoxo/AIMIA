--!strict
--!optimize 2

--[[
	The skin sets from the owner's Rhythia skin files (.rhs, Rhythia's Settings > Skins export), added 2026-11-07. A set's pieces
	sit in the game's lists under the set's own name (Custom Map Skins, Menu Skins, Cursor Style, Cursor Color, Colors, Note
	Mesh, Border, Trail Color), so picking the same name in each list gives the whole matching set.

	Representation
		Sets: by name. Background is the colour behind everything; Pictures are drawn over it in order (Fit "cover" fills the
		view, "contain" fits inside it, "box" fits inside a box given as fractions of the view: X, Y its middle, W, H its size).
		Tint multiplies a picture, Opacity is its own. Cursor is a Cursor Style name (code-drawn) or an image id. Colors are note
		colours (hex). Note is a note picture (image id). Border is a border picture (image id) or a drawn border's name, with
		its tint and opacity. Trail is the trail the skin had: colour gradient points (0 at the cursor, 1 at the tail; nil is
		white), fade time, spacing, shrink and opacity.
		Pictures were uploaded as images (each fits in 1024 x 1024, Roblox's limit); asset ids in
		anything rythm related\skins 2026-11-07\asset_ids.txt. A picture bigger than that also has Tiles: pieces of the original
		cut by tools/aimia/skin_tiles.ps1 (X, Y, W, H in the original's pixels; GL, GT the gutter of neighbouring pixels each
		piece carries on its inner sides), drawn edge to edge once all have loaded; Image is then the 1024 copy shown meanwhile,
		and PW, PH are the original's size.

	Design Notes
		Where a skin names one of Rhythia's built-in pictures, which aren't in the files, the nearest one the game has stands in:
		the circle cursor is drawn ("rhythia circle"), "glowy" is the owner's white glow cursor, the plain/rounded/short-rounded
		borders are drawn. Rhythia's built-in square notes and the colour sets "Suspicious 11" and "Neko_Mao's Choice" aren't
		known, so those sets keep the player's own notes or colours there. "Darker Red", "White" and "Lighter Pink" are taken
		at their names.
		Katana's background is a video in the skin file: Video is its Roblox video (the owner's upload, shared with this game; a
		VideoFrame plays it on a loop), with a still frame of it underneath while it loads.
		Pure data and small helpers: nothing here requires the settings (SettingsProfile reads the lists from here).
]]

local SkinSets = {}

export type Tile = {
	Image: string,
	X: number,
	Y: number,
	W: number,
	H: number,
	GL: number?,
	GT: number?,
}

export type Picture = {
	Image: string,
	PW: number,
	PH: number,
	Fit: string,
	X: number?,
	Y: number?,
	W: number?,
	H: number?,
	Tint: Color3?,
	Opacity: number?,
	Rotation: number?,
	Tiles: { Tile }?,
}

export type Trail = {
	Gradient: { { number } }?,
	Fade: number,
	Spacing: number,
	Shrink: boolean,
	Opacity: number,
}

export type Set = {
	Name: string,
	Background: Color3,
	Pictures: { Picture },
	Video: string?,
	Rays: boolean?,
	-- a light background: in a song the HUD's words and bars are near black on it (white would vanish: UI/Game/UIComponent's
	-- Ink). Measured from the pictures 2026-11-07: only d and Dasdaw are light; the rest are dark under their tints.
	Light: boolean?,
	-- a light picture whose bottom is dark (Dasdaw's grass): the HUD's bottom row (health bar, speed, skip, modifier icons) stays
	-- white there
	DarkBottom: boolean?,
	Cursor: string,
	CursorColor: Color3,
	Colors: { string }?,
	Note: string?,
	Border: string?,
	BorderColor: Color3?,
	BorderOpacity: number?,
	Trail: Trail,
}

local function RGB(R: number, G: number, B: number): Color3
	return Color3.fromRGB(R, G, B)
end

local function Gray(Value: number): Color3
	return Color3.fromRGB(Value, Value, Value)
end

-- Rhythia's "Apply Rainbow Gradient" (Settings > Cursor > Cursor Trail > Rainbow Cursor Trail)
SkinSets.Rainbow = {
	{ 0, 255, 0, 0 },
	{ 0.17, 255, 127, 0 },
	{ 0.33, 255, 255, 0 },
	{ 0.5, 0, 255, 0 },
	{ 0.67, 0, 0, 255 },
	{ 0.83, 75, 0, 130 },
	{ 1, 148, 0, 211 },
}

local Circle = "rhythia circle"
local Glowy = "white glow"
local SoftDot = "rbxassetid://139950628821895"
local Squircle = "rbxassetid://135978413237440"
local Vines = "rbxassetid://112601628289411"

SkinSets.Sets = {
	{
		Name = "Brend3r",
		Background = Gray(0),
		Pictures = { { Image = "rbxassetid://74276755177669", PW = 1024, PH = 1024, Fit = "contain" } },
		Cursor = Circle,
		CursorColor = Gray(255),
		Colors = { "#e3bdd5", "#e0d4ca", "#dceac0", "#d6ffbf", "#bffac8", "#a8f5d1", "#92f0da", "#8bfde2", "#8ccce3", "#8d9ce3", "#939ee3", "#9ba6e3", "#ada9dd", "#bfaed7", "#d1b4d3" },
		Border = "plain",
		BorderColor = Gray(255),
		BorderOpacity = 1,
		-- (the skin has its trail switched off, with Rhythia's rainbow set for it)
		Trail = { Gradient = SkinSets.Rainbow, Fade = 0.1, Spacing = 0.4, Shrink = true, Opacity = 0.9 },
	},
	{
		Name = "d",
		Background = Gray(230),
		Light = true,
		Pictures = {},
		Cursor = Circle,
		CursorColor = Gray(0),
		Colors = { "#000000" },
		Trail = { Fade = 0.155, Spacing = 0.05, Shrink = true, Opacity = 0.4 },
	},
	{
		Name = "Dasdaw",
		Background = Gray(0),
		Light = true,
		DarkBottom = true,
		Pictures = { { Image = "rbxassetid://113013977661770", PW = 910, PH = 569, Fit = "cover" } },
		Cursor = Circle,
		CursorColor = Gray(0),
		Colors = { "#000000" },
		Border = "rounded short",
		BorderColor = Gray(109),
		BorderOpacity = 0.91,
		Trail = { Fade = 0.045, Spacing = 0.4, Shrink = true, Opacity = 0.9 },
	},
	{
		Name = "Rei",
		Background = Gray(0),
		-- (the skin also had the Evangelion logo top left; left out at the owner's ask, as the riskiest piece to copyright)
		Pictures = {
			{ Image = "rbxassetid://139849400120023", PW = 561, PH = 784, Fit = "box", X = 0.878, Y = 0.519, W = 0.69, H = 0.969, Tint = Gray(205) },
		},
		Cursor = Glowy,
		CursorColor = Gray(255),
		Note = "rbxassetid://70992033803471",
		Border = "rbxassetid://87649180034173",
		BorderColor = Gray(255),
		BorderOpacity = 0.39,
		Trail = { Gradient = { { 0, 255, 255, 255 }, { 0.413, 255, 255, 255 }, { 1, 255, 224, 174 } }, Fade = 0.02, Spacing = 0.4, Shrink = false, Opacity = 0.6 },
	},
	{
		Name = "Katana",
		Background = Gray(0),
		Pictures = { { Image = "rbxassetid://89355394929627", PW = 1024, PH = 576, Fit = "cover" } },
		Video = "rbxassetid://96449426385379",
		Cursor = Circle,
		CursorColor = Gray(255),
		Colors = { "#ffffff" },
		Border = "rounded",
		BorderColor = Gray(255),
		BorderOpacity = 1,
		Trail = { Gradient = { { 0, 255, 255, 255 }, { 1, 0, 0, 0 } }, Fade = 0.065, Spacing = 0.6, Shrink = true, Opacity = 0.9 },
	},
	{
		Name = "Lappland",
		Background = Gray(0),
		Pictures = {
			{
				Image = "rbxassetid://87038004991105",
				PW = 1365,
				PH = 768,
				Fit = "cover",
				Tiles = {
					{ Image = "rbxassetid://136894815913654", X = 0, Y = 0, W = 684, H = 768 },
					{ Image = "rbxassetid://83110158692087", X = 684, Y = 0, W = 681, H = 768, GL = 4 },
				},
			},
		},
		Cursor = SoftDot,
		CursorColor = Gray(255),
		Note = Squircle,
		Trail = { Fade = 0.16, Spacing = 0.05, Shrink = true, Opacity = 0.07 },
	},
	{
		Name = "Red Moon",
		Background = RGB(244, 18, 18),
		Pictures = { { Image = "rbxassetid://81365670587570", PW = 736, PH = 426, Fit = "cover" } },
		Rays = true,
		Cursor = SoftDot,
		CursorColor = RGB(255, 0, 0),
		Colors = { "#a50f0f" },
		Trail = { Fade = 0.035, Spacing = 0.4, Shrink = false, Opacity = 1 },
	},
	{
		Name = "Rhythm Addict",
		Background = Gray(0),
		Pictures = {
			{
				Image = "rbxassetid://133978160825923",
				PW = 1920,
				PH = 1080,
				Fit = "cover",
				Opacity = 0.305,
				Tiles = {
					{ Image = "rbxassetid://75668485843519", X = 0, Y = 0, W = 960, H = 540 },
					{ Image = "rbxassetid://94111994079552", X = 960, Y = 0, W = 960, H = 540, GL = 4 },
					{ Image = "rbxassetid://107642205618670", X = 0, Y = 540, W = 960, H = 540, GT = 4 },
					{ Image = "rbxassetid://117281185845760", X = 960, Y = 540, W = 960, H = 540, GL = 4, GT = 4 },
				},
			},
		},
		Cursor = "rbxassetid://127012157032803",
		CursorColor = Gray(255),
		Colors = { "#ffc4e1" },
		Border = Vines,
		BorderColor = Gray(255),
		BorderOpacity = 1,
		Trail = { Gradient = { { 0, 0, 250, 255 }, { 1, 255, 255, 255 } }, Fade = 0.1, Spacing = 0.4, Shrink = true, Opacity = 0.9 },
	},
	{
		Name = "Snowcat",
		Background = RGB(75, 8, 8),
		Pictures = { { Image = "rbxassetid://123991709236906", PW = 736, PH = 414, Fit = "cover", Tint = Gray(146) } },
		Cursor = "rbxassetid://110920133133678",
		CursorColor = RGB(185, 184, 158),
		Colors = { "#c5c4ad" },
		Note = Squircle,
		Border = Vines,
		BorderColor = RGB(192, 191, 168),
		BorderOpacity = 1,
		Trail = { Fade = 0.049, Spacing = 0.05, Shrink = true, Opacity = 1 },
	},
	{
		Name = "Syn",
		Background = Gray(255),
		Pictures = { { Image = "rbxassetid://95061662592541", PW = 736, PH = 414, Fit = "cover", Tint = Gray(136), Rotation = -0.54 } },
		Cursor = Glowy,
		CursorColor = Gray(255),
		Trail = { Gradient = SkinSets.Rainbow, Fade = 0.1, Spacing = 0.5, Shrink = true, Opacity = 0.9 },
	},
	{
		Name = "v2",
		Background = Gray(0),
		Pictures = {},
		Cursor = Circle,
		CursorColor = Gray(255),
		Colors = { "#ffffff" },
		Trail = { Fade = 0.2, Spacing = 0.05, Shrink = true, Opacity = 0.4 },
	},
} :: { Set }

local ByName: { [string]: Set } = {}

SkinSets.Names = {} :: { string }

for _, Set in SkinSets.Sets do
	ByName[Set.Name] = Set
	table.insert(SkinSets.Names, Set.Name)
end

-- Sets renamed after they shipped (2026-11-07: the owner named the Evangelion set "Rei"): an old name still finds its set,
-- and SettingsManager.Load and LiveSpectate.ProfileOf turn saved and received old names into the new ones.
SkinSets.Renamed = { Evangelion = "Rei" } :: { [string]: string }

function SkinSets.Get(Name: string?): Set?
	return if Name then ByName[Name] or ByName[SkinSets.Renamed[Name] or ""] else nil
end

-- Extra trail pictures that came in the skins (Rhythia's Custom Trail Image), by the set they came with.
SkinSets.TrailPictures = {
	Dasdaw = "rbxassetid://120248580137118",
	Lappland = "rbxassetid://137336432984829",
} :: { [string]: string }

-- Trail Image: "smooth line", "cursor", then the trail pictures by set.
SkinSets.TrailImageNames = { "smooth line", "cursor", "Dasdaw", "Lappland" }

-- Trail Color: the cursor's colour, white, Rhythia's rainbow, then every set's own trail colour.
SkinSets.TrailColorNames = { "cursor", "white", "rainbow" }

for _, Set in SkinSets.Sets do
	table.insert(SkinSets.TrailColorNames, Set.Name)
end

local Contents: { [string]: Content } = {}

-- The Content of an image id, made once.
function SkinSets.ContentOf(Image: string): Content
	local Made = Contents[Image]

	if not Made then
		Made = Content.fromUri(Image)
		Contents[Image] = Made
	end

	return Made
end

-- A trail picture by its Trail Image name; nil for "smooth line", "cursor" and unknown names.
function SkinSets.TrailPicture(Name: string?): Content?
	local Image = if Name then SkinSets.TrailPictures[Name] else nil

	return if Image then SkinSets.ContentOf(Image) else nil
end

-- The gradient of a Trail Color name: Rhythia's rainbow or a set's own gradient; nil for a single colour.
function SkinSets.TrailGradient(Name: string?): { { number } }?
	if Name == "rainbow" then
		return SkinSets.Rainbow
	end

	local Set = SkinSets.Get(Name)

	return if Set then Set.Trail.Gradient else nil
end

-- The single colour of a Trail Color name: "white" only. A set without a gradient answers nil, so its trail takes the cursor's
-- colour: every skin file has Rhythia's "inherit from cursor" on (a red cursor leaves a red trail).
function SkinSets.TrailSolid(Name: string?): Color3?
	return if Name == "white" then Color3.new(1, 1, 1) else nil
end

-- A gradient's colour at Fraction (0 to 1) as 0..1 red, green, blue: straight between the points, held past the ends.
function SkinSets.GradientAt(Points: { { number } }, Fraction: number): (number, number, number)
	local Count = #Points

	if Count == 0 then
		return 1, 1, 1
	end

	local First, Last = Points[1], Points[Count]

	if Fraction <= First[1] then
		return First[2] / 255, First[3] / 255, First[4] / 255
	end

	if Fraction >= Last[1] then
		return Last[2] / 255, Last[3] / 255, Last[4] / 255
	end

	for Index = 1, Count - 1 do
		local A, B = Points[Index], Points[Index + 1]

		if Fraction <= B[1] then
			local Span = B[1] - A[1]
			local T = if Span > 0 then (Fraction - A[1]) / Span else 0

			return (A[2] + (B[2] - A[2]) * T) / 255, (A[3] + (B[3] - A[3]) * T) / 255, (A[4] + (B[4] - A[4]) * T) / 255
		end
	end

	return Last[2] / 255, Last[3] / 255, Last[4] / 255
end

-- Drawn borders standing in for Rhythia's built-in ones (border.png, rounded.png, roundedshort.png): white lines on a clear
-- square, drawn on the PC (tools/aimia/out/skin_border_*.png) and uploaded.
SkinSets.DrawnBorders = {
	plain = "rbxassetid://128746840075415",
	rounded = "rbxassetid://116255562478132",
	["rounded short"] = "rbxassetid://132811881542980",
} :: { [string]: string }

-- A border picture's side in Godot units (the playfield is 3 across, the grid picture 4): frames sit just outside the notes
-- and just inside the song's progress bar, which a 3.3 frame ran through; the Evangelion corners are drawn wider so their
-- thorns stay round the notes.
local BorderSide = 3.12
local BorderSides = { ["rbxassetid://87649180034173"] = 3.4 }

-- Border: "none", then the sets that have one.
SkinSets.BorderNames = { "none" }

for _, Set in SkinSets.Sets do
	if Set.Border then
		table.insert(SkinSets.BorderNames, Set.Name)
	end
end

-- A Border name's picture, side (Godot units), colour and opacity; nil picture for "none" and unknown names.
function SkinSets.BorderOf(Name: string?): (Content?, number, Color3, number)
	local Set = SkinSets.Get(Name)

	if not Set or not Set.Border then
		return nil, BorderSide, Color3.new(1, 1, 1), 0
	end

	local Image = SkinSets.DrawnBorders[Set.Border] or Set.Border

	return SkinSets.ContentOf(Image), BorderSides[Image] or BorderSide, Set.BorderColor or Color3.new(1, 1, 1), Set.BorderOpacity or 1
end

-- The flat note pictures that came in skins, by set name (Note Mesh options; SkinManager.LoadMesh answers "picture://<set>").
SkinSets.NotePictureNames = {} :: { string }

for _, Set in SkinSets.Sets do
	if Set.Note then
		table.insert(SkinSets.NotePictureNames, Set.Name)
	end
end

function SkinSets.NotePicture(Name: string?): Content?
	local Set = SkinSets.Get(Name)

	return if Set and Set.Note then SkinSets.ContentOf(Set.Note) else nil
end

-- Custom Trails: "your own", then every set: picking one loads the set's trail into the trail settings (SettingsProfile).
SkinSets.TrailPresetNames = { "your own" }

for _, Set in SkinSets.Sets do
	table.insert(SkinSets.TrailPresetNames, Set.Name)
end

return SkinSets
