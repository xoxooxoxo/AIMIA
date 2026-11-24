--!strict
--!optimize 2

--[[
	The cursor trail, as Rhythia's own Cursor Trail settings describe it (Settings > Cursor > Cursor Trail): pieces left behind
	the cursor that fade over Trail Fade Time, get smaller with age when Shrink Over Time is on, at Trail Opacity, Trail Spacing
	apart, coloured by Trail Color (the cursor's colour, white, Rhythia's rainbow gradient, or a skin's gradient). Trail Image
	picks the pieces: "smooth line" (one tapered line, the trail of the rhythia.com map preview), "cursor" (copies of the cursor's
	picture, Rhythia's default "inherit from cursor"), or a skin's trail picture. Every setting is read from the attempt's
	settings, so a replay, a Leaderboards replay or a spectated player shows the trail the player had.

	Smoothness
		The cursor's path is kept as timed points (one a frame) and read back through a Hermite curve whose tangents are the
		cursor's speed at each point (time-based Catmull-Rom, tangents capped so a sudden stop can't loop), so the trail bends
		smoothly between frames instead of in straight steps. Each piece gets the exact time the cursor passed it, not the time of
		the frame that drew it, so pieces fade evenly along the trail at any frame rate.
		The smooth line is one Beam per slice of age (Trail Fade Time / Slices): a slice keeps its age, so its width,
		transparency and colour stay set and only the attachments move each frame. Pictures are square textured Beams, pooled,
		laid Trail Spacing x the cursor's size apart along the curve (further apart only when a long fast trail would need more than
		MaxPieces); their transparency and colour use cached sequences, and a piece that doesn't shrink is placed once.

	Representation
		PX, PY, PT, PR: the path's points from First to Last (Godot units on the grid plane, seconds, radians), oldest first.
		Pieces: the live pictures, oldest first; Spare: hidden pieces for reuse.

	Design Notes
		Replaces TrailRenderer.cs's spawner (one cursor copy a frame at a time-based rate, TrailDetail), which left gaps when the
		cursor moved fast at 60 fps. TrailDetail stays in the settings (hidden) so old profiles and replays still load.
		The cursor draws over the trail because GameWorld draws its quad a little nearer the camera (CursorLift): level with
		the grid, Roblox drew the trail's beams over it at most spots, and it dimmed and brightened as it moved. A beam draws
		a plain square until its picture has loaded on the 3D side, so every trail picture is prepared as AIMIA opens, and
		pieces and the head's half disc wait until theirs is (Picture).
		A hollow cursor (CursorStyles.HoleOf; the default skin's cursor.png is a rounded square outline) would show the trail's
		head through its open middle: the line starts at the middle's edge (while the cursor shows), and copies of its picture stay
		OutlineSpacing apart, as closer their outlines ran together into a smear. A trail picture (a skin's dots or drawing) is
		hidden while its middle is that close (PictureReach), so none sits inside the cursor.
]]

const AttemptModule = require("../Attempt")
const CursorStyles = require("../../Skinning/CursorStyles")
const GameWorld = require("./GameWorld")
const RendererModule = require("../Renderers/Renderer")
const SettingsProfile = require("../../Database/Settings/SettingsProfile")
const SkinProfile = require("../../Skinning/SkinProfile")
const SkinSets = require("../../Skinning/SkinSets")
const Tone = require("./Tone")
const WorldTransform = require("./WorldTransform")

const ContentProvider = game:GetService("ContentProvider")
const RunService = game:GetService("RunService")

export type Runner = {
	Attempt: AttemptModule.Attempt,
	Playing: boolean,
	-- seeks so far (Game/Runner): the trail starts again after each
	Seeks: number,
}

type Piece = {
	X: number,
	Y: number,
	T: number,
	R: number,
	Beam: Beam,
	A0: Attachment,
	A1: Attachment,
	Level: number,
	Hue: number,
	Wide: number,
}

-- A picture for beams, and whether they can show it yet: a beam draws a plain square until its picture's 3D form has loaded,
-- and Roblox makes that form on the first request in a while, which takes seconds ("Asset content representation is being
-- generated"), while a GUI image of the same picture shows at once (a player's trail showed as grey squares at the start of
-- a song). So a picture counts as ready only once ContentProvider has prepared it for a beam (Prepare) and a hidden beam has
-- drawn it for WarmSeconds.
type Picture = {
	-- a hidden beam that draws the picture, so the 3D side keeps it loaded
	Warm: Beam,
	Content: Content?,
	-- the uploaded image's address ("" for a drawn picture: a beam can't show one)
	Uri: string,
	-- when the picture was first found prepared (os.clock), or -1 until then
	Since: number,
}

export type View = {
	World: GameWorld.World,
	Runner: Runner,
	-- the runner's seek count the trail was last drawn for
	Seeks: number,
	Ticks: () -> number,
	Anchor: Part,
	PX: { number },
	PY: { number },
	PT: { number },
	PR: { number },
	First: number,
	Last: number,
	LineAttachments: { Attachment },
	LineBeams: { Beam },
	LineSlices: number,
	LineShown: boolean,
	Cap: Beam?,
	Cap0: Attachment?,
	Cap1: Attachment?,
	-- the trail's picture and the head's half disc: beams show them only once ready (Picture)
	Picture: Picture,
	CapPicture: Picture,
	Pieces: { Piece },
	Spare: { Piece },
	LaidUntil: number,
	Carry: number,
	-- what the pieces and the line were last set up for
	Image: string,
	ColorName: string,
	Opacity: number,
	Shrink: boolean,
	Fade: number,
	Size: number,
	Core: number,
	-- how far a hollow cursor's open middle reaches from its centre, as a share of its quad (CursorStyles.HoleOf); 0 when solid
	Hole: number,
	Tint: Color3?,
	Content: Content?,
	Transparencies: { NumberSequence },
	Hues: { ColorSequence },
	Solid: ColorSequence,
}

-- the two Trail Image choices that aren't a skin's picture
const LineName = "smooth line"
const CursorName = "cursor"

-- the trail's plane: a hair behind the cursor quad's face (QuadThickness / 2 = 0.025 in front of the grid plane)
const PlaneZ = 0.02
-- the smooth line: one curved beam per SliceSeconds of fade, within these bounds, each drawn in LineSegments pieces. Neighbouring
-- beams share an attachment turned along the path, so their edges meet exactly (separate straight beams overlapped at every
-- bend, and their see-through overlaps showed as stripes). 3 ms slices give the default 0.1 s fade 33 of them, as dense as the
-- rhythia.com preview's trail (about 34 points over 0.1 s): 8 ms (13 slices) showed as corners on fast turns.
const SliceSeconds = 0.003
const MinSlices = 6
const MaxSlices = 40
const LineSegments = 8
-- the line's round head: a half disc (flat side at the head, round side forward), drawn as one more flat beam
const CapImage = "rbxassetid://102387800003792"
-- the line is as wide as the cursor's body at its head (CursorStyles.CoreOf); Shrink Over Time tapers it as the map preview's taper
-- of 0.5 does
const LineTaper = 0.5
-- with Shrink Over Time the line's tail keeps this much of its opacity (its width is gone by then); without it, it fades out
const LineTailAlpha = 0.35
-- pictures alive at once at most, and the closest they're laid, in cursor sizes (the closest a skin's own Trail Spacing goes):
-- a long fast trail spaces its pictures out a little to stay within MaxPieces instead of losing its tail
const MaxPieces = 240
const MinSpacing = 0.05
-- the closest copies of a hollow cursor's picture are laid, in cursor sizes: closer, their outlines run together into a smear
-- (the skins' Trail Spacing of 0.05 was made for their solid cursors)
const OutlineSpacing = 0.25
-- a trail picture stays hidden while its middle is within a hollow cursor's open middle and this share of its own width more
-- (the smooth line starts at the open middle's edge; copies of the cursor's own picture are its outline and stay)
const PictureReach = 0.35
-- a gap this long (a pause) starts a new path; so does a seek (Process watches the runner's seek count)
const JumpGap = 0.3
-- a curve tangent may be at most this many times its segment's chord
const TangentLimit = 1.5
-- the head's cap shows once the cursor moves faster than this (grid units a second) and hides once it's slower than the
-- second: one threshold flickered it on and off every frame while the cursor crept
const CapShowSpeed = 0.025
const CapHideSpeed = 0.006
-- the cap's speed and way are read over this much of the newest path: over one 3 ms slice, a frame the mouse didn't move in
-- (240 FPS with a slower mouse) read as standing still and the cap flickered, and a creep at a note turned it sideways
const CapSeconds = 0.008
-- cached transparency and colour steps for pictures
const Levels = 64
const ColorLevels = 32
-- the path keeps this much more than the fade time
const HistoryMargin = 0.1
-- beams show a picture this long after it has been prepared (meanwhile the hidden beam draws it, so the 3D side has it too)
const WarmSeconds = 0.3
-- the hidden beam: this wide and this see-through (nothing shows), at the grid's middle a hair behind the trail
const WarmWidth = 0.01
const WarmTransparency = 0.98
-- a picture that failed to prepare is asked for again after this long, up to this many tries in a row (then again whenever
-- a trail needs it)
const RetrySeconds = 2
const PrepareTries = 3

const function ShortAngle(From: number, To: number): number
	const Turn = 2 * math.pi

	return (To - From + math.pi) % Turn - math.pi
end

-- Starts a new path (a jump, a pause, the start of a run). Pieces already laid stay and fade.
const function ResetPath(View: View)
	View.First = 1
	View.Last = 0
	View.Carry = 0
end

const function AddPoint(View: View, X: number, Y: number, T: number, R: number)
	const Last = View.Last

	if Last >= View.First then
		if T - View.PT[Last] > JumpGap then
			ResetPath(View)
			View.LaidUntil = T
		elseif T <= View.PT[Last] then
			View.PX[Last], View.PY[Last], View.PR[Last] = X, Y, R

			return
		end
	end

	const At = View.Last + 1

	View.Last = At
	View.PX[At], View.PY[At], View.PT[At], View.PR[At] = X, Y, T, R
end

-- Drops points older than Before, keeping at least two, and packs the arrays now and then.
const function DropOld(View: View, Before: number)
	while View.Last - View.First >= 2 and View.PT[View.First + 1] < Before do
		View.First += 1
	end

	if View.First > 256 then
		const Count = View.Last - View.First + 1

		table.move(View.PX, View.First, View.Last, 1)
		table.move(View.PY, View.First, View.Last, 1)
		table.move(View.PT, View.First, View.Last, 1)
		table.move(View.PR, View.First, View.Last, 1)
		View.First = 1
		View.Last = Count
	end
end

-- The path at time T within the segment from point I to I + 1: a Hermite curve with the cursor's speed as tangents.
const function SegmentAt(View: View, I: number, T: number): (number, number, number)
	const PX, PY, PT, PR = View.PX, View.PY, View.PT, View.PR
	const X1, Y1, T1 = PX[I], PY[I], PT[I]
	const X2, Y2, T2 = PX[I + 1], PY[I + 1], PT[I + 1]
	const H = T2 - T1

	if H <= 0 then
		return X2, Y2, PR[I + 1]
	end

	const S = math.clamp((T - T1) / H, 0, 1)
	local X0, Y0, T0 = 2 * X1 - X2, 2 * Y1 - Y2, T1 - H

	if I > View.First then
		X0, Y0, T0 = PX[I - 1], PY[I - 1], PT[I - 1]
	end

	local X3, Y3, T3 = 2 * X2 - X1, 2 * Y2 - Y1, T2 + H

	if I + 2 <= View.Last then
		X3, Y3, T3 = PX[I + 2], PY[I + 2], PT[I + 2]
	end

	local VX1, VY1 = (X2 - X0) / (T2 - T0) * H, (Y2 - Y0) / (T2 - T0) * H
	local VX2, VY2 = (X3 - X1) / (T3 - T1) * H, (Y3 - Y1) / (T3 - T1) * H
	const Cap = TangentLimit * math.sqrt((X2 - X1) * (X2 - X1) + (Y2 - Y1) * (Y2 - Y1))
	const L1 = math.sqrt(VX1 * VX1 + VY1 * VY1)
	const L2 = math.sqrt(VX2 * VX2 + VY2 * VY2)

	if L1 > Cap then
		const K = if L1 > 0 then Cap / L1 else 0

		VX1 *= K
		VY1 *= K
	end

	if L2 > Cap then
		const K = if L2 > 0 then Cap / L2 else 0

		VX2 *= K
		VY2 *= K
	end

	const S2 = S * S
	const S3 = S2 * S
	const H00 = 2 * S3 - 3 * S2 + 1
	const H10 = S3 - 2 * S2 + S
	const H01 = -2 * S3 + 3 * S2
	const H11 = S3 - S2
	const R1 = PR[I]

	return H00 * X1 + H10 * VX1 + H01 * X2 + H11 * VX2,
		H00 * Y1 + H10 * VY1 + H01 * Y2 + H11 * VY2,
		R1 + ShortAngle(R1, PR[I + 1]) * S
end

-- The trail's colour at a fraction of its fade (0 at the cursor, 1 at the tail), toned for the 3D world.
const function ColorAt(View: View, Fraction: number): Color3
	const Gradient = SkinSets.TrailGradient(View.ColorName)

	if Gradient then
		const R, G, B = SkinSets.GradientAt(Gradient, Fraction)

		return Tone.Color(R, G, B)
	end

	const Solid = SkinSets.TrailSolid(View.ColorName)

	if Solid then
		return Tone.Color(Solid.R, Solid.G, Solid.B)
	end

	return View.Tint or Tone.Color(1, 1, 1)
end

-- A beam between two attachments on the anchor (new ones unless given), hidden until drawn.
const function NewBeam(View: View, Given0: Attachment?, Given1: Attachment?): (Beam, Attachment, Attachment)
	local A0 = Given0
	local A1 = Given1

	if A0 == nil then
		A0 = Instance.new("Attachment")
		A0.Parent = View.Anchor
	end

	if A1 == nil then
		A1 = Instance.new("Attachment")
		A1.Parent = View.Anchor
	end

	const Beam = Instance.new("Beam")

	Beam.Attachment0 = A0
	Beam.Attachment1 = A1
	Beam.FaceCamera = true
	Beam.Segments = 1
	Beam.LightInfluence = 0
	Beam.LightEmission = 0
	Beam.Brightness = 1
	Beam.TextureMode = Enum.TextureMode.Stretch
	Beam.TextureLength = 1
	Beam.TextureSpeed = 0
	-- (a hair further away, still in front of the grid's own picture and border; the cursor draws over the trail because its
	-- quad is drawn nearer the camera, GameWorld's CursorLift)
	Beam.ZOffset = -0.01
	Beam.Enabled = false
	Beam.Parent = View.Anchor

	return Beam, A0 :: Attachment, A1 :: Attachment
end

const function HideLine(View: View)
	if View.LineShown then
		for _, Beam in View.LineBeams do
			Beam.Enabled = false
		end

		if View.Cap then
			View.Cap.Enabled = false
		end

		View.LineShown = false
	end
end

-- Pictures ContentProvider has prepared for beams (by address), and when each was last asked for (math.huge while it is
-- being prepared): a beam shows a prepared picture at once, an unprepared one as a plain square for seconds.
const Prepared: { [string]: boolean } = {}
const Asked: { [string]: number } = {}

-- Asks ContentProvider to prepare pictures for beams, each through a beam of its own (a GUI image of a picture doesn't
-- prepare it for beams); a picture being prepared, or that failed less than RetrySeconds ago, is left.
const function Prepare(Uris: { string })
	const Now = os.clock()

	for _, Uri in Uris do
		if Uri == "" or Prepared[Uri] or Now - (Asked[Uri] or -math.huge) < RetrySeconds then
			continue
		end

		Asked[Uri] = math.huge

		task.spawn(function()
			const Beam = Instance.new("Beam")

			Beam.TextureContent = SkinSets.ContentOf(Uri)

			for Try = 1, PrepareTries do
				local Failed = false

				const Ok = pcall(function()
					ContentProvider:PreloadAsync({ Beam }, function(_: string, Status: Enum.AssetFetchStatus)
						if Status ~= Enum.AssetFetchStatus.Success then
							Failed = true
						end
					end)
				end)

				if Ok and not Failed then
					Prepared[Uri] = true

					break
				end

				if Try < PrepareTries then
					task.wait(RetrySeconds)
				end
			end

			Beam:Destroy()
			Asked[Uri] = os.clock()
		end)
	end
end

-- Gives a slot its picture (nil: none); a new picture has to be prepared and warm again.
const function SetPicture(Picture: Picture, Next: Content?)
	if Next == Picture.Content then
		return
	end

	Picture.Content = Next
	Picture.Uri = if Next then Next.Uri or "" else ""
	Picture.Since = -1
	Picture.Warm.TextureContent = Next or Content.none
	Picture.Warm.Enabled = Next ~= nil
end

-- A picture slot and its hidden beam (on the anchor).
const function NewPicture(Anchor: Part, Start: Content?): Picture
	const A0 = Instance.new("Attachment")
	const A1 = Instance.new("Attachment")

	A0.Position = Vector3.new(0, 0, PlaneZ - 0.01)
	A1.Position = Vector3.new(WarmWidth, 0, PlaneZ - 0.01)
	A0.Parent = Anchor
	A1.Parent = Anchor

	const Warm = Instance.new("Beam")

	Warm.Name = "TrailWarm"
	Warm.Attachment0 = A0
	Warm.Attachment1 = A1
	Warm.FaceCamera = true
	Warm.Segments = 1
	Warm.LightInfluence = 0
	Warm.Width0 = WarmWidth
	Warm.Width1 = WarmWidth
	Warm.Transparency = NumberSequence.new(WarmTransparency)
	Warm.Enabled = false
	Warm.Parent = Anchor

	const Picture: Picture = {
		Warm = Warm,
		Content = nil,
		Uri = "",
		Since = -1,
	}

	SetPicture(Picture, Start)

	return Picture
end

-- Whether beams can show the slot's picture now (no picture: plain squares are what's meant); a picture that isn't prepared
-- yet is asked for (again, if it failed).
const function PictureReady(Picture: Picture): boolean
	if Picture.Content == nil then
		return true
	end

	if Picture.Since < 0 then
		if Prepared[Picture.Uri] then
			Picture.Since = os.clock()
		elseif Picture.Uri ~= "" and os.clock() - (Asked[Picture.Uri] or -math.huge) >= RetrySeconds then
			Prepare({ Picture.Uri })
		end

		return false
	end

	return os.clock() - Picture.Since >= WarmSeconds
end

const function HidePieces(View: View)
	for _, Piece in View.Pieces do
		Piece.Beam.Enabled = false
		table.insert(View.Spare, Piece)
	end

	table.clear(View.Pieces)
end

-- Reads the settings and the world into the view; the line's and the pieces' fixed properties are set again when they change.
const function Configure(View: View, Settings: SettingsProfile.SettingsProfile)
	const Image = Settings.TrailImage.Value :: string
	const ColorName = Settings.TrailColor.Value :: string
	const Opacity = math.clamp(Settings.TrailOpacity.Value :: number, 0, 1)
	const Shrink = Settings.TrailShrink.Value :: boolean
	const Fade = math.max(Settings.TrailTime.Value :: number, 0.005)
	const Size = View.World.CursorSize
	-- (the style the cursor was drawn with at the run's start, GameWorld.Setup: a change mid-song waits for the next song, as
	-- the cursor does)
	const Style = View.World.CursorStyle
	const Core = CursorStyles.CoreOf(Style)
	const Hole = CursorStyles.HoleOf(Style)
	const Tint = View.World.CursorTint
	-- (the cursor's own picture as an uploaded image: a beam can't show the drawn ones)
	const Content = if Image == CursorName then CursorStyles.TrailContentOf(Style) else SkinSets.TrailPicture(Image)

	if Image == View.Image and ColorName == View.ColorName and Opacity == View.Opacity and Shrink == View.Shrink and Fade == View.Fade
		and Size == View.Size and Core == View.Core and Hole == View.Hole and Tint == View.Tint and Content == View.Content
	then
		return
	end

	const ImageChanged = Image ~= View.Image or Content ~= View.Content

	SetPicture(View.Picture, Content)

	View.Image = Image
	View.ColorName = ColorName
	View.Opacity = Opacity
	View.Shrink = Shrink
	View.Fade = Fade
	View.Size = Size
	View.Core = Core
	View.Hole = Hole
	View.Tint = Tint
	View.Content = Content

	-- the smooth line: slices of age, each with its own width, transparency and colour
	const Slices = math.clamp(math.round(Fade / SliceSeconds), MinSlices, MaxSlices)

	for Index = #View.LineAttachments + 1, Slices + 1 do
		const A = Instance.new("Attachment")

		A.Parent = View.Anchor
		View.LineAttachments[Index] = A
	end

	for Index = #View.LineBeams + 1, Slices do
		const Beam = NewBeam(View, View.LineAttachments[Index], View.LineAttachments[Index + 1])

		Beam.Segments = LineSegments
		Beam.FaceCamera = false
		View.LineBeams[Index] = Beam
	end

	for Index, Beam in View.LineBeams do
		if Index > Slices then
			Beam.Enabled = false

			continue
		end

		-- (a line on screen keeps showing the slices it has now)
		if View.LineShown then
			Beam.Enabled = true
		end

		const F0, F1 = (Index - 1) / Slices, Index / Slices
		const W0 = Size * Core * (if Shrink then (1 - F0) ^ LineTaper else 1)
		const W1 = Size * Core * (if Shrink then (1 - F1) ^ LineTaper else 1)
		const Tail = if Shrink then LineTailAlpha else 0
		const Alpha0 = Opacity * (1 - (1 - Tail) * F0)
		const Alpha1 = Opacity * (1 - (1 - Tail) * F1)

		Beam.Width0 = W0
		Beam.Width1 = W1
		Beam.Transparency = NumberSequence.new(1 - Alpha0, 1 - Alpha1)
		Beam.Color = ColorSequence.new(ColorAt(View, F0), ColorAt(View, F1))
	end

	View.LineSlices = Slices

	if not View.Cap then
		const Cap, Cap0, Cap1 = NewBeam(View)

		Cap.FaceCamera = false
		Cap.TextureContent = SkinSets.ContentOf(CapImage)
		View.Cap, View.Cap0, View.Cap1 = Cap, Cap0, Cap1
	end

	const Cap = View.Cap :: Beam

	Cap.Width0 = Size * Core
	Cap.Width1 = Size * Core
	Cap.Color = ColorSequence.new(ColorAt(View, 0))
	Cap.Transparency = NumberSequence.new(1 - Opacity)

	-- pictures: cached transparency steps and colour steps
	table.clear(View.Transparencies)

	for Level = 0, Levels - 1 do
		View.Transparencies[Level + 1] = NumberSequence.new(Level / (Levels - 1))
	end

	table.clear(View.Hues)

	for Level = 0, ColorLevels - 1 do
		View.Hues[Level + 1] = ColorSequence.new(ColorAt(View, Level / (ColorLevels - 1)))
	end

	View.Solid = ColorSequence.new(ColorAt(View, 0))

	for _, Piece in View.Pieces do
		Piece.Level = -1
		Piece.Hue = -1
		Piece.Beam.Color = View.Solid

		if ImageChanged then
			Piece.Beam.TextureContent = Content or Piece.Beam.TextureContent
		end
	end

	for _, Piece in View.Spare do
		if ImageChanged then
			Piece.Beam.TextureContent = Content or Piece.Beam.TextureContent
		end
	end
end

-- Where the smooth line's slice points are this frame (reused): X, Y by slice, 0 at the cursor.
const LineX: { number } = {}
const LineY: { number } = {}

-- The smooth line: slice K's attachment sits where the cursor was K slices of fade ago, turned along the path, and each beam
-- curves between its two (a Bezier from the Catmull-Rom tangents of the slice points), so the line bends smoothly and its
-- beams join without seams.
const function DrawLine(View: View, Now: number)
	const Slices = View.LineSlices
	const Fade = View.Fade
	const First, Last = View.First, View.Last
	const Attachments = View.LineAttachments
	const Beams = View.LineBeams
	local I = Last - 1

	for K = 0, Slices do
		const T = Now - Fade * K / Slices
		local X, Y = View.PX[Last], View.PY[Last]

		if K > 0 and Last > First then
			if T <= View.PT[First] then
				X, Y = View.PX[First], View.PY[First]
			else
				while I > First and View.PT[I] > T do
					I -= 1
				end

				X, Y = SegmentAt(View, I, T)
			end
		end

		LineX[K], LineY[K] = X, Y
	end

	-- (a hollow cursor would show the line's head through its open middle: the line starts where the path leaves the middle,
	-- and the points inside are put at that spot, so their slices have no length. Not while the cursor is hidden)
	const Hole = if View.World.Cursors[1].Transparency < 1 then View.Hole * View.Size else 0

	if Hole > 0 then
		const CentreX, CentreY = LineX[0], LineY[0]
		local Out = 1

		while Out <= Slices and (LineX[Out] - CentreX) ^ 2 + (LineY[Out] - CentreY) ^ 2 < Hole * Hole do
			Out += 1
		end

		local EdgeX, EdgeY = CentreX, CentreY

		if Out <= Slices then
			-- (where the step from the last point inside to the first outside crosses the edge)
			const InX, InY = LineX[Out - 1] - CentreX, LineY[Out - 1] - CentreY
			const StepX, StepY = LineX[Out] - LineX[Out - 1], LineY[Out] - LineY[Out - 1]
			const Square = StepX * StepX + StepY * StepY
			const Along = InX * StepX + InY * StepY
			const U = (math.sqrt(math.max(Along * Along - Square * (InX * InX + InY * InY - Hole * Hole), 0)) - Along) / Square

			EdgeX, EdgeY = LineX[Out - 1] + StepX * U, LineY[Out - 1] + StepY * U
		end

		for K = 0, Out - 1 do
			LineX[K], LineY[K] = EdgeX, EdgeY
		end
	end

	-- (tangents run from the cursor towards the tail, in slice steps; Bezier handles are a third of them)
	local PrevSize = 0

	for K = 0, Slices do
		const Back = if K > 0 then K - 1 else 0
		const Ahead = if K < Slices then K + 1 else Slices
		const Steps = Ahead - Back
		const TX = (LineX[Ahead] - LineX[Back]) / Steps
		const TY = (LineY[Ahead] - LineY[Back]) / Steps
		const Length = math.sqrt(TX * TX + TY * TY)
		const AX = if Length > 1e-6 then TX / Length else 1
		const AY = if Length > 1e-6 then TY / Length else 0

		Attachments[K + 1].CFrame = CFrame.new(LineX[K], LineY[K], PlaneZ, AX, -AY, 0, AY, AX, 0, 0, 0, 1)

		const Handle = Length / 3

		if K > 0 then
			const Beam = Beams[K]

			Beam.CurveSize0 = PrevSize
			Beam.CurveSize1 = Handle
		end

		PrevSize = Handle
	end

	if not View.LineShown then
		for Index, Beam in View.LineBeams do
			Beam.Enabled = Index <= Slices
		end

		View.LineShown = true
	end

	-- the head's half disc, pointing the way the cursor is going (none while it stands still: there's no line)
	const Cap = View.Cap

	if Cap then
		const Span = math.clamp(math.round(CapSeconds * Slices / View.Fade), 1, Slices)
		const WayX, WayY = LineX[0] - LineX[Span], LineY[0] - LineY[Span]
		const Way = math.sqrt(WayX * WayX + WayY * WayY)
		const Speed = Way * Slices / (Span * View.Fade)
		-- (none in a hollow cursor: the line starts at the edge of its middle, and the half disc would sit in the middle)
		const Moving = Hole == 0 and (if Cap.Enabled then Speed > CapHideSpeed else Speed > CapShowSpeed)

		if Moving then
			const FX, FY = WayX / Way, WayY / Way
			const Reach = Cap.Width0 / 2

			;(View.Cap0 :: Attachment).CFrame = CFrame.new(LineX[0], LineY[0], PlaneZ, FX, -FY, 0, FY, FX, 0, 0, 0, 1)
			;(View.Cap1 :: Attachment).CFrame = CFrame.new(LineX[0] + FX * Reach, LineY[0] + FY * Reach, PlaneZ, FX, -FY, 0, FY, FX, 0, 0, 0, 1)
		end

		const Show = Moving and PictureReady(View.CapPicture)

		if Cap.Enabled ~= Show then
			Cap.Enabled = Show
		end
	end
end

const function NewPiece(View: View, X: number, Y: number, T: number, R: number)
	local Piece = table.remove(View.Spare)

	if Piece == nil then
		if #View.Pieces >= MaxPieces then
			Piece = table.remove(View.Pieces, 1)
		else
			const Beam, A0, A1 = NewBeam(View)

			Piece = {
				X = 0,
				Y = 0,
				T = 0,
				R = 0,
				Beam = Beam,
				A0 = A0,
				A1 = A1,
				Level = -1,
				Hue = -1,
				Wide = -1,
			}
		end
	end

	const Made = Piece :: Piece

	Made.X, Made.Y, Made.T, Made.R = X, Y, T, R
	Made.Level = -1
	Made.Hue = -1
	Made.Wide = -1

	if View.Content and Made.Beam.TextureContent ~= View.Content then
		Made.Beam.TextureContent = View.Content
	end

	Made.Beam.Color = View.Solid
	table.insert(View.Pieces, Made)
end

-- The path's length since a time, in straight steps between the frames' points (close enough to space pieces by).
const function PathLength(View: View, Since: number): number
	local Length = 0

	for I = View.Last, View.First + 1, -1 do
		if View.PT[I] < Since then
			break
		end

		const DX, DY = View.PX[I] - View.PX[I - 1], View.PY[I] - View.PY[I - 1]

		Length += math.sqrt(DX * DX + DY * DY)
	end

	return Length
end

-- Walks the path from where pieces were last laid to now in short steps, dropping a piece every Spacing Godot units.
const function LayPieces(View: View, Now: number, Spacing: number)
	const First, Last = View.First, View.Last

	if Last <= First then
		View.LaidUntil = Now

		return
	end

	const From = math.max(View.LaidUntil, View.PT[First])

	if Now <= From then
		return
	end

	local I = Last - 1

	while I > First and View.PT[I] > From do
		I -= 1
	end

	local PrevX, PrevY, PrevR = SegmentAt(View, I, From)
	local PrevT = From
	const ChordX, ChordY = View.PX[Last] - PrevX, View.PY[Last] - PrevY
	const Steps = math.clamp(math.ceil(math.sqrt(ChordX * ChordX + ChordY * ChordY) / Spacing * 4), 2, 96)

	for J = 1, Steps do
		const T = From + (Now - From) * J / Steps

		while I < Last - 1 and View.PT[I + 1] < T do
			I += 1
		end

		const X, Y, R = SegmentAt(View, I, T)
		local DX, DY = X - PrevX, Y - PrevY
		local D = math.sqrt(DX * DX + DY * DY)

		while D > 0 and View.Carry + D >= Spacing do
			const U = (Spacing - View.Carry) / D
			const SX, SY = PrevX + DX * U, PrevY + DY * U
			const ST = PrevT + (T - PrevT) * U
			const SR = PrevR + ShortAngle(PrevR, R) * U

			NewPiece(View, SX, SY, ST, SR)
			PrevX, PrevY, PrevT, PrevR = SX, SY, ST, SR
			DX, DY = X - PrevX, Y - PrevY
			D = math.sqrt(DX * DX + DY * DY)
			View.Carry = 0
		end

		View.Carry += D
		PrevX, PrevY, PrevT, PrevR = X, Y, T, R
	end

	View.LaidUntil = Now
end

-- Ages every piece: gone past the fade, otherwise placed at its size, transparency and colour of the moment.
const function DrawPieces(View: View, Now: number, CentreX: number, CentreY: number)
	const Pieces = View.Pieces
	const Fade = View.Fade
	const Size = View.Size
	const Shrink = View.Shrink
	const Opacity = View.Opacity
	const Gradient = SkinSets.TrailGradient(View.ColorName) ~= nil
	const Ready = PictureReady(View.Picture)
	-- (a hollow cursor's open middle, where no trail picture shows while the cursor does)
	const Clear = if View.Image ~= CursorName and View.World.Cursors[1].Transparency < 1 then View.Hole * Size else 0
	local Kept = 0

	for Index = 1, #Pieces do
		const Piece = Pieces[Index]
		const F = (Now - Piece.T) / Fade

		if F >= 1 or F < -0.5 then
			Piece.Beam.Enabled = false
			table.insert(View.Spare, Piece)

			continue
		end

		Kept += 1
		Pieces[Kept] = Piece

		const Age = math.max(F, 0)
		const Wide = Size * (if Shrink then 1 - Age else 1)
		const Beam = Piece.Beam

		-- (placed again only when its size changed: without Shrink Over Time a piece is placed once)
		if Wide ~= Piece.Wide then
			const Half = Wide / 2
			const C, S = math.cos(Piece.R) * Half, math.sin(Piece.R) * Half

			Piece.Wide = Wide
			Piece.A0.Position = Vector3.new(Piece.X - C, Piece.Y - S, PlaneZ)
			Piece.A1.Position = Vector3.new(Piece.X + C, Piece.Y + S, PlaneZ)
			Beam.Width0 = Wide
			Beam.Width1 = Wide
		end

		const Level = math.clamp(math.round((1 - Opacity * (1 - Age)) * (Levels - 1)), 0, Levels - 1)

		if Level ~= Piece.Level then
			Piece.Level = Level
			Beam.Transparency = View.Transparencies[Level + 1]
		end

		if Gradient then
			const Hue = math.clamp(math.round(Age * (ColorLevels - 1)), 0, ColorLevels - 1)

			if Hue ~= Piece.Hue then
				Piece.Hue = Hue
				Beam.Color = View.Hues[Hue + 1]
			end
		end

		local Shown = Ready

		if Clear > 0 then
			const DX, DY = Piece.X - CentreX, Piece.Y - CentreY
			const Reach = Clear + Wide * PictureReach

			Shown = Ready and DX * DX + DY * DY >= Reach * Reach
		end

		if Beam.Enabled ~= Shown then
			Beam.Enabled = Shown
		end
	end

	for Index = #Pieces, Kept + 1, -1 do
		Pieces[Index] = nil
	end
end

-- The trail for one frame. Off: nothing shows. Paused: the trail stays as it is.
const function Process(View: View, Delta: number, Attempt: AttemptModule.Attempt)
	const Settings = Attempt.Settings

	if not Settings.CursorTrail.Value then
		HideLine(View)
		HidePieces(View)
		ResetPath(View)

		return
	end

	-- (a seek moves the cursor in one frame: the trail starts again where it lands instead of streaking across the grid, and a
	-- seek while paused clears it at once)
	const Seeks = View.Runner.Seeks or 0

	if Seeks ~= View.Seeks then
		View.Seeks = Seeks
		ResetPath(View)
		HideLine(View)
		HidePieces(View)
		View.LaidUntil = View.Ticks() / 1000000
	end

	-- (before the Playing check: the trail's pictures are prepared and warm during the lead-in, so the trail can show from
	-- the run's first frame, and a pause keeps it set up)
	Configure(View, Settings)
	PictureReady(View.Picture)
	PictureReady(View.CapPicture)

	if not View.Runner.Playing then
		return
	end

	const Now = View.Ticks() / 1000000
	const Position = Attempt.CursorPosition
	const Rotation = WorldTransform.DegreesToRadians(View.World.Cursors[1].RotationDegrees)

	AddPoint(View, Position.x, Position.y, Now, Rotation)
	DropOld(View, Now - View.Fade - HistoryMargin)

	if View.Image == LineName then
		HidePieces(View)
		DrawLine(View, Now)
		View.LaidUntil = Now
		View.Carry = 0
	else
		HideLine(View)

		const Least = if View.Image == CursorName and View.Hole > 0 then OutlineSpacing else MinSpacing
		const Spacing = math.max(math.max(Settings.TrailSpacing.Value :: number, Least) * View.Size, PathLength(View, Now - View.Fade) / MaxPieces)

		LayPieces(View, Now, Spacing)
		DrawPieces(View, Now, Position.x, Position.y)
	end
end

-- The trail's Setup: it reads its settings where it uses them, so there is nothing to store.
const function Setup(Settings: SettingsProfile.SettingsProfile, Skin: SkinProfile.SkinProfile)
	return
end

-- The trail renderer for a world and its runner; Ticks answers the time in microseconds.
const function New(World: GameWorld.World, Runner: Runner, Ticks: () -> number): RendererModule.Renderer
	const Anchor = Instance.new("Part")

	Anchor.Name = "TrailAnchor"
	Anchor.Anchored = true
	Anchor.CanCollide = false
	Anchor.CanQuery = false
	Anchor.CanTouch = false
	Anchor.CastShadow = false
	Anchor.Transparency = 1
	Anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	Anchor.CFrame = CFrame.new(WorldTransform.Origin.x, WorldTransform.Origin.y, WorldTransform.Origin.z)
	Anchor.Parent = World.Trails

	const View: View = {
		World = World,
		Runner = Runner,
		Seeks = Runner.Seeks or 0,
		Ticks = Ticks,
		Anchor = Anchor,
		PX = {},
		PY = {},
		PT = {},
		PR = {},
		First = 1,
		Last = 0,
		LineAttachments = {},
		LineBeams = {},
		LineSlices = 0,
		LineShown = false,
		Pieces = {},
		Spare = {},
		LaidUntil = 0,
		Carry = 0,
		Image = "",
		ColorName = "",
		Opacity = -1,
		Shrink = false,
		Fade = 0.1,
		Size = 0,
		Core = 0.55,
		Hole = 0,
		Tint = nil,
		Content = nil,
		Transparencies = {},
		Hues = {},
		Solid = ColorSequence.new(Color3.new(1, 1, 1)),
		Picture = NewPicture(Anchor, nil),
		CapPicture = NewPicture(Anchor, SkinSets.ContentOf(CapImage)),
	}

	return {
		Setup = Setup,
		Process = function(Delta: number, Attempt: AttemptModule.Attempt)
			Process(View, Delta, Attempt)
		end,
	}
end

-- Every trail picture (each cursor's, each trail picture, the head's half disc) is prepared as AIMIA opens, so a song's
-- trail can show from its first frame (on a player's device only: the server draws nothing).
if RunService:IsClient() then
	const Uris = { CapImage }

	for _, Name in CursorStyles.Names do
		table.insert(Uris, CursorStyles.TrailContentOf(Name).Uri or "")
	end

	for _, Image in SkinSets.TrailPictures do
		table.insert(Uris, Image)
	end

	Prepare(Uris)
end

return New
