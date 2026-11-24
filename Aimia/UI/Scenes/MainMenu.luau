--!strict
--!optimize 2

--[[
	The main menu scene's script (scripts/scenes/MainMenu.cs) on the root of res://scenes/main_menu.tscn: the menu buttons
	switch between the panels under "Menus" with Godot's fade.

	Representation
		New is attached by ScriptRegistry with the scene's Context. It sets the scene's Load (the space's state and the
		selected map, MainMenu.Load) and Destroy (the input connection and the fades) on Context.Scene.

	Design Notes
		Nodes.Set and Nodes.Connect are the node API; the fades are UI/Tween tweens of "modulate" (tinting, no CanvasGroup),
		and a fade replaces the one still running on its panel, as Godot's modulate tween does.
		Godot's Tween with only SetTrans uses EaseType InOut; the fade-out sets Ease In.
		Escape is _UnhandledInput: it runs only while the scene is in the tree (a cached scene that is off the tree ignores it).
		DEVIATION: mouse side buttons (Xbutton1/2) have no Roblox input; VSync has no Roblox setting.
]]

const Items = require("../Item")
const Nodes = require("../Nodes")
const Tween = require("../Tween")
const Input = require("../Input")
const SettingsManager = require("../../SettingsManager")
const SettingsProfile = require("../../Database/Settings/SettingsProfile")
const MapManager = require("../../Map/MapManager")
const SoundManager = require("../../Audio/SoundManager")
const Waves = require("../../Spaces/Waves")
const BaseScene = require("./BaseScene")
const MapInfo = require("../Menu/Play/MapInfo")

type Item = Items.Item

const Transparent = { Color = { 1, 1, 1, 0 } }
const Opaque = { Color = { 1, 1, 1, 1 } }

export type MainMenu = {
	CurrentMenu: Item,
	LastMenu: Item,
	HomeMenu: Item,
	PlayMenu: Item,
	TopBar: Item,
	MenuHolder: Item,
	TopBarButtons: Item,
	Fades: { [Item]: Tween.Tween },
	Connections: { () -> () },
}

-- Fades an item's modulate to Target over Time, replacing the fade still running on it.
const function Fade(Menu: MainMenu, Item: Item, Target: { Color: { number } }, Time: number, EaseType: number, Finished: (() -> ())?)
	const Previous = Menu.Fades[Item]

	if Previous then
		Tween.Kill(Previous)
	end

	const Running = Tween.Create(Item)

	Tween.SetTrans(Running, Tween.TransitionType.Quad)
	Tween.SetEase(Running, EaseType)
	Tween.TweenProperty(Running, Item, "modulate", Target, Time)

	if Finished then
		Tween.TweenCallback(Running, Finished)
	end

	Menu.Fades[Item] = Running
end

-- @src scripts/scenes/MainMenu.cs:Transition L125-155
const function Transition(Menu: MainMenu, Target: Item, Instant: boolean?)
	if Menu.CurrentMenu == Target then
		return
	end

	Menu.LastMenu = Menu.CurrentMenu
	Menu.CurrentMenu = Target

	const Last = Menu.LastMenu
	const LastButton = Nodes.FindChild(Menu.TopBarButtons, Last.Name, false)
	const CurrentButton = Nodes.FindChild(Menu.TopBarButtons, Target.Name, false)

	if LastButton then
		Nodes.Set(LastButton, "disabled", false)
	end

	if CurrentButton then
		Nodes.Set(CurrentButton, "disabled", true)
	end

	const TweenTime = if Instant then 0 else 0.15

	Fade(Menu, Last, Transparent, TweenTime, Tween.EaseType.In, function()
		Nodes.Set(Last, "visible", false)
	end)
	Nodes.Set(Target, "visible", true)
	Fade(Menu, Target, Opaque, TweenTime, Tween.EaseType.InOut, nil)

	SoundManager.RefreshMenuMusicPlayback()
end

-- The scene's Load (MainMenu.Load): the space's state and the selected map on it.
-- @src scripts/scenes/MainMenu.cs:Load L88-115
const function Load(Space: Waves.Waves?)
	-- DisplayServer VSync: no Roblox setting.
	-- A selection made while the menu was off the tree is applied now (e.g. the baked maps selected at start).
	MapInfo.ApplyPending()
	MapInfo.Refresh()

	if Space then
		Waves.UpdateState(Space, false)
	end

	const Map = MapManager.Selected.Value

	if Map and Space then
		Waves.UpdateMap(Space, Map)
	end

	SoundManager.RefreshMenuMusicPlayback()

	if (SettingsManager.Settings :: SettingsProfile.SettingsProfile).AutoplayJukebox.Value and not SoundManager.Song.Playing and SoundManager.Map ~= nil then
		SoundManager.PlayJukebox(SoundManager.JukeboxIndex)
	end
end

-- The scene's Destroy: disconnects the menu's connections and stops its fades.
const function Destroy(Menu: MainMenu)
	for _, Disconnect in Menu.Connections do
		Disconnect()
	end

	table.clear(Menu.Connections)

	for _, Running in Menu.Fades do
		Tween.Kill(Running)
	end

	table.clear(Menu.Fades)
end

-- @src scripts/scenes/MainMenu.cs:_Ready L20-57
const function New(Item: Item, Context: BaseScene.Context)
	const MenuHolder = Nodes.GetNode(Item, "Menus")
	const HomeMenu = Nodes.GetNode(Item, "Menus/Home")
	const TopBarButtons = Nodes.GetNode(Item, "TopBar/MenuButtons")
	const Menu = {
		CurrentMenu = HomeMenu,
		LastMenu = HomeMenu,
		HomeMenu = HomeMenu,
		PlayMenu = Nodes.GetNode(Item, "Menus/Play"),
		TopBar = Nodes.GetNode(Item, "TopBar"),
		MenuHolder = MenuHolder,
		TopBarButtons = TopBarButtons,
		Fades = {},
		Connections = {},
	}
	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile

	-- JukeboxPanel, MapList and MapInfo scripts: phase 2.
	Input.SetMouseMode(if Settings.UseCursorInMenus.Value then "Hidden" else "Visible")

	const MenuButtons: { Item } = Nodes.GetChildren(TopBarButtons)

	for _, Container in Nodes.GetChildren(Nodes.GetNode(Item, "Menus/Home/Buttons")) do
		const First = Nodes.GetChildren(Container)[1]

		if First then
			table.insert(MenuButtons, First)
		end
	end

	for _, Button in MenuButtons do
		const Target = Nodes.FindChild(MenuHolder, Button.Name, false)

		if Target then
			table.insert(Menu.Connections, Nodes.Connect(Button, "pressed", function()
				Transition(Menu, Target)
			end))
		end
	end

	-- @src scripts/scenes/MainMenu.cs:_UnhandledInput L75-86
	table.insert(Menu.Connections, Input.OnInput(function(Event: Input.InputEvent, Processed: boolean)
		if not Processed and Event.Pressed and Event.Keycode == Input.Key.Escape and Nodes.IsInsideTree(Item) then
			Transition(Menu, Menu.HomeMenu)
		end
	end))

	const function OnLoad()
		Load(Context.GetSpace())
	end

	const function OnDestroy()
		Destroy(Menu)
	end

	Context.Scene.Load = OnLoad
	Context.Scene.Destroy = OnDestroy
	Context.Scene.State = Menu
end

return {
	New = New,
	Transition = Transition,
}
