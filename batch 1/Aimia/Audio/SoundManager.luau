--!strict
--!optimize 2

--[[
	SoundManager.cs: the song, the menu music, the hit, miss and fail sounds, the jukebox queue and the volume of each player,
	over the audio backend (Audio/Backend; the default is Audio/Clock, silent). The module table is the source's static class.

	Representation
		Song, MenuMusic, HitSound, MissSound and FailSound are Player records (Stream, Loaded, Length, Playing, StreamPaused,
		PitchScale, VolumeDb, MaxPolyphony). Map, JukeboxIndex, JukeboxQueue (map ids in MapManager order), Scope and the two
		signals are the static fields. JukeboxPanel.Playback is this module table: its fields Map, JukeboxIndex, JukeboxPlayed,
		JukeboxEmpty and its functions PlayJukebox, IsJukeboxPaused, ToggleJukeboxPause, PlaybackPosition and Seek.

	Design Notes
		A change that has a time (play, stop, seek, pitch, pause, volume) is a call here, which keeps the record and the
		backend in step. Song.PitchScale, Song.StreamPaused and Song.VolumeDb are read by other modules; they are written with
		SongSetPitch, SongSetPaused and SongSetVolumeDb.
		Godot's Song.Finished is Process: a player whose position reached its stream length has ended.
		Stream keys: skin sounds are their file names ("hit.mp3", "miss.mp3", "fail.mp3", "menu.mp3"); map audio is the MD5 hex of
		its bytes; a quiet stream is "sounds/quiet.mp3". The backend looks keys up in AimiaContent/AudioAssets.
		Hooks are set by the owners of the UI and of the presence; an unset hook does nothing, except Hooks.Panel, which
		ToggleJukeboxPause requires (the source dereferences JukeboxPanel.Instance there).
		The main menu's scene name is "SceneMenu" (main_menu.tscn): the source's `SceneManager.Scene is MainMenu` is that scene.
		DEVIATION(platform): Aimia.TempMode is never set in this port (no command line), so its check is dropped.
		DEVIATION(string-utf16): the presence title is cut by code points where the source cuts UTF-16 units; the two agree for BMP text.
		Not ported: printSongPlaybackState (it sets a flag nothing reads).
]]

const Backend = require("./Backend")
const LoadStream = require("./Audio")
const Clock = require("./Clock")
const Lobby = require("../Multiplayer/Lobby")
const MapManager = require("../Map/MapManager")
const MapTypes = require("../Map/MapTypes")
const FileSystem = require("../Util/FileSystem")
const MapUtil = require("../Map/MapUtil")
const Md5 = require("../Util/Md5")
const Numbers = require("../Numbers")
const Signal = require("../Util/Signal")
const SettingsItem = require("../Database/Settings/SettingsItem")
const SettingsManager = require("../SettingsManager")
const SettingsProfile = require("../Database/Settings/SettingsProfile")
const SkinManager = require("../Skinning/SkinManager")
const SkinProfile = require("../Skinning/SkinProfile")

export type Player = {
	Voice: string,
	Stream: LoadStream.Stream?,
	Loaded: boolean,
	Length: number,
	Playing: boolean,
	StreamPaused: boolean,
	PitchScale: number,
	VolumeDb: number,
	MaxPolyphony: number,
}

export type PlaybackScope = number

-- JukeboxPanel.Instance: the calls SoundManager makes on the jukebox panel.
export type PanelHooks = {
	UpdateMap: (Map: MapTypes.Map?) -> (),
	ClearMap: () -> (),
	ShowMenuTheme: () -> (),
}

-- The volume and offset popups: the label text, and for the volume the fraction of the bar (master / 100).
export type PopupHooks = {
	ShowVolume: (Text: string, Fraction: number) -> (),
	HideVolume: () -> (),
	ShowOffset: (Text: string) -> (),
	HideOffset: () -> (),
}

export type Hooks = {
	Panel: PanelHooks?,
	Popups: PopupHooks?,
	UpdatePresence: ((Text: string) -> ())?,
	SceneName: (() -> string?)?,
}

const PlaybackScope = {
	Silent = 0,
	Preview = 1,
	GameplayResults = 2,
}

