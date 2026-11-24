--!strict
--!native
--!optimize 2

--[[
	The blurred copy of the backdrop that ui_blur.gdshader shows: textureLod(screen_texture, SCREEN_UV, 2.0), the screen's
	mip 2 with linear filtering. Roblox-free.

	Paradigm
		New(Width, Height, ScreenWidth, ScreenHeight) starts a copy of a backdrop of Width x Height pixels that is shown on a
		screen of ScreenWidth x ScreenHeight. AddRow takes the backdrop's rows in order (RGBA8). Process runs the rest of the
		work (the blur, the dither, the 8-bit quantization) in slices until it answers true; then Pixels (RGBA8, SmallWidth x
		SmallHeight) is complete. The label that shows it stretches it with smooth filtering.

	Design Notes
		Godot's mip 2 is the screen box-filtered by 4 (two 2 x 2 mip steps: a box of 4 screen pixels), sampled linearly, which
		reconstructs between the 4-pixel cells with a tent of the same width. The two make a kernel of variance 4^2/12 + 4^2/6
		= 4, a Gaussian of sigma 2 screen pixels. The project has no stretch mode (project.godot: a 1280 x 720 window), so the
		screen texture is the window in pixels and that sigma holds at every size. ASSUMED: Godot builds each mip step as a
		2 x 2 box (the renderer source is not in reference/).
		The copy is the backdrop box-filtered by Block (2, more above 1024 pixels wide, 512 pixels wide at most). A copy cell
		is ScreenWidth / SmallWidth screen pixels wide; the copy's box (one cell) and the label's bilinear stretch (a tent of one
		cell) already give variance cell^2 / 4. Where that is below the target, the copy is blurred by the rest: three passes
		of [A, 1 - 2A, A], folded into one 7-tap kernel (the same weights; the edges are clamped once). Each pass adds variance
		2A in copy pixels, so A = extra / 6. At a 1920 screen the cell is 4 pixels and no pass runs.
		DEVIATION(render): the passes are 3-tap kernels, not boxes: a box of whole pixels has variance 0 or 2/3 (widths 1 and
		3), and the needed variance is any value up to 2 (the largest pass, A = 1/3).
		The work is f32 until the last step, which adds a 4 x 4 ordered (Bayer) dither before the 8-bit rounding, so the dark
		gradient has no bands.
]]

const MinBlock = 2
const MaxWidth = 512
const LodVariance = 4
const Radius = 3
const Quarter = 0.25
const Third = 1 / 3
const Sixteenth = 1 / 16
const Half = 0.5

const StageAcross = 1
const StageDown = 2
const StageQuantize = 3
const StageDone = 4

const Bayer = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 }

-- The dither threshold of each cell of the 4 x 4 pattern (row-major, 1-based): (Bayer + 0.5) / 16, in (0, 1).
const Thresholds: { number } = table.create(16, 0)

for Index = 1, 16 do
	Thresholds[Index] = (Bayer[Index] + Half) * Sixteenth
end

export type BlurSource = {
	Width: number,
	Height: number,
	Block: number,
	SmallWidth: number,
	SmallHeight: number,
	Sums: { number },
	Rows: number,
	Work: buffer, -- f32 RGBA: the copy's box averages, then the blurred copy
	Scratch: buffer, -- f32 RGBA: the other buffer of the blur passes (Work itself when there are none)
	Input: buffer, -- the buffer the next stage reads
	Output: buffer, -- the buffer the next pass writes
	Pixels: buffer, -- RGBA8 result
	Across: { number }?, -- the 7 weights of the horizontal pass, nil when it is the identity
	Down: { number }?, -- the 7 weights of the vertical pass, nil when it is the identity
	Stage: number,
	Row: number,
}

