--!strict
--!optimize 2

--[[
	NoteRenderer.cs as a Renderer: one Part per slot of the runner's note range, in the world's Notes folder. Each frame every slot
	is placed by Game/Renderers/NoteMath: a drawn note takes its transform and its skin color with Transparency 1 - alpha, and a
	slot that is not drawn, or that the range no longer reaches, is parked at Transparency 1. The pool grows as needed and is
	never destroyed during a run.

	Representation
		Slot i is one of the source's MultiMesh instances; Parts[i + 1] is it. DEVIATION(smoothness): the note at position k of the
		map's notes takes slot k mod the pool's size (the source gives instance i to the note at position i of the runner's range),
		so a note keeps one part from the moment it comes into range until it leaves. When a note leaves, no other slot moves on to
		the next note, and a picture note's canvas never changes colour while it flies. The range is consecutive and never longer
		than the pool, so two of its notes never share a slot. The pool grows PoolStep slots at a time (a growth moves the notes in
		range to new slots, so it should be rare) and is never destroyed during a run.
		View.Params is NoteMath's Params, refreshed from the settings each frame.
		Painted[i + 1] is the colour index slot i last took, Sized[i + 1] the size it last took, Fades[i + 1] the transparency it last
		took (rounded to 1/255, finer than a colour channel shows): each is only written again when it changes. Drawn[i + 1] is the
		frame (Stamp) slot i was last drawn on; after drawing, every slot not drawn this frame is hidden.
		The drawn notes' transforms go to the engine in one WorldRoot:BulkMoveTo a frame, not one CFrame write per note.

	Design Notes
		The note mesh is the skin's .obj (Game/View/NoteMesh): a MeshPart per slot, cloned from one made at Setup, scaled by the note's
		basis times the mesh's own extents. It is Neon (unshaded, as the source's material), without shadows, collisions, touches
		or queries. The mesh is built on its own thread (it yields), and no note is drawn until it is ready. DEVIATION(render): a skin
		whose mesh cannot be read gets Blocks the size of the scale basis times 2.
		Not in the source: a skin set's flat note picture (Note Mesh named after a set, Skinning/SkinSets; SkinManager.LoadMesh
		answers "picture://<set>"): each slot is an image quad (GameWorld.NewQuad) 2 x 2 like the squircle mesh, facing the camera's
		way, tinted by the note colour (toned for the world, as the cursor is) and faded with ImageTransparency.
		Not in the source: Note Glow off (Game/View/NoteGlow) draws a mesh note as a picture note too, its outline seen head-on
		(View.Flat), in the colours and fade Neon shows without its glow (NoteGlow.FlatTint at NoteGlow.FlatBrightness,
		NoteGlow.FlatFade).
		Not in the source: Note Glow Strength caps a Neon note's colour (NoteGlow.Tint), which is how Roblox's glow is turned
		down. With Note Glow Fade off (the default) a see-through note keeps its glow: Roblox stops drawing it long before the
		note is gone, so a halo picture (NoteGlow.MeshHalo, one quad a slot, made when first needed) goes just behind the note
		and shows what Roblox no longer does (NoteGlow.Fill). A solid note has no halo: its glow is all Roblox's.
		Setup is the source's Setup: the pool is parked and the settings and skin are stored.
]]

const AttemptModule = require("../Attempt")
const Color = require("../../Godot/Color")
const GameWorld = require("./GameWorld")
const NoteModule = require("../../Map/Objects/Note")
const NoteMath = require("../Renderers/NoteMath")
const ObjectType = require("../../Map/Objects/ObjectType")
const RendererModule = require("../Renderers/Renderer")
const SettingsProfile = require("../../Database/Settings/SettingsProfile")
const NoteGlow = require("./NoteGlow")
const NoteMesh = require("./NoteMesh")
const SkinProfile = require("../../Skinning/SkinProfile")
const SkinSets = require("../../Skinning/SkinSets")
const Tone = require("./Tone")
const WorldTransform = require("./WorldTransform")

export type Runner = {
	Attempt: AttemptModule.Attempt,
	ObjectIndicesStart: { [number]: number },
	ObjectIndicesEnd: { [number]: number },
}

