--!strict
--!optimize 2

--[[
	The game's 3D world in Workspace, built client-side from the scene's Runner (HUD grid, cursor, cursor trail, grid guides,
	visibility assist), Camera3D and the note folder. New builds the folder far from the origin, Setup applies the settings and
	skin (the source's Grid.Init), Sync copies the camera table and the cursors to the Workspace each frame, and Destroy restores
	the camera and removes the folder.

	Representation
		World.Camera is { Position, Rotation, Fov } in Godot units and radians, written by the camera modes. World.Cursors is the
		list of CursorManager.Cursor (entry 1 is the scene's cursor). A quad is { Part, Image }: the Part is the Godot transform's
		geometry, the Image (an ImageLabel in the Part's SurfaceGui) the texture and the Godot transparency. The cursor quads follow
		the cursor list: Sync adds and removes them when it changes (a replay's start and end). World.Hud is the folder the HUD
		builds its panels in.

	Design Notes
		DEVIATION(render): an image quad is a Part with a transparent body and a SurfaceGui on the face the camera sees, holding an
		ImageLabel. The label carries the image (its alpha shows) and the Godot transparency, as ImageTransparency. Godot's
		material transparency is a property of the geometry, which the Part's own transparency would also take; the label keeps
		the body out of the picture.
		The Workspace camera is Scriptable while the world exists; Destroy restores the previous camera and its CameraType.
		The cursor quads are drawn CursorLift nearer the camera along its rays (smaller by the same factor, so they look exactly
		the same): level with the grid, Roblox drew the trail's beams over the cursor at most spots.
		Skin textures reach UI/Images: a baked image by its path, a decoded one registered once per table.
		The host place's Atmosphere and color corrections would tint the whole world (its sky's haze turns every space purple), so they
		are off while the world exists; Destroy puts them back, unless something else changed the Atmosphere meanwhile.
]]

const CameraMode = require("../Camera/CameraMode")
const Constants = require("../../Constants")
const CursorManager = require("../Managers/CursorManager")
const CursorStyles = require("../../Skinning/CursorStyles")
const SkinSets = require("../../Skinning/SkinSets")
const Images = require("../../UI/Images")
const Math = require("../../Godot/Math")
const Numbers = require("../../Numbers")
const SettingsProfile = require("../../Database/Settings/SettingsProfile")
const SkinProfile = require("../../Skinning/SkinProfile")
const Tone = require("./Tone")

const Lighting = game:GetService("Lighting")
const WorldTransform = require("./WorldTransform")
const CameraNudge = require("./CameraNudge")

export type Quad = {
	Part: BasePart,
	Image: ImageLabel,
}

export type World = {
	Folder: Folder,
	Hud: Folder,
	Notes: Folder,
	Trails: Folder,
	Camera: CameraMode.Camera,
	Cursors: { CursorManager.Cursor },
	CursorQuads: { Quad },
	CursorSize: number,
	CursorCanvas: number,
	CursorContent: Content?,
	-- the Custom Cursors style the cursor is drawn with (Setup): the trail copies it
	CursorStyle: string,
	CursorTint: Color3?,
	CursorColor: Color3?,
	TrailTransparency: number,
	Grid: Quad,
	Guides: Quad,
	Assist: Quad,
	Border: ImageLabel,
	Backdrop: Part,
	BackdropFill: Frame,
	PreviousCamera: Camera?,
	PreviousType: Enum.CameraType,
	PreviousFov: number,
	RestoreLighting: () -> (),
}

-- The scene's Grid quad (game.tscn: a 4 x 4 QuadMesh at the origin), its GridGuides (scale 1.01 at z -0.2, hidden by default)
-- and its VisibilityAssist (scale 300 at z -140, a 1 x 1 QuadMesh with Godot transparency 0.25).
const GridSize = 4
-- The backdrop: a surface of the clear color (project.godot) just beyond the farthest of the world (the grid space ends 64 studs from
-- the camera), facing it. It is near because lower graphics quality levels do not draw far parts: a far backdrop shows the sky.
-- At 90 studs a 400 stud surface covers more than the camera's field of view.
const BackdropSize = 400
-- Its color is a UI frame's on the part (shaded and tone mapped parts show other colors at other graphics quality levels).
const BackdropColor = Tone.Color(0.0885599, 0.08855992, 0.08855987)
const BackdropOffset = CFrame.new(0, 0, -90)
const GuidesScale = 1.01
const GuidesZ = -0.2
const AssistScale = 300
const AssistZ = -140
const AssistTransparency = 0.25

-- The scene's Camera3D: at (0, 0, 3.75) with a 70 degree field of view.
const CameraPosition = vector.create(0, 0, 3.75)
const CameraFov = 70
const MinFov = 1
const MaxFov = 120

-- The canvas of a quad's SurfaceGui, in pixels; FixedSize stretches it over the face.
const CanvasSize = 512

-- The cursor quads are drawn this many studs nearer the camera, and smaller by the same factor, along the camera's rays: they
-- look exactly the same, but Roblox draws them over the trail's beams on the grid plane. Level with the grid, the beams drew
-- over the cursor at most spots, so it dimmed and brightened as it moved (tested 2026-11-09: a beam has to be about 0.07 studs
-- behind a quad's middle to draw under it; the rest is room for the Spin camera's tilt). Looks only: hits never read the quad.
const CursorLift = 0.35

-- How many pixels a Godot unit on the grid plane covers on screen now (the camera sits CameraPosition.z in front of it).
const function GridPixelsPerUnit(): number
	const Camera = workspace.CurrentCamera
	const Height = if Camera then Camera.ViewportSize.Y else 1080
	const Fov = if Camera then Camera.FieldOfView else CameraFov

	return Height / (2 * CameraPosition.z * math.tan(math.rad(Fov) / 2))
end

-- The canvas for a picture Side units wide on the grid plane: a little over its size on screen, in steps of 16. A surface's
-- picture drawn much bigger than it shows is shrunk without smoothing, and its edges break up into pixels and shimmer (the
-- cursors were drawn at 512 for about 40 pixels on screen).
const function GridCanvas(Side: number): number
	return math.clamp(math.ceil(Side * GridPixelsPerUnit() * 1.25 / 16) * 16, 32, CanvasSize)
end

-- Sets a quad's canvas to Side pixels square.
const function SetCanvas(Quad: Quad, Side: number)
	const Gui = Quad.Image.Parent :: SurfaceGui
	const Size = Vector2.new(Side, Side)

	if Gui.CanvasSize ~= Size then
		Gui.CanvasSize = Size
	end
end

-- Hidden is a fully transparent image; a visible grid guide is opaque apart from its own alpha.
const HiddenTransparency = 1
const VisibleTransparency = 0

-- A scale basis: each axis scaled by Scale (the rows of a Godot Transform3D with a diagonal basis).
const function ScaledBasis(Scale: number): Math.Basis
	return {
		vector.create(Scale, 0, 0),
		vector.create(0, Scale, 0),
		vector.create(0, 0, Scale),
	}
end

-- A quad: a Part with a transparent body, and on the face the camera sees a SurfaceGui with an ImageLabel that stretches.
const function NewQuad(Parent: Instance, Name: string): Quad
	const Part = Instance.new("Part")

	Part.Name = Name
	Part.Anchored = true
	Part.CanCollide = false
	Part.CanTouch = false
	Part.CanQuery = false
	Part.CastShadow = false
	Part.Material = Enum.Material.Neon
	Part.Transparency = HiddenTransparency

	const Gui = Instance.new("SurfaceGui")

	Gui.Face = WorldTransform.QuadFace
	Gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	Gui.CanvasSize = Vector2.new(CanvasSize, CanvasSize)
	Gui.LightInfluence = 0
	Gui.Parent = Part

	const Image = Instance.new("ImageLabel")

	Image.Size = UDim2.fromScale(1, 1)
	Image.BackgroundTransparency = 1
	Image.BorderSizePixel = 0
	Image.ScaleType = Enum.ScaleType.Stretch
	Image.ImageTransparency = HiddenTransparency
	Image.Parent = Gui
	Part.Parent = Parent

	return {
		Part = Part,
		Image = Image,
	}
end

-- Textures already registered with UI/Images, by their decoded table, so a skin's image is registered once.
const Keys: { [SkinProfile.Image]: string } = {}

-- The content of a skin texture: a baked default image by its path, or a decoded file registered with UI/Images once.
const function ContentOf(Texture: SkinProfile.Texture?): Content?
	if Texture == nil then
		return nil
	end

	if Texture.Path then
		return Images.GetContent(Texture.Path)
	end

	const Decoded = Texture.Image

	if Decoded == nil then
		return nil
	end

	local Key = Keys[Decoded]

	if Key == nil then
		Key = Images.Register(Decoded)
		Keys[Decoded] = Key
	end

	return Images.GetContent(Key)
end

-- Sets a quad's image; nil leaves the image as it is.
const function SetContent(Quad: Quad, Content: Content?)
	if Content then
		Quad.Image.ImageContent = Content
	end
end

-- Keeps one cursor quad per cursor: creates the missing ones, removes the extra ones, and places each at its cursor.
const function SyncCursorQuads(World: World)
	const Quads = World.CursorQuads
	const Cursors = World.Cursors

	for Index = #Quads + 1, #Cursors do
		const Quad = NewQuad(World.Folder, `Cursor{Index}`)

		if World.CursorCanvas > 0 then
			SetCanvas(Quad, World.CursorCanvas)
		end

		SetContent(Quad, World.CursorContent)
		Quad.Image.ImageColor3 = World.CursorTint or Quad.Image.ImageColor3
		table.insert(Quads, Quad)
	end

	for Index = #Quads, #Cursors + 1, -1 do
		Quads[Index].Part:Destroy()
		table.remove(Quads, Index)
	end

	-- (the camera's position in the world's own units, a Godot unit being a stud: each quad moves CursorLift towards it)
	const Camera = workspace.CurrentCamera
	const Eye = if Camera then Camera.CFrame.Position else nil
	const Origin = WorldTransform.Origin

	for Index, Cursor in Cursors do
		const Quad = Quads[Index]
		local Position = Cursor.Position
		local Size = World.CursorSize

		if Eye then
			const EX, EY, EZ = Eye.X - Origin.x, Eye.Y - Origin.y, Eye.Z - Origin.z
			const DX, DY, DZ = Position.x - EX, Position.y - EY, Position.z - EZ
			const Distance = math.sqrt(DX * DX + DY * DY + DZ * DZ)

			if Distance > 2 * CursorLift then
				const Scale = (Distance - CursorLift) / Distance

				Position = vector.create(EX + DX * Scale, EY + DY * Scale, EZ + DZ * Scale)
				Size *= Scale
			end
		end

		WorldTransform.PlaceQuad(Quad.Part, WorldTransform.DegreesToRadians(Cursor.RotationDegrees), Position, Size)
		Quad.Image.ImageTransparency = Cursor.Transparency
	end
end

-- Clears the host place's Atmosphere, color corrections and depth of field; answers what puts them back. (The hub's depth of
-- field blurs only past 233 studs, where a song has nothing but its even backdrop: it was a full-screen pass every frame for
-- nothing. Bloom stays: it is the Neon notes' glow.)
const function ClearLighting(): () -> ()
	const Atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	const Density = if Atmosphere then Atmosphere.Density else 0
	const Haze = if Atmosphere then Atmosphere.Haze else 0
	const Glare = if Atmosphere then Atmosphere.Glare else 0
	const Corrections: { ColorCorrectionEffect } = {}

	if Atmosphere then
		Atmosphere.Density = 0
		Atmosphere.Haze = 0
		Atmosphere.Glare = 0
	end

	const Focus: { DepthOfFieldEffect } = {}

	for _, Child in Lighting:GetChildren() do
		if Child:IsA("ColorCorrectionEffect") and Child.Enabled then
			Child.Enabled = false
			table.insert(Corrections, Child)
		elseif Child:IsA("DepthOfFieldEffect") and Child.Enabled then
			Child.Enabled = false
			table.insert(Focus, Child)
		end
	end

	return function()
		if Atmosphere and Atmosphere.Density == 0 then
			Atmosphere.Density = Density
			Atmosphere.Haze = Haze
			Atmosphere.Glare = Glare
		end

		for _, Correction in Corrections do
			Correction.Enabled = true
		end

		for _, Effect in Focus do
			Effect.Enabled = true
		end
	end
end

-- Builds the world under Parent (the Workspace by default). The camera starts at the scene's rest pose and becomes Scriptable.
const function New(Parent: Instance?): World
	const Folder = Instance.new("Folder")

	Folder.Name = "AimiaGame"

	const Hud = Instance.new("Folder")

	Hud.Name = "HUD"
	Hud.Parent = Folder

	const Notes = Instance.new("Folder")

	Notes.Name = "Notes"
	Notes.Parent = Folder

	const Trails = Instance.new("Folder")

	Trails.Name = "CursorTrail"
	Trails.Parent = Folder

	const Grid = NewQuad(Folder, "Grid")
	const Guides = NewQuad(Folder, "GridGuides")
	const Assist = NewQuad(Folder, "VisibilityAssist")

	WorldTransform.PlaceFlat(Grid.Part, ScaledBasis(1), vector.zero, GridSize, GridSize)
	WorldTransform.PlaceFlat(Guides.Part, ScaledBasis(GuidesScale), vector.create(0, 0, GuidesZ), GridSize, GridSize)
	WorldTransform.PlaceFlat(Assist.Part, ScaledBasis(AssistScale), vector.create(0, 0, AssistZ), 1, 1)

	-- Not in the source: the Border setting's frame round the playfield (Skinning/SkinSets), in the grid's own SurfaceGui so it
	-- lies exactly on the grid's plane, behind grid.png (ZIndex 0); Setup sizes and shows it.
	const Border = Instance.new("ImageLabel")

	Border.Name = "Border"
	Border.BackgroundTransparency = 1
	Border.BorderSizePixel = 0
	Border.AnchorPoint = Vector2.new(0.5, 0.5)
	Border.Position = UDim2.fromScale(0.5, 0.5)
	Border.Size = UDim2.fromScale(1, 1)
	Border.ScaleType = Enum.ScaleType.Stretch
	Border.ZIndex = 0
	Border.ImageTransparency = HiddenTransparency
	Border.Parent = Grid.Image.Parent

	-- The clear color behind the world (Godot's clear color where the game space is not drawn): a transparent part with a frame
	-- of the color, which lighting does not shade, in front of the camera and facing it. It hides the sky.
	const Backdrop = Instance.new("Part")

	Backdrop.Name = "Backdrop"
	Backdrop.Anchored = true
	Backdrop.CanCollide = false
	Backdrop.CanQuery = false
	Backdrop.CanTouch = false
	Backdrop.CastShadow = false
	Backdrop.Transparency = HiddenTransparency
	Backdrop.Size = (Vector3.xAxis + Vector3.yAxis) * BackdropSize + Vector3.zAxis
	Backdrop.Parent = Folder

	const BackdropGui = Instance.new("SurfaceGui")

	BackdropGui.Face = WorldTransform.QuadFace
	BackdropGui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	BackdropGui.CanvasSize = Vector2.new(CanvasSize, CanvasSize)
	BackdropGui.LightInfluence = 0
	BackdropGui.Parent = Backdrop

	const BackdropFill = Instance.new("Frame")

	BackdropFill.BorderSizePixel = 0
	BackdropFill.BackgroundColor3 = BackdropColor
	BackdropFill.Size = UDim2.fromScale(1, 1)
	BackdropFill.Parent = BackdropGui

	Folder.Parent = Parent or workspace

	const Current = workspace.CurrentCamera
	const PreviousType = if Current then Current.CameraType else Enum.CameraType.Custom
	const PreviousFov = if Current then Current.FieldOfView else 70

	if Current then
		Current.CameraType = Enum.CameraType.Scriptable
	end

	const World = {
		Folder = Folder,
		Hud = Hud,
		Notes = Notes,
		Trails = Trails,
		Camera = {
				Position = CameraPosition,
				Rotation = vector.zero,
				Fov = CameraFov,
			},
		Cursors = {
				{
					Position = vector.zero,
					RotationDegrees = 0,
					Transparency = 0,
				},
			},
		CursorQuads = {} :: { Quad },
		CursorSize = Numbers.F32(Constants.CursorSize),
		CursorCanvas = 0,
		CursorContent = nil :: Content?,
		CursorStyle = "skin",
		TrailTransparency = 0,
		Grid = Grid,
		Guides = Guides,
		Assist = Assist,
		Border = Border,
		Backdrop = Backdrop,
		BackdropFill = BackdropFill,
		PreviousCamera = Current :: Camera?,
		PreviousType = PreviousType,
		PreviousFov = PreviousFov,
		RestoreLighting = ClearLighting(),
	}

	SyncCursorQuads(World)

	return World
end

-- Grid.Init: the textures, the guides and visibility assist (shown or hidden), the cursor size and its transparency, and the
-- cursor trail's transparency. Clamps the cursor opacity to [0, 1] as Grid.Init does; ShowCursor does not.
-- @src scripts/game/ui/Grid.cs:Init L27-59
const function Setup(World: World, Settings: SettingsProfile.SettingsProfile, Skin: SkinProfile.SkinProfile)
	const Alpha = math.clamp(Numbers.F32(Settings.CursorOpacity.Value), 0, 1)

	World.CursorSize = Numbers.F32(Constants.CursorSize * Settings.CursorScale.Value)
	-- (Cursor Style and Cursor Color change only the picture: the quad, its size and where a note counts as hit stay the same)
	World.CursorContent = CursorStyles.ContentOf(Settings.CursorStyle.Value) or ContentOf(Skin.CursorImage)
	World.CursorStyle = Settings.CursorStyle.Value

	const Tint = CursorStyles.ColorOf(Settings.CursorColor.Value)

	World.CursorTint = if Tint then Tone.Color(Tint.R, Tint.G, Tint.B) else Color3.new(1, 1, 1)
	World.CursorColor = Tint or Color3.new(1, 1, 1)
	World.TrailTransparency = Numbers.F32(1 - Alpha)
	World.Cursors[1].Transparency = Numbers.F32(1 - Alpha)

	SetContent(World.Grid, ContentOf(Skin.GridImage))

	-- (the border's side is in Godot units; the grid's canvas spans GridSize of them)
	const BorderPicture, BorderSide, BorderTint, BorderOpacity = SkinSets.BorderOf(Settings.Border.Value)

	-- (a border takes the place of grid.png's corner marks: both at once draw two frames round the playfield)
	World.Grid.Image.ImageTransparency = if BorderPicture then HiddenTransparency else VisibleTransparency

	World.Border.Size = UDim2.fromScale(BorderSide / GridSize, BorderSide / GridSize)
	World.Border.ImageColor3 = Tone.Color(BorderTint.R, BorderTint.G, BorderTint.B)

	if BorderPicture then
		World.Border.ImageContent = BorderPicture
	end

	World.Border.ImageTransparency = if BorderPicture then 1 - BorderOpacity else HiddenTransparency

	-- (the guides and the assist are only loaded when they show: each is a 1000-pixel picture, and a device holds few of those)
	if Settings.GridGuides.Value then
		SetContent(World.Guides, ContentOf(Skin.GridGuidesImage))
	end

	World.Guides.Image.ImageTransparency = if Settings.GridGuides.Value then VisibleTransparency else HiddenTransparency

	if Settings.VisibilityAssist.Value then
		SetContent(World.Assist, ContentOf(Skin.VisibilityAssistImage))
	end

	World.Assist.Image.ImageTransparency = if Settings.VisibilityAssist.Value then AssistTransparency else HiddenTransparency

	for _, Quad in World.CursorQuads do
		SetContent(Quad, World.CursorContent)
		Quad.Image.ImageColor3 = World.CursorTint :: Color3
	end
end

-- Copies the camera table to the Workspace camera and the cursors to their quads. Runs every frame.
const function Sync(World: World)
	const Current = workspace.CurrentCamera

	if Current then
		if Current.CameraType ~= Enum.CameraType.Scriptable then
			Current.CameraType = Enum.CameraType.Scriptable
		end

		-- (CameraNudge: the owner panel's trolls move the view a little. The game reads nothing back from the camera, and the
		-- HUD's canvas fitting takes out the nudge the camera has, CameraNudge.Applied: UI/Game/UIComponent)
		const Nudge = CameraNudge.Offset

		Current.CFrame = WorldTransform.CameraCFrame(World.Camera.Position, World.Camera.Rotation) * Nudge
		CameraNudge.Applied = Nudge
		Current.FieldOfView = math.clamp(World.Camera.Fov, MinFov, MaxFov)
		World.Backdrop.CFrame = Current.CFrame * BackdropOffset
	end

	-- (the cursor's canvas follows its size on screen, which the window, the field of view and Cursor Scale change; it grows at
	-- once and shrinks only past a quarter, so a field of view that wobbles can't make it flip every frame)
	const Canvas = GridCanvas(World.CursorSize)

	if Canvas > World.CursorCanvas or Canvas < World.CursorCanvas * 0.75 then
		World.CursorCanvas = Canvas

		for _, Quad in World.CursorQuads do
			SetCanvas(Quad, Canvas)
		end
	end

	SyncCursorQuads(World)
end

-- Restores the previous Workspace camera and its type, and removes the world.
const function Destroy(World: World)
	-- (the camera goes back to the player, with no nudge on it)
	CameraNudge.Applied = CFrame.identity

	if World.PreviousCamera then
		workspace.CurrentCamera = World.PreviousCamera
		World.PreviousCamera.CameraType = World.PreviousType
		World.PreviousCamera.FieldOfView = World.PreviousFov
	end

	World.RestoreLighting()
	World.Folder:Destroy()
end

return {
	New = New,
	Setup = Setup,
	Sync = Sync,
	Destroy = Destroy,
	NewQuad = NewQuad,
	SetContent = SetContent,
	GridCanvas = GridCanvas,
	SetCanvas = SetCanvas,

}
