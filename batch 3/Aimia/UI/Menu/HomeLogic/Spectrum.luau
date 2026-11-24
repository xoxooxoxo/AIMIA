--!strict
--!optimize 2

--[[
	AudioSpectrum's bar arithmetic (scripts/ui/AudioSpectrum.cs), Roblox-free: the bar count of the panel width, the
	frequency range of each bar, the smoothed magnitudes and ceiling, and the segments of the bars.

	Design Notes
		Every float is float32: Numbers.F32 after each operation, as C# computes it. Mathf.Lerp is from + (to - from) * weight.
		Math.Round is half to even (Numbers.RoundHalfEven); the (int) cast truncates (Numbers.TruncInt32).
		Without audio every magnitude is 0 (the magnitude source of AudioSpectrum answers 0), so every segment is zero-length.
]]

const Numbers = require("../../../Numbers")

-- @src scripts/ui/AudioSpectrum.cs:_Process L64
const function BarCount(SizeX: number, BarSize: number, BarGap: number): number
	const Width = Numbers.F32(SizeX - BarSize)
	const Pitch = Numbers.F32(BarSize + BarGap)

	return Numbers.TruncInt32(Numbers.RoundHalfEven(Numbers.F32(Width / Pitch)))
end

-- Mathf.Lerp in float32.
-- @src scripts/ui/AudioSpectrum.cs:_Process L80
const function Lerp(From: number, To: number, Weight: number): number
	return Numbers.F32(From + Numbers.F32(Numbers.F32(To - From) * Weight))
end

-- Moves Current toward Target by min(1, Delta * Responsiveness) (magnitudes use Responsiveness, the ceiling uses 6).
-- @src scripts/ui/AudioSpectrum.cs:_Process L80
-- @src scripts/ui/AudioSpectrum.cs:_Process L89
const function Smooth(Current: number, Target: number, Delta: number, Responsiveness: number): number
	return Lerp(Current, Target, Numbers.F32(math.min(1, Delta * Responsiveness)))
end

-- The frequency step of the bars, in float32.
-- @src scripts/ui/AudioSpectrum.cs:_Process L71
const function FreqStep(MinFreq: number, MaxFreq: number, BarCount: number): number
	return Numbers.F32((MaxFreq - MinFreq) / BarCount)
end

-- The lower and upper frequency of bar Index (0-based).
-- @src scripts/ui/AudioSpectrum.cs:_Process L76-77
const function FrequencyRange(Index: number, MinFreq: number, FreqStep: number): (number, number)
	const Lower = Numbers.F32(MinFreq + math.max(0, Numbers.F32(Index * FreqStep)))

	return Lower, Numbers.F32(Lower + FreqStep)
end

-- The ceiling the magnitudes are scaled by: the loudest bar when normalizing (kept while the loudest is quiet), else the setting.
-- @src scripts/ui/AudioSpectrum.cs:_Process L88
const function TargetCeiling(Normalize: boolean, MagnitudeCeiling: number, MaxMagnitude: number, Target: number): number
	if not Normalize then
		return MagnitudeCeiling
	end

	return if MaxMagnitude > 0.0015 then MaxMagnitude else Target
end

-- The DrawMultiline points of the bars: a start and an end per bar (Size is the panel's size).
-- @src scripts/ui/AudioSpectrum.cs:_Draw L94-115
const function Segments(Magnitudes: { number }, Ceiling: number, Size: vector, BarSize: number, BarMinSize: number, Align: number): { vector }
	const Points: { vector } = {}
	const Width = Numbers.F32(Size.x - BarSize)
	const Height = Size.y
	const Divisor = Numbers.F32(#Magnitudes - 1)

	for Index = 1, #Magnitudes do
		const Minimum = Numbers.F32(BarMinSize / Height)

		if Minimum > 1 then
			error(`Min ({Minimum}) must be less than or equal to max (1)`, 2)
		end

		const Scale = math.clamp(Numbers.F32(Magnitudes[Index] / Ceiling), Minimum, 1)
		const StartX = Numbers.F32(Numbers.F32(Numbers.F32((Index - 1) / Divisor) * Width) + Numbers.F32(BarSize / 2))
		const StartY = Numbers.F32(Numbers.F32(Align * Numbers.F32(1 - Scale)) * Height)

		table.insert(Points, vector.create(StartX, StartY, 0))
		table.insert(Points, vector.create(StartX, Numbers.F32(StartY + Numbers.F32(Scale * Height)), 0))
	end

	return Points
end

return {
	BarCount = BarCount,
	Lerp = Lerp,
	Smooth = Smooth,
	FreqStep = FreqStep,
	FrequencyRange = FrequencyRange,
	TargetCeiling = TargetCeiling,
	Segments = Segments,
}
