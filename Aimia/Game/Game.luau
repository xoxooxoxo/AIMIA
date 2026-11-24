--!strict
--!optimize 2

--[[
	Game.cs: the game scene's logic without Roblox. The attempt the scene plays (the results scene reads it), the start and the
	restart of an attempt, the scene's input handlers (mouse, pause, skip, replay viewer, fade, pushback) and the load of an
	attempt into the runner. The view (UI/Scenes/Game) builds one Session per run and calls these functions with it.

	Representation
		Game is one module table: Attempt is the attempt the scene plays (nil before the first Play), StartQueued is true from
		Play until the scene loads, FadeoutToggleValue is the fade kept when the fade is toggled off (-1 until then), Instance is
		the Session of the loaded scene (nil when it is not loaded), Hooks are the scene loader's functions.
		Session is one run's objects: the runner, the cursor and replay managers, the pause menu, the playtest overlay and the
		mouse mode setter. The view creates it at load and drops it at unload.

	Design Notes
		Play and Restart load through Hooks, which SceneManager sets, so this module never requires UI.
		Play takes no Players: every source caller passes null, so Attempt.New gets nil.
		Restart passes replays only for a replay: Attempt.New treats any replay list as a replay, and a play's Replays is an
		empty array here.
		SettingsManager.Shown is never set by the source (the settings menu keeps its own Shown), so the first branch of the pause
		toggle is kept and never taken.
		TempMode is Constants.TempMapMode, which is false: the playtest checks never pass.
		The handlers read Game.Attempt, the source's static Attempt, not the runner's copy (they differ only during a restart).
]]

const AttemptModule = require("./Attempt")
const CameraMode = require("./Camera/CameraMode")
const Constants = require("../Constants")
const CursorManagerModule = require("./Managers/CursorManager")
const Lobby = require("../Multiplayer/Lobby")
const Logger = require("../Util/Logger")
const MapManager = require("../Map/MapManager")
const MapModule = require("../Map/Map")
const MapParser = require("../Map/MapParser")
const MapTypes = require("../Map/MapTypes")
const Modifier = require("./Modifiers/Modifier")
const Numbers = require("../Numbers")
const ObjectType = require("../Map/Objects/ObjectType")
const ReplayModule = require("../Map/Replay")
const ReplayManagerModule = require("./Managers/ReplayManager")
const RunnerModule = require("./Runner")
const SettingsItem = require("../Database/Settings/SettingsItem")
const SettingsManager = require("../SettingsManager")
const Stats = require("../Database/Stats")

export type GameHooks = {
	LoadScene: (Path: string, SkipTransition: boolean?) -> (),
	ReloadScene: () -> (),
	-- a run's results are about to load: true takes them over (the Handheld's, for a VS round's run and a watched one in VS)
	SkipResults: ((Attempt: AttemptModule.Attempt) -> boolean)?,
}

-- The pause menu: its Shown flag and ShowMenu(Show, Instant) and HideMenu(Instant) (UI/Game/PauseMenu).
export type Menu = {
	Shown: boolean,
	ShowMenu: (Show: boolean, Instant: boolean?) -> (),
	HideMenu: (Instant: boolean?) -> (),
}

-- The playtest overlay: PlaytestInit and UpdatePlaytestOverlay(Show) (UI/Game/PlaytestOverlay).
export type Playtest = {
	PlaytestInit: boolean,
	UpdatePlaytestOverlay: (Show: boolean) -> (),
}

-- One run's objects. SetMouseMode takes the source's Input.MouseMode names; HideSettings hides the settings menu.
export type Session = {
	Runner: RunnerModule.Runner,
	Cursor: CursorManagerModule.Manager,
	Replay: ReplayManagerModule.Manager,
	Menu: Menu,
	Playtest: Playtest,
	SetMouseMode: (Mode: string) -> (),
	HideSettings: () -> (),
}

const GamePath = "res://scenes/game.tscn"
const AutoplayName = "Autoplay"
const ModeNames = { "NONE", "RECORD", "PLAYBACK" }

-- The absolute mouse position's scale to the nightly's 1:1 (0.582f in the source).
const AbsoluteScale = Numbers.F32(0.582)
-- The distance's divisor (57.5 in the source).
const DistanceDivisor = 57.5

const Hooks = {} :: GameHooks

const Game = {
	Attempt = nil :: AttemptModule.Attempt?,
	StartQueued = false,
	FadeoutToggleValue = -1,
	Instance = nil :: Session?,
	Hooks = Hooks,
}

