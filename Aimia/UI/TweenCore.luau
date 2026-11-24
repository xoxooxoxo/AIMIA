--!strict
--!optimize 2

--[[
	Godot's Tween timeline and easing equations, Roblox-free (UI/Tween drives Instances with it).

	Design Notes
		A timeline is a list of steps. A tweener appended in parallel mode (SetParallel, or Parallel for the next one)
		joins the last step; otherwise it opens a new step. A step lasts as long as its longest tweener, and the next
		step starts when it ends. A property or method tweener interpolates its components (1 for numbers, 4 for
		colors, 2 for vectors) from the values it has when its step starts; a callback runs once when its step starts.
		Defaults as Godot: TRANS_LINEAR and EASE_IN_OUT, both set on the timeline and read when a tweener is created;
		Parallel and Chain apply to the next tweener only; SetParallel stays on until turned off.
		Loops: 1 runs once, 0 loops forever (Godot set_loops).

		Easing: the Penner equations per transition, combined per ease as Godot does (In, Out = 1 - In(1 - t),
		InOut, OutIn). reference/engine has no tween.cpp: the Spring curve and the Back and Elastic constants are
		unverified against Godot (Penner defaults used; period 0.3, overshoot 1.70158).
]]

export type Tweener = {
	Kind: number,
	Duration: number,
	Trans: number,
	Ease: number,
	From: { number },
	To: { number },
	Current: { number },
	Started: boolean,
	Called: boolean,
	Callback: (() -> ())?,
	Payload: unknown,
}

export type Step = {
	Tweeners: { Tweener },
	Duration: number,
}

export type Timeline = {
	Steps: { Step },
	Trans: number,
	Ease: number,
	Parallel: boolean,
	ParallelNext: boolean,
	ChainNext: boolean,
	Loops: number,
	Loop: number,
	StepIndex: number,
	Elapsed: number,
	PassDuration: number,
	Running: boolean,
}

-- The host implements Begin (fills From when the tweener starts) and Apply (reads Current).
export type Driver = {
	Begin: (Tweener) -> (),
	Apply: (Tweener) -> (),
}

const Transition = {
	Linear = 0,
	Sine = 1,
	Quint = 2,
	Quart = 3,
	Quad = 4,
	Expo = 5,
	Elastic = 6,
	Cubic = 7,
	Circ = 8,
	Bounce = 9,
	Back = 10,
	Spring = 11,
}

const Easing = {
	In = 0,
	Out = 1,
	InOut = 2,
	OutIn = 3,
}

const Kind = {
	Property = 1,
	Method = 2,
	Callback = 3,
	Interval = 4,
}

const BackOvershoot = 1.70158
const ElasticPeriod = 0.3
const BounceLimit = 2.75

-- Penner's bounce ease-out, t in [0, 1].
const function BounceOut(Time: number): number
	if Time < 1 / BounceLimit then
		return 7.5625 * Time * Time
	elseif Time < 2 / BounceLimit then
		const Shifted = Time - 1.5 / BounceLimit

		return 7.5625 * Shifted * Shifted + 0.75
	elseif Time < 2.5 / BounceLimit then
		const Shifted = Time - 2.25 / BounceLimit

		return 7.5625 * Shifted * Shifted + 0.9375
	end

	const Shifted = Time - 2.625 / BounceLimit

	return 7.5625 * Shifted * Shifted + 0.984375
end

-- The ease-in curve of a transition (Penner), t in [0, 1].
const function Base(Trans: number, Time: number): number
	if Trans == Transition.Sine then
		return 1 - math.cos(Time * math.pi * 0.5)
	elseif Trans == Transition.Quint then
		return Time ^ 5
	elseif Trans == Transition.Quart then
		return Time ^ 4
	elseif Trans == Transition.Quad then
		return Time * Time
	elseif Trans == Transition.Cubic then
		return Time ^ 3
	elseif Trans == Transition.Expo then
		if Time == 0 then
			return 0
		end

		return 2 ^ (10 * (Time - 1))
	elseif Trans == Transition.Circ then
		return 1 - math.sqrt(1 - Time * Time)
	elseif Trans == Transition.Back then
		return Time * Time * ((BackOvershoot + 1) * Time - BackOvershoot)
	elseif Trans == Transition.Elastic then
		if Time == 0 or Time == 1 then
			return Time
		end

		const Shift = ElasticPeriod / 4
		const Offset = Time - 1

		return -(2 ^ (10 * Offset)) * math.sin((Offset - Shift) * (2 * math.pi) / ElasticPeriod)
	elseif Trans == Transition.Bounce then
		return 1 - BounceOut(1 - Time)
	elseif Trans == Transition.Spring then
		const Remaining = 1 - Time

		return math.cos(Remaining * math.pi * 4.5) * math.exp(-6 * Remaining)
	end

	return Time
end

-- The eased progress of a transition for Time in [0, 1] (Godot run_equation).
const function Ratio(Trans: number, EaseType: number, Time: number): number
	if EaseType == Easing.In then
		return Base(Trans, Time)
	elseif EaseType == Easing.Out then
		return 1 - Base(Trans, 1 - Time)
	elseif EaseType == Easing.InOut then
		if Time < 0.5 then
			return Base(Trans, Time * 2) / 2
		end

		return 1 - Base(Trans, 2 - Time * 2) / 2
	end

	if Time < 0.5 then
		return (1 - Base(Trans, 1 - Time * 2)) / 2
	end

	return Base(Trans, Time * 2 - 1) / 2 + 0.5