const function NewPlayer(Voice: string, MaxPolyphony: number): Player
	return {
		Voice = Voice,
		Stream = nil,
		Loaded = false,
		Length = 0,
		Playing = false,
		StreamPaused = false,
		PitchScale = 1,
		VolumeDb = 0,
		MaxPolyphony = MaxPolyphony,
	}
end

const Song = NewPlayer("Song", 1)
const MenuMusic = NewPlayer("Menu", 1)
const HitSound = NewPlayer("Hit", 16)
const MissSound = NewPlayer("Miss", 16)
const FailSound = NewPlayer("Fail", 1)
const Players = { Song, MenuMusic, HitSound, MissSound, FailSound }

local Active: Backend.Backend = Clock
local MenuMusicPausedByUser = false
local VolumePopupShown = false
local LastVolumeChange = 0
local OffsetPopupShown = false
local LastOffsetChange = 0
local CachedBytes: buffer? = nil
local CachedKey = ""

const SoundManager = {
	Song = Song,
	MenuMusic = MenuMusic,
	HitSound = HitSound,
	MissSound = MissSound,
	FailSound = FailSound,
	JukeboxQueue = {} :: { number },
	JukeboxIndex = 0,
	JukeboxPaused = false,
	LastRewind = 0,
	Map = nil :: MapTypes.Map?,
	Scope = PlaybackScope.Silent,
	JukeboxPlayed = Signal.New() :: Signal.Signal<MapTypes.Map?>,
	JukeboxEmpty = Signal.New() :: Signal.Signal<()>,
	Hooks = {} :: Hooks,
}

const function CurrentSettings(): SettingsProfile.SettingsProfile
	return SettingsManager.Settings :: SettingsProfile.SettingsProfile
end

-- @src scripts/SoundManager.cs:isScopedPlayback L415-418
const function IsScopedPlayback(): boolean
	return not CurrentSettings().AutoplayJukebox.Value
end

-- Time.GetTicksMsec: the clock's seconds as whole milliseconds.
const function TicksMsec(): number
	return Clock.Hooks.Clock() * 1000 // 1
end

-- new Random().Next(0, Count): a random index below Count, 0 when Count is 0.
const function RandomIndex(Count: number): number
	if Count == 0 then
		return 0
	end

	return math.random(0, Count - 1)
end

const function CurrentSceneName(): string?
	const SceneName = SoundManager.Hooks.SceneName

	if SceneName == nil then
		return nil
	end

	return SceneName()
end

-- A new stream replaces the player's stream and stops the player (Godot's set_stream stops it); pause and pitch stay.
const function LoadPlayer(Player: Player, Stream: LoadStream.Stream?)
	Player.Playing = false
	Player.Stream = Stream
	Player.Loaded = Stream ~= nil
	Player.Length = if Stream then Stream.Length else 0

	Active.Load(Player.Voice, Stream, Player.MaxPolyphony)
end

const function StopPlayer(Player: Player)
	Player.Playing = false
	Active.Stop(Player.Voice)
end

-- Play(From) of a player without a stream does nothing.
const function PlayPlayer(Player: Player, From: number)
	if not Player.Loaded then
		return
	end

	Player.Playing = true
	Active.Play(Player.Voice, Numbers.F32(From))
end

const function SetPlayerPaused(Player: Player, Paused: boolean)
	Player.StreamPaused = Paused
	Active.SetPaused(Player.Voice, Paused)
end

const function SetPlayerPitch(Player: Player, Scale: number)
	Player.PitchScale = Numbers.F32(Scale)
	Active.SetPitch(Player.Voice, Player.PitchScale)
end

const function SetPlayerVolume(Player: Player, Db: number)
	Player.VolumeDb = Numbers.F32(Db)
	Active.SetVolume(Player.Voice, Player.VolumeDb)
end

-- @src scripts/SoundManager.cs:isSoundEffectEnabled L551-554
const function IsSoundEffectEnabled(Setting: SettingsItem.SettingsItem<boolean>?, Player: Player): boolean
	return Setting ~= nil and Setting.Value and Player.Stream ~= nil
end

