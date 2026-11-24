--!strict
--!optimize 2

--[[
	The down-pointing chevron of a drop-down button, drawn with Roblox UI: two rounded strokes (frames, rotated) that meet at the
	bottom middle of a Width x Height box, one pixel in from its edges. It replaces an image of the arrow: the strokes are
	frames, so the button's fade and tint treat them as any frame (their color is the frame's background).
]]

-- The chevron's two strokes in Parent, a box of Width x Height at the parent's top-left, in Color with Transparency.
const function New(Parent: Instance, Width: number, Height: number, Stroke: number, Color: Color3, Transparency: number)
	const Across = Width / 2 - 1
	const Down = Height - 2
	const Reach = math.sqrt(Across * Across + Down * Down) + Stroke
	const Angle = math.deg(math.atan2(Down, Across))

	for Index = 1, 2 do
		const Arm = Instance.new("Frame")
		const Round = Instance.new("UICorner")

		Arm.Name = if Index == 1 then "Left" else "Right"
		Arm.BorderSizePixel = 0
		Arm.Active = false
		Arm.AnchorPoint = Vector2.new(0.5, 0.5)
		Arm.Size = UDim2.fromOffset(Reach, Stroke)
		Arm.Position = UDim2.fromOffset(if Index == 1 then 1 + Across / 2 else Width - 1 - Across / 2, 1 + Down / 2)
		Arm.Rotation = if Index == 1 then Angle else -Angle
		Arm.BackgroundColor3 = Color
		Arm.BackgroundTransparency = Transparency
		Round.CornerRadius = UDim.new(0.5, 0)
		Round.Parent = Arm
		Arm.Parent = Parent
	end
end

-- Sets the color of the chevron's strokes in Parent.
const function SetColor(Parent: Instance, Color: Color3, Transparency: number)
	for _, Arm in Parent:GetChildren() do
		if Arm:IsA("Frame") then
			Arm.BackgroundColor3 = Color
			Arm.BackgroundTransparency = Transparency
		end
	end
end

return {
	New = New,
	SetColor = SetColor,
}
