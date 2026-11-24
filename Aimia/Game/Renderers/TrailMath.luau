--!strict
--!optimize 2

--[[
	The cursor trail math of TrailRenderer.cs: the emission rate from TrailDetail and the spawn accumulator, a trail's lifetime,
	its alpha, and whether it is skipped because the cursor did not move. Roblox-free: the view (Game/View/TrailRenderer) keeps
	the trail records and the quads.

	Representation
		Spawner is { Accumulator } (the source's deltaAccumulator, in seconds). Times are microseconds (Time.GetTicksUsec), numbers
		below 2^53.

	Design Notes
		TrailDetail is clamped as a double, then cast to float32; the rate is float32 and the interval is the double 1 / rate.
		The lifetime is (ulong)(TrailTime * 1e6): the product is truncated, and a negative one saturates to 0.
		The alpha: elapsed is float32 (ulong difference) / 1e6, step is float32 Clamp(elapsed / TrailTime, 0, 1), and
		Mathf.Lerp(1, 0, step) is 1 + (0 - 1) * step, which is 1 - step in float32.
		Skipped is Vector2.DistanceTo == 0 through Math.DistanceTo, whose squares are float32: a gap that squares to zero counts
		as no movement, as in the source.
]]

const Math = require("../../Godot/Math")
const Numbers = require("../../Numbers")

export type Spawner = {
	Accumulator: number,
}

-- trail_spawn_rate: trails per second at full detail.
const SpawnRate = 240

-- trail_min_detail and trail_max_detail: TrailDetail is clamped to [0, 100].
const MinDetail = 0
const MaxDetail = 100

-- Math.Clamp on doubles; NaN stays NaN, as Math.Clamp does.
const function Clamp(Value: number, Lower: number, Upper: number): number
	if Value < Lower then
		return Lower
	end

	if Value > Upper then
		return Upper
	end

	return Value
end

-- The trails per second for a TrailDetail: TrailDetail / 100 * 240 in float32.
-- @src scripts/game/renderers/TrailRenderer.cs:processTrailSpawning L47-65
const function EmissionRate(TrailDetail: number): number
	const Detail = Numbers.F32(Clamp(TrailDetail, MinDetail, MaxDetail))
	const Wanted = Numbers.F32(Detail / MaxDetail)

	return Numbers.F32(Wanted * SpawnRate)
end

-- Adds the frame's delta to the accumulator and answers true when a trail spawns. At most one trail spawns per frame, and a
-- zero rate spawns nothing and keeps the accumulator.
-- @src scripts/game/renderers/TrailRenderer.cs:processTrailSpawning L47-65
const function Spawns(Spawner: Spawner, Delta: number, Rate: number): boolean
	if Rate <= 0 then
		return false
	end

	const Interval = 1 / Rate

	Spawner.Accumulator += Delta

	const Steps = Numbers.TruncInt32(Spawner.Accumulator / Interval)

	if Steps <= 0 then
		return false
	end

	Spawner.Accumulator -= Interval * Steps

	return true
end

-- maxLifeTime: (ulong)(TrailTime * 1_000_000) in microseconds.
-- @src scripts/game/renderers/TrailRenderer.cs:cullExpiredTrails L67-80
const function Lifetime(TrailTime: number): number
	return math.max(0, Numbers.Trunc(TrailTime * 1000000))
end

-- A trail is culled once its age reaches the lifetime.
-- @src scripts/game/renderers/TrailRenderer.cs:cullExpiredTrails L67-80
const function Expired(Now: number, Time: number, MaxLife: number): boolean
	return Now - Time >= MaxLife
end

-- The trail's alpha: 1 when it spawns, 0 once TrailTime has passed.
-- @src scripts/game/renderers/TrailRenderer.cs:updateTrailRendering L82-113
const function Alpha(Now: number, Time: number, TrailTime: number): number
	const Elapsed = Numbers.F32(Numbers.F32(Now - Time) / 1000000)
	const Step = Numbers.F32(Clamp(Elapsed / TrailTime, 0, 1))

	return Numbers.F32(1 - Step)
end

-- A trail the cursor has not moved away from since it spawned is drawn fully transparent.
-- @src scripts/game/renderers/TrailRenderer.cs:updateTrailRendering L82-113
const function Skipped(TrailPosition: vector, CursorPosition: vector): boolean
	return Math.DistanceTo(TrailPosition, CursorPosition) == 0
end

return {
	EmissionRate = EmissionRate,
	Spawns = Spawns,
	Lifetime = Lifetime,
	Expired = Expired,
	Alpha = Alpha,
	Skipped = Skipped,
}
