--!strict
--!optimize 2

--[[
	Pure-Luau signal for Godot signals and C# events, delegates and Actions.

	Design Notes
		Fire calls listeners synchronously in connection order over a snapshot of the list, as C# multicast
		delegates and Godot EmitSignal do. Connect is `event += handler`; Disconnect is `event -= handler`
		(removes the last occurrence). Invoke is `event.Invoke(...)` without `?.`: it errors when nothing is
		connected, as C# throws on a null delegate.
]]

export type Signal<T...> = {
	Listeners: { (T...) -> () },
}

const function New<T...>(): Signal<T...>
	const Listeners: { (T...) -> () } = {}

	return {
		Listeners = Listeners,
	}
end

const function Connect<T...>(Signal: Signal<T...>, Listener: (T...) -> ())
	table.insert(Signal.Listeners, Listener)
end

const function Disconnect<T...>(Signal: Signal<T...>, Listener: (T...) -> ())
	const Listeners = Signal.Listeners

	for Index = #Listeners, 1, -1 do
		if Listeners[Index] == Listener then
			table.remove(Listeners, Index)
			return
		end
	end
end

const function Fire<T...>(Signal: Signal<T...>, ...: T...)
	const Listeners = Signal.Listeners

	if #Listeners == 0 then
		return
	end

	for _, Listener in table.clone(Listeners) do
		Listener(...)
	end
end

const function Invoke<T...>(Signal: Signal<T...>, ...: T...)
	if #Signal.Listeners == 0 then
		error("Object reference not set to an instance of an object.", 0)
	end

	Fire(Signal, ...)
end

const function Clear<T...>(Signal: Signal<T...>)
	table.clear(Signal.Listeners)
end

return {
	New = New,
	Connect = Connect,
	Disconnect = Disconnect,
	Fire = Fire,
	Invoke = Invoke,
	Clear = Clear,
}
