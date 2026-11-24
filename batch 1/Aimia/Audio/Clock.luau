--!strict
--!optimize 2

--[[
	The default audio backend: a silent simulated stream player per voice. A voice that plays and is not paused advances at
	its pitch scale through the seconds of Hooks.Clock, and ends when its position reaches its length.

	Representation
		Anchor is the stream position at AnchorTime. Every change (play, stop, seek, pitch, pause) and every read folds the
		time since AnchorTime into Anchor first, so a change applies from the moment it is made.

	Design Notes
		Hooks.Clock is the seconds source. It stays at 0 until a host sets it (tests drive it by hand), so nothing moves.
		Nothing is heard: SetVolume keeps nothing (SoundManager keeps VolumeDb).
		TimeSinceLastMix is 0: the simulated mix happens at each read, so there is no output latency to add back.
		A stopped voice reads position 0. Play on a voice without a stream does nothing; Seek on a voice that does not play
		does nothing (Godot drops the playback on stop). Pause and pitch survive Load, as the player's properties do in Godot.
]]

const Audio = require("./Audio")

export type ClockVoice = {
	Loaded: boolean,
	Length: number,
	Playing: boolean,
	Paused: boolean,
	Pitch: number,
	Anchor: number,
	AnchorTime: number,
}

const function FixedClock(): number
	return 0
end

const Hooks = {
	Clock = FixedClock,
}

const Voices: { [string]: ClockVoice } = {}

-- The state of a voice, created on first use: not loaded, not playing, not paused, at pitch 1.
const function StateOf(Voice: string): ClockVoice
	const Existing = Voices[Voice]

	if Existing then
		return Existing
	end

	const Created = {
		Loaded = false,
		Length = 0,
		Playing = false,
		Paused = false,
		Pitch = 1,
		Anchor = 0,
		AnchorTime = 0,
	}
	Voices[Voice] = Created

	return Created
end

-- Folds the time since AnchorTime into Anchor while the voice plays and is not paused, and ends the voice at its length.
const function Advance(State: ClockVoice): number
	if State.Playing and not State.Paused then
		const Now = Hooks.Clock()

		State.Anchor = math.min(State.Anchor + (Now - State.AnchorTime) * State.Pitch, State.Length)
		State.AnchorTime = Now

		if State.Anchor >= State.Length then
			State.Playing = false
		end
	end

	return State.Anchor
end

const function Load(Voice: string, Stream: Audio.Stream?, MaxPolyphony: number)
	const State = StateOf(Voice)

	State.Loaded = Stream ~= nil
	State.Length = if Stream then Stream.Length else 0
	State.Playing = false
	State.Anchor = 0
end

const function Play(Voice: string, From: number)
	const State = StateOf(Voice)

	if not State.Loaded then
		return
	end

	State.Playing = true
	State.Anchor = math.clamp(From, 0, State.Length)
	State.AnchorTime = Hooks.Clock()
end

const function Stop(Voice: string)
	const State = StateOf(Voice)

	State.Playing = false
	State.Anchor = 0
end

const function SetPaused(Voice: string, Paused: boolean)
	const State = StateOf(Voice)

	Advance(State)
	State.Paused = Paused
	State.AnchorTime = Hooks.Clock()
end

const function Seek(Voice: string, Seconds: number)
	const State = StateOf(Voice)

	Advance(State)

	if not State.Playing then
		return
	end

	State.Anchor = math.clamp(Seconds, 0, State.Length)
	State.AnchorTime = Hooks.Clock()
end

const function SetPitch(Voice: string, Scale: number)
	const State = StateOf(Voice)

	if Scale == State.Pitch then
		return
	end

	Advance(State)
	State.Pitch = Scale
	State.AnchorTime = Hooks.Clock()
end

-- A silent backend: the volume has no output.
const function SetVolume(Voice: string, Db: number)
	return
end

const function Position(Voice: string): number
	return Advance(StateOf(Voice))
end

const function TimeSinceLastMix(): number
	return 0
end

return {
	Hooks = Hooks,
	Load = Load,
	Play = Play,
	Stop = Stop,
	SetPaused = SetPaused,
	Seek = Seek,
	SetPitch = SetPitch,
	SetVolume = SetVolume,
	Position = Position,
	TimeSinceLastMix = TimeSinceLastMix,
}