export type View = {
	World: GameWorld.World,
	Runner: Runner,
	Params: NoteMath.Params,
	Parts: { BasePart },
	Images: { ImageLabel },
	Painted: { number },
	Sized: { vector },
	Fades: { number },
	Drawn: { number },
	Stamp: number,
	-- a picture note's canvas side (Levels[i + 1]): a power of two a little over its size on screen, kept as it flies in
	Levels: { number },
	VisibleCount: number,
	Settings: SettingsProfile.SettingsProfile?,
	Colors: { Color.Color },
	Tints: { Color3 },
	Template: MeshPart?,
	Picture: Content?,
	-- the picture is a mesh drawn flat (Note Glow off)
	Flat: boolean,
	Extents: vector,
	Ready: boolean,
	-- the glow kept behind see-through notes (nil: none): the halo picture and half the mesh's side; a quad a slot and what
	-- each last took; each tint's glow level and halo colour
	Halo: Content?,
	HaloHalf: number,
	HaloQuads: { [number]: GameWorld.Quad },
	HaloFades: { [number]: number },
	HaloPainted: { [number]: number },
	HaloSized: { [number]: vector },
	HaloDrawn: { [number]: number },
	HaloTints: { Color3 },
	GlowLevels: { number },
}

-- The extents of a Block note when the skin's mesh cannot be read: a cube spanning [-1, 1] on each axis.
const BlockExtents = vector.create(2, 2, 2)

-- A picture note's quad: 2 x 2 like the squircle mesh (so Note Size means the same), as thin as every quad.
const PictureExtents = vector.create(2, 2, WorldTransform.QuadThickness)

const Origin = WorldTransform.Origin

-- How many slots the pool grows by at a time.
const PoolStep = 16

-- A halo quad's canvas (the picture is a blur: it needs no more), and how far behind its note it sits, so Roblox draws the
-- note over it (a see-through part has to be clearly nearer to draw last). It is moved back along the camera's rays and
-- grown by the same factor, so it looks exactly where and as big as it would level with the note (the picture leaves the
-- note's own outline empty: off to one side it would show as a bright sliver inside the note).
const HaloCanvas = 128
const HaloBehind = 0.12

-- The parts and transforms of this frame's drawn notes, for one BulkMoveTo (reused every frame, empty between frames).
const MoveParts: { BasePart } = {}
const MoveFrames: { CFrame } = {}

-- The meshes made so far by path, so a run after the first takes its mesh at once.
const Templates: { [string]: MeshPart } = {}

-- A pooled note part: a clone of the note mesh (a Block without one), unshaded, that does not shadow, collide, touch or answer queries.
const function NewPart(Parent: Instance, Index: number, Template: MeshPart?): BasePart
	const Part: BasePart = if Template then (Template:Clone() :: MeshPart) else Instance.new("Part")

	Part.Name = `Note{Index}`
	Part.Material = Enum.Material.Neon
	Part.Anchored = true
	Part.CanCollide = false
	Part.CanTouch = false
	Part.CanQuery = false
	Part.CastShadow = false
	Part.Transparency = 1
	Part.Parent = Parent

	return Part
end

-- Sets slot Index's (1-based) transparency: the image's for a picture note, the part's otherwise. Only a change is written.
const function Fade(View: View, Index: number, Transparency: number)
	if View.Fades[Index] == Transparency then
		return
	end

	View.Fades[Index] = Transparency

	if View.Picture then
		View.Images[Index].ImageTransparency = Transparency
	else
		View.Parts[Index].Transparency = Transparency
	end
end

-- Hides slot Index (1-based).
const function Hide(View: View, Index: number)
	Fade(View, Index, 1)
end

-- Hides slot Index's halo, if it has one showing.
const function HideHalo(View: View, Index: number)
	if View.HaloFades[Index] ~= nil and View.HaloFades[Index] ~= 1 then
		View.HaloFades[Index] = 1
		View.HaloQuads[Index].Image.ImageTransparency = 1
	end
end

-- Parks every slot of the pool.
const function ParkAll(View: View)
	for Index = 1, #View.Parts do
		Hide(View, Index)
	end

	for Index in View.HaloQuads do
		HideHalo(View, Index)
	end
end

-- Places slot Index's part at a transform (WorldTransform.Place's maths): the CFrame every time (queued for this frame's
-- BulkMoveTo), the size only when it changed.
const function Put(View: View, Index: number, Part: BasePart, Rows: { vector }, Position: vector)
	const Column0 = vector.create(Rows[1].x, Rows[2].x, Rows[3].x)
	const Column1 = vector.create(Rows[1].y, Rows[2].y, Rows[3].y)
	const Column2 = vector.create(Rows[1].z, Rows[2].z, Rows[3].z)
	const Length0 = vector.magnitude(Column0)
	const Length1 = vector.magnitude(Column1)
	const Length2 = vector.magnitude(Column2)
	const X = if Length0 > 0 then Column0 / Length0 else Column0
	const Y = if Length1 > 0 then Column1 / Length1 else Column1
	const Z = if Length2 > 0 then Column2 / Length2 else Column2
	const Extents = View.Extents
	const Size = vector.create(Extents.x * Length0, Extents.y * Length1, if View.Picture then Extents.z else Extents.z * Length2)

	table.insert(MoveParts, Part)
	table.insert(MoveFrames, CFrame.new(Position.x + Origin.x, Position.y + Origin.y, Position.z + Origin.z, X.x, Y.x, Z.x, X.y, Y.y, Z.y, X.z, Y.z, Z.z))

	if View.Sized[Index] ~= Size then
		View.Sized[Index] = Size
		Part.Size = Vector3.new(Size.x, Size.y, Size.z)
	end
