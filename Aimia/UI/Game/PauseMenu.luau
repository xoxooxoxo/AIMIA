--!strict
--!optimize 2

--[[
	The pause menu (scripts/game/ui/PauseMenu.cs) on the game scene's Menu node: the resume, restart, settings and give-up
	buttons, the hide button over the dimmed background, and the fade. ShowMenu pauses or resumes the run, the audio and the
	menu cursor with it, and sets the mouse for the state.

	Representation
		New returns the menu table: Shown, ShowMenu(Show, Instant), HideMenu(Instant), and Destroy, which disconnects the buttons.
		Runner and Replay are the run's managers; SetMouseMode takes the mouse mode names of UI/Scenes/Game.

	Design Notes
		DEVIATION(platform): the source warps the captured mouse to the centre when the menu shows; Roblox cannot warp a locked
		cursor, so the mouse is freed while the menu shows (the native cursor is hidden when the menu cursor is on, as upstream).
		Upstream keeps the mouse captured while paused and only resets it on resume, which is the same call here.
]]

const AttemptModule = require("../../Game/Attempt")
const Game = require("../../Game/Game")
const Items = require("../Item")
const MenuCursor = require("../MenuCursor")
const Nodes = require("../Nodes")
const ReplayManagerModule = require("../../Game/Managers/ReplayManager")
const RunnerModule = require("../../Game/Runner")
const SettingsManager = require("../../SettingsManager")
const SettingsMenu = require("../SettingsMenu")
const LiveSpectate = require("../../Game/LiveSpectate")
const SettingsProfile = require("../../Database/Settings/SettingsProfile")
const SoundManager = require("../../Audio/SoundManager")
const Tween = require("../Tween")

type Item = Items.Item

export type PauseMenu = {
	Item: Item,
	Runner: RunnerModule.Runner,
	Replay: ReplayManagerModule.Manager,
	SetMouseMode: (Mode: string) -> (),
	Shown: boolean,
	Connections: { () -> () },
	ShowMenu: (Show: boolean, Instant: boolean?) -> (),
	HideMenu: (Instant: boolean?) -> (),
	Destroy: () -> (),
}

const FadeTime = 0.25
const Opaque = 1
const Transparent = 0

-- The running fade of each menu node. The game scene is kept between runs and every run's pause menu wraps the same Menu
-- node, so the fade still running from the last show or hide (or from the last run) is stopped before the next one starts:
-- left running, its end set the menu visible again over a run restarted within its 0.25 s.
const Fades: { [Item]: Tween.Tween } = setmetatable({}, { __mode = "k" }) :: any

-- Pauses or resumes the run and shows or hides the menu (ShowMenu). Showing frees the mouse and makes the menu visible at
-- once; the fade sets Visible = Shown at its end.
-- @src scripts/game/ui/PauseMenu.cs:ShowMenu L41-93
const function ShowMenuOf(Menu: PauseMenu, Show: boolean, Instant: boolean?)
	Menu.Shown = Show
	Menu.Runner.Playing = not Show

	const Attempt = Menu.Runner.Attempt :: AttemptModule.Attempt
	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile
	const UseCursor = Settings.UseCursorInMenus.Value

	SoundManager.SongSetPitch(Attempt.Speed)
	SoundManager.SongSetPaused(not Menu.Runner.Playing)

	MenuCursor.UpdateVisible(MenuCursor.Instance :: MenuCursor.CursorState, Show and UseCursor)

	if Show then
		Nodes.Set(Menu.Item, "visible", true)
		Menu.SetMouseMode(if UseCursor then "Hidden" else "Visible")
	else
		Menu.SetMouseMode(Game.ResumeMouseMode(Attempt, Menu.Replay.ViewerVisible))
	end

	const Duration = if Instant == true then 0 else FadeTime
	const Running = Fades[Menu.Item]

	if Running then
		Tween.Kill(Running)
	end

	const Fade = Tween.Create(Menu.Item)

	Fades[Menu.Item] = Fade
	const Alpha = if Show then Opaque else Transparent
	const Fading = Tween.TweenProperty(Fade, Menu.Item, "modulate", { Color = { 1, 1, 1, Alpha } }, Duration)

	Tween.SetTweenerTrans(Fading, Tween.TransitionType.Quad)
	Tween.TweenCallback(Fade, function()
		Nodes.Set(Menu.Item, "visible", Show)
	end)
end

-- The pause menu of a run: its buttons drive the run (Hide and Resume close the menu, Restart reloads the attempt, Settings
-- opens the settings menu, Give up fails and stops the run). The menu starts hidden.
-- @src scripts/game/ui/PauseMenu.cs:_Ready L29-39
const function New(Item: Item, Runner: RunnerModule.Runner, Replay: ReplayManagerModule.Manager, SetMouseMode: (Mode: string) -> ()): PauseMenu
	local Menu: PauseMenu

	const function ShowMenu(Show: boolean, Instant: boolean?)
		ShowMenuOf(Menu, Show, Instant)
	end

	const function HideMenu(Instant: boolean?)
		ShowMenuOf(Menu, false, Instant)
	end

	const function Destroy()
		for _, Disconnect in Menu.Connections do
			Disconnect()
		end

		-- (its fade, still running, would land on the next run's menu on the same node)
		const Running = Fades[Menu.Item]

		if Running then
			Tween.Kill(Running)
			Fades[Menu.Item] = nil
		end
	end

	Menu = {
		Item = Item,
		Runner = Runner,
		Replay = Replay,
		SetMouseMode = SetMouseMode,
		Shown = false,
		Connections = {},
		ShowMenu = ShowMenu,
		HideMenu = HideMenu,
		Destroy = Destroy,
	}

	const Hide = Nodes.GetNode(Item, "Hide")
	const Resume = Nodes.GetNode(Item, "Holder/Resume")
	const Restart = Nodes.GetNode(Item, "Holder/Restart")
	const Settings = Nodes.GetNode(Item, "Holder/Settings")
	const Quit = Nodes.GetNode(Item, "Holder/Quit")

	table.insert(Menu.Connections, Nodes.Connect(Hide, "pressed", function()
		HideMenu()
	end))
	table.insert(Menu.Connections, Nodes.Connect(Resume, "pressed", function()
		HideMenu()
	end))
	table.insert(Menu.Connections, Nodes.Connect(Restart, "pressed", function()
		Game.Restart()
	end))
	table.insert(Menu.Connections, Nodes.Connect(Settings, "pressed", function()
		-- (not in the source: anyone watching is let go while the player is in the settings, Game/LiveSpectate)
		LiveSpectate.PlayerAway()
		SettingsMenu.ShowMenu(SettingsMenu.Instance :: SettingsMenu.SettingsMenu)
	end))
	table.insert(Menu.Connections, Nodes.Connect(Quit, "pressed", function()
		RunnerModule.GiveUp(Runner)
	end))

	return Menu
end

return New
