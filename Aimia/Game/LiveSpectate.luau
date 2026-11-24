--!strict
--!optimize 2

--[[
	Watching someone's song live. The player's game sends what it's doing while anyone watches; the watcher's game plays the same
	map as a replay that keeps growing (Attempt.IsLive), a moment behind the player so the results are there before the notes are.

	Sending: Attach starts it for a song that is not a replay. Nothing goes out but the song's name until the host says someone
	is watching (SetWatched): then cursor frames and note results, in batches. SendSnapshot answers a new watcher: everything they
	need to catch up to now. A song ending sends the final numbers (End).
	Watching: Watch starts the map with the snapshot, Receive adds batches, TargetEnded takes the final numbers and shows the
	results once the view reaches them.

	Design Notes
		Hooks connect this to the host (Client.Controllers.Handheld): Send(Kind, ...) goes to the server, Started says the view is up,
		Ended says there's nothing left to watch. Everything crossing the network is checked here: a batch that doesn't read is dropped.
		The watcher's settings stay out of it. The attempt reads a fresh profile holding the player's values (written straight to
		.Value, so no update action runs and nothing saves), and the skin's note mesh and colors are put back by StopWatching. Volumes
		and the hit sounds stay the watcher's, because SoundManager reads the watcher's profile; so does their audio offset.
		A listed run's replay shows its player's look the same way: SharedOf goes up with the replay (SendReplayTail)
		and comes back with it, and the Leaderboards menu makes it the replay's profile with ProfileOf.
		The song lists only take a run with its replay, so a run that could be listed sends its replay up as it is recorded
		(Streams): a slice of the new cursor frames every ReplayGap seconds, about 1.4 KB, built from frames the runner has already
		recorded, and when the run ends the rest of the file, a few KB, just ahead of End. The server then has the whole replay
		before it has the final numbers, so leaving right after a song, a slow connection or a long replay can't cost the run.
		Nothing is compressed, hashed or read from a file while the song plays. Each run has a token of its own (Song, the replay's
		pieces and End all carry it), so the server never pairs one run's end or replay with another run.
		A batch is flags (u8, bit 0 playing), frame count and result count (u16 each), then frames (progress, x, y as f32) and results
		(note index as u32, lateness as f32, -1 for a miss), then the player's fade-out (f32) and pushback (u8) as they are then, which F
		and P change mid-song (a batch without them still reads). Lateness is read when the batch is sent, after the runner has stored it.
]]

const EncodingService = game:GetService("EncodingService")
const HttpService = game:GetService("HttpService")
const UserInputService = game:GetService("UserInputService")

const AttemptModule = require("./Attempt")
const Constants = require("../Constants")
const FileSystem = require("../Util/FileSystem")
const Game = require("./Game")
const HitResult = require("./Judgments/HitResult")
const MapModule = require("../Map/Map")
const MapParser = require("../Map/MapParser")
const MapTypes = require("../Map/MapTypes")
const ObjectType = require("../Map/Objects/ObjectType")
const OnlineBoard = require("../Map/OnlineBoard")
const ReplayFile = require("../Map/Replay")
const ReplayManager = require("./Managers/ReplayManager")
const RunnerModule = require("./Runner")
const SettingsManager = require("../SettingsManager")
const SettingsProfile = require("../Database/Settings/SettingsProfile")
const SettingsProfileConverter = require("../Database/Settings/SettingsProfileConverter")
const Signal = require("../Util/Signal")
const SkinManager = require("../Skinning/SkinManager")
const SoundManager = require("../Audio/SoundManager")
const GridSpace = require("./View/GridSpace")
const NoteGlow = require("./View/NoteGlow")
const SpaceColor = require("../Spaces/SpaceColor")
const SkinSets = require("../Skinning/SkinSets")
const Tone = require("./View/Tone")

