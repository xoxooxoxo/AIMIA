--!optimize 2

--[[
	The animated backgrounds of the Menu Space and Game Space settings. Each is drawn with plain GUI objects in a container
	frame: on the screen behind the menus (UI/SceneManager) and on a quad that follows the camera in a song (UI/Scenes/Game), so
	a background looks the same in both. They move on their own and lean on the music (the analyzer's bass, mids and highs);
	in a song they take the colour of the last hit, and stay dimmer, with the middle quieter still, so notes read first.

	Design Notes
		No background makes its own RunService connection: the owner calls Process from Nodes, which stops while AIMIA is closed
		(Frames.Paused).
		Glow is drawn, not post-processed: a soft wider copy behind each line or outline.
		Colours come from a palette of three made from the accent, and go through Fix: the world shows its UI darker than given
		(Game/View/Tone), the screen doesn't.
		Positions are in the container's pixels, read each frame, so a resized window or canvas just works.
]]

local AssetService = game:GetService("AssetService")

local RobloxBackend = require("../Audio/RobloxBackend")
local SkinSets = require("../Skinning/SkinSets")

local Backgrounds = {}

-- A soft white picture made once, in memory: a round glow fading from the middle. Nil when the device won't make it (then
-- glows are drawn with plain shapes).
local Textures: { Disc: Content? }? = nil
local TextureSide = 128

local function MakeTexture(Alpha: (number) -> number): Content?
	local Made, Image = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(TextureSide, TextureSide) })
	end)

	if not Made or not Image then
		return nil
	end

	local Pixels = buffer.create(TextureSide * TextureSide * 4)
	local Half = TextureSide / 2

	for Y = 0, TextureSide - 1 do
		for X = 0, TextureSide - 1 do
			local DX, DY = (X + 0.5) / Half - 1, (Y + 0.5) / Half - 1
			local At = (Y * TextureSide + X) * 4

			buffer.writeu8(Pixels, At, 255)
			buffer.writeu8(Pixels, At + 1, 255)
			buffer.writeu8(Pixels, At + 2, 255)
			buffer.writeu8(Pixels, At + 3, math.floor(math.clamp(Alpha(math.sqrt(DX * DX + DY * DY)), 0, 1) * 255 + 0.5))
		end
	end

	local Written = pcall(function()
		Image:WritePixelsBuffer(Vector2.zero, Vector2.new(TextureSide, TextureSide), Pixels)
	end)

	return if Written then Content.fromObject(Image) else nil
end

local function Soft()
	if Textures == nil then
		Textures = {
			Disc = MakeTexture(function(Distance: number): number
				local T = math.clamp(1 - Distance, 0, 1)

				return T * T * T * (T * (T * 6 - 15) + 10)
			end),
		}
	end

	return Textures :: { Disc: Content? }
end

-- The setting values, in the order the lists show them.
-- (2026-11-07: the fast moving ones, tunnel, vortex, warp, spectrum, prism and pulse, were taken out; Database/Settings/
-- SettingsProfile's RetiredSpaces turns a saved one back to the skin's)
Backgrounds.Names = { "aurora", "horizon", "drift" }

local Known = {}

for _, Name in Backgrounds.Names do
	Known[Name] = true
end

-- the skin sets' backgrounds (Skinning/SkinSets), by set name
for _, Name in SkinSets.Names do
	Known[Name] = true
end

function Backgrounds.Has(Name: string?): boolean
	return Name ~= nil and Known[Name] == true
end

-- Each background's own colour when nothing gives one (no hit colour, Space Color on default).
local Defaults = {
	aurora = Color3.fromRGB(70, 230, 170),
	horizon = Color3.fromRGB(255, 70, 190),
	drift = Color3.fromRGB(90, 140, 255),
}

local White = Color3.new(1, 1, 1)

local function Make(Class: string, Parent: Instance, Props: { [string]: any }): any
	local Object = Instance.new(Class)

	for Key, Value in Props do
		(Object :: any)[Key] = Value
	end

	Object.Parent = Parent

	return Object
end

local function Seq(...: number): NumberSequence
	local Values = { ... }
	local Points = {}

	for Index = 1, #Values, 2 do
		table.insert(Points, NumberSequenceKeypoint.new(Values[Index], Values[Index + 1]))
	end

	return NumberSequence.new(Points)
end

local function Blank(Parent: Instance, ZIndex: number): Frame
	return Make("Frame", Parent, {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = ZIndex,
	})
end

local function Bar(Parent: Instance, ZIndex: number): Frame
	local Fill = Blank(Parent, ZIndex)

	Fill.BackgroundTransparency = 1
	Fill.BackgroundColor3 = White

	return Fill
end

local function Dot(Parent: Instance, ZIndex: number): Frame
	local Fill = Bar(Parent, ZIndex)

	Make("UICorner", Fill, { CornerRadius = UDim.new(0.5, 0) })

	return Fill
