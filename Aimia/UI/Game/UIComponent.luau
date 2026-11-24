--!strict
--!optimize 2

--[[
	The shared parts of the HUD components (scripts/game/ui/UIComponent.cs and the nodes they read): the game scene's node
	properties from its converted data (global transforms, meshes, viewports, Label3D fields, font resources), the quads the HUD
	stands in the world with (panels holding a SubViewport's controls, Label3D texts, Sprite3D images), and the texture keys of
	skin images.

	Representation
		A Component is the set of functions the HUD drives: Init (an attempt starts), Process (every frame of an attempt),
		PhysicsProcess (60 steps a second, Godot's _PhysicsProcess) and Exit (the attempt's signals are released).
		A Panel, Label and Sprite are records of the Instances they draw with, and the basis and extents they are placed by.

	Design Notes
		Placement is WorldTransform.Place, as for the world's quads: Godot's transforms, the quad's extents in Godot units. A
		panel's SurfaceGui is its viewport's canvas, with pixels per stud the canvas over the mesh width (1088 px over 10.88
		units is 100 px per unit), so its 2D controls keep their pixels. A Label3D's canvas is its text box in pixels, with
		pixels per stud 1 / pixel_size. A Sprite3D's canvas is its texture.
		DEVIATION(render): a Label3D's outline is a UIStroke of thickness outline_size / 2, as UI/SceneBuilder draws text outlines.
		DEVIATION(render): a Label3D's transparency fades its fill and outline together, as the material does; the text is drawn
		by a TextLabel, so its colour is the modulate's RGB and its alpha the modulate times (1 - transparency).
		Scene nodes are read from UI/SceneData (the converted game.tscn); a missing node is an error, as get_node is in Godot.
]]

const Images = require("../Images")
const Items = require("../Item")
const Math = require("../../Godot/Math")
const SceneBuilder = require("../SceneBuilder")
const SkinProfile = require("../../Skinning/SkinProfile")
const Style = require("../Style")
const Theme = require("../Theme")
const WorldTransform = require("../../Game/View/WorldTransform")
const GameWorld = require("../../Game/View/GameWorld")
const CameraNudge = require("../../Game/View/CameraNudge")
const Runner = require("../../Game/Runner")
const Attempt = require("../../Game/Attempt")

export type Context = {
	World: GameWorld.World,
	Runner: Runner.Runner,
}

export type Component = {
	Init: () -> (),
	Exit: () -> (),
	Process: ((number, Attempt.Attempt) -> ())?,
	PhysicsProcess: ((number) -> ())?,
}

export type Panel = {
	Part: BasePart,
	Gui: SurfaceGui,
	Built: SceneBuilder.Built,
	Viewport: string,
}

export type Label = {
	Part: BasePart,
	Gui: SurfaceGui,
	Text: TextLabel,
	Stroke: UIStroke,
	Basis: Math.Basis,
	Extents: vector,
	Modulate: { number },
	OutlineModulate: { number },
	Transparency: number,
	Visible: boolean,
}

export type LabelSpec = {
	Transform: Math.Transform3D,
	PixelSize: number,
	Canvas: vector,
	Modulate: { number },
	OutlineModulate: { number },
	OutlineSize: number,
	Font: Font,
	FontSize: number,
	Text: string,
	Wrap: boolean,
}

export type Sprite = {
	Part: BasePart,
	Gui: SurfaceGui,
	Image: ImageLabel,
	Basis: Math.Basis,
	Extents: vector,
	Modulate: { number },
	Transparency: number,
	Visible: boolean,
}

export type SpriteSpec = {
	Transform: Math.Transform3D,
	PixelSize: number,
	Key: string?,
	Modulate: { number },
	AlwaysOnTop: boolean,
}

-- The game scene's converted data: its nodes are read by their scene path.
const GameScene = "res://scenes/game.tscn"

-- Label3D defaults (Godot 4): font size 32, pixel size 0.005, outline 12 with an opaque black outline.
const LabelFontSize = 32
const LabelPixelSize = 0.005
const LabelOutlineSize = 12

-- Sprite3D's default pixel size.
const SpritePixelSize = 0.01

-- The thickness of a quad's Part, as the world's.
const Thickness = WorldTransform.QuadThickness

-- Decoded skin images registered with UI/Images, by their decoded table, so each is registered once.
const Registered: { [SkinProfile.Image]: string } = {}

-- The properties of a node of the game scene, by its scene path. An error when the node is missing (a Godot get_node).
-- @src scenes/game.tscn L1-1
const function NodeOf(Path: string): { [string]: unknown }
	const File = Items.SceneIndex[GameScene]

	for _, Node in File.Nodes or {} do
		if (Node :: { Path: string }).Path == Path then
			return (Node :: { Properties: { [string]: unknown } }).Properties
		end
	end

	error(`Aimia UI: no HUD node {Path}`, 2)
end

-- A node's Transform3D from its "transform" (Godot's twelve values: the basis rows, then the origin); the identity when absent.
-- @src scenes/game.tscn L1-1
const function TransformOf(Properties: { [string]: unknown }): Math.Transform3D
	const Value = Properties["transform"]

	if type(Value) ~= "table" then
		return Math.IdentityTransform()
	end

	const Values = (Value :: { Arguments: { number } }).Arguments

	return {
		Basis = {
			vector.create(Values[1], Values[2], Values[3]),
			vector.create(Values[4], Values[5], Values[6]),
			vector.create(Values[7], Values[8], Values[9]),
		},
		Origin = vector.create(Values[10], Values[11], Values[12]),
	}
