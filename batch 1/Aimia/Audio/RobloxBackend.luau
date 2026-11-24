--!strict
--!optimize 2

--[[
	The Roblox audio backend (Audio/Backend). A sound voice plays through an AudioPlayer, one per polyphony slot, with the
	asset of its stream key from AimiaContent/AudioAssets (rbxtemp:// or rbxassetid://). Every player is wired to one mixer
	(an AudioFader) that feeds the device output and an AudioAnalyzer: the analyzer is the master bus's spectrum analyzer
	(AudioSpectrum reads it through Magnitude). A voice without an asset plays on Audio/Clock, so the game keeps its timing
	without audio. Install makes this the backend of SoundManager.

	Design Notes
		The logic is Audio/VoiceState (lute-tested); this file only creates the audio instances and forwards to them.
		AudioPlayer has no pause: Stop keeps the time position, so Pause is Stop and Resume is Play; the handle's Stop also
		returns to the start, as Sound:Stop does. Stop does not fire Ended; only a natural end does.
		The analyzer's spectrum is read at most once a frame, by the first Magnitude of the frame (nothing asks in a song over
		the grid): its bins span 0 to the Nyquist frequency (half of SampleRate), and a frequency range answers the largest bin
		in it (Godot's MAGNITUDE_MAX, the default of the spectrum analyzer).
		Install sets Clock.Hooks.Clock to os.clock: the seconds source of the clock voices and of the pending starts. Nothing
		else sets it, so the clock stays at 0 (nothing moves) until Install runs.
]]

const RunService = game:GetService("RunService")

const Frames = require("../UI/Frames")
const SoundService = game:GetService("SoundService")

const AudioFolder = Instance.new("Folder")
const Mixer = Instance.new("AudioFader")
const Output = Instance.new("AudioDeviceOutput")
const Analyzer = Instance.new("AudioAnalyzer")

const AudioAssets = require("../../AimiaContent/AudioAssets")
const AudioGains = require("../../AimiaContent/AudioGains")
const Clock = require("./Clock")
const SoundManager = require("./SoundManager")
const VoiceState = require("./VoiceState")

-- The engine's mixing rate; the analyzer's bins span half of it.
const SampleRate = 48000

-- Every song (an asset with an AudioGains entry) plays this much louder on top of its map's gain: 25% more (2026-11-08),
-- then 10% more on top of that (1.25 x 1.1, 2026-11-20). Hit, miss, fail and the menu theme have no entry and stay as
-- they are.
const SongBoost = 1.375

-- A map that ends before its song does (a chart of only the start of a song) says where the song ends through its stub length
-- (VoiceState's Length, handed over by SetEnd): the song fades out over this many seconds up to there, then stops and ends
-- as if the file ended there (2026-11-22). A song whose stub is its whole length (every map before) never fades.
const SongFadeLength = 3

AudioFolder.Name = "AimiaAudio"
AudioFolder.Parent = SoundService

Mixer.Name = "Mixer"
Mixer.Parent = AudioFolder
Output.Name = "Output"
Output.Parent = AudioFolder
Analyzer.Name = "Analyzer"
Analyzer.SpectrumEnabled = true
Analyzer.Parent = AudioFolder

-- A wire from a source to a target, owned by the source.
const function Connect(Source: Instance, Target: Instance)
	const Link = Instance.new("Wire")

	Link.SourceInstance = Source
	Link.TargetInstance = Target
	Link.Parent = Source
end

Connect(Mixer, Output)
Connect(Mixer, Analyzer)

-- The analyzer's spectrum of this frame.
local Bins: { number } = {}

-- One AudioPlayer as a VoiceState handle. OnLoaded runs once the asset is ready, OnEnded when playback reaches its end.
const function NewSound(OnLoaded: () -> (), OnEnded: () -> ()): VoiceState.SoundHandle
	const Player = Instance.new("AudioPlayer")
	-- A song boosted by its map's Sound Volume (AudioGains above 1) plays through this limiter so its peaks can't clip; at
	-- a gain of 1 or less it is bypassed and the voice sounds exactly as before.
	const Limiter = Instance.new("AudioLimiter")
	Limiter.MaxLevel = -0.5
	Limiter.Bypass = true

	local Notified = false
	-- the asset playing and the volume asked for: a song's own gain (AudioGains, from its map's Sound) multiplies the volume
	local Asset = ""
	local Wanted = 1
	-- where the song ends for its map (seconds into the song), the fade factor now, and the frame watch while a fade can happen
	local EndAt = math.huge
	local Fade = 1
	local Watch: RBXScriptConnection? = nil

	const function ApplyVolume()
		const Listed = AudioGains[Asset]
		const Gain = if Listed then Listed * SongBoost else 1

		Player.Volume = Wanted * Gain * Fade
		Limiter.Bypass = Gain <= 1
	end

	const function Check()
		if Player.IsReady and not Notified then
			Notified = true
			OnLoaded()
		end
	end

	const function IsLoaded(): boolean
		return Player.IsReady
	end

	const function IsPlaying(): boolean
		return Player.IsPlaying
	end

	const function GetTimePosition(): number
		return Player.TimePosition
	end

	const function SetTimePosition(Seconds: number)
		Player.TimePosition = Seconds
	end

	const function SetAsset(NewAsset: string)
		Notified = false
		Asset = NewAsset
		Player.Asset = NewAsset
		ApplyVolume()

		task.defer(Check)
	end

	const function SetSpeed(Scale: number)
		Player.PlaybackSpeed = Scale
	end

	const function StopWatch()
		if Watch then
			Watch:Disconnect()
			Watch = nil
		end

		if Fade ~= 1 then
			Fade = 1
			ApplyVolume()
		end
	end

	-- Each frame while the song can end early: the fade before EndAt, and the end itself.
	const function WatchEnd()
		if not Player.IsReady then
			return
		end

		if EndAt >= Player.TimeLength - 1 then
			StopWatch()

			return
		end

		const Position = Player.TimePosition
		const Factor = math.clamp((EndAt - Position) / SongFadeLength, 0, 1)

		if Factor ~= Fade then
			Fade = Factor
			ApplyVolume()
		end

		if Position >= EndAt and Player.IsPlaying then
			Player:Stop()
			OnEnded()
		end
	end

	const function SetEnd(Seconds: number)
		EndAt = if Seconds > 0 then Seconds else math.huge

		if EndAt == math.huge then
			StopWatch()
		elseif Watch == nil then
			Watch = RunService.Heartbeat:Connect(WatchEnd)
		end
	end

	const function SetVolume(Volume: number)
		Wanted = Volume
		ApplyVolume()
	end

	const function Play()
		Player:Play()
	end

	const function Pause()
		Player:Stop()
	end

	const function Resume()
		Player:Play()
	end

	const function Stop()
		Player:Stop()

		Player.TimePosition = 0
	end

	const function Destroy()
		if Watch then
			Watch:Disconnect()
			Watch = nil
		end

		Player:Destroy()
	end

	Player.Parent = AudioFolder
	Limiter.Parent = Player
	Connect(Player, Limiter)
	Connect(Limiter, Mixer)
	Player:GetPropertyChangedSignal("IsReady"):Connect(Check)
	Player.Ended:Connect(OnEnded)

	return {
		IsLoaded = IsLoaded,
		IsPlaying = IsPlaying,
		GetTimePosition = GetTimePosition,
		SetTimePosition = SetTimePosition,
		SetAsset = SetAsset,
		SetSpeed = SetSpeed,
		SetVolume = SetVolume,
		Play = Play,
		Pause = Pause,
		Resume = Resume,
		Stop = Stop,
		Destroy = Destroy,
		SetEnd = SetEnd,
	}
end

-- Whether Bins is from an earlier frame. The spectrum is read when something first asks for it in a frame (a background's
-- bands, the jukebox's bars), not every frame: a song over the grid asks for none of it, and each read makes a table of every
-- bin. False until Install's frame loop marks it, as Bins stayed empty until then.
local BinsStale = false

-- The largest magnitude of the analyzer's bins between two frequencies (Hz).
const function Magnitude(Lower: number, Upper: number): number
	if BinsStale then
		BinsStale = false
		Bins = Analyzer:GetSpectrum()
	end

	const Count = #Bins

	if Count == 0 then
		return 0
	end

	const BinWidth = SampleRate / 2 / Count
	const First = math.clamp(Lower // BinWidth + 1, 1, Count)
	const Last = math.clamp(math.max(math.ceil(Upper / BinWidth), First), 1, Count)
	local Largest = 0

	for Index = First, Last do
		Largest = math.max(Largest, Bins[Index])
	end

	return Largest
end

const function Install()
	VoiceState.Hooks.NewSound = NewSound
	VoiceState.Hooks.Assets = AudioAssets
	Clock.Hooks.Clock = os.clock

	RunService.PreRender:Connect(function()
		if not Frames.Paused then
			BinsStale = true
		end
	end)

	SoundManager.SetBackend(VoiceState)
end

return {
	Load = VoiceState.Load,
	Play = VoiceState.Play,
	Stop = VoiceState.Stop,
	SetPaused = VoiceState.SetPaused,
	Seek = VoiceState.Seek,
	SetPitch = VoiceState.SetPitch,
	SetVolume = VoiceState.SetVolume,
	Position = VoiceState.Position,
	TimeSinceLastMix = VoiceState.TimeSinceLastMix,
	Magnitude = Magnitude,
	Install = Install,
}