end

local function Smooth(Edge0: number, Edge1: number, X: number): number
	local T = math.clamp((X - Edge0) / (Edge1 - Edge0), 0, 1)

	return T * T * (3 - 2 * T)
end

-- In a song the middle (where the notes are) is drawn at a quarter strength, rising to full past the grid.
local function Clear(State, Distance: number, H: number): number
	if not State.Game then
		return 1
	end

	return 0.25 + 0.75 * Smooth(H * 0.3, H * 0.52, Distance)
end

-- A line with a soft glow behind it.
local function NewLine(Parent: Instance, ZIndex: number)
	local Glow = Bar(Parent, ZIndex)

	Make("UIGradient", Glow, { Rotation = 90, Transparency = Seq(0, 1, 0.5, 0.35, 1, 1) })

	return { Glow = Glow, Core = Bar(Parent, ZIndex + 1) }
end

local function PlaceLine(Line, X1: number, Y1: number, X2: number, Y2: number, Thick: number, Color: Color3, Alpha: number)
	local DX, DY = X2 - X1, Y2 - Y1
	local Length = math.sqrt(DX * DX + DY * DY)
	local Where = UDim2.fromOffset((X1 + X2) / 2, (Y1 + Y2) / 2)
	local Turn = math.deg(math.atan2(DY, DX))
	local Core, Glow = Line.Core, Line.Glow

	Core.Position = Where
	Core.Rotation = Turn
	Core.Size = UDim2.fromOffset(Length, Thick)
	Core.BackgroundColor3 = Color
	Core.BackgroundTransparency = 1 - Alpha
	Glow.Position = Where
	Glow.Rotation = Turn
	Glow.Size = UDim2.fromOffset(Length + Thick * 2, Thick * 6)
	Glow.BackgroundColor3 = Color
	Glow.BackgroundTransparency = 1 - Alpha * 0.32
end

-- An outline (a rounded square) with a glow: a wide faint stroke behind a thin one, both painted by gradients.
local function NewOutline(Parent: Instance, ZIndex: number, Corner: number)
	local function Stroked(Layer: number)
		local Shape = Blank(Parent, Layer)

		Make("UICorner", Shape, { CornerRadius = UDim.new(Corner, 0) })

		local Stroke = Make("UIStroke", Shape, { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = White })

		return { Shape = Shape, Stroke = Stroke, Paint = Make("UIGradient", Stroke, {}) }
	end

	local Glow = Stroked(ZIndex)

	return { Glow = Glow, Core = Stroked(ZIndex + 1) }
end

local function PlaceOutline(Outline, X: number, Y: number, Size: number, Turn: number, Thick: number, Alpha: number, Paint: number)
	local Where = UDim2.fromOffset(X, Y)
	local Box = UDim2.fromOffset(Size, Size)
	local Core, Glow = Outline.Core, Outline.Glow

	Core.Shape.Position = Where
	Core.Shape.Size = Box
	Core.Shape.Rotation = Turn
	Core.Paint.Rotation = Paint
	Core.Stroke.Thickness = Thick
	Core.Stroke.Transparency = 1 - Alpha
	Glow.Shape.Position = Where
	Glow.Shape.Size = Box
	Glow.Shape.Rotation = Turn
	Glow.Paint.Rotation = Paint
	Glow.Stroke.Thickness = Thick * 3.5
	Glow.Stroke.Transparency = 1 - Alpha * 0.18
end

local function PaintOutline(Outline, Colors: ColorSequence)
	Outline.Glow.Paint.Color = Colors
	Outline.Core.Paint.Color = Colors
end

-- A soft round glow: the soft disc picture stretched to Width by Height, or stacked faint discs without it.
local function NewBlob(Parent: Instance, ZIndex: number, Layers: number)
	local Disc = Soft().Disc

	if Disc then
		return {
			Picture = Make("ImageLabel", Parent, {
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				ZIndex = ZIndex,
				ImageContent = Disc,
				ImageTransparency = 1,
			}),
		}
	end

	local Discs = {}

	for _ = 1, Layers do
		table.insert(Discs, Dot(Parent, ZIndex))
	end

	return { Discs = Discs }
end

local function PlaceBlob(Blob, X: number, Y: number, Width: number, Height: number, Color: Color3, Alpha: number)
	if Blob.Picture then
		Blob.Picture.Position = UDim2.fromOffset(X, Y)
		Blob.Picture.Size = UDim2.fromOffset(Width, Height)
		Blob.Picture.ImageColor3 = Color
		Blob.Picture.ImageTransparency = 1 - math.clamp(Alpha * 1.6, 0, 1)

		return
	end

	local Count = #Blob.Discs

	for Index, Disc in Blob.Discs do
		local Share = Index / Count

		Disc.Position = UDim2.fromOffset(X, Y)
		Disc.Size = UDim2.fromOffset(Width * Share, Height * Share)
		Disc.BackgroundColor3 = Color
		Disc.BackgroundTransparency = 1 - Alpha / Count
	end