end

-- The transform of a node in the world: its own and its ancestors', composed from the scene root down (Godot's
-- global_transform of a Node3D chain: parent * child).
const function GlobalTransform(Path: string): Math.Transform3D
	local Global = Math.IdentityTransform()
	local Prefix = ""

	for Segment in string.gmatch(Path, "[^/]+") do
		Prefix = if Prefix == "" then Segment else `{Prefix}/{Segment}`

		const Local = TransformOf(NodeOf(Prefix))

		Global = {
			Basis = Math.MultiplyBasis(Global.Basis, Local.Basis),
			Origin = Math.MultiplyBasisVector(Global.Basis, Local.Origin) + Global.Origin,
		}
	end

	return Global
end

-- A texture key for a skin texture: its baked path, or a decoded image registered once. Nil when the skin has no texture.
const function TextureKey(Texture: SkinProfile.Texture?): string?
	if Texture == nil then
		return nil
	end

	if Texture.Path then
		return Texture.Path
	end

	const Decoded = Texture.Image

	if Decoded == nil then
		return nil
	end

	local Key = Registered[Decoded]

	if Key == nil then
		Key = Images.Register(Decoded)
		Registered[Decoded] = Key
	end

	return Key
end

-- The Roblox font of a font resource of the game scene (an ExtResource), or the default font.
const function FontOf(Value: unknown): Font
	return Style.GetFont(Theme.ResolveResource(Items.SceneIndex[GameScene], Value, Items.SceneIndex))
end

-- The Roblox font of a font file by its res:// path (a font of a prefab, not of the game scene).
const function FontAt(Path: string): Font
	return Style.GetFont({
		Type = "FontFile",
		Path = Path,
		Properties = {},
		File = Items.SceneIndex[GameScene],
	})
end

-- A quad's Part: anchored, not collidable, invisible (the surface gui draws the picture on its face).
const function NewPart(Parent: Instance, Name: string): BasePart
	const Part = Instance.new("Part")

	Part.Name = Name
	Part.Anchored = true
	Part.CanCollide = false
	Part.CanTouch = false
	Part.CanQuery = false
	Part.CastShadow = false
	Part.Transparency = 1
	Part.Parent = Parent

	return Part
end

-- A surface gui on the face the camera sees: a canvas of Canvas pixels at PixelsPerStud.
const function NewGui(Part: BasePart, Canvas: vector, PixelsPerStud: number, AlwaysOnTop: boolean): SurfaceGui
	const Gui = Instance.new("SurfaceGui")

	Gui.Face = WorldTransform.QuadFace
	Gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	Gui.CanvasSize = Vector2.new(Canvas.x, Canvas.y)
	Gui.PixelsPerStud = PixelsPerStud
	Gui.LightInfluence = 0
	Gui.AlwaysOnTop = AlwaysOnTop
	Gui.Parent = Part

	return Gui
end