end

-- Shows slot Index's halo at Fill (0 to 1) behind a note at the transform, in tint Pick's colour: the note's own turn, the
-- halo picture's size, HaloBehind further from the camera. The quad is made the first time the slot needs one.
const function PutHalo(View: View, Index: number, Pick: number, Fill: number, Rows: { vector }, Position: vector)
	local Quad = View.HaloQuads[Index]

	if Quad == nil then
		Quad = GameWorld.NewQuad(View.World.Notes, `Glow{Index}`)
		;(Quad.Image.Parent :: SurfaceGui).Brightness = NoteGlow.FlatBrightness
		GameWorld.SetCanvas(Quad, HaloCanvas)
		GameWorld.SetContent(Quad, View.Halo)
		View.HaloQuads[Index] = Quad
		View.HaloFades[Index] = 1
		View.HaloPainted[Index] = 0
	end

	if View.HaloPainted[Index] ~= Pick then
		View.HaloPainted[Index] = Pick
		Quad.Image.ImageColor3 = View.HaloTints[Pick]
	end

	const Clear = math.round((1 - Fill) * 255) / 255

	if View.HaloFades[Index] ~= Clear then
		View.HaloFades[Index] = Clear
		Quad.Image.ImageTransparency = Clear
	end

	View.HaloDrawn[Index] = View.Stamp

	const Column0 = vector.create(Rows[1].x, Rows[2].x, Rows[3].x)
	const Column1 = vector.create(Rows[1].y, Rows[2].y, Rows[3].y)
	const Column2 = vector.create(Rows[1].z, Rows[2].z, Rows[3].z)
	const Length0 = vector.magnitude(Column0)
	const Length1 = vector.magnitude(Column1)
	const Length2 = vector.magnitude(Column2)
	const X = if Length0 > 0 then Column0 / Length0 else Column0
	const Y = if Length1 > 0 then Column1 / Length1 else Column1
	const Z = if Length2 > 0 then Column2 / Length2 else Column2
	const Camera = workspace.CurrentCamera
	const WorldX, WorldY, WorldZ = Position.x + Origin.x, Position.y + Origin.y, Position.z + Origin.z
	local EyeX, EyeY, EyeZ = WorldX, WorldY, WorldZ + 1

	if Camera then
		const Eye = Camera.CFrame.Position

		EyeX, EyeY, EyeZ = Eye.X, Eye.Y, Eye.Z
	end

	const Reach = math.max(math.sqrt((WorldX - EyeX) ^ 2 + (WorldY - EyeY) ^ 2 + (WorldZ - EyeZ) ^ 2), 0.5)
	const Grow = 1 + HaloBehind / Reach
	const Side = 2 * View.HaloHalf * NoteGlow.HaloScale * Grow
	const Size = vector.create(Side * Length0, Side * Length1, WorldTransform.QuadThickness)

	table.insert(MoveParts, Quad.Part)
	table.insert(
		MoveFrames,
		CFrame.new(EyeX + (WorldX - EyeX) * Grow, EyeY + (WorldY - EyeY) * Grow, EyeZ + (WorldZ - EyeZ) * Grow, X.x, Y.x, Z.x, X.y, Y.y, Z.y, X.z, Y.z, Z.z)
	)

	if View.HaloSized[Index] ~= Size then
		View.HaloSized[Index] = Size
		Quad.Part.Size = Vector3.new(Size.x, Size.y, Size.z)
	end
