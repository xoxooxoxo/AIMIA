--!strict

--[[
	Frames: the switch that pauses AIMIA's frames, and the frame clock.

	Paused is set while the handheld is closed (Client.Controllers.Handheld): nothing of AIMIA's runs each frame behind the
	world.

	The clock steps once a frame, first thing in the frame's dispatch (UI/Nodes), from PreRender's delta. Time is what the
	runner's timeline and the cursor trail read for the frame (the game scene's ticks), and Delta is what every OnProcess and
	OnFrame callback gets, so they all move by the same step. Before, the runner and the trail read os.clock part-way through
	the frame, so each step also carried how long the work before that read took, which differs every frame: at 240 FPS a
	large share of a 4 ms frame, seen as uneven motion.

	Smoothing takes out frame timing noise. While frames come at a steady rate the clock steps by their average time, pulled
	toward real time by 15% of the gap each frame (at most a fifth of a frame), so it stays within a millisecond or two of
	real time. A hitch (a frame half again as long as the average, or half as short) passes straight through, as does a gap
	of over a frame; three such frames in a row mean the rate has changed, and the average starts over.

	Whatever the smoothing asks, the clock never steps backward and stays within a quarter of a frame ahead of real time
	(Lead). When frames came faster all at once, the average followed them slowly, the clock ran more than a frame ahead,
	and its snap back to real time was a backward step: the notes moved backward for a frame (seen in Studio, 2026-11-08).
]]

const Frames = {
	Paused = false,
	-- the clock's seconds (os.clock's count) and this frame's step in seconds
	Time = os.clock(),
	Delta = 1 / 60,
	-- the average frame time in seconds (0 until frames come steadily): UIStep and Budget read it
	Mean = 0,
	Smoothing = true,
}

-- frame times within this share of the average are steady; the average follows them by this share a frame
const Window = 0.5
const Follow = 0.05
-- the share of the gap to real time taken back each frame, and its limit as a share of a frame
const Pull = 0.15
const PullLimit = 0.2
-- how far ahead of real time the clock may run, as a share of a frame
const Lead = 0.25

-- real time, as the frames' deltas add up; the average frame time; frames in a row off it
local Real = Frames.Time
local Mean = 0
local Odd = 0

-- Steps the clock by one frame of Raw seconds (PreRender's delta).
function Frames.Step(Raw: number)
	Raw = math.max(Raw, 0)
	Real += Raw

	-- (straight through: the clock lands on real time)
	local Delta = Real - Frames.Time

	if Frames.Smoothing then
		if Mean > 0 and math.abs(Raw - Mean) <= Window * Mean then
			Odd = 0
			Mean += (Raw - Mean) * Follow

			const Gap = Delta - Mean

			if math.abs(Gap) <= Mean then
				Delta = Mean + math.clamp(Gap * Pull, -PullLimit * Mean, PullLimit * Mean)
			end
		else
			Odd += 1

			if Mean == 0 or Odd >= 3 then
				Mean = Raw
				Odd = 0
			end
		end

		-- (at most a frame behind real time and a quarter of a frame ahead of it)
		const Straight = Real - Frames.Time
		const Frame = if Mean > 0 then Mean else Raw

		Delta = math.clamp(Delta, Straight - Frame, Straight + Lead * Frame)
	end

	-- (never backward)
	Delta = math.max(Delta, 0)

	Frames.Delta = Delta
	Frames.Time += Delta
	Frames.Mean = Mean
end

-- A UI animation's step this frame (Tween, the menu backdrop's fade): Delta, but at most two average frames, so a fade that
-- starts on a slow frame (a scene being built) eases in from its start instead of jumping most of the way at once.
function Frames.UIStep(): number
	return math.min(Frames.Delta, if Mean > 0 then 2 * Mean else 1 / 30)
end

-- A frame's work budget in seconds (the menu backdrop's and the results backdrop's painting): Share of the average frame,
-- within Low and High. A budget sized for a 60 FPS frame took most of a 240 FPS one and halved the frame rate while it ran.
function Frames.Budget(Share: number, Low: number, High: number): number
	return math.clamp(Share * (if Mean > 0 then Mean else 1 / 60), Low, High)
end

return Frames
