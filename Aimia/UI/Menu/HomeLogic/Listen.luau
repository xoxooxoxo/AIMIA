--!strict
--!optimize 2

--[[
	Connects a listener to a Util/Signal that is not an item's own (a settings, skin or stats event), and drops it when the
	item is freed: the disconnect goes into the item's Cleanup, which Nodes runs on QueueFree.
]]

const Items = require("../../Item")
const Signal = require("../../../Util/Signal")

const function Listen<T...>(Item: Items.Item, Emitter: Signal.Signal<T...>, Listener: (T...) -> ())
	Signal.Connect(Emitter, Listener)

	table.insert(Item.Cleanup, function()
		Signal.Disconnect(Emitter, Listener)
	end)
end

return Listen