-- The canvas of a viewport in pixels: its size_2d_override when it has one, else its size.
const function CanvasOf(ViewportPath: string): vector
	const Properties = NodeOf(ViewportPath)
	const Override = Items.VectorOf(Properties["size_2d_override"])

	if Override.x > 0 then
		return Override
	end

	return Items.VectorOf(Properties["size"])
end

-- A panel: a mesh quad at its node's global transform, with the controls of its SubViewport built on its face. Yields.
-- @src scripts/game/ui/HealthBar.cs:Init L14-16
const function NewPanel(Parent: Instance, NodePath: string, ViewportPath: string): Panel
	const MeshResource = Theme.ResolveResource(Items.SceneIndex[GameScene], NodeOf(NodePath)["mesh"], Items.SceneIndex)
	const Size = Items.VectorOf(if MeshResource then MeshResource.Properties["size"] else nil)
	const Canvas = CanvasOf(ViewportPath)
	const Global = GlobalTransform(NodePath)
	const Part = NewPart(Parent, NodePath)
	const Gui = NewGui(Part, Canvas, Canvas.x / Size.x, false)

	WorldTransform.Place(Part, Global.Basis, Global.Origin, vector.create(Size.x, Size.y, Thickness))

	const Built = SceneBuilder.BuildSubtree(GameScene, ViewportPath, Gui, Gui)

	return {
		Part = Part,
		Gui = Gui,
		Built = Built,
		Viewport = ViewportPath,
	}
end

-- A control under a panel's viewport, by its name.
const function Control(Panel: Panel, Name: string): Items.Item
	return SceneBuilder.Get(Panel.Built, `{Panel.Viewport}/{Name}`)
end

-- Frees a panel's controls and its quad.
const function DestroyPanel(Panel: Panel)
	SceneBuilder.FreeTree(Panel.Built.Root :: Items.Item)
	Panel.Part:Destroy()
end

-- The spec of a Label3D node of the game scene: its global transform, fields and text, on a canvas of Canvas pixels.
-- @src scripts/game/ui/Progress.cs:Init L9-9
const function SceneLabel(Path: string, Canvas: vector, Wrap: boolean): LabelSpec
	const Node = NodeOf(Path)
	const Text = Node["text"]
	const Modulate = if Node["modulate"] ~= nil then Items.ColorComponents(Node["modulate"]) else { 1, 1, 1, 1 }
	const OutlineModulate = if Node["outline_modulate"] ~= nil then Items.ColorComponents(Node["outline_modulate"]) else { 0, 0, 0, 1 }

	return {
		Transform = GlobalTransform(Path),
		PixelSize = Items.Number(Node, "pixel_size", LabelPixelSize),
		Canvas = Canvas,
		Modulate = table.clone(Modulate),
		OutlineModulate = table.clone(OutlineModulate),
		OutlineSize = Items.Number(Node, "outline_size", LabelOutlineSize),
		Font = FontOf(Node["font"]),
		FontSize = Items.Number(Node, "font_size", LabelFontSize),
		Text = if type(Text) == "string" then Text else "",
		Wrap = Wrap,
	}
end

-- Draws a label's current colours, transparency and visibility.
const function ApplyLabel(Label: Label)
	const Fill = Label.Modulate
	const Outline = Label.OutlineModulate
	const Clear = 1 - Label.Transparency

	Label.Text.TextColor3 = Color3.new(Fill[1], Fill[2], Fill[3])
	Label.Text.TextTransparency = 1 - Fill[4] * Clear
	Label.Stroke.Color = Color3.new(Outline[1], Outline[2], Outline[3])
	-- The outline's alpha is scaled by the label's modulate alpha (Label3D draws the outline with it). (The owner chose this:
	-- it keeps the big combo number in the middle of the grid hidden, 2026-11-07.)
	Label.Stroke.Transparency = 1 - Outline[4] * Fill[4] * Clear
	Label.Gui.Enabled = Label.Visible
end