end

-- Twinkling points, fixed in place.
local function NewStars(State, Count: number, Top: number)
	local Stars = {}

	for _ = 1, Count do
		table.insert(Stars, {
			Dot = Dot(State.Container, 1),
			X = math.random(),
			Y = math.random() * Top,
			Size = 1 + math.random() * 2.2,
			Phase = math.random() * 6.28,
			Rate = 0.5 + math.random() * 1.8,
		})
	end

	return Stars
end

local function StepStars(State, Stars, W: number, H: number)
	for _, Star in Stars do
		local Twinkle = 0.5 + 0.5 * math.sin(State.Clock * Star.Rate + Star.Phase)
		local Size = Star.Size * H / 900

		-- (a star holds still: it's placed, and its share of the middle's dimming worked out, only when the canvas changes size;
		-- from frame to frame only its twinkle changes)
		if Star.W ~= W or Star.H ~= H then
			Star.W, Star.H = W, H
			Star.Clear = Clear(State, math.abs(Star.Y * H - H / 2) + math.abs(Star.X * W - W / 2) * 0.5, H)
			Star.Dot.Position = UDim2.fromOffset(Star.X * W, Star.Y * H)
			Star.Dot.Size = UDim2.fromOffset(Size, Size)
		end

		Star.Dot.BackgroundTransparency = 1 - (0.2 + 0.6 * Twinkle) * State.Strength * (0.7 + 0.3 * State.High.Value) * Star.Clear
	end
end

-- A loudness that follows the music: the band's peak over a ceiling that falls slowly, eased in fast and out slowly so big
-- areas never flash at note rate.
local function NewBand(Low: number, High: number)
	return { Low = Low, High = High, Ceiling = 0.0015, Value = 0, Raw = 0 }
end

local function StepBand(Band, Delta: number)
	local Raw = RobloxBackend.Magnitude(Band.Low, Band.High)

	if Raw ~= Raw then
		Raw = 0
	end

	Band.Ceiling = math.max(Raw, Band.Ceiling - Band.Ceiling * math.min(1, Delta * 0.35), 0.0015)

	local Level = Raw / Band.Ceiling

	Band.Raw = Level
	Band.Value += (Level - Band.Value) * math.min(1, Delta * (if Level > Band.Value then 14 else 3))
end

local Builders = {}
local Steppers = {}

-- AURORA: soft curtains of colour waving over a starry dark, the slowest of them all.
Builders.aurora = function(State)
	State.Twinkles = NewStars(State, if State.Low then 25 else 55, 0.7)
	State.Veils = {}

	for Index = 1, 4 do
		local Veil = Bar(State.Container, 2)
		local Paint = Make("UIGradient", Veil, { Rotation = 90, Transparency = Seq(0, 1, 0.18, 1, 0.38, 0.8, 0.55, 0.4, 0.75, 0.85, 0.9, 1, 1, 1) })

		table.insert(State.Veils, { Veil = Veil, Paint = Paint, Period = ({ 17, 23, 31, 41 })[Index], Shift = Index * 1.7 })
	end
end

Steppers.aurora = function(State, Delta: number, W: number, H: number)
	StepStars(State, State.Twinkles, W, H)

	for Index, Item in State.Veils do
		local Phase = State.Clock * math.pi * 2 / Item.Period + Item.Shift
		local Wave = math.sin(Phase)

		if State.Repaint then
			Item.Paint.Color = if Index == 4 then State.Far elseif Index % 2 == 0 then State.Loop else State.Sweep
		end

		Item.Veil.Position = UDim2.fromOffset(W / 2 + Wave * W * 0.1, H * (0.18 + 0.13 * Index) + math.cos(Phase * 0.8) * H * 0.05)
		Item.Veil.Size = UDim2.fromOffset(W * 1.6, H * (0.38 + 0.12 * math.sin(Phase * 1.4)))
		Item.Veil.Rotation = -8 + 6 * Index + 7 * math.sin(Phase * 0.6)
		Item.Veil.BackgroundTransparency = 1 - (0.42 + 0.22 * State.Bass.Value) * State.Strength * (if State.Game then 0.6 else 1)
		Item.Paint.Offset = Vector2.new(0, 0.06 * math.sin(Phase * 1.9))
	end
end

