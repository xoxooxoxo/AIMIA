--!strict
--!optimize 2

--[[
	The progress shader of the jukebox spectrum (scripts/shaders/jukebox_progress.gdshader) without Roblox: where its color
	changes from color_fill to color_background, as a count of columns of the element.

	Design Notes
		The shader's x = (SCREEN_UV.x - margin / 2) / (1 - margin) reaches the progress at SCREEN_UV.x = margin / 2 +
		progress * (1 - margin). A column is filled while its pixel center lies left of that edge, so the fill is the first
		Columns of the element: Columns = ceil(edge * ViewportWidth - Left - 0.5), clamped to the element's width.
]]

-- The number of leading columns of an element at screen position Left and Width pixels wide that take color_fill.
-- @src scripts/shaders/jukebox_progress.gdshader:fragment L8-12
const function FillColumns(Progress: number, Margin: number, ViewportWidth: number, Left: number, Width: number): number
	const Edge = Margin / 2 + Progress * (1 - Margin)

	return math.clamp(math.ceil(Edge * ViewportWidth - Left - 0.5), 0, Width)
end

return FillColumns
