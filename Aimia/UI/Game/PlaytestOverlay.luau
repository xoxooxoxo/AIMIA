--!strict
--!optimize 2

--[[
	The playtest overlay (scripts/game/ui/PlaytestOverlay.cs) on the game scene's PlaytestOverlay node: the playtest menu with its
	spin toggle, the start and speed fields and the play button. Showing it pauses the run; hiding it stops the run and starts
	the attempt again with the fields' values (the scene reloads).

	Representation
		New returns the overlay table: PlaytestInit (the source's flag), UpdatePlaytestOverlay(Show), which the game module calls,
		and Destroy, which disconnects the fields and the button.

	Design Notes
		Only the temporary map mode shows this overlay, and that mode is not ported (Constants.TempMapMode is false), so nothing
		calls UpdatePlaytestOverlay(true) yet.
		DEVIATION(phase3): Aimia.TempCam and Aimia.TempMods are the temporary map mode's statics, not ported here; the overlay
		keeps the source's defaults (a lock camera and the NoFail modifier).
		DEVIATION(platform): the source's Input.WarpMouse(centre) is not done (see UI/Game/PauseMenu).
		The speed parameter (--sp) does not exist in this port: its default "1" is the field's text. The start parameter (--sf)
		defaults to "" in the source, which parses as 0 (the field then reads 0:00).
]]

const AttemptModule = require("../../Game/Attempt")
const CameraLock = require("../../Game/Camera/CameraLock")
const CameraMode = require("../../Game/Camera/CameraMode")
const CameraSpin = require("../../Game/Camera/CameraSpin")
const DotnetNumber = require("../../Dotnet/Number")
const Game = require("../../Game/Game")
const Items = require("../Item")
const MapParser = require("../../Map/MapParser")
const MapTypes = require("../../Map/MapTypes")
const MenuCursor = require("../MenuCursor")
const Modifier = require("../../Game/Modifiers/Modifier")
const NoFailModifier = require("../../Game/Modifiers/NoFailModifier")
const Nodes = require("../Nodes")
const PlaytestText = require("./PlaytestText")
const ReplayManagerModule = require("../../Game/Managers/ReplayManager")
const RunnerModule = require("../../Game/Runner")
const SettingsManager = require("../../SettingsManager")
const SettingsProfile = require("../../Database/Settings/SettingsProfile")
const SoundManager = require("../../Audio/SoundManager")

type Item = Items.Item

export type PlaytestOverlay = {
	Item: Item,
	Runner: RunnerModule.Runner,
	Replay: ReplayManagerModule.Manager,
	SetMouseMode: (Mode: string) -> (),
	PlaytestInit: boolean,
	Connections: { () -> () },
	UpdatePlaytestOverlay: (Show: boolean) -> (),
	Destroy: () -> (),
}

-- Aimia.TempCam and Aimia.TempMods of the source, with their defaults (see the header).
local TempCam: CameraMode.CameraMode = CameraLock()
const TempMods = { NoFailModifier() :: Modifier.Modifier }

-- Aimia.SpeedParameter: the speed parameter's default (see the header).
const SpeedParameter = "1"

-- Shows or hides the overlay and pauses or resumes the run (UpdatePlaytestOverlay). Hiding stops the run and starts the attempt
-- again with the start and speed the fields hold.
-- @src scripts/game/ui/PlaytestOverlay.cs:UpdatePlaytestOverlay L24-85
const function UpdatePlaytestOverlay(Overlay: PlaytestOverlay, Show: boolean)
	const Attempt = Game.Attempt :: AttemptModule.Attempt
	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile
	const UseCursor = Settings.UseCursorInMenus.Value

	Overlay.Runner.Playing = not Show

	SoundManager.SongSetPitch(Attempt.Speed)
	SoundManager.SongSetPaused(not Overlay.Runner.Playing)

	Nodes.Set(Overlay.Item, "visible", Show)
	MenuCursor.UpdateVisible(MenuCursor.Instance :: MenuCursor.CursorState, Show and UseCursor)

	if Show then
		Overlay.SetMouseMode(if UseCursor then "Hidden" else "Visible")
	else
		Overlay.SetMouseMode(Game.ResumeMouseMode(Attempt, Overlay.Replay.ViewerVisible))
	end

	const Holder = Nodes.GetNode(Overlay.Item, "VB")
	const SpinCheck = Nodes.Get(Nodes.GetNode(Holder, "SpinCheck"), "button_pressed") == true

	TempCam = if SpinCheck then CameraSpin() else CameraLock()

	const StartFromEdit = Nodes.GetNode(Holder, "StartFrom/LineEdit")
	const SpeedEdit = Nodes.GetNode(Holder, "Speed/LineEdit")

	Overlay.PlaytestInit = not Show

	if not Overlay.PlaytestInit and Settings.OptionalPlaytestParameters.Value then
		-- The start parameter parses as 0 (double.TryParse fails on ""), so the field shows 0:00 for it.
		Nodes.Set(StartFromEdit, "text", PlaytestText.ApplyStartFrom("0", Attempt.Map.Length))
		Nodes.Set(SpeedEdit, "text", SpeedParameter)
	end

	if not Show then
		RunnerModule.Stop(Overlay.Runner, false)

		local SpeedValue = 1.0
		const SpeedParsed, SpeedDouble = DotnetNumber.TryParseDouble(Nodes.Get(SpeedEdit, "text") :: string)

		if SpeedParsed then
			SpeedValue = SpeedDouble
		end

		const Map = MapParser.Decode(Attempt.Map.FolderPath) :: MapTypes.Map
		const StartFrom = PlaytestText.StartFromSeconds(Nodes.Get(StartFromEdit, "text") :: string) * 1000

		Game.Attempt = AttemptModule.New(Map, SpeedValue, StartFrom, TempCam, TempMods)
		Game.Hooks.ReloadScene()
	end
end

-- The start field's text is checked when it loses focus or is submitted.
-- @src scripts/game/ui/PlaytestOverlay.cs:ApplyStartFrom L87-134
const function CheckStartFrom(StartFromEdit: Item)
	const Attempt = Game.Attempt :: AttemptModule.Attempt
	const Text = Nodes.Get(StartFromEdit, "text") :: string

	Nodes.Set(StartFromEdit, "text", PlaytestText.ApplyStartFrom(Text, Attempt.Map.Length))
end

-- The playtest overlay of a run, hidden at first. Its play button hides the overlay.
-- @src scripts/game/ui/PlaytestOverlay.cs:_Ready L14-22
const function New(Item: Item, Runner: RunnerModule.Runner, Replay: ReplayManagerModule.Manager, SetMouseMode: (Mode: string) -> ()): PlaytestOverlay
	local Overlay: PlaytestOverlay

	const function UpdateOverlay(Show: boolean)
		UpdatePlaytestOverlay(Overlay, Show)
	end

	const function Destroy()
		for _, Disconnect in Overlay.Connections do
			Disconnect()
		end
	end

	Overlay = {
		Item = Item,
		Runner = Runner,
		Replay = Replay,
		SetMouseMode = SetMouseMode,
		PlaytestInit = false,
		Connections = {},
		UpdatePlaytestOverlay = UpdateOverlay,
		Destroy = Destroy,
	}

	const Holder = Nodes.GetNode(Item, "VB")
	const StartFromEdit = Nodes.GetNode(Holder, "StartFrom/LineEdit")
	const PlayButton = Nodes.GetNode(Holder, "PlayButton")

	table.insert(Overlay.Connections, Nodes.Connect(StartFromEdit, "focus_exited", function()
		CheckStartFrom(StartFromEdit)
	end))
	table.insert(Overlay.Connections, Nodes.Connect(StartFromEdit, "text_submitted", function()
		CheckStartFrom(StartFromEdit)
	end))
	table.insert(Overlay.Connections, Nodes.Connect(PlayButton, "pressed", function()
		UpdateOverlay(false)
	end))

	return Overlay
end

return New
