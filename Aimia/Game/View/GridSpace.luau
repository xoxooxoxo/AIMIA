--!strict
--!optimize 2

--[[
	The grid space of the game scene (res://prefabs/spaces/grid.tscn and scripts/spaces/Grid.cs): two planes, 10 units above and
	below the grid, tiled with a square-and-line texture that slides along the notes' axis, tinted by the color of the last hit,
	and the dark violet depth fog of its environment (fog_mode depth, begin 10 by default, end 60, curve 0.15).

	Design Notes
		DEVIATION(render): each plane is a transparent Part with a SurfaceGui (LightInfluence 0) drawing the texture with Roblox UI:
		a fill, the lines along Z, the lines across, and over them a frame of the fog color whose gradient is the fog by depth. UI
		colors are not shaded by the lights, but the world still shows them dimmer (Game/View/Tone): every color here is the one to give to
		show the wanted one. A Neon or lit part is worse: shaded and tone mapped, by a different curve at each graphics quality level.
		DEVIATION(render): the lines are a pixel wide on a canvas of PixelsPerStud, about twice the texture's 2 of 128 pixels, so
		that they stay visible at depth, where Godot's mipmaps keep them faint but there. 8.5 pixels a stud make a tile a whole
		30 pixels, so the lines are evenly spaced.
		The lines across slide along Z and wrap, as the texture's UV offset does (3 tiles a second, Uv1Offset += Up * delta * 3).
		The planes themselves move, by the offset within a tile, toward the far end, and jump back a tile at the wrap, where every
		line lands on the next one's place. Moving the lines inside the canvas instead moved them in whole canvas pixels (Roblox
		places UI on whole pixels): an eighth of a stud every third frame at 240 FPS, a judder near the camera. The fog stays
		put in the world: its frame, a tile taller than the canvas, moves back down by whole pixels, which at the nearest depth
		on screen changes the fog by under a level of 255.
		DEVIATION(render): the fog is not Lighting's: that fogs the notes and the HUD too, which the source's materials exempt (the
		note material sets DisableFog). The fog is Godot's depth fog: the fraction ((depth - 10) / 50) ^ 0.15 of the way to the fog color
		(the real game's floor pixels agree: 72% fog at 16 units, 89% at 24, none before 10). It is a frame of the fog color over the
		lines, whose gradient alpha is that fraction, approximated by keypoints. The frame blends in the given colors, so its alpha at
		each keypoint is solved for the line's shown color to be the wanted mix; the fill, which is dark, follows closely.
		The face of a plane is the face the quads use (WorldTransform.QuadFace: the canvas's right is the part's +X, its top the part's
		+Y), turned to look at the camera with the canvas's top toward -Z (the far end).
		The hit color follows BaseSpace._Process: it moves toward the attempt's last hit color by min(1, delta * 8) while the
		"space hit effects" setting is on.
		The fog color is the source's violet unless the Space Color setting (Spaces/SpaceColor) gives another.
]]

const Color = require("../../Godot/Color")
const Tone = require("./Tone")
const WorldTransform = require("./WorldTransform")

type Plane = {
	Fog: UIGradient,
	Fill: Frame,
	Lines: { Frame },
	Slide: Frame,
	SlideLines: { Frame },
	-- the plane's part and where it rests, the fog's frame and how many pixels it is moved back
	Part: Part,
	Base: CFrame,
	FogFrame: Frame,
	FogBack: number,
}

export type GridSpace = {
	Folder: Folder,
	Planes: { Plane },
	Offset: number,
	Tint: Color3,
	HitColor: { number },
	FogColor: { number },
	-- seconds since the tint was last painted
	SincePaint: number,
}

const Extent = 120
const Height = 10
const Tiles = 34
const Step = Extent / Tiles
const Thickness = 0.05
const ScrollTilesPerSecond = 3
-- The camera's depth origin (the scene's rest pose is at z 3.75) and the fog's begin, end and curve (fog_depth_begin is Godot's default).
const CameraZ = 3.75
const FogDepthBegin = 10
const FogDepthEnd = 60
const FogCurve = 0.15
const DefaultFogColor = { 0.0470588, 0.0313726, 0.109804 }
-- The texture's line and its square (grid_tile.png: a 2 pixel light gray line, 211 / 255, over a dark gray, (42, 37, 42) / 255).
const LineColor = { 0.827, 0.827, 0.827 }
const FillColor = { 0.165, 0.145, 0.165 }
-- The planes need only the stretch in front of the camera.
const NearZ = 12
const Span = Extent / 2 + NearZ
const Origin = vector.create(0, 10000, 0)
-- A plane's canvas: pixels for a stud, and the width of a line in pixels.
const PixelsPerStud = 8.5
const LinePixels = 1
const TilePixels = math.round(Step * PixelsPerStud)
-- the tint is painted at most this often while it eases (a paint is 118 property writes and a new fog sequence)
const MinPaintGap = 1 / 60
-- The lines across that the stretch holds, from the first past the far end.
const SlideCount = math.ceil(Span / Step) + 1
-- The depths where the fog gradient has a keypoint, from the far end of the plane to its near end (behind the camera, no fog).
const FarDepth = CameraZ + Extent / 2
-- (the fog's frame starts a tile beyond the far end: see the header)
const FogDepths = { FarDepth + Step, FarDepth, 60, 50, 42, 35, 29, 24, 20, 17, 14.5, 12.5, 11.3, 10.6, 10.2, 10, FarDepth - Span }

-- The fraction of the way to the fog color at a depth in front of the camera (Godot's depth fog, density 1).
const function FogAt(Depth: number): number
	return math.clamp((Depth - FogDepthBegin) / (FogDepthEnd - FogDepthBegin), 0, 1) ^ FogCurve
end

const function NewFrame(Parent: Instance, Name: string, ZIndex: number): Frame
	const Piece = Instance.new("Frame")

	Piece.Name = Name
	Piece.BorderSizePixel = 0
	Piece.ZIndex = ZIndex
	Piece.Parent = Parent

	return Piece
end

-- The transparency of the fog frame by depth, for lines that show Line (three components): the frame is transparent where there is
-- no fog. Its alpha is the weight of the fog color in the blend of the given colors that shows the wanted mix of the shown ones.
const function FogSequence(Line: { number }, FogColor: { number }): NumberSequence
	const Keypoints: { NumberSequenceKeypoint } = {}
	-- (a channel's given line color and its gap to the fog's are the same at every depth: worked out once here, not at each of
	-- the 16 keypoints, where they were most of a paint's Tone.Encode calls)
	const Starts = { Tone.Encode(Line[1]), Tone.Encode(Line[2]), Tone.Encode(Line[3]) }
	const Gaps = { Starts[1] - Tone.Encode(FogColor[1]), Starts[2] - Tone.Encode(FogColor[2]), Starts[3] - Tone.Encode(FogColor[3]) }

	for _, Depth in FogDepths do
		const Fraction = FogAt(Depth)
		local Sum = 0
		local Count = 0

		for Channel = 1, 3 do
			const Start = Starts[Channel]
			const Gap = Gaps[Channel]

			if math.abs(Gap) > 0.02 then
				const Wanted = Line[Channel] + (FogColor[Channel] - Line[Channel]) * Fraction

				Sum += (Start - Tone.Encode(Wanted)) / Gap
				Count += 1
			end
		end

		const Alpha = if Count > 0 then math.clamp(Sum / Count, 0, 1) else Fraction

		table.insert(Keypoints, NumberSequenceKeypoint.new(math.clamp((FarDepth + Step - Depth) / (Span + Step), 0, 1), 1 - Alpha))
	end

	return NumberSequence.new(Keypoints)
end

-- A plane above (Side 1) or below (Side -1) the grid.
const function NewPlane(Folder: Folder, Side: number, FogColor: { number }): Plane
	const Part = Instance.new("Part")
	-- The canvas's right is along X (turned over for the plane above, which the grid's symmetry hides), its top toward -Z, and the
	-- face looks toward the camera: the part's Z is +Y for the plane below, -Y for the one above.
	const Position = Vector3.yAxis * (Origin.y + Side * Height) + Vector3.zAxis * (Origin.z - Extent / 2 + Span / 2)

	Part.Name = "Plane"
	Part.Anchored = true
	Part.CanCollide = false
	Part.CanTouch = false
	Part.CanQuery = false
	Part.CastShadow = false
	Part.Transparency = 1
	Part.Size = (Vector3.xAxis * Extent) + (Vector3.yAxis * Span) + (Vector3.zAxis * Thickness)
	Part.CFrame = CFrame.fromMatrix(Position, Vector3.xAxis * -Side, -Vector3.zAxis, Vector3.yAxis * -Side)

	const Gui = Instance.new("SurfaceGui")

	Gui.Face = WorldTransform.QuadFace
	Gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	Gui.PixelsPerStud = PixelsPerStud
	Gui.LightInfluence = 0
	Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	Gui.Parent = Part

	const Fill = NewFrame(Gui, "Fill", 1)

	Fill.Size = UDim2.fromScale(1, 1)

	const Lines: { Frame } = {}

	for Index = 0, Tiles do
		const Line = NewFrame(Gui, "Line", 2)

		Line.Position = UDim2.fromOffset(Index * TilePixels, 0)
		Line.Size = UDim2.new(0, LinePixels, 1, 0)
		table.insert(Lines, Line)
	end

	const Slide = NewFrame(Gui, "Slide", 2)

	Slide.BackgroundTransparency = 1
	Slide.Size = UDim2.fromScale(1, 1)

	const SlideLines: { Frame } = {}

	for Index = 1, SlideCount do
		const Line = NewFrame(Slide, "Line", 1)

		Line.Position = UDim2.fromOffset(0, Index * TilePixels)
		Line.Size = UDim2.new(1, 0, 0, LinePixels)
		table.insert(SlideLines, Line)
	end

	const Fog = NewFrame(Gui, "Fog", 3)

	-- (a tile taller than the canvas, from a tile above it; Process moves it back down as the plane slides)
	Fog.Position = UDim2.fromOffset(0, -TilePixels)
	Fog.Size = UDim2.new(1, 0, 1, TilePixels)
	Fog.BackgroundColor3 = Tone.Color(FogColor[1], FogColor[2], FogColor[3])

	const Gradient = Instance.new("UIGradient")

	Gradient.Rotation = 90
	Gradient.Parent = Fog
	Part.Parent = Folder

	return {
		Fog = Gradient,
		Fill = Fill,
		Lines = Lines,
		Slide = Slide,
		SlideLines = SlideLines,
		Part = Part,
		Base = Part.CFrame,
		FogFrame = Fog,
		FogBack = 0,
	}
end

-- Paints the lines in the tint, and the fills in their dark violet times it.
const function ApplyTint(Space: GridSpace, Tint: Color3)
	Space.Tint = Tint

	const Shown = { LineColor[1] * Tint.R, LineColor[2] * Tint.G, LineColor[3] * Tint.B }
	const Line = Tone.Color(Shown[1], Shown[2], Shown[3])
	const Fill = Tone.Color(FillColor[1] * Tint.R, FillColor[2] * Tint.G, FillColor[3] * Tint.B)
	const Sequence = FogSequence(Shown, Space.FogColor)

	for _, Plane in Space.Planes do
		Plane.Fill.BackgroundColor3 = Fill
		Plane.Fog.Transparency = Sequence

		for _, Piece in Plane.Lines do
			Piece.BackgroundColor3 = Line
		end

		for _, Piece in Plane.SlideLines do
			Piece.BackgroundColor3 = Line
		end
	end
end

-- The planes. Parent is the world's folder; FogColor is the Space Color setting's, if any.
const function New(Parent: Instance, FogColor: { number }?): GridSpace
	const Fog = FogColor or DefaultFogColor
	const Folder = Instance.new("Folder")
	const Space = {
		Folder = Folder,
		Planes = {},
		Offset = 0,
		Tint = Color3.new(1, 1, 1),
		HitColor = { 1, 1, 1 },
		FogColor = Fog,
		SincePaint = 0,
	} :: GridSpace

	Folder.Name = "GridSpace"

	for _, Side in { -1, 1 } do
		table.insert(Space.Planes, NewPlane(Folder, Side, Fog))
	end

	ApplyTint(Space, Space.Tint)
	Folder.Parent = Parent

	return Space
end

-- The hit color follows the attempt's last hit; the lines slide.
-- @src scripts/spaces/Grid.cs:_Process L17-23
-- @src scripts/spaces/BaseSpace.cs:_Process L47-57
const function Process(Space: GridSpace, Delta: number, LastHit: Color.Color?, HitEffects: boolean)
	if HitEffects and LastHit then
		const Weight = math.min(1, Delta * 8)
		const Hit = Space.HitColor

		Hit[1] += (LastHit.R - Hit[1]) * Weight
		Hit[2] += (LastHit.G - Hit[2]) * Weight
		Hit[3] += (LastHit.B - Hit[3]) * Weight
	end

	const Tint = Color3.new(Space.HitColor[1], Space.HitColor[2], Space.HitColor[3])

	Space.Offset = (Space.Offset + Delta * ScrollTilesPerSecond * Step) % Extent

	-- The lines and the fills are painted when the hit color has moved a visible step since the last paint (more than a level
	-- of 255 in a channel), at most MinPaintGap apart, and exactly once it reaches the hit's color or stops moving. A paint is
	-- 118 property writes and a new fog sequence, and easing in after a hit the color changes a little every frame for about
	-- two seconds (at 240 FPS that was a paint on most frames).
	Space.SincePaint += Delta

	if Tint ~= Space.Tint then
		const Painted = Space.Tint
		local Resting = true

		if HitEffects and LastHit then
			Resting = Tint == Color3.new(LastHit.R, LastHit.G, LastHit.B)
		end

		if Resting
			or Space.SincePaint >= MinPaintGap and (
				math.abs(Tint.R - Painted.R) > 1 / 255
				or math.abs(Tint.G - Painted.G) > 1 / 255
				or math.abs(Tint.B - Painted.B) > 1 / 255
			)
		then
			ApplyTint(Space, Tint)
			Space.SincePaint = 0
		end
	end

	-- The planes move by the offset within a tile toward the far end (their parts' +Y, the canvas's top), so the lines across
	-- are at j * Step - (offset within a tile) from the far end, smoothly; the fog's frame moves back by whole pixels (header).
	const Slid = Space.Offset % Step
	const Back = Slid * PixelsPerStud // 1

	for _, Plane in Space.Planes do
		Plane.Part.CFrame = Plane.Base * CFrame.new(0, Slid, 0)

		if Back ~= Plane.FogBack then
			Plane.FogBack = Back
			Plane.FogFrame.Position = UDim2.fromOffset(0, Back - TilePixels)
		end
	end
end

-- Removes the space.
const function Destroy(Space: GridSpace)
	Space.Folder:Destroy()
end

-- What the far field is: the fog color, which is what the sky behind the world must be.
const function BackdropOf(FogColor: { number }?): Color3
	const Fog = FogColor or DefaultFogColor

	return Tone.Color(Fog[1], Fog[2], Fog[3])
end

return {
	BackdropOf = BackdropOf,
	New = New,
	Process = Process,
	Destroy = Destroy,
}
