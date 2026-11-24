--!strict
--!optimize 2

--[[
	Serial queues of tween runs by key, Roblox-free: a run starts when the runs queued before it under the same key are done
	(upstream's queueTween awaits the previous tween of the same toast).

	Design Notes
		A run receives Done and calls it once its tween has finished, or at once when it has nothing to do. A key's queue is
		released when its last run is done, so a key that is idle starts its next run at once.
]]

export type Run = (Done: () -> ()) -> ()

export type TweenQueue = {
	Busy: { [string]: { Run } },
}

const function New(): TweenQueue
	return { Busy = {} }
end

-- Starts Run under Key; when it is done, starts the next run queued under Key, or releases Key.
const function Advance(Queue: TweenQueue, Key: string, Run: Run)
	Run(function()
		const Waiting = Queue.Busy[Key] :: { Run }
		const Next = table.remove(Waiting, 1)

		if Next then
			Advance(Queue, Key, Next)
		else
			Queue.Busy[Key] = nil
		end
	end)
end

-- Runs Run now when Key is idle, else after the runs queued before it under Key.
const function Enqueue(Queue: TweenQueue, Key: string, Run: Run)
	const Waiting = Queue.Busy[Key]

	if Waiting then
		table.insert(Waiting, Run)

		return
	end

	Queue.Busy[Key] = {}

	Advance(Queue, Key, Run)
end

return {
	New = New,
	Enqueue = Enqueue,
}