-- A label drawn into a canvas far bigger than it shows is shrunk without smoothing and its text breaks up (the song's title
-- and time were drawn at 2.4 to 2.8 times their size on screen). Its canvas is cut to a little over its size on screen, and
-- the text, still laid out at the scene's size, is scaled down with it. Done when it's made; nothing before the camera is placed.
const function SharpenLabel(Gui: SurfaceGui, Text: TextLabel, Part: BasePart, Full: vector)
	const Camera = workspace.CurrentCamera

	if not Camera then
		return
	end

	-- (from the song's own view: the troll nudge the camera has now, Game/View/CameraNudge.Applied, is taken out)
	const Depth = -(Camera.CFrame * CameraNudge.Applied:Inverse()):PointToObjectSpace(Part.Position).Z

	if Depth <= 0.1 then
		return
	end

	const PerStud = Camera.ViewportSize.Y / (2 * Depth * math.tan(math.rad(Camera.FieldOfView) / 2))
	const Ratio = Full.x / math.max(Part.Size.X * PerStud, 1)

	if Ratio <= 1.6 then
		return
	end

	const Scale = 1.3 / Ratio
	const Fit = Instance.new("UIScale")

	Gui.CanvasSize = Vector2.new(math.ceil(Full.x * Scale), math.ceil(Full.y * Scale))
	Text.Size = UDim2.fromOffset(Full.x, Full.y)
	Fit.Scale = Scale
	Fit.Parent = Text
end

-- A Label3D: a quad at the spec's transform with a TextLabel on its face, the text centred on the canvas. Its outline is a
-- UIStroke. Its Part is placed at the spec's origin.
-- @src scripts/game/ui/Title.cs:Init L9-10
const function NewLabel(Parent: Instance, Name: string, Spec: LabelSpec): Label
	const Part = NewPart(Parent, Name)
	const Gui = NewGui(Part, Spec.Canvas, 1 / Spec.PixelSize, false)
	const Text = Instance.new("TextLabel")

	Text.Name = "Text"
	Text.BackgroundTransparency = 1
	Text.BorderSizePixel = 0
	Text.Size = UDim2.fromScale(1, 1)
	Text.FontFace = Spec.Font
	Text.TextSize = Spec.FontSize
	Text.TextXAlignment = Enum.TextXAlignment.Center
	Text.TextYAlignment = Enum.TextYAlignment.Center
	Text.TextWrapped = Spec.Wrap
	Text.Text = Spec.Text
	Text.Parent = Gui

	const Stroke = Instance.new("UIStroke")

	Stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	Stroke.Thickness = Spec.OutlineSize / 2
	Stroke.Parent = Text

	const Label = {
		Part = Part,
		Gui = Gui,
		Text = Text,
		Stroke = Stroke,
		Basis = Spec.Transform.Basis,
		Extents = vector.create(Spec.Canvas.x * Spec.PixelSize, Spec.Canvas.y * Spec.PixelSize, Thickness),
		Modulate = Spec.Modulate,
		OutlineModulate = Spec.OutlineModulate,
		Transparency = 0,
		Visible = true,
	}

	WorldTransform.Place(Part, Label.Basis, Spec.Transform.Origin, Label.Extents)
	SharpenLabel(Gui, Text, Part, Spec.Canvas)
	ApplyLabel(Label)

	return Label
end

-- Sets a label's text when it changes (Godot's Label3D.text setter has no effect on an unchanged text).
const function SetLabelText(Label: Label, Text: string)
	if Label.Text.Text ~= Text then
		Label.Text.Text = Text
	end
end

