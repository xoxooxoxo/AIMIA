--!strict
--!optimize 2

--[[
	Note Glow (Database/Settings/SettingsProfile NoteGlow, not in the source): whether notes show Roblox's Neon glow.

	Roblox draws a soft glow round bright Neon parts from render quality level 6 of 21 up, 3 of the 10 graphics bars (measured in
	Studio 2026-11-10: level 5 none, level 6 the glow; Lighting's Bloom has no part in it). The notes are Neon
	(Game/View/NoteRenderer), so the glow came and went with each player's graphics: a spectator on high graphics saw a glow
	the player on low graphics never had. On keeps the Neon notes, so the glow is Roblox's own. Off draws a mesh note flat, as
	low graphics draw it: its outline seen head-on (Flat), on a picture quad, in the colour low graphics show (FlatTint at
	FlatBrightness).

	Design Notes
		ScreenDraws reads the player's own graphics setting: a game can't read the level Automatic picks (Stats' quality level
		needs plugin rights), so Automatic counts as glowing. Game/LiveSpectate sends it with the look (NoteGlowShown), so a
		watcher draws the notes flat when the player's own screen showed no glow.
		The colours come from grey ramps measured on screen in a song's lighting at level 5: what a Neon part shows for each
		value (NeonShown) and what a SurfaceGui with LightInfluence 0 shows at Brightness 2 (FlatShown). FlatTint gives, channel
		by channel, the value that shows what Neon shows. Brightness 2 is the most that stays under the Bloom effect's threshold
		at level 21 (3 bloomed like the glow); a flat white shows 245 where Neon shows 253. A see-through Neon part stays
		brighter than a see-through picture (white at 0.7 transparency: 184 against 135), so FlatFade turns a note's
		transparency into the picture's that shows the same (white ramps measured the same way).
		A flat picture is an EditableImage (one per mesh file, Side a side, white with the outline's coverage as alpha, Samples
		by Samples a pixel). A device out of its EditableImage budget gets nil, and the notes stay Neon.
		Halo is the settings preview's stand-in for the glow (UI/SettingsPreview draws notes as rings in the menu, where no Neon
		can be): a soft copy of a ring shape, falling off as Roblox's glow does round a note.

		Note Glow Strength and Note Glow Fade (2026-11-10, the owner's ask: the glow was too bright, and it went out while a
		fading note was still plain to see). Measured in a paused song at the grid and 10 studs back: Roblox's glow depends on
		the colour's brightest component, none up to about 164 of 255 and all of it from about 192, and a see-through note
		counts as that much darker (white lost it between 0.45 and 0.55 transparency). A colour's Level is its brightest
		component to the power LevelPower, times how much of the note shows; the glow rises from GlowLevelFrom over
		GlowLevelRise. So Strength caps each component of a note's colour (Tint): the glow drops with the cap while the note
		itself barely changes (Neon shows 164 as 252 of 255). With Note Glow Fade off, the glow a see-through note has lost is
		put back by a picture behind it (MeshHalo, the mesh's outline blurred as Halo is; Fill is how much of it shows), so the
		glow lasts as long as the note does.
]]

const AssetService = game:GetService("AssetService")

const FileSystem = require("../../Util/FileSystem")
const MeshFiles = require("../../../AimiaData/Meshes")

-- The graphics bars Roblox draws the glow from (render quality level 6 of 21: bar n is level floor(2.1 n), bar 1 is 1).
const GlowBars = 3

-- Grey ramps, 0 to 255: the value given, what Neon shows of it, and what a flat SurfaceGui at FlatBrightness shows of it.
const Given = { 0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240, 255 }
const NeonShown = { 0, 0, 3, 14, 39, 82, 134, 181, 215, 235, 246, 251, 253, 253, 253, 253, 253 }
const FlatShown = { 0, 6, 25, 51, 82, 112, 139, 163, 183, 198, 211, 221, 229, 234, 239, 243, 245 }
-- A note's transparency (0 to 1 in tenths) and the flat picture's that looks the same: white Neon showed 253, 252, 250,
-- 246, 239, 229, 212, 184, 143, 86 at these, a flat white 245, 241, 234, 224, 211, 192, 167, 135, 98, 58.
const NeonClear = { 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1 }
const FlatClear = { 0, 0, 0, 0, 0.129, 0.25, 0.392, 0.532, 0.675, 0.83, 1 }

-- A flat picture's side in pixels, and its samples a pixel along each side (4: a row of a pixel's samples is one u32).
const Side = 256
const Samples = 4
const Grid = Side * Samples