-- HORIZON: a glowing grid floor running to a horizon, under a striped sun in a starry sky.
Builders.horizon = function(State)
	State.SkyWash = Bar(State.Container, 1)
	State.SkyPaint = Make("UIGradient", State.SkyWash, { Rotation = 90, Transparency = Seq(0, 1, 0.6, 0.75, 1, 0.3) })
	State.Twinkles = NewStars(State, if State.Low then 20 else 40, 0.5)
	State.Halo = NewBlob(State.Container, 2, 6)
	State.Sun = Dot(State.Container, 3)
	State.SunPaint = Make("UIGradient", State.Sun, { Rotation = 90 })
	State.Floor = Bar(State.Container, 4)
	State.FloorPaint = Make("UIGradient", State.Floor, { Rotation = 90 })
	State.Edge = NewLine(State.Container, 6)
	State.Rows = {}
	State.Rails = {}

	for Index = 1, if State.Low then 8 else 14 do
		table.insert(State.Rows, { Line = NewLine(State.Container, 5), Depth = Index / (if State.Low then 8 else 14) })
	end

	local Along = if State.Low then 11 else 19

	for Index = 1, Along do
		table.insert(State.Rails, { Line = NewLine(State.Container, 5), Spread = (Index - (Along + 1) / 2) / ((Along - 1) / 2) })
	end
end

Steppers.horizon = function(State, Delta: number, W: number, H: number)
	local Horizon = H * 0.62
	local Speed = (0.22 + 0.55 * State.Bass.Value) * State.Moving
	local Dim = if State.Game then 0.55 else 1

	if State.Repaint then
		State.SkyPaint.Color = ColorSequence.new(State.C, State.A)
		State.SunPaint.Color = ColorSequence.new(State.Warm, State.A)
		State.FloorPaint.Color = ColorSequence.new(Color3.new(0, 0, 0), State.Deep)
	end

	State.SkyWash.Position = UDim2.fromOffset(W / 2, Horizon / 2)
	State.SkyWash.Size = UDim2.fromOffset(W, Horizon)
	State.SkyWash.BackgroundTransparency = 1 - 0.5 * State.Strength * Dim
	StepStars(State, State.Twinkles, W, H)

	local Sun = H * (0.4 + 0.02 * State.Bass.Value)
	local SunY = Horizon - Sun * 0.18

	PlaceBlob(State.Halo, W / 2, SunY, Sun * 2.1, Sun * 2.1, State.A, (0.3 + 0.25 * State.Bass.Value) * State.Strength * Dim)
	State.Sun.Position = UDim2.fromOffset(W / 2, SunY)
	State.Sun.Size = UDim2.fromOffset(Sun, Sun)
	State.Sun.BackgroundTransparency = 1 - 0.95 * State.Strength * Dim

	-- the gaps in the sun's lower half slide down and widen as they go
	local Points = { NumberSequenceKeypoint.new(0, 0) }
	local Slide = (State.Clock * 0.05) % 0.1

	for Band = 0, 3 do
		local Top = 0.4 + Band * 0.1 + Slide
		local Gap = 0.012 + 0.018 * Band

		if Top + Gap < 0.995 then
			table.insert(Points, NumberSequenceKeypoint.new(Top, 0))
			table.insert(Points, NumberSequenceKeypoint.new(Top + 0.001, 1))
			table.insert(Points, NumberSequenceKeypoint.new(Top + Gap, 1))
			table.insert(Points, NumberSequenceKeypoint.new(Top + Gap + 0.001, 0))
		end
	end

	table.insert(Points, NumberSequenceKeypoint.new(1, 0))
	State.SunPaint.Transparency = NumberSequence.new(Points)

	-- The floor and the horizon's line hold still: placed only when the canvas changes size, and the line recoloured when the
	-- palette changes (in a song a hit colour easing in repaints it often), not rewritten every frame.
	if State.FloorW ~= W or State.FloorH ~= H then
		State.FloorW, State.FloorH = W, H
		State.Floor.Position = UDim2.fromOffset(W / 2, (Horizon + H) / 2)
		State.Floor.Size = UDim2.fromOffset(W, H - Horizon)
		State.Floor.BackgroundTransparency = 0
		PlaceLine(State.Edge, 0, Horizon, W, Horizon, math.max(1, 2.5 * H / 900), State.A:Lerp(White, 0.3), 0.9 * State.Strength * Dim)
	elseif State.Repaint then
		local Tint = State.A:Lerp(White, 0.3)

		State.Edge.Core.BackgroundColor3 = Tint
		State.Edge.Glow.BackgroundColor3 = Tint
	end

	for _, Row in State.Rows do
		Row.Depth -= Delta * Speed

		if Row.Depth <= 0.05 then
			Row.Depth += 1
		end

		local Y = Horizon + (H - Horizon) * (0.05 / Row.Depth)
		local Near = Smooth(1, 0.25, Row.Depth)

		PlaceLine(Row.Line, 0, Y, W, Y, math.max(1, 2.2 * H / 900 * (0.4 + Near)), State.A, (0.15 + 0.65 * Near) * State.Strength * Dim)
	end

	-- The rails hold still: placed only when the canvas changes size and recoloured when the palette changes. Placing them every
	-- frame was ten property writes a rail.
	if State.RailsW ~= W or State.RailsH ~= H then
		State.RailsW, State.RailsH = W, H

		for _, Rail in State.Rails do
			PlaceLine(Rail.Line, W / 2, Horizon, W / 2 + Rail.Spread * W * 1.5, H, math.max(1, 1.8 * H / 900), State.B, 0.55 * State.Strength * Dim)
		end
	elseif State.Repaint then
		for _, Rail in State.Rails do
			Rail.Line.Core.BackgroundColor3 = State.B
			Rail.Line.Glow.BackgroundColor3 = State.B
		end
	end
