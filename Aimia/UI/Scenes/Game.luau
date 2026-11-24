--!strict
--!optimize 2

--[[
	The game scene's script (scripts/scenes/Game.cs) on res://scenes/game.tscn: one run's objects (the 3D world, the runner with
	its note renderer and trail, the cursors, the replay manager, the HUD, the pause menu, the playtest overlay and the replay
	viewer) are built when the scene loads and torn down when it leaves. The scene's 2D nodes are the scene's own, built once.

	Paradigm
		New is attached by ScriptRegistry with the scene's Context and sets the scene's Load and Unload. It also sets
		GameStart.Hooks.Play to Game.Play, so a menu start reaches the game module. The game scene is cached by path, as upstream,
		so its Load builds the run each time and its Unload frees it.

	Design Notes
		Frame order (PreRender, as the source's _Process): the cursor, the runner, the replay manager, the trail (moved after them so
		it starts where the cursor is drawn), then the world's camera and cursors (World.Sync). The source's ReplayManager node
		precedes the runner in the tree; here it runs after it, so the replays' cursors are drawn at the frame's time, with the
		notes (before the runner they were a frame behind them).
		Input is Godot's _Input: keys and the left button come from UI/Input, the relative motion from the input's Delta (UI/Input's
		events carry the position only).
		The runner's ticks are the frame clock's microseconds (UI/Frames), not os.clock read mid-frame. Clock.Hooks is not
		used: it is a fixed zero until the audio backend is installed.
		DEVIATION(render): the game space is drawn inside the source's scene (AddSpaceAsChild). A screen-level space would cover
		the 3D world, so the game scene mounts none (UI/SceneManager).
		DEVIATION(platform): the mouse is captured with LockCenter; confined is free (Roblox cannot confine the mouse).
		Not ported: the temporary map mode's flags; the QuitOverlay (hidden in game.tscn, no script upstream); the NotificationHolder,
		which nothing fills upstream. Aimia.Hooks.IsPlaying and StopRun are set by the bootstrap (Game.IsPlaying, Game.StopRun).
]]

const GuiService = game:GetService("GuiService")
const UserInputService = game:GetService("UserInputService")

const AttemptModule = require("../../Game/Attempt")
const Backgrounds = require("../../Spaces/Backgrounds")
const BaseScene = require("./BaseScene")
const CursorManagerModule = require("../../Game/Managers/CursorManager")
const Frames = require("../Frames")
const Game = require("../../Game/Game")
const GameStart = require("../Menu/Play/GameStart")
const GridSpace = require("../../Game/View/GridSpace")
const GameWorldModule = require("../../Game/View/GameWorld")
const HudManagerModule = require("../Game/HudManager")
const Input = require("../Input")
const Items = require("../Item")
const LiveSpectate = require("../../Game/LiveSpectate")
const MenuCursor = require("../MenuCursor")
const Modifier = require("../../Game/Modifiers/Modifier")
const NewNoteRenderer = require("../../Game/View/NoteRenderer")
const NewPauseMenu = require("../Game/PauseMenu")
const NewPlaytestOverlay = require("../Game/PlaytestOverlay")
const NewOrthogonalView = require("../Game/OrthogonalView")
const NewReplayViewer = require("../Game/ReplayViewer")
const NewTrailRenderer = require("../../Game/View/TrailRenderer")
const Nodes = require("../Nodes")
const PlayerInputController = require("../../Game/PlayerInputController")
const ReplayManagerModule = require("../../Game/Managers/ReplayManager")
const RunnerModule = require("../../Game/Runner")
const Scale = require("../Scale")
const SettingsManager = require("../../SettingsManager")
const SettingsMenu = require("../SettingsMenu")
const Signal = require("../../Util/Signal")
const SkinManager = require("../../Skinning/SkinManager")
const SpaceColor = require("../../Spaces/SpaceColor")
const SkinSets = require("../../Skinning/SkinSets")
const Tone = require("../../Game/View/Tone")

type Item = Items.Item

