--!strict
--!optimize 2

--[[
	The playback calls SoundManager makes per voice (Song, Menu, Hit, Miss, Fail). Clock is the default backend (silent,
	simulated); a Roblox backend (Sound instances, ids from AimiaContent/AudioAssets) replaces it through SoundManager.SetBackend.

	Design Notes
		Playing, StreamPaused, PitchScale, VolumeDb, Length and Loaded are kept by SoundManager in its player records. A backend
		gets each change as a call and answers only the position. A stream that reaches its length ends there: SoundManager
		sees it in Process (Position >= Length).
		MaxPolyphony is given at Load: the hit and miss voices overlap up to 16 plays, the others 1. A backend that cannot
		overlap ignores it.
]]

const Audio = require("./Audio")

export type Backend = {
	Load: (Voice: string, Stream: Audio.Stream?, MaxPolyphony: number) -> (),
	Play: (Voice: string, From: number) -> (),
	Stop: (Voice: string) -> (),
	SetPaused: (Voice: string, Paused: boolean) -> (),
	Seek: (Voice: string, Seconds: number) -> (),
	SetPitch: (Voice: string, Scale: number) -> (),
	SetVolume: (Voice: string, Db: number) -> (),
	Position: (Voice: string) -> number,
	-- (not in the source: whether the voice has moved since it was last started, seeked or resumed; a backend without it
	-- moves at once)
	Moving: ((Voice: string) -> boolean)?,
	TimeSinceLastMix: () -> number,
}

return {}