end

const function New(): Timeline
	return {
		Steps = {},
		Trans = Transition.Linear,
		Ease = Easing.InOut,
		Parallel = false,
		ParallelNext = false,
		ChainNext = false,
		Loops = 1,
		Loop = 0,
		StepIndex = 1,
		Elapsed = 0,
		PassDuration = 0,
		Running = true,
	}
end

-- Appends a tweener of Components values to the timeline, with the timeline's current transition and ease.
const function Append(Timeline: Timeline, TweenerKind: number, Duration: number, Components: number): Tweener
	const Entry = {
		Kind = TweenerKind,
		Duration = Duration,
		Trans = Timeline.Trans,
		Ease = Timeline.Ease,
		From = table.create(Components, 0),
		To = table.create(Components, 0),
		Current = table.create(Components, 0),
		Started = false,
		Called = false,
		Callback = nil,
		Payload = nil,
	} :: Tweener
	const Steps = Timeline.Steps
	const Last = Steps[#Steps]
	const Joins = Last ~= nil and (Timeline.Parallel or Timeline.ParallelNext) and not Timeline.ChainNext

	if Joins then
		table.insert(Last.Tweeners, Entry)

		if Duration > Last.Duration then
			Last.Duration = Duration
		end
	else
		table.insert(Steps, {
			Tweeners = { Entry },
			Duration = Duration,
		})
	end

	Timeline.ParallelNext = false
	Timeline.ChainNext = false

	return Entry
end

const function SetTrans(Timeline: Timeline, Trans: number)
	Timeline.Trans = Trans
end

const function SetEase(Timeline: Timeline, EaseType: number)
	Timeline.Ease = EaseType
end

const function SetParallel(Timeline: Timeline, On: boolean)
	Timeline.Parallel = On
end

const function Parallel(Timeline: Timeline)
	Timeline.ParallelNext = true
end

const function Chain(Timeline: Timeline)
	Timeline.ChainNext = true
end

const function SetLoops(Timeline: Timeline, Loops: number)
	Timeline.Loops = Loops
end

const function Kill(Timeline: Timeline)
	Timeline.Running = false
end

const function IsRunning(Timeline: Timeline): boolean
	return Timeline.Running
end

const function EnterStep(Step: Step)
	for _, Entry in Step.Tweeners do
		Entry.Started = false
		Entry.Called = false
	end
end

-- Advances the timeline by Delta seconds. Answers true when it finished on this call (not when it was killed).
const function Update(Timeline: Timeline, Delta: number, Driver: Driver): boolean
	if not Timeline.Running then
		return false
	end

	const Steps = Timeline.Steps

	if #Steps == 0 then
		Timeline.Running = false

		return true
	end

	local Elapsed = Timeline.Elapsed + Delta

	while true do
		if Timeline.StepIndex > #Steps then
			Timeline.Loop += 1

			if Timeline.PassDuration <= 0 or (Timeline.Loops ~= 0 and Timeline.Loop >= Timeline.Loops) then
				Timeline.Running = false
				Timeline.Elapsed = 0

				return true
			end

			Timeline.StepIndex = 1
			Timeline.PassDuration = 0
			EnterStep(Steps[1])
		end

		const Step = Steps[Timeline.StepIndex]

		for _, Entry in Step.Tweeners do
			if not Entry.Started then
				Entry.Started = true
				Driver.Begin(Entry)
			end

			if Entry.Kind == Kind.Callback then
				if not Entry.Called then
					Entry.Called = true

					if Entry.Callback then
						Entry.Callback()
					end

					if not Timeline.Running then
						return false
					end
				end
			elseif Entry.Kind ~= Kind.Interval then
				const Local = math.min(Elapsed, Entry.Duration)
				const Progress = if Entry.Duration > 0 then Ratio(Entry.Trans, Entry.Ease, Local / Entry.Duration) else 1

				for Index = 1, #Entry.Current do
					const Start = Entry.From[Index]

					Entry.Current[Index] = Start + (Entry.To[Index] - Start) * Progress
				end

				Driver.Apply(Entry)

				if not Timeline.Running then
					return false
				end
			end
		end

		if Elapsed < Step.Duration then
			break
		end

		Elapsed -= Step.Duration
		Timeline.PassDuration += Step.Duration
		Timeline.StepIndex += 1

		if Timeline.StepIndex <= #Steps then
			EnterStep(Steps[Timeline.StepIndex])
		end
	end

	Timeline.Elapsed = Elapsed

	return false
end

return {
	Transition = Transition,
	Easing = Easing,
	Kind = Kind,
	Ratio = Ratio,
	New = New,
	Append = Append,
	SetTrans = SetTrans,
	SetEase = SetEase,
	SetParallel = SetParallel,
	Parallel = Parallel,
	Chain = Chain,
	SetLoops = SetLoops,
	Kill = Kill,
	IsRunning = IsRunning,
	Update = Update,
}
