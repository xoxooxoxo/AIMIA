--!strict
--!optimize 2

--[[
	Bindable<T>: a value whose writes fire ValueChanged, as scripts/util/bindables/Bindable.cs.

	Design Notes
		Value is a field read directly. Writes go through Set, which fires ValueChanged synchronously with
		(Bindable, BindableEventArgs { Value, OldValue }), as the C# setter does, even when the value is unchanged.
		ValueChanged is a Util/Signal; Dispose clears its listeners (the C# sets the event to null).
]]

const Signal = require("../Signal")
const NewEventArgs = require("./BindableEventArgs")

export type Bindable<T> = {
	Name: string?,
	Default: T,
	Value: T,
	ValueChanged: Signal.Signal<Bindable<T>, NewEventArgs.BindableEventArgs<T>>,
}

-- @src scripts/util/bindables/Bindable.cs:Bindable L22-26
-- @src scripts/util/bindables/Bindable.cs:Bindable L28-33
const function New<T>(DefaultValue: T, Name: string?): Bindable<T>
	return {
		Name = Name,
		Default = DefaultValue,
		Value = DefaultValue,
		ValueChanged = Signal.New() :: Signal.Signal<Bindable<T>, NewEventArgs.BindableEventArgs<T>>,
	}
end

-- @src scripts/util/bindables/Bindable.cs:Value L11-20
const function Set<T>(Bindable: Bindable<T>, Value: T)
	const OldValue = Bindable.Value

	Bindable.Value = Value
	Signal.Fire(Bindable.ValueChanged, Bindable, NewEventArgs(Value, OldValue))
end

-- @src scripts/util/bindables/Bindable.cs:Dispose L35-35
const function Dispose<T>(Bindable: Bindable<T>)
	Signal.Clear(Bindable.ValueChanged)
end

-- DEVIATION(format): tostring, so a boolean reads "true" where .NET's ToString reads "True".
-- @src scripts/util/bindables/Bindable.cs:ToString L37-37
const function ToString<T>(Bindable: Bindable<T>): string
	return tostring(Bindable.Value)
end

return {
	New = New,
	Set = Set,
	Dispose = Dispose,
	ToString = ToString,
}
