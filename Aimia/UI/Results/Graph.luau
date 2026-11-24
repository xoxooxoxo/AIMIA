--!strict
--!optimize 2

--[[
	The hit graph of the results scene (scripts/ui/results/Graph.cs on the Graph ColorRect): the marks of the attempt
	(UI/Results/GraphMarks) drawn across the node.

	Design Notes
		Nodes has no drawing calls, so the marks are Frames under the item's Instance, rebuilt on each draw. This is the one
		place a script creates Instances; the rest of the script goes through Nodes.
		The marks are at ZIndex 0: above the node's own color and style box (-2), below its child labels (1 and up).
		Drawn when attached and on every resize (Godot redraws a control when its size changes).
]]

const Items = require("../Item")
const Nodes = require("../Nodes")
const Marks = require("./GraphMarks")
const BaseScene = require("../Scenes/BaseScene")
const GameAttempt = require("../../Game/Attempt")

type Item = Items.Item

-- @src scripts/ui/results/Graph.cs:_Draw L5-46
const function New(Item: Item, Context: BaseScene.Context)
	const Frames: { Frame } = {}

	const function Draw()
		for _, Frame in Frames do
			Frame:Destroy()
		end

		table.clear(Frames)

		const Size = Nodes.Get(Item, "size") :: vector
		const Attempt = Context.Attempt :: GameAttempt.Attempt

		for _, Mark in Marks(Attempt, Size.x, Size.y) do
			const Frame = Instance.new("Frame")
			const Color = Mark.Color

			Frame.Name = "Mark"
			Frame.BorderSizePixel = 0
			Frame.ZIndex = 0
			Frame.BackgroundColor3 = Color3.new(Color.R, Color.G, Color.B)
			Frame.BackgroundTransparency = 1 - Color.A
			Frame.Position = UDim2.fromOffset(Mark.X, Mark.Y)
			Frame.Size = UDim2.fromOffset(Mark.Width, Mark.Height)
			Frame.Parent = Item.Instance

			table.insert(Frames, Frame)
		end
	end

	Draw()
	Nodes.Connect(Item, "resized", Draw)
end

return New