end

-- DRIFT: glassy rounded squares rising and turning at three depths, with sparks.
Builders.drift = function(State)
	State.Floaters = {}
	State.Sparks = {}

	for _ = 1, if State.Low then 9 else 16 do
		local Outline = NewOutline(State.Container, 2, 0.3)
		local Fill = Make("Frame", Outline.Core.Shape, { BackgroundColor3 = White, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) })

		Make("UICorner", Fill, { CornerRadius = UDim.new(0.3, 0) })
		Make("UIGradient", Fill, { Rotation = 45, Transparency = Seq(0, 0.2, 1, 1) })
		table.insert(State.Floaters, { Outline = Outline, Fill = Fill })
	end

	for _ = 1, if State.Low then 10 else 24 do
		table.insert(State.Sparks, { Dot = Dot(State.Container, 1) })
	end
end

local function Respawn(Floater, Age: number?)
	Floater.Age = Age or 0
	Floater.Layer = math.random(3)
	Floater.Life = 12 + math.random() * 8
	Floater.X = math.random()
	Floater.Scale = (0.05 + math.random() * 0.06) * Floater.Layer
	Floater.Turn = math.random() * 90
	Floater.Spin = (math.random() - 0.5) * 40
	Floater.Rise = 0.035 * Floater.Layer + math.random() * 0.02
	Floater.Pick = math.random(3)
end

Steppers.drift = function(State, Delta: number, W: number, H: number)
	local Tints = { State.A, State.B, State.C }

	for _, Floater in State.Floaters do
		if Floater.X == nil then
			Respawn(Floater, math.random() * 12)
		end

		Floater.Age += Delta * (1 + 0.8 * State.Bass.Value) * State.Moving

		if Floater.Age >= Floater.Life or H * (1.1 - Floater.Rise * Floater.Age) < -H * 0.2 then
			Respawn(Floater)
		end

		local Share = Floater.Age / Floater.Life
		local Seen = Smooth(0, 0.15, Share) * Smooth(1, 0.8, Share)
		local Size = H * Floater.Scale * (1 + 0.05 * State.Bass.Value)
		local X, Y = Floater.X * W, H * (1.1 - Floater.Rise * Floater.Age)
		local Alpha = Seen * (0.25 + 0.2 * Floater.Layer) * State.Strength * Clear(State, math.abs(Y - H / 2) + math.abs(X - W / 2) * 0.6, H)

		Floater.Turn += Delta * Floater.Spin * State.Moving

		if State.Repaint or Floater.Painted ~= Floater.Pick then
			local Tint = Tints[Floater.Pick]

			PaintOutline(Floater.Outline, ColorSequence.new(Tint:Lerp(White, 0.4), Tint))
			Floater.Fill.BackgroundColor3 = Tint
			Floater.Painted = Floater.Pick
		end

		PlaceOutline(Floater.Outline, X, Y, Size, Floater.Turn, math.max(1, 2 * H / 900), Alpha, 45)
		Floater.Fill.BackgroundTransparency = 1 - Alpha * 0.25
	end

	for Index, Spark in State.Sparks do
		local Rate = 0.03 + (Index % 5) * 0.012
		local Y = (1.05 - ((State.Clock * Rate + Index * 0.137) % 1.1)) * H
		local X = ((Index * 0.618) % 1) * W + math.sin(State.Clock * 0.7 + Index) * W * 0.02
		local Size = (1.5 + (Index % 3)) * H / 900

		Spark.Dot.Position = UDim2.fromOffset(X, Y)
		-- (a spark's size changes only with the canvas and its colour only with the palette, which is also painted on the first
		-- frame: neither is rewritten every frame)
		if Spark.H ~= H then
			Spark.H = H
			Spark.Dot.Size = UDim2.fromOffset(Size, Size)
		end

		if State.Repaint then
			Spark.Dot.BackgroundColor3 = Tints[Index % 3 + 1]:Lerp(White, 0.5)
		end
		Spark.Dot.BackgroundTransparency = 1 - (0.35 + 0.4 * State.High.Value) * State.Strength * Clear(State, math.abs(Y - H / 2) + math.abs(X - W / 2) * 0.6, H)
	end
end