-- Convolves two weight lists (Result[I + J - 1] += First[I] * Second[J]).
const function Convolve(First: { number }, Second: { number }): { number }
	const Result = table.create(#First + #Second - 1, 0)

	for FirstIndex, FirstWeight in First do
		for SecondIndex, SecondWeight in Second do
			Result[FirstIndex + SecondIndex - 1] += FirstWeight * SecondWeight
		end
	end

	return Result
end

-- The 7 weights (offsets -3 to 3, symmetric, sum 1) that make the copy show Godot's mip 2 when a copy cell is Cell screen
-- pixels wide: the copy's box and the stretch's tent give variance (1/12 + 1/6) copy pixels^2, and the passes add the rest.
-- nil when there is none to add (Cell of 4 pixels or more: the copy is at least as blurred as the target).
const function Kernel(Cell: number): { number }?
	const Extra = LodVariance / (Cell * Cell) - Quarter

	if Extra <= 0 then
		return nil
	end

	const Weight = math.min(Extra / 6, Third)
	const Pass = { Weight, 1 - 2 * Weight, Weight }

	return Convolve(Convolve(Pass, Pass), Pass)
end

-- An empty copy for a backdrop of Width x Height pixels shown on a ScreenWidth x ScreenHeight screen.
const function New(Width: number, Height: number, ScreenWidth: number, ScreenHeight: number): BlurSource
	const Block = math.max(MinBlock, (Width + MaxWidth - 1) // MaxWidth)
	const SmallWidth = math.max(1, (Width + Block - 1) // Block)
	const SmallHeight = math.max(1, (Height + Block - 1) // Block)
	const Count = SmallWidth * SmallHeight * 4
	const Across = Kernel(math.max(1, ScreenWidth) / SmallWidth)
	const Down = Kernel(math.max(1, ScreenHeight) / SmallHeight)
	const Work = buffer.create(Count * 4)
	const Scratch = if Across or Down then buffer.create(Count * 4) else Work

	return {
		Width = Width,
		Height = Height,
		Block = Block,
		SmallWidth = SmallWidth,
		SmallHeight = SmallHeight,
		Sums = table.create(4 * SmallWidth, 0),
		Rows = 0,
		Work = Work,
		Scratch = Scratch,
		Input = Work,
		Output = Scratch,
		Pixels = buffer.create(Count),
		Across = Across,
		Down = Down,
		Stage = if Across then StageAcross elseif Down then StageDown else StageQuantize,
		Row = 0,
	}
end

-- Averages the open block of rows into the copy's row SmallY, then clears its sums.
const function FlushBlock(Source: BlurSource, SmallY: number)
	const Sums = Source.Sums
	const Work = Source.Work
	const Block = Source.Block

	for SmallX = 0, Source.SmallWidth - 1 do
		const Columns = math.min(Block, Source.Width - SmallX * Block)
		const Samples = Source.Rows * Columns
		const Target = (SmallY * Source.SmallWidth + SmallX) * 16

		for Channel = 0, 3 do
			const Sum = 4 * SmallX + Channel + 1

			buffer.writef32(Work, Target + Channel * 4, Sums[Sum] / Samples)
			Sums[Sum] = 0
		end
	end

	Source.Rows = 0
end

-- Adds the backdrop row Y (RGBA8, Width pixels) to the copy; the block of the last row is flushed as well when it is short.
const function AddRow(Source: BlurSource, Row: buffer, Y: number)
	const Sums = Source.Sums
	const Block = Source.Block

	for X = 0, Source.Width - 1 do
		const Sum = 4 * (X // Block) + 1
		const Offset = X * 4

		Sums[Sum] += buffer.readu8(Row, Offset)
		Sums[Sum + 1] += buffer.readu8(Row, Offset + 1)
		Sums[Sum + 2] += buffer.readu8(Row, Offset + 2)
		Sums[Sum + 3] += buffer.readu8(Row, Offset + 3)
	end

	Source.Rows += 1

	if Source.Rows == Block or Y == Source.Height - 1 then
		FlushBlock(Source, Y // Block)
	end
end

-- The horizontal pass of row Row: Output = Across * Input along x, with the edge pixels repeated.
const function AcrossRow(Source: BlurSource, Weights: { number }, Row: number)
	const Input = Source.Input
	const Output = Source.Output
	const Columns = Source.SmallWidth
	const Base = Row * Columns

	for X = 0, Columns - 1 do
		for Channel = 0, 3 do
			local Sum = 0

			for Tap = -Radius, Radius do
				const Index = math.clamp(X + Tap, 0, Columns - 1)

				Sum += Weights[Tap + Radius + 1] * buffer.readf32(Input, ((Base + Index) * 4 + Channel) * 4)
			end

			buffer.writef32(Output, ((Base + X) * 4 + Channel) * 4, Sum)
		end
	end
end

-- The vertical pass of row Row: Output = Down * Input along y, with the edge rows repeated.
const function DownRow(Source: BlurSource, Weights: { number }, Row: number)
	const Input = Source.Input
	const Output = Source.Output
	const Columns = Source.SmallWidth
	const Rows = Source.SmallHeight

	for X = 0, Columns - 1 do
		for Channel = 0, 3 do
			local Sum = 0

			for Tap = -Radius, Radius do
				const Y = math.clamp(Row + Tap, 0, Rows - 1)

				Sum += Weights[Tap + Radius + 1] * buffer.readf32(Input, ((Y * Columns + X) * 4 + Channel) * 4)
			end

			buffer.writef32(Output, ((Row * Columns + X) * 4 + Channel) * 4, Sum)
		end
	end
end

-- Dithers row Row of the blurred copy into the RGBA8 result: floor(value + threshold), clamped.
const function QuantizeRow(Source: BlurSource, Row: number)
	const Input = Source.Input
	const Pixels = Source.Pixels
	const Columns = Source.SmallWidth
	const Base = Row * Columns

	for X = 0, Columns - 1 do
		const Threshold = Thresholds[(Row % 4) * 4 + X % 4 + 1]

		for Channel = 0, 3 do
			const Value = buffer.readf32(Input, ((Base + X) * 4 + Channel) * 4)

			buffer.writeu8(Pixels, (Base + X) * 4 + Channel, math.clamp((Value + Threshold) // 1, 0, 255))
		end
	end
end

-- Moves to the stage after the current one; a pass's output is the next stage's input.
const function AdvanceStage(Source: BlurSource)
	if Source.Stage == StageQuantize then
		Source.Stage = StageDone

		return
	end

	Source.Input, Source.Output = Source.Output, Source.Input

	if Source.Stage == StageAcross and Source.Down then
		Source.Stage = StageDown
	else
		Source.Stage = StageQuantize
	end
end

-- Runs the blur, the dither and the quantization row by row until the deadline (os.clock) or the end; answers true when
-- Pixels is complete. Each call does at least one row, so slices always progress. Every row of the backdrop must have
-- been added first.
const function Process(Source: BlurSource, Deadline: number): boolean
	while Source.Stage ~= StageDone do
		const Stage = Source.Stage
		const Row = Source.Row

		if Stage == StageAcross then
			AcrossRow(Source, Source.Across :: { number }, Row)
		elseif Stage == StageDown then
			DownRow(Source, Source.Down :: { number }, Row)
		else
			QuantizeRow(Source, Row)
		end

		Source.Row += 1

		if Source.Row == Source.SmallHeight then
			Source.Row = 0
			AdvanceStage(Source)
		end

		if Source.Stage ~= StageDone and os.clock() >= Deadline then
			return false
		end
	end

	return true
end

return {
	New = New,
	AddRow = AddRow,
	Process = Process,
	Kernel = Kernel,
}