-- Sets the alpha of a label (the fourth component of its modulate colour; the outline's own alpha is kept).
const function SetLabelAlpha(Label: Label, Alpha: number)
	Label.Modulate[4] = Alpha
	ApplyLabel(Label)
end

-- Sets a label's Godot transparency (0 opaque, 1 invisible).
const function SetLabelTransparency(Label: Label, Transparency: number)
	Label.Transparency = Transparency
	ApplyLabel(Label)
end

-- Shows or hides a label (its Godot visible flag).
const function SetLabelVisible(Label: Label, Visible: boolean)
	Label.Visible = Visible
	ApplyLabel(Label)
end

-- Moves a label's quad to an origin in the world, keeping its basis and extents.
const function MoveLabel(Label: Label, Origin: vector)
	WorldTransform.Place(Label.Part, Label.Basis, Origin, Label.Extents)
end

-- Fits a quad's canvas to its size on screen (a little over it), never past the canvas it was made with: a picture drawn into a
-- canvas far bigger than it shows is shrunk without smoothing and its edges break up (the miss marks, the modifier icons).
-- Done when it's made, from where the camera is then; nothing happens before the camera is placed.
const function FitCanvas(Gui: SurfaceGui, Part: BasePart, Full: vector)
	const Camera = workspace.CurrentCamera

	if not Camera then
		return
	end

	-- (from the song's own view: the troll nudge the camera has now, Game/View/CameraNudge.Applied, is taken out)
	const Depth = -(Camera.CFrame * CameraNudge.Applied:Inverse()):PointToObjectSpace(Part.Position).Z

	if Depth <= 0.1 then
		return
	end

	const PerStud = Camera.ViewportSize.Y / (2 * Depth * math.tan(math.rad(Camera.FieldOfView) / 2))
	const Wanted = math.max(Part.Size.X, Part.Size.Y) * PerStud * 1.25
	const Biggest = math.max(Full.x, Full.y)

	if Biggest <= 0 or Wanted >= Biggest then
		return
	end

	const Scale = math.max(Wanted, 24) / Biggest

	Gui.CanvasSize = Vector2.new(math.max(math.ceil(Full.x * Scale), 1), math.max(math.ceil(Full.y * Scale), 1))
end

-- Draws a sprite's current colour, transparency and visibility.
const function ApplySprite(Sprite: Sprite)
	const Tint = Sprite.Modulate
	const Clear = 1 - Sprite.Transparency

	Sprite.Image.ImageColor3 = Color3.new(Tint[1], Tint[2], Tint[3])
	Sprite.Image.ImageTransparency = 1 - Tint[4] * Clear
	Sprite.Gui.Enabled = Sprite.Visible
end

-- A Sprite3D: a quad at the spec's transform, its texture on the face at the texture's size times the pixel size. A nil key
-- is a skin without that texture: the sprite takes one pixel and draws nothing.
-- @src prefabs/miss_icon.tscn L1-1
const function NewSprite(Parent: Instance, Name: string, Spec: SpriteSpec): Sprite
	const Source = if Spec.Key then Images.GetSourceSize(Spec.Key) else Vector2.one
	const Canvas = vector.create(math.max(Source.X, 1), math.max(Source.Y, 1), 0)
	const Part = NewPart(Parent, Name)
	const Gui = NewGui(Part, Canvas, 1 / Spec.PixelSize, Spec.AlwaysOnTop)
	const Image = Instance.new("ImageLabel")

	Image.Name = "Image"
	Image.BackgroundTransparency = 1
	Image.BorderSizePixel = 0
	Image.Size = UDim2.fromScale(1, 1)
	Image.ScaleType = Enum.ScaleType.Stretch

	if Spec.Key then
		Image.ImageContent = Images.GetContent(Spec.Key)
	end

	Image.Parent = Gui

	const Sprite = {
		Part = Part,
		Gui = Gui,
		Image = Image,
		Basis = Spec.Transform.Basis,
		Extents = vector.create(Canvas.x * Spec.PixelSize, Canvas.y * Spec.PixelSize, Thickness),
		Modulate = Spec.Modulate,
		Transparency = 0,
		Visible = true,
	}

	WorldTransform.Place(Part, Sprite.Basis, Spec.Transform.Origin, Sprite.Extents)
	FitCanvas(Gui, Part, Canvas)
	ApplySprite(Sprite)

	return Sprite
end

-- Sets a sprite's Godot transparency.
const function SetSpriteTransparency(Sprite: Sprite, Transparency: number)
	Sprite.Transparency = Transparency
	ApplySprite(Sprite)
end

-- Shows or hides a sprite (its Godot visible flag).
const function SetSpriteVisible(Sprite: Sprite, Visible: boolean)
	Sprite.Visible = Visible
	ApplySprite(Sprite)
end

-- Moves a sprite's quad to an origin in the world, keeping its basis and extents.
const function MoveSprite(Sprite: Sprite, Origin: vector)
	WorldTransform.Place(Sprite.Part, Sprite.Basis, Origin, Sprite.Extents)
end

-- Not in the source: the HUD's words read on any map skin (the owner's ask, 2026-11-07: the title, time and combo counter
-- vanished on a light grey skin). On a light one (HudManager sets Ink.Light from SkinSets' Light, with no Space Color over
-- it) the words and bars are near black with a soft light edge; elsewhere the scene's white gets a thin dark edge.
const Ink = { Light = false, LightBottom = false }
const DarkInk = Color3.new(0.08, 0.08, 0.09)

-- A Label3D's colours for the skin (Bottom: a label of the HUD's bottom row, which follows Ink.LightBottom). Its alpha is
-- left to the component, so pulses and fades carry on.
const function InkLabel(Label: Label, Bottom: boolean?)
	const Base = (Label :: any).InkBase or { Fill = table.clone(Label.Modulate) }
	const Fill, Edge = Label.Modulate, Label.OutlineModulate
	const Kept: any = Label

	Kept.InkBase = Base

	if (if Bottom then Ink.LightBottom else Ink.Light) then
		Fill[1], Fill[2], Fill[3] = DarkInk.R, DarkInk.G, DarkInk.B
		Edge[1], Edge[2], Edge[3], Edge[4] = 1, 1, 1, 0.4
	else
		Fill[1], Fill[2], Fill[3] = Base.Fill[1], Base.Fill[2], Base.Fill[3]
		Edge[1], Edge[2], Edge[3], Edge[4] = 0, 0, 0, 0.7
	end

	Label.Stroke.Thickness = 2
	ApplyLabel(Label)