end

-- Draws the runner's note range: Count notes from Start (0-based), each placed by NoteMath in its own slot (its position mod
-- the pool's size); then moves them all at once and hides every slot not drawn.
-- @src scripts/game/renderers/NoteRenderer.cs:Render L65-132
const function Render(View: View, Attempt: NoteMath.Attempt, Notes: { NoteModule.Note }, Start: number, Count: number)
	const Parts = View.Parts
	const Tints = View.Tints
	const Settings = View.Settings :: SettingsProfile.SettingsProfile

	if not View.Ready or #Tints == 0 then
		return
	end

	NoteMath.Refresh(View.Params, Settings)

	for Index = #Parts + 1, math.ceil(Count / PoolStep) * PoolStep do
		if View.Picture then
			const Quad = GameWorld.NewQuad(View.World.Notes, `Note{Index}`)

			-- (a flat note shows Neon's colours: NoteGlow.FlatTint is for this brightness)
			if View.Flat then
				(Quad.Image.Parent :: SurfaceGui).Brightness = NoteGlow.FlatBrightness
			end

			-- (one canvas a little over the note's size on screen at the grid, set once: changing a surface's canvas while it
			-- moves made the note blink, most of all as missed notes flew past)
			GameWorld.SetCanvas(Quad, GameWorld.GridCanvas(Settings.NoteSize.Value))
			GameWorld.SetContent(Quad, View.Picture)
			table.insert(Parts, Quad.Part)
			table.insert(View.Images, Quad.Image)
		else
			table.insert(Parts, NewPart(View.World.Notes, Index, View.Template))
		end

		View.Painted[Index] = 0
	end

	const Picture = View.Picture ~= nil
	const Flat = View.Flat
	const Halo = not Picture and View.Halo ~= nil
	const GlowLevels = View.GlowLevels
	const Images = View.Images
	const Painted = View.Painted
	const Drawn = View.Drawn
	const Pool = #Parts
	const Stamp = View.Stamp + 1

	View.Stamp = Stamp
	table.clear(MoveParts)
	table.clear(MoveFrames)

	for At = Start, Start + Count - 1 do
		const Index = (At % Pool) + 1
		const Part = Parts[Index]
		const Note = Notes[At + 1]
		const Alpha = NoteMath.Place(View.Params, Note, Attempt)

		-- (a slot not drawn is hidden after the loop, with the rest)
		if Alpha == nil then
			continue
		end

		const Pick = (Note.Index % #Tints) + 1

		if Painted[Index] ~= Pick then
			Painted[Index] = Pick

			if Picture then
				Images[Index].ImageColor3 = Tints[Pick]
			else
				Part.Color = Tints[Pick]
			end
		end

		Drawn[Index] = Stamp
		-- (a flat note fades as see-through Neon looks, which stays brighter: NoteGlow.FlatFade)
		Fade(View, Index, math.round((if Flat then NoteGlow.FlatFade(1 - Alpha) else 1 - Alpha) * 255) / 255)
		Put(View, Index, Part, Note.Transform.Basis, Note.Transform.Origin)

		-- (the glow a see-through note has lost, put back behind it)
		if Halo and Alpha < 1 then
			const Fill = NoteGlow.Fill(GlowLevels[Pick], 1 - Alpha)

			if Fill > 0.004 then
				PutHalo(View, Index, Pick, Fill, Note.Transform.Basis, Note.Transform.Origin)
			end
		end
	end

	if #MoveParts > 0 then
		const Root = View.World.Notes:FindFirstAncestorWhichIsA("WorldRoot") :: WorldRoot?

		if Root then
			Root:BulkMoveTo(MoveParts, MoveFrames, Enum.BulkMoveMode.FireCFrameChanged)
		else
			for Moved, Part in MoveParts do
				Part.CFrame = MoveFrames[Moved]
			end
		end

		table.clear(MoveParts)
		table.clear(MoveFrames)
	end

	for Index = 1, Pool do
		if Drawn[Index] ~= Stamp then
			Hide(View, Index)
		end
	end

	for Index in View.HaloQuads do
		if View.HaloDrawn[Index] ~= Stamp then
			HideHalo(View, Index)
		end
	end

	View.VisibleCount = Count
end

-- Renders the attempt's notes in the runner's range for the note object type.
-- @src scripts/game/renderers/NoteRenderer.cs:Process L134-148
const function Process(View: View, Delta: number, Attempt: AttemptModule.Attempt)
	const Notes = Attempt.Objects[ObjectType.Note] :: { NoteModule.Note }

	if Notes == nil then
		return
	end

	const Start = View.Runner.ObjectIndicesStart[ObjectType.Note]
	const Count = math.max(0, View.Runner.ObjectIndicesEnd[ObjectType.Note] - Start)

	Render(View, Attempt :: NoteMath.Attempt, Notes, Start, Count)
end

-- Stores the settings and skin, and parks the pool (the source's Setup resets the instance count to 0).
-- @src scripts/game/renderers/NoteRenderer.cs:Setup L30-57
const function Setup(View: View, Settings: SettingsProfile.SettingsProfile, Skin: SkinProfile.SkinProfile)
	ParkAll(View)
	View.VisibleCount = 0
	View.Settings = Settings
	View.Colors = Skin.NoteColors
	View.Ready = false
	View.Template = nil

	const Mesh = Skin.NoteMesh
	const Path = if Mesh then Mesh.Path else "res://user/meshes/squircle.obj"
	const PictureName = string.match(Path, "^picture://(.+)$")
	local Picture = if PictureName then SkinSets.NotePicture(PictureName) else nil
	local Extents = PictureExtents
	local Flat = false

	-- (Note Glow off: a mesh note drawn flat, as Roblox draws Neon without its glow; a device that can't make the picture
	-- keeps the Neon notes)
	if Picture == nil and not NoteGlow.Wanted(Settings) then
		const FlatPicture, Half = NoteGlow.Flat(Path)

		if FlatPicture and Half then
			Picture = FlatPicture
			Extents = vector.create(2 * Half, 2 * Half, WorldTransform.QuadThickness)
			Flat = true
		end
	end

	-- (a pool built for the other kind of note can't be reused: it goes, and the new kind grows its own. A flat pool's
	-- surfaces are brighter than a picture's)
	if (Picture ~= nil) ~= (View.Picture ~= nil) or Flat ~= View.Flat or (Picture and #View.Images > 0 and View.Images[1].ImageContent ~= Picture) then
		for _, Part in View.Parts do
			Part:Destroy()
		end

		table.clear(View.Parts)
		table.clear(View.Images)
		table.clear(View.Painted)
		table.clear(View.Sized)
		table.clear(View.Levels)
		table.clear(View.Fades)
		table.clear(View.Drawn)
	end

	View.Picture = Picture
	View.Flat = Flat
	table.clear(View.Tints)

	-- (a Neon note's colour is capped by Note Glow Strength: at full strength it is the colour itself)
	const Strength = NoteGlow.Strength(Settings)

	for _, Tint in View.Colors do
		table.insert(
			View.Tints,
			if Flat
				then NoteGlow.FlatTint(Tint.R, Tint.G, Tint.B)
				elseif Picture then Tone.Color(Tint.R, Tint.G, Tint.B)
				else NoteGlow.Tint(Tint.R, Tint.G, Tint.B, Strength)
		)
	end

	-- Note Glow Fade off: Neon notes that go see-through keep their glow as a halo picture behind them. Not on a screen whose
	-- graphics draw no glow, and a device that can't make the picture keeps only Roblox's glow.
	local Halo: Content? = nil
	local HaloHalf = 0

	table.clear(View.GlowLevels)
	table.clear(View.HaloTints)

	if Picture == nil and Strength > 0 and NoteGlow.Wanted(Settings) and not NoteGlow.Fades(Settings) and NoteGlow.ScreenDraws() then
		const Made, Half = NoteGlow.MeshHalo(Path)

		if Made and Half then
			Halo = Made
			HaloHalf = Half

			for _, Tint in View.Tints do
				const _, Shown = NoteGlow.GlowOf(Tint)

				table.insert(View.GlowLevels, NoteGlow.LevelOf(Tint))
				table.insert(View.HaloTints, Shown)
			end
		end
	end

	-- (halo quads made for another picture go; the same picture's are kept, hidden, and take their colour again)
	if Halo ~= View.Halo then
		for _, Quad in View.HaloQuads do
			Quad.Part:Destroy()
		end

		table.clear(View.HaloQuads)
		table.clear(View.HaloFades)
		table.clear(View.HaloSized)
		table.clear(View.HaloDrawn)
	end

	table.clear(View.HaloPainted)
	View.Halo = Halo
	View.HaloHalf = HaloHalf

	for Index in View.Painted do
		View.Painted[Index] = 0
	end

	if Picture then
		View.Extents = Extents
		View.Ready = true

		return
	end

	task.spawn(function()
		-- (a device low on memory can refuse the mesh: Blocks, not a song with no notes)
		const Worked, Made = pcall(function(): MeshPart?
			return Templates[Path] or NoteMesh(Path)
		end)

		if Worked and Made then
			Templates[Path] = Made
			View.Template = Made
			View.Extents = vector.create(Made.Size.X, Made.Size.Y, Made.Size.Z)
		else
			View.Extents = BlockExtents
			-- (Blocks have no outline to glow round: the halo was made from the mesh that couldn't be built)
			View.Halo = nil
		end

		table.clear(View.Sized)
		View.Ready = true
	end)
end

-- Setup of the renderer bound to its view (the renderer's contract takes the settings and skin, not the view).
const function BindSetup(View: View): (SettingsProfile.SettingsProfile, SkinProfile.SkinProfile) -> ()
	return function(Settings: SettingsProfile.SettingsProfile, Skin: SkinProfile.SkinProfile)
		Setup(View, Settings, Skin)
	end
end

-- Process of the renderer bound to its view.
const function BindProcess(View: View): (number, AttemptModule.Attempt) -> ()
	return function(Delta: number, Attempt: AttemptModule.Attempt)
		Process(View, Delta, Attempt)
	end
end

-- The renderer for a world and the runner that owns its note range. The settings and skin are kept in the view.
-- @src scripts/game/renderers/NoteRenderer.cs:_Ready L17-28
const function New(World: GameWorld.World, Runner: Runner): RendererModule.Renderer
	const View = {
		World = World,
		Runner = Runner,
		Params = NoteMath.New(),
		Parts = {} :: { BasePart },
		Images = {} :: { ImageLabel },
		Painted = {} :: { number },
		Sized = {} :: { vector },
		Fades = {} :: { number },
		Drawn = {} :: { number },
		Stamp = 0,
		Levels = {} :: { number },
		VisibleCount = 0,
		Settings = nil :: SettingsProfile.SettingsProfile?,
		Colors = {} :: { Color.Color },
		Tints = {} :: { Color3 },
		Template = nil :: MeshPart?,
		Picture = nil :: Content?,
		Flat = false,
		Extents = BlockExtents,
		Ready = false,
		Halo = nil :: Content?,
		HaloHalf = 0,
		HaloQuads = {} :: { [number]: GameWorld.Quad },
		HaloFades = {} :: { [number]: number },
		HaloPainted = {} :: { [number]: number },
		HaloSized = {} :: { [number]: vector },
		HaloDrawn = {} :: { [number]: number },
		HaloTints = {} :: { Color3 },
		GlowLevels = {} :: { number },
	}

	return {
		Setup = BindSetup(View),
		Process = BindProcess(View),
	}
end

return New