-- Whether the attempt has the Autoplay modifier (the source's Exists(mod is AutoplayModifier)).
-- DEVIATION(phase3): modifiers are tables, so the check is by name, as Runner does.
const function HasAutoplay(Attempt: AttemptModule.Attempt): boolean
	for _, Mod in Attempt.Modifiers do
		if Mod.Name == AutoplayName then
			return true
		end
	end

	return false
end

-- Starts a new attempt of the map (Game.Play). A start while one is queued does nothing. Versus, for a VS round's song
-- (Multiplayer/Versus), goes on the attempt: no pause, no restart and no skip but the last one in it.
-- @src scripts/scenes/Game.cs:Play L211-230
function Game.Play(Map: MapTypes.Map, Speed: number, StartFrom: number, CameraModeValue: CameraMode.CameraMode, Mods: { Modifier.Modifier }, Replays: { ReplayModule.Replay }?, Versus: { Lobby: string, Round: number }?)
	if Game.StartQueued then
		return
	end

	Game.StartQueued = true

	const ParsedMap = MapParser.Decode(Map.FolderPath) :: MapTypes.Map

	Game.Attempt = AttemptModule.New(ParsedMap, Speed, StartFrom, CameraModeValue, Mods, nil, Replays)
	;(Game.Attempt :: any).Versus = if Replays == nil then Versus else nil
	Hooks.LoadScene(GamePath)
end

-- The settings F and P change: the ones the notes are drawn with. In a replay those are a copy (Attempt.New), so watching
-- one never touches the player's settings.
const function ViewSettings(): SettingsProfile.SettingsProfile
	const Attempt = Game.Attempt :: AttemptModule.Attempt

	return Attempt.Settings
end

-- Ends the running attempt (failed, not saved) and starts it again from the map file, then reloads the scene.
-- @src scripts/scenes/Game.cs:Restart L232-250
function Game.Restart()
	const Session = Game.Instance :: Session
	const OldAttempt = Game.Attempt :: AttemptModule.Attempt

	-- (nothing a watcher presses changes the song they're watching, and a VS round's song plays once, from its start)
	if OldAttempt.IsLive or (OldAttempt :: any).Versus then
		return
	end

	-- (anyone watching stays for the new run instead of seeing this one end: Game/LiveSpectate tells the server it's a restart.
	-- A run that has just ended on its own is over as it ended: it isn't a restart to anyone, and its numbers still go up.)
	if not OldAttempt.Stopped then
		(OldAttempt :: any).Restarting = true
		RunnerModule.Fail(Session.Runner)
		RunnerModule.Stop(Session.Runner, false)
	end

	const ParsedMap = MapParser.Decode(OldAttempt.Map.FolderPath) :: MapTypes.Map
	const Replays = if OldAttempt.IsReplay then OldAttempt.Replays else nil

	Game.Attempt = AttemptModule.New(ParsedMap, OldAttempt.Speed, OldAttempt.StartFrom, OldAttempt.CameraMode, OldAttempt.Modifiers, OldAttempt.Players, Replays)
	Hooks.ReloadScene()
end

-- The mouse moves the cursor: by the relative motion, or with absolute input by the position from the window's centre. A
-- replay, a paused or stopped run and autoplay ignore it. Each motion adds its distance in mm.
-- @src scripts/scenes/Game.cs:OnMouseMove L47-66
function Game.MouseMove(Session: Session, Relative: vector, Absolute: vector, WindowSize: vector)
	const Attempt = Game.Attempt :: AttemptModule.Attempt

	-- (and the owner panel's auto, which is autoplay too: Runner.Hooks)
	if not Session.Runner.Playing or Attempt.IsReplay or HasAutoplay(Attempt) or Session.Runner.OwnerAuto ~= nil then
		return
	end

	-- Vertical Sensitivity shapes the input here, so replays, autoplay and watchers never see it.
	const Vertical = Attempt.Settings.VerticalSensitivity.Value
	const Shape = vector.create(1, if math.isfinite(Vertical) then math.clamp(Vertical, 0.25, 2) else 1, 1)

	if Attempt.Settings.AbsoluteInput.Value then
		-- Vector2i / 2 is an integer division, so the centre is floored before the subtraction.
		const Centre = vector.create(WindowSize.x // 2, WindowSize.y // 2, 0)

		CursorManagerModule.UpdateCursor(Session.Cursor, (Absolute - Centre) * AbsoluteScale * Shape)
	else
		CursorManagerModule.UpdateCursor(Session.Cursor, Relative * Shape)
	end

	Attempt.DistanceMM += Numbers.F32(vector.magnitude(Relative)) / Attempt.Settings.Sensitivity.Value / DistanceDivisor
end

-- Pauses the run (R held in a song, Client.Controllers.Handheld; Escape no longer does, Game/PlayerInputController): any pause disqualifies the pass, then the pause
-- menu toggles. Upstream the settings menu's branch never runs (SettingsManager.Shown stays false).
-- DEVIATION: upstream keeps the pass after a pause before the first note or after the last one; here any pause counts (the
-- owner's rule, 2026-11-07).
-- @src scripts/scenes/Game.cs:OnTogglePaused L70-87
function Game.TogglePaused(Session: Session)
	const Attempt = Game.Attempt :: AttemptModule.Attempt

	-- (a VS round's song has no pause: Escape does nothing in it, and R held lets it go, Client.Controllers.Handheld)
	if Attempt.IsLive or (Attempt :: any).Versus then
		return
	end

	-- (the results then say DISQUALIFIED, and neither LiveSpectate nor the server's song lists take the run: both want PASSED.
	-- A finished run, its results on the way, keeps what it had.)
	if not Attempt.Stopped then
		Attempt.Qualifies = false
	end

	if SettingsManager.Shown then
		Session.HideSettings()
	else
		if Constants.TempMapMode and not Session.Playtest.PlaytestInit then
			return
		end

		Session.Menu.ShowMenu(not Session.Menu.Shown)
	end
end

-- Space: a replay pauses its playback, the temporary map mode opens its playtest menu, otherwise the run skips to the next
-- note (not with several players in the lobby).
-- @src scripts/scenes/Game.cs:OnPauseOrSkipPressed L105-127
function Game.PauseOrSkipPressed(Session: Session)
	const Attempt = Game.Attempt :: AttemptModule.Attempt

	if Attempt.IsLive then
		return
	end

	if Attempt.IsReplay then
		ReplayManagerModule.TogglePause(Session.Replay)
	elseif not Session.Playtest.PlaytestInit and Constants.TempMapMode then
		Session.Playtest.UpdatePlaytestOverlay(false)
	else
		if #Lobby.Players > 1 then
			return
		end

		-- (in a VS round only the end skips, to the results a moment sooner: a skip anywhere else would run ahead of the others)
		if (Attempt :: any).Versus and Session.Runner.ObjectIndicesStart[ObjectType.Note] < #MapModule.GetNotes(Attempt.Map) then
			return
		end

		RunnerModule.Skip(Session.Runner)
	end
end

-- F2: shows or hides the replay viewer of a replay.
-- @src scripts/scenes/Game.cs:OnToggleReplayViewerVisibility L89-95
function Game.ToggleReplayViewer(Session: Session)
	const Attempt = Game.Attempt :: AttemptModule.Attempt

	if Attempt.IsReplay and not Attempt.IsLive then
		ReplayManagerModule.ShowReplayViewer(Session.Replay, Attempt)
	end
end

-- F3: shows or hides the orthogonal camera of a replay.
-- @src scripts/scenes/Game.cs:OnToggleShowOrthonogalCamera L97-103
function Game.ToggleOrthogonalCamera(Session: Session)
	const Attempt = Game.Attempt :: AttemptModule.Attempt

	if Attempt.IsReplay and not Attempt.IsLive then
		ReplayManagerModule.ShowOrthogonalCamera(Session.Replay, Attempt)
	end
end

-- The fade each settings profile had when F last turned it off. Kept per profile (weak keys: a replay's or a watched player's
-- copy goes with its attempt), so turning the fade back on in your own song never brings someone else's fade into your settings.
const KeptFade: { [unknown]: number } = setmetatable({}, { __mode = "k" }) :: any

-- F: the note fade-out. On, it stores the fade and sets it to 0; off, it restores the stored fade (100 at first).
-- @src scripts/scenes/Game.cs:OnToggleFade L133-148
function Game.ToggleFade()
	const Attempt = Game.Attempt :: AttemptModule.Attempt

	-- (nothing a watcher presses changes the song they're watching: they see the player's own fade)
	if Attempt.IsLive then
		return
	end

	const Settings = ViewSettings()

	local Value: number

	if Settings.FadeOut.Value > 0 then
		KeptFade[Settings] = Settings.FadeOut.Value
		Game.FadeoutToggleValue = Settings.FadeOut.Value
		Value = 0
	else
		Value = KeptFade[Settings] or 100
	end

	SettingsItem.SetValue(Settings.FadeOut, Value)
end

-- P: toggles the pushback setting.
-- @src scripts/scenes/Game.cs:OnTogglePushback L150-150
function Game.TogglePushback()
	const Attempt = Game.Attempt :: AttemptModule.Attempt

	-- (nothing a watcher presses changes the song they're watching: they see the player's own pushback)
	if Attempt.IsLive then
		return
	end

	const Settings = ViewSettings()

	SettingsItem.SetValue(Settings.Pushback, not Settings.Pushback.Value)
end

-- The mouse mode a run starts with (Input.MouseMode in Load): visible for absolute input and replays, captured otherwise.
-- @src scripts/scenes/Game.cs:Load L154-209
function Game.MouseModeOf(Attempt: AttemptModule.Attempt): string
	return if Attempt.Settings.AbsoluteInput.Value or Attempt.IsReplay then "Visible" else "Captured"
end

-- The mouse mode once the pause menu hides: visible for a replay whose viewer shows, confined and hidden for absolute input,
-- captured otherwise (PauseMenu.ShowMenu(false)).
-- @src scripts/game/ui/PauseMenu.cs:ShowMenu L41-93
function Game.ResumeMouseMode(Attempt: AttemptModule.Attempt, ViewerVisible: boolean): string
	if Attempt.IsReplay and ViewerVisible then
		return "Visible"
	elseif Attempt.Settings.AbsoluteInput.Value then
		return "ConfinedHidden"
	end

	return "Captured"
end

-- Loads the attempt into the runner (Game.Load after the scene has built the session): the mouse mode, the runner's attempt,
-- the replay viewer and the replay mode, the start of the run, and the attempt's count (not for a replay).
-- @src scripts/scenes/Game.cs:Load L154-209
function Game.Load(Session: Session)
	const Attempt = Game.Attempt :: AttemptModule.Attempt
	const Runner = Session.Runner
	const Replay = Session.Replay

	Game.Instance = Session
	Session.SetMouseMode(Game.MouseModeOf(Attempt))

	Runner.Attempt = Attempt
	ReplayManagerModule.InitReplayLength(Replay)
	const ShowsViewer = Attempt.IsReplay and not Attempt.IsLive

	ReplayManagerModule.ShowReplayViewer(Replay, Attempt, ShowsViewer)
	ReplayManagerModule.ShowOrthogonalCamera(Replay, Attempt, ShowsViewer)

	Session.Menu.HideMenu(true)

	-- A watcher has no seeker, and still needs the mouse for the X.
	if Attempt.IsLive then
		Session.SetMouseMode("Visible")
	end

	if Attempt.IsReplay then
		Replay.CurrentMode = ReplayManagerModule.Mode.PLAYBACK
	elseif Attempt.Settings.RecordReplays.Value and not HasAutoplay(Attempt) then
		ReplayManagerModule.NewReplay(Replay, Attempt)
		Replay.CurrentMode = ReplayManagerModule.Mode.RECORD
	else
		Replay.CurrentMode = ReplayManagerModule.Mode.NONE
	end

	Logger.Log(`Replay Mode: {ModeNames[Replay.CurrentMode + 1]}`)

	RunnerModule.Play(Runner)
	Game.StartQueued = false

	if not Attempt.IsReplay then
		Stats.Instance.Attempts += 1
		Attempt.Map.PlayCount += 1
		MapManager.Update(Attempt.Map)
	end

	if Constants.TempMapMode and not Session.Playtest.PlaytestInit then
		Session.Playtest.UpdatePlaytestOverlay(true)
	end
end

-- Forgets the loaded session when the scene leaves.
function Game.Unload()
	Game.Instance = nil
end

-- Whether a run is playing (KeybindsManager and the quit hook read it).
function Game.IsPlaying(): boolean
	const Session = Game.Instance

	return Session ~= nil and Session.Runner.Playing
end

-- Stops the loaded run, loading the results when Results is not false (the quit hook's Runner.Stop).
function Game.StopRun(Results: boolean)
	RunnerModule.Stop((Game.Instance :: Session).Runner, Results)
end

return Game
