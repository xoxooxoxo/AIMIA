--!strict
--!optimize 2

--[[
	Game constants, as scripts/Constants.cs.

	Design Notes
		UserFolder is the root of the in-memory file system (Util/FileSystem), not an OS path. The OS folders
		(ROOT_FOLDER, DEFAULT_USER_FOLDER, USER_FOLDER_POINTER, PREVIOUS_USER_FOLDER, NIGHTLY_FOLDER) have no
		Roblox equivalent and are not ported. Bounds is a float32 vector (Godot Vector2 as a vector with Z = 0).
]]

const Numbers = require("./Numbers")
const Color = require("./Godot/Color")

const CursorSize = 0.2625
const GridSize = 3.0
const Bound = Numbers.F32(GridSize / 2 - CursorSize / 2)

-- @src scripts/Constants.cs:Constants L5-48
const Constants = {
	Started = os.clock(),
	UserFolder = "user",
	DefaultMapExt = "phxm",
	TempMapMode = false,
	CursorSize = CursorSize,
	GridSize = GridSize,
	Bounds = vector.create(Bound, Bound, 0),
	HitBoxSize = 0.07,
	HitWindow = 55,
	BreakTime = 4000,
	Difficulties = { "N/A", "Easy", "Medium", "Hard", "Insane", "Illogical" },
	DifficultyColors = {
		Color.FromRgba(0xffffffff),
		Color.FromRgba(0x77f379ff),
		Color.FromRgba(0xfff832ff),
		Color.FromRgba(0xe24479ff),
		Color.FromRgba(0x9d6effff),
		Color.FromRgba(0x0094fcff),
	},
}

return Constants
