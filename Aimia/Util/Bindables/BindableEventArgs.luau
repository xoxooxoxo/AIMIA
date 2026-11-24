--!strict
--!optimize 2

--[[
	Payload of Bindable.ValueChanged: the new value and the value it replaces, as scripts/util/bindables/BindableEventArgs.cs.

	Design Notes
		Fields are public and mutable in C#; the table is a fresh value per change.
]]

export type BindableEventArgs<T> = {
	Value: T,
	OldValue: T,
}

-- @src scripts/util/bindables/BindableEventArgs.cs:BindableEventArgs L3-8
const function New<T>(Value: T, OldValue: T): BindableEventArgs<T>
	return {
		Value = Value,
		OldValue = OldValue,
	}
end

return New