-- One run's teardown functions, run in order when the scene leaves, then its world goes.
type Run = {
	Teardown: { () -> () },
	World: GameWorldModule.World,
}

const ResultsPath = "res://scenes/results.tscn"

-- The scene's node and context, set by New (the scene is built once; its runs come and go).
local SceneItem: Item
local SceneContext: BaseScene.Context
local Current: Run? = nil

-- The mouse mode last asked for. Motion right after the lock changes or the window or Roblox's menu gives the mouse back can
-- carry the jump to the centre: the next event is dropped, and for SettleTime so are events over SettleLimit pixels.
local MouseMode = "Visible"
local DropNextMotion = false
local SettleUntil = 0
const SettleTime = 0.1
const SettleLimit = 60

-- Time.GetTicksUsec: the frame clock's microseconds as a whole number (UI/Frames: one time for the whole frame, so the
-- runner and the trail move by one even step; os.clock read part-way through the frame added the varying work before it).
const function Ticks(): number
	return Frames.Time * 1000000 // 1
end

const function Settle()
	DropNextMotion = true
	SettleUntil = os.clock() + SettleTime
end

-- Input.MouseMode: captured locks the mouse to the window's centre; the other modes leave it free. The cursor icon is shown
-- for visible only.
-- DEVIATION(platform): confined and hidden are both free: Roblox cannot confine the mouse.
const function SetMouseMode(Mode: string)
	const Behavior = if Mode == "Captured" then Enum.MouseBehavior.LockCenter else Enum.MouseBehavior.Default

	MouseMode = Mode

	if UserInputService.MouseBehavior ~= Behavior then
		UserInputService.MouseBehavior = Behavior
		Settle()
	end

	Input.SetMouseMode(if Mode == "Visible" then "Visible" else "Hidden")
end

