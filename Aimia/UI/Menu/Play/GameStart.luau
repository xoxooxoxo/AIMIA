--!strict
--!optimize 2

--[[
	Game.Play (scripts/scenes/Game.cs): a run's start from the map info and the score panels, with the map, speed, start time,
	camera mode and modifiers (and the replays, to watch one).

	Design Notes
		The game scene is phase 3. It sets Hooks.Play; until then a start is logged and nothing starts (the source would switch
		scenes). A replay start passes its replay list, as the source's last argument.
]]

const CameraMode = require("../../../Game/Camera/CameraMode")
const Logger = require("../../../Util/Logger")
const Modifier = require("../../../Game/Modifiers/Modifier")
const MapTypes = require("../../../Map/MapTypes")
const Replay = require("../../../Map/Replay")

export type PlayHook = (Map: MapTypes.Map, Speed: number, StartFrom: number, Camera: CameraMode.CameraMode, Mods: { Modifier.Modifier }, Replays: { Replay.Replay }?) -> ()

const Hooks = {
	Play = nil :: PlayHook?,
	-- the map info's VS button: a VS lobby with this song, speed, camera, modifiers and start (ms; Multiplayer/Versus, set by
	-- the Handheld). Answers whether it was asked for, and why not.
	Versus = nil :: ((Map: MapTypes.Map, Speed: number, Camera: CameraMode.CameraMode, Mods: { Modifier.Modifier }, StartFrom: number?) -> (boolean, string?))?,
}

-- @src scripts/scenes/Game.cs:Play L211-222
const function Play(Map: MapTypes.Map, Speed: number, StartFrom: number, Camera: CameraMode.CameraMode, Mods: { Modifier.Modifier }, Replays: { Replay.Replay }?)
	const Hook = Hooks.Play

	if Hook then
		Hook(Map, Speed, StartFrom, Camera, Mods, Replays)

		return
	end

	Logger.Log(`Game is not ported yet (phase 3): {Map.Name} was not started`)
end

return {
	Hooks = Hooks,
	Play = Play,
}
