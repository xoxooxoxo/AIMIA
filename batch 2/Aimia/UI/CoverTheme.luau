--!strict
--!optimize 2

--[[
	The colour a button is dressed in, from a song's cover or a player's note colours, and the button's colours from it: the
	round PLAY AGAIN after a fail (Scenes/Results) and WATCH on the Spectate tab (Menu/SpectateMenu).

	Design Notes
		Of reads a decoded picture (ImageDecode.Image: Width, Height, Pixels as RGBA bytes) on a 40 x 40 grid. Each vivid pixel
		counts by how vivid and bright it is, a hue together with its neighbours, and the hue most of them share wins, made
		bright enough to glow. OfColors does the same with a skin's note colours, one count each. Both answer nil for too little
		colour (grey, black or white), which gets plain whites. Only a hue some colour fell in can win, so the colour is never
		worked out from nothing (0 / 0).
		OfThumb reads the small cover kept with each baked map (its folder's Cover attribute: 96 x 96 RGB, Zstd, Base64), which is
		quick to read and plenty for a colour.
]]

const EncodingService = game:GetService("EncodingService")

const White = Color3.new(1, 1, 1)
const Bins = 24
const Steps = 40

export type Picture = { Width: number, Height: number, Pixels: buffer }

export type Buttons = { Ring: Color3, Hover: Color3, Fill: Color3, HoverFill: Color3 }

type Tally = { Weights: { number }, Reds: { number }, Greens: { number }, Blues: { number }, Total: number }

const function NewTally(): Tally
	return {
		Weights = table.create(Bins, 0),
		Reds = table.create(Bins, 0),
		Greens = table.create(Bins, 0),
		Blues = table.create(Bins, 0),
		Total = 0,
	}
end

const function Count(Tally: Tally, Red: number, Green: number, Blue: number)
	const Hue, Saturation, Value = Color3.new(Red, Green, Blue):ToHSV()

	if Saturation >= 0.18 and Value >= 0.18 then
		const Weight = Saturation * Value
		const Bin = math.min(Bins, math.floor(Hue * Bins) + 1)

		Tally.Weights[Bin] += Weight
		Tally.Reds[Bin] += Red * Weight
		Tally.Greens[Bin] += Green * Weight
		Tally.Blues[Bin] += Blue * Weight
		Tally.Total += Weight
	end
end

const function Winner(Tally: Tally, Least: number): Color3?
	if Tally.Total < Least then
		return nil
	end

	const Weights = Tally.Weights
	local Best, BestScore = 0, -1

	for Bin = 1, Bins do
		const Score = Weights[Bin] + 0.5 * (Weights[(Bin - 2) % Bins + 1] + Weights[Bin % Bins + 1])

		if Weights[Bin] > 0 and Score > BestScore then
			Best, BestScore = Bin, Score
		end
	end

	if Best == 0 then
		return nil
	end

	const Weight = Weights[Best]
	const Hue, Saturation, Value = Color3.new(Tally.Reds[Best] / Weight, Tally.Greens[Best] / Weight, Tally.Blues[Best] / Weight):ToHSV()

	return Color3.fromHSV(Hue, math.clamp(Saturation, 0.5, 0.9), math.clamp(Value, 0.85, 1))
end

-- A picture's own colour, or nil for one with too little colour.
const function Of(Image: Picture?): Color3?
	if not Image or Image.Width < 1 or Image.Height < 1 or buffer.len(Image.Pixels) < Image.Width * Image.Height * 4 then
		return nil
	end

	const Tally = NewTally()

	for Row = 0, Steps - 1 do
		const Y = math.floor((Row + 0.5) * Image.Height / Steps)

		for Column = 0, Steps - 1 do
			const X = math.floor((Column + 0.5) * Image.Width / Steps)
			const At = (Y * Image.Width + X) * 4

			Count(Tally, buffer.readu8(Image.Pixels, At) / 255, buffer.readu8(Image.Pixels, At + 1) / 255, buffer.readu8(Image.Pixels, At + 2) / 255)
		end
	end

	return Winner(Tally, Steps * Steps * 0.02)
end

-- A set of note colours' own colour (the one most of them share), or nil when they're all grey, black or white.
const function OfColors(Colors: { Color3 }?): Color3?
	if not Colors or #Colors == 0 then
		return nil
	end

	const Tally = NewTally()

	for _, Color in Colors do
		Count(Tally, Color.R, Color.G, Color.B)
	end

	return Winner(Tally, 0.05)
end

-- A baked map's small cover's colour (its folder's Cover attribute), or nil.
const function OfThumb(Text: unknown): Color3?
	if type(Text) ~= "string" then
		return nil
	end

	const Read, Picture = pcall(function(): Picture?
		const Side = 96
		const Rgb = EncodingService:DecompressBuffer(EncodingService:Base64Decode(buffer.fromstring(Text)), Enum.CompressionAlgorithm.Zstd)

		if buffer.len(Rgb) < Side * Side * 3 then
			return nil
		end

		const Rgba = buffer.create(Side * Side * 4)

		for Index = 0, Side * Side - 1 do
			buffer.writeu8(Rgba, Index * 4, buffer.readu8(Rgb, Index * 3))
			buffer.writeu8(Rgba, Index * 4 + 1, buffer.readu8(Rgb, Index * 3 + 1))
			buffer.writeu8(Rgba, Index * 4 + 2, buffer.readu8(Rgb, Index * 3 + 2))
			buffer.writeu8(Rgba, Index * 4 + 3, 255)
		end

		return { Width = Side, Height = Side, Pixels = Rgba }
	end)

	return if Read then Of(Picture) else nil
end

-- A button's colours from its colour: the ring a light tint of it (the full colour under the mouse), the fill a deep shade of
-- it (lighter under the mouse). Plain whites and near-blacks without one.
const function ButtonsOf(Theme: Color3?): Buttons
	if not Theme then
		return {
			Ring = Color3.fromRGB(236, 236, 236),
			Hover = White,
			Fill = Color3.fromRGB(12, 12, 14),
			HoverFill = Color3.fromRGB(38, 38, 42),
		}
	end

	const Hue, Saturation = Theme:ToHSV()

	return {
		Ring = Theme:Lerp(White, 0.55),
		Hover = Theme,
		Fill = Color3.fromHSV(Hue, math.min(Saturation, 0.55), 0.1),
		HoverFill = Color3.fromHSV(Hue, math.min(Saturation, 0.6), 0.22),
	}
end

return {
	Of = Of,
	OfColors = OfColors,
	OfThumb = OfThumb,
	ButtonsOf = ButtonsOf,
}
