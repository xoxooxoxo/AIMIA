--!strict
--!optimize 2

--[[
	The motion of the settings menu's fades, Roblox-free: the progress of a timed fade, Godot's Quad easing, and the
	transparency a visual gets at a fade's alpha.

	Design Notes
		Godot's tweens of the menu use TRANS_QUAD: EASE_OUT (1 - (1 - t)^2) for the show and hide fades, and the default
		EASE_IN_OUT for the option popup. The menu drives one value from 0 (hidden) to 1 (shown) with its ease, and every
		transparency and the holder's slide follow from it, so an interrupted fade starts from the value it has reached.
		Transparency is the modulate of Godot: an element of base transparency T shows alpha A as 1 - (1 - T) * A.
]]

const EaseOut = 0
const EaseInOut = 1

-- The fraction of a fade's duration that has passed, from 0 to 1 (a zero duration is done at once).
const function Progress(Elapsed: number, Duration: number): number
	if Duration <= 0 then
		return 1
	end

	return math.clamp(Elapsed / Duration, 0, 1)
end

-- Godot's TRANS_QUAD easing of a fraction T (0 to 1) for EaseOut or EaseInOut.
const function Quad(T: number, Ease: number): number
	if Ease == EaseInOut then
		if T < 0.5 then
			return 2 * T * T
		end

		return 1 - (-2 * T + 2) * (-2 * T + 2) / 2
	end

	return 1 - (1 - T) * (1 - T)
end

-- The value between From and To at an eased fraction.
const function Blend(From: number, To: number, Eased: number): number
	return From + (To - From) * Eased
end

-- The transparency of an element of base transparency Base at an alpha (1 shows the base, 0 hides it).
const function Transparency(Base: number, Alpha: number): number
	return 1 - (1 - Base) * Alpha
end

return {
	EaseOut = EaseOut,
	EaseInOut = EaseInOut,
	Progress = Progress,
	Quad = Quad,
	Blend = Blend,
	Transparency = Transparency,
}
