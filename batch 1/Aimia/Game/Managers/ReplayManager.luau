--!strict
--!optimize 2

--[[
	ReplayManager.cs: writes an attempt's replay file (user/replays/<ID>.phxr, the layout Map/Replay reads) while the attempt
	is recorded, and plays replays back: each replay's cursor at the attempt's progress, the seek and the pause. The replay
	viewer, the orthogonal camera, the seeker slider and the pause icon are the View callbacks.

	Representation
		Mode is a number (NONE 0, RECORD 1, PLAYBACK 2, the source's enum). A manager is a table from New; View is shared by
		every manager, and each callback in it is optional (nil does nothing).
		Attempt.ReplayFrames entries are { Progress, X, Y } (the source's float[3], 1-based here). Attempt.HitsInfo and
		Replay.Notes are read at Index + 1 for the note Index. A replay's FrameIndex stays the source's 0-based index.
		Recording is the file being written: its path, the bytes before the status byte and the bytes between the status byte
		and the frame count. The source writes the status and the frame count at fixed offsets, so SaveReplay rebuilds the
		file from these parts and the attempt, then appends the digest.

	Design Notes
		DEVIATION(platform): the source also skips recording when Aimia.TempMode is set, which only a command-line flag does;
		this port never sets it (Aimia.luau), so the check is left out.
		Upstream quirk kept: a name's length prefix is its UTF-16 length while its bytes are UTF-8, so a non-ASCII map folder
		name is stored with the wrong length and Map/Replay reads it back short.
		Upstream quirk kept: when NewReplay skips (RecordReplays off) the recording still open is the one SaveReplay writes,
		with the attempt's data; it then hashes the file named by the attempt's ID, which fails when that file is missing.
		Upstream quirk kept: a cursor at a frame's exact progress is NaN: the interpolation divides 0 by 0 on the last frame.
		The hit byte casts a float to a byte: a negative value wraps modulo 256 ((byte)(-2f) is 254), NaN is 0.
		DEVIATION(phase3): the node wiring of _Ready (the node lookups, the seeker's signals, the label through TimeText, and
		CursorManager) is the view's. The seeker's hover state is Manager.SeekerHovered, which the view sets on focus.
]]

const Constants = require("../../Constants")
const FileSystem = require("../../Util/FileSystem")
const HitResult = require("../Judgments/HitResult")
const Note = require("../../Map/Objects/Note")
const MapModule = require("../../Map/Map")
const MapTypes = require("../../Map/MapTypes")
const Numbers = require("../../Numbers")
const Replay = require("../../Map/Replay")
const Sha256 = require("../../Util/Sha256")
const Signal = require("../../Util/Signal")
const UtilString = require("../../Util/String")
const CameraMode = require("../Camera/CameraMode")
const Modifier = require("../Modifiers/Modifier")
const SettingsProfile = require("../../Database/Settings/SettingsProfile")

export type Attempt = {
	ID: string,
	Speed: number,
	StartFrom: number,
	Progress: number,
	MaxReplayLength: number,
	IsReplay: boolean,
	Alive: boolean,
	Qualifies: boolean,
	Settings: SettingsProfile.SettingsProfile,
	Modifiers: { Modifier.Modifier },
	CameraMode: CameraMode.CameraMode,
	Map: MapTypes.Map,
	Replays: { Replay.Replay },
	FirstNote: number,
	Sum: number,
	HitsInfo: { number },
	ReplayFrames: { { number } },
	ReplaySkips: { number },
	ReplayPath: string,
	Hits: number,
	Misses: number,
	Accuracy: number,
	Score: number,
	Combo: number,
	ComboMultiplier: number,
	ComboMultiplierProgress: number,
	Health: number,
	HealthStep: number,
}

export type Runner = {
	Attempt: Attempt,
	Playing: boolean,
	Speed: number,
	Pause: (boolean?) -> (),
	Seek: (number) -> (),
	AttemptStatsUpdated: Signal.Signal<Attempt>,
	HitResultChanged: Signal.Signal<number, number>,
}

-- The cursors of the replays by their 0-based index (the source's cursor index).
export type CursorManager = {
	UpdateCursor: (vector, number) -> (),
	ShowCursor: (number, boolean) -> (),
	HideCursor: (number, boolean) -> (),
}

export type Mode = number

export type Recording = {
	Path: string,
	Head: buffer,
	Middle: buffer,
}

export type Manager = {
	Runner: Runner,
	CursorManager: CursorManager,
	CurrentMode: Mode,
	ViewerVisible: boolean,
	CanShow: boolean,
	ReplayLength: number,
	ReplayPath: string?,
	CursorPosition: vector,
	SeekerHovered: boolean,
	Recording: Recording?,
}

-- DEVIATION(phase3): ShowReplayViewer(Visible) sets Visible on the five viewer controls (SeekerPause, the time label, the
-- seeker, the tip and the background), as ShowReplayViewer does with `visible = ViewerVisible && attempt.IsReplay`.
-- DEVIATION(phase3): SetMouseVisible(Visible) sets Input.MouseMode to Visible or Hidden; called only for replays.
-- DEVIATION(phase3): ShowOrthogonalCamera(Visible) sets the orthogonal panel Visible (CanShow && IsReplay).
-- DEVIATION(phase3): SetPauseIcon(Playing) sets the pause button texture to pause.png when Playing, else play.png.
-- DEVIATION(phase3): SetSeekerValue(Ratio) sets the seeker to Progress / MaxReplayLength; the view formats its label with
-- TimeText, as the source's ValueChanged handler does.
export type ViewCallbacks = {
	ShowReplayViewer: ((boolean) -> ())?,
	SetMouseVisible: ((boolean) -> ())?,
	ShowOrthogonalCamera: ((boolean) -> ())?,
	SetPauseIcon: ((boolean) -> ())?,
	SetSeekerValue: ((number) -> ())?,
}

const Signature = "phxr"
const FileVersion = 1
const MissNote = -1
const TwoPow32 = 4294967296
const PlayerName = "You"
const StatusPassed = 0
const StatusDisqualified = 1
const StatusFailed = 2

-- @src scripts/game/managers/ReplayManager.cs:Mode L9-14
const Mode = {
	NONE = 0,
	RECORD = 1,
	PLAYBACK = 2,
}

-- The view's side effects. The replay viewer sets them; nil does nothing. Each one stands for a node change the source makes.
const View: ViewCallbacks = {}

-- The concatenation of byte parts, in order.
const function Concat(Parts: { buffer }): buffer
	local Size = 0

	for _, Part in Parts do
		Size += buffer.len(Part)
	end

	const Bytes = buffer.create(Size)
	local Offset = 0

	for _, Part in Parts do
		buffer.copy(Bytes, Offset, Part)
		Offset += buffer.len(Part)
	end

	return Bytes
end

-- The little-endian bytes of the writes the source makes (Store8, Store32, Store64, StoreFloat, StoreDouble).
const function Uint8Bytes(Value: number): buffer
	const Bytes = buffer.create(1)

	buffer.writeu8(Bytes, 0, Value)

	return Bytes
end

const function Uint32Bytes(Value: number): buffer
	const Bytes = buffer.create(4)

	buffer.writeu32(Bytes, 0, Value)

	return Bytes
end

const function Uint64Bytes(Value: number): buffer
	return Concat({ Uint32Bytes(Value % TwoPow32), Uint32Bytes(Value // TwoPow32) })
end

const function Float32Bytes(Value: number): buffer
	const Bytes = buffer.create(4)

	buffer.writef32(Bytes, 0, Value)

	return Bytes
end

const function Float64Bytes(Value: number): buffer
	const Bytes = buffer.create(8)

	buffer.writef64(Bytes, 0, Value)

	return Bytes
end

-- A name as the source's storeSizedString writes it: its UTF-16 length (the quirk kept), then its UTF-8 bytes.
-- @src scripts/game/managers/ReplayManager.cs:storeSizedString L89-93
const function SizedText(Text: string): buffer
	local Units = 0

	for _, CodePoint in utf8.codes(Text) do
		Units += if CodePoint > 0xFFFF then 2 else 1
	end

	return Concat({ Uint32Bytes(Units), buffer.fromstring(Text) })
end

-- The modifier names, then Spin or Lock when the camera is one of them, joined with "_" (the source's temporary replay format,
-- which had Spin only: Lock, the camera that stays still, goes the same way). The default camera adds nothing.
-- @src scripts/game/managers/ReplayManager.cs:NewReplay L77-85
const function ModifierNames(Attempt: Attempt): string
	const Names: { string } = {}

	for _, Mod in Attempt.Modifiers do
		table.insert(Names, Mod.Name)
	end

	if Attempt.CameraMode.Name == "Spin" or Attempt.CameraMode.Name == "Lock" then
		table.insert(Names, Attempt.CameraMode.Name)
	end

	return table.concat(Names, "_")
end

-- The header of a new recording: everything before the status byte. Settings are read as the source does.
-- @src scripts/game/managers/ReplayManager.cs:NewReplay L49-72
const function HeaderBytes(Attempt: Attempt): buffer
	const Settings = Attempt.Settings

	return Concat({
		buffer.fromstring(Signature),
		Uint8Bytes(FileVersion),
		Float64Bytes(Attempt.Speed),
		Float64Bytes(Attempt.StartFrom),
		Float64Bytes(Settings.ApproachRate.Value),
		Float64Bytes(Settings.ApproachDistance.Value),
		Float64Bytes(Settings.FadeIn.Value),
		Uint8Bytes(if Settings.FadeOut.Value > 0 then 1 else 0),
		Uint8Bytes(if Settings.Pushback.Value then 1 else 0),
		Float64Bytes(Settings.CameraParallax.Value),
		Float64Bytes(Settings.FoV.Value),
		Float64Bytes(Settings.NoteSize.Value),
		Float64Bytes(Settings.Sensitivity.Value),
	})
end

-- The hit byte of one note: a miss is 255, otherwise the hit times 4 (254 / 55 is the integer 4 in the source), at most 254.
-- @src scripts/game/managers/ReplayManager.cs:SaveReplay L133-133
const function HitByte(Hit: number): number
	if Hit == -1 then
		return 255
	end

	const Scaled = Hit * 4
	const Capped = if Scaled < 254 then Scaled else 254

	return Numbers.Uint8(Numbers.TruncInt32(Capped))
end

-- The hit bytes of the notes from FirstNote on, Sum of them (HitsInfo[low..high] of the source).
-- @src scripts/game/managers/ReplayManager.cs:SaveReplay L127-135
const function HitBytes(Attempt: Attempt): buffer
	const Low = math.max(0, Numbers.Int32(Attempt.FirstNote))
	local High = Numbers.Int32(Attempt.FirstNote + Attempt.Sum)

	if High < Low then
		High = Low
	end

	if High > #Attempt.HitsInfo then
		error("Range is outside the hits.", 0)
	end

	const Bytes = buffer.create(High - Low)

	for Index = Low, High - 1 do
		buffer.writeu8(Bytes, Index - Low, HitByte(Attempt.HitsInfo[Index + 1]))
	end

	return Bytes
end

-- The file's parts before its digest, with the status byte and the frame count the attempt gives (SaveReplay).
-- @src scripts/game/managers/ReplayManager.cs:SaveReplay L104-143
const function Content(Recording: Recording, Attempt: Attempt): buffer
	const Status = if Attempt.Alive then (if Attempt.Qualifies then StatusPassed else StatusDisqualified) else StatusFailed
	const Frames = Attempt.ReplayFrames
	const FrameParts: { buffer } = {}

	for _, Frame in Frames do
		table.insert(FrameParts, Float32Bytes(Frame[1]))
		table.insert(FrameParts, Float32Bytes(Frame[2]))
		table.insert(FrameParts, Float32Bytes(Frame[3]))
	end

	const SkipParts: { buffer } = {}

	for _, Skip in Attempt.ReplaySkips do
		table.insert(SkipParts, Float32Bytes(Skip))
	end

	return Concat({
		Recording.Head,
		Uint8Bytes(Status),
		Recording.Middle,
		Uint64Bytes(#Frames),
		Concat(FrameParts),
		Uint64Bytes(Attempt.FirstNote),
		Uint64Bytes(Attempt.Sum),
		HitBytes(Attempt),
		Uint64Bytes(#Attempt.ReplaySkips),
		Concat(SkipParts),
	})
end

-- @src scripts/game/managers/ReplayManager.cs:ReplayManager L7-354
const function New(Runner: Runner, CursorManager: CursorManager): Manager
	return {
		Runner = Runner,
		CursorManager = CursorManager,
		CurrentMode = Mode.NONE,
		ViewerVisible = false,
		CanShow = false,
		ReplayLength = 0,
		ReplayPath = nil,
		CursorPosition = vector.zero,
		SeekerHovered = false,
		Recording = nil,
	}
end

-- Starts a recording of the attempt when its settings record replays: the file gets its header now, and SaveReplay
-- completes it.
-- @src scripts/game/managers/ReplayManager.cs:NewReplay L47-102
const function NewReplay(Manager: Manager, Attempt: Attempt)
	if not Attempt.Settings.RecordReplays.Value then
		return
	end

	const Path = `{Constants.UserFolder}/replays/{Attempt.ID}.phxr`
	const Head = HeaderBytes(Attempt)
	const Middle = Concat({
		SizedText(ModifierNames(Manager.Runner.Attempt)),
		SizedText(FileSystem.GetFileName(Attempt.Map.FolderPath)),
		Uint64Bytes(#MapModule.GetNotes(Attempt.Map)),
		SizedText(PlayerName),
	})

	Manager.ReplayPath = Path
	Manager.Recording = {
		Path = Path,
		Head = Head,
		Middle = Middle,
	}

	FileSystem.WriteAllBytes(Path, Concat({ Head, Uint8Bytes(0), Middle, Uint64Bytes(0) }))
end

-- Completes the recording: the status, the frames, the tail and the digest. Nothing is saved without a recording.
-- @src scripts/game/managers/ReplayManager.cs:SaveReplay L104-154
const function SaveReplay(Manager: Manager, Attempt: Attempt)
	const Recording = Manager.Recording

	if not Recording then
		return
	end

	FileSystem.WriteAllBytes(Recording.Path, Content(Recording, Attempt))
	Manager.Recording = nil

	const HashPath = `{Constants.UserFolder}/replays/{Attempt.ID}.phxr`

	if not FileSystem.Exists(HashPath) then
		error(`Replay file {HashPath} is missing`, 0)
	end

	const Written = FileSystem.ReadAllBytes(HashPath)

	FileSystem.WriteAllBytes(HashPath, Concat({ Written, Sha256.Hash(Written) }))

	Attempt.ReplayPath = Recording.Path
end

-- The replay's length, once the attempt is a replay that has one.
-- @src scripts/game/managers/ReplayManager.cs:InitReplayLength L156-161
const function InitReplayLength(Manager: Manager)
	const Attempt = Manager.Runner.Attempt

	if not Attempt or not Attempt.IsReplay then
		return
	end

	Manager.ReplayLength = Attempt.MaxReplayLength
end

-- Shows or hides the viewer (toggled when Show is nil). The mouse is visible while a replay's viewer shows.
-- @src scripts/game/managers/ReplayManager.cs:ShowReplayViewer L219-234
const function ShowReplayViewer(Manager: Manager, Attempt: Attempt, Show: boolean?)
	if Show ~= nil then
		Manager.ViewerVisible = Show
	else
		Manager.ViewerVisible = not Manager.ViewerVisible
	end

	const Visible = Manager.ViewerVisible and Attempt.IsReplay

	if View.ShowReplayViewer then
		View.ShowReplayViewer(Visible)
	end

	if Attempt.IsReplay and View.SetMouseVisible then
		View.SetMouseVisible(Visible)
	end
end

-- Shows or hides the orthogonal camera panel (toggled when Show is nil), for replays only.
-- @src scripts/game/managers/ReplayManager.cs:ShowOrthonogalCamera L236-242
const function ShowOrthogonalCamera(Manager: Manager, Attempt: Attempt, Show: boolean?)
	if Show ~= nil then
		Manager.CanShow = Show
	else
		Manager.CanShow = not Manager.CanShow
	end

	if View.ShowOrthogonalCamera then
		View.ShowOrthogonalCamera(Manager.CanShow and Attempt.IsReplay)
	end
end

-- Pauses or resumes the runner (its toggle), and shows the icon of the new state.
-- @src scripts/game/managers/ReplayManager.cs:TogglePause L244-251
const function TogglePause(Manager: Manager)
	Manager.Runner.Pause()

	if View.SetPauseIcon then
		View.SetPauseIcon(Manager.Runner.Playing)
	end
end

-- The seeker's label at a slider ratio: the time reached and the replay's length, as "m:ss / m:ss".
-- @src scripts/game/managers/ReplayManager.cs:_Ready L178-183
const function TimeText(Manager: Manager, Ratio: number): string
	const Current = UtilString.FormatTime(Ratio * Manager.ReplayLength / 1000)
	const End = UtilString.FormatTime(Numbers.F32(Manager.ReplayLength / 1000))

	return `{Current} / {End}`
end

-- a replay cursor's curve tangent may be at most this many times its segment's chord (as the trail's, Game/View/TrailRenderer)
const TangentLimit = 1.5

-- Where a replay's cursor is at Ratio of the way between its frames Index and Next (0-based): a Hermite curve through the
-- frames with the cursor's speed at each as its tangent (time-based Catmull-Rom, tangents capped so a sudden stop can't loop),
-- the curve the trail draws. Straight lines between the frames (60 a second, a watched player's 30) turned the path into
-- corners and the cursor's speed into steps at high frame rates. The curve passes through every frame exactly.
const function CurveAt(Frames: { Replay.Frame }, Index: number, Next: number, Ratio: number): vector
	const Current = Frames[Index + 1]
	const Following = Frames[Next + 1]
	const P1, P2 = Current.CursorPosition, Following.CursorPosition
	const T1, T2 = Current.Progress, Following.Progress
	const H = T2 - T1

	if not (H > 0) then
		return P1 + (P2 - P1) * Ratio
	end

	-- the frames either side (none at the ends: the segment is mirrored there)
	const Before = Frames[Index]
	const After = Frames[Next + 2]
	local P0, T0 = 2 * P1 - P2, T1 - H
	local P3, T3 = 2 * P2 - P1, T2 + H

	if Before and Before.Progress < T1 then
		P0, T0 = Before.CursorPosition, Before.Progress
	end

	if After and After.Progress > T2 then
		P3, T3 = After.CursorPosition, After.Progress
	end

	local V1 = (P2 - P0) * (H / (T2 - T0))
	local V2 = (P3 - P1) * (H / (T3 - T1))
	const Cap = TangentLimit * vector.magnitude(P2 - P1)
	const L1 = vector.magnitude(V1)
	const L2 = vector.magnitude(V2)

	if L1 > Cap then
		V1 *= if L1 > 0 then Cap / L1 else 0
	end

	if L2 > Cap then
		V2 *= if L2 > 0 then Cap / L2 else 0
	end

	const S = Ratio
	const S2 = S * S
	const S3 = S2 * S

	return P1 * (2 * S3 - 3 * S2 + 1) + V1 * (S3 - 2 * S2 + S) + P2 * (-2 * S3 + 3 * S2) + V2 * (S3 - S2)
end

-- Moves every replay's cursor to the attempt's progress. A frame index only moves forward, and a cursor past the last
-- frame is hidden once.
-- @src scripts/game/managers/ReplayManager.cs:updateCursors L318-353
const function UpdateCursors(Manager: Manager)
	const Attempt = Manager.Runner.Attempt

	for Index = 0, #Attempt.Replays - 1 do
		const Track = Attempt.Replays[Index + 1]
		const Frames = Track.Frames :: { Replay.Frame }
		const LastFrame = #Frames - 1

		if Track.FrameIndex == LastFrame then
			continue
		end

		while Track.FrameIndex < LastFrame and Attempt.Progress >= Frames[Track.FrameIndex + 2].Progress do
			Track.FrameIndex += 1

			-- (a live replay's last frame isn't the end: more are on their way)
			if Track.FrameIndex == LastFrame and not Track.Live then
				Manager.CursorManager.HideCursor(Index, false)
			end
		end

		const Next = math.min(Track.FrameIndex + 1, LastFrame)
		const Current = Frames[Track.FrameIndex + 1]
		const Following = Frames[Next + 1]
		const Inverse = if Track.Live and Following.Progress == Current.Progress then 0 else (Attempt.Progress - Current.Progress) / (Following.Progress - Current.Progress)

		local Ratio = Inverse

		if Ratio < 0 then
			Ratio = 0
		elseif Ratio > 1 then
			Ratio = 1
		end

		-- (along the frames' curve; the quirks stay as they were: on the last frame, or between two frames with one progress,
		-- the straight line still gives NaN, or a live replay waiting on its next frame holds its last one)
		const Position = if Ratio == Ratio and Next ~= Track.FrameIndex
			then CurveAt(Frames, Track.FrameIndex, Next, Numbers.F32(Ratio))
			else Current.CursorPosition + (Following.CursorPosition - Current.CursorPosition) * Numbers.F32(Ratio)

		Manager.CursorPosition = Position
		Manager.CursorManager.UpdateCursor(Position, Index)
		Manager.CursorManager.ShowCursor(Index, true)
	end
end

-- Seeks to a time. The attempt's counts restart, the notes before the seek are hit or missed as the replay had them, and the
-- replay's frame index moves to the seek time.
-- @src scripts/game/managers/ReplayManager.cs:seek L253-316
const function SeekTo(Manager: Manager, Seeked: number)
	const Attempt = Manager.Runner.Attempt
	const FirstReplay = Attempt.Replays[1]
	const ReplayedNotes = FirstReplay.Notes :: { number }

	-- Note.luau types the runner's attempt with exactly the fields the hit reads (Luau table properties are invariant), so
	-- the same table is passed through unknown.
	const NoteRunner = (Manager.Runner :: unknown) :: Note.Runner

	Attempt.Hits = 0
	Attempt.Misses = 0
	Attempt.Sum = 0
	Attempt.Accuracy = 100
	Attempt.Score = 0
	Attempt.Combo = 0
	Attempt.ComboMultiplier = 1
	Attempt.ComboMultiplierProgress = 0
	Attempt.Health = 100
	Attempt.HealthStep = 15
	Attempt.Alive = true
	Attempt.Qualifies = true

	const Notes = MapModule.GetNotes(Attempt.Map)

	const function Rejudge()
		for Index = 1, #Notes do
			const NoteValue = Notes[Index]

			NoteValue.Hittable = false
			NoteValue.LastResult = HitResult.None

			if NoteValue.Millisecond > math.max(Attempt.Progress, Seeked) then
				break
			elseif NoteValue.Millisecond < Seeked and NoteValue.Index >= Attempt.FirstNote then
				if ReplayedNotes[Index] == MissNote then
					Note.Miss(NoteValue, NoteRunner, false)
				else
					Note.Hit(NoteValue, NoteRunner, false)
				end
			end
		end
	end

	-- (not in the source, a live view only: the earlier notes are judged again with only the runner's own scoring listening,
	-- and the screen is told once, by the stats sent below. Every note used to go through the whole HUD as well, a hit
	-- popup and five texts redrawn each: joining a song late, the player skipping a break or a gap of over 2 s froze the
	-- watcher's game for up to a second or more, longer the further into the song, and a freeze of over 2 s asked for the
	-- next seek by itself. The score, combo, health and counts come out the same. A saved replay's seek is as it was.)
	if FirstReplay.Live then
		const Hits, Stats = Manager.Runner.HitResultChanged, Manager.Runner.AttemptStatsUpdated
		const Heard, Told = Hits.Listeners, Stats.Listeners
		const Scoring = (Manager.Runner :: any).HitListener

		Hits.Listeners = if Scoring ~= nil and table.find(Heard, Scoring) then { Scoring } else {}
		Stats.Listeners = {}

		const Judged, Problem = pcall(Rejudge)

		Hits.Listeners, Stats.Listeners = Heard, Told

		if not Judged then
			error(Problem, 0)
		end
	else
		Rejudge()
	end

	if Attempt.Progress > Manager.ReplayLength and Seeked <= Manager.ReplayLength and not Manager.Runner.Playing then
		TogglePause(Manager)
	end

	Manager.Runner.Seek(Seeked)
	Signal.Fire(Manager.Runner.AttemptStatsUpdated, Attempt)

	const Frames = FirstReplay.Frames :: { Replay.Frame }

	for Index = 0, #Frames - 1 do
		if Attempt.Progress < Frames[Index + 1].Progress then
			FirstReplay.FrameIndex = math.max(0, Index - 1)

			break
		end
	end

	UpdateCursors(Manager)
end

-- Seeks to a ratio of the replay's length (the seeker's drag end).
const function Seek(Manager: Manager, Ratio: number)
	SeekTo(Manager, Numbers.F32(Numbers.F32(Ratio) * Manager.ReplayLength))
end

-- The per-frame update. While a replay plays the seeker follows the progress (unless it is hovered), the replay pauses
-- once the progress passes its length, and the cursors move.
-- @src scripts/game/managers/ReplayManager.cs:_Process L201-217
const function Process(Manager: Manager)
	const Attempt = Manager.Runner.Attempt

	if not Attempt.IsReplay or not Manager.Runner.Playing then
		return
	end

	if not Manager.SeekerHovered then
		-- (a live view has no seeker: it is hidden, and its length isn't known, so this redrew it with a new tiny value each frame)
		if View.SetSeekerValue and not Attempt.Replays[1].Live then
			View.SetSeekerValue(Attempt.Progress / Attempt.MaxReplayLength)
		end

		if Attempt.Progress > Manager.ReplayLength and Manager.Runner.Playing then
			TogglePause(Manager)
		end
	end

	UpdateCursors(Manager)
end

return {
	Mode = Mode,
	View = View,
	New = New,
	NewReplay = NewReplay,
	SaveReplay = SaveReplay,
	InitReplayLength = InitReplayLength,
	ShowReplayViewer = ShowReplayViewer,
	ShowOrthogonalCamera = ShowOrthogonalCamera,
	TogglePause = TogglePause,
	Seek = Seek,
	SeekTo = SeekTo,
	ModifierNames = ModifierNames,
	Process = Process,
	TimeText = TimeText,
}
