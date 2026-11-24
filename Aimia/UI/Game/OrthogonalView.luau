--!strict
--!optimize 2

--[[
	The replay viewer's orthogonal camera panel (game.tscn ReplayViewer/OrthogonalPanel: a SubViewport with an orthogonal Camera3D,
	size 4.5, looking down the notes' axis at the same world): the grid, its guides, the notes and the cursor seen straight on,
	with no depth.

	Design Notes
		DEVIATION(render): a second 3D view cannot show the quads (their images are SurfaceGuis, which a ViewportFrame does not
		draw), so the view is drawn with Roblox UI from the world's own data: the grid, guides and cursor images are ImageLabels
		with the world's contents, and each visible note part of the world is a rounded Frame at its x and y. Pixels per unit are the
		viewport's 256 pixels over the camera's 4.5 units, scaled by the container's 1.2.
		It draws only while the panel is shown.
]]

const GameWorld = require("../../Game/View/GameWorld")
const Items = require("../Item")
const Nodes = require("../Nodes")

type Item = Items.Item

-- Pixels of the panel for a unit of the world: 256 pixels over the camera's size 4.5, times the container's scale 1.2.
const PixelsPerUnit = 256 / 4.5 * 1.2
const GridUnits = 4
const GuidesScale = 1.01
const WorldY = 10000

type View = {
	Panel: Item,
	World: GameWorld.World,
	Canvas: Frame,
	Grid: ImageLabel,
	Guides: ImageLabel,
	Cursor: ImageLabel,
	Notes: { Frame },
}

-- An image label of Units wide in the canvas, centered.
const function NewImage(Canvas: Frame, Name: string, ZIndex: number): ImageLabel
	const Image = Instance.new("ImageLabel")

	Image.Name = Name
	Image.BackgroundTransparency = 1
	Image.BorderSizePixel = 0
	Image.AnchorPoint = Vector2.new(0.5, 0.5)
	Image.ZIndex = ZIndex
	Image.Parent = Canvas

	return Image
end

-- Puts an image at a world position (x, y) and size in units, in the canvas centered.
const function Place(Image: GuiObject, X: number, Y: number, Units: number)
	Image.Position = UDim2.new(0.5, X * PixelsPerUnit, 0.5, -Y * PixelsPerUnit)
	Image.Size = UDim2.fromOffset(Units * PixelsPerUnit, Units * PixelsPerUnit)
end

-- A note's frame: a rounded square in the note's color.
const function NewNote(Canvas: Frame): Frame
	const Note = Instance.new("Frame")
	const Round = Instance.new("UICorner")
	const Outline = Instance.new("UIStroke")

	Note.Name = "Note"
	Note.BorderSizePixel = 0
	Note.AnchorPoint = Vector2.new(0.5, 0.5)
	Note.ZIndex = 3
	Note.Visible = false
	Round.CornerRadius = UDim.new(0.25, 0)
	Round.Parent = Note
	Outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	Outline.BorderStrokePosition = Enum.BorderStrokePosition.Inner
	Outline.Thickness = 2
	Outline.Parent = Note
	Note.Parent = Canvas

	return Note
end

-- Draws the world into the view.
const function Draw(View: View)
	const World = View.World

	View.Grid.ImageContent = World.Grid.Image.ImageContent
	View.Guides.ImageContent = World.Guides.Image.ImageContent
	View.Guides.ImageTransparency = World.Guides.Image.ImageTransparency
	View.Cursor.ImageContent = World.CursorContent or View.Cursor.ImageContent
	-- (Cursor Color, as given: this panel is flat GUI, which the world's dimming doesn't touch)
	View.Cursor.ImageColor3 = World.CursorColor or Color3.new(1, 1, 1)

	const Cursor = World.Cursors[1]

	if Cursor then
		Place(View.Cursor, Cursor.Position.x, Cursor.Position.y, World.CursorSize)
		View.Cursor.ImageTransparency = Cursor.Transparency
	end

	const Parts = World.Notes:GetChildren()

	for Index = #View.Notes + 1, #Parts do
		table.insert(View.Notes, NewNote(View.Canvas))
	end

	for Index, Note in View.Notes do
		const Part = Parts[Index] :: BasePart?

		-- How see-through the note is and its colour. A mesh note's are its part's. A picture note's, and a flat note's (Note
		-- Glow off), are its image's: that note is an image on a part that is always fully see-through (GameWorld.NewQuad),
		-- so reading only the part showed no notes here at all with either. The glow's halo quads live in the same folder
		-- and aren't notes.
		local Clear = 1
		local Color = Color3.new(1, 1, 1)

		if Part ~= nil and string.sub(Part.Name, 1, 4) ~= "Glow" then
			const Gui = Part:FindFirstChildOfClass("SurfaceGui")
			const Image = if Gui then Gui:FindFirstChildOfClass("ImageLabel") else nil

			if Gui and Image then
				-- (the image's tint as it is: a flat note's surface is drawn brighter than its tint (NoteGlow.FlatBrightness), but
				-- brightening the square the same way turned most colours white; the tint keeps the note's colour, as a mesh
				-- note's part colour does)
				Clear = Image.ImageTransparency
				Color = Image.ImageColor3
			else
				Clear = Part.Transparency
				Color = Part.Color
			end
		end

		if Part == nil or Clear >= 1 then
			Note.Visible = false

			continue
		end

		const Position = Part.Position
		const Units = Part.Size.X

		Note.Visible = true
		Note.Position = UDim2.new(0.5, Position.X * PixelsPerUnit, 0.5, -(Position.Y - WorldY) * PixelsPerUnit)
		Note.Size = UDim2.fromOffset(Units * PixelsPerUnit, Units * PixelsPerUnit)
		Note.BackgroundColor3 = Color
		Note.BackgroundTransparency = 0.55 + 0.45 * Clear

		const Outline = Note:FindFirstChildOfClass("UIStroke")

		if Outline then
			Outline.Color = Color
			Outline.Transparency = Clear
		end
	end
end

-- The orthogonal view in the replay viewer's panel. Answers its per-frame draw (it does nothing while the panel is hidden) and
-- the function that removes it.
const function New(Panel: Item, World: GameWorld.World): (() -> (), () -> ())
	const Host = Panel.Instance :: Frame
	const Canvas = Instance.new("Frame")

	Canvas.Name = "Orthogonal"
	Canvas.BackgroundTransparency = 1
	Canvas.BorderSizePixel = 0
	Canvas.ClipsDescendants = true
	Canvas.Size = UDim2.fromScale(1, 1)
	Canvas.Parent = Host

	const View = {
		Panel = Panel,
		World = World,
		Canvas = Canvas,
		Grid = NewImage(Canvas, "Grid", 1),
		Guides = NewImage(Canvas, "Guides", 2),
		Cursor = NewImage(Canvas, "Cursor", 4),
		Notes = {},
	} :: View

	Place(View.Grid, 0, 0, GridUnits)
	Place(View.Guides, 0, 0, GridUnits * GuidesScale)

	const function Process()
		if Nodes.Get(Panel, "visible") == true then
			Draw(View)
		end
	end

	const function Destroy()
		Canvas:Destroy()
	end

	return Process, Destroy
end

return New
