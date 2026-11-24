--!strict
--!optimize 2

--[[
	Godot's Tween for the UI ports (docs/port/ui.md, "Tweens"): property, method and callback tweeners, stepped every
	frame by the dispatch of UI/Nodes (OnFrame) with the timeline and easing of UI/TweenCore.

	Design Notes
		A tween created with an owner item is killed when the owner is freed. Finished fires when the tween completes
		(not when it is killed); connect it with Util/Signal.
		A property tweener reads the property (Nodes.Get) when its step starts and writes it (Nodes.Set) every frame.
		A number, a vector (a Vector2) or a color ({ Color = {r, g, b, a} }) interpolates per component. The tweener's
		value table is reused, so a tween allocates nothing per frame.
		TweenProperty and TweenMethod answer the tweener; SetTweenerTrans and SetTweenerEase set its transition and ease
		(Godot's PropertyTweener.set_trans and set_ease). SetTrans and SetEase set the defaults of the tweeners created
		after them, as Godot's Tween.set_trans does.
		Not in the source (smoothness): a tween steps by Frames.UIStep, the frame's step but at most two average frames, so a
		tween that starts on (or runs through) a slow frame eases on from where it was instead of jumping ahead.
]]

const Frames = require("./Frames")
const Items = require("./Item")
const Nodes = require("./Nodes")
const TweenCore = require("./TweenCore")
const Signal = require("../Util/Signal")

type Item = Items.Item

-- What a property tweener writes: a number, a vector, or a color table.
type Shape = "number" | "vector" | "color"

type PropertyPayload = {
	Timeline: TweenCore.Timeline,
	Item: Item,
	Property: string,
	Shape: Shape,
	Color: { Color: { number } },
}

type MethodPayload = {
	Callback: (number) -> (),
}

export type Tween = {
	Timeline: TweenCore.Timeline,
	Finished: Signal.Signal<...unknown>,
	Stop: (() -> ())?,
}

-- The shape of a value to tween, and its number of components.
const function ShapeOf(Value: unknown): (Shape, number)
	if type(Value) == "vector" then
		return "vector", 2
	elseif type(Value) == "table" then
		return "color", 4
	end

	return "number", 1
end

-- Copies a value's components into Target (a vector's x and y, a color's four components, a number).
const function LoadComponents(Value: unknown, Target: { number }, Shape: Shape)
	if Shape == "vector" then
		const Vector = if type(Value) == "vector" then Value :: vector else vector.zero

		Target[1] = Vector.x
		Target[2] = Vector.y
	elseif Shape == "color" then
		const Components = if type(Value) == "table" then (Value :: { Color: { number }? }).Color else nil

		for Index = 1, 4 do
			Target[Index] = if Components then Components[Index] or 1 else 1
		end
	else
		Target[1] = if type(Value) == "number" then Value else 0
	end
end

const function Begin(Tweener: TweenCore.Tweener)
	if Tweener.Kind ~= TweenCore.Kind.Property then
		return
	end

	const Payload = Tweener.Payload :: PropertyPayload

	-- A tween of a freed node ends (Godot invalidates a tween whose target is gone).
	if Payload.Item.Freed then
		TweenCore.Kill(Payload.Timeline)

		return
	end

	LoadComponents(Nodes.Get(Payload.Item, Payload.Property), Tweener.From, Payload.Shape)
end

const function Apply(Tweener: TweenCore.Tweener)
	const Current = Tweener.Current

	if Tweener.Kind == TweenCore.Kind.Method then
		(Tweener.Payload :: MethodPayload).Callback(Current[1])

		return
	elseif Tweener.Kind ~= TweenCore.Kind.Property then
		return
	end

	const Payload = Tweener.Payload :: PropertyPayload

	if Payload.Item.Freed then
		TweenCore.Kill(Payload.Timeline)

		return
	end

	if Payload.Shape == "vector" then
		Nodes.Set(Payload.Item, Payload.Property, vector.create(Current[1], Current[2], 0))
	elseif Payload.Shape == "color" then
		const Components = Payload.Color.Color

		for Index = 1, 4 do
			Components[Index] = Current[Index]
		end

		Nodes.Set(Payload.Item, Payload.Property, Payload.Color)
	else
		Nodes.Set(Payload.Item, Payload.Property, Current[1])
	end
end

const Driver = {
	Begin = Begin,
	Apply = Apply,
} :: TweenCore.Driver

-- Drops what a finished or killed tween holds: its frame subscription, and its steps with their callbacks and targets, so
-- nothing it touched is kept alive by it. (A tween never runs again once finished or killed.)
const function Release(Created: Tween)
	if Created.Stop then
		Created.Stop()
		Created.Stop = nil
	end

	table.clear(Created.Timeline.Steps)
end

const function Kill(Created: Tween)
	TweenCore.Kill(Created.Timeline)
	Release(Created)
end

const function Advance(Created: Tween, Delta: number)
	if TweenCore.Update(Created.Timeline, Delta, Driver) then
		Release(Created)
		Signal.Fire(Created.Finished)
	elseif not TweenCore.IsRunning(Created.Timeline) then
		-- Killed from inside (the target was freed): the frame subscription ends with it.
		Release(Created)
	end
end

-- Godot's create_tween: a tween that runs from the next frame. With an owner it is killed when the owner is freed.
const function Create(Owner: Item?): Tween
	const Created = {
		Timeline = TweenCore.New(),
		Finished = Signal.New(),
		Stop = nil,
	} :: Tween

	Created.Stop = Nodes.OnFrame(function(Delta: number)
		-- (a freed owner takes its tweens with it: they aren't listed on the owner, which may live all session)
		if Owner and Owner.Freed then
			Kill(Created)

			return
		end

		Advance(Created, Frames.UIStep())
	end)

	return Created
end

-- Godot's tween_property: sets Property of the item from its current value to Final over Duration seconds.
const function TweenProperty(Created: Tween, Item: Item, Property: string, Final: unknown, Duration: number): TweenCore.Tweener
	const Shape, Count = ShapeOf(Final)
	const Entry = TweenCore.Append(Created.Timeline, TweenCore.Kind.Property, Duration, Count)

	LoadComponents(Final, Entry.To, Shape)

	Entry.Payload = {
		Timeline = Created.Timeline,
		Item = Item,
		Property = Property,
		Shape = Shape,
		Color = { Color = table.create(4, 1) },
	} :: PropertyPayload

	return Entry
end

-- Godot's tween_method: calls Callback with values from From to To over Duration seconds.
const function TweenMethod(Created: Tween, Callback: (number) -> (), From: number, To: number, Duration: number): TweenCore.Tweener
	const Entry = TweenCore.Append(Created.Timeline, TweenCore.Kind.Method, Duration, 1)

	Entry.From[1] = From
	Entry.To[1] = To
	Entry.Payload = { Callback = Callback } :: MethodPayload

	return Entry
end

-- Godot's tween_callback: calls Callback when its step starts.
const function TweenCallback(Created: Tween, Callback: () -> ()): TweenCore.Tweener
	const Entry = TweenCore.Append(Created.Timeline, TweenCore.Kind.Callback, 0, 0)

	Entry.Callback = Callback

	return Entry
end

-- Godot's tween_interval: waits Duration seconds.
const function TweenInterval(Created: Tween, Duration: number): TweenCore.Tweener
	return TweenCore.Append(Created.Timeline, TweenCore.Kind.Interval, Duration, 0)
end

const function SetTrans(Created: Tween, Trans: number)
	TweenCore.SetTrans(Created.Timeline, Trans)
end

const function SetEase(Created: Tween, EaseType: number)
	TweenCore.SetEase(Created.Timeline, EaseType)
end

-- Godot's set_parallel (default true): the tweeners that follow run together with the previous one.
const function SetParallel(Created: Tween, On: boolean?)
	TweenCore.SetParallel(Created.Timeline, On ~= false)
end

-- Godot's parallel(): the next tweener runs with the previous one.
const function Parallel(Created: Tween)
	TweenCore.Parallel(Created.Timeline)
end

-- Godot's chain(): the next tweener runs after the previous one.
const function Chain(Created: Tween)
	TweenCore.Chain(Created.Timeline)
end

-- Godot's set_loops: 1 runs once, 0 loops forever.
const function SetLoops(Created: Tween, Loops: number)
	TweenCore.SetLoops(Created.Timeline, Loops)
end

const function SetTweenerTrans(Entry: TweenCore.Tweener, Trans: number)
	Entry.Trans = Trans
end

const function SetTweenerEase(Entry: TweenCore.Tweener, EaseType: number)
	Entry.Ease = EaseType
end

const function IsRunning(Created: Tween): boolean
	return TweenCore.IsRunning(Created.Timeline)
end

return {
	Create = Create,
	TweenProperty = TweenProperty,
	TweenMethod = TweenMethod,
	TweenCallback = TweenCallback,
	TweenInterval = TweenInterval,
	SetTrans = SetTrans,
	SetEase = SetEase,
	SetParallel = SetParallel,
	Parallel = Parallel,
	Chain = Chain,
	SetLoops = SetLoops,
	SetTweenerTrans = SetTweenerTrans,
	SetTweenerEase = SetTweenerEase,
	Kill = Kill,
	IsRunning = IsRunning,
	TransitionType = TweenCore.Transition,
	EaseType = TweenCore.Easing,
}
