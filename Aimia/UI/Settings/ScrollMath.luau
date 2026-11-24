--!strict
--!optimize 2

--[[
	Scroll rules of the settings menu's scroll areas (Godot ScrollContainer and its VScrollBar), Roblox-free.

	Design Notes
		The offset is the content's distance scrolled, in pixels, from 0 to MaxOffset. The thumb's length is the visible share
		of the track, and its top is the offset's share of the thumb's travel (Range rules: the thumb and the track end at the
		same fraction). WheelStep is the offset of one wheel tick.
		DEVIATION(unverified): the wheel step (40 pixels) is not in reference/engine; the thumb has no minimum length.
]]

const WheelStep = 40

-- The largest offset: the content taller than the viewport, less the viewport (0 when it fits).
const function MaxOffset(Content: number, Viewport: number): number
	return math.max(0, Content - Viewport)
end

-- The offset kept inside 0 and the largest offset.
const function ClampOffset(Offset: number, Content: number, Viewport: number): number
	return math.clamp(Offset, 0, MaxOffset(Content, Viewport))
end

-- The offset after a wheel tick: Direction is 1 for up (scrolls toward the top) and -1 for down.
const function WheelOffset(Offset: number, Direction: number, Content: number, Viewport: number): number
	return ClampOffset(Offset - Direction * WheelStep, Content, Viewport)
end

-- The thumb's length along a track of Track pixels: the visible share of the content (the whole track when it fits).
const function ThumbLength(Track: number, Content: number, Viewport: number): number
	if Content <= Viewport or Content <= 0 then
		return Track
	end

	return math.max(1, math.round(Track * Viewport / Content))
end

-- The thumb's top along the track for an offset.
const function ThumbTop(Track: number, Length: number, Offset: number, Max: number): number
	if Max <= 0 or Track <= Length then
		return 0
	end

	return math.round((Track - Length) * math.clamp(Offset, 0, Max) / Max)
end

-- The offset for a thumb top (dragging the thumb).
const function OffsetForThumb(Track: number, Length: number, Top: number, Max: number): number
	if Track <= Length then
		return 0
	end

	return math.clamp(Top, 0, Track - Length) * Max / (Track - Length)
end

return {
	WheelStep = WheelStep,
	MaxOffset = MaxOffset,
	ClampOffset = ClampOffset,
	WheelOffset = WheelOffset,
	ThumbLength = ThumbLength,
	ThumbTop = ThumbTop,
	OffsetForThumb = OffsetForThumb,
}
