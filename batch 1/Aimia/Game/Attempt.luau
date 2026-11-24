--!strict
--!optimize 2

--[[
	Attempt.cs: one play of a map, or of a replay of one: the map, speed and start point, the camera mode and modifiers, the
	timeline objects the runner walks, and the score, health, cursor and replay state that the game and results scene read.
	New is the C# constructor; the Attempt type holds every field of the class.

	Representation
		Replays is an empty array for a play that is not a replay: IsReplay carries C# `Replays != null`. A replay's HitsInfo is
		the replay's own Notes table, as the C# array is shared, not copied.
		Objects is keyed by ObjectType: ObjectType.Note holds a copy of the map's note array (the notes themselves are shared).
		Cursor and camera positions are vectors; the 2D ones have Z = 0.
		ReplayPath is "" where the C# field is null: FileSystem.Exists("") is false, as FileAccess.FileExists(null) is.

	Design Notes
		The song length is SoundManager.Song.Length (0 without a stream, as the C# `?? 0`), except that a map whose song lives on
		Roblox (an AIMIASTUB audio naming its length) uses its own: a start that didn't come through the song list (spectating,
		a listed run's replay, a song right after another) found the last song still loaded, and ran to its length (the owner saw
		"0:42 / 5:35" on a 3:19 song, 2026-11-07). The device id and the clock are Hooks:
		OS.GetUniqueId and the system time belong to the host. Notes come from MapModule.GetNotes, the C# Notes getter.
		Replays are valid replay files (Replay.Valid), so their Status and Notes are set; the type says so with casts at New and
		at the readers that index them.
		Upstream quirks kept: FirstNote is the index of the first note at or after StartFrom, or of the last note when none is,
		and keeps its value when the map has no notes. LastHitColour takes C#'s truncated `%` index, a negative one counting from
		the end of the colour list.
]]

const CameraMode = require("./Camera/CameraMode")
const Color = require("../Godot/Color")
const Dotnet = require("../Dotnet/String")
const MapModule = require("../Map/Map")
const MapTypes = require("../Map/MapTypes")
const Modifier = require("./Modifiers/Modifier")
const Note = require("../Map/Objects/Note")
const ObjectType = require("../Map/Objects/ObjectType")
const ReplayTypes = require("../Map/ReplayTypes")
const SettingsManager = require("../SettingsManager")
const SettingsProfile = require("../Database/Settings/SettingsProfile")
const SkinManager = require("../Skinning/SkinManager")
const SoundManager = require("../Audio/SoundManager")
const LoadStream = require("../Audio/Audio")

export type AttemptHooks = {
	UniqueId: (() -> string)?,
	UnixTime: (() -> number)?,
}

export type Attempt = {
	TimeStarted: number,
	DeathTime: number,
	ID: string,
	Map: MapTypes.Map,
	CameraMode: CameraMode.CameraMode,
	Modifiers: { Modifier.Modifier },
	Objects: { [ObjectType.ObjectType]: { Note.TimelineObject } },
	Settings: SettingsProfile.SettingsProfile,
	UseFadeOut: boolean,
	IsReplay: boolean,
	IsLive: boolean,
	Stopped: boolean,
	Paused: boolean,
	Alive: boolean,
	CanSkip: boolean,
	Qualifies: boolean,
	Players: { string },
	Progress: number,
	Speed: number,
	StartFrom: number,
	Length: number,
	Accuracy: number,
	Health: number,
	HealthStep: number,
	HasHealthModifier: boolean,
	Hits: number,
	Misses: number,
	Sum: number,
	Score: number,
	Combo: number,
	ComboMultiplier: number,
	ComboMultiplierProgress: number,
	ComboMultiplierIncrement: number,
	ModsMultiplier: number,
	HitsInfo: { number },
	LastHitColour: Color.Color,
	CameraPosition: vector,
	CameraRotation: vector,
	CameraBasisZ: vector,
	CursorPosition: vector,
	RawCursorPosition: vector,
	DistanceMM: number,
	FirstNote: number,
	ReplayPath: string,
	Replays: { ReplayTypes.Replay },
	ReplayFrames: { { number } },
	ReplaySkips: { number },
	MaxReplayLength: number,
	LastReplayFrame: number,
	ReplayFrameCountOffset: number,
	ReplayAttemptStatusOffset: number,
}