-- Builds the run's objects and loads the attempt into the runner (the scene's Load). The runner's host is built first, and
-- the parts it needs from the managers are filled in as they are created: the replay manager needs the runner, the cursor
-- manager the replay manager, and the HUD the runner.
-- @src scripts/scenes/Game.cs:_Ready L32-152
-- @src scripts/scenes/Game.cs:Load L154-209
const function Load()
	const Attempt = Game.Attempt :: AttemptModule.Attempt
	const Teardown: { () -> () } = {}

	MenuCursor.UpdateVisible(MenuCursor.Instance :: MenuCursor.CursorState, false, false)

	const Focused = Nodes.GetFocusOwner(SceneItem)

	if Focused then
		Nodes.ReleaseFocus(Focused)
	end

	const World = GameWorldModule.New(nil)

	-- From here the run can be torn down: a build that fails (a device refusing an image) must not leave the camera and lighting
	-- as the song's, or stop the scene from ever leaving.
	Current = {
		Teardown = Teardown,
		World = World,
	}

	GameWorldModule.Setup(World, Attempt.Settings, SkinManager.Skin)

	-- The camera is placed now, not at the first frame: until then the player's camera would show behind the transition.
	GameWorldModule.Sync(World)

	-- The game space is drawn in the world (the scene adds it as a child, AddSpaceAsChild): only the grid space is ported. Its name is
	-- the setting's, or the skin's when the setting is "skin" (Skin.GameSpace is only loaded for the spaces SkinManager ports).
	const SpaceName = if Attempt.Settings.GameSpace.Value == "skin" then SkinManager.Skin.Config.GameSpace else Attempt.Settings.GameSpace.Value
	const Fog = SpaceColor.Of(Attempt.Settings.SpaceColor.Value)
	const Space = if SpaceName == "grid" then GridSpace.New(World.Folder, Fog) else nil

	-- The void keeps the clear color unless the Space Color setting gives one.
	if Space or Fog then
		World.BackdropFill.BackgroundColor3 = GridSpace.BackdropOf(Fog)
	end

	-- An animated background (Spaces/Backgrounds) is drawn on a quad held between the notes and the far backdrop, wherever the
	-- camera looks. It takes the hit colour when Space Hit Effects is on.
	local Background: any = nil
	local BackgroundPart: Part? = nil
	local BackgroundGui: SurfaceGui? = nil
	local BackgroundTint: Color3? = nil

	-- A map skin's pictures are drawn 1:1 on the screen: the canvas is the view's own pixels plus a whole-pixel margin on each
	-- side, so every canvas pixel lands on a screen pixel (a 900-row canvas was stretched again to the screen, which blurred
	-- them). The other backgrounds keep the cheaper 900-row canvas.
	const PictureSet = SkinSets.Get(SpaceName)
	const Sharp = PictureSet ~= nil and #PictureSet.Pictures > 0

	-- The canvas for a view, and the view in whole pixels.
	const function CanvasFor(View: Vector2): (Vector2, Vector2)
		const ViewX, ViewY = math.max(math.round(View.X), 2), math.max(math.round(View.Y), 2)

		return Vector2.new(ViewX + 2 * math.ceil(ViewX * 0.02), ViewY + 2 * math.ceil(ViewY * 0.02)), Vector2.new(ViewX, ViewY)
	end

	if Backgrounds.Has(SpaceName) then
		const Part = Instance.new("Part")

		Part.Name = "Background"
		Part.Anchored = true
		Part.CanCollide = false
		Part.CanQuery = false
		Part.CanTouch = false
		Part.CastShadow = false
		Part.Transparency = 1
		Part.Size = Vector3.new(1, 1, 0.05)

		const Gui = Instance.new("SurfaceGui")

		Gui.Face = Enum.NormalId.Back
		Gui.LightInfluence = 0
		Gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
		-- (set right away: a canvas that changes size while it shows blinks)
		Gui.CanvasSize = if Sharp then (CanvasFor(workspace.CurrentCamera.ViewportSize)) else Vector2.new(1600, 900)
		Gui.Parent = Part

		const Holder = Instance.new("Frame")

		Holder.BackgroundTransparency = 1
		Holder.BorderSizePixel = 0
		Holder.Size = UDim2.fromScale(1, 1)
		Holder.Parent = Gui
		Part.Parent = World.Folder

		BackgroundPart = Part
		BackgroundGui = Gui
		Background = Backgrounds.New(SpaceName, Holder, {
			Fix = function(Color: Color3): Color3
				return Tone.Color(Color.R, Color.G, Color.B)
			end,
			Game = true,
		})
		World.BackdropFill.BackgroundColor3 = if Fog then GridSpace.BackdropOf(Fog) else Tone.Color(0.012, 0.01, 0.022)
	end

	-- Holds the quad in front of the camera at the size of the view, then draws a frame of the background.
	const function DrawBackground(Delta: number, Run: RunnerModule.Runner)
		const Part = BackgroundPart :: Part
		const Gui = BackgroundGui :: SurfaceGui
		const Camera = workspace.CurrentCamera
		const Distance = 80
		const Tall = 2 * Distance * math.tan(math.rad(Camera.FieldOfView) / 2)
		const View = Camera.ViewportSize
		local Shown: Vector2? = nil

		if Sharp then
			-- (the quad is as many studs a pixel as the screen at its distance: a change of field of view only resizes it)
			const Canvas, Seen = CanvasFor(View)
			const PerPixel = Tall / Seen.Y

			Part.Size = Vector3.new(Canvas.X * PerPixel, Canvas.Y * PerPixel, 0.05)
			Shown = Seen

			if Gui.CanvasSize ~= Canvas then
				Gui.CanvasSize = Canvas
			end
		else
			const Aspect = if View.Y > 0 then View.X / View.Y else 16 / 9
			const Canvas = Vector2.new(math.floor(900 * Aspect), 900)

			Part.Size = Vector3.new(Tall * Aspect * 1.04, Tall * 1.04, 0.05)

			if Gui.CanvasSize ~= Canvas then
				Gui.CanvasSize = Canvas
			end
		end

		Part.CFrame = Camera.CFrame * CFrame.new(0, 0, -Distance)

		const Hit = (Run.Attempt :: AttemptModule.Attempt).LastHitColour

		if Attempt.Settings.SpaceHitEffects.Value and Hit and not SkinSets.Get(SpaceName) then
			const Wanted = Color3.new(Hit.R, Hit.G, Hit.B)

			BackgroundTint = if BackgroundTint then BackgroundTint:Lerp(Wanted, math.min(1, Delta * 6)) else Wanted
		else
			BackgroundTint = Backgrounds.AccentOf(Fog)
		end

		Backgrounds.Process(Background, Delta, BackgroundTint, if Run.Playing then 1 else 0.15, Shown)
	end

	local Hud: HudManagerModule.Hud
	local Cursor: CursorManagerModule.Manager

	const function InitHud()
		HudManagerModule.Init(Hud)
	end

	const function DisplayModifier(Mod: Modifier.Modifier)
		HudManagerModule.DisplayModifier(Hud, Mod)
	end

	const function UpdateAutoplayCursor(Position: vector)
		CursorManagerModule.UpdateAutoplayCursor(Cursor, Position)
	end

	const function LoadResults()
		-- (a VS round's run, and a watched one in VS, go on to the VS tab or the next player instead: Game.Hooks.SkipResults)
		const Skip = Game.Hooks.SkipResults

		if Skip then
			const Asked, Skipped = pcall(Skip, Game.Attempt :: AttemptModule.Attempt)

			if not Asked then
				warn("[AIMIA] " .. tostring(Skipped))
			elseif Skipped then
				return
			end
		end

		SceneContext.Load(ResultsPath)
	end

	const Host = {
		Hud = {
			Init = InitHud,
			DisplayModifier = DisplayModifier,
		},
		Renderers = {},
		Cursor = {
			UpdateAutoplayCursor = UpdateAutoplayCursor,
		},
		-- Set below, once the replay manager exists: the runner reads Host.Replay only when it stops.
		Replay = (nil :: unknown) :: ReplayManagerModule.Manager,
		Camera = World.Camera :: { Fov: number },
		Ticks = Ticks,
		Scenes = {
			LoadResults = LoadResults,
		},
		NoteMesh = nil :: (() -> ())?,
	}

	const Runner = RunnerModule.New(Host)

	-- CursorManager reads the attempt when it is built (its _EnterTree reads Game.Attempt); Game.Load sets it again.
	Runner.Attempt = Attempt

	-- The replay manager takes the cursor manager's three functions bound to it, which exist only once the cursor manager does
	-- (it takes the replay manager): they are closures over the cursor, which is set below.
	const function UpdateCursor(Position: vector, Index: number)
		CursorManagerModule.UpdateCursor(Cursor, Position, Index)
	end

	const function ShowCursor(Index: number, Instant: boolean)
		CursorManagerModule.ShowCursor(Cursor, Index, Instant)
	end

	const function HideCursor(Index: number, Instant: boolean)
		CursorManagerModule.HideCursor(Cursor, Index, Instant)
	end

	const CursorBinding = {
		UpdateCursor = UpdateCursor,
		ShowCursor = ShowCursor,
		HideCursor = HideCursor,
	}

	const Replay = ReplayManagerModule.New((Runner :: unknown) :: ReplayManagerModule.Runner, CursorBinding)

	Host.Replay = Replay
	Cursor = CursorManagerModule.New((Runner :: unknown) :: CursorManagerModule.Runner, Replay, World.Camera, World.Cursors)

	table.insert(Teardown, function()
		CursorManagerModule.Exit(Cursor)
	end)

	table.insert(Host.Renderers, NewNoteRenderer(World, (Runner :: unknown) :: NewNoteRenderer.Runner))

	const Trail = NewTrailRenderer(World, (Runner :: unknown) :: NewTrailRenderer.Runner, Ticks)

	Hud = HudManagerModule.New(World, Runner)

	table.insert(Teardown, function()
		HudManagerModule.Destroy(Hud)
	end)

	const PauseMenu = NewPauseMenu(Nodes.GetNode(SceneItem, "Menu"), Runner, Replay, SetMouseMode)
	const Playtest = NewPlaytestOverlay(Nodes.GetNode(SceneItem, "PlaytestOverlay"), Runner, Replay, SetMouseMode)

	table.insert(Teardown, PauseMenu.Destroy)
	table.insert(Teardown, Playtest.Destroy)
	table.insert(Teardown, NewReplayViewer(Nodes.GetNode(SceneItem, "ReplayViewer"), Replay, SetMouseMode))

	const DrawOrthogonal, DestroyOrthogonal = NewOrthogonalView(Nodes.GetNode(Nodes.GetNode(SceneItem, "ReplayViewer"), "OrthogonalPanel"), World)

	table.insert(Teardown, DestroyOrthogonal)

	const function HideSettings()
		SettingsMenu.ShowMenu(SettingsMenu.Instance :: SettingsMenu.SettingsMenu, false)
	end

	const Session = {
		Runner = Runner,
		Cursor = Cursor,
		Replay = Replay,
		Menu = PauseMenu :: Game.Menu,
		Playtest = Playtest :: Game.Playtest,
		SetMouseMode = SetMouseMode,
		HideSettings = HideSettings,
	}

	-- The player input: the controller's Godot _Input signals, fed from UI/Input (keys, the left button) and the mouse delta.
	const Controller = PlayerInputController.New()

	-- (Absolute is the mouse in screen pixels, so the window it's centred in is too: the menus' scale has no say in it. The
	-- mouse's position starts below Roblox's top bar and the window's size doesn't, so the bar's height goes back on.)
	Signal.Connect(Controller.OnMouseMove, function(Relative: vector, Absolute: vector)
		const Screen = Scale.ScreenSizeOf(SceneItem.Scene.Viewport)
		const Inset = GuiService:GetGuiInset()

		Game.MouseMove(Session, Relative, Absolute + vector.create(Inset.X, Inset.Y, 0), vector.create(Screen.X, Screen.Y, 0))
	end)
	Signal.Connect(Controller.OnTogglePaused, function()
		Game.TogglePaused(Session)
	end)
	Signal.Connect(Controller.OnRestartPressed, function()
		Game.Restart()
	end)
	Signal.Connect(Controller.OnToggleReplayViewerVisibility, function()
		Game.ToggleReplayViewer(Session)
	end)
	Signal.Connect(Controller.OnToggleShowOrthonogalCamera, function()
		Game.ToggleOrthogonalCamera(Session)
	end)
	Signal.Connect(Controller.OnPauseOrSkipPressed, function()
		Game.PauseOrSkipPressed(Session)
	end)
	Signal.Connect(Controller.OnToggleFade, function()
		Game.ToggleFade()
	end)
	Signal.Connect(Controller.OnTogglePushback, function()
		Game.TogglePushback()
	end)

	table.insert(Teardown, Input.OnInput(function(Event: Input.InputEvent)
		if Event.Class == "InputEventKey" then
			if Event.PhysicalKeycode then
				PlayerInputController.HandleKey(Controller, Event.PhysicalKeycode, Event.Pressed, Event.Echo)
			end
		elseif Event.Class == "InputEventMouseButton" and Event.ButtonIndex == Input.MouseButton.Left then
			PlayerInputController.HandleMouseButton(Controller, Event.Pressed, false)
		end
	end))

	local HasFocus = true

	const FocusLost = UserInputService.WindowFocusReleased:Connect(function()
		HasFocus = false
	end)
	const FocusBack = UserInputService.WindowFocused:Connect(function()
		HasFocus = true
		Settle()
	end)
	const MenuClosed = GuiService.MenuClosed:Connect(Settle)

	-- (not the Processed flag: in a locked song the pointer sits at the window's centre, over whatever GUI is there)
	const Motion = UserInputService.InputChanged:Connect(function(Raw: InputObject)
		if Raw.UserInputType ~= Enum.UserInputType.MouseMovement or not HasFocus or GuiService.MenuIsOpen then
			return
		end

		if DropNextMotion then
			DropNextMotion = false

			return
		end

		if os.clock() < SettleUntil and Raw.Delta.Magnitude > SettleLimit then
			return
		end

		PlayerInputController.HandleMouseMotion(
			Controller,
			vector.create(Raw.Delta.X, Raw.Delta.Y, 0),
			vector.create(Raw.Position.X, Raw.Position.Y, 0)
		)
	end)

	table.insert(Teardown, function()
		Motion:Disconnect()
		FocusLost:Disconnect()
		FocusBack:Disconnect()
		MenuClosed:Disconnect()
	end)

	-- The per-frame order (see the header): cursor, runner, replay manager, trail; then the world follows the camera.
	table.insert(Teardown, Nodes.OnProcess(SceneItem, function(Delta: number)
		-- Nothing else holds the lock during a song. Host.Open matters: closing the gear must free the mouse.
		if Runner.Playing and Input.Host.Open and not GuiService.MenuIsOpen and MouseMode == "Captured" and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
			SetMouseMode("Captured")
		end

		LiveSpectate.Process(Delta)
		CursorManagerModule.Process(Cursor, Delta)
		RunnerModule.Process(Runner, Delta)
		-- (the replays' cursors once the runner has moved the timeline, so they are drawn at this frame's time, with the notes)
		ReplayManagerModule.Process(Replay)
		-- (the trail after the replays and the runner have moved the cursor this frame, autoplay included, so its head is where
		-- the cursor is drawn; before them it lagged a frame behind and showed a gap at speed)
		Trail.Process(Delta, Runner.Attempt :: AttemptModule.Attempt)
		DrawOrthogonal()

		if Space then
			GridSpace.Process(Space, Delta, (Runner.Attempt :: AttemptModule.Attempt).LastHitColour, Attempt.Settings.SpaceHitEffects.Value)
		end

		GameWorldModule.Sync(World)

		-- (the HUD stays on the grid with the Spin camera, now that the camera is placed for this frame: HudManager.Follow)
		HudManagerModule.Follow(Hud)

		-- (after the camera is placed for this frame; a broken background goes, and the song goes on over the void)
		if Background then
			const Drawn, Why = pcall(DrawBackground, Delta, Runner)

			if not Drawn then
				warn("[AIMIA] the game space stopped: " .. tostring(Why))
				pcall(Backgrounds.Destroy, Background)
				Background = nil
			end
		end
	end))

	table.insert(Teardown, function()
		if Background then
			Backgrounds.Destroy(Background)
			Background = nil
		end

		if BackgroundPart then
			BackgroundPart:Destroy()
		end
	end)

	if Space then
		table.insert(Teardown, function()
			GridSpace.Destroy(Space)
		end)
	end

	Game.Load(Session)

	-- (the listener goes after Game.Load, so it hears a hit after the runner has scored it)
	table.insert(Teardown, 1, LiveSpectate.Detach)
	LiveSpectate.Attach(Session)
end

-- Frees the run (the scene's Unload, when it leaves or reloads): the connections, the menus and the world, and the mouse back
-- to the menus' mode.
-- @src scripts/scenes/Game.cs:Load L154-209
const function Unload()
	const Run = Current

	Game.Unload()

	if Run then
		for _, Teardown in Run.Teardown do
			Teardown()
		end

		-- The world goes last: it is destroyed after the frame and the input are disconnected.
		GameWorldModule.Destroy(Run.World)
	end

	Current = nil

	SetMouseMode("Visible")

	-- (the menus' own cursor, when Use Cursor in Menus is on: the run hid it, and nothing else shows it again)
	const Settings = SettingsManager.Settings

	if MenuCursor.Instance and Settings then
		MenuCursor.UpdateVisible(MenuCursor.Instance, Settings.UseCursorInMenus.Value)
	end
end

-- Attaches the game scene's Load and Unload (the scene is cached and built once) and the menu start.
-- @src scripts/scenes/Game.cs:_Ready L32-152
const function New(Item: Item, Context: BaseScene.Context)
	SceneItem = Item
	SceneContext = Context

	Context.Scene.Load = Load
	Context.Scene.Unload = Unload
end

GameStart.Hooks.Play = Game.Play

return New