-- The preview halo, fitted to Roblox's glow round a ring note measured on screen (level 17, a 95-pixel ring, side by side
-- with this): the glow is the ring blurred (Gaussian) twice over, a tight blur HaloGain times brighter and a wide one
-- (the light that fills the ring's hole) WideGain times, capped at full; HaloBlur and WideBlur are shares of the note's
-- side, as round a near note in a song. The picture's side, how far it reaches past the ring (a share of the note's side),
-- and the outer share of that reach it fades out over (so the picture's edge never shows).
const HaloSide = 96
const HaloBlur = 0.14
const HaloGain = 2.7
const WideBlur = 0.35
const WideGain = 1
const HaloReach = 0.5
const HaloFade = 0.6
-- A colour glows by its brightest component (a mid grey doesn't): its Level is that component to the power LevelPower, and
-- the glow is none up to GlowLevelFrom, all of it from GlowLevelFrom + GlowLevelRise (greys 164 and 192 of 255).
-- Neon's core is whiter where it glows, and a see-through note glows less, none from GlowClear (measured: a white Neon part
-- loses its glow between 0.1 and 0.3 transparency).
const LevelPower = 0.8
const GlowLevelFrom = 0.7
const GlowLevelRise = 0.1
const CoreWhite = 0.45
const GlowClear = 0.3

const NoteGlow = {
	FlatBrightness = 2,
	-- the halo picture's size against the note's side
	HaloScale = 1 + 2 * HaloReach,
}

-- Whether this screen draws the Neon glow: the player's graphics setting, 3 bars or more, or Automatic.
function NoteGlow.ScreenDraws(): boolean
	const Read, Setting = pcall(function(): unknown
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel
	end)

	return not (Read and typeof(Setting) == "EnumItem" and Setting ~= Enum.SavedQualitySetting.Automatic and (Setting :: EnumItem).Value < GlowBars)
end

-- Whether a profile wants the glow (a profile without the switch does, as every one did before it).
function NoteGlow.Wanted(Settings: any): boolean
	const Item = if type(Settings) == "table" then Settings.NoteGlow else nil

	return Item == nil or Item.Value ~= false
end

-- A value of one ramp at X, read off another (both increasing), 0 to 255.
const function Across(From: { number }, To: { number }, X: number): number
	if X <= From[1] then
		return To[1]
	end

	for Index = 2, #From do
		if X <= From[Index] then
			const Low = From[Index - 1]
			const High = From[Index]
			const Weight = if High > Low then (X - Low) / (High - Low) else 0

			return To[Index - 1] + (To[Index] - To[Index - 1]) * Weight
		end
	end

	return To[#To]
end

-- The component to give a flat note (at FlatBrightness) so it shows what Neon shows.
const function FlatComponent(Value: number): number
	const Shown = math.min(Across(Given, NeonShown, math.clamp(Value, 0, 1) * 255), FlatShown[#FlatShown])

	return Across(FlatShown, Given, Shown) / 255
end

-- The tint of a flat note of the colour (Red, Green, Blue).
function NoteGlow.FlatTint(Red: number, Green: number, Blue: number): Color3
	return Color3.new(FlatComponent(Red), FlatComponent(Green), FlatComponent(Blue))
end

-- The transparency to give a flat note so it looks as a Neon note at Transparency (0 to 1) does. A mesh note is drawn from
-- both sides (Game/View/NoteMesh), so a see-through one is two layers deep and looks as one layer at Transparency squared
-- (checked in a song: rings at 0.5, 0.7 and 0.85 showed 250, 230, 166, as one layer at 0.25, 0.49 and 0.72 does).
function NoteGlow.FlatFade(Transparency: number): number
	const Clear = math.clamp(Transparency, 0, 1)

	return Across(NeonClear, FlatClear, Clear * Clear)
end

-- What Neon shows of a component (0 to 1) without its glow.
const function NeonComponent(Value: number): number
	return Across(Given, NeonShown, math.clamp(Value, 0, 1) * 255) / 255
end

-- How much a note of the colour glows, 0 to 1 (a dark colour doesn't); the colour of its glow, as Neon shows the colour;
-- and the colour its ring shows with the glow on (whiter, as Neon's core is where it glows). Amount scales the whitening
-- (GlowAt of a see-through note: no glow, no whiter core).
function NoteGlow.GlowOf(Color: Color3, Amount: number?): (number, Color3, Color3)
	const Level = math.pow(math.clamp(math.max(Color.R, Color.G, Color.B), 0, 1), LevelPower)
	const Strength = math.clamp((Level - GlowLevelFrom) / GlowLevelRise, 0, 1)
	const Shown = Color3.new(NeonComponent(Color.R), NeonComponent(Color.G), NeonComponent(Color.B))

	return Strength, Shown, Shown:Lerp(Color3.new(1, 1, 1), CoreWhite * Strength * (Amount or 1))
end

-- How much of its glow a note shows at a transparency (0 solid, 1 gone): a mesh note is two layers deep (FlatFade).
function NoteGlow.GlowAt(Transparency: number): number
	const Clear = math.clamp(Transparency, 0, 1)

	return math.clamp(1 - Clear * Clear / GlowClear, 0, 1)
end

-- How much of Roblox's glow a Level shows, 0 to 1.
const function ShareOf(Level: number): number
	return math.clamp((Level - GlowLevelFrom) / GlowLevelRise, 0, 1)
end

-- A profile's Note Glow Strength, 0 to 1 (a profile without it has the full glow, as every one did before it).
function NoteGlow.Strength(Settings: any): number
	const Item = if type(Settings) == "table" then Settings.NoteGlowStrength else nil
	const Value = if Item ~= nil then Item.Value else nil

	if type(Value) ~= "number" or Value ~= Value then
		return 1
	end

	return math.clamp(Value, 0, 1)
end

-- Whether a profile lets the glow go out as soon as a note starts to fade, as Roblox's own does (Note Glow Fade).
function NoteGlow.Fades(Settings: any): boolean
	const Item = if type(Settings) == "table" then Settings.NoteGlowFade else nil

	return Item ~= nil and Item.Value == true
end

-- A Neon note's colour at a glow Strength (0 to 1): each component capped where Roblox's glow is that strong. At 1 the
-- colour is untouched.
function NoteGlow.Tint(Red: number, Green: number, Blue: number, Strength: number): Color3
	if Strength >= 1 then
		return Color3.new(Red, Green, Blue)
	end

	const Cap = math.pow(GlowLevelFrom + GlowLevelRise * math.max(Strength, 0), 1 / LevelPower)

	return Color3.new(math.min(Red, Cap), math.min(Green, Cap), math.min(Blue, Cap))
end

-- A note colour's glow Level (see the header).
function NoteGlow.LevelOf(Color: Color3): number
	return math.pow(math.clamp(math.max(Color.R, Color.G, Color.B), 0, 1), LevelPower)
end

-- How much of the halo picture goes behind a note of a Level at a Transparency (0 solid, 1 gone), 0 to 1: the glow the
-- note should still have (its solid glow, by how much of the note shows) less what Roblox still draws of it. A mesh note
-- is two layers deep (FlatFade).
function NoteGlow.Fill(Level: number, Transparency: number): number
	const Clear = math.clamp(Transparency, 0, 1)
	const Seen = 1 - Clear * Clear

	return math.max(ShareOf(Level) * Seen - ShareOf(Level * Seen), 0)
end

-- An EditableImage of Size with the pixels written, or nil when the device can't make one.
const function MakeImage(Size: number, Pixels: buffer): Content?
	const Made, Image = pcall(function(): EditableImage?
		return AssetService:CreateEditableImage({ Size = Vector2.new(Size, Size) })
	end)

	if not Made or Image == nil then
		return nil
	end

	const Written = pcall(function()
		(Image :: EditableImage):WritePixelsBuffer(Vector2.zero, Vector2.new(Size, Size), Pixels)
	end)

	if not Written then
		pcall(function()
			(Image :: EditableImage):Destroy()
		end)

		return nil
	end

	return Content.fromObject(Image)
end

-- A mesh file's text, as Game/View/NoteMesh reads it (the user folder's file, else the game's own copy).
const function TextOf(Path: string): string?
	const Name = string.match(Path, "[^/]*$") :: string

	if FileSystem.Exists(Path) then
		return buffer.tostring(FileSystem.ReadAllBytes(Path))
	end

	return MeshFiles[Name]
end

-- The mesh seen head-on: every triangle's shadow on the note's plane, as coverage (Grid by Grid samples, 1 where covered)
-- of the square from -Half to Half; nil for a file with no triangle.
const function Outline(Text: string): (buffer?, number)
	const Xs: { number } = {}
	const Ys: { number } = {}
	const Triangles: { number } = {}

	for Line in string.gmatch(Text, "[^\r\n]+") do
		const X, Y = string.match(Line, "^v%s+(%S+)%s+(%S+)")

		if X and Y then
			table.insert(Xs, tonumber(X) or 0)
			table.insert(Ys, tonumber(Y) or 0)
		elseif string.sub(Line, 1, 2) == "f " then
			const Corners: { number } = {}

			for Reference in string.gmatch(Line, "%S+") do
				const Index = tonumber(string.match(Reference, "^(-?%d+)"))

				if Index then
					table.insert(Corners, if Index < 0 then #Xs + 1 + Index else Index)
				end
			end

			for Index = 2, #Corners - 1 do
				table.insert(Triangles, Corners[1])
				table.insert(Triangles, Corners[Index])
				table.insert(Triangles, Corners[Index + 1])
			end
		end
	end

	local Half = 0

	for _, Corner in Triangles do
		const X, Y = Xs[Corner], Ys[Corner]

		if X and Y then
			Half = math.max(Half, math.abs(X), math.abs(Y))
		end
	end

	if #Triangles == 0 or Half <= 0 or not math.isfinite(Half) then
		return nil, 0
	end

	const Mask = buffer.create(Grid * Grid)
	const Scale = Grid / (2 * Half)

	for First = 1, #Triangles, 3 do
		const A, B, C = Triangles[First], Triangles[First + 1], Triangles[First + 2]

		if not (Xs[A] and Xs[B] and Xs[C]) then
			continue
		end

		-- (in samples, Y down; sorted top to bottom)
		local X0, Y0 = (Xs[A] + Half) * Scale, (Half - Ys[A]) * Scale
		local X1, Y1 = (Xs[B] + Half) * Scale, (Half - Ys[B]) * Scale
		local X2, Y2 = (Xs[C] + Half) * Scale, (Half - Ys[C]) * Scale

		if Y1 < Y0 then
			X0, Y0, X1, Y1 = X1, Y1, X0, Y0
		end

		if Y2 < Y0 then
			X0, Y0, X2, Y2 = X2, Y2, X0, Y0
		end

		if Y2 < Y1 then
			X1, Y1, X2, Y2 = X2, Y2, X1, Y1
		end

		if Y2 - Y0 < 1e-9 then
			continue
		end

		for Row = math.max(math.ceil(Y0 - 0.5), 0), math.min(math.floor(Y2 - 0.5), Grid - 1) do
			const Y = Row + 0.5
			const Long = X0 + (X2 - X0) * (Y - Y0) / (Y2 - Y0)
			local Short = X1

			if Y < Y1 then
				if Y1 - Y0 > 1e-9 then
					Short = X0 + (X1 - X0) * (Y - Y0) / (Y1 - Y0)
				end
			elseif Y2 - Y1 > 1e-9 then
				Short = X1 + (X2 - X1) * (Y - Y1) / (Y2 - Y1)
			end

			const From = math.max(math.ceil(math.min(Long, Short) - 0.5), 0)
			const To = math.min(math.floor(math.max(Long, Short) - 0.5), Grid - 1)

			if To >= From then
				buffer.fill(Mask, Row * Grid + From, 1, To - From + 1)
			end
		end
	end

	return Mask, Half
end

-- The flat pictures made, by mesh path (false: the mesh can't be drawn flat here).
const Flats: { [string]: { Picture: Content, Half: number } | false } = {}

-- Note Glow off: the mesh at Path drawn flat, white (tinted per note), and how far it reaches from its middle (half its
-- side, in the mesh's units); nil when it can't be made (the notes stay Neon).
function NoteGlow.Flat(Path: string): (Content?, number?)
	const Known = Flats[Path]

	if Known ~= nil then
		if Known then
			return Known.Picture, Known.Half
		end

		return nil, nil
	end

	const Read, Text = pcall(TextOf, Path)
	const Drawn, Mask, Half = pcall(Outline, if Read and type(Text) == "string" then Text else "")

	if not Drawn or Mask == nil then
		Flats[Path] = false

		return nil, nil
	end

	const Pixels = buffer.create(Side * Side * 4)
	const Full = Samples * Samples

	for PixelY = 0, Side - 1 do
		for PixelX = 0, Side - 1 do
			local Count = 0

			-- (a row of the pixel's samples is four bytes of 0 or 1: their sum is the word mod 255)
			for Row = 0, Samples - 1 do
				Count += buffer.readu32(Mask :: buffer, (PixelY * Samples + Row) * Grid + PixelX * Samples) % 255
			end

			const Alpha = math.floor(Count * 255 / Full + 0.5)

			buffer.writeu32(Pixels, (PixelY * Side + PixelX) * 4, 0x00FFFFFF + Alpha * 0x1000000)
		end
	end

	const Picture = MakeImage(Side, Pixels)

	if Picture == nil then
		-- (out of budget now: tried again at the next song)
		return nil, nil
	end

	Flats[Path] = { Picture = Picture, Half = Half }

	return Picture, Half
end

-- A rounded square's distance at (X, Y) from its middle (negative inside): half side Size, corner radius Radius.
const function BoxDistance(X: number, Y: number, Size: number, Radius: number): number
	const QX = math.abs(X) - (Size - Radius)
	const QY = math.abs(Y) - (Size - Radius)
	const OutX = math.max(QX, 0)
	const OutY = math.max(QY, 0)

	return math.sqrt(OutX * OutX + OutY * OutY) + math.min(math.max(QX, QY), 0) - Radius
end

-- A square picture (Side by Side values, row by row) blurred by a Gaussian of Sigma pixels: across, then down.
const function Blur(Source: { number }, Side: number, Sigma: number): { number }
	const Taps = math.ceil(3 * Sigma)
	const Weights: { number } = {}
	local Total = 0

	for Offset = -Taps, Taps do
		const Weight = math.exp(-(Offset * Offset) / (2 * Sigma * Sigma))

		Weights[Offset + Taps + 1] = Weight
		Total += Weight
	end

	for Index, Weight in Weights do
		Weights[Index] = Weight / Total
	end

	const Sideways: { number } = table.create(Side * Side, 0)
	const Blurred: { number } = table.create(Side * Side, 0)

	for Y = 0, Side - 1 do
		const Row = Y * Side

		for X = 0, Side - 1 do
			local Sum = 0

			for Offset = math.max(-Taps, -X), math.min(Taps, Side - 1 - X) do
				Sum += Source[Row + X + Offset + 1] * Weights[Offset + Taps + 1]
			end

			Sideways[Row + X + 1] = Sum
		end
	end

	for X = 0, Side - 1 do
		for Y = 0, Side - 1 do
			local Sum = 0

			for Offset = math.max(-Taps, -Y), math.min(Taps, Side - 1 - Y) do
				Sum += Sideways[(Y + Offset) * Side + X + 1] * Weights[Offset + Taps + 1]
			end

			Blurred[Y * Side + X + 1] = Sum
		end
	end

	return Blurred
end

-- The preview halos made, by shape, and their pixels (kept, so a device that refused the picture only tries the picture
-- again, not the blur).
const Halos: { [string]: Content } = {}
const HaloPixels: { [string]: buffer } = {}

-- The settings preview's glow round a ring of the shape (Corner and Ring as shares of the note's side, as
-- UI/SettingsPreview draws it), white (tinted per note), HaloScale times the note's side; nil when it can't be made.
function NoteGlow.Halo(Corner: number, Ring: number): Content?
	const Key = string.format("%.4f|%.4f", Corner, Ring)
	const Known = Halos[Key]

	if Known then
		return Known
	end

	const Ready = HaloPixels[Key]

	if Ready then
		const Picture = MakeImage(HaloSide, Ready)

		if Picture then
			Halos[Key] = Picture
		end

		return Picture
	end

	const Span = 1 + 2 * HaloReach
	const PerSide = HaloSide / Span
	const Radius = math.clamp(Corner, 0, 0.5)
	const Inner = math.max(0.5 - Ring, 0)
	const InnerRadius = math.min(math.max(Radius - Ring, 0), Inner)
	const Count = HaloSide * HaloSide
	const Ring2D: { number } = table.create(Count, 0)
	const Faded: { number } = table.create(Count, 0)

	-- the ring as the preview draws it (a pixel of soft edge), and how far past it each pixel is
	for PixelY = 0, HaloSide - 1 do
		for PixelX = 0, HaloSide - 1 do
			-- (in note sides from the middle)
			const X = ((PixelX + 0.5) / HaloSide - 0.5) * Span
			const Y = ((PixelY + 0.5) / HaloSide - 0.5) * Span
			const Outside = BoxDistance(X, Y, 0.5, Radius)
			-- (a shape with no hole: every pixel is outside it)
			const Hole = if Inner > 0 then BoxDistance(X, Y, Inner, InnerRadius) else math.huge
			const Index = PixelY * HaloSide + PixelX + 1
			const Fade = math.clamp((HaloReach - Outside) / (HaloReach * HaloFade), 0, 1)

			Ring2D[Index] = math.clamp(0.5 - Outside * PerSide, 0, 1) * math.clamp(0.5 + Hole * PerSide, 0, 1)
			Faded[Index] = Fade * Fade * (3 - 2 * Fade)
		end
	end

	const Tight = Blur(Ring2D, HaloSide, HaloBlur * PerSide)
	const Wide = Blur(Ring2D, HaloSide, WideBlur * PerSide)
	const Pixels = buffer.create(Count * 4)

	for Index = 1, Count do
		const Glow = math.min(1, HaloGain * Tight[Index] + WideGain * Wide[Index]) * Faded[Index]
		const Alpha = math.floor(Glow * 255 + 0.5)

		buffer.writeu32(Pixels, (Index - 1) * 4, 0x00FFFFFF + Alpha * 0x1000000)
	end

	HaloPixels[Key] = Pixels

	const Picture = MakeImage(HaloSide, Pixels)

	if Picture then
		Halos[Key] = Picture
	end

	return Picture
end

-- The song halo (MeshHalo): Roblox's glow round a solid white note at the grid, measured in a paused song side by side
-- with this picture (2026-11-10): how far from the note's edge, as a share of its side, and the brightness shown there, 0
-- to 255. It is the same going into a ring's hole as going out.
const HaloAway = { 0, 0.032, 0.064, 0.096, 0.128, 0.16, 0.192, 0.224, 0.256, 0.288, 0.32, 0.352, 0.384, 0.416 }
const HaloShown = { 255, 231, 199, 157, 118, 82, 56, 39, 26, 16, 8, 5, 2, 0 }
-- Its side in pixels, and the blur that smooths it, as a share of the note's side.
const MeshSide = 128
const HaloSoft = 0.04

-- The song halos made, by mesh path (false: the mesh can't be read), and their pixels (kept, so a device that refused the
-- picture only tries the picture again).
const MeshHalos: { [string]: { Picture: Content, Half: number } | false } = {}
const MeshHaloPixels: { [string]: { Pixels: buffer, Half: number } } = {}

-- The glow of the mesh at Path as a picture (Note Glow Fade off, Game/View/NoteRenderer): round its outline seen head-on,
-- as bright at each distance from it as Roblox's glow is (HaloShown; on a surface at FlatBrightness), and nothing under
-- the outline itself, so the note's own fade is left as it is. White (tinted per note), HaloScale times the mesh's side;
-- and half that side in the mesh's units. nil when it can't be made (the notes keep only Roblox's glow).
function NoteGlow.MeshHalo(Path: string): (Content?, number?)
	const Known = MeshHalos[Path]

	if Known ~= nil then
		if Known then
			return Known.Picture, Known.Half
		end

		return nil, nil
	end

	local Ready = MeshHaloPixels[Path]

	if Ready == nil then
		const Read, Text = pcall(TextOf, Path)
		const Drawn, Mask, Half = pcall(Outline, if Read and type(Text) == "string" then Text else "")

		if not Drawn or Mask == nil then
			MeshHalos[Path] = false

			return nil, nil
		end

		const Span = 1 + 2 * HaloReach
		const PerSide = MeshSide / Span
		const First = (MeshSide - PerSide) / 2
		const PerPixel = Grid / PerSide
		const Count = MeshSide * MeshSide
		const Shape: { number } = table.create(Count, 0)
		-- how far each pixel is from the outline, in pixels (0 on it)
		const Away: { number } = table.create(Count, math.huge)

		for PixelY = 0, MeshSide - 1 do
			for PixelX = 0, MeshSide - 1 do
				if PixelX < First or PixelY < First or PixelX >= First + PerSide or PixelY >= First + PerSide then
					continue
				end

				-- (the outline's coverage of this pixel: 4 by 4 of its samples)
				local Sum = 0

				for SubY = 0, 3 do
					const Row = math.clamp(math.floor((PixelY - First + (SubY + 0.5) / 4) * PerPixel), 0, Grid - 1)

					for SubX = 0, 3 do
						const Column = math.clamp(math.floor((PixelX - First + (SubX + 0.5) / 4) * PerPixel), 0, Grid - 1)

						Sum += buffer.readu8(Mask :: buffer, Row * Grid + Column)
					end
				end

				const Index = PixelY * MeshSide + PixelX + 1

				Shape[Index] = Sum / 16

				if Sum >= 8 then
					Away[Index] = 0
				end
			end
		end

		-- (two sweeps: each pixel takes the nearest covered pixel through its neighbours, a step 1 or a diagonal 1.414)
		const Diagonal = math.sqrt(2)

		for PixelY = 0, MeshSide - 1 do
			for PixelX = 0, MeshSide - 1 do
				const Index = PixelY * MeshSide + PixelX + 1
				local Nearest = Away[Index]

				if Nearest > 0 then
					if PixelX > 0 then
						Nearest = math.min(Nearest, Away[Index - 1] + 1)
					end

					if PixelY > 0 then
						Nearest = math.min(Nearest, Away[Index - MeshSide] + 1)

						if PixelX > 0 then
							Nearest = math.min(Nearest, Away[Index - MeshSide - 1] + Diagonal)
						end

						if PixelX < MeshSide - 1 then
							Nearest = math.min(Nearest, Away[Index - MeshSide + 1] + Diagonal)
						end
					end

					Away[Index] = Nearest
				end
			end
		end

		for PixelY = MeshSide - 1, 0, -1 do
			for PixelX = MeshSide - 1, 0, -1 do
				const Index = PixelY * MeshSide + PixelX + 1
				local Nearest = Away[Index]

				if Nearest > 0 then
					if PixelX < MeshSide - 1 then
						Nearest = math.min(Nearest, Away[Index + 1] + 1)
					end

					if PixelY < MeshSide - 1 then
						Nearest = math.min(Nearest, Away[Index + MeshSide] + 1)

						if PixelX < MeshSide - 1 then
							Nearest = math.min(Nearest, Away[Index + MeshSide + 1] + Diagonal)
						end

						if PixelX > 0 then
							Nearest = math.min(Nearest, Away[Index + MeshSide - 1] + Diagonal)
						end
					end

					Away[Index] = Nearest
				end
			end
		end

		-- (the edge is half a pixel before the first covered pixel's middle)
		const Bright: { number } = table.create(Count, 0)

		for Index = 1, Count do
			Bright[Index] = Across(HaloAway, HaloShown, math.max(Away[Index] - 0.5, 0) / PerSide)
		end

		-- (a little blur: the brightness by nearest edge alone has ridges where the nearest edge changes, a cross in a ring's
		-- hole, and Roblox's glow, which adds up from every side, has none. A pixel the outline covers shows none of it.)
		const Soft = Blur(Bright, MeshSide, HaloSoft * PerSide)
		const Pixels = buffer.create(Count * 4)

		for Index = 1, Count do
			const Shown = Soft[Index] * (1 - Shape[Index])
			const Alpha = math.clamp(math.floor(Across(FlatShown, Given, Shown) + 0.5), 0, 255)

			buffer.writeu32(Pixels, (Index - 1) * 4, 0x00FFFFFF + Alpha * 0x1000000)
		end

		Ready = { Pixels = Pixels, Half = Half }
		MeshHaloPixels[Path] = Ready
	end

	const Picture = MakeImage(MeshSide, Ready.Pixels)

	if Picture == nil then
		-- (out of budget now: tried again at the next song)
		return nil, nil
	end

	MeshHalos[Path] = { Picture = Picture, Half = Ready.Half }

	return Picture, Ready.Half
end

return NoteGlow
