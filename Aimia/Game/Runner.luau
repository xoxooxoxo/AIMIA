--!strict
--!optimize 2

--[[
	Runner.cs: plays one attempt. Each frame it advances the progress from the tick clock, keeps the song in step with it
	(the de-sync corrector), records replay frames, processes and renders the timeline objects and runs the autoplay cursor.
	It also starts, pauses, skips, seeks, fails and stops the attempt, and scores each hit (score, combo, accuracy, health).

	Representation
		A runner is a table from New(Host). Functions take it first (Runner.Play(Runner)). Attempt is nil until the scene sets
		it; the functions that need it read it through a cast, as the source dereferences it. Pause and Seek are closures
		over the runner, because ReplayManager calls Manager.Runner.Pause(). HitListener is the function connected to
		HitResultChanged while an attempt plays. ObjectIndicesStart and ObjectIndicesEnd are keyed by ObjectType and hold
		0-based indexes, as the source's do. Times are milliseconds; Host.Ticks and the frame gap are microseconds.

	Design Notes
		Attempt.Objects holds notes only (Attempt.New), so the timeline hooks are Note's. Note.Runner names only the fields a
		hit reads and Luau table properties are invariant, so the runner reaches Note through AsNoteRunner, the one cast.
		Mathf.Epsilon is not in reference/engine; FLT_EPSILON is used, as UI/Menu/Play/InfoLogic/Speed.luau does.
		Upstream quirks kept: the replay frame check compares arrays with `!=` (a reference comparison in C#), so every frame
		is recorded once the frame gap has passed; the miss accuracy is a float division (Mathf.Floor), the hit accuracy a
		double one (Math.Floor); the skip window of a map with no notes left is int.MaxValue.
]]

const AttemptModule = require("./Attempt")
const Constants = require("../Constants")
const FileSystem = require("../Util/FileSystem")
const HitResult = require("./Judgments/HitResult")
const Leaderboard = require("../Map/Leaderboard")
const Logger = require("../Util/Logger")
const MapModule = require("../Map/Map")
const MapTypes = require("../Map/MapTypes")
const Misc = require("../Util/Misc")
const Modifier = require("./Modifiers/Modifier")
const Note = require("../Map/Objects/Note")
const Numbers = require("../Numbers")
const ObjectType = require("../Map/Objects/ObjectType")
const Renderer = require("./Renderers/Renderer")
const ReplayManager = require("./Managers/ReplayManager")
const SettingsManager = require("../SettingsManager")
const SettingsProfile = require("../Database/Settings/SettingsProfile")
const SkinManager = require("../Skinning/SkinManager")
const Sha256 = require("../Util/Sha256")
const Signal = require("../Util/Signal")
const SoundManager = require("../Audio/SoundManager")
const Stats = require("../Database/Stats")
const AutoplayHandler = require("./AutoplayHandler")

type Attempt = AttemptModule.Attempt

export type Host = {
	Hud: {
		Init: () -> (),
		DisplayModifier: (Modifier.Modifier) -> (),
	},
	Renderers: { Renderer.Renderer },
	Cursor: {
		UpdateAutoplayCursor: (vector) -> (),
	},
	Replay: ReplayManager.Manager,
	Camera: { Fov: number },
	Ticks: () -> number,
	Scenes: {
		LoadResults: () -> (),
	},
	NoteMesh: (() -> ())?,
}

export type Runner = {
	Host: Host,
	Attempt: Attempt?,
	Map: MapTypes.Map?,
	Speed: number,
	Paused: boolean,
	Playing: boolean,
	StopQueued: boolean,
	NotesOnly: boolean,
	ObjectIndicesStart: { [number]: number },
	ObjectIndicesEnd: { [number]: number },
	Settings: SettingsProfile.SettingsProfile?,
	AutoplayHandler: AutoplayHandler.AutoplayHandler?,
	AutoplayEnabled: boolean,
	LastFrame: number,
	FirstFrame: boolean,
	EventsConnected: boolean,
	HitResultProgressOverride: number?,
	NoteTimestamps: { number },
	AttemptStatsUpdated: Signal.Signal<Attempt>,
	SkipAvailable: Signal.Signal<Attempt>,
	HitResultChanged: Signal.Signal<number, number>,
	HitListener: (number, number) -> (),
	Pause: (boolean?) -> (),
	Seek: (number) -> (),
	-- how many seeks there have been (the cursor trail starts again after each, Game/View/TrailRenderer)
	Seeks: number,
	-- the owner panel's auto (Hooks.OwnerAuto): the notes (1-based, of the attempt's notes) it misses on purpose, or nil
	OwnerAuto: { [number]: boolean }?,
}

-- The 1/60 s replay frame gap in microseconds (1000000 / 60 in the source, an integer division).
const ReplayFrameTicks = 1000000 // 60
-- Float32 machine epsilon: the corrector's tolerance for the pitch scale (Mathf.Epsilon).
const Epsilon = 1.1920928955078125e-07
-- int.MaxValue: the next note's millisecond on a map whose notes are all passed.
const IntMax = 2147483647
-- uint.MaxValue: the saturation of a (uint) cast of a double.
const UintMax = 4294967295
-- DEVIATION(phase3): the source's `mod is AutoplayModifier` tests the modifier's name, as modifiers are tables, not classes.
const AutoplayName = "Autoplay"