end

-- The edge on one of a panel's words (light on a light skin, else dark; thinner on the small hit and miss counts, which fade).
const function InkText(Text: Instance)
	if not (Text:IsA("TextLabel") or Text:IsA("TextButton") or Text:IsA("TextBox")) then
		return
	end

	-- (words with their own outline from the scene keep it: SceneBuilder leaves an InkEdge alone, but two strokes don't mix)
	for _, Child in Text:GetChildren() do
		if Child:IsA("UIStroke") and Child.Name ~= "InkEdge" then
			return
		end
	end

	local Edge = Text:FindFirstChild("InkEdge")

	if not Edge then
		Edge = Instance.new("UIStroke")
		Edge.Name = "InkEdge"
		;(Edge :: UIStroke).ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		Edge.Parent = Text
	end

	const Stroke = Edge :: UIStroke
	const Small = (Text :: TextLabel).TextSize <= 44

	Stroke.Color = if Ink.Light then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
	Stroke.Transparency = if Ink.Light then (if Small then 0.7 else 0.5) else (if Small then 0.55 else 0.4)
	Stroke.Thickness = if Small then 1 else 1.5
end

-- A panel's words for the skin: a thin edge on each (InkText), and on a light skin the given controls turn near black through
-- their modulate (its alpha is kept; a dark skin puts the white back). A control's words are made when it first gets text and
-- made again later, so new ones take the edge as they come.
const function InkPanel(Panel: Panel, Darkened: { Items.Item })
	for _, Text in Panel.Gui:GetDescendants() do
		InkText(Text)
	end

	const Kept: any = Panel

	if not Kept.InkLink then
		Kept.InkLink = Panel.Gui.DescendantAdded:Connect(InkText)
	end

	for _, Item in Darkened do
		const Own = Item.Modulate

		if Ink.Light then
			Items.SetModulate(Item, DarkInk.R, DarkInk.G, DarkInk.B, Own[4])
		elseif Own[1] == DarkInk.R and Own[2] == DarkInk.G and Own[3] == DarkInk.B then
			Items.SetModulate(Item, 1, 1, 1, Own[4])
		end
	end
end

return {
	Ink = Ink,
	DarkInk = DarkInk,
	InkLabel = InkLabel,
	InkPanel = InkPanel,
	NodeOf = NodeOf,
	GlobalTransform = GlobalTransform,
	TextureKey = TextureKey,
	NewPanel = NewPanel,
	DestroyPanel = DestroyPanel,
	Control = Control,
	SceneLabel = SceneLabel,
	FontAt = FontAt,
	NewLabel = NewLabel,
	ApplyLabel = ApplyLabel,
	SetLabelText = SetLabelText,
	SetLabelAlpha = SetLabelAlpha,
	SetLabelTransparency = SetLabelTransparency,
	SetLabelVisible = SetLabelVisible,
	MoveLabel = MoveLabel,
	NewSprite = NewSprite,
	SetSpriteTransparency = SetSpriteTransparency,
	SetSpriteVisible = SetSpriteVisible,
	MoveSprite = MoveSprite,
	LabelFontSize = LabelFontSize,
	LabelPixelSize = LabelPixelSize,
	SpritePixelSize = SpritePixelSize,
}
