--!strict
--!optimize 2

--[[
	Godot Range value rules for the Roblox-drawn sliders (UI/Controls/Slider), Roblox-free.

	Design Notes
		Value rules (Range::set_value as far as known): snap to step from min when step > 0 (Math::round, half away from
		zero), round to an integer when rounded, then clamp to [min, max - page] unless allow_greater, and to min unless
		allow_lesser. range.cpp is not in reference/engine: the order and the rounded behavior are unverified.
		Tick and wheel placement are inferred (slider.cpp is not in reference/engine): unverified.
]]

-- Math::round: half away from zero.
const function RoundHalfAway(Value: number): number
	const Magnitude = (math.abs(Value) + 0.5) // 1

	return if Value < 0 then -Magnitude else Magnitude
end

-- The value after Range's step and rounded rules (before the bounds).
const function SnapValue(Value: number, Min: number, Step: number, Rounded: boolean): number
	local Result = Value

	if Step > 0 then
		Result = RoundHalfAway((Result - Min) / Step) * Step + Min
	end

	if Rounded then
		Result = RoundHalfAway(Result)
	end

	return Result
end

-- The value Range::set_value stores for a requested Value.
const function SetValue(Value: number, Min: number, Max: number, Step: number, Page: number, Rounded: boolean, AllowGreater: boolean, AllowLesser: boolean): number
	local Result = SnapValue(Value, Min, Step, Rounded)

	if not AllowGreater and Result > Max - Page then
		Result = Max - Page
	end

	if not AllowLesser and Result < Min then
		Result = Min
	end

	return Result
end

-- The fraction of the range a value sits at (0 when the range is empty).
const function RatioOf(Value: number, Min: number, Max: number): number
	if Max <= Min then
		return 0
	end

	return (Value - Min) / (Max - Min)
end

-- The value at a fraction of the range (the mouse position mapped by Slider).
const function ValueAt(Ratio: number, Min: number, Max: number): number
	return Min + Ratio * (Max - Min)
end

-- The fraction of tick Index (0-based) out of Count ticks: at the borders when OnBorders, else spaced evenly between.
const function TickRatio(Index: number, Count: number, OnBorders: boolean): number
	if Count <= 1 then
		return 0
	end

	if OnBorders then
		return Index / (Count - 1)
	end

	return (Index + 1) / (Count + 1)
end

-- The change a mouse wheel tick makes: the step, else a hundredth of the range (unverified).
const function WheelStep(Step: number, Min: number, Max: number): number
	if Step > 0 then
		return Step
	end

	return (Max - Min) / 100
end

return {
	RoundHalfAway = RoundHalfAway,
	SnapValue = SnapValue,
	SetValue = SetValue,
	RatioOf = RatioOf,
	ValueAt = ValueAt,
	TickRatio = TickRatio,
	WheelStep = WheelStep,
}
