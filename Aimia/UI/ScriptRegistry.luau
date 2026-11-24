--!strict
--!optimize 2

--[[
	The ported scene scripts, by the res:// path of the script a node attaches (`script = ExtResource(...)` in the .tscn).
	SceneManager attaches them to the tree of each scene it instantiates; a node whose script is listed gets the module's
	New(Item, Context).

	Paradigm
		Scripts attach after the tree is built, children before their parent (Godot's _ready order), so a parent script finds
		its children's state built. A scene loads only when its root script is listed (Has): an unported scene is not loaded.

	Adding a script
		Require its module here and list its res:// path in Attachments. New is called with the node and the scene's Context;
		New returns nothing, and keeps its state in closures (Context.Scene.Load, Unload and Destroy). The path is the one the
		.tscn names (for example res://scripts/ui/menu/play/MapList.cs attaches to UI/Menu/Play/MapList).

	Design Notes
		The modules do not require SceneManager, so there is no require cycle; they take their types from BaseScene.
]]

const Items = require("./Item")
const Nodes = require("./Nodes")
const Theme = require("./Theme")
const BaseScene = require("./Scenes/BaseScene")
const AudioSpectrum = require("./AudioSpectrum")
const Background = require("./Menu/Background")
const FPSCounter = require("./FPSCounter")
const JukeboxPanel = require("./Menu/JukeboxPanel")
const LayoutButton = require("./Menu/LayoutButton")
const MenuCursor = require("./MenuCursor")
const SettingsMenuButton = require("./Menu/SettingsMenuButton")
const VersionLabel = require("./Menu/VersionLabel")
const Graph = require("./Results/Graph")
const MapInfo = require("./Menu/Play/MapInfo")
const MapList = require("./Menu/Play/MapList")
const RandomPickButton = require("./Menu/Play/RandomPickButton")
const SearchPanel = require("./Menu/Play/SearchPanel")
const SortMenuButton = require("./Menu/Play/SortMenuButton")
const LinkPopupButton = require("./LinkPopupButton")
const GameScene = require("./Scenes/Game")
const MainMenu = require("./Scenes/MainMenu")
const Results = require("./Scenes/Results")

type Item = Items.Item

-- The ported scripts: script res:// path -> New(Item, Context). The game scene's pause menu, playtest overlay and replay
-- viewer are not listed: the game scene builds them for each run (UI/Scenes/Game).
const Attachments = {
	["res://scripts/scenes/Game.cs"] = GameScene,
	["res://scripts/scenes/MainMenu.cs"] = MainMenu.New,
	["res://scripts/scenes/Results.cs"] = Results,
	["res://scripts/ui/results/Graph.cs"] = Graph,
	["res://scripts/ui/LinkPopupButton.cs"] = LinkPopupButton.New,
	["res://scripts/ui/menu/Background.cs"] = Background,
	["res://scripts/ui/menu/JukeboxPanel.cs"] = JukeboxPanel.New,
	["res://scripts/ui/menu/LayoutButton.cs"] = LayoutButton,
	["res://scripts/ui/menu/SettingsMenuButton.cs"] = SettingsMenuButton,
	["res://scripts/ui/menu/VersionLabel.cs"] = VersionLabel,
	["res://scripts/ui/MenuCursor.cs"] = MenuCursor.New,
	["res://scripts/ui/FPSCounter.cs"] = FPSCounter,
	["res://scripts/ui/AudioSpectrum.cs"] = AudioSpectrum.New,
	["res://scripts/ui/menu/play/MapList.cs"] = MapList.New,
	["res://scripts/ui/menu/play/MapInfo.cs"] = MapInfo.New,
	["res://scripts/ui/menu/play/SortMenuButton.cs"] = SortMenuButton,
	["res://scripts/ui/menu/play/RandomPickButton.cs"] = RandomPickButton,
	["res://scripts/ui/menu/play/SearchPanel.cs"] = SearchPanel,
}

-- The res:// path of the script a node attaches, or nil when it has none.
const function ScriptPath(Item: Item): string?
	const Script = Items.ResolveValue(Item.Context.Properties["script"], Theme.FileOf(Item.Context, "script"), Item)

	return if Script then Script.Path else nil
end

-- Attaches the ported scripts of Item and its descendants, children first (Godot's _ready order).
const function Attach(Item: Item, Context: BaseScene.Context)
	for _, Child in Nodes.GetChildren(Item) do
		Attach(Child, Context)
	end

	const Path = ScriptPath(Item)
	const Module = if Path then Attachments[Path] else nil

	if Module then
		Module(Item, Context)
	end
end

-- Whether the root's script is ported (a scene whose root is not is not loaded).
const function Has(Item: Item): boolean
	const Path = ScriptPath(Item)

	return Path ~= nil and Attachments[Path] ~= nil
end

return {
	Has = Has,
	Attach = Attach,
}