-- (cursor frames go out at 60 a second, as a replay records them, on a fixed schedule: frames taken whenever 1/30 s had passed
-- came 8 or 9 frames apart at 240 FPS, and the watcher's cursor sped up and slowed down between them)
const FrameGap = 1 / 60
const BatchGap = 0.1
-- How far behind the newest batch a watcher stays, in seconds, on top of the time batches take to arrive: enough that the cursor
-- always has a next frame to move toward and a late note's result is there before the note is.
const WatchDelay = 0.3
const SongDrift = 0.4
const Statuses = { PASSED = true, DISQUALIFIED = true, FAILED = true }
const Pending = -2
-- A run's replay on its way up: a slice of frames every ReplayGap seconds, at most ReplaySlice frames a message (12 bytes each).
const ReplayGap = 2
const ReplaySlice = 1024
-- Modifiers whose runs the song lists never take (the server's Rules.MOD_BONUS has none for them): their replays stay here.
const Unlisted = { NoFail = true, Autoplay = true }

-- The player's settings a watcher sees: what the song looks like, not how it sounds or how they aim.
const SharedSettings = {
	"Sensitivity", "CursorDrift", "ApproachRate", "ApproachDistance", "ApproachTime", "FadeIn", "FadeOut", "Pushback",
	"CameraParallax", "HUDParallax", "FoV", "GameSpace", "SpaceColor", "SpaceHitEffects", "SpaceEffects", "NoteColors",
	"NoteOpacity", "NoteOpacityExponent", "NoteMesh", "NoteSize", "NoteGlow", "NoteGlowStrength", "NoteGlowFade", "CursorScale", "CursorOpacity", "CursorRotation", "CursorTrail",
	"TrailTime", "TrailDetail", "HPLerpValue", "GridGuides", "SimpleHUD", "SuperSimpleHUD", "AltComboCounter", "VisibilityAssist",
	"HitPopups", "MissPopups", "CursorStyle", "CursorColor", "TrailImage", "TrailSpacing", "TrailShrink", "TrailOpacity", "TrailColor", "Border",
}

-- The rest of a player's saved settings: they go with the look but never change what a watcher sees or hears, only what Copy
-- Settings saves (CopyToProfile). Left out on purpose: Local Offset (each player's own audio delay), the user folder, the
-- window settings Roblox has no use for, and Approach Time (worked out from the rate and distance).
const CopiedSettings = {
	"VerticalSensitivity", "AbsoluteSensitivity", "AbsoluteInput", "EdgeOvershoot", "MenuScale", "HudScale", "MenuSpace", "TrailPreset",
	"UseCursorInMenus", "GridGuidesOff", "Popups", "VolumeMaster", "VolumeMusic", "VolumeSFX", "VolumeHitSound", "VolumeMissSound",
	"VolumeMenuMusic", "AlwaysPlayHitSound", "AutoplayJukebox", "DisplayFPS", "RecordReplays",
}

-- What goes up with a song or a listed run's replay: the look, then the rest (the server keeps at most 128).
const SentSettings = table.clone(SharedSettings)

for _, Name in CopiedSettings do
	table.insert(SentSettings, Name)
end

-- Never taken from another player into a profile of one's own.
const NotCopied = { LocalOffset = true, ApproachTime = true, HPLerpValue = true, Skin = true, SetUserFolderPath = true, RecordReplays = true }

type Session = Game.Session
type Attempt = AttemptModule.Attempt

export type Final = {
	Status: string,
	Accuracy: number,
	Score: number,
	Hits: number,
	Misses: number,
	Sum: number,
	Progress: number,
	DeathTime: number,
}

type Sending = {
	Session: Session,
	Attempt: Attempt,
	Frames: { number },
	Results: { number },
	LastFrame: number,
	LastBatch: number,
	Watched: boolean,
	Listener: (number, number) -> (),
	-- what the server was last told of the song's clock (for the Spectate tab): when, the song's time then, whether it played
	ClockAt: number,
	ClockProgress: number,
	ClockPlaying: boolean,
	-- the run's token, whether its replay is going up as it plays, how many of its frames have gone, and when the last slice went
	Token: string,
	Streams: boolean,
	ReplaySent: number,
	ReplayAt: number,
	-- how many times the screen was touched during the song, and what counts them (Attach)
	Touches: number,
	TouchWatch: RBXScriptConnection?,
}

type Viewing = {
	Session: Session?,
	Recording: ReplayFile.Replay,
	Speed: number,
	Newest: number,
	Arrival: number,
	Playing: boolean,
	Held: boolean,
	Final: Final?,
	FinalAt: number,
	Finished: boolean,
	NextSongCheck: number,
	-- when the player's frames said their song stopped (paused), or nil while it plays
	PausedAt: number?,
}

const Hooks = {
	Send = nil :: ((string, ...any) -> ())?,
	Started = nil :: (() -> ())?,
	-- the view ended with nothing to show; Reason "away" when the player left their song for the settings
	Ended = nil :: ((Reason: string?) -> ())?,
	-- the view reached the player's results
	Finished = nil :: ((Status: string) -> ())?,
}

local Outgoing: Sending? = nil
local Current: Viewing? = nil

const function Send(Kind: string, ...: any)
	const Hook = Hooks.Send

	if Hook then
		Hook(Kind, ...)
	end
end

const function Finite(Value: unknown, Fallback: number): number
	return if type(Value) == "number" and math.isfinite(Value) then Value else Fallback
end

-- The player's look ----------------------------------------------------------------------------------------------------

-- The sent settings' values, by name: what goes to a watcher, and up with a listed run's replay. With them, not a setting,
-- NoteGlowShown: whether the notes glowed on the player's own screen (Note Glow on and graphics that draw it,
-- Game/View/NoteGlow), so a watcher on higher graphics doesn't see a glow the player never had.
const function SharedOf(Settings: SettingsProfile.SettingsProfile): { [string]: unknown }
	const Shared: { [string]: unknown } = {}

	for _, Name in SentSettings do
		const Item: any = SettingsProfile.ItemNamed(Settings, Name)

		if Item then
			Shared[Name] = Item.Value
		end
	end

	Shared.NoteGlowShown = NoteGlow.Wanted(Settings) and NoteGlow.ScreenDraws()

	return Shared
end

-- A fresh profile holding another player's look (written straight to .Value, so no update action runs and nothing saves).
-- A value of the wrong type, or a name that could reach outside the colorset or mesh folders, keeps the default. The audio
-- offset is the watcher's own, and it never records.
const function ProfileOf(Given: unknown): SettingsProfile.SettingsProfile
	const Own = SettingsManager.Settings :: SettingsProfile.SettingsProfile
	const Profile = SettingsProfile.New()
	const Values: { [string]: unknown } = if type(Given) == "table" then Given :: any else {}

	for _, Name in SharedSettings do
		const Item: any = SettingsProfile.ItemNamed(Profile, Name)
		const Value: any = Values[Name]

		if Item and type(Value) == type(Item.Value) then
			local Wanted: any = Value

			if type(Wanted) == "number" then
				if not math.isfinite(Wanted) then
					continue
				end

				-- (inside the setting's own range, as the settings menu keeps it)
				if Item.Slider then
					Wanted = math.clamp(Wanted, Item.Slider.Floor, Item.Slider.Ceiling)
				end
			elseif type(Wanted) == "string" and (#Wanted > 64 or string.find(Wanted, "[/\\]") or string.find(Wanted, "..", 1, true)) then
				continue
			end

			-- (a renamed map skin set arrives under its new name)
			if type(Wanted) == "string" and SkinSets.Renamed[Wanted] then
				Wanted = SkinSets.Renamed[Wanted]
			end

			-- (a background that was taken out shows as the skin's: the profile's default)
			if Name == "GameSpace" and SettingsProfile.RetiredSpaces[Wanted] then
				continue
			end

			Item.Value = Wanted
		end
	end

	-- (the approach time follows the rate and distance, as the settings work it out)
	if Profile.ApproachRate.Value > 0 then
		Profile.ApproachTime.Value = Profile.ApproachDistance.Value / Profile.ApproachRate.Value
	end

	-- (Note Glow as the player's own screen showed it: none there, from the switch or from their graphics, draws the notes
	-- flat here too. A look from before the switch has neither, and glows as every one did)
	if Values.NoteGlowShown == false then
		Profile.NoteGlow.Value = false
	end

	Profile.FoV.Value = math.clamp(Profile.FoV.Value, 1, 120)
	Profile.RecordReplays.Value = false
	Profile.LocalOffset.Value = Own.LocalOffset.Value
	Profile.AlwaysPlayHitSound.Value = Own.AlwaysPlayHitSound.Value

	return Profile
end

-- The player's look for the Spectate tab, before anyone watches (the whole look goes with a snapshot): the background they
-- play on and their note colours, as "Name;rrggbb,rrggbb" (at most 8 colours).
const function LookOf(Attempt: Attempt): string
	const Settings: any = Attempt.Settings
	const Skin: any = SkinManager.Skin
	local Space: any = if Settings and Settings.GameSpace then Settings.GameSpace.Value else nil

	if Space == "skin" then
		Space = Skin.Config and Skin.Config.GameSpace
	end

	const Hexes = {}

	for Index, Value in Skin.NoteColors or {} do
		if Index > 8 then
			break
		end

		const function Byte(Part: number): number
			return math.clamp(math.round(Part * 255), 0, 255)
		end

		table.insert(Hexes, string.format("%02x%02x%02x", Byte(Value.R), Byte(Value.G), Byte(Value.B)))
	end

	return `{string.sub(if type(Space) == "string" then Space else "", 1, 40)};{table.concat(Hexes, ",")}`
end

-- Sending ---------------------------------------------------------------------------------------------------------------

-- Sends what has built up since the last batch.
const function Flush(Out: Sending)
	const FrameCount = #Out.Frames // 3
	const ResultCount = #Out.Results

	if FrameCount == 0 and ResultCount == 0 then
		return
	end

	const Data = buffer.create(5 + FrameCount * 12 + ResultCount * 8 + 5)

	buffer.writeu8(Data, 0, if Out.Session.Runner.Playing then 1 else 0)
	buffer.writeu16(Data, 1, FrameCount)
	buffer.writeu16(Data, 3, ResultCount)

	local Offset = 5

	for _, Value in Out.Frames do
		buffer.writef32(Data, Offset, Value)
		Offset += 4
	end

	for _, Index in Out.Results do
		buffer.writeu32(Data, Offset, Index)
		buffer.writef32(Data, Offset + 4, Out.Attempt.HitsInfo[Index + 1])
		Offset += 8
	end

	-- (then the fade-out and pushback the player has now: F and P change them mid-song, and the snapshot had only the first ones)
	buffer.writef32(Data, Offset, Out.Attempt.Settings.FadeOut.Value)
	buffer.writeu8(Data, Offset + 4, if Out.Attempt.Settings.Pushback.Value then 1 else 0)

	table.clear(Out.Frames)
	table.clear(Out.Results)
	Send("Frames", Data)
end

-- Sends the replay frames recorded since the last slice, at most ReplaySlice of them, as the bytes the replay file holds for
-- them (ReplayManager.Content: the song's time, x and y as f32). All sends every frame left, in as many slices as it takes.
const function SendReplayFrames(Out: Sending, All: boolean)
	const Frames = Out.Attempt.ReplayFrames
	const Count = #Frames

	repeat
		const From = Out.ReplaySent
		const Size = math.min(Count - From, ReplaySlice)

		if Size <= 0 then
			break
		end

		const Data = buffer.create(Size * 12)

		for Index = 1, Size do
			const Frame = Frames[From + Index]
			const Offset = (Index - 1) * 12

			buffer.writef32(Data, Offset, Frame[1])
			buffer.writef32(Data, Offset + 4, Frame[2])
			buffer.writef32(Data, Offset + 8, Frame[3])
		end

		Out.ReplaySent = From + Size
		Send("Replay", "Frames", Out.Token, From, Data)
	until not All
end

-- The run is over and its replay file written: the frames not sent yet, then the file's bytes before its frames and after
-- them. In the file the frames follow an 8-byte count; after them come the first note and the judged count (8 bytes each),
-- a byte a judged note, the skip count (8) and 4 bytes a skip, then the 32-byte digest. With what went up during the song
-- that is the whole file.
const function SendReplayTail(Out: Sending, Look: { [string]: unknown })
	const Attempt = Out.Attempt
	const File = FileSystem.ReadAllBytes(Attempt.ReplayPath)
	const Size = buffer.len(File)
	const FrameCount = #Attempt.ReplayFrames

	-- Where the frames sit is worked out from the file's end and checked against the file itself: the frame count just ahead
	-- of them and the skip count just ahead of the skips must be the ones expected. The skips are counted down from the
	-- attempt's list, which can have grown since the file was written (a skip pressed as the song stopped).
	local Skips = #Attempt.ReplaySkips
	local PrefixSize = -1
	local SuffixSize = 0

	while Skips >= 0 do
		SuffixSize = 56 + Attempt.Sum + Skips * 4

		const Start = Size - FrameCount * 12 - SuffixSize - 8
		const SkipsAt = Size - 40 - Skips * 4

		if Start >= 100 and Start <= 600 and SkipsAt > Start and buffer.readu32(File, Start) == FrameCount and buffer.readu32(File, SkipsAt) == Skips then
			PrefixSize = Start

			break
		end

		Skips -= 1
	end

	-- (a file that isn't laid out as this expects goes up whole instead, when the server asks for it)
	if PrefixSize < 0 then
		return
	end

	SendReplayFrames(Out, true)

	const Prefix = buffer.create(PrefixSize)
	const Suffix = buffer.create(SuffixSize)

	buffer.copy(Prefix, 0, File, 0, PrefixSize)
	buffer.copy(Suffix, 0, File, buffer.len(File) - SuffixSize, SuffixSize)
	Send("Replay", "Tail", Out.Token, Prefix, Suffix, Look)
end

const function StopSending(Out: Sending)
	Outgoing = nil
	Signal.Disconnect(Out.Session.Runner.HitResultChanged, Out.Listener)

	if Out.TouchWatch then
		Out.TouchWatch:Disconnect()
		Out.TouchWatch = nil
	end

	Flush(Out)

	const Attempt = Out.Attempt

	-- (a restart isn't the song's end for anyone watching: they're kept for the new run, Game.Restart)
	if (Attempt :: any).Restarting then
		Send("End", { Status = "RESTART" }, Out.Token)

		return
	end

	const NoteCount = #MapModule.GetNotes(Attempt.Map)

	-- (a run through every note whose scene leaves before the runner has stopped it is stopped here, as it would have been a
	-- moment later: its replay is written, so it counts like any other)
	if not Attempt.Stopped and Attempt.Alive and Attempt.Qualifies and Attempt.StartFrom == 0 and Attempt.Sum == NoteCount then
		pcall(RunnerModule.Stop, Out.Session.Runner, false)
	end

	-- A run that could be listed: the rest of its replay goes up ahead of its final numbers (the lists take no run without
	-- one), and its file is kept in mind by its token in case the server asks for all of it.
	if Attempt.Alive and Attempt.Qualifies and Attempt.StartFrom == 0 and Attempt.Sum == NoteCount and FileSystem.Exists(Attempt.ReplayPath) then
		const Look = SharedOf(Attempt.Settings)

		OnlineBoard.KeepRun(Out.Token, Attempt.ReplayPath, Look)

		if Out.Streams then
			const Sent, Problem = pcall(SendReplayTail, Out, Look)

			if not Sent then
				warn(`[AIMIA] the replay's end wasn't sent: {Problem}`)
			end
		end
	end

	Send("End", {
		Status = if Attempt.Alive then (if Attempt.Qualifies then "PASSED" else "DISQUALIFIED") else "FAILED",
		Accuracy = Attempt.Accuracy,
		Score = Attempt.Score,
		Hits = Attempt.Hits,
		Misses = Attempt.Misses,
		Sum = Attempt.Sum,
		Progress = Attempt.Progress,
		DeathTime = Attempt.DeathTime,
		Touches = Out.Touches,
	}, Out.Token)
end

const function ProcessSending(Out: Sending)
	if Out.Attempt.Stopped then
		StopSending(Out)

		return
	end

	const Now = os.clock()

	-- The Spectate tab shows everyone's song time: the server is told again when the song stops, goes on or jumps (a skip),
	-- at most twice a second, and every 5 s in case a message was dropped (it writes nothing when nothing moved).
	if Now - Out.ClockAt >= 0.5 then
		const Playing = Out.Session.Runner.Playing
		const Progress = Out.Attempt.Progress
		const Expected = Out.ClockProgress + (if Out.ClockPlaying then (Now - Out.ClockAt) * 1000 * Out.Attempt.Speed else 0)

		if Playing ~= Out.ClockPlaying or math.abs(Progress - Expected) > 300 or Now - Out.ClockAt >= 5 then
			Out.ClockAt = Now
			Out.ClockProgress = Progress
			Out.ClockPlaying = Playing
			Send("Clock", Progress, Playing, workspace:GetServerTimeNow())
		end
	end

	-- The run's replay goes up as it is recorded: the frames since the last slice, every ReplayGap seconds. A run that can't be
	-- listed any more (failed, or paused: Game.TogglePaused) stops sending.
	if Out.Streams and Now - Out.ReplayAt >= ReplayGap then
		const Attempt = Out.Attempt

		if Attempt.Alive and Attempt.Qualifies then
			SendReplayFrames(Out, false)
			-- (more left than one slice holds, as after a long freeze: the rest follows a tenth of a second apart)
			Out.ReplayAt = if #Attempt.ReplayFrames > Out.ReplaySent then Now - ReplayGap + 0.1 else Now
		else
			Out.Streams = false
		end
	end

	if not Out.Watched then
		return
	end

	if Now - Out.LastFrame >= FrameGap then
		Out.LastFrame = if Now - Out.LastFrame < 2 * FrameGap then Out.LastFrame + FrameGap else Now

		const Cursor = Out.Attempt.CursorPosition

		table.insert(Out.Frames, Out.Attempt.Progress)
		table.insert(Out.Frames, Cursor.x)
		table.insert(Out.Frames, Cursor.y)
	end

	if Now - Out.LastBatch >= BatchGap then
		Out.LastBatch = Now
		Flush(Out)
	end
end

-- Someone is watching, or nobody is any more.
const function SetWatched(On: boolean)
	const Out = Outgoing

	if Out then
		Out.Watched = On

		if not On then
			table.clear(Out.Frames)
			table.clear(Out.Results)
		end
	end
end

-- Everything a new watcher needs to catch up to now: the song, the player's look, and the result of every note so far.
const function SendSnapshot()
	const Out = Outgoing

	if not Out then
		return
	end

	Flush(Out)

	const Attempt = Out.Attempt
	const Notes = MapModule.GetNotes(Attempt.Map)
	local Last = 0

	for Index, Note in Notes do
		if Note.LastResult ~= HitResult.None then
			Last = Index
		end
	end

	const Results = buffer.create(Last * 4)

	for Index = 1, Last do
		buffer.writef32(Results, (Index - 1) * 4, if Notes[Index].LastResult ~= HitResult.None then Attempt.HitsInfo[Index] else Pending)
	end

	const Shared = SharedOf(Attempt.Settings)

	Send("Snapshot", {
		MapID = FileSystem.GetFileName(Attempt.Map.FolderPath),
		Speed = Attempt.Speed,
		StartFrom = Attempt.StartFrom,
		Mods = ReplayManager.ModifierNames(Attempt :: any),
		Progress = Attempt.Progress,
		CursorX = Attempt.CursorPosition.x,
		CursorY = Attempt.CursorPosition.y,
		Playing = Out.Session.Runner.Playing,
		Settings = Shared,
	}, EncodingService:CompressBuffer(Results, Enum.CompressionAlgorithm.Zstd, 3))
end

-- Watching --------------------------------------------------------------------------------------------------------------

-- Where the view should be: behind the newest frame by the delay, and not running on when frames stop coming.
-- (2026-11-12: it runs on for the delay at most, so never past the newest frame. It used to run on for a whole second: with
-- a late batch the view went up to 0.9 s past everything it had been sent, the cursor standing still and notes flying
-- through the grid unjudged, then all of them judged at once with their sounds when the batch landed. Batches normally
-- come 0.1 s apart, so nothing changes while they keep coming.)
const function TargetOf(View: Viewing): number
	const Elapsed = if View.Playing then math.min(os.clock() - View.Arrival, WatchDelay) else 0

	return View.Newest + (Elapsed - WatchDelay) * 1000 * View.Speed
end

-- Starts the view of a player's song. Answers false when this game can't show that map.
const function Watch(Info: any, Compressed: buffer): boolean
	const MapID = Info.MapID

	-- (a second answer that crossed paths with leaving and coming back: the view that's up carries on)
	if Current then
		return true
	end

	if type(MapID) ~= "string" or string.find(MapID, "[/\\]") then
		return false
	end

	const Path = `{Constants.UserFolder}/maps/{MapID}`

	if not FileSystem.DirectoryExists(Path) then
		return false
	end

	const Map = MapParser.Decode(Path) :: MapTypes.Map
	const Count = #MapModule.GetNotes(Map)

	-- (the results come from another player's game: a buffer that would open to more than a result a note is refused unopened)
	if typeof(Compressed) ~= "buffer" then
		return false
	end

	const Sized, Size = pcall(EncodingService.GetDecompressedBufferSize, EncodingService, Compressed, Enum.CompressionAlgorithm.Zstd)

	if not Sized or type(Size) ~= "number" or Size > Count * 4 then
		return false
	end
	const Speed = math.clamp(Finite(Info.Speed, 1), 0.05, 10)
	const Progress = Finite(Info.Progress, 0)
	const Profile = ProfileOf(Info.Settings)

	-- (a listed replay's look still on would be saved below as the watcher's own)
	SkinManager.TakeOffNoteLook()

	const Recording = ReplayFile.Live(
		MapID,
		Count,
		Speed,
		Finite(Info.StartFrom, 0),
		if type(Info.Mods) == "string" then Info.Mods else "",
		Profile,
		Progress,
		vector.create(Finite(Info.CursorX, 0), Finite(Info.CursorY, 0), 0)
	)
	-- (everything the player's game sent, for Copy Settings)
	;(Recording :: any).Look = if type(Info.Settings) == "table" then Info.Settings else nil

	const Results = EncodingService:DecompressBuffer(Compressed, Enum.CompressionAlgorithm.Zstd)
	const Notes = Recording.Notes :: { number }

	for Index = 1, math.min(Count, buffer.len(Results) // 4) do
		const Lateness = buffer.readf32(Results, (Index - 1) * 4)

		if Lateness ~= Pending and math.isfinite(Lateness) then
			Notes[Index] = Lateness
		end
	end

	Current = {
		Session = nil,
		Recording = Recording,
		Speed = Speed,
		Newest = Progress,
		Arrival = os.clock(),
		Playing = Info.Playing == true,
		Held = false,
		Final = nil,
		FinalAt = 0,
		Finished = false,
		NextSongCheck = 0,
	}

	-- The player's note look, worn on the watcher's skin until StopWatching. A skin load meanwhile (a settings change while
	-- watching) puts the watcher's own look back and forgets the worn one, so leaving never brings back stale colors.
	SkinManager.WearNoteLook(Profile)

	SoundManager.SongStop()

	-- (an older start still on its way, as when the player restarts in their first moments, would swallow this one: it lands
	-- first, unwatched (Attach), and this one starts after it. A view that ended or was replaced meanwhile starts nothing)
	if Game.StartQueued then
		const View = Current

		task.spawn(function()
			const Asked = os.clock()

			while Game.StartQueued and Current == View and os.clock() - Asked < 8 do
				task.wait()
			end

			if Current ~= View then
				return
			end

			Game.StartQueued = false -- (an old start that never landed doesn't hold this one any longer)
			Game.Play(Map, Speed, Recording.StartFrom, Recording.CameraMode :: any, Recording.Modifiers :: any, { Recording })
		end)

		return true
	end

	Game.Play(Map, Speed, Recording.StartFrom, Recording.CameraMode :: any, Recording.Modifiers :: any, { Recording })

	return true
end

-- A batch from the player.
const function Receive(Data: unknown)
	const View = Current

	if not View or type(Data) ~= "buffer" then
		return
	end

	const Recording = View.Recording
	const Frames = Recording.Frames :: { ReplayFile.Frame }
	const Notes = Recording.Notes :: { number }

	-- (the batch's first byte is whether the player's song is running: when it stops, the watcher is told they paused)
	pcall(function()
		const Running = buffer.readu8(Data, 0) == 1

		if Running then
			View.PausedAt = nil
		elseif View.PausedAt == nil then
			View.PausedAt = os.clock()
		end
	end)

	pcall(function()
		const FrameCount = buffer.readu16(Data, 1)
		const ResultCount = buffer.readu16(Data, 3)
		local Offset = 5

		for _ = 1, FrameCount do
			const Progress = buffer.readf32(Data, Offset)
			const X = buffer.readf32(Data, Offset + 4)
			const Y = buffer.readf32(Data, Offset + 8)

			Offset += 12

			if math.isfinite(Progress) and math.isfinite(X) and math.isfinite(Y) and Progress >= View.Newest then
				table.insert(Frames, { Progress = Progress, CursorPosition = vector.create(X, Y, 0) })
				View.Newest = Progress
			end
		end

		for _ = 1, ResultCount do
			const Index = buffer.readu32(Data, Offset)
			const Lateness = buffer.readf32(Data, Offset + 4)

			Offset += 8

			if Notes[Index + 1] ~= nil and math.isfinite(Lateness) then
				Notes[Index + 1] = Lateness
			end
		end

		-- (then the player's fade-out and pushback now, which F and P change mid-song: into the view's own profile, straight to
		-- .Value as ProfileOf writes it. A batch that ends before them keeps the snapshot's)
		if buffer.len(Data) >= Offset + 5 then
			const Settings = Recording.Settings :: SettingsProfile.SettingsProfile
			const Fade = buffer.readf32(Data, Offset)

			if math.isfinite(Fade) then
				Settings.FadeOut.Value = math.clamp(Fade, 0, 100)
			end

			Settings.Pushback.Value = buffer.readu8(Data, Offset + 4) == 1
		end

		View.Playing = buffer.readu8(Data, 0) == 1
		View.Arrival = os.clock()
	end)
end

-- The player's song is over: the view shows the results once it gets there. Nothing on screen yet means nothing to show.
const function TargetEnded(Given: unknown)
	const View = Current

	const Away = type(Given) == "table" and (Given :: any).Status == "AWAY"

	if not View or not View.Session or type(Given) ~= "table" or Away then
		const Ended = Hooks.Ended

		if Ended then
			Ended(if Away then "away" else nil)
		end

		return
	end

	const Info = Given :: any

	View.FinalAt = os.clock() + WatchDelay
	View.Final = {
		Status = if type(Info.Status) == "string" and Statuses[Info.Status] then Info.Status else "FAILED",
		Accuracy = Finite(Info.Accuracy, 0),
		Score = Finite(Info.Score, 0),
		Hits = Finite(Info.Hits, 0),
		Misses = Finite(Info.Misses, 0),
		Sum = Finite(Info.Sum, 0),
		Progress = Finite(Info.Progress, View.Newest),
		DeathTime = Finite(Info.DeathTime, -1),
	}
end

-- Stops the view on the player's final numbers and shows the results.
const function ShowResults(View: Viewing, Final: Final)
	const Session = View.Session :: Session
	const Runner = Session.Runner
	const Attempt = Runner.Attempt :: Attempt
	const Notes = View.Recording.Notes :: { number }

	View.Finished = true
	View.Session = nil

	for Index, Lateness in Notes do
		if Lateness == math.huge then
			Notes[Index] = -1
		end
	end

	RunnerModule.Stop(Runner, false)

	Attempt.Accuracy = Final.Accuracy
	Attempt.Score = Final.Score
	Attempt.Hits = Final.Hits
	Attempt.Misses = Final.Misses
	Attempt.Sum = Final.Sum
	Attempt.Progress = Final.Progress
	Attempt.MaxReplayLength = if Final.DeathTime >= 0 then Final.DeathTime else Final.Progress
	View.Recording.Status = Final.Status

	Runner.Host.Scenes.LoadResults()

	const Finished = Hooks.Finished

	if Finished then
		Finished(Final.Status)
	end
end

const function ProcessViewing(View: Viewing, Delta: number)
	const Session = View.Session

	if not Session or View.Finished then
		return
	end

	const Final = View.Final

	if Final and os.clock() >= View.FinalAt then
		ShowResults(View, Final)

		return
	end

	const Runner = Session.Runner
	const Attempt = Runner.Attempt :: Attempt
	const Target = TargetOf(View)

	-- (2026-11-12: a note whose result never came. Results are sent once, in the batch after the note is judged, and batches
	-- arrive in order, so once the player's frames are a second past a note its result isn't on its way any more (a batch
	-- the server dropped). The runner can't pass a note with no result, so it walked, and kept a part for, every note
	-- after it, slower each second until the song ended. It is counted as a hit, as a seek counts one; the player's own
	-- numbers still replace the view's at the end.)
	do
		const Head = Runner.ObjectIndicesStart[ObjectType.Note]
		const Waiting: any = (Attempt.Objects[ObjectType.Note] :: any)[Head + 1]
		const Results = View.Recording.Notes :: { number }

		if Waiting and Results[Head + 1] == math.huge and View.Newest - Waiting.Millisecond > (Waiting.HitWindow + 1000) * View.Speed then
			Results[Head + 1] = 0
		end
	end

	-- The player paused, or their frames stopped coming: the view waits where it is.
	if View.Held then
		if Target > Attempt.Progress then
			View.Held = false
			Runner.Pause(true)
		end

		return
	end

	-- (2026-11-12: the gap is measured from where the runner is about to put the timeline this frame. It was measured before
	-- the runner's own advance and closed here as well, so a long frame on this game, as when the view first comes up, was
	-- counted twice: the view landed up to that frame's length ahead of the player, then stood still or had its song moved
	-- back until the player caught up.)
	const Coming = if Runner.Playing and not (Runner :: any).FirstFrame then Delta * 1000 * View.Speed else 0
	const Behind = Target - (Attempt.Progress + Coming)

	if Behind < -200 * View.Speed then
		View.Held = true
		Runner.Pause(false)
	elseif Behind > 2000 * View.Speed then
		-- the player skipped a break, or this game stalled
		-- (not past notes whose results can't have come yet: a seek counts a note with no result as hit)
		ReplayManager.SeekTo(Session.Replay, math.min(Target, View.Newest - 100 * View.Speed) - Coming)
		-- (the runner has just aimed the song: the check below waits a second, for a fresh position to judge)
		View.NextSongCheck = os.clock() + 1
	else
		-- (the gap closes at 2.5 times its size a second, as before, but while it is under 50 ms at most 3% faster or slower
		-- than the song: batches arrive unevenly, and the old pull showed every late one as the notes speeding up and slowing
		-- down. Past 50 ms the limit grows with the gap, so a real one still closes about as fast as before.)
		const Gap = Behind / (1000 * View.Speed)
		const Limit = 0.03 + math.max(0, math.abs(Gap) - 0.05) * 2.5
		const Step = math.clamp(Gap * 2.5, -Limit, Limit) * Delta * 1000 * View.Speed

		Attempt.Progress += math.clamp(Step, -math.abs(Behind), math.abs(Behind))
	end

	-- The runner bends the song's pitch to follow small drifts; a big one (a song that started mid-way) needs a jump.
	const Now = os.clock()

	if Now >= View.NextSongCheck and Attempt.Progress > 0 then
		View.NextSongCheck = Now + 1

		const Expected = (Attempt.Progress - Attempt.Settings.LocalOffset.Value) / 1000

		if Expected < SoundManager.Song.Length and math.abs(SoundManager.SongPosition() - Expected) > SongDrift * View.Speed then
			SoundManager.SongSeek(Expected)
		end
	end
end

-- Leaving: the watcher's own note look comes back (nothing to take off when a skin load already brought it back).
const function StopWatching()
	if Current then
		Current = nil
		SkinManager.TakeOffNoteLook()
	end
end

-- The color behind the song on screen, for anything drawn over it to match (as the game scene picks it).
const function BackdropColor(): Color3
	const Attempt = Game.Attempt

	if not Attempt then
		return Color3.new(0, 0, 0)
	end

	const Settings = Attempt.Settings
	const Fog = SpaceColor.Of(Settings.SpaceColor.Value)
	const SpaceName = if Settings.GameSpace.Value == "skin" then SkinManager.Skin.Config.GameSpace else Settings.GameSpace.Value

	-- (a map skin's own colour, under its pictures)
	const Set = SkinSets.Get(SpaceName)

	if Set then
		return Tone.Color(Set.Background.R, Set.Background.G, Set.Background.B)
	end

	if Fog or SpaceName == "grid" then
		return GridSpace.BackdropOf(Fog)
	end

	return Tone.Color(0.0885599, 0.08855992, 0.08855987)
end

-- The scene --------------------------------------------------------------------------------------------------------------

-- A run's scene is up: a song starts sending, and a live view catches up with the player.
const function Attach(Session: Session)
	const Attempt = Session.Runner.Attempt :: Attempt
	const View = Current

	if Attempt.IsLive then
		-- (only the run started for this view: one left from before a restart, landing late, is someone's old run)
		const Replays = (Attempt :: any).Replays

		if View and Replays and Replays[1] == View.Recording then
			View.Session = Session

			-- (not past notes whose results can't have come yet: a seek counts a note with no result as hit)
			const Target = math.min(TargetOf(View), View.Newest - 100 * View.Speed)

			if Target > 0 then
				ReplayManager.SeekTo(Session.Replay, Target)
				-- (the runner has just aimed the song a little ahead, where the notes will be once it sounds. The view's own
				-- song check, due on its first frame, could read the position from before the seek and move the song back
				-- to where the notes are now: it waits a second)
				View.NextSongCheck = os.clock() + 1
			elseif Target > Attempt.Progress then
				Attempt.Progress = Target
			end

			const Started = Hooks.Started

			if Started then
				Started()
			end
		end
	elseif not Attempt.IsReplay then
		local Out: Sending

		const function Listener(NoteIndex: number, Result: number)
			if Out.Watched and Result ~= HitResult.None then
				table.insert(Out.Results, NoteIndex)
			end
		end

		-- (its replay goes up as it plays when the run could be listed: recorded, from the song's start, and with no modifier
		-- the lists refuse)
		local Streams = Attempt.StartFrom == 0 and Attempt.Qualifies and Session.Replay.CurrentMode == ReplayManager.Mode.RECORD

		for _, Mod in Attempt.Modifiers do
			if Unlisted[Mod.Name] then
				Streams = false
			end
		end

		Out = {
			Session = Session,
			Attempt = Attempt,
			Frames = {},
			Results = {},
			LastFrame = 0,
			LastBatch = 0,
			Watched = false,
			Listener = Listener,
			ClockAt = os.clock(),
			ClockProgress = Attempt.Progress,
			ClockPlaying = Session.Runner.Playing,
			Token = (string.gsub(HttpService:GenerateGUID(false), "%W", "")),
			Streams = Streams,
			ReplaySent = 0,
			ReplayAt = os.clock(),
			Touches = 0,
			TouchWatch = nil,
		}
		Outgoing = Out

		-- Any touch on the screen during the song goes up with its end, whatever device this is (a touch screen with a keyboard
		-- plays too). The song lists then hold the run to a hand's moves: a pen, which Roblox can count as touch, or a finger
		-- dragged moves the cursor like a mouse and still counts; taps that put the cursor on each note don't (the server's
		-- Rules.cursorProblem).
		Out.TouchWatch = UserInputService.InputBegan:Connect(function(Input: InputObject)
			if Input.UserInputType == Enum.UserInputType.Touch then
				Out.Touches += 1
			end
		end)

		Signal.Connect(Session.Runner.HitResultChanged, Listener)
		-- (speed and start go with it: the song lists read them from here, not at the end, when the modifiers may be cleared)
		-- (with the song's time now and when it was read, for the Spectate tab's clock, and the player's look for its list)
		Send(
			"Song",
			FileSystem.GetFileName(Attempt.Map.FolderPath),
			ReplayManager.ModifierNames(Attempt :: any),
			Attempt.Speed,
			Attempt.StartFrom,
			Attempt.Progress,
			workspace:GetServerTimeNow(),
			LookOf(Attempt),
			Out.Token
		)
	end
end

-- The run's scene is leaving.
const function Detach()
	const Out = Outgoing

	if Out then
		StopSending(Out)
	end

	if Current then
		Current.Session = nil
	end
end

-- Every frame of a run, before the runner.
const function Process(Delta: number)
	const Out = Outgoing
	const View = Current

	if Out then
		ProcessSending(Out)
	end

	if View then
		ProcessViewing(View, Delta)
	end
end

-- The player left their song for the settings (from the pause menu): whoever watches is let go, and the song can't be
-- watched again until the next one. (The run is paused, so it no longer counts for the song lists anyway.)
const function PlayerAway()
	const Out = Outgoing

	if not Out then
		return
	end

	Outgoing = nil
	Signal.Disconnect(Out.Session.Runner.HitResultChanged, Out.Listener)

	if Out.TouchWatch then
		Out.TouchWatch:Disconnect()
		Out.TouchWatch = nil
	end

	Send("End", { Status = "AWAY" }, Out.Token)
end

-- The player is restarting: the view of their old run goes (the watcher's skin as it was), and the next snapshot starts the new.
const function Restarting()
	StopWatching()
	-- (the old run's song used to play on under "is restarting" until the new view came)
	SoundManager.SongStop()
end

-- How the watched song is doing: whether the player has it paused, and for how long.
const function PausedFor(): number
	const View = Current

	if not View or not View.PausedAt or View.Finished then
		return 0
	end

	return os.clock() - View.PausedAt
end

-- Copy Settings: saves another player's settings (as they came with a spectated song or a listed run's replay) as a new
-- profile named after them, "name's profile" (then "name's profile 2" and so on). Nothing of the watcher's own changes: not
-- their profiles, not the one in use; they switch to the new one in Settings. A setting the player's game didn't send (a run
-- listed before everything went up with it) keeps the watcher's own value. Answers the new profile's name, or nil and why not.
const function CopyToProfile(Given: unknown, PlayerName: string): (string?, string?)
	if type(Given) ~= "table" then
		return nil, "Their settings didn't come with this one."
	end

	const Folder = `{Constants.UserFolder}/profiles`

	if #FileSystem.GetFiles(Folder) >= SettingsManager.MaxProfiles then
		return nil, `You can have {SettingsManager.MaxProfiles - 1} profiles. Delete one in Settings first.`
	end

	const Base = `{PlayerName}'s profile`
	local Name = Base
	local Number = 1

	while FileSystem.Exists(`{Folder}/{Name}.json`) do
		Number += 1
		Name = `{Base} {Number}`
	end

	if SettingsManager.ProfileProblem(Name) then
		return nil, "That name can't be a profile."
	end

	const Own = SettingsManager.Settings :: SettingsProfile.SettingsProfile
	const Profile = SettingsProfile.New()
	const Values: { [string]: unknown } = Given :: any

	for _, SettingName in SettingsProfile.Order do
		const Item: any = SettingsProfile.ItemNamed(Profile, SettingName)
		const Mine: any = SettingsProfile.ItemNamed(Own, SettingName)

		if not Item or Item.Value == nil then
			continue
		end

		if Mine and type(Mine.Value) == type(Item.Value) then
			Item.Value = Mine.Value
		end

		if NotCopied[SettingName] then
			continue
		end

		local Wanted: any = Values[SettingName]

		if type(Wanted) ~= type(Item.Value) then
			continue
		end

		if type(Wanted) == "number" then
			if not math.isfinite(Wanted) then
				continue
			end

			if Item.Slider then
				Wanted = math.clamp(Wanted, Item.Slider.Floor, Item.Slider.Ceiling)
			end
		elseif type(Wanted) == "string" and (#Wanted > 64 or string.find(Wanted, "[/\\]") or string.find(Wanted, "..", 1, true)) then
			continue
		end

		Item.Value = Wanted
	end

	if Profile.ApproachRate.Value > 0 then
		Profile.ApproachTime.Value = Profile.ApproachDistance.Value / Profile.ApproachRate.Value
	end

	Profile.FoV.Value = math.clamp(Profile.FoV.Value, 1, 120)
	-- (the one-time grid marks switch has run for this profile already: their Grid Guides stay as they had them)
	Profile.GridGuidesOff.Value = true

	FileSystem.WriteAllText(`{Folder}/{Name}.json`, SettingsProfileConverter.Serialize(Profile))

	return Name, nil
end

return {
	Hooks = Hooks,
	Attach = Attach,
	Detach = Detach,
	Process = Process,
	SetWatched = SetWatched,
	SendSnapshot = SendSnapshot,
	Watch = Watch,
	Receive = Receive,
	TargetEnded = TargetEnded,
	StopWatching = StopWatching,
	BackdropColor = BackdropColor,
	SharedOf = SharedOf,
	ProfileOf = ProfileOf,
	CopyToProfile = CopyToProfile,
	PlayerAway = PlayerAway,
	Restarting = Restarting,
	PausedFor = PausedFor,
}