-- Hooks the host sets: UniqueId is OS.GetUniqueId; UnixTime is the system time in seconds.
const Hooks: AttemptHooks = {}

-- The attempts created so far: the device id of an attempt the host does not identify (Hooks.UniqueId unset).
local CreatedCount = 0

const CameraPositionStart = vector.create(0, 0, 3.75)

-- A copy of a profile's values in a fresh profile (written straight to .Value, so no update action runs and nothing saves),
-- never recording.
const function CopyOf(Profile: SettingsProfile.SettingsProfile): SettingsProfile.SettingsProfile
	const Copy = SettingsProfile.New()

	for _, Name in SettingsProfile.Order do
		const From: any = SettingsProfile.ItemNamed(Profile, Name)
		const To: any = SettingsProfile.ItemNamed(Copy, Name)
		const Kind = if From then type(From.Value) else nil

		if To and (Kind == "number" or Kind == "string" or Kind == "boolean") and type(To.Value) == Kind then
			To.Value = From.Value
		end
	end

	Copy.RecordReplays.Value = false

	return Copy
end

-- @src scripts/game/Attempt.cs:Attempt L66-123
const function New(
	Map: MapTypes.Map,
	Speed: number,
	StartFrom: number,
	Mode: CameraMode.CameraMode,
	Mods: { Modifier.Modifier },
	Players: { string }?,
	Replays: { ReplayTypes.Replay }?
): Attempt
	-- DEVIATION(platform): OS.GetUniqueId is the host's device id. Without Hooks.UniqueId the id is this session's attempt count.
	-- DEVIATION(platform): the date is Hooks.UnixTime (os.time without it), formatted in UTC as Godot's datetime string is.
	CreatedCount += 1

	const DeviceId = if Hooks.UniqueId then Hooks.UniqueId() else tostring(CreatedCount)
	const Unix = if Hooks.UnixTime then Hooks.UnixTime() else os.time()
	const Stamp = os.date("!%Y-%m-%dT%H:%M:%S", Unix // 1)
	const Id = Dotnet.Replace(`{Map.Name}_{DeviceId}_{Stamp}`, ":", "_")

	const IsReplay = Replays ~= nil
	const ReplayList: { ReplayTypes.Replay } = Replays or {}
	-- Watching someone's song live, or a listed run's replay that came with its player's look, shows their settings from a
	-- copy: the watcher's own are never read or changed.
	const IsLive = IsReplay and ReplayList[1].Live == true
	const ShowsPlayer = IsReplay and (IsLive or ReplayList[1].ShowsPlayer == true)
	-- A replay of your own shows your settings from a copy too, so F and P change what it shows, never your saved settings.
	const Settings = (
		if ShowsPlayer
			then ReplayList[1].Settings
			elseif IsReplay then CopyOf(SettingsManager.Settings :: SettingsProfile.SettingsProfile)
			else SettingsManager.Settings
	) :: SettingsProfile.SettingsProfile

	-- A listed replay that came with its player's look wears their note look on the skin (only for a start that was accepted:
	-- this runs for an accepted Game.Play or a restart); anything else takes a worn look off.
	if ShowsPlayer and not IsLive then
		SkinManager.WearNoteLook(ReplayList[1].Settings :: SettingsProfile.SettingsProfile)
	elseif not ShowsPlayer then
		SkinManager.TakeOffNoteLook()
	end

	-- (the map's own song length when its audio is a stub: reading one is a few bytes; an embedded song keeps the loaded one's)
	const Audio = Map.AudioBuffer
	const OwnLength = if Audio and buffer.len(Audio) < 64 then LoadStream(Audio).Length else 0
	const Length = math.max(1000 * (if OwnLength > 0 then OwnLength else SoundManager.Song.Length), Map.Length + 1000)
	const Notes = MapModule.GetNotes(Map)
	const Progress = Speed * -1000 - Settings.ApproachTime.Value * 1000 + StartFrom

	const ComboMultiplierIncrement = math.max(2, #Notes // 200)
	local HasHealthModifier = false

	for _, Mod in Mods do
		if Mod.ApplyHealthResult ~= nil then
			HasHealthModifier = true
		end
	end

	local MaxReplayLength = 0

	if IsReplay then
		for _, Recording in ReplayList do
			if Recording.Length > MaxReplayLength then
				MaxReplayLength = Recording.Length
			end
		end
	end

	-- The first note at or after StartFrom (the last note when none is): the loop leaves FirstNote on the note it stops at.
	local Qualifies = true
	local FirstNote = 0

	if StartFrom > 0 then
		Qualifies = false

		for _, Item in Notes do
			FirstNote = Item.Index

			if Item.Millisecond >= StartFrom then
				break
			end
		end
	end

	-- (a replay with fewer note results than the map has notes counts the rest as misses, so every note has one)
	if IsReplay and type(ReplayList[1].Notes) == "table" then
		const Recorded = ReplayList[1].Notes :: { number }

		for Index = #Recorded + 1, #Notes do
			Recorded[Index] = -1
		end
	end

	const HitsInfo: { number } = if IsReplay
		then ReplayList[1].Notes :: { number }
		else table.create(#Notes, 0)

	-- The colour index is C#'s `(int)(FirstNote - 1) % Length`, truncated; a negative index counts from the end.
	const NoteColors = SkinManager.Skin.NoteColors
	const ColourRemainder = math.fmod(FirstNote - 1, #NoteColors)
	const ColourSlot = if ColourRemainder >= 0 then ColourRemainder else #NoteColors + ColourRemainder
	const LastHitColour = table.clone(NoteColors[ColourSlot + 1])

	const Objects = {
		[ObjectType.Note] = table.clone(Notes) :: { Note.TimelineObject },
	}

	return {
		TimeStarted = 0,
		DeathTime = -1,
		ID = Id,
		Map = Map,
		CameraMode = Mode,
		Modifiers = Mods,
		Objects = Objects,
		Settings = Settings,
		UseFadeOut = true,
		IsReplay = IsReplay,
		IsLive = IsLive,
		Stopped = false,
		Paused = false,
		Alive = true,
		CanSkip = false,
		Qualifies = Qualifies,
		Players = Players or {},
		Progress = Progress,
		Speed = Speed,
		StartFrom = StartFrom,
		Length = Length,
		Accuracy = 100,
		Health = 100,
		HealthStep = 15,
		HasHealthModifier = HasHealthModifier,
		Hits = 0,
		Misses = 0,
		Sum = 0,
		Score = 0,
		Combo = 0,
		ComboMultiplier = 1,
		ComboMultiplierProgress = 0,
		ComboMultiplierIncrement = ComboMultiplierIncrement,
		ModsMultiplier = 1,
		HitsInfo = HitsInfo,
		LastHitColour = LastHitColour,
		CameraPosition = CameraPositionStart,
		CameraRotation = vector.zero,
		CameraBasisZ = vector.zero,
		CursorPosition = vector.zero,
		RawCursorPosition = vector.zero,
		DistanceMM = 0,
		FirstNote = FirstNote,
		ReplayPath = "",
		Replays = ReplayList,
		ReplayFrames = {},
		ReplaySkips = {},
		MaxReplayLength = MaxReplayLength,
		LastReplayFrame = 0,
		ReplayFrameCountOffset = 0,
		ReplayAttemptStatusOffset = 0,
	}
end

return {
	New = New,
	Hooks = Hooks,
}
