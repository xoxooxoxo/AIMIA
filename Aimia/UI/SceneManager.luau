--!strict
--!optimize 2

--[[
	Loads the scenes into the main scene and runs their transitions, as scripts/SceneManager.cs. The main scene
	(res://scenes/main.tscn: the settings menu, cursor and FPS counter are its nodes) is the root under the screen; each
	scene is instantiated under it with its scripts attached (UI/ScriptRegistry), and its space is drawn behind it.

	Paradigm
		One singleton module, as the autoload: the state is the exported table (Scene, Space, Attempt, ...). Scenes are
		cached by path, except SceneResults, which is built for each load and freed when it leaves (as upstream).
		Load fades the current scene's Transition to opaque, swaps the scene, and fades the new one in.

	Design Notes
		Instantiating a scene measures text, so it yields; Load yields with it. Its callers run on threads that may yield:
		the start and the button presses.
		The space is drawn by UI/SpaceView on the screen, behind the main scene (BackZIndex), not in the SubViewport of
		main.tscn (the container and the viewport there are not used). The clear color is a frame behind it (Backdrop), hidden
		while a scene draws its own world. A scene with AddSpaceAsChild (the game scene) mounts no
		space: upstream draws it inside the scene under the 3D world, and on the screen it would cover the world (DEVIATION(render)).
		Only the waves space is ported (SkinManager's PortedSpaces); any other space is void and mounts nothing, showing the clear
		color, which the Space Color setting can replace. A skin load (a change of the Menu Space setting) swaps the space at once.
		The attempt a scene gets in its Context is Game.Attempt (the source's static), read when the scene is built: the results
		scene is built for each load, so it reads the attempt that was just stopped.
		Game.Hooks (the game module's start and restart) are set here, since this module loads scenes.
		A load of a scene whose root script is not ported logs and keeps the current scene.
		The newest Load wins: one that hasn't swapped its scene in yet is dropped by the next, along with a run it was to start, so
		nothing lands after the host has moved on. A scene can't leave while its Load runs (Building): the game scene's yields
		while its text is first measured, and until it ends there is no run to tear down.
]]

const Items = require("./Item")
const Nodes = require("./Nodes")
const Scale = require("./Scale")
const SceneBuilder = require("./SceneBuilder")
const ScriptRegistry = require("./ScriptRegistry")
const SettingsMenu = require("./SettingsMenu")
const SpaceView = require("./SpaceView")
const Tween = require("./Tween")
const BaseScene = require("./Scenes/BaseScene")
const GameModule = require("../Game/Game")
const SettingsManager = require("../SettingsManager")
const SettingsProfile = require("../Database/Settings/SettingsProfile")
const SkinManager = require("../Skinning/SkinManager")
const Signal = require("../Util/Signal")
const SpaceColor = require("../Spaces/SpaceColor")
const Backgrounds = require("../Spaces/Backgrounds")
const Logger = require("../Util/Logger")
const Waves = require("../Spaces/Waves")

type Item = Items.Item

-- A load on its way. The table is its token: Pending stops being it when a newer load comes.
type PendingLoad = {
	Fade: Tween.Tween?,
	Target: BaseScene.BaseScene?,
}

const MainPath = "res://scenes/main.tscn"
const GamePath = "res://scenes/game.tscn"
const WavesPath = "res://prefabs/spaces/waves.tscn"
const FadeTime = 0.25
const ClearColor = Color3.new(0.0885599, 0.08855992, 0.08855987)

const SceneManager = {
	Screen = nil :: ScreenGui?,
	Backdrop = nil :: Frame?,
	Main = nil :: Item?,
	Scene = nil :: BaseScene.BaseScene?,
	Space = nil :: Waves.Waves?,
	VolumePanel = nil :: Item?,
	OffsetPanel = nil :: Item?,
	Building = false,
}

local Built: Items.Built? = nil
local Mounted: SpaceView.View? = nil
local WavesSpace: Waves.Waves? = nil
local ActivePath = ""
local Pending: PendingLoad? = nil

const Scenes: { [string]: BaseScene.BaseScene } = {}

-- The color of a fade's end: white at Alpha (the Transition's self_modulate).
const function WhiteAt(Alpha: number): { Color: { number } }
	return { Color = { 1, 1, 1, Alpha } }
end

-- The waves space (the menu and game space of the skin when it is waves), made once; any other space is nil (void), and
-- so is the space of a scene that draws it inside itself (AddSpaceAsChild, see the header).
-- @src scripts/scenes/BaseScene.cs:GetSpace L26-32
const function SpaceOf(Scene: BaseScene.BaseScene): Waves.Waves?
	if Scene.AddSpaceAsChild or BaseScene.SpacePath(Scene) ~= WavesPath then
		return nil
	end

	if WavesSpace == nil then
		WavesSpace = Waves.New(SettingsManager.Settings :: SettingsProfile.SettingsProfile)
	end

	return WavesSpace
end

-- The space the scenes get, when a scene asks for one (the Context's GetSpace).
const function GetSpace(): Waves.Waves?
	return SceneManager.Space
end

-- Mounts a space on the screen and loads it (addSpace). Nothing when there is none, or it is mounted already.
-- @src scripts/SceneManager.cs:addSpace L124-145
const function AddSpace(Space: Waves.Waves?)
	if Space == nil or Space == SceneManager.Space then
		return
	end

	Mounted = SpaceView.Mount(SceneManager.Screen :: ScreenGui, Space)
	SceneManager.Space = Space

	Waves.Load(Space, SkinManager.Skin.NoteColors)
end

-- Unmounts the space on the screen (removeSpace). The space itself is kept for the next scene that uses it.
-- @src scripts/SceneManager.cs:removeSpace L147-157
const function RemoveSpace()
	if Mounted then
		SpaceView.Destroy(Mounted)
	end

	Mounted = nil
	SceneManager.Space = nil
end

-- The clear color: the Space Color setting's, or the source's.
const function PaintBackdrop()
	const Backdrop = SceneManager.Backdrop
	const Color = SpaceColor.Of((SettingsManager.Settings :: SettingsProfile.SettingsProfile).SpaceColor.Value)

	if Backdrop then
		Backdrop.BackgroundColor3 = if Color then Color3.new(Color[1], Color[2], Color[3]) else ClearColor
	end
end

-- The animated background picked as Menu Space (Spaces/Backgrounds), on the screen behind the menus. Not under a scene that
-- draws its own world (a song has its Game Space).
local MenuBackground: any = nil
local MenuBackgroundFrame: Frame? = nil
local MenuBackgroundStop: (() -> ())? = nil

const function RefreshMenuBackground(Shown: BaseScene.BaseScene?)
	const Screen = SceneManager.Screen
	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile
	const Wanted = Settings.MenuSpace.Value
	const Scene = Shown or SceneManager.Scene
	const Shows = Screen ~= nil and Backgrounds.Has(Wanted)

	if MenuBackground and (not Shows or MenuBackground.Name ~= Wanted) then
		if MenuBackgroundStop then
			MenuBackgroundStop()
		end

		Backgrounds.Destroy(MenuBackground)
		MenuBackground = nil
		MenuBackgroundStop = nil
	end

	if Shows and not MenuBackground then
		local Holder = MenuBackgroundFrame

		if not Holder then
			const Made = Instance.new("Frame")

			Made.Name = "MenuBackground"
			Made.BackgroundTransparency = 1
			Made.BorderSizePixel = 0
			Made.Size = UDim2.fromScale(1, 1)
			-- (above the clear color, below the waves space and every scene)
			Made.ZIndex = -1500
			Made.Parent = Screen
			Holder = Made
			MenuBackgroundFrame = Made
		end

		const State = Backgrounds.New(Wanted, Holder :: Frame)

		MenuBackground = State
		MenuBackgroundStop = Nodes.OnFrame(function(Delta: number)
			const Holder = MenuBackgroundFrame

			if Holder and Holder.Visible and MenuBackground == State then
				-- (a broken background goes and the menus carry on: Nodes' frame loop has no guard of its own)
				const Drawn, Why = pcall(Backgrounds.Process, State, Delta, Backgrounds.AccentOf(SpaceColor.Of(Settings.SpaceColor.Value)))

				if not Drawn then
					warn("[AIMIA] the menu space stopped: " .. tostring(Why))
					pcall(Backgrounds.Destroy, State)
					MenuBackground = nil

					if MenuBackgroundStop then
						MenuBackgroundStop()
						MenuBackgroundStop = nil
					end
				end
			end
		end)
	end

	if MenuBackgroundFrame then
		MenuBackgroundFrame.Visible = MenuBackground ~= nil and not (Scene and Scene.AddSpaceAsChild)
	end
end

-- A skin load may have changed the space of the scene that is shown: the old one goes and the new one is mounted.
const function OnSkinLoaded()
	PaintBackdrop()
	RefreshMenuBackground()

	const Scene = SceneManager.Scene

	if Scene == nil or Nodes.GetParent(Scene.Item) ~= SceneManager.Main then
		return
	end

	const Wanted = SpaceOf(Scene)

	if Wanted ~= SceneManager.Space then
		RemoveSpace()
		AddSpace(Wanted)
	end
end

-- Adds a scene under the main scene, with its space, and runs its Load (addScene).
-- @src scripts/SceneManager.cs:addScene L86-100
const function AddScene(Scene: BaseScene.BaseScene)
	if Nodes.GetParent(Scene.Item) == SceneManager.Main then
		return
	end

	AddSpace(SpaceOf(Scene))
	Nodes.AddChild(SceneManager.Main :: Item, Scene.Item)

	-- The clear color is drawn on the screen, so it would cover the 3D world of a scene that draws its own (the game scene).
	const Backdrop = SceneManager.Backdrop

	if Backdrop then
		Backdrop.Visible = not Scene.AddSpaceAsChild
	end

	RefreshMenuBackground(Scene)

	const Load = Scene.Load

	if Load then
		Load()
	end
end

-- The results scene is not cached: it is freed when it leaves, or when a newer load means it never shows.
const function FreeResults(Scene: BaseScene.BaseScene)
	if Scene.Name == "SceneResults" then
		const Destroy = Scene.Destroy

		if Destroy then
			Destroy()
		end

		Nodes.QueueFree(Scene.Item)
	end
end

-- Removes a scene from the main scene: its Unload runs, a results scene is freed, and the space goes (removeScene).
-- @src scripts/SceneManager.cs:removeScene L102-122
const function RemoveScene(Scene: BaseScene.BaseScene?)
	if Scene == nil or Nodes.GetParent(Scene.Item) ~= SceneManager.Main then
		return
	end

	const Unload = Scene.Unload

	if Unload then
		Unload()
	end

	Nodes.RemoveChild(SceneManager.Main :: Item, Scene.Item)
	FreeResults(Scene)
	RemoveSpace()
end

-- Instantiates the scene at Path under the main scene's viewport, with its scripts attached. Nil when its root script is
-- not in UI/ScriptRegistry: the scene is not ported, and nothing is built.
-- @src scripts/SceneManager.cs:Load L49-84
const function Instantiate(Path: string): BaseScene.BaseScene?
	const Root = Nodes.Instantiate(Built :: Items.Built, Path)

	if not ScriptRegistry.Has(Root) then
		Logger.Log(`Scene {Path} is not ported: its script is not in UI/ScriptRegistry`)
		Nodes.QueueFree(Root)

		return nil
	end

	const Scene = BaseScene.New(Root, Path)

	ScriptRegistry.Attach(Root, {
		Scene = Scene,
		Load = SceneManager.Load,
		GetSpace = GetSpace,
		Attempt = GameModule.Attempt,
	})

	return Scene
end

-- Builds res://scenes/main.tscn under Screen: the root every scene is loaded into (_EnterTree). Yields while text is
-- measured.
-- @src scripts/SceneManager.cs:_EnterTree L25-31
function SceneManager.Initialize(Screen: ScreenGui, UiScale: number?)
	const Backdrop = Instance.new("Frame")
	const Factor = UiScale or 1
	const ScaledRoot = Instance.new("Frame")
	const Scaling = Instance.new("UIScale")

	Backdrop.Name = "ClearColor"
	Backdrop.BorderSizePixel = 0
	Backdrop.BackgroundColor3 = ClearColor
	Backdrop.Size = UDim2.fromScale(1, 1)
	Backdrop.ZIndex = -2000
	Backdrop.Parent = Screen
	SceneManager.Backdrop = Backdrop
	PaintBackdrop()
	Signal.Connect(SkinManager.Loaded, OnSkinLoaded)

	-- The scenes are laid out in Godot's pixels: their root is scaled (see UI/Scale).
	ScaledRoot.Name = "Scaled"
	ScaledRoot.BackgroundTransparency = 1
	ScaledRoot.BorderSizePixel = 0
	ScaledRoot.Size = UDim2.fromScale(1 / Factor, 1 / Factor)
	Scaling.Scale = Factor
	Scaling.Parent = ScaledRoot
	ScaledRoot.Parent = Screen
	Scale.Install(Screen, ScaledRoot, Factor, Scaling)

	const Result = SceneBuilder.Build(MainPath, ScaledRoot)
	const Root = Result.Root :: Item

	Built = Result
	SceneManager.Screen = Screen
	SceneManager.Main = Root
	SceneManager.VolumePanel = Nodes.GetNode(Root, "Volume")
	SceneManager.OffsetPanel = Nodes.GetNode(Root, "Offset")

	-- The scripts of main.tscn's nodes (cursor, FPS counter): Godot readies them with the root.
	ScriptRegistry.Attach(Root, {
		Scene = BaseScene.New(Root, MainPath),
		Load = SceneManager.Load,
		GetSpace = GetSpace,
		Attempt = GameModule.Attempt,
	})

	-- The settings menu is main.tscn's Settings node, built from Instances (UI/SettingsMenu) under the same root.
	SettingsMenu.New(Result)
end

-- Changes the menus' scale (Menu Scale or the window): the built scenes lay out again through Scale.Changed.
function SceneManager.SetUiScale(Factor: number)
	Scale.SetFactor(Factor)
end

-- Visits every built scene: the cached ones and the one shown (results isn't cached).
function SceneManager.EachScene(Visit: (Scene: BaseScene.BaseScene) -> ())
	const Shown = SceneManager.Scene
	local SawShown = false

	for _, Scene in Scenes do
		SawShown = SawShown or Scene == Shown
		Visit(Scene)
	end

	if Shown and not SawShown then
		Visit(Shown)
	end
end

-- Whether the game scene is the one shown (SceneManager.Scene is Game): the hooks that differ during a run use it.
function SceneManager.IsGameScene(): boolean
	const Current = SceneManager.Scene

	return Current ~= nil and Current.Path == GamePath
end

-- Whether a load hasn't swapped its scene in yet.
function SceneManager.IsLoading(): boolean
	return Pending ~= nil
end

-- Loads the scene at Path (Load): the current scene's Transition fades to opaque, the scene is swapped, and the new scene's
-- Transition fades out. SkipTransition makes both fades instant. Yields while the scene is built.
-- @src scripts/SceneManager.cs:Load L49-84
function SceneManager.Load(Path: string, SkipTransition: boolean?)
	const Duration = if SkipTransition == true then 0 else FadeTime
	const This: PendingLoad = { Fade = nil }

	if Pending and Pending.Fade then
		Tween.Kill(Pending.Fade)
		FreeResults(Pending.Target :: BaseScene.BaseScene)
	end

	Pending = This

	if Path ~= GamePath then
		GameModule.StartQueued = false
	end

	const Cached = Scenes[Path]
	const Next = if Cached then Cached else Instantiate(Path)

	if Next == nil then
		if Pending == This then
			Pending = nil
		end

		return
	end

	const Target: BaseScene.BaseScene = Next

	if Cached == nil and Target.Name ~= "SceneResults" then
		Scenes[Path] = Target
	end

	-- (building it yielded, and a newer load came)
	if Pending ~= This then
		FreeResults(Target)

		return
	end

	const Current = SceneManager.Scene
	const OutTween = Tween.Create(SceneManager.Main)

	This.Fade = OutTween
	This.Target = Target
	Tween.SetTrans(OutTween, Tween.TransitionType.Quad)

	if Current and Current.Transition then
		Tween.TweenProperty(OutTween, Current.Transition, "self_modulate", WhiteAt(1), Duration)
	end

	Tween.TweenCallback(OutTween, function()
		while SceneManager.Building do
			task.wait()
		end

		if Pending ~= This then
			return
		end

		Pending = nil
		RemoveScene(SceneManager.Scene)

		ActivePath = Path
		SceneManager.Scene = Target

		-- (a listed replay's player's note look stays on through the song and its results, and comes off for anything else)
		if Path ~= GamePath and Target.Name ~= "SceneResults" then
			SkinManager.TakeOffNoteLook()
		end

		-- The new scene's Transition is opaque before the scene is added: its Load builds the scene (the game scene builds its world) and
		-- may take a while, and until then nothing else covers what is behind the screen.
		const Transition = Target.Transition

		if Transition then
			Nodes.Set(Transition, "self_modulate", WhiteAt(1))
		end

		SceneManager.Building = true

		const Added, Problem = pcall(AddScene, Target)

		SceneManager.Building = false

		if not Added then
			error(Problem, 0)
		end

		if Transition then
			const InTween = Tween.Create(SceneManager.Main)

			Nodes.Set(Transition, "self_modulate", WhiteAt(1))
			Tween.SetTrans(InTween, Tween.TransitionType.Quad)
			Tween.TweenProperty(InTween, Transition, "self_modulate", WhiteAt(0), Duration)
		end
	end)
end

-- Loads the scene that is shown again (ReloadCurrentScene), with no transition.
-- @src scripts/SceneManager.cs:ReloadCurrentScene L44-47
function SceneManager.ReloadCurrentScene()
	SceneManager.Load(ActivePath, true)
end

-- The game module starts and restarts runs through the loader (it does not require UI).
GameModule.Hooks.LoadScene = SceneManager.Load
GameModule.Hooks.ReloadScene = SceneManager.ReloadCurrentScene

return SceneManager