-- @src scripts/SoundManager.cs:shouldPlayMenuMusic L526-549
const function ShouldPlayMenuMusic(): boolean
	if not CurrentSettings().EnableMenuMusic.Value then
		return false
	end

	if not MenuMusic.Loaded then
		return false
	end

	if CurrentSceneName() ~= "SceneMenu" then
		return false
	end

	-- The menu theme is what the paused jukebox plays: no song yet, or a song on pause.
	if Song.Playing and not Song.StreamPaused then
		return false
	end

	return true
end

-- DEVIATION(format): the text of a double as the labels show it: the shortest of %.15g, %.16g and %.17g that reads back.
-- .NET's exponent form (1E-05) is not produced; the labels never reach it.
const function NumberText(Value: number): string
	const Short = string.format("%.15g", Value)

	if tonumber(Short) == Value then
		return Short
	end

	const Longer = string.format("%.16g", Value)

	if tonumber(Longer) == Value then
		return Longer
	end

	return string.format("%.17g", Value)
end

-- Presence text (Discord.Client.UpdateState); unset until Discord is ported.
const function UpdatePresence(Text: string)
	const Update = SoundManager.Hooks.UpdatePresence

	if Update then
		Update(Text)
	end
end

-- The audio key of map audio: the MD5 hex of its bytes and the format as the extension ("<md5>.mp3", the name of its file in
-- out/AudioUpload and so its entry in AudioAssets). The last buffer is kept, so replaying a map hashes it once.
const function MapAudioKey(Bytes: buffer, Format: string): string
	if Bytes ~= CachedBytes then
		CachedBytes = Bytes
		CachedKey = Md5.ToHexLower(Md5.Hash({ Bytes }))
	end

	return `{CachedKey}.{Format}`
end

-- The streams of the maps' audio files by map name, read and hashed once.
const MapStreams: { [string]: LoadStream.Stream } = {}

-- The stream of a map's audio file in the maps folder (Util.Audio.LoadFromFile of {MapsFolder}/{name}/audio.{ext}); a map with
-- no file is the quiet stream.
const function MapFileStream(Map: MapTypes.Map): LoadStream.Stream
	const Cached = MapStreams[Map.Name]

	if Cached then
		return Cached
	end

	const Path = `{MapUtil.MapsFolder}/{Map.Name}/audio.{Map.AudioExt}`
	const Stream = LoadStream(if FileSystem.Exists(Path) then FileSystem.ReadAllBytes(Path) else nil)

	if Stream.Bytes ~= nil then
		Stream.Key = MapAudioKey(Stream.Bytes, Stream.Format)
		MapStreams[Map.Name] = Stream
	end

	return Stream
end

-- A skin sound: its stream keyed by its file name (the source loads the file from the skin folder, LoadSound).
const function LoadSkinSound(Player: Player, Bytes: buffer?, FileName: string)
	const Stream = LoadStream(Bytes)

	if Stream.Bytes ~= nil then
		Stream.Key = FileName
	end

	-- The menu music plays from its Roblox upload and isn't baked in (BakedSounds mounts a stand-in), so its length is the upload's.
	if FileName == "menu.mp3" then
		Stream.Length = 243
	end

	LoadPlayer(Player, Stream)
end

-- Maps.FindIndex(x => x.Id == map.Id): the 0-based index, -1 when the map is not listed.
const function IndexOfMap(Map: MapTypes.Map): number
	for Index, Candidate in MapManager.Maps do
		if Candidate.Id == Map.Id then
			return Index - 1
		end
	end

	return -1
end

-- JukeboxPanel.Instance, which the source uses without a check: an unset panel is an error.
const function RequiredPanel(): PanelHooks
	const Panel = SoundManager.Hooks.Panel

	if Panel == nil then
		error("Object reference not set to an instance of an object.", 0)
	end

	return Panel
end

-- @src scripts/SoundManager.cs:_Ready L65-88
const function SongFinished()
	-- The menu's jukebox: another song at random, for as long as you stay.
	if CurrentSceneName() == "SceneMenu" and CurrentSettings().AutoplayJukebox.Value and #SoundManager.JukeboxQueue > 0 then
		SoundManager.PlayRandom()
		return
	end

	if IsScopedPlayback() then
		SoundManager.StopScopedSession()
		return
	end

	const SceneName = CurrentSceneName()

	if SceneName == "SceneMenu" then
		if CurrentSettings().AutoplayJukebox.Value then
			SoundManager.JukeboxIndex += 1
			SoundManager.PlayJukebox(SoundManager.JukeboxIndex)
		end
	elseif SceneName == "SceneResults" then
		SoundManager.PlayJukebox(SoundManager.JukeboxIndex)
	end
