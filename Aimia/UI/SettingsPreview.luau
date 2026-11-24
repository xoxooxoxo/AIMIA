--!strict
--!optimize 2

--[[
	The preview card of the settings menu (not in the source): a small playfield at the foot of the sidebar, opened with the
	Preview button under it while the Visual section is shown. It draws the player's own look as a song would: the Custom Map
	Skins space, the note colours and note picture, the border and grid pictures, and the cursor (its picture, colour, scale,
	opacity and spin) with its trail, passing through a few notes.

	Paradigm
		New(Host) builds the button and the card once, in the menu's holder. While the menu's root is visible one PreRender
		step places them for the holder's size, follows the section shown and the menu's fade, and draws a frame of the card
		while it can be seen. Nothing runs while the menu is hidden, and while the card is closed only that placing and
		following does.

	Representation
		The card is a plain frame (a CanvasGroup redraws, and blurs, whenever anything in it moves); the menu's fade and the
		card's own opening are one cover of the panel's black over it, clear when the card is fully shown. Inside it everything
		is in the card's layout pixels, Unit of them to a Godot unit: the card spans the grid picture's 4 units, so the
		playfield is its middle 3.
		The cursor runs a figure-eight through the middle, right and left cells once every LoopSeconds, and a note comes in to
		each of those cells as it passes (taking the note colours in turn, as a map's notes do). The cursor, the notes and the
		trail are functions of the card's clock: the trail is the path read back over its fade time, so no history is kept.

	Design Notes
		A settings change (an Updated signal, or a skin load) only marks the card dirty: it reads the settings again on its next
		drawn frame, so a profile load that writes every setting costs one refresh, and a closed card costs nothing.
		SettingsMenu makes the card after its fade has tracked the menu, so that fade never writes the card's moving pieces;
		the button is a menu button (UI/Settings/Buttons) and fades with the menu as the others do.
		A problem stops the card for good and hides its button, with one warning; the menu itself is never touched. The space
		has a guard of its own, as the menu's space does (UI/SceneManager): a broken one goes and the card goes on without it.
		The space goes whenever the card closes, so a moving one (or a video) never runs behind a closed card.
		Spaces/Backgrounds lays out in its holder's AbsoluteSize, which is in screen pixels, while the menus are under UI/Scale's
		UIScale: the holder it gets undoes that scale, so the space is drawn 1:1 on the screen at the card's size.
		The world tones its colours (Game/View/Tone); the card is on the screen, so its colours are given as they should look.
		A mesh note's ring shows its colour as Neon does (Game/View/NoteGlow.GlowOf). With Note Glow on, on graphics that draw
		it, a soft halo made to match Roblox's glow side by side (NoteGlow.Halo; only Neon in the world gets the real one) sits
		behind a whiter ring, and fades out as the note turns see-through, as the real one does.
		DEVIATION: there is no 3D world here, so the grid space is a flat stand-in (its floor and ceiling fading into the fog,
		the lines across them sliding toward you), and a note mesh is drawn as the ring of its shape.
]]

const RunService = game:GetService("RunService")

const Backgrounds = require("../Spaces/Backgrounds")
const Buttons = require("./Settings/Buttons")
const Constants = require("../Constants")
const CursorStyles = require("../Skinning/CursorStyles")
const Draw = require("./Settings/Draw")
const Fade = require("./Settings/Fade")
const FileSystem = require("../Util/FileSystem")
const Frames = require("./Frames")
const Geometry = require("./Settings/Geometry")
const Images = require("./Images")
const Look = require("./Settings/Look")
const Motion = require("./Settings/Motion")
const NoteGlow = require("../Game/View/NoteGlow")
const Scale = require("./Scale")
const SettingsManager = require("../SettingsManager")
const SettingsProfile = require("../Database/Settings/SettingsProfile")
const SettingsSection = require("../Database/Settings/SettingsSection")
const Signal = require("../Util/Signal")
const SkinManager = require("../Skinning/SkinManager")
const SkinProfile = require("../Skinning/SkinProfile")
const SkinSets = require("../Skinning/SkinSets")
const SpaceColor = require("../Spaces/SpaceColor")
const Text = require("./SettingsLogic/Text")
const Tooltip = require("./Settings/Tooltip")

type Rect = Geometry.Rect

-- What the card needs of the settings menu, which passes it in (requiring the menu from here would be a cycle).
export type Host = {
	-- the menu's root: the card runs while it is visible
	Root: Frame,
	-- the panels' holder: the button and the card sit in its sidebar column
	Holder: Frame,
	-- the menu's fade (its Alpha is the menu's) and its tooltip
	Overlay: Fade.Fade,
	Tooltip: Tooltip.Tooltip,
	-- the name of the section shown, and how many sections the sidebar lists
	Section: () -> string?,
	Sections: () -> number,
}

-- How a note mesh is drawn: its ring's corner radius and width, as shares of the note's side.
type Shape = { Corner: number, Ring: number }

-- A note: the ring a mesh is drawn as and the picture a skin set's flat note is (the looks show one of them), the ring's
-- glow (Note Glow), and the hit it showed last (its colour is only set again when that changes) and how much it glows.
type NoteSlot = {
	Ring: Frame,
	Stroke: UIStroke,
	Corner: UICorner,
	Picture: ImageLabel,
	Halo: ImageLabel,
	Hit: number,
	Glow: number,
}

-- A slice of the trail's line: its bar, the gradient that colours and fades it along its length, and its width.
type Slice = {
	Bar: Frame,
	Paint: UIGradient,
	Width: number,
}

-- The grid space's stand-in: the ceiling and floor bands, the lines across them (the ceiling's first), the rails along them,
-- and the tint they were painted in.
type Floor = {
	Bands: { Frame },
	Lines: { Frame },
	Rails: { Frame },
	Tint: Color3,
}

