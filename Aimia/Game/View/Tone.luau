--!strict
--!optimize 2

--[[
	The color a Roblox UI color reaches the screen as, on a SurfaceGui in the world (LightInfluence 0): the world's rendering does
	not show a UI color as it is given, whatever the lighting, but dimmer, and much dimmer for dark colors. Encode answers the color
	to give to show a wanted one.

	Design Notes
		Measured on the client's screenshots (a color given and the pixel it showed, 0 to 1): 1 shows 0.875; 0.157 shows 0.078;
		0.11 shows 0.043; 0.047 shows 0.012; 0.031 shows 0.008. The curve is those points joined by lines below 0.157; above it is
		the power fitted to 0.157 and 1, shown = 0.875 * given ^ 1.3 (no measurement lies between them).
		ASSUMED: one curve for the three channels (the points are of grays and of one violet), and the same at every graphics quality
		level (it was measured at one). A color that must blend in the UI with another (a fog over a line) is blended there in the
		given colors, so the caller solves the blend's weight in shown colors (Game/View/GridSpace).
]]

const Gain = 0.875
const Exponent = 1.3

-- (shown, given) pairs, increasing.
const Points = {
	{ 0, 0 },
	{ 0.0078, 0.031 },
	{ 0.0118, 0.047 },
	{ 0.043, 0.11 },
	{ 0.0784, 0.157 },
}

for _, Shown in { 0.15, 0.3, 0.5, 0.7, Gain } do
	table.insert(Points, { Shown, (Shown / Gain) ^ (1 / Exponent) })
end

-- The given component that shows Shown (0 to 1): a component above what the screen can show is 1.
const function Encode(Shown: number): number
	if Shown <= 0 then
		return 0
	elseif Shown >= Gain then
		return 1
	end

	for Index = 2, #Points do
		const High = Points[Index]

		if Shown <= High[1] then
			const Low = Points[Index - 1]
			const Weight = (Shown - Low[1]) / (High[1] - Low[1])

			return Low[2] + (High[2] - Low[2]) * Weight
		end
	end

	return 1
end

-- The color to give to show the color (Red, Green, Blue).
const function Color(Red: number, Green: number, Blue: number): Color3
	return Color3.new(Encode(Red), Encode(Green), Encode(Blue))
end

return {
	Encode = Encode,
	Color = Color,
}
