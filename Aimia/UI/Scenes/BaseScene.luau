--!strict
--!optimize 2

--[[
	The base of the scene scripts (scripts/scenes/BaseScene.cs): the state SceneManager keeps for a scene (its root, its
	Transition node, the space it uses, and its Load, Unload and Destroy hooks), and the Context a scene script is attached
	with.

	Representation
		A scene is one BaseScene table, made from the root item of the scene. The root's script overrides the hooks by setting
		Context.Scene.Load, Unload or Destroy, as a C# subclass overrides the virtual methods.

	Design Notes
		Destroy is not in the source: SceneManager calls it when a scene is freed (Results is not cached), so a script can
		disconnect the global input connections it made (Input.OnInput is not owned by an item, so Nodes does not free it).
		A Context is made per scene load. Load and GetSpace are SceneManager's, passed in: the scripts do not require
		SceneManager (ScriptRegistry requires the scripts, and SceneManager requires ScriptRegistry).
]]

const Items = require("../Item")
const Nodes = require("../Nodes")
const GameAttempt = require("../../Game/Attempt")
const SkinManager = require("../../Skinning/SkinManager")
const Waves = require("../../Spaces/Waves")

type Item = Items.Item

export type BaseScene = {
	Item: Item,
	Path: string,
	Name: string,
	Transition: Item?, -- nil for res://scenes/main.tscn, the root the scenes load into (not a BaseScene upstream)
	UseGameSpace: boolean,
	UseMenuSpace: boolean,
	AddSpaceAsChild: boolean,
	Load: (() -> ())?,
	Unload: (() -> ())?,
	Destroy: (() -> ())?,
	-- The scene script's own state (the C# scene node), for other scripts that test `SceneManager.Scene is MainMenu`.
	State: unknown?,
}

export type Context = {
	Scene: BaseScene,
	Load: (Path: string, SkipTransition: boolean?) -> (),
	GetSpace: () -> Waves.Waves?,
	Attempt: GameAttempt.Attempt?,
}

-- The path of the space a scene uses (BaseScene.GetSpace): the skin's game or menu space, or nil for none.
-- @src scripts/scenes/BaseScene.cs:GetSpace L26-32
const function SpacePath(Scene: BaseScene): string?
	if Scene.UseGameSpace then
		return SkinManager.Skin.GameSpace
	elseif Scene.UseMenuSpace then
		return SkinManager.Skin.MenuSpace
	end

	return nil
end

-- The state of the scene whose root item is Item, loaded from Path.
-- @src scripts/scenes/BaseScene.cs:_Ready L16-21
const function New(Item: Item, Path: string): BaseScene
	return {
		Item = Item,
		Path = Path,
		Name = Item.Name,
		Transition = Nodes.GetNodeOrNull(Item, "Transition"),
		UseGameSpace = Nodes.Get(Item, "UseGameSpace") == true,
		UseMenuSpace = Nodes.Get(Item, "UseMenuSpace") == true,
		AddSpaceAsChild = Nodes.Get(Item, "AddSpaceAsChild") == true,
		Load = nil,
		Unload = nil,
		Destroy = nil,
	}
end

return {
	New = New,
	SpacePath = SpacePath,
}