-- SKIN SETS (Skinning/SkinSets): the set's colour, its pictures laid out as Rhythia's background editor places them (cover fills
-- the view, contain fits inside it, box fits inside a part of it), its video when it has one, and light rays when the skin had them.
-- Pictures keep the skin's own look: no hit colour and no dimming in a song.
local function NewSkinPicture(State, Picture, ZIndex: number): ImageLabel
	return Make("ImageLabel", State.Container, {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		-- (placed by its corner on whole pixels; a turned picture turns round its middle)
		AnchorPoint = if (Picture.Rotation or 0) == 0 then Vector2.zero else Vector2.new(0.5, 0.5),
		ZIndex = ZIndex,
		ImageContent = SkinSets.ContentOf(Picture.Image),
		ScaleType = Enum.ScaleType.Stretch,
		ImageColor3 = State.Fix(Picture.Tint or White),
		ImageTransparency = 1 - (Picture.Opacity or 1),
		Rotation = Picture.Rotation or 0,
	})
end

-- A big picture's pieces (SkinSets Tiles), each showing only its own part of its file (its gutter of neighbouring pixels is
-- there so the edges blend true), hidden until every piece has loaded: the 1024 copy shows meanwhile.
local function NewSkinTiles(State, Picture, ZIndex: number, Copy: ImageLabel)
	local Pieces = {}
	local Wanted = {}

	for _, Tile in Picture.Tiles do
		local Label = Make("ImageLabel", State.Container, {
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.zero,
			ZIndex = ZIndex,
			ImageContent = SkinSets.ContentOf(Tile.Image),
			ImageRectOffset = Vector2.new(Tile.GL or 0, Tile.GT or 0),
			ImageRectSize = Vector2.new(Tile.W, Tile.H),
			ScaleType = Enum.ScaleType.Stretch,
			ImageColor3 = Copy.ImageColor3,
			-- (all but clear, so it is drawn, and loads, while the copy still shows)
			ImageTransparency = 0.999,
		})

		table.insert(Pieces, { Label = Label, Tile = Tile })
		table.insert(Wanted, Label)
	end

	task.spawn(function()
		pcall(function()
			game:GetService("ContentProvider"):PreloadAsync(Wanted)
		end)
	end)

	return Pieces
end