end

-- Godot's Song.Finished for every player: a player whose position reached its length has ended. The song's end runs
-- SongFinished; the menu music is replayed by RefreshMenuMusicPlayback.
const function EndPlayers()
	for _, Player in Players do
		if Player.Playing and not Player.StreamPaused and Active.Position(Player.Voice) >= Player.Length then
			Player.Playing = false

			if Player == Song then
				SongFinished()
			end
		end
	end
end

-- @src scripts/SoundManager.cs:_Ready L91-94
const function OnSpeedChanged(Speed: number)
	SoundManager.SongSetPitch(Speed)
end

-- @src scripts/SoundManager.cs:_Ready L95-95
const function OnSelectedChanged()
	SoundManager.RefreshMenuMusicPlayback()
end

-- @src scripts/SoundManager.cs:_Ready L97-122
const function OnMapDeleted(Deleted: MapTypes.Map)
	SoundManager.UpdateJukeboxQueue()

	if SoundManager.Map ~= Deleted then
		return
	end

	if IsScopedPlayback() then
		SoundManager.StopScopedSession()
		return
	end

	if #SoundManager.JukeboxQueue == 0 then
		StopPlayer(Song)
		SoundManager.Map = nil
		Signal.Fire(SoundManager.JukeboxEmpty)
	else
		SoundManager.PlayJukebox(RandomIndex(#SoundManager.JukeboxQueue))
	end
end

-- @src scripts/SoundManager.cs:_Ready L126-138
const function Start()
	SoundManager.UpdateJukeboxQueue()
	SoundManager.RefreshMenuMusicPlayback()
end

-- @src scripts/SoundManager.cs:_Ready L42-151
function SoundManager.Initialize()
	Signal.Connect(SkinManager.Loaded, SoundManager.UpdateSkin)
	SoundManager.UpdateSkin(SkinManager.Skin)

	Signal.Connect(SettingsManager.Loaded, SoundManager.UpdateVolume)
	Signal.Connect(Lobby.SpeedChanged, OnSpeedChanged)
	Signal.Connect(MapManager.Selected.ValueChanged, OnSelectedChanged)
	Signal.Connect(MapManager.MapDeleted, OnMapDeleted)

	SoundManager.UpdateVolume()

	if MapManager.Initialized then
		Start()
		return
	end

	Signal.Connect(MapManager.MapsInitialized, Start)
	SoundManager.RefreshMenuMusicPlayback()
end

-- The song is dimmed after a fail or a quit, until the player picks a song, plays or restarts: dB taken off it, eased each frame.
const SongDimDb = -12
const SongDimSpeed = 30 -- dB per second
local SongDim = 0
local SongDimTarget = 0

function SoundManager.SetSongDimmed(Dimmed: boolean)
	SongDimTarget = if Dimmed then SongDimDb else 0
end

-- @src scripts/SoundManager.cs:_Process L153-174
function SoundManager.Process(Delta: number?)
	EndPlayers()

	if SongDim ~= SongDimTarget then
		-- (by the frame's time, PreRender's delta: a fixed 1/60 s a frame dimmed four times too fast at 240 FPS)
		const Step = SongDimSpeed * (if Delta and Delta == Delta then math.clamp(Delta, 0, 0.1) else 1 / 60)

		SongDim = if SongDim > SongDimTarget then math.max(SongDimTarget, SongDim - Step) else math.min(SongDimTarget, SongDim + Step)
		SoundManager.UpdateVolume()
	end

	SoundManager.RefreshMenuMusicPlayback()

	const Popups = SoundManager.Hooks.Popups

	if VolumePopupShown and TicksMsec() - LastVolumeChange >= 1000 then
		VolumePopupShown = false

		if Popups then
			Popups.HideVolume()
		end
	end

	if OffsetPopupShown and TicksMsec() - LastOffsetChange >= 1000 then
		OffsetPopupShown = false

		if Popups then
			Popups.HideOffset()
		end
	end
end

-- The mouse wheel while Ctrl or Alt (volume) or Shift (local offset) is held (_UnhandledInput). Up is the wheel direction.
-- @src scripts/SoundManager.cs:_UnhandledInput L176-235
function SoundManager.HandleWheel(Up: boolean, Ctrl: boolean, Alt: boolean, Shift: boolean)
	const Settings = CurrentSettings()
	const Popups = SoundManager.Hooks.Popups

	if Ctrl or Alt then
		const Master = Numbers.RoundHalfEven(Settings.VolumeMaster.Value)

		if Up then
			SettingsItem.SetValue(Settings.VolumeMaster, Numbers.F32(math.min(100, Master + 5)))
		else
			SettingsItem.SetValue(Settings.VolumeMaster, Numbers.F32(math.max(0, Master - 5)))
		end

		const Volume = Settings.VolumeMaster.Value

		if Popups then
			Popups.ShowVolume(NumberText(Volume), Volume / 100)
		end

		VolumePopupShown = true
		LastVolumeChange = TicksMsec()

		SoundManager.UpdateVolume()
	end

	if Shift then
		const Offset = Numbers.RoundHalfEven(Settings.LocalOffset.Value)

		if Up then
			SettingsItem.SetValue(Settings.LocalOffset, Offset + 1)
		else
			SettingsItem.SetValue(Settings.LocalOffset, Offset - 1)
		end

		if Popups then
			Popups.ShowOffset(`Local Offset: {NumberText(Settings.LocalOffset.Value)}ms`)
		end

		OffsetPopupShown = true
		LastOffsetChange = TicksMsec()
	end
end

-- Song.Stream = the stream of a map's audio bytes (Util/Audio.LoadStream): a missing buffer is the quiet stream.
function SoundManager.LoadSong(AudioBuffer: buffer?)
	const Stream = LoadStream(AudioBuffer)

	if Stream.Bytes ~= nil then
		Stream.Key = MapAudioKey(Stream.Bytes, Stream.Format)
	end

	LoadPlayer(Song, Stream)
end

-- @src scripts/SoundManager.cs:PlayJukebox L237-273
function SoundManager.PlayJukeboxMap(Map: MapTypes.Map?, SetRichPresence: boolean?)
	if Map == nil then
		return
	end

	if IsScopedPlayback() then
		SoundManager.StartMapSelectionPlayback(Map, SetRichPresence)
		return
	end

	StopPlayer(MenuMusic)
	MenuMusicPausedByUser = false
	SoundManager.Map = Map

	if Map.AudioBuffer == nil then
		SoundManager.JukeboxIndex += 1
		SoundManager.PlayJukebox(SoundManager.JukeboxIndex)
		return
	end

	SoundManager.JukeboxIndex = IndexOfMap(Map)
	LoadPlayer(Song, MapFileStream(Map))
	PlayPlayer(Song, 0)

	Signal.Fire(SoundManager.JukeboxPlayed, Map)

	if SetRichPresence ~= false then
		UpdatePresence(`Listening to {Map.PrettyTitle}`)
	end
end

-- @src scripts/SoundManager.cs:PlayJukebox L275-296
-- The songs played since the menu theme, oldest first: what the jukebox's back button walks through.
local PlayedIds: { number } = {}

-- A song at random from the list, the theme never among them, and not the one just heard while there is another to pick.
function SoundManager.PlayRandom()
	SoundManager.SetSongDimmed(false)

	const Queue = SoundManager.JukeboxQueue

	if #Queue == 0 then
		return
	end

	const CurrentId = if SoundManager.Map then SoundManager.Map.Id else nil
	local Choices: { number } = {}

	for _, Id in Queue do
		if Id ~= CurrentId then
			table.insert(Choices, Id)
		end
	end

	if #Choices == 0 then
		Choices = Queue
	end

	const Id = Choices[math.random(#Choices)]

	table.insert(PlayedIds, Id)
	SoundManager.PlayJukeboxMap(MapManager.GetMapById(Id))
end

-- As when the game has just opened: paused on the menu theme from its start, no song, nothing to go back through.
function SoundManager.RestartMenuTheme()
	SoundManager.SetSongDimmed(false)
	table.clear(PlayedIds)
	StopPlayer(MenuMusic)
	SetPlayerPaused(MenuMusic, false)
	MenuMusicPausedByUser = false
	SoundManager.StopScopedSession()
end

-- The song before this one, and from the first song, back to the paused menu theme.
function SoundManager.PlayPrevious()
	SoundManager.SetSongDimmed(false)
	table.remove(PlayedIds)

	const Id = PlayedIds[#PlayedIds]

	if Id == nil then
		SoundManager.RestartMenuTheme()
	else
		SoundManager.PlayJukeboxMap(MapManager.GetMapById(Id))
	end
end

function SoundManager.PlayJukebox(Index: number?, SetRichPresence: boolean?)
	const Queue = SoundManager.JukeboxQueue

	if #Queue == 0 then
		return
	end

	const Requested = if Index == nil or Index == -1 then SoundManager.JukeboxIndex else Index
	const Target = if Requested >= #Queue then 0 elseif Requested < 0 then #Queue - 1 else Requested

	SoundManager.PlayJukeboxMap(MapManager.GetMapById(Queue[Target + 1]), SetRichPresence)
end

-- @src scripts/SoundManager.cs:StartMapSelectionPlayback L298-340
function SoundManager.StartMapSelectionPlayback(Map: MapTypes.Map?, SetRichPresence: boolean?)
	if Map == nil then
		return
	end

	SoundManager.SetSongDimmed(false)

	StopPlayer(Song)
	SetPlayerPaused(Song, false)
	SetPlayerPitch(Song, Lobby.Speed)
	StopPlayer(MenuMusic)
	MenuMusicPausedByUser = false

	SoundManager.Map = Map
	SoundManager.Scope = PlaybackScope.Preview

	const Index = IndexOfMap(Map)

	if Index >= 0 then
		SoundManager.JukeboxIndex = Index
	end

	-- A map without audio has no file: its Song.Stream is null, so nothing plays.
	if Map.AudioBuffer == nil then
		LoadPlayer(Song, nil)
	else
		LoadPlayer(Song, MapFileStream(Map))
	end

	PlayPlayer(Song, 0)

	Signal.Fire(SoundManager.JukeboxPlayed, Map)

	if SetRichPresence ~= false then
		const Title = Map.PrettyTitle
		const Count = utf8.len(Title) or #Title
		const Cut = (utf8.offset(Title, 113) or #Title + 1) - 1
		const Shown = if Count > 115 then `{string.sub(Title, 1, Cut)}...` else Title

		UpdatePresence(`Listening to {Shown}`)
	end
end

-- @src scripts/SoundManager.cs:BeginGameplayScope L342-352
function SoundManager.BeginGameplayScope(Map: MapTypes.Map)
	if not IsScopedPlayback() then
		return
	end

	SoundManager.Map = Map
	SoundManager.Scope = PlaybackScope.GameplayResults
	StopPlayer(MenuMusic)
end

-- @src scripts/SoundManager.cs:StopScopedSession L354-363
function SoundManager.StopScopedSession()
	StopPlayer(Song)
	SetPlayerPaused(Song, false)
	SoundManager.Map = nil
	SoundManager.Scope = PlaybackScope.Silent
	Signal.Fire(SoundManager.JukeboxEmpty)

	SoundManager.RefreshMenuMusicPlayback()
end

-- @src scripts/SoundManager.cs:IsJukeboxPaused L365-373
function SoundManager.IsJukeboxPaused(): boolean
	return Song.StreamPaused or not Song.Playing
end

-- @src scripts/SoundManager.cs:ToggleJukeboxPause L375-413
function SoundManager.ToggleJukeboxPause(): boolean
	SoundManager.SetSongDimmed(false)

	if Song.Playing or Song.StreamPaused then
		SetPlayerPaused(Song, not Song.StreamPaused)
		RequiredPanel().UpdateMap(SoundManager.Map)

		return Song.StreamPaused
	end

	-- Nothing picked yet: play starts a random song.
	SoundManager.PlayRandom()

	return not Song.Playing
end

-- Volume in dB of a player at a volume and master (0 to 100) over a range in dB. Volume or master at 0 is silence (-inf).
-- @src scripts/SoundManager.cs:ComputeVolumeDb L420-425
function SoundManager.ComputeVolumeDb(Volume: number, Master: number, Range: number): number
	const Level = Numbers.F32(Volume)
	const Gain = Numbers.F32(Master)
	const Span = Numbers.F32(Range)

	if Level <= 0 or Gain <= 0 then
		return -math.huge
	end

	return Numbers.F32(-80 + Span * (Numbers.F32(Level / 100) ^ 0.1) * (Numbers.F32(Gain / 100) ^ 0.1))
end

-- The volume (0 to 100) of a dB value: the inverse of ComputeVolumeDb, clamped to 0 to 100.
-- @src scripts/SoundManager.cs:ComputeVolumeFromDb L427-432
function SoundManager.ComputeVolumeFromDb(Db: number, Master: number, Range: number): number
	const Level = Numbers.F32(Db)
	const Gain = Numbers.F32(Master)
	const Span = Numbers.F32(Range)

	if Level == -math.huge or Gain <= 0 then
		return 0
	end

	const Shifted = Numbers.F32(Level + 80)
	const Raw = 100 * (Shifted / (Span * (Numbers.F32(Gain / 100) ^ 0.1))) ^ 10
	const Clamped = if Raw < 0 then 0 elseif Raw > 100 then 100 else Raw

	return Numbers.F32(Clamped)
end

-- @src scripts/SoundManager.cs:UpdateVolume L434-443
function SoundManager.UpdateVolume()
	const Settings = CurrentSettings()
	const Master = Settings.VolumeMaster.Value

	SetPlayerVolume(Song, SoundManager.ComputeVolumeDb(Settings.VolumeMusic.Value, Master, 70) + SongDim)
	SetPlayerVolume(MenuMusic, SoundManager.ComputeVolumeDb(Settings.VolumeMenuMusic.Value, Master, 70))
	SetPlayerVolume(HitSound, SoundManager.ComputeVolumeDb(Settings.VolumeHitSound.Value, Master, 80))
	SetPlayerVolume(MissSound, SoundManager.ComputeVolumeDb(Settings.VolumeMissSound.Value, Master, 80))
	SetPlayerVolume(FailSound, SoundManager.ComputeVolumeDb(Settings.VolumeSFX.Value, Master, 80))
end

-- @src scripts/SoundManager.cs:PlayHitSound L445-453
function SoundManager.PlayHitSound()
	const Settings = SettingsManager.Settings
	const Setting = if Settings then Settings.EnableHitSound else nil

	if not IsSoundEffectEnabled(Setting, HitSound) then
		return
	end

	PlayPlayer(HitSound, 0)
end

-- @src scripts/SoundManager.cs:PlayMissSound L455-463
function SoundManager.PlayMissSound()
	const Settings = SettingsManager.Settings
	const Setting = if Settings then Settings.EnableMissSound else nil

	if not IsSoundEffectEnabled(Setting, MissSound) then
		return
	end

	PlayPlayer(MissSound, 0)
end

-- The fail sound plays without a setting check: the Runner calls FailSound.Play directly.
function SoundManager.PlayFail()
	PlayPlayer(FailSound, 0)
end

-- @src scripts/SoundManager.cs:UpdateJukeboxQueue L465-468
function SoundManager.UpdateJukeboxQueue()
	const Ids: { number } = {}

	for _, Map in MapManager.Maps do
		table.insert(Ids, Map.Id)
	end

	SoundManager.JukeboxQueue = Ids
end

-- @src scripts/SoundManager.cs:UpdateSkin L470-478
function SoundManager.UpdateSkin(Skin: SkinProfile.SkinProfile)
	LoadSkinSound(HitSound, Skin.HitSoundBuffer, "hit.mp3")
	LoadSkinSound(MissSound, Skin.MissSoundBuffer, "miss.mp3")
	LoadSkinSound(FailSound, Skin.FailSoundBuffer, "fail.mp3")
	LoadSkinSound(MenuMusic, Skin.MenuMusicBuffer, "menu.mp3")

	SoundManager.RefreshMenuMusicPlayback()
end

-- @src scripts/SoundManager.cs:RefreshMenuMusicPlayback L480-524
function SoundManager.RefreshMenuMusicPlayback()
	const Panel = SoundManager.Hooks.Panel

	if Panel and not Song.StreamPaused then
		Panel.UpdateMap(SoundManager.Map)
	end

	if MenuMusicPausedByUser then
		if MenuMusic.Playing and not MenuMusic.StreamPaused then
			SetPlayerPaused(MenuMusic, true)
		end

		if Panel then
			Panel.ShowMenuTheme()
		end

		return
	end

	if ShouldPlayMenuMusic() then
		if MenuMusic.StreamPaused then
			SetPlayerPaused(MenuMusic, false)
		elseif not MenuMusic.Playing then
			PlayPlayer(MenuMusic, 0)
		end

		if Panel then
			Panel.ShowMenuTheme()
		end
	elseif MenuMusic.Playing or MenuMusic.StreamPaused then
		StopPlayer(MenuMusic)
		SetPlayerPaused(MenuMusic, false)

		if SoundManager.Map == nil and Panel then
			Panel.ClearMap()
		end
	end
end

-- MenuMusic.Stop() (Results): the menu music stops; its pause is kept.
function SoundManager.StopMenuMusic()
	StopPlayer(MenuMusic)
end

-- The song's position in seconds (GetPlaybackPosition).
function SoundManager.SongPosition(): number
	return Active.Position(Song.Voice)
end

-- (Not in the source: whether the song has moved since it was last started, seeked or resumed. Roblox starts one 50-150 ms
-- after it is asked; a backend that cannot tell answers true.)
function SoundManager.SongMoving(): boolean
	const Moving = Active.Moving

	return if Moving then Moving(Song.Voice) else true
end

-- Song.Play(From): from From seconds, 0 by default.
function SoundManager.SongPlay(From: number?)
	PlayPlayer(Song, From or 0)
end

function SoundManager.SongStop()
	StopPlayer(Song)
end

-- Song.Seek(Seconds): moves a playing song (paused or not); a stopped song does nothing.
function SoundManager.SongSeek(Seconds: number)
	Active.Seek(Song.Voice, Numbers.F32(Seconds))
end

function SoundManager.SongSetPaused(Paused: boolean)
	SetPlayerPaused(Song, Paused)
end

function SoundManager.SongSetPitch(Scale: number)
	SetPlayerPitch(Song, Scale)
end

function SoundManager.SongSetVolumeDb(Db: number)
	SetPlayerVolume(Song, Db)
end

-- AudioServer.GetTimeSinceLastMix.
function SoundManager.TimeSinceLastMix(): number
	return Active.TimeSinceLastMix()
end

-- FlatPreview.Hooks.Playback (scripts/ui/FlatPreview.cs): while the named map's song is loaded, whether it plays (not paused)
-- and its position in seconds; nil, nil otherwise.
function SoundManager.Playhead(MapName: string): (boolean?, number?)
	const Map = SoundManager.Map

	if Map == nil or Map.Name ~= MapName then
		return nil, nil
	end

	return not Song.StreamPaused, SoundManager.SongPosition()
end

-- Replaces the backend. Each player is loaded into the new one with its state; a playing player plays from its position in
-- the old one.
function SoundManager.SetBackend(Next: Backend.Backend)
	const Previous = Active
	Active = Next

	for _, Player in Players do
		const Position = Previous.Position(Player.Voice)

		Next.Load(Player.Voice, Player.Stream, Player.MaxPolyphony)
		Next.SetVolume(Player.Voice, Player.VolumeDb)
		Next.SetPitch(Player.Voice, Player.PitchScale)
		Next.SetPaused(Player.Voice, Player.StreamPaused)

		if Player.Playing then
			Next.Play(Player.Voice, Position)
		end
	end
end

-- JukeboxPanel.Playback contract: the same functions as SongPosition and SongSeek.
SoundManager.PlaybackPosition = SoundManager.SongPosition
SoundManager.Seek = SoundManager.SongSeek

return SoundManager