-- The owner panel's auto (only an Owner's game sets this hook: the panel, from ServerStorage.AimiaOwnerPanel). When a run
-- starts with no Autoplay, and isn't a replay, a watched song or a notes-only preview, OwnerAuto(Attempt, Notes) is asked
-- for a plan: { Misses = the set of note indices (1-based, of Notes) to miss, Path = the cursor's stops ({ X, Y,
-- Millisecond }, one a note, with a spot beside each missed one) }, or nil to play normally. The run then plays itself as
-- autoplay does (so no local score or replay is kept: Stop) but misses exactly those notes, and it never fails
-- (OnHitResultChanged).
const Hooks = {
	OwnerAuto = nil :: ((Attempt: Attempt, Notes: { Note.Note }) -> any)?,
}

-- The runner as a Note.Runner. Its Attempt has more fields than Note reads, so this is the single cast between the two types.
const function AsNoteRunner(Runner: Runner): Note.Runner
	return (Runner :: unknown) :: Note.Runner
end

-- Modifier and AutoplayHandler declare the attempt and map fields they read with narrower types (a SettingsItem is not a
-- { Value } table, and a map's Notes may be nil). Luau table properties are invariant, so these are the casts between them.
const function AsModifierAttempt(Attempt: Attempt): Modifier.Attempt
	return (Attempt :: unknown) :: Modifier.Attempt
end

const function AsModifierMap(Map: MapTypes.Map): Modifier.Map
	return (Map :: unknown) :: Modifier.Map
end

const function AsAutoplayAttempt(Attempt: Attempt): AutoplayHandler.AutoplayAttempt
	return (Attempt :: unknown) :: AutoplayHandler.AutoplayAttempt
end

-- @src scripts/game/Runner.cs:ProcessObjects L182-218
const function ProcessObjects(Runner: Runner)
	const Attempt = Runner.Attempt :: Attempt
	const Settings = Runner.Settings :: SettingsProfile.SettingsProfile
	const NoteRunner = AsNoteRunner(Runner)

	for ObjectKind, Objects in Attempt.Objects do
		const StartIndex = Runner.ObjectIndicesStart[ObjectKind]

		Runner.ObjectIndicesEnd[ObjectKind] = #Objects

		for Index = StartIndex + 1, #Objects do
			const Object = Objects[Index] :: Note.Note

			if Note.DoProcess(Object, NoteRunner) then
				Note.Process(Object, NoteRunner)
			else
				-- don't waste time iterating over objects past the approach time
				-- (with the approach the notes are drawn with: a replay's recorded one made notes pop in part way)
			if Object.Millisecond > Attempt.Progress + Attempt.Settings.ApproachTime.Value * 1000 * Runner.Speed then
					Runner.ObjectIndicesEnd[ObjectKind] = math.max(Object.Index, Runner.ObjectIndicesStart[ObjectKind])

					break
				end

				if Object.Index == Runner.ObjectIndicesStart[ObjectKind] and Object.Millisecond < math.max(Attempt.Progress, Attempt.StartFrom) then
					Runner.ObjectIndicesStart[ObjectKind] += 1
				end
			end
		end
	end
end

-- @src scripts/game/Runner.cs:RenderObjects L220-226
const function RenderObjects(Runner: Runner, Delta: number)
	const Attempt = Runner.Attempt :: Attempt

	for _, View in Runner.Host.Renderers do
		View.Process(Delta, Attempt)
	end
end

-- The autoplay hits: every note up to the progress that is not hit yet is hit at its own millisecond (the override).
-- @src scripts/game/Runner.cs:processAutoplayHits L228-263
const function ProcessAutoplayHits(Runner: Runner)
	const Attempt = Runner.Attempt :: Attempt
	const Objects = Attempt.Objects[ObjectType.Note]

	if not Runner.AutoplayEnabled or Attempt.IsReplay or Objects == nil then
		return
	end

	const StartIndex = Runner.ObjectIndicesStart[ObjectType.Note]

	for Index = StartIndex + 1, #Objects do
		const Object = Objects[Index] :: Note.Note

		if Object.Millisecond > Attempt.Progress then
			break
		end

		if Object.Millisecond < Attempt.StartFrom or Object.LastResult ~= HitResult.None then
			continue
		end

		-- (the owner panel's auto: a note it misses is never hit. It's missed once its window has passed, as anyone's is, or
		-- at once if the cursor's path comes onto it first, so the count is always the one picked.)
		if Runner.OwnerAuto and Runner.OwnerAuto[Index] then
			const Cursor = Attempt.CursorPosition
			const Reach = 0.5 + Constants.HitBoxSize + 0.02

			if math.abs(Cursor.x - Object.X) <= Reach and math.abs(Cursor.y - Object.Y) <= Reach then
				Note.Miss(Object, AsNoteRunner(Runner), nil)
			end

			continue
		end

		Object.Hittable = true
		Runner.HitResultProgressOverride = Object.Millisecond

		-- The override is cleared on both paths, as the source's finally does, before the error is raised again.
		-- The nil is Note.Hit's PlaySound (true by default).
		const Success, Failure = pcall(Note.Hit, Object, AsNoteRunner(Runner), nil)

		Runner.HitResultProgressOverride = nil

		if not Success then
			error(Failure, 0)
		end
	end
end

-- (when the de-sync corrector last fixed a stall with a seek, and when the song was last started or moved, os.clock seconds)
local LastResync = -math.huge
local LastSongStart = -math.huge
-- (not in the source: after a seek, a start part-way into the song or a resume, the timeline waits for the song to move, for
-- at most SongWaitLimit seconds; Resuming notes a pause, so the next playing frame starts that wait)
local WaitForSong = false
local Resuming = false
const SongWaitLimit = 0.25
-- (not in the source, a live view only (Attempt.IsLive, someone else's song being watched): its timeline is the watched
-- player's, moved by Game/LiveSpectate, so it never waits or slows for this game's song as a run of one's own does. The two
-- used to pull against each other: after any catch-up the notes stood still for the song, fell behind the player, sped up,
-- ran ahead of the song and had the song moved again, about every two seconds, for many seconds. The song follows instead:
-- its seek aims where the notes will be once it moves, by how long this game's song last took to move.)
local LiveSongLag = 0.1
-- (not in the source: how close to its end, in song milliseconds, the song stops being followed: Roblox can stop a song a
-- block or two before its length, and from here the timeline runs on by the clock)
const SongEndMargin = 300

-- Moves the song to the progress (minus the local offset) when the attempt has audio.
-- @src scripts/game/Runner.cs:syncSongPosition L684-696
const function SyncSongPosition(Runner: Runner)
	const Attempt = Runner.Attempt :: Attempt

	if Attempt.Map.AudioBuffer ~= nil then
		if not SoundManager.Song.Playing and Runner.Playing then
			SoundManager.SongPlay()
		end

		if Attempt.IsLive then
			SoundManager.SongSeek(Numbers.F32(Numbers.F32(Attempt.Progress + LiveSongLag * 1000 * Runner.Speed - Attempt.Settings.LocalOffset.Value) / 1000))
		else
			SoundManager.SongSeek(Numbers.F32(Numbers.F32(Attempt.Progress - Attempt.Settings.LocalOffset.Value) / 1000))
		end

		LastSongStart = os.clock()
		WaitForSong = true
	end
end

-- @src scripts/game/Runner.cs:Seek L401-418
const function Seek(Runner: Runner, Ms: number)
	const Attempt = Runner.Attempt :: Attempt

	Runner.Seeks += 1

	Attempt.Progress = Ms

	if Runner.AutoplayHandler then
		AutoplayHandler.Reset(Runner.AutoplayHandler, Attempt.Progress)
	end

	for ObjectKind, Objects in Attempt.Objects do
		Runner.ObjectIndicesStart[ObjectKind] = Misc.BinarySearch(Runner.NoteTimestamps, Ms) + 1
		Runner.ObjectIndicesEnd[ObjectKind] = #Objects
	end

	ProcessObjects(Runner)
	RenderObjects(Runner, 0)

	SyncSongPosition(Runner)
end

-- Pauses or resumes (Value true plays, false pauses; nil toggles). The song follows the new state.
-- @src scripts/game/Runner.cs:Pause L370-380
const function Pause(Runner: Runner, Value: boolean?)
	Runner.Playing = if Value ~= nil then Value else not Runner.Playing
	SoundManager.SongSetPitch(Runner.Speed)
	SoundManager.SongSetPaused(not Runner.Playing)

	if Runner.Playing then
		SyncSongPosition(Runner)
	end
end

-- @src scripts/game/Runner.cs:Fail L420-437
const function Fail(Runner: Runner)
	const Attempt = Runner.Attempt :: Attempt

	-- (not in the source: a run that has ended keeps how it ended. A restart or give-up landing in the moment between the stop
	-- and the results used to turn a finished run into a failed one, which the song lists then never took.)
	if Attempt.Stopped then
		return
	end

	if Attempt.Alive then
		SoundManager.PlayFail()
	end

	if not Attempt.IsReplay then
		SoundManager.SetSongDimmed(true)
		Attempt.Alive = false
		Attempt.Qualifies = false

		if Attempt.DeathTime == -1 then
			Attempt.DeathTime = math.max(0, Attempt.Progress)
		end
	end
end

-- @src scripts/game/Runner.cs:QueueStop L445-454
const function QueueStop(Runner: Runner)
	if not Runner.Playing then
		return
	end

	Runner.Playing = false
	Runner.StopQueued = true
end

-- Ends the attempt: the last object pass, the replay save, the playtime, distance, personal best and stats. Results
-- (default true) loads the results scene.
-- @src scripts/game/Runner.cs:Stop L456-547
const function Stop(Runner: Runner, Results: boolean?)
	const Attempt = Runner.Attempt :: Attempt

	if Attempt.Stopped then
		return
	end

	-- give objects a last chance
	ProcessObjects(Runner)

	Runner.Playing = false
	Runner.StopQueued = false
	Attempt.Stopped = true

	if Runner.EventsConnected then
		Runner.EventsConnected = false
		Signal.Disconnect(Runner.HitResultChanged, Runner.HitListener)
	end

	-- dont want an infinite dependency loop so im just going to do this -fog
	if not Runner.AutoplayEnabled and not Attempt.IsReplay and Runner.Host.Replay.CurrentMode == ReplayManager.Mode.RECORD then
		-- (not in the source: a replay that can't be written doesn't stop the run from ending. It used to leave the song
		-- stopped with no results; now the results come up, and only the replay, and so the run's place on the lists, is lost.)
		const Saved, Problem = pcall(ReplayManager.SaveReplay, Runner.Host.Replay, Attempt)

		if not Saved then
			warn(`[AIMIA] the replay wasn't saved: {Problem}`)
		end
	end

	-- Aimia.TempMode is Constants.TempMapMode in this port.
	if not Attempt.IsReplay and not Constants.TempMapMode then
		Stats.Instance.GamePlaytime += (Runner.Host.Ticks() - Attempt.TimeStarted) // 1000000
		Stats.Instance.TotalDistance += math.max(0, Numbers.Trunc(Attempt.DistanceMM))

		if Attempt.StartFrom == 0 and not Runner.AutoplayEnabled then
			const BoardPath = `{Constants.UserFolder}/pbs/{Attempt.Map.Name}`

			if not FileSystem.Exists(BoardPath) then
				const Digest = Sha256.Hash(buffer.create(4))
				const Bytes = buffer.create(4 + buffer.len(Digest))

				buffer.copy(Bytes, 4, Digest)
				FileSystem.WriteAllBytes(BoardPath, Bytes)
			end

			const ModifierEntries: { Leaderboard.ModifierEntry } = {}
			const Named: { [string]: boolean } = {}

			for _, Mod in Attempt.Modifiers do
				if not Named[Mod.Name] then
					Named[Mod.Name] = true

					table.insert(ModifierEntries, { Key = Mod.Name, Value = true })
				end
			end

			const Board = Leaderboard.New(Attempt.Map.Name, BoardPath)
			-- DEVIATION(platform): Time.GetUnixTimeFromSystem is the host's clock (Attempt.Hooks.UnixTime), else whole seconds of os.time().
			const UnixTime = if AttemptModule.Hooks.UnixTime then AttemptModule.Hooks.UnixTime() else os.time()

			Leaderboard.Add(
				Board,
				Leaderboard.NewScore(
					Attempt.ID,
					"You",
					Attempt.Qualifies,
					Attempt.Score,
					Attempt.Accuracy,
					UnixTime,
					Attempt.Progress,
					Attempt.Map.Length,
					Runner.Speed,
					ModifierEntries
				)
			)
			Leaderboard.Save(Board)

			if Attempt.Qualifies then
				Stats.Instance.Passes += 1
				Stats.Instance.TotalScore += Attempt.Score

				if Attempt.Accuracy == 100 then
					Stats.Instance.FullCombos += 1
				end

				if Attempt.Score > Stats.Instance.HighestScore then
					Stats.Instance.HighestScore = Attempt.Score
				end

				Stats.Instance.AverageAccuracy = (Stats.Instance.AverageAccuracy + Attempt.Accuracy) / Stats.Instance.Passes
			end
		end

		Stats.ForceUpdate(Stats.Instance)
	end

	if Results ~= false then
		Runner.Host.Scenes.LoadResults()
	end
end

-- The skip: a skip the window allows is recorded and the attempt seeks to the next note (or stops past the last one).
-- @src scripts/game/Runner.cs:Skip L382-399
const function Skip(Runner: Runner)
	const Attempt = Runner.Attempt :: Attempt

	-- (not in the source: a run that has ended takes no more skips. Space pressed just as the song stopped used to add one
	-- to the attempt after its replay file was written.)
	if Attempt.CanSkip and not Attempt.Stopped then
		table.insert(Attempt.ReplaySkips, Numbers.F32(Attempt.Progress))

		const Settings = Runner.Settings :: SettingsProfile.SettingsProfile
		const PassedNotes = Runner.ObjectIndicesStart[ObjectType.Note]
		const Notes = MapModule.GetNotes(Attempt.Map)

		if PassedNotes >= #Notes then
			Stop(Runner, true)
		else
			-- turn AT to ms and multiply by 1.5x. Only ever forward: with a long approach time this lands before where you are,
			-- which sent you back in the song.
			const Target = Notes[PassedNotes + 1].Millisecond - Settings.ApproachTime.Value * 1500 * Runner.Speed

			if Target > Attempt.Progress then
				Seek(Runner, Target)
			end
		end
	end
end

-- @src scripts/game/Runner.cs:GiveUp L439-443
const function GiveUp(Runner: Runner)
	Fail(Runner)
	Stop(Runner, true)
end

-- Starts the attempt: the timeline, the events, the modifiers, the autoplay, the settings, the renderers and the song.
-- @src scripts/game/Runner.cs:Play L265-368
const function Play(Runner: Runner)
	const Attempt = Runner.Attempt

	if Attempt == nil then
		return
	end

	Runner.Map = Attempt.Map
	Runner.Speed = Attempt.Speed

	Runner.ObjectIndicesStart = {}
	Runner.ObjectIndicesEnd = {}

	for ObjectKind, Objects in Attempt.Objects do
		Runner.ObjectIndicesStart[ObjectKind] = Attempt.FirstNote
		Runner.ObjectIndicesEnd[ObjectKind] = #Objects
	end

	Runner.NoteTimestamps = {}

	for _, Object in Attempt.Objects[ObjectType.Note] do
		table.insert(Runner.NoteTimestamps, Object.Millisecond)
	end

	if not Runner.NotesOnly then
		Runner.Host.Hud.Init()
		Attempt.TimeStarted = Runner.Host.Ticks()

		if not Runner.EventsConnected then
			Runner.EventsConnected = true
			Signal.Connect(Runner.HitResultChanged, Runner.HitListener)
		end

		Signal.Fire(Runner.AttemptStatsUpdated, Attempt)
	end

	for _, Mod in Attempt.Modifiers do
		Mod.Active = false

		if Mod.ModifyMap ~= nil or Mod.ModifyRenderObject ~= nil then
			Mod.Activate(Mod, AsModifierAttempt(Attempt))
			Runner.Host.Hud.DisplayModifier(Mod)

			if Mod.ModifyMap then
				Mod.ModifyMap(AsModifierMap(Attempt.Map), AsModifierAttempt(Attempt))
			end
		end
	end

	local HasAutoplay = false

	for _, Mod in Attempt.Modifiers do
		HasAutoplay = HasAutoplay or Mod.Name == AutoplayName
	end

	Runner.AutoplayEnabled = HasAutoplay and not Attempt.IsReplay

	if Runner.AutoplayEnabled then
		for _, Mod in Attempt.Modifiers do
			if Mod.Name == AutoplayName then
				Mod.Activate(Mod, AsModifierAttempt(Attempt))

				if not Runner.NotesOnly then
					Runner.Host.Hud.DisplayModifier(Mod)
				end
			end
		end

		Runner.AutoplayHandler = AutoplayHandler.New(AsAutoplayAttempt(Attempt))
	else
		Runner.AutoplayHandler = nil
	end

	-- The owner panel's auto (Hooks): autoplay that misses the notes its plan gives. With anything wrong in the plan, the run
	-- plays normally.
	Runner.OwnerAuto = nil

	-- (never in a VS round's song: VS is played by hand)
	if Hooks.OwnerAuto and not HasAutoplay and not Attempt.IsReplay and not Attempt.IsLive and not Runner.NotesOnly
		and not (Attempt :: any).Versus
	then
		const Notes = Attempt.Objects[ObjectType.Note]
		const Asked, Plan = pcall(Hooks.OwnerAuto, Attempt, Notes)

		if Asked and type(Plan) == "table" and type(Plan.Misses) == "table" and type(Plan.Path) == "table" and Notes and #Plan.Path == #Notes then
			const Built, Handler = pcall(AutoplayHandler.New, ({ Map = { Notes = Plan.Path } } :: any) :: AutoplayHandler.AutoplayAttempt)

			if Built then
				Runner.OwnerAuto = Plan.Misses
				Runner.AutoplayEnabled = true
				Runner.AutoplayHandler = Handler
			end
		end
	end

	-- Someone watching live sees the same symbol the player does, though their own copy of the run doesn't play itself.
	if Attempt.IsLive and HasAutoplay then
		for _, Mod in Attempt.Modifiers do
			if Mod.Name == AutoplayName then
				Mod.Activate(Mod, AsModifierAttempt(Attempt))
				Runner.Host.Hud.DisplayModifier(Mod)
			end
		end
	end

	Runner.Settings = if Attempt.IsReplay then Attempt.Replays[1].Settings else SettingsManager.Settings

	const Settings = Runner.Settings :: SettingsProfile.SettingsProfile

	Runner.Host.Camera.Fov = Numbers.F32(Settings.FoV.Value)

	-- DEVIATION(phase3): the source sets Renderers[0] (NoteRenderer)'s multimesh to the skin's note mesh here; the view does that
	-- through Host.NoteMesh before the renderers are set up (temp until skinning support).
	if Runner.Host.NoteMesh then
		Runner.Host.NoteMesh()
	end

	for _, View in Runner.Host.Renderers do
		View.Setup(Attempt.Settings, SkinManager.Skin)
	end

	SoundManager.SetSongDimmed(false)
	SoundManager.BeginGameplayScope(Attempt.Map)
	SoundManager.UpdateVolume()

	if Attempt.Map.AudioBuffer ~= nil then
		SoundManager.LoadSong(Attempt.Map.AudioBuffer)
		SoundManager.SongSetPitch(Runner.Speed)
	end

	if Attempt.IsReplay then
		for _, Replay in Attempt.Replays do
			Replay.FrameIndex = 0
		end
	end

	Runner.Playing = true
	Runner.FirstFrame = true

	Logger.Log(`Playing map {Attempt.Map.Name}`)
end

-- The health after one hit or miss: a health modifier sets it (and is activated on its first use), otherwise the step grows
-- on a hit and the health falls by the step on a miss.
-- @src scripts/game/Runner.cs:updateHealth L627-655
const function UpdateHealth(Runner: Runner, IsHit: boolean)
	const Attempt = Runner.Attempt :: Attempt

	if Attempt.HasHealthModifier then
		for _, Mod in Attempt.Modifiers do
			if Mod.ApplyHealthResult then
				Attempt.Health = Mod.ApplyHealthResult(IsHit, Attempt.Health)

				if not Mod.Active then
					Mod.Activate(Mod, AsModifierAttempt(Attempt))
					Runner.Host.Hud.DisplayModifier(Mod)
				end
			end
		end
	elseif IsHit then
		Attempt.HealthStep = math.max(Attempt.HealthStep / 1.45, 15)
		Attempt.Health = math.min(100, Attempt.Health + Attempt.HealthStep / 1.75)
	else
		Attempt.Health = math.max(0, Attempt.Health - Attempt.HealthStep)
		Attempt.HealthStep = math.min(Attempt.HealthStep * 1.2, 100)
	end
end

-- Whether the attempt fails: the default is health at or below 0; a fail modifier answers it (the first one that answers
-- true stops the search), and a modifier whose answer differs from the default is activated.
-- @src scripts/game/Runner.cs:checkFail L657-682
const function CheckFail(Runner: Runner, IsHit: boolean, Health: number): boolean
	const Attempt = Runner.Attempt :: Attempt
	const DefaultFail = Health <= 0

	local FailCondition: boolean? = nil

	for _, Mod in Attempt.Modifiers do
		if Mod.CheckFailCondition then
			FailCondition = Mod.CheckFailCondition(IsHit, Health)

			if FailCondition ~= DefaultFail and not Mod.Active then
				Mod.Activate(Mod, AsModifierAttempt(Attempt))
				Runner.Host.Hud.DisplayModifier(Mod)
			end

			if FailCondition == true then
				break
			end
		end
	end

	if FailCondition ~= nil then
		return FailCondition
	end

	return DefaultFail
end

-- A judged note: the score, combo, multiplier, accuracy, hit info and health move with it, then the fail and queued-stop
-- checks run and the stats are sent.
-- @src scripts/game/Runner.cs:onHitResultChanged L549-625
const function OnHitResultChanged(Runner: Runner, NoteIndex: number, Result: HitResult.HitResult)
	const Attempt = Runner.Attempt :: Attempt
	const JudgmentProgress = Runner.HitResultProgressOverride or Attempt.Progress

	-- A replay's lateness is stored; a live hit's is the whole-millisecond gap (C# (int) cast) over the speed, as a float.
	const Lateness = if Attempt.IsReplay
		then Attempt.HitsInfo[NoteIndex + 1]
		else Numbers.F32((Numbers.TruncInt32(JudgmentProgress) - MapModule.GetNotes(Attempt.Map)[NoteIndex + 1].Millisecond) / Runner.Speed)

	const Overshoot = Numbers.F32(math.max(0, Numbers.F32(Lateness - 25)))
	const Factor = Numbers.F32(1 - Numbers.F32(Overshoot / 150))
	-- (uint) of a double saturates on .NET 10: a negative factor (a replay hit more than 175 ms late) scores 0.
	const HitScore = math.clamp(Numbers.Trunc(100 * Attempt.ComboMultiplier * Attempt.ModsMultiplier * Factor * ((Runner.Speed - 1) / 2.5 + 1)), 0, UintMax)
	const NoteColors = SkinManager.Skin.NoteColors

	if Result == HitResult.Hit then
		Attempt.Hits += 1
		Attempt.Sum += 1

		const Ratio = Numbers.F32(Numbers.F32(Numbers.F32(Attempt.Hits) / Numbers.F32(Attempt.Sum)) * 10000)

		Attempt.Accuracy = (Ratio // 1) / 100
		Attempt.Combo += 1
		Attempt.ComboMultiplierProgress += 1
		Attempt.LastHitColour = table.clone(NoteColors[(NoteIndex % #NoteColors) + 1])
		Attempt.Score = Numbers.Uint32(Attempt.Score + HitScore)

		if not Attempt.IsReplay then
			Stats.Instance.NotesHit += 1

			if Attempt.Combo > Stats.Instance.HighestCombo then
				Stats.Instance.HighestCombo = Attempt.Combo
			end

			Attempt.HitsInfo[NoteIndex + 1] = Lateness
		end

		if Attempt.ComboMultiplierProgress == Attempt.ComboMultiplierIncrement then
			if Attempt.ComboMultiplier < 8 then
				Attempt.ComboMultiplierProgress = if Attempt.ComboMultiplier == 7 then Attempt.ComboMultiplierIncrement else 0
				Attempt.ComboMultiplier += 1
			end
		end
	elseif Result == HitResult.Miss then
		Attempt.Misses += 1
		Attempt.Sum += 1

		const Ratio = Numbers.F32(Numbers.F32(Numbers.F32(Attempt.Hits) / Numbers.F32(Attempt.Sum)) * 10000)

		-- Mathf.Floor returns a float, so this division is float too.
		Attempt.Accuracy = Numbers.F32((Ratio // 1) / 100)
		Attempt.Combo = 0
		Attempt.ComboMultiplierProgress = 0
		Attempt.ComboMultiplier = math.max(1, Attempt.ComboMultiplier - 1)

		if not Attempt.IsReplay then
			Stats.Instance.NotesMissed += 1
			Attempt.HitsInfo[NoteIndex + 1] = -1
		end
	end

	if Result ~= HitResult.None then
		const IsHit = Result == HitResult.Hit

		UpdateHealth(Runner, IsHit)

		-- (the owner panel's auto never fails: its health keeps a sliver, and no fail condition ends it early)
		if Runner.OwnerAuto and Attempt.Health < 1 then
			Attempt.Health = 1
		end

		if not Attempt.IsReplay and Attempt.Health <= 0 and Attempt.Alive then
			Fail(Runner)
		end

		-- (a live view ends when the player's song does, with their final numbers: Game/LiveSpectate)
		if CheckFail(Runner, IsHit, Attempt.Health) and not Attempt.IsLive and not Runner.OwnerAuto then
			QueueStop(Runner)
		end
	end

	Signal.Fire(Runner.AttemptStatsUpdated, Attempt)
end

-- DEVIATION(phase3): _Ready (the node lookups of the HUD, camera, renderers, grid and cursor) is the view's; Host supplies them.
-- @src scripts/game/Runner.cs:Runner L8-697
const function New(Host: Host): Runner
	local Runner: Runner

	const function ListenHitResult(NoteIndex: number, Result: number)
		OnHitResultChanged(Runner, NoteIndex, Result)
	end

	const function PauseRunner(Value: boolean?)
		Pause(Runner, Value)
	end

	const function SeekRunner(Ms: number)
		Seek(Runner, Ms)
	end

	Runner = {
		Host = Host,
		Attempt = nil :: Attempt?,
		Map = nil :: MapTypes.Map?,
		Settings = nil :: SettingsProfile.SettingsProfile?,
		AutoplayHandler = nil :: AutoplayHandler.AutoplayHandler?,
		HitResultProgressOverride = nil :: number?,
		Speed = 1,
		Paused = false,
		Playing = false,
		StopQueued = false,
		NotesOnly = false,
		ObjectIndicesStart = {},
		ObjectIndicesEnd = {},
		AutoplayEnabled = false,
		LastFrame = Host.Ticks(),
		FirstFrame = true,
		EventsConnected = false,
		NoteTimestamps = {},
		AttemptStatsUpdated = Signal.New() :: Signal.Signal<Attempt>,
		SkipAvailable = Signal.New() :: Signal.Signal<Attempt>,
		HitResultChanged = Signal.New() :: Signal.Signal<number, number>,
		HitListener = ListenHitResult,
		Pause = PauseRunner,
		Seek = SeekRunner,
		Seeks = 0,
	}

	return Runner
end

-- The per-frame update. The delta is the tick clock's difference, so the argument is overwritten and never read.
-- @src scripts/game/Runner.cs:_Process L72-180
const function Process(Runner: Runner, Delta: number)
	const Now = Runner.Host.Ticks()

	Delta = (Now - Runner.LastFrame) / 1000000
	Runner.LastFrame = Now

	-- (a stop queued outside a frame, like a replay seek that re-judges the notes into a fail, is done here: it used to wait
	-- for a frame that never came, freezing the picture while the song played on)
	if Runner.StopQueued and not Runner.Playing then
		Runner.StopQueued = false
		Stop(Runner, true)

		return
	end

	if not Runner.Playing then
		-- (not in the source: the next playing frame is a resume)
		Resuming = true

		return
	end

	if Runner.FirstFrame then
		Runner.FirstFrame = false

		return
	end

	-- (not in the source: the pause menu's resume only lets the song go on, and Roblox takes a moment to really resume it,
	-- so the timeline waits for it as it does after a seek; the song used to stay about 40 ms behind the notes)
	if Resuming then
		Resuming = false
		WaitForSong = SoundManager.Song.Playing

		if WaitForSong then
			LastSongStart = os.clock()
		end
	end

	const Attempt = Runner.Attempt :: Attempt
	const Settings = Runner.Settings :: SettingsProfile.SettingsProfile
	-- this frame's advance of the timeline, in milliseconds
	const Advance = Delta * 1000 * Runner.Speed

	Attempt.Progress += Advance

	-- De-sync corrector

	-- (not in the source: a run lasts until a second after its last note, which is past the end of its song when the last note
	-- comes in the song's final second. With the song over there is nothing left to follow, so from just before its end the
	-- timeline runs on by the clock to the run's end. It used to keep waiting there for the stopped song, so the run never
	-- finished on its own: it sat on "Press Space" until you pressed it.)
	const SongEndMs = SoundManager.Song.Length * 1000
	const PastSong = SongEndMs > 0 and Attempt.Progress - Attempt.Settings.LocalOffset.Value >= SongEndMs - SongEndMargin

	if Attempt.Progress > 0 and Attempt.Progress < Attempt.Length and not Attempt.Stopped and not PastSong then
		const AudioDelay = Attempt.Progress - Attempt.Settings.LocalOffset.Value - (1000 * (Numbers.F32(SoundManager.SongPosition()) + SoundManager.TimeSinceLastMix()))

		-- if de-sync is over 40 milliseconds, then adjust the song until under 40 milliseconds. Here the bend is at most 1% of the
		-- speed (the source bends by the whole delay, up to 50%: an audible pitch jump at normal speed), and a de-sync over 150 ms
		-- (a stall) is fixed with one seek instead, at most once a second.
		const Drift = math.abs(AudioDelay / Runner.Speed)

		const Settling = os.clock() - LastSongStart < 1.5

		-- (not in the source: after a seek, a start part-way into the song or a resume, Roblox takes 50-150 ms to really start
		-- the song, and its position stands still until then. The timeline waits with it, so the picture starts once, with
		-- the music: it used to move on, stop when it got 15 ms ahead, then move again. At most SongWaitLimit.)
		const Live = Attempt.IsLive

		if WaitForSong and (SoundManager.SongMoving() or os.clock() - LastSongStart >= SongWaitLimit) then
			-- (a live view: how long the song took to move this time, for where its next seek aims. Only a wait that was one:
			-- a song started before the song's time 0 is only looked at here once the lead-in is over, long after it moved)
			if Live and SoundManager.SongMoving() and os.clock() - LastSongStart < SongWaitLimit + 0.1 then
				LiveSongLag = math.clamp((LiveSongLag + (os.clock() - LastSongStart)) / 2, 0.03, 0.25)
			end

			WaitForSong = false
		end

		if WaitForSong then
			if not Live then
				Attempt.Progress -= Advance
			end
		elseif not Live and Settling and AudioDelay / Runner.Speed > 6 then
			-- Roblox starts a song (or a seek in it) 50-150 ms after it is asked: just after a start or seek the game waits for
			-- the song instead of bending the pitch to catch it up (only when the game is ahead, so no note is skipped). It gives
			-- back at most this frame's advance, so the picture never steps backward (snapping onto the song stepped it back
			-- every few frames at high frame rates: a forward-back shudder until the song moved). (Not in the source: it slows
			-- in proportion to how far ahead it is, from 95% of its speed 6 ms ahead to a stop 30 ms ahead, so the picture eases
			-- down and back up. It used to stop dead 15 ms ahead, and as a song's first steps come unevenly it stopped and went
			-- several times in a row.)
			const Over = AudioDelay - 6 * Runner.Speed

			Attempt.Progress -= math.min(Over, math.max(Advance, 0) * math.clamp(Over / Runner.Speed / 24, 0.05, 1))
		elseif not Live and Settling and Drift > 6 and Drift <= 40 then
			-- once the song moves, the timeline eases onto it, at most 5% slower or faster, instead of jumping
			-- (a frame that took no time has no room to ease in; math.clamp errors on a reversed range)
			const Room = 0.05 * math.max(Advance, 0)

			Attempt.Progress -= math.clamp(AudioDelay - math.sign(AudioDelay) * 6 * Runner.Speed, -Room, Room)
		elseif Drift > 150 and os.clock() - LastResync > 1 and (not Live or os.clock() - LastSongStart > 1) then
			LastResync = os.clock()
			SoundManager.SongSetPitch(Runner.Speed)
			-- (not in the source: this frame's advance is taken back first, so the song is moved to where the picture stands and
			-- the picture waits there for it. A live view's picture goes on and only its song is moved.)
			if not Live then
				Attempt.Progress -= Advance
			end

			SyncSongPosition(Runner)
		elseif Drift > math.max(40, Delta) then
			-- (set only when it changes: past 40 ms the bend is always the whole 1%, and it was written again every frame)
			const Bent = Runner.Speed * (1 + math.clamp(AudioDelay / Runner.Speed / 4000, -0.01, 0.01))

			if math.abs(SoundManager.Song.PitchScale - Bent) > Epsilon then
				SoundManager.SongSetPitch(Bent)
			end
		elseif math.abs(SoundManager.Song.PitchScale - Runner.Speed) > Epsilon then
			SoundManager.SongSetPitch(Runner.Speed)
		end
	end

	-- Save replay frame

	if Runner.AutoplayEnabled then
		Runner.Host.Cursor.UpdateAutoplayCursor(AutoplayHandler.GetCursorPosition(Runner.AutoplayHandler :: AutoplayHandler.AutoplayHandler, Attempt.Progress))
		ProcessAutoplayHits(Runner)
	end

	-- if not paused & record replays on & not a temporary map & time from now and last replay frame was 60 frames apart
	-- The source's `!=` compares the frame's cursor array with a new array by reference, which is always unequal, so
	-- the cursor is not checked.
	if not Runner.AutoplayEnabled and not Attempt.Stopped and Settings.RecordReplays.Value and not Attempt.Map.Ephemeral and Now - Attempt.LastReplayFrame >= ReplayFrameTicks then
		-- (the next frame is due a period after this one was due, not a period after the frame that took it, so frames come an
		-- even 60 a second at any frame rate: from the frame's own time, at 240 FPS a frame a hair early made the gap five frames
		-- instead of four, and replays came out at about 50 a second, unevenly. After a long gap it starts again from now.)
		Attempt.LastReplayFrame = if Now - Attempt.LastReplayFrame < 2 * ReplayFrameTicks then Attempt.LastReplayFrame + ReplayFrameTicks else Now

		table.insert(Attempt.ReplayFrames, { Numbers.F32(Attempt.Progress), Attempt.CursorPosition.x, Attempt.CursorPosition.y })
	end

	-- Song state check

	if Attempt.Map.AudioBuffer ~= nil then
		const OffsetProgress = Attempt.Progress - Attempt.Settings.LocalOffset.Value
		const SongEnd = SoundManager.Song.Length * 1000

		-- (a song that just ran out isn't started again for its last moment: see SongEndMargin)
		if not SoundManager.Song.Playing and OffsetProgress >= 0 and OffsetProgress < SongEnd - SongEndMargin then
			SoundManager.SongPlay(Numbers.F32(Numbers.F32(OffsetProgress) / 1000))
			LastSongStart = os.clock()
			-- (a start part-way into the song is a seek in Roblox, slow to begin: the timeline waits for it. A start from the
			-- beginning begins at once and is eased onto as before.)
			WaitForSong = OffsetProgress > 100
		elseif SoundManager.Song.Playing and OffsetProgress >= SongEnd then
			SoundManager.SongStop()
		end
	end

	-- Skip check

	const Notes = MapModule.GetNotes(Attempt.Map)
	const PassedNotes = Runner.ObjectIndicesStart[ObjectType.Note]
	const NextNoteMillisecond = if PassedNotes >= #Notes then IntMax else Notes[PassedNotes + 1].Millisecond

	-- (no "Press Space" when the skip wouldn't move you forward, as near the end of a break with a long approach time)
	if NextNoteMillisecond - Attempt.Progress >= Constants.BreakTime * Runner.Speed
		and NextNoteMillisecond - Settings.ApproachTime.Value * 1500 * Runner.Speed - Attempt.Progress >= 500 * Runner.Speed
	then
		const LastNoteMillisecond = if PassedNotes > 0 then Notes[PassedNotes].Millisecond else 0
		const SkipWindow = NextNoteMillisecond - Constants.BreakTime - LastNoteMillisecond

		-- only allow skipping if i'm gonna allow it for at least 1 second
		if SkipWindow >= 1000 * Runner.Speed then
			if not Attempt.CanSkip then
				Attempt.CanSkip = true
				Signal.Fire(Runner.SkipAvailable, Attempt)
			end
		end
	else
		Attempt.CanSkip = false
	end

	-- Object processing

	ProcessObjects(Runner)
	RenderObjects(Runner, Delta)

	if Runner.StopQueued or (Attempt.Progress >= Attempt.Length and not Attempt.IsReplay) then
		Runner.StopQueued = false
		Stop(Runner, true)
	end
end

return {
	New = New,
	Process = Process,
	ProcessObjects = ProcessObjects,
	RenderObjects = RenderObjects,
	Play = Play,
	Pause = Pause,
	Skip = Skip,
	Seek = Seek,
	Fail = Fail,
	GiveUp = GiveUp,
	QueueStop = QueueStop,
	Stop = Stop,
	Hooks = Hooks,
}
