--!strict
--!optimize 2

--[[
	The spectrum bars of the jukebox (scripts/ui/AudioSpectrum.cs): every frame each bar's magnitude is smoothed toward the
	magnitude of its frequency range, and the bars are scaled by a ceiling that follows the loudest bar.

	Design Notes
		AudioSpectrum.Magnitude is the audio bus's spectrum analyzer of the source (the audio backend sets it); without one every
		bar stays at zero. The bar arithmetic is UI/Menu/HomeLogic/Spectrum.
		_Draw: the Node API has no line drawing, so the bars (Spectrum.Segments) are frames of the panel's style host, tinted by
		its progress shader (Shaders.SetBars). A panel without the progress shader draws no bars.
		The fields (MinFreq, MaxFreq, ...) are the scene's properties, or the source's defaults when the scene leaves them out.
]]

const Items = require("./Item")
const Nodes = require("./Nodes")
const Shaders = require("./Shaders")
const Spectrum = require("./Menu/HomeLogic/Spectrum")

export type Bars = {
	Item: Items.Item,
	MinFreq: number,
	MaxFreq: number,
	NormalizeMagnitude: boolean,
	MagnitudeCeiling: number,
	BarSize: number,
	BarGap: number,
	BarMinSize: number,
	BarColor: { number },
	Align: number,
	Responsiveness: number,
	BarCount: number,
	Magnitudes: { number },
	Ceiling: number,
	TargetCeiling: number,
}

const AudioSpectrum = {
	-- The magnitude of a frequency range (Lower, Upper in Hz): the audio port replaces it.
	Magnitude = nil :: ((number, number) -> number)?,
}

-- DEVIATION(audio): no audio, so no bus spectrum: every frequency range is silent.
const function Silence(Lower: number, Upper: number): number
	return 0
end

-- A scene's export, or the source's default when the scene leaves it out.
const function Export(Item: Items.Item, Name: string, Default: number): number
	const Value = Nodes.Get(Item, Name)

	return if type(Value) == "number" then Value else Default
end

-- @src scripts/ui/AudioSpectrum.cs:_Process L62-92
const function Process(State: Bars, Delta: number)
	const Size = Nodes.Get(State.Item, "size") :: vector
	const Magnitude = AudioSpectrum.Magnitude or Silence

	State.BarCount = Spectrum.BarCount(Size.x, State.BarSize, State.BarGap)

	if #State.Magnitudes ~= State.BarCount then
		State.Magnitudes = table.create(State.BarCount, 0)
	end

	const FreqStep = Spectrum.FreqStep(State.MinFreq, State.MaxFreq, State.BarCount)

	local MaxMagnitude = 0

	for Index = 1, State.BarCount do
		const Lower, Upper = Spectrum.FrequencyRange(Index - 1, State.MinFreq, FreqStep)

		State.Magnitudes[Index] = Spectrum.Smooth(State.Magnitudes[Index], Magnitude(Lower, Upper), Delta, State.Responsiveness)

		if State.Magnitudes[Index] > MaxMagnitude then
			MaxMagnitude = State.Magnitudes[Index]
		end
	end

	State.TargetCeiling = Spectrum.TargetCeiling(State.NormalizeMagnitude, State.MagnitudeCeiling, MaxMagnitude, State.TargetCeiling)
	State.Ceiling = Spectrum.Smooth(State.Ceiling, State.TargetCeiling, Delta, 6)

	-- @src scripts/ui/AudioSpectrum.cs:_Draw L94-115
	const Host = State.Item.StyleHost

	if Host and State.BarCount > 1 and Size.y > State.BarMinSize then
		Shaders.SetBars(Host, Spectrum.Segments(State.Magnitudes, State.Ceiling, Size, State.BarSize, State.BarMinSize, State.Align), State.BarSize, State.BarColor)
	end
end

-- @src scripts/ui/AudioSpectrum.cs:_Ready L57-60
-- The audio bus is not read (SpectrumAnalyzer is AudioSpectrum.Magnitude instead).
function AudioSpectrum.New(Item: Items.Item)
	const State = {
		Item = Item,
		MinFreq = Export(Item, "MinFreq", 20),
		MaxFreq = Export(Item, "MaxFreq", 20000),
		NormalizeMagnitude = Nodes.Get(Item, "NormalizeMagnitude") ~= false,
		MagnitudeCeiling = Export(Item, "MagnitudeCeiling", 0.2),
		BarSize = Export(Item, "BarSize", 4),
		BarGap = Export(Item, "BarGap", 4),
		BarMinSize = Export(Item, "BarMinSize", 0),
		BarColor = Items.ColorComponents(Nodes.Get(Item, "BarColor")),
		Align = Export(Item, "Align", 0.5),
		Responsiveness = Export(Item, "Responsiveness", 24),
		BarCount = 0,
		Magnitudes = {},
		Ceiling = 0.01,
		TargetCeiling = 0.01,
	} :: Bars

	Nodes.OnProcess(Item, function(Delta: number)
		Process(State, Delta)
	end)
end

return AudioSpectrum
