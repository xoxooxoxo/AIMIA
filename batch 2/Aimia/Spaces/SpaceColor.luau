--!strict
--!optimize 2

--[[
	The colors of the Space Color setting: the far field of the grid (its fog) and the fill of the void, dark so the notes stay readable.
	Nil for "default": the grid keeps its violet and the void the clear color.
]]

const Colors: { [string]: { number } } = {
	black = { 0, 0, 0 },
	red = { 0.172, 0.009, 0.011 },
	orange = { 0.193, 0.049, 0.007 },
	yellow = { 0.163, 0.132, 0.007 },
	green = { 0.011, 0.153, 0.029 },
	teal = { 0.007, 0.132, 0.163 },
	blue = { 0.011, 0.029, 0.225 },
	purple = { 0.078, 0.014, 0.23 },
	pink = { 0.203, 0.014, 0.11 },
	crimson = { 0.2, 0.0, 0.035 },
	magenta = { 0.19, 0.0, 0.17 },
	violet = { 0.13, 0.03, 0.22 },
	indigo = { 0.04, 0.02, 0.2 },
	navy = { 0.0, 0.03, 0.12 },
	cyan = { 0.0, 0.15, 0.2 },
	mint = { 0.03, 0.17, 0.11 },
	lime = { 0.09, 0.17, 0.0 },
	gray = { 0.06, 0.06, 0.07 },
}

const function Of(Name: string): { number }?
	return Colors[Name]
end

return {
	Of = Of,
}