-- The settings as the card draws them, read again by Refresh. Sizes are in Godot units.
type Looks = {
	Space: string,
	Fog: { number }?,
	HitEffects: boolean,
	Colors: { Color3 },
	NotePicture: Content?,
	NoteShape: Shape,
	NoteSize: number,
	NoteOpacity: number,
	-- the glow's picture when the notes glow (Note Glow on, a mesh, graphics that draw it), else nil
	Halo: Content?,
	-- Note Glow Strength (0 to 1), and whether the glow goes out as soon as a note fades (Note Glow Fade)
	GlowStrength: number,
	GlowFades: boolean,
	Border: Content?,
	BorderSide: number,
	BorderTint: Color3,
	BorderOpacity: number,
	Cursor: Content?,
	CursorTint: Color3,
	CursorSize: number,
	CursorOpacity: number,
	CursorSpin: number,
	Trail: boolean,
	TrailLine: boolean,
	TrailPicture: Content?,
	TrailFade: number,
	TrailSpacing: number,
	TrailShrink: boolean,
	TrailOpacity: number,
	TrailCore: number,
	-- how far a hollow cursor's open middle reaches (CursorStyles.HoleOf), 0 while the cursor is hidden
	TrailHole: number,
	-- the same for a trail picture, which stays hidden there (0 for copies of the cursor's own picture)
	TrailClear: number,
	TrailGradient: { { number } }?,
	TrailSolid: Color3?,
	Hues: { Color3 },
}

export type Preview = {
	Host: Host,
	Button: Buttons.Button,
	Card: GuiObject,
	Group: CanvasGroup?,
	Cover: Frame,
	Fill: Frame,
	Scenery: Frame,
	Border: ImageLabel,
	Grid: ImageLabel,
	Notes: { NoteSlot },
	Slices: { Slice },
	SliceCount: number,
	Head: Frame,
	Pieces: { ImageLabel },
	Cursor: ImageLabel,
	-- the space drawn (a Spaces/Backgrounds state in its unscaled holder, or the grid's stand-in) and what it was made for
	Background: any,
	Counter: Frame?,
	CounterScale: UIScale?,
	CounterFactor: number,
	Floor: Floor?,
	SceneryKey: string?,
	Looks: Looks?,
	-- the space's hit colour, eased toward the last hit's (Space Hit Effects)
	Tint: Color3?,
	-- the card's own open and close, and whether the player wants it open
	Toggle: Fade.Fade,
	Wanted: boolean,
	-- whether the Visual section is shown with room for the card, whether the card is drawn, and its state
	Visual: boolean,
	Room: boolean,
	Drawn: boolean,
	Dirty: boolean,
	Broken: boolean,
	-- the card's layout: pixels to a unit, its middle, its rest in the holder, and what it was laid out for
	Unit: number,
	Center: number,
	RestX: number,
	RestY: number,
	LaidWidth: number,
	LaidHeight: number,
	LaidCount: number,
	-- the alpha and opening last shown, and the card's clock
	ShownAlpha: number,
	ShownOpen: number,
	Clock: number,
	Stepping: RBXScriptConnection?,
	Watching: RBXScriptConnection?,
	-- the Roblox graphics setting, which decides whether a song draws Note Glow
	Graphics: RBXScriptConnection?,
	Signals: { Signal.Signal<unknown> },
	MarkDirty: (unknown) -> (),
}

-- The section the card belongs to, and the setting values it tells apart.
const VisualSection = Text.SectionName(SettingsSection.Visual)
const SkinName = "skin"
const GridName = "grid"
const LineName = "smooth line"
const CursorName = "cursor"

-- The settings the card shows (the profile's property names): a change to any of them marks it dirty.
const Watched = {
	"GameSpace",
	"SpaceColor",
	"SpaceHitEffects",
	"NoteColors",
	"NoteOpacity",
	"NoteMesh",
	"NoteSize",
	"NoteGlow",
	"NoteGlowStrength",
	"NoteGlowFade",
	"Border",
	"CursorStyle",
	"CursorColor",
	"CursorScale",
	"CursorOpacity",
	"CursorRotation",
	"CursorTrail",
	"TrailImage",
	"TrailTime",
	"TrailSpacing",
	"TrailShrink",
	"TrailOpacity",
	"TrailColor",
}

-- The button's texts and tooltip.
const OpenText = "Preview"
const CloseText = "Hide Preview"
const ButtonTip = "Your map skin, notes, cursor and trail as they look in a song"

-- The button sits at the foot of the sidebar inside the panels' margin, as tall as a setting row's buttons. The card is the
-- square that fits between the section buttons and it; with less room than MinSide neither is shown.
const Margin = 8
const ButtonHeight = Geometry.RowHeight - 8
const MinSide = 96
-- Over the sidebar (2) and the header (3), under the holder's outline (5).
const CardZ = 4
-- The card's own open and close: the menu's fade time and ease, rising SlideOffset pixels as it opens.
const ToggleSeconds = 0.25
const SlideOffset = 6
-- The most one frame moves the card on: a hitch doesn't make it jump.
const MaxDelta = 0.1

-- The card's layers, back to front (the screen's ZIndexBehavior is Sibling). The notes take NoteZ to NoteZ + MaxNotes - 1,
-- the next one to be hit in front, over every note's glow (HaloZ).
const FillZ = 1
const SceneryZ = 2
const BorderZ = 3
const GridZ = 4
const HaloZ = 5
const NoteZ = 6
const TrailZ = 10
const CursorZ = 11
const CoverZ = 20

-- Godot units across the card: the grid picture's quad (Game/View/GameWorld), whose middle 3 are the playfield.
const UnitsAcross = 4

-- The cursor's path: a figure-eight PathWidth units to each side of the middle and PathHeight up and down, once a loop.
-- (a medium map's pace, a note every LoopSeconds / 4: at 2 seconds a loop the trail at its default fade time was only a speck
-- under a hollow cursor, so the trail settings couldn't be seen; at this pace it shows as a streak, as it does in a song)
const LoopSeconds = 1.25
const PathWidth = 1
const PathHeight = 0.6
const Tau = 2 * math.pi
-- The path's top speed in units a second (at the middle, where its tangent is (PathWidth, 2 PathHeight) a radian).
const TopSpeed = math.sqrt(PathWidth * PathWidth + 4 * PathHeight * PathHeight) * Tau / LoopSeconds

-- The notes: one at each cell the path passes, in the order it passes them (middle, right, middle, left), HitGap apart.
const HitCells = { { X = 0, Y = 0 }, { X = 1, Y = 0 }, { X = 0, Y = 0 }, { X = -1, Y = 0 } }
const HitGap = LoopSeconds / #HitCells
-- A note comes ApproachDistance units in over ApproachSeconds, seen from the camera CameraDistance units back (the scene's
-- Camera3D), fading in over the first FadeInShare of that; on its hit it grows by PopGrow as it fades out over PopSeconds.
const ApproachSeconds = 0.75
const ApproachDistance = 15
const CameraDistance = 3.75
const FadeInShare = 0.35
const PopSeconds = 0.12
const PopGrow = 0.12
const MaxNotes = 4
-- The clock an opened card starts at: whole loops in (the loop's start), far enough for a trail of the longest fade (2
-- seconds) to be whole.
const WarmClock = LoopSeconds * math.ceil(2 / LoopSeconds)

-- How each note mesh the game has (user/meshes) is drawn. The squircle rounds off over half its side; the square is a plain
-- frame, and the cube's and plane's frames are thinner. Any other mesh is drawn as the squircle.
const NoteShapes: { [string]: Shape } = {
	squircle = { Corner = 0.25, Ring = 0.12 },
	square = { Corner = 0, Ring = 0.1 },
	cube = { Corner = 0, Ring = 0.06 },
	plane = { Corner = 0, Ring = 0.06 },
}
const DefaultShape = NoteShapes.squircle

-- The trail, as Game/View/TrailRenderer draws it: the line is as wide as the cursor's body and tapers with Shrink Over Time,
-- keeping LineTailAlpha of its opacity at the tail; the pictures are laid at least MinSpacing cursor sizes apart.
const LineTaper = 0.5
const LineTailAlpha = 0.35
const MinSpacing = 0.12
-- and copies of a hollow cursor's picture at least OutlineSpacing apart, as the game lays them
const OutlineSpacing = 0.25
-- and a trail picture hidden while its middle is within a hollow cursor's open middle and PictureReach of its width more
const PictureReach = 0.35
-- The line is cut into slices about SliceUnits long at the cursor's top speed (MinSlices to MaxSlices), each JoinPixels
-- longer so no seam shows between them; at most MaxPieces pictures (the oldest go first), their gradient in ColorLevels steps.
const SliceUnits = 0.06
const MinSlices = 6
const MaxSlices = 40
const JoinPixels = 1
const MaxPieces = 64
const ColorLevels = 32

-- What the world shows behind each kind of space (Scenes/Game): near black behind an animated one, the grid's violet fog,
-- and the void's clear color. Space Color replaces each.
const AnimatedFill = Color3.new(0.012, 0.01, 0.022)
const ClearFill = Color3.new(0.0885599, 0.08855992, 0.08855987)
const GridFog = { 0.0470588, 0.0313726, 0.109804 }

-- The grid space (Game/View/GridSpace): planes GridHeight above and below the grid, lines across them every GridStep sliding
-- in at 3 steps a second, and Godot's depth fog. Seen from the camera, a plane meets the card's edge EdgeDepth units away;
-- the card draws its lines out to FarDepth, where the fog has nearly taken them.
const GridHeight = 10
const GridStep = 120 / 34
const GridSpeed = 3 * GridStep
const FogBegin = 10
const FogEnd = 60
const FogCurve = 0.15
const EdgeDepth = GridHeight * CameraDistance / (UnitsAcross / 2)
const FarDepth = 45
const GridLines = math.ceil((FarDepth - EdgeDepth) / GridStep) + 1
const GridLineColor = Color3.new(0.827, 0.827, 0.827)
const GridFillColor = Color3.new(0.165, 0.145, 0.165)
-- The rails (the lines along each plane), in grid steps to each side of the middle.
const GridRails = { -2, -1, 0, 1, 2 }

const White = Color3.new(1, 1, 1)

-- The path's length from its start at each of PathSteps steps of one loop, in units: the trail's pictures are laid evenly
-- along it.
const PathSteps = 256
const PathLengths: { number } = { 0 }

do
	local Length = 0
	local LastX, LastY = 0, 0

	for Index = 1, PathSteps do
		const Theta = Tau * Index / PathSteps
		const X = PathWidth * math.sin(Theta)
		const Y = PathHeight * math.sin(2 * Theta)

		Length += math.sqrt((X - LastX) * (X - LastX) + (Y - LastY) * (Y - LastY))
		PathLengths[Index + 1] = Length
		LastX, LastY = X, Y
	end
end

const LoopLength = PathLengths[PathSteps + 1]

-- The fog's share at a depth in front of the camera (Godot's depth fog, as Game/View/GridSpace has it).
const function FogAt(Depth: number): number
	return math.clamp((Depth - FogBegin) / (FogEnd - FogBegin), 0, 1) ^ FogCurve
end

-- A plane's fade from the card's edge (0) to its middle (1): each height of it is that much further off.
const function BandFade(): NumberSequence
	const Points: { NumberSequenceKeypoint } = {}

	for _, Share in { 0, 0.15, 0.3, 0.45, 0.6, 0.75, 1 } do
		const Depth = if Share < 1 then EdgeDepth / (1 - Share) else math.huge

		table.insert(Points, NumberSequenceKeypoint.new(Share, FogAt(Depth)))
	end

	return NumberSequence.new(Points)
end

const BandSequence = BandFade()
const RailSequence = NumberSequence.new(FogAt(EdgeDepth), FogAt(FarDepth))

-- A colour from three components.
const function ColorOf(Components: { number }): Color3
	return Color3.new(Components[1], Components[2], Components[3])
end

-- A colour times a tint, component by component.
const function Tinted(Color: Color3, Tint: Color3): Color3
	return Color3.new(Color.R * Tint.R, Color.G * Tint.G, Color.B * Tint.B)
end

-- Whether two colours are too close to tell apart (an easing tint isn't painted again for less).
const function Alike(A: Color3, B: Color3): boolean
	return math.abs(A.R - B.R) + math.abs(A.G - B.G) + math.abs(A.B - B.B) < 0.01
end

-- Where the cursor is at time T, in units from the middle (Y up).
const function PathAt(T: number): (number, number)
	const Theta = Tau * T / LoopSeconds

	return PathWidth * math.sin(Theta), PathHeight * math.sin(2 * Theta)
end

-- How far along the path the cursor has gone at time T (none before 0), in units.
const function DistanceAt(T: number): number
	const Loops = math.max(T, 0) / LoopSeconds
	const Whole = math.floor(Loops)
	const Along = (Loops - Whole) * PathSteps
	const Step = math.min(math.floor(Along), PathSteps - 1)
	const Low = PathLengths[Step + 1]

	return Whole * LoopLength + Low + (PathLengths[Step + 2] - Low) * (Along - Step)
end

-- When the cursor had gone Distance units along the path (DistanceAt the other way).
const function TimeAt(Distance: number): number
	const Whole = math.floor(Distance / LoopLength)
	const Rest = Distance - Whole * LoopLength
	local Low = 0
	local High = PathSteps - 1

	-- (the last step that starts at or before Rest)
	while Low < High do
		const Middle = (Low + High + 1) // 2

		if PathLengths[Middle + 1] <= Rest then
			Low = Middle
		else
			High = Middle - 1
		end
	end

	const Start = PathLengths[Low + 1]
	const Span = PathLengths[Low + 2] - Start
	const Share = if Span > 0 then math.clamp((Rest - Start) / Span, 0, 1) else 0

	return (Whole + (Low + Share) / PathSteps) * LoopSeconds
end

-- Where the cursor is at time T, in the card's pixels.
const function PixelAt(Preview: Preview, T: number): (number, number)
	const X, Y = PathAt(T)

	return Preview.Center + X * Preview.Unit, Preview.Center - Y * Preview.Unit
end

-- Sets up a piece of the card: no border, placed by its middle, and parented last (as the menu's builders do).
const function Mount(Object: GuiObject, Parent: Instance, Name: string, ZIndex: number)
	Object.Name = Name
	Object.BorderSizePixel = 0
	Object.AnchorPoint = Vector2.new(0.5, 0.5)
	Object.ZIndex = ZIndex
	Object.Active = false
	Object.Parent = Parent
end

-- A picture of the card, unseen until drawn.
const function NewImage(Parent: Instance, Name: string, ZIndex: number): ImageLabel
	const Image = Instance.new("ImageLabel")

	Image.BackgroundTransparency = 1
	Image.ScaleType = Enum.ScaleType.Stretch
	Image.ImageTransparency = 1
	Mount(Image, Parent, Name, ZIndex)

	return Image
end

-- A plain bar of the card (white until painted), unseen until drawn.
const function NewBar(Parent: Instance, Name: string, ZIndex: number): Frame
	const Bar = Instance.new("Frame")

	Bar.BackgroundColor3 = White
	Bar.BackgroundTransparency = 1
	Mount(Bar, Parent, Name, ZIndex)

	return Bar
end

-- A note's ring and picture, both hidden.
const function NewNote(Parent: Instance, Index: number): NoteSlot
	const Ring = NewBar(Parent, `Note{Index}`, NoteZ)
	const Corner = Instance.new("UICorner")
	const Stroke = Instance.new("UIStroke")
	const Picture = NewImage(Parent, `NotePicture{Index}`, NoteZ)
	const Halo = NewImage(Parent, `NoteGlow{Index}`, HaloZ)

	Ring.Visible = false
	Halo.Visible = false
	Corner.Parent = Ring
	-- (inside the ring's square: the mesh's outer edge is the note's size)
	Stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	Stroke.BorderStrokePosition = Enum.BorderStrokePosition.Inner
	Stroke.Transparency = 1
	Stroke.Parent = Ring
	Picture.Visible = false

	return { Ring = Ring, Stroke = Stroke, Corner = Corner, Picture = Picture, Halo = Halo, Hit = -1, Glow = 0 }
end

-- A skin texture the menu can draw by its path (the default skin's are baked, UI/Images), or nil: a decoded file (the world
-- registers those itself) or a path with no image.
const function SkinContentOf(Texture: SkinProfile.Texture?): Content?
	const Path = if Texture then Texture.Path else nil

	if Path == nil then
		return nil
	end

	const Found, Made = pcall(Images.GetContent, Path)

	return if Found then Made else nil
end

-- The cursor's picture as Game/View/GameWorld picks it (the style's, else the skin's own), or the style's uploaded twin when
-- neither can be drawn here.
const function CursorContentOf(Style: string): Content?
	return CursorStyles.ContentOf(Style) or SkinContentOf(SkinManager.Skin.CursorImage) or CursorStyles.TrailContentOf(Style)
end

-- The ring a note mesh file is drawn as when it isn't one of the game's own (a map skin's): a square frame, every point of it
-- at a corner of its outer or inner square, is drawn square with its own frame's width; anything else as the squircle.
const function ShapeOfFile(Path: string): Shape?
	const Read, Text = pcall(FileSystem.ReadAllText, Path)

	if not Read or type(Text) ~= "string" then
		return nil
	end

	const Lines = "\n" .. Text
	local Outer = 0
	local Points = 0

	for X, Y in string.gmatch(Lines, "\nv%s+(%S+)%s+(%S+)") do
		const Across, Up = math.abs(tonumber(X) or 0), math.abs(tonumber(Y) or 0)

		-- (a point off its square's diagonal: a rounded or other shape)
		if math.abs(Across - Up) > 1e-3 then
			return nil
		end

		Outer = math.max(Outer, Across)
		Points += 1
	end

	if Points == 0 or Outer <= 0 then
		return nil
	end

	local Inner = 0

	for X in string.gmatch(Lines, "\nv%s+(%S+)") do
		const Across = math.abs(tonumber(X) or 0)

		if Across < Outer - 1e-3 then
			Inner = math.max(Inner, Across)
		end
	end

	return { Corner = 0, Ring = if Inner > 0 then (Outer - Inner) / (2 * Outer) else 0.5 }
end

-- The note picture or ring and the colours the profile gives, as SkinManager reads them for it (not from the skin, which may
-- be wearing a listed replay's look). A colour set that can't be read keeps the skin's colours.
const function NoteLookOf(Settings: SettingsProfile.SettingsProfile): (Content?, Shape, { Color3 })
	const Read, Mesh, Found = pcall(SkinManager.NoteLookOf, Settings)
	const Path = if Read then Mesh.Path else ""
	const PictureName = string.match(Path, "^picture://(.+)$")
	const MeshName = string.match(Path, "([^/]+)%.obj$")
	const Colors: { Color3 } = {}

	for _, Color in (if Read then Found else nil) or SkinManager.Skin.NoteColors do
		table.insert(Colors, Color3.new(Color.R, Color.G, Color.B))
	end

	if #Colors == 0 then
		table.insert(Colors, White)
	end

	const Picture = if PictureName then SkinSets.NotePicture(PictureName) else nil
	const Shape = (if MeshName then NoteShapes[MeshName] or ShapeOfFile(Path) else nil) or DefaultShape

	return Picture, Shape, Colors
end

-- The trail's colour at a share of its fade (0 at the cursor, 1 at the tail), as Game/View/TrailRenderer colours it.
const function TrailColorAt(Looks: Looks, Share: number): Color3
	const Gradient = Looks.TrailGradient

	if Gradient then
		const Red, Green, Blue = SkinSets.GradientAt(Gradient, Share)

		return Color3.new(Red, Green, Blue)
	end

	return Looks.TrailSolid or Looks.CursorTint
end

-- The colour of the last note hit (the notes take the colours in turn).
const function LastHitColor(Looks: Looks, Now: number): Color3
	const Colors = Looks.Colors

	return Colors[math.floor(Now / HitGap) % #Colors + 1]
end

-- The grid space's stand-in in the card's space holder: a band for the ceiling and one for the floor, fading into the fog
-- toward the middle, with their rails and the lines across them (DrawFloor slides those).
const function NewFloor(Parent: Instance): Floor
	const Floor = { Bands = {}, Lines = {}, Rails = {}, Tint = White } :: Floor

	for Plane = 0, 1 do
		const Band = Instance.new("Frame")
		const Paint = Instance.new("UIGradient")

		Band.Name = "Plane"
		Band.BorderSizePixel = 0
		Band.BackgroundColor3 = GridFillColor
		Band.Position = UDim2.fromScale(0, 0.5 * Plane)
		Band.Size = UDim2.fromScale(1, 0.5)
		Band.ZIndex = 1
		-- (from the card's edge to its middle: down for the ceiling, up for the floor)
		Paint.Rotation = if Plane == 0 then 90 else -90
		Paint.Transparency = BandSequence
		Paint.Parent = Band
		Band.Parent = Parent
		table.insert(Floor.Bands, Band)

		for _ = 1, GridLines do
			const Line = NewBar(Parent, "Line", 2)

			Line.BackgroundColor3 = GridLineColor
			Line.Size = UDim2.new(1, 0, 0, 1)
			table.insert(Floor.Lines, Line)
		end

		for _ = 1, #GridRails do
			const Rail = NewBar(Parent, "Rail", 2)
			const Fog = Instance.new("UIGradient")

			Rail.BackgroundColor3 = GridLineColor
			Rail.BackgroundTransparency = 0
			Fog.Transparency = RailSequence
			Fog.Parent = Rail
			table.insert(Floor.Rails, Rail)
		end
	end

	return Floor
end

-- Lays the rails out for the card's size: each runs along its plane from the card's edge to where the fog takes it.
const function PlaceRails(Preview: Preview, Floor: Floor)
	const Unit = Preview.Unit
	const Center = Preview.Center
	const NearScale = CameraDistance / EdgeDepth
	const FarScale = CameraDistance / FarDepth

	for Index, Rail in Floor.Rails do
		const Up = if Index <= #GridRails then 1 else -1
		const Across = GridRails[(Index - 1) % #GridRails + 1] * GridStep
		const NearX, NearY = Center + Across * NearScale * Unit, Center - Up * GridHeight * NearScale * Unit
		const FarX, FarY = Center + Across * FarScale * Unit, Center - Up * GridHeight * FarScale * Unit
		const DX, DY = FarX - NearX, FarY - NearY

		Rail.Position = UDim2.fromOffset((NearX + FarX) / 2, (NearY + FarY) / 2)
		Rail.Size = UDim2.fromOffset(math.sqrt(DX * DX + DY * DY), 1)
		Rail.Rotation = math.deg(math.atan2(DY, DX))
	end
end

-- Paints the stand-in in the space's tint (the grid's lines and fills take the hit colour, as Game/View/GridSpace's do).
const function PaintFloor(Floor: Floor, Tint: Color3)
	const Line = Tinted(GridLineColor, Tint)
	const Fill = Tinted(GridFillColor, Tint)

	Floor.Tint = Tint

	for _, Band in Floor.Bands do
		Band.BackgroundColor3 = Fill
	end

	for _, Piece in Floor.Lines do
		Piece.BackgroundColor3 = Line
	end

	for _, Rail in Floor.Rails do
		Rail.BackgroundColor3 = Line
	end
end

-- The lines across the planes: one every grid step further in, sliding toward you at the grid's speed, fogged by depth.
const function DrawFloor(Preview: Preview, Floor: Floor, Now: number, Tint: Color3)
	if not Alike(Floor.Tint, Tint) then
		PaintFloor(Floor, Tint)
	end

	const Shift = (Now * GridSpeed) % GridStep

	for Index, Line in Floor.Lines do
		const Up = if Index <= GridLines then 1 else -1
		const Depth = EdgeDepth + ((Index - 1) % GridLines + 1) * GridStep - Shift
		const Reach = GridHeight * CameraDistance / Depth * Preview.Unit

		Line.Position = UDim2.fromOffset(Preview.Center, Preview.Center - Up * Reach)
		Line.BackgroundTransparency = FogAt(Depth)
	end
end

-- Takes the space out of the card. KeepKey: a space that broke stays out until its setting changes.
const function DropScenery(Preview: Preview, KeepKey: boolean)
	const Background = Preview.Background

	Preview.Background = nil
	Preview.Counter = nil
	Preview.CounterScale = nil
	Preview.Floor = nil

	if not KeepKey then
		Preview.SceneryKey = nil
	end

	if Background then
		pcall(Backgrounds.Destroy, Background)
	end

	Preview.Scenery:ClearAllChildren()
end

-- Keeps the background's holder at the card's size on the screen, with the menus' UIScale (UI/Scale's factor) undone.
const function Unscale(Preview: Preview)
	const Counter = Preview.Counter
	const CounterScale = Preview.CounterScale
	const Factor = Scale.FactorOf(Preview.Card)

	if Counter and CounterScale and Factor > 0 and Factor ~= Preview.CounterFactor then
		Preview.CounterFactor = Factor
		Counter.Size = UDim2.fromScale(Factor, Factor)
		CounterScale.Scale = 1 / Factor
	end
end

-- Builds the Custom Map Skins space in the card over the fill the world shows behind it (Scenes/Game): a background of
-- Spaces/Backgrounds (as a song draws it: dimmer, quieter in the middle; with fewer pieces, for a card this small), the
-- grid's stand-in, or the void's plain fill. Space Color colours each.
const function BuildScenery(Preview: Preview, Looks: Looks, Key: string)
	DropScenery(Preview, false)
	Preview.SceneryKey = Key

	const Fog = Looks.Fog

	if Looks.Space == GridName then
		Preview.Fill.BackgroundColor3 = ColorOf(Fog or GridFog)
		Preview.Floor = NewFloor(Preview.Scenery)

		return
	end

	if not Backgrounds.Has(Looks.Space) then
		Preview.Fill.BackgroundColor3 = if Fog then ColorOf(Fog) else ClearFill

		return
	end

	Preview.Fill.BackgroundColor3 = if Fog then ColorOf(Fog) else AnimatedFill

	const Counter = Instance.new("Frame")
	const CounterScale = Instance.new("UIScale")

	Counter.Name = "Unscaled"
	Counter.BackgroundTransparency = 1
	Counter.BorderSizePixel = 0
	Counter.ZIndex = 1
	CounterScale.Parent = Counter
	Counter.Parent = Preview.Scenery

	Preview.Counter = Counter
	Preview.CounterScale = CounterScale
	Preview.CounterFactor = -1
	Unscale(Preview)

	const Built, Made = pcall(Backgrounds.New, Looks.Space, Counter, { Low = true, Game = true })

	if Built then
		Preview.Background = Made
	else
		warn("[AIMIA] the settings preview's space stopped: " .. tostring(Made))
		DropScenery(Preview, true)
	end
end

-- The trail's still parts: the line's slices (each keeps its share of the fade, so its width, colour and fade are set here and
-- only its ends move), its round head, and the pictures' gradient steps and picture.
const function ApplyTrail(Preview: Preview, Looks: Looks, CursorSide: number)
	const Slices = Preview.Slices
	const Count = if Looks.Trail and Looks.TrailLine
		then math.clamp(math.ceil(Looks.TrailFade * TopSpeed / SliceUnits), MinSlices, MaxSlices)
		else 0
	const Wide = CursorSide * Looks.TrailCore
	const Tail = if Looks.TrailShrink then LineTailAlpha else 0
	const Opacity = Looks.TrailOpacity

	for Index = #Slices + 1, Count do
		const Bar = NewBar(Preview.Card, `TrailSlice{Index}`, TrailZ)
		const Paint = Instance.new("UIGradient")

		Bar.BackgroundTransparency = 0
		Paint.Parent = Bar
		Slices[Index] = { Bar = Bar, Paint = Paint, Width = 0 }
	end

	for Index, Slice in Slices do
		if Index > Count then
			Slice.Bar.Visible = false

			continue
		end

		const From = (Index - 1) / Count
		const To = Index / Count
		const Middle = (From + To) / 2

		Slice.Width = Wide * (if Looks.TrailShrink then (1 - Middle) ^ LineTaper else 1)
		Slice.Paint.Color = ColorSequence.new(TrailColorAt(Looks, From), TrailColorAt(Looks, To))
		Slice.Paint.Transparency = NumberSequence.new(1 - Opacity * (1 - (1 - Tail) * From), 1 - Opacity * (1 - (1 - Tail) * To))
		Slice.Bar.Visible = true
	end

	Preview.SliceCount = Count

	const Head = Preview.Head

	Head.Size = UDim2.fromOffset(Wide, Wide)
	Head.BackgroundColor3 = TrailColorAt(Looks, 0)
	Head.BackgroundTransparency = 1 - Opacity
	-- (none in a hollow cursor: the line starts at the edge of its open middle)
	Head.Visible = Count > 0 and Looks.TrailHole == 0

	if Looks.TrailGradient then
		for Level = 0, ColorLevels - 1 do
			Looks.Hues[Level + 1] = TrailColorAt(Looks, Level / (ColorLevels - 1))
		end
	end

	for _, Piece in Preview.Pieces do
		if Looks.TrailPicture then
			Piece.ImageContent = Looks.TrailPicture
		end

		Piece.Visible = false
	end
end

-- Sets the card's still parts for the looks and its size: the grid and border pictures, the cursor, the notes' rings, the
-- trail's slices and pictures, and the grid space's rails.
const function Apply(Preview: Preview, Looks: Looks)
	const Unit = Preview.Unit
	const GridPicture = SkinContentOf(SkinManager.Skin.GridImage)
	const Grid = Preview.Grid
	const Border = Preview.Border
	const Cursor = Preview.Cursor
	const CursorSide = Looks.CursorSize * Unit

	if GridPicture then
		Grid.ImageContent = GridPicture
	end

	-- (a border takes the place of grid.png's corner marks, as in a song: Game/View/GameWorld's Setup)
	Grid.ImageTransparency = if GridPicture and not Looks.Border then 0 else 1

	if Looks.Border then
		Border.ImageContent = Looks.Border
	end

	Border.Size = UDim2.fromOffset(Looks.BorderSide * Unit, Looks.BorderSide * Unit)
	Border.ImageColor3 = Looks.BorderTint
	Border.ImageTransparency = if Looks.Border then 1 - Looks.BorderOpacity else 1

	if Looks.Cursor then
		Cursor.ImageContent = Looks.Cursor
	end

	Cursor.Size = UDim2.fromOffset(CursorSide, CursorSide)
	Cursor.ImageColor3 = Looks.CursorTint
	Cursor.ImageTransparency = if Looks.Cursor then 1 - Looks.CursorOpacity else 1

	for _, Note in Preview.Notes do
		Note.Hit = -1
		Note.Corner.CornerRadius = UDim.new(Looks.NoteShape.Corner, 0)
		Note.Ring.Visible = false
		Note.Picture.Visible = false
		Note.Halo.Visible = false

		if Looks.NotePicture then
			Note.Picture.ImageContent = Looks.NotePicture
		end

		if Looks.Halo then
			Note.Halo.ImageContent = Looks.Halo
		end
	end

	ApplyTrail(Preview, Looks, CursorSide)

	if Preview.Floor then
		PlaceRails(Preview, Preview.Floor)
	end
end

-- Reads the settings into the card's looks and sets the card's still parts for them; the space is built again only when it
-- is another one (or has another Space Color).
const function Refresh(Preview: Preview)
	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile
	const Space = Settings.GameSpace.Value
	const Style = Settings.CursorStyle.Value
	const TrailImage = Settings.TrailImage.Value
	const TrailColor = Settings.TrailColor.Value
	const CursorSize = Constants.CursorSize * math.max(Settings.CursorScale.Value, 0)
	const Cursor = CursorContentOf(Style)
	const NotePicture, NoteShape, Colors = NoteLookOf(Settings)
	const Border, BorderSide, BorderTint, BorderOpacity = SkinSets.BorderOf(Settings.Border.Value)
	-- (Roblox's glow is a Neon note's: a skin set's picture note never has it, nor does a screen that doesn't draw it. The
	-- halo is only made when it shows)
	const GlowStrength = NoteGlow.Strength(Settings)
	const Glows = NotePicture == nil and GlowStrength > 0 and NoteGlow.Wanted(Settings) and NoteGlow.ScreenDraws()
	local Read: boolean, Halo: Content? = false, nil

	if Glows then
		Read, Halo = pcall(NoteGlow.Halo, NoteShape.Corner, NoteShape.Ring)
	end
	const Looks: Looks = {
		-- (the skin's own space when the setting is "skin", as Scenes/Game reads it)
		Space = if Space == SkinName then SkinManager.Skin.Config.GameSpace else Space,
		Fog = SpaceColor.Of(Settings.SpaceColor.Value),
		HitEffects = Settings.SpaceHitEffects.Value,
		Colors = Colors,
		NotePicture = NotePicture,
		NoteShape = NoteShape,
		NoteSize = math.clamp(Settings.NoteSize.Value, 0, 2),
		NoteOpacity = math.clamp(Settings.NoteOpacity.Value, 0, 1),
		Halo = if Glows and Read then Halo else nil,
		GlowStrength = GlowStrength,
		GlowFades = NoteGlow.Fades(Settings),
		Border = Border,
		BorderSide = BorderSide,
		BorderTint = BorderTint,
		BorderOpacity = BorderOpacity,
		Cursor = Cursor,
		CursorTint = CursorStyles.ColorOf(Settings.CursorColor.Value) or White,
		CursorSize = CursorSize,
		CursorOpacity = math.clamp(Settings.CursorOpacity.Value, 0, 1),
		CursorSpin = Settings.CursorRotation.Value,
		Trail = Settings.CursorTrail.Value,
		TrailLine = TrailImage == LineName,
		-- (the cursor's own picture for "cursor", a skin's trail picture by its name)
		TrailPicture = if TrailImage == CursorName then Cursor else SkinSets.TrailPicture(TrailImage) or Cursor,
		TrailFade = math.max(Settings.TrailTime.Value, 0.005),
		TrailSpacing = math.max(Settings.TrailSpacing.Value, if TrailImage == CursorName and CursorStyles.HoleOf(Style) > 0
			then OutlineSpacing
			else MinSpacing) * CursorSize,
		TrailShrink = Settings.TrailShrink.Value,
		TrailOpacity = math.clamp(Settings.TrailOpacity.Value, 0, 1),
		TrailCore = CursorStyles.CoreOf(Style),
		-- (nothing covers the line's head while the cursor is hidden)
		TrailHole = if Settings.CursorOpacity.Value > 0 then CursorStyles.HoleOf(Style) else 0,
		TrailClear = if Settings.CursorOpacity.Value > 0 and TrailImage ~= CursorName then CursorStyles.HoleOf(Style) else 0,
		TrailGradient = SkinSets.TrailGradient(TrailColor),
		TrailSolid = SkinSets.TrailSolid(TrailColor),
		Hues = {},
	}
	const Key = `{Looks.Space}|{Settings.SpaceColor.Value}`

	Preview.Looks = Looks
	Preview.Dirty = false

	if Key ~= Preview.SceneryKey then
		BuildScenery(Preview, Looks, Key)
	end

	Apply(Preview, Looks)
end

-- One frame of the space, in the colour Scenes/Game gives it: the last hit's, eased in, when Space Hit Effects is on (never
-- on a skin set's pictures), otherwise Space Color's. The grid's lines take the hit colour as Game/View/GridSpace's do.
const function DrawScenery(Preview: Preview, Looks: Looks, Delta: number, Now: number)
	const Hit = LastHitColor(Looks, Now)
	const Was = Preview.Tint
	const Background = Preview.Background

	if Background then
		local Accent = Backgrounds.AccentOf(Looks.Fog)

		if Looks.HitEffects and not SkinSets.Get(Looks.Space) then
			const Eased = if Was then Was:Lerp(Hit, math.min(1, Delta * 6)) else Hit

			Preview.Tint = Eased
			Accent = Eased
		end

		Unscale(Preview)

		-- (a broken space goes, and the card goes on without it)
		const Drawn, Why = pcall(Backgrounds.Process, Background, Delta, Accent)

		if not Drawn then
			warn("[AIMIA] the settings preview's space stopped: " .. tostring(Why))
			DropScenery(Preview, true)
		end

		return
	end

	const Floor = Preview.Floor

	if Floor then
		local Tint = White

		if Looks.HitEffects then
			Tint = (Was or White):Lerp(Hit, math.min(1, Delta * 8))
			Preview.Tint = Tint
		end

		DrawFloor(Preview, Floor, Now, Tint)
	end
end

-- The notes: hit N comes in to its cell over ApproachSeconds (from far off, so from near the middle) and is hit as the
-- cursor gets there; it takes the colour set's colours in turn, as a map's N-th note does (Game/View/NoteRenderer).
const function DrawNotes(Preview: Preview, Looks: Looks, Now: number)
	const Notes = Preview.Notes
	const Colors = Looks.Colors
	const Unit = Preview.Unit
	const Center = Preview.Center
	const First = math.ceil((Now - PopSeconds) / HitGap)
	const Last = math.floor((Now + ApproachSeconds) / HitGap)
	local Used = 0

	for Hit = First, Last do
		if Used >= #Notes then
			break
		end

		Used += 1

		const Note = Notes[Used]
		const Cell = HitCells[Hit % #HitCells + 1]
		const HitAt = Hit * HitGap
		local Reach = 1
		local Grow = 1
		local Alpha = 1

		if Now < HitAt then
			const Left = (HitAt - Now) / ApproachSeconds

			-- (seen in perspective: far off, a note is small and near the middle)
			Reach = CameraDistance / (CameraDistance + ApproachDistance * Left)
			Alpha = math.clamp((1 - Left) / FadeInShare, 0, 1)
		else
			const Since = math.clamp((Now - HitAt) / PopSeconds, 0, 1)

			Grow = 1 + PopGrow * Since
			Alpha = 1 - Since
		end

		const Side = Looks.NoteSize * Unit * Reach * Grow
		const Where = UDim2.fromOffset(Center + Cell.X * Unit * Reach, Center - Cell.Y * Unit * Reach)
		const Size = UDim2.fromOffset(Side, Side)
		const Seen = 1 - Alpha * Looks.NoteOpacity
		const Layer = NoteZ + MaxNotes - Used

		if Note.Hit ~= Hit then
			const Color = Colors[Hit % #Colors + 1]

			Note.Hit = Hit
			Note.Picture.ImageColor3 = Color

			-- (a ring is Neon in a song: the colour as Neon shows it, whiter with the glow, which takes that colour. A ring Note
			-- Opacity keeps see-through has no glow and no whiter core)
			-- (Note Glow Strength caps the colour, as in a song; a glow that doesn't fade early stays by how much of the note shows)
			const Faint = 1 - Looks.NoteOpacity
			const Capped = NoteGlow.Tint(Color.R, Color.G, Color.B, Looks.GlowStrength)
			const Strength, Shown, Core = NoteGlow.GlowOf(Capped, if Looks.GlowFades then NoteGlow.GlowAt(Faint) else 1 - Faint * Faint)

			if Looks.Halo then
				Note.Glow = Strength
				Note.Stroke.Color = Core
				Note.Halo.ImageColor3 = Shown
			else
				Note.Glow = 0
				Note.Stroke.Color = Shown
			end
		end

		if Looks.NotePicture then
			Note.Picture.Position = Where
			Note.Picture.Size = Size
			Note.Picture.ImageTransparency = Seen
			Note.Picture.ZIndex = Layer
			Note.Picture.Visible = true
			Note.Halo.Visible = false
		else
			Note.Ring.Position = Where
			Note.Ring.Size = Size
			Note.Ring.ZIndex = Layer
			Note.Stroke.Thickness = math.max(1, Side * Looks.NoteShape.Ring)
			Note.Stroke.Transparency = Seen
			Note.Ring.Visible = true

			-- (a see-through note glows less, as Neon does)
			const Glow = Note.Glow * (if Looks.GlowFades then NoteGlow.GlowAt(Seen) else 1 - Seen * Seen)

			if Looks.Halo and Glow > 0 then
				const Reach = Side * NoteGlow.HaloScale

				Note.Halo.Position = Where
				Note.Halo.Size = UDim2.fromOffset(Reach, Reach)
				Note.Halo.ImageTransparency = 1 - Glow
				Note.Halo.Visible = true
			else
				Note.Halo.Visible = false
			end
		end
	end

	for Index = Used + 1, #Notes do
		Notes[Index].Ring.Visible = false
		Notes[Index].Picture.Visible = false
		Notes[Index].Halo.Visible = false
	end
end

-- The smooth line: slice K runs from where the cursor was K - 1 slices of the fade ago to where it was K slices ago, and the
-- round head sits under the cursor.
const function DrawLine(Preview: Preview, Looks: Looks, Now: number)
	const Count = Preview.SliceCount
	const Seconds = Looks.TrailFade
	local NewerX, NewerY = PixelAt(Preview, Now)
	-- (a hollow cursor's open middle: the line starts at its edge, as Game/View/TrailRenderer draws it)
	const Hole = Looks.TrailHole * Looks.CursorSize * Preview.Unit
	const CentreX, CentreY = NewerX, NewerY
	local Started = Hole <= 0

	Preview.Head.Position = UDim2.fromOffset(NewerX, NewerY)

	for Index = 1, Count do
		const OlderX, OlderY = PixelAt(Preview, Now - Seconds * Index / Count)
		const Slice = Preview.Slices[Index]
		const Bar = Slice.Bar

		if not Started then
			const OX, OY = OlderX - CentreX, OlderY - CentreY
			const Older = math.sqrt(OX * OX + OY * OY)

			-- (a slice all inside has no length; the first one out starts at the edge)
			if Older < Hole then
				Bar.Size = UDim2.fromOffset(0, 0)

				continue
			end

			Started = true
			NewerX, NewerY = CentreX + OX * Hole / Older, CentreY + OY * Hole / Older
		end

		const DX, DY = OlderX - NewerX, OlderY - NewerY

		-- (the bar runs from the newer end to the older, as its gradient does)
		Bar.Position = UDim2.fromOffset((NewerX + OlderX) / 2, (NewerY + OlderY) / 2)
		Bar.Size = UDim2.fromOffset(math.sqrt(DX * DX + DY * DY) + JoinPixels, Slice.Width)
		Bar.Rotation = math.deg(math.atan2(DY, DX))
		NewerX, NewerY = OlderX, OlderY
	end
end

-- The trail's Index-th picture, made when the trail first needs that many.
const function PieceAt(Preview: Preview, Looks: Looks, Index: number): ImageLabel
	const Pieces = Preview.Pieces
	const Found = Pieces[Index]

	if Found then
		return Found
	end

	const Piece = NewImage(Preview.Card, `TrailPiece{Index}`, TrailZ)

	if Looks.TrailPicture then
		Piece.ImageContent = Looks.TrailPicture
	end

	Pieces[Index] = Piece

	return Piece
end

-- The pictures: one at every Trail Spacing along the path, where the cursor was when it passed that mark (turned as it was
-- then), aged since: smaller with Shrink Over Time, fading, and coloured along the gradient.
const function DrawPieces(Preview: Preview, Looks: Looks, Now: number)
	const Pieces = Preview.Pieces
	const Spacing = Looks.TrailSpacing
	local Used = 0

	-- (a cursor of no size lays nothing)
	if Spacing > 1e-4 then
		const Seconds = Looks.TrailFade
		const Last = math.floor(DistanceAt(Now) / Spacing)
		const First = math.max(math.ceil(DistanceAt(Now - Seconds) / Spacing), Last - MaxPieces + 1)
		const Side = Looks.CursorSize * Preview.Unit
		const Gradient = Looks.TrailGradient ~= nil
		const Solid = Looks.TrailSolid or Looks.CursorTint
		-- (no trail picture in a hollow cursor's open middle, as the game draws it)
		const Clear = Looks.TrailClear * Side
		const CentreX, CentreY = PixelAt(Preview, Now)

		for Mark = First, Last do
			const At = TimeAt(Mark * Spacing)
			const Age = (Now - At) / Seconds

			if Age < 0 or Age >= 1 then
				continue
			end

			const X, Y = PixelAt(Preview, At)
			const Wide = Side * (if Looks.TrailShrink then 1 - Age else 1)

			if Clear > 0 and (X - CentreX) ^ 2 + (Y - CentreY) ^ 2 < (Clear + Wide * PictureReach) ^ 2 then
				continue
			end

			Used += 1

			const Piece = PieceAt(Preview, Looks, Used)

			Piece.Position = UDim2.fromOffset(X, Y)
			Piece.Size = UDim2.fromOffset(Wide, Wide)
			Piece.Rotation = (Looks.CursorSpin * At) % 360
			Piece.ImageColor3 = if Gradient then Looks.Hues[math.round(Age * (ColorLevels - 1)) + 1] else Solid
			Piece.ImageTransparency = 1 - Looks.TrailOpacity * (1 - Age)
			Piece.Visible = true
		end
	end

	for Index = Used + 1, #Pieces do
		Pieces[Index].Visible = false
	end
end

-- The trail, when Cursor Trail is on: the smooth line, or the pictures.
const function DrawTrail(Preview: Preview, Looks: Looks, Now: number)
	if not Looks.Trail then
		return
	end

	if Looks.TrailLine then
		DrawLine(Preview, Looks, Now)
	else
		DrawPieces(Preview, Looks, Now)
	end
end

-- The cursor where the path is now, turned by Cursor Rotation's degrees a second.
const function DrawCursor(Preview: Preview, Looks: Looks, Now: number)
	const X, Y = PixelAt(Preview, Now)

	Preview.Cursor.Position = UDim2.fromOffset(X, Y)
	Preview.Cursor.Rotation = (Looks.CursorSpin * Now) % 360
end

-- A frame of the card at its clock: the space, the notes, the trail and the cursor (the settings read first if they changed).
const function DrawCard(Preview: Preview, Delta: number)
	Preview.Clock += Delta

	if Preview.Dirty or Preview.Looks == nil then
		Refresh(Preview)
	end

	const Looks = Preview.Looks :: Looks
	const Now = Preview.Clock

	DrawScenery(Preview, Looks, Delta, Now)
	DrawNotes(Preview, Looks, Now)
	DrawTrail(Preview, Looks, Now)
	DrawCursor(Preview, Looks, Now)
end

-- Shows the card, from the start of its loop and with the settings read again.
const function OpenCard(Preview: Preview)
	if Preview.Drawn then
		return
	end

	Preview.Drawn = true
	Preview.Clock = WarmClock
	Preview.Tint = nil
	Preview.Dirty = true
	Preview.Card.Visible = true
end

-- Hides the card, and takes its space out (a moving one, or a video, shouldn't run on behind a closed card).
const function CloseCard(Preview: Preview)
	if not Preview.Drawn then
		return
	end

	Preview.Drawn = false
	Preview.Card.Visible = false
	DropScenery(Preview, false)
end

-- The card at an alpha (the menu's fade times its own opening), risen as far as it has opened.
const function ShowAt(Preview: Preview, Alpha: number, Open: number)
	if Alpha ~= Preview.ShownAlpha then
		Preview.ShownAlpha = Alpha
		-- (the card fades from and to the panel's black: the cover is clear once it's fully shown)
		Preview.Cover.BackgroundTransparency = Alpha
	end

	if Open ~= Preview.ShownOpen then
		Preview.ShownOpen = Open
		Preview.Card.Position = UDim2.fromOffset(Preview.RestX, Preview.RestY + math.round(SlideOffset * (1 - Open)))
	end
end

-- Places the button at the foot of the sidebar and the card in the room above it, for the holder's size and the number of
-- sections the sidebar lists (Geometry's panels, as UI/SettingsMenu lays them out).
const function Layout(Preview: Preview, Width: number, Height: number, Count: number)
	const Column = Geometry.PanelsOf(Width, Height).Sidebar
	const ButtonRect: Rect = {
		X = Column.X + Margin,
		Y = Column.Y + Column.Height - Margin - ButtonHeight,
		Width = Column.Width - 2 * Margin,
		Height = ButtonHeight,
	}
	const Top = Column.Y + Geometry.SidebarRowTop(Count) + Margin
	const Bottom = ButtonRect.Y - Margin
	const Side = math.min(ButtonRect.Width, Bottom - Top)

	Preview.LaidWidth = Width
	Preview.LaidHeight = Height
	Preview.LaidCount = Count
	Preview.Room = Side >= MinSide
	Buttons.Place(Preview.Button, ButtonRect)

	if not Preview.Room then
		return
	end

	Preview.Unit = Side / UnitsAcross
	Preview.Center = Side / 2
	Preview.RestX = Column.X + (Column.Width - Side) // 2
	Preview.RestY = Bottom - Side
	Preview.Card.Size = UDim2.fromOffset(Side, Side)
	-- (placed again on its next frame, and its pieces sized for the new unit)
	Preview.ShownOpen = -1
	Preview.Dirty = true
end

-- One frame while the menu's root is visible: the button and the card follow the holder's size, the section shown and the
-- menu's fade, and the card draws while it can be seen.
const function StepCard(Preview: Preview, Delta: number)
	-- (nothing of AIMIA's runs while the handheld is closed, UI/Frames: the card closes, and its space goes with it)
	if Frames.Paused then
		CloseCard(Preview)

		return
	end

	const Host = Preview.Host
	const Size = Host.Holder.Size
	const Count = Host.Sections()

	if Size.X.Offset ~= Preview.LaidWidth or Size.Y.Offset ~= Preview.LaidHeight or Count ~= Preview.LaidCount then
		Layout(Preview, Size.X.Offset, Size.Y.Offset, Count)
	end

	const Visual = Preview.Room and Host.Section() == VisualSection

	if Visual ~= Preview.Visual then
		Preview.Visual = Visual
		Preview.Button.Object.Visible = Visual
		-- (a section switch is instant, as the rows' is: the card comes and goes with its section)
		Fade.Set(Preview.Toggle, if Visual and Preview.Wanted then 1 else 0)
	end

	const Open = Preview.Toggle.Alpha
	const Alpha = Open * Host.Overlay.Alpha

	if Alpha <= 0 then
		CloseCard(Preview)

		return
	end

	OpenCard(Preview)
	ShowAt(Preview, Alpha, Open)
	DrawCard(Preview, math.min(Delta, MaxDelta))
end

-- Ends the card's frame step.
const function Stop(Preview: Preview)
	const Stepping = Preview.Stepping

	Preview.Stepping = nil

	if Stepping then
		Stepping:Disconnect()
	end
end

-- Stops the card for good after a problem, with one warning: its button and card go, and the menu carries on.
const function Break(Preview: Preview, Problem: unknown)
	if Preview.Broken then
		return
	end

	Preview.Broken = true
	warn("[AIMIA] the settings preview stopped: " .. tostring(Problem))
	Stop(Preview)
	pcall(function()
		Preview.Button.Object.Visible = false
		Preview.Card.Visible = false
		DropScenery(Preview, false)
	end)
end

-- Runs the card's step while the menu's root is visible, and stops it (closing the card) when the root hides.
const function Watch(Preview: Preview)
	if Preview.Broken then
		return
	end

	if Preview.Host.Root.Visible then
		if Preview.Stepping == nil then
			Preview.Stepping = RunService.PreRender:Connect(function(Delta: number)
				const Stepped, Problem = pcall(StepCard, Preview, Delta)

				if not Stepped then
					Break(Preview, Problem)
				end
			end)
		end

		return
	end

	Stop(Preview)

	const Closed, Problem = pcall(CloseCard, Preview)

	if not Closed then
		Break(Preview, Problem)
	end
end

-- Builds the button and the card (both hidden) in the menu's holder, then starts watching the menu's root and the settings
-- the card shows.
const function Build(Host: Host): Preview
	const Holder = Host.Holder
	-- (a plain frame, never a CanvasGroup: one redraws its whole picture every frame its moving pieces move, and Roblox lowers
	-- its resolution when busy, which blurs it. The card fades with a cover of the panel's black over it instead)
	const Group: CanvasGroup? = nil
	const Card: GuiObject = Instance.new("Frame")

	Card.Name = "PreviewCard"
	Card.BackgroundTransparency = 1
	Card.BorderSizePixel = 0
	Card.ClipsDescendants = true
	Card.ZIndex = CardZ
	Card.Active = false
	Card.Visible = false
	Draw.Corner(Card, Look.Corner)

	const Fill = Instance.new("Frame")

	Fill.Name = "Fill"
	Fill.BorderSizePixel = 0
	Fill.BackgroundColor3 = ClearFill
	Fill.Size = UDim2.fromScale(1, 1)
	Fill.ZIndex = FillZ
	Fill.Parent = Card

	const Scenery = Instance.new("Frame")

	Scenery.Name = "Space"
	Scenery.BackgroundTransparency = 1
	Scenery.BorderSizePixel = 0
	Scenery.ClipsDescendants = true
	Scenery.Size = UDim2.fromScale(1, 1)
	Scenery.ZIndex = SceneryZ
	Scenery.Parent = Card

	const Cover = Instance.new("Frame")

	Cover.Name = "Cover"
	Cover.BorderSizePixel = 0
	Cover.BackgroundColor3 = Color3.new(0, 0, 0)
	Cover.BackgroundTransparency = 1
	Cover.Size = UDim2.fromScale(1, 1)
	Cover.ZIndex = CoverZ
	Cover.Parent = Card

	const Border = NewImage(Card, "Border", BorderZ)
	const Grid = NewImage(Card, "Grid", GridZ)
	const Head = NewBar(Card, "TrailHead", TrailZ)
	const Cursor = NewImage(Card, "Cursor", CursorZ)
	const Round = Instance.new("UICorner")
	const Notes: { NoteSlot } = {}

	Border.Position = UDim2.fromScale(0.5, 0.5)
	Grid.Position = UDim2.fromScale(0.5, 0.5)
	Grid.Size = UDim2.fromScale(1, 1)
	Head.Visible = false
	Round.CornerRadius = UDim.new(0.5, 0)
	Round.Parent = Head

	for Index = 1, MaxNotes do
		table.insert(Notes, NewNote(Card, Index))
	end

	local Preview: Preview

	const function Pressed()
		Preview.Wanted = not Preview.Wanted
		Buttons.SetText(Preview.Button, if Preview.Wanted then CloseText else OpenText)
		Fade.Go(Preview.Toggle, if Preview.Wanted then 1 else 0, ToggleSeconds, Motion.EaseOut, nil)
	end

	const function MarkDirty(_: unknown)
		Preview.Dirty = true
	end

	const Button = Buttons.New(Holder, {
		Name = "PreviewButton",
		Rect = { X = 0, Y = 0, Width = 0, Height = 0 },
		ZIndex = CardZ,
		Style = Look.RowButton,
		Text = OpenText,
		Font = Look.Fonts.Default,
		FontSize = Look.Sizes.Body,
		Align = Enum.TextXAlignment.Center,
		Overlay = Host.Overlay,
		OnActivated = Pressed,
	})
	const Toggle = Fade.New(function() end)

	Button.Object.Visible = false
	Tooltip.Attach(Host.Tooltip, Button.Object, ButtonTip)
	Fade.Set(Toggle, 0)

	Preview = {
		Host = Host,
		Button = Button,
		Card = Card,
		Group = Group,
		Cover = Cover,
		Fill = Fill,
		Scenery = Scenery,
		Border = Border,
		Grid = Grid,
		Notes = Notes,
		Slices = {},
		SliceCount = 0,
		Head = Head,
		Pieces = {},
		Cursor = Cursor,
		Background = nil,
		Counter = nil,
		CounterScale = nil,
		CounterFactor = -1,
		Floor = nil,
		SceneryKey = nil,
		Looks = nil,
		Tint = nil,
		Toggle = Toggle,
		Wanted = false,
		Visual = false,
		Room = false,
		Drawn = false,
		Dirty = true,
		Broken = false,
		Unit = 0,
		Center = 0,
		RestX = 0,
		RestY = 0,
		LaidWidth = -1,
		LaidHeight = -1,
		LaidCount = -1,
		ShownAlpha = -1,
		ShownOpen = -1,
		Clock = WarmClock,
		Stepping = nil,
		Watching = nil,
		Graphics = nil,
		Signals = {},
		MarkDirty = MarkDirty,
	}

	Card.Parent = Holder

	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile

	for _, Name in Watched do
		const Item = SettingsProfile.ItemNamed(Settings, Name)

		if Item then
			Signal.Connect(Item.Updated, MarkDirty)
			table.insert(Preview.Signals, Item.Updated)
		end
	end

	Signal.Connect(SkinManager.Loaded, MarkDirty)
	Preview.Watching = Host.Root:GetPropertyChangedSignal("Visible"):Connect(function()
		Watch(Preview)
	end)

	-- (changing the Roblox graphics bars turns Note Glow's glow on or off in a song, so the card follows)
	pcall(function()
		Preview.Graphics = UserSettings():GetService("UserGameSettings"):GetPropertyChangedSignal("SavedQualityLevel"):Connect(MarkDirty)
	end)
	Watch(Preview)

	return Preview
end

-- Builds the Preview button and its card in the menu's holder (they show in the Visual section), or answers nil with a
-- warning when they can't be built: the menu works on without them.
const function New(Host: Host): Preview?
	const Built, Made = pcall(Build, Host)

	if Built then
		return Made
	end

	warn("[AIMIA] the settings preview could not be made: " .. tostring(Made))

	-- (whatever was made before the problem goes)
	for _, Name in { "PreviewCard", "PreviewButton" } do
		const Left = Host.Holder:FindFirstChild(Name)

		if Left then
			Left:Destroy()
		end
	end

	return nil
end

-- Stops the card and lets go of all it holds: its step, its watchers, its space, and its button and card.
const function DestroyNow(Preview: Preview)
	Preview.Broken = true
	Stop(Preview)
	Fade.Stop(Preview.Toggle)

	const Watching = Preview.Watching

	Preview.Watching = nil

	if Watching then
		Watching:Disconnect()
	end

	const Graphics = Preview.Graphics

	Preview.Graphics = nil

	if Graphics then
		Graphics:Disconnect()
	end

	for _, Updated in Preview.Signals do
		Signal.Disconnect(Updated, Preview.MarkDirty)
	end

	table.clear(Preview.Signals)
	Signal.Disconnect(SkinManager.Loaded, Preview.MarkDirty)
	DropScenery(Preview, false)

	for _, Link in Preview.Button.Connections do
		Link:Disconnect()
	end

	-- (the menu's fade lets go of the button before it goes)
	Fade.Forget(Preview.Host.Overlay, Preview.Button.Object)
	Preview.Button.Object:Destroy()
	Preview.Card:Destroy()
end

-- The card goes with the menu (UI/SettingsMenu's Destroy): a problem here is only warned about, so the menu's own clean-up
-- runs on.
const function Destroy(Preview: Preview)
	const Done, Problem = pcall(DestroyNow, Preview)

	if not Done then
		warn("[AIMIA] the settings preview did not close cleanly: " .. tostring(Problem))
	end
end

return {
	New = New,
	Destroy = Destroy,
}