local function BuildSkin(State)
	local Set = SkinSets.Get(State.Name)

	State.Set = Set
	State.Fill = Make("Frame", State.Container, {
		BackgroundColor3 = State.Fix(Set.Background),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
	})
	State.Shots = {}

	for Index, Picture in Set.Pictures do
		local Label = NewSkinPicture(State, Picture, 1 + Index)
		local Shot = { Label = Label, Picture = Picture, Tiles = nil, Sharp = false }

		-- (a small view, such as the settings preview card, keeps the copy: the pieces wouldn't show any sharper there)
		if Picture.Tiles and not State.Low and (Picture.Rotation or 0) == 0 then
			Shot.Tiles = NewSkinTiles(State, Picture, 1 + Index, Label)
		end

		table.insert(State.Shots, Shot)
	end

	-- (the still picture stays under the video, so something shows while it loads)
	if Set.Video then
		local Made, Video = pcall(function()
			return Make("VideoFrame", State.Container, {
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				ZIndex = 4,
				Looped = true,
				Volume = 0,
				Video = Set.Video,
			})
		end)

		if Made and Video then
			State.Video = Video
			pcall(function()
				Video:Play()
			end)
		end
	end

	if Set.Rays then
		State.Rays = {}

		for Index = 1, 9 do
			local Ray = Bar(State.Container, 6)

			-- a bar across the middle, seen only on one side: a ray from the middle (GUI turns round an object's own middle)
			Make("UIGradient", Ray, { Transparency = Seq(0, 1, 0.5, 1, 0.52, 0.35, 1, 1) })
			table.insert(State.Rays, { Ray = Ray, Turn = (Index - 1) * 40 + math.random() * 12, Spin = if Index % 2 == 0 then 3 else -2 })
		end
	end

	-- (a light skin's song needs nothing here: the HUD's words and bars turn near black on it, UI/Game/UIComponent's Ink)

	State.Laid = Vector2.zero
end

local function StepSkin(State, Delta: number, W: number, H: number)
	-- Space Color washes the skin's pictures and colour (it arrives as the accent through Process; white is none)
	local Accent = State.Painted

	if State.SkinAccent ~= Accent then
		State.SkinAccent = Accent

		local Plain = Accent.R > 0.99 and Accent.G > 0.99 and Accent.B > 0.99

		local function Wash(Color: Color3): Color3
			if Plain then
				return Color
			end

			return Color:Lerp(Color3.new(Color.R * Accent.R, Color.G * Accent.G, Color.B * Accent.B), 0.65)
		end

		State.Fill.BackgroundColor3 = State.Fix(Wash(State.Set.Background))
		State.RayTint = State.Fix(if Plain then Color3.fromRGB(255, 47, 47) else Accent)

		for _, Shot in State.Shots do
			local Tint = State.Fix(Wash(Shot.Picture.Tint or White))

			Shot.Label.ImageColor3 = Tint

			if Shot.Tiles then
				for _, Piece in Shot.Tiles do
					Piece.Label.ImageColor3 = Tint
				end
			end
		end
	end

	-- A big picture's pieces take over from its copy once every one has loaded, all at once (no half-sharp picture), and the
	-- copy goes, or it would show through a see-through picture. A piece that never loads leaves the copy.
	for _, Shot in State.Shots do
		if Shot.Tiles and not Shot.Sharp then
			local Ready = true

			for _, Piece in Shot.Tiles do
				if not Piece.Label.IsLoaded then
					Ready = false

					break
				end
			end

			if Ready then
				local Seen = 1 - (Shot.Picture.Opacity or 1)

				Shot.Sharp = true

				for _, Piece in Shot.Tiles do
					Piece.Label.ImageTransparency = Seen
				end

				Shot.Label.Visible = false
			end
		end
	end

	-- The pictures fit the view on the screen (View: in a song the canvas runs a little past the screen on every side), and
	-- land on whole pixels: a picture shown at its own size is then drawn pixel for pixel, and pieces meet without a seam.
	local View = State.View
	local VW, VH = if View then View.X else W, if View then View.Y else H

	if State.Laid.X ~= W or State.Laid.Y ~= H or State.LaidVW ~= VW or State.LaidVH ~= VH then
		State.Laid = Vector2.new(W, H)
		State.LaidVW, State.LaidVH = VW, VH

		local OX, OY = (W - VW) / 2, (H - VH) / 2

		for _, Shot in State.Shots do
			local Picture = Shot.Picture
			local Scale, CX, CY

			if Picture.Fit == "box" then
				Scale = math.min(VW * (Picture.W or 1) / Picture.PW, VH * (Picture.H or 1) / Picture.PH)
				CX, CY = OX + VW * (Picture.X or 0.5), OY + VH * (Picture.Y or 0.5)
			elseif Picture.Fit == "contain" then
				Scale = math.min(VW / Picture.PW, VH / Picture.PH)
				CX, CY = OX + VW / 2, OY + VH / 2
			else
				-- (a turned picture grows a little so its corners stay out of the view)
				Scale = math.max(VW / Picture.PW, VH / Picture.PH) * (1 + math.abs(math.rad(Picture.Rotation or 0)) * 2)
				CX, CY = OX + VW / 2, OY + VH / 2
			end

			local SW, SH = Picture.PW * Scale, Picture.PH * Scale

			if (Picture.Rotation or 0) ~= 0 then
				Shot.Label.Position = UDim2.fromOffset(math.round(CX), math.round(CY))
				Shot.Label.Size = UDim2.fromOffset(math.round(SW), math.round(SH))
			else
				local L, T = math.round(CX - SW / 2), math.round(CY - SH / 2)

				Shot.Label.Position = UDim2.fromOffset(L, T)
				Shot.Label.Size = UDim2.fromOffset(math.round(CX + SW / 2) - L, math.round(CY + SH / 2) - T)

				-- (each piece's edges are rounded from the picture's one corner, so neighbours share an edge exactly)
				if Shot.Tiles then
					for _, Piece in Shot.Tiles do
						local Tile = Piece.Tile
						local X0, X1 = L + math.round(Tile.X * Scale), L + math.round((Tile.X + Tile.W) * Scale)
						local Y0, Y1 = T + math.round(Tile.Y * Scale), T + math.round((Tile.Y + Tile.H) * Scale)

						Piece.Label.Position = UDim2.fromOffset(X0, Y0)
						Piece.Label.Size = UDim2.fromOffset(X1 - X0, Y1 - Y0)
					end
				end
			end
		end

		if State.Video then
			local Scale = math.max(VW / 16, VH / 9)

			State.Video.Position = UDim2.fromOffset(W / 2, H / 2)
			State.Video.Size = UDim2.fromOffset(16 * Scale, 9 * Scale)
		end
	end

	if State.Rays then
		local Reach = math.sqrt(W * W + H * H)
		local Tint = State.RayTint

		for _, Item in State.Rays do
			Item.Turn += Delta * Item.Spin * State.Moving
			Item.Ray.Rotation = Item.Turn

			-- (a ray only turns: where it is, its size and its colour change with the canvas and the Space Color, so they aren't
			-- rewritten every frame)
			if Item.W ~= W or Item.H ~= H then
				Item.W, Item.H = W, H
				Item.Ray.Position = UDim2.fromOffset(W / 2, H / 2)
				Item.Ray.Size = UDim2.fromOffset(Reach, H * 0.06)
				Item.Ray.BackgroundTransparency = 0.89
			end

			if Item.Tint ~= Tint then
				Item.Tint = Tint
				Item.Ray.BackgroundColor3 = Tint
			end
		end
	end
end

local function Identity(Color: Color3): Color3
	return Color
end

-- The palette of an accent: the accent and two neighbours on the colour wheel, kept bright enough to glow.
local function Repaint(State, Accent: Color3)
	local Hue, Saturation, Value = Accent:ToHSV()
	local Fix = State.Fix

	Saturation = if Saturation < 0.2 then Saturation else math.max(Saturation, 0.5)
	Value = math.max(Value, 0.8)

	local A = Color3.fromHSV(Hue, Saturation, Value)
	local B = Color3.fromHSV((Hue + 0.08) % 1, Saturation, Value)
	local C = Color3.fromHSV((Hue - 0.11) % 1, math.min(1, Saturation + 0.1), Value)

	State.A, State.B, State.C = Fix(A), Fix(B), Fix(C)
	State.D = Fix(Color3.fromHSV((Hue + 0.42) % 1, math.max(Saturation, 0.45), Value))
	State.Warm = Fix(A:Lerp(Color3.fromRGB(255, 190, 80), 0.6))
	State.Far = ColorSequence.new({
		ColorSequenceKeypoint.new(0, State.D),
		ColorSequenceKeypoint.new(0.5, State.B),
		ColorSequenceKeypoint.new(1, State.D),
	})
	State.Deep = Fix(A:Lerp(Color3.new(0, 0, 0), 0.82))
	State.Loop = ColorSequence.new({
		ColorSequenceKeypoint.new(0, State.A),
		ColorSequenceKeypoint.new(0.33, State.B),
		ColorSequenceKeypoint.new(0.66, State.C),
		ColorSequenceKeypoint.new(1, State.A),
	})
	State.Sweep = ColorSequence.new({
		ColorSequenceKeypoint.new(0, State.C),
		ColorSequenceKeypoint.new(0.5, State.A),
		ColorSequenceKeypoint.new(1, State.B),
	})
	State.Painted = Accent
	State.Repaint = true
end

-- Starts the background Name in Container (filled, clipped). Options: Fix (colour correction for where it's drawn), Low (fewer
-- pieces), Game (a song: dimmer, with the middle quieter).
function Backgrounds.New(Name: string, Container: Frame, Options: { Fix: ((Color3) -> Color3)?, Low: boolean?, Game: boolean? }?)
	local Settings = Options or {}
	local Layer = Make("Frame", Container, {
		Name = "Background",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
		ZIndex = Container.ZIndex,
	})
	local State = {
		Name = Name,
		Container = Layer,
		Fix = Settings.Fix or Identity,
		Low = Settings.Low == true,
		Game = Settings.Game == true,
		Strength = if Settings.Game then 0.45 else 1,
		Clock = 0,
		Moving = 1,
		Bass = NewBand(30, 150),
		Mid = NewBand(150, 1500),
		High = NewBand(1500, 8000),
	}

	Repaint(State, Defaults[Name] or White)
	;(Builders[Name] or BuildSkin)(State)

	return State
end

-- One frame. Accent is the colour to draw in (nil: the background's own); Moving is 0 to 1, how much it moves (a paused song
-- holds it nearly still). View is the part of the canvas the screen shows, in its pixels, when the canvas runs past it (a
-- song's): a skin's pictures fit that, not the whole canvas.
function Backgrounds.Process(State, Delta: number, Accent: Color3?, Moving: number?, View: Vector2?)
	State.View = View

	local Size = State.Container.AbsoluteSize

	if Size.X < 2 or Size.Y < 2 then
		return
	end

	local Wanted = Accent or Defaults[State.Name] or White
	local Old = State.Painted

	-- (repainted only when the colour moved enough to see: a hit colour easing in changes a little every frame)
	if math.abs(Wanted.R - Old.R) + math.abs(Wanted.G - Old.G) + math.abs(Wanted.B - Old.B) > 0.02 then
		Repaint(State, Wanted)
	end

	Delta = math.min(Delta, 0.1)
	State.Moving = Moving or 1
	State.Clock += Delta * (0.2 + 0.8 * State.Moving)

	StepBand(State.Bass, Delta)
	StepBand(State.Mid, Delta)
	StepBand(State.High, Delta)

	;(Steppers[State.Name] or StepSkin)(State, Delta, Size.X, Size.Y)
	State.Repaint = false
end

function Backgrounds.Destroy(State)
	State.Container:Destroy()
end

-- A bright version of a Space Color (those are dark fills), to draw a background in. Nil for none, or black.
function Backgrounds.AccentOf(Color: { number }?): Color3?
	if not Color then
		return nil
	end

	local Brightest = math.max(Color[1], Color[2], Color[3])

	if Brightest < 0.01 then
		return nil
	end

	return Color3.new(Color[1] / Brightest * 0.9, Color[2] / Brightest * 0.9, Color[3] / Brightest * 0.9)
end

return Backgrounds
