--!strict
--!optimize 2

--[[
	The results scene's script (scripts/scenes/Results.cs) on res://scenes/results.tscn: the attempt's title, scores, status,
	modifiers and cover, and the buttons and keys that leave for the menu or play again.

	Representation
		The attempt is the structural type of Game/Attempt; the game port (phase 3) passes its Attempt in Context. The scene is
		built for each attempt and freed when it leaves (Destroy disconnects its input). LastFrame is the module state the
		source keeps in statics.

	Design Notes
		Replay and Play need the game (Game.Play, phase 3): until it is ported they log and stay on the results.
		The holder follows the mouse on _Process. Upstream takes the frame delta as whole seconds (an integer division of
		microseconds), so the holder moves only on the first frame: that is kept. MousePosition is never set upstream, so
		it is zero.
		Audio (SoundManager's Song and MenuMusic, the volume and the pitch) is deferred. VSync has no Roblox setting.
		MenuCursor (the cursor's visibility) is not ported (phase 2).
		DEVIATION: mouse side button Xbutton1 has no Roblox input, so its branch never runs.
]]

const Items = require("../Item")
const Nodes = require("../Nodes")
const Input = require("../Input")
const Images = require("../Images")
const FileSystem = require("../../Util/FileSystem")
const Misc = require("../../Util/Misc")
const UtilString = require("../../Util/String")
const Constants = require("../../Constants")
const SettingsManager = require("../../SettingsManager")
const SettingsProfile = require("../../Database/Settings/SettingsProfile")
const SkinManager = require("../../Skinning/SkinManager")
const BaseScene = require("./BaseScene")
const CoverBackdrop = require("../CoverBackdrop")
const ImageDecode = require("../../Util/ImageDecode")
const CameraMode = require("../../Game/Camera/CameraMode")
const Game = require("../../Game/Game")
const GameAttempt = require("../../Game/Attempt")
const MapParser = require("../../Map/MapParser")
const Modifier = require("../../Game/Modifiers/Modifier")
const MapTypes = require("../../Map/MapTypes")
const ReplayFile = require("../../Map/Replay")
const SoundManager = require("../../Audio/SoundManager")
const Scale = require("../Scale")
const CoverTheme = require("../CoverTheme")

const GuiService = game:GetService("GuiService")
const TweenService = game:GetService("TweenService")
const UserInputService = game:GetService("UserInputService")

type Item = Items.Item

const MenuPath = "res://scenes/main_menu.tscn"

-- Layout pixels the screen must be tall for PLAY AGAIN to sit in the middle after a fail (AimiaApp's FailPlay): below it (a
-- big Menu Scale on a wide window) the circle would reach the line under the title or the hit graph, so Play stays in the
-- footer.
const MiddleMinHeight = 800

-- The round PLAY AGAIN after a fail. Its colours come from the song's cover (CoverTheme), so it sits right on every
-- cover; its edge, ring and words land on whole screen pixels (sized and placed against the menus' scale), so they're sharp;
-- and it moves: it springs in, a light runs slowly round its ring, and under the mouse it grows a touch, takes the cover's
-- colour and sends out soft rings. Layout pixels for its side; how see-through its disc is at rest and under the mouse; how
-- long the light takes round the ring and each ring under the mouse takes to spread.
const CircleSide = 190
const CircleRestTransparency = 0.18
const CircleHoverTransparency = 0.06
const SheenSeconds = 4.5
const RippleSeconds = 1.1
const White = Color3.new(1, 1, 1)

-- Rounds a frame into a circle.
const function Rounded(Gui: GuiObject)
	const Corner = Instance.new("UICorner")

	Corner.CornerRadius = UDim.new(0.5, 0)
	Corner.Parent = Gui
end

-- The last frame's time in microseconds (Time.GetTicksUsec), and the mouse offset the holder moves toward (never set
-- upstream, so zero).
local LastFrame = 0
const MousePosition = vector.zero

-- Sets the text of the label at Name under Holder.
const function SetText(Holder: Item, Name: string, Text: string)
	Nodes.Set(Nodes.GetNode(Holder, Name), "text", Text)
end

-- The status line: the replay's status, else PASSED or DISQUALIFIED when alive, else FAILED.
-- @src scripts/scenes/Results.cs:_Ready L40-43
const function StatusOf(Attempt: GameAttempt.Attempt): string
	if Attempt.IsReplay then
		return Attempt.Replays[1].Status :: string
	elseif Attempt.Alive then
		return if Attempt.Qualifies then "PASSED" else "DISQUALIFIED"
	end

	return "FAILED"
end

-- A texture value for Nodes: a baked path, or a decoded image registered as one. Nil when there is no texture.
const function TextureValue(Texture: { Path: string?, Image: Images.Decoded? }?): { Path: string }?
	if Texture == nil then
		return nil
	elseif Texture.Image then
		return { Path = Images.Register(Texture.Image) }
	elseif Texture.Path then
		return { Path = Texture.Path }
	end

	return nil
end

-- The icon of a modifier (Util/Misc.GetModIcon): the skin's texture for it. Godot's placeholder for an unknown name has
-- no image here, so an unknown name has no icon.
-- @src scripts/util/Misc.cs:GetModIcon L14-54
const function ModIcon(Name: string): { Path: string }?
	const Skin = SkinManager.Skin

	if Name == "NoFail" then
		return TextureValue(Skin.ModNoFailImage)
	elseif Name == "Autoplay" then
		return TextureValue(Skin.ModAutoplayImage)
	elseif Name == "Ghost" then
		return TextureValue(Skin.ModGhostImage)
	elseif Name == "Strobe" then
		return TextureValue(Skin.ModStrobeImage)
	elseif Name == "Chaos" then
		return TextureValue(Skin.ModChaosImage)
	elseif Name == "Vortex" then
		return TextureValue(Skin.ModVortexImage)
	elseif Name == "Earthquake" then
		return TextureValue(Skin.ModEarthquakeImage)
	elseif Name == "HFlip" then
		return TextureValue(Skin.ModHFlipImage)
	elseif Name == "VFlip" then
		return TextureValue(Skin.ModVFlipImage)
	end

	return nil
end

-- Leaves for the main menu (Stop). The temporary map mode, which quits instead, is not ported.
-- @src scripts/scenes/Results.cs:Stop L185-203
const function LeaveForMenu(Context: BaseScene.Context)
	Context.Load(MenuPath)
end

-- Plays the attempt again (Replay): the map is decoded afresh, with the attempt's speed, start, camera and modifiers.
-- @src scripts/scenes/Results.cs:Replay L174-183
const function Replay(Attempt: GameAttempt.Attempt)
	-- (a second press while the song is already on its way does nothing)
	if Game.StartQueued then
		return
	end

	const Map = MapParser.Decode(Attempt.Map.FolderPath) :: MapTypes.Map

	Map.Ephemeral = Attempt.Map.Ephemeral
	SoundManager.SongStop()
	Game.Play(Map, Attempt.Speed, Attempt.StartFrom, Attempt.CameraMode, Attempt.Modifiers)
end

-- Plays a replay file (the Replay button, when its file exists). Watching a listed run's replay again keeps its player's look.
-- @src scripts/scenes/Results.cs:_Ready L99-119
const function PlayReplay(Path: string, Previous: ReplayFile.Replay?)
	const Recording = ReplayFile.New(Path)

	-- (a file that didn't read whole, like one left by a run stopped while it loaded, would freeze the replay)
	if not Recording.Valid or not Recording.Frames or not Recording.Notes or not Recording.MapFilePath then
		return
	end

	if Previous and Previous.ShowsPlayer and Previous.ID == Recording.ID then
		Recording.Settings = Previous.Settings
		Recording.ShowsPlayer = true
		;(Recording :: any).Look = (Previous :: any).Look
		;(Recording :: any).PlayerName = (Previous :: any).PlayerName
	end

	SoundManager.SongStop()
	Game.Play(
		MapParser.Decode(Recording.MapFilePath :: string) :: MapTypes.Map,
		Recording.Speed,
		Recording.StartFrom,
		Recording.CameraMode :: CameraMode.CameraMode,
		Recording.Modifiers :: { Modifier.Modifier },
		{ Recording }
	)
end

-- The holder moves toward the mouse (_Process). The frame delta is whole seconds, as upstream computes it.
-- @src scripts/scenes/Results.cs:_Process L122-131
const function Follow(Item: Item, Holder: Item)
	const Now = os.clock() * 1000000 // 1
	const Delta = (Now - LastFrame) // 1000000

	LastFrame = Now

	const Size = Nodes.GetViewportRect(Item)
	const Target = (Size / 2 - MousePosition) * (8 / Size.y)
	const Weight = math.min(1, Delta * 16)

	-- (Not in the source: with a whole-second delta the weight is 0 on every frame, so nothing moves; the read and the Set
	-- each laid the scene out for nothing, every frame of the results)
	if Weight <= 0 then
		return
	end

	const Position = Nodes.Get(Holder, "position") :: vector

	Nodes.Set(Holder, "position", Position + (Target - Position) * Weight)
end

-- @src scripts/scenes/Results.cs:_Ready L16-120
const function New(Item: Item, Context: BaseScene.Context)
	const Attempt = Context.Attempt :: GameAttempt.Attempt
	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile
	const Holder = Nodes.GetNode(Item, "Holder")
	const Footer = Nodes.GetNode(Item, "Footer")
	const Cover = Nodes.GetNode(Item, "Cover")
	const CoverBackground = Nodes.GetNode(Item, "CoverBackground")
	const Connections: { () -> () } = {}

	-- SoundManager.MenuMusic.Stop: audio is deferred. MenuCursor.Instance.Visible: MenuCursor is phase 2.
	Input.SetMouseMode(if Settings.UseCursorInMenus.Value then "Hidden" else "Visible")

	const Prefix = if Attempt.IsReplay and not Attempt.IsLive then "[REPLAY] " else ""

	SetText(Holder, "Title", `{Prefix}{Attempt.Map.PrettyTitle}`)
	SetText(Holder, "Difficulty", Attempt.Map.DifficultyName)
	SetText(Holder, "Mappers", `by {Attempt.Map.PrettyMappers}`)
	SetText(Holder, "Accuracy", `{string.format("%.2f", Attempt.Accuracy)}%`)
	SetText(Holder, "Score", UtilString.PadMagnitude(Attempt.Score))
	SetText(Holder, "Hits", `{UtilString.PadMagnitude(Attempt.Hits)} / {UtilString.PadMagnitude(Attempt.Sum)}`)
	SetText(Holder, "Status", StatusOf(Attempt))
	SetText(Holder, "Speed", `{string.format("%.2f", Attempt.Speed)}x`)

	const ModifiersContainer = Nodes.GetNode(Holder, "Modifiers/HBoxContainer")
	const ModifierTemplate = Nodes.GetNode(ModifiersContainer, "ModifierTemplate")

	for _, Modifier in Attempt.Modifiers do
		const Icon = Nodes.Duplicate(ModifierTemplate)
		const Texture = ModIcon(Modifier.Name)

		Nodes.Set(Icon, "visible", true)

		if Texture then
			Nodes.Set(Icon, "texture", Texture)
		end

		Nodes.AddChild(ModifiersContainer, Icon)
	end

	local CoverImage: ImageDecode.Image? = nil
	-- (the cover's runtime image is this screen's alone: it is freed with the screen, or one piled up per song)
	local CoverKey: string? = nil

	if Attempt.Map.CoverBuffer then
		const Image = Misc.LoadImageFromBuffer(Attempt.Map.CoverBuffer)

		if Image then
			CoverKey = Images.Register(Image)

			const Texture = { Path = CoverKey :: string }

			CoverImage = Image
			Nodes.Set(Cover, "texture", Texture)
			Nodes.Set(CoverBackground, "texture", Texture)
		end
	end

	-- The blur panels (GraphBlur, the top bar, the footer) blur what is behind them: the background and the cover.
	const StopBackdrop = CoverBackdrop(Item, CoverImage)

	-- SoundManager.Song (the song, its pitch and the jukebox index) is audio: deferred.

	const BackButton = Nodes.GetNode(Footer, "Back")
	const PlayButton = Nodes.GetNode(Footer, "Play")
	const ReplayButton = Nodes.GetNode(Footer, "Replay")

	table.insert(Connections, Input.OnInput(function(Event: Input.InputEvent)
		-- Someone who watched this song live only sees the player's results; the host's X takes them out.
		if Attempt.IsLive then
			return
		end

		if Event.Class == "InputEventKey" and Event.Pressed then
			if Event.PhysicalKeycode == Input.Key.Escape then
				LeaveForMenu(Context)
			elseif Event.PhysicalKeycode == Input.Key.Quoteleft then
				Replay(Attempt)
			end
		elseif Event.Class == "InputEventMouseButton" and Event.Pressed and Event.ButtonIndex == Input.MouseButton.Xbutton1 then
			LeaveForMenu(Context)
		end
	end))

	Nodes.Connect(BackButton, "pressed", function()
		LeaveForMenu(Context)
	end)
	Nodes.Connect(PlayButton, "pressed", function()
		Replay(Attempt)
	end)

	Nodes.Set(ReplayButton, "visible", not Attempt.Map.Ephemeral)

	if not FileSystem.Exists(Attempt.ReplayPath) and not Attempt.IsReplay then
		-- The replay can be missing for several reasons; the desync notification stays off, as upstream.
		Nodes.Set(ReplayButton, "visible", false)
	end

	if Attempt.IsLive then
		Nodes.Set(BackButton, "visible", false)
		Nodes.Set(PlayButton, "visible", false)
		Nodes.Set(ReplayButton, "visible", false)
	end

	-- Your own song failed (given up too): Play leaves the footer for a round PLAY AGAIN in the middle of the screen (FailPlay,
	-- added by AimiaApp, holds it), and Watch Replay takes the corner it leaves. Never for a replay or a song watched live.
	const FailPlay = Nodes.GetNodeOrNull(Item, "FailPlay")

	if FailPlay and not Attempt.IsReplay and not Attempt.IsLive and not Attempt.Alive then
		const Button: Item = FailPlay
		const Host = Button.Instance :: GuiObject
		const Colors = CoverTheme.ButtonsOf(CoverTheme.Of(CoverImage))

		-- (the words in the FAILED line's own font; Roboto Bold if it can't be found)
		local Face = Font.new("rbxasset://fonts/families/Roboto.json", Enum.FontWeight.Bold)
		const StatusItem = Nodes.GetNodeOrNull(Holder, "Status")

		if StatusItem then
			const Words = if StatusItem.Instance:IsA("TextLabel") then StatusItem.Instance else StatusItem.Instance:FindFirstChildWhichIsA("TextLabel", true)

			if Words then
				Face = (Words :: TextLabel).FontFace
			end
		end

		local GrowTo, ShrinkTo = 1.05, 0.95
		const Ripple = Instance.new("Frame")
		const RippleRing = Instance.new("UIStroke")
		const RippleGrow = Instance.new("UIScale")
		const Circle = Instance.new("TextButton")
		const Ring = Instance.new("UIStroke")
		const Sheen = Instance.new("UIGradient")
		const Give = Instance.new("UIScale")

		-- (the soft rings it sends out under the mouse, behind it)
		Ripple.Name = "Ripple"
		Ripple.BackgroundTransparency = 1
		Ripple.BorderSizePixel = 0
		Ripple.AnchorPoint = Vector2.new(0.5, 0.5)
		Ripple.ZIndex = 1
		Rounded(Ripple)
		RippleRing.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		RippleRing.Color = Colors.Hover
		RippleRing.Transparency = 1
		RippleRing.Parent = Ripple
		RippleGrow.Parent = Ripple
		Ripple.Parent = Host

		Circle.Name = "Circle"
		Circle.AutoButtonColor = false
		Circle.BorderSizePixel = 0
		Circle.AnchorPoint = Vector2.new(0.5, 0.5)
		Circle.ZIndex = 2
		Circle.BackgroundColor3 = Colors.Fill
		Circle.BackgroundTransparency = 1
		Circle.Text = "PLAY AGAIN"
		Circle.FontFace = Face
		Circle.TextSize = 28
		Circle.TextColor3 = White
		Circle.TextTransparency = 1
		Rounded(Circle)
		Ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		Ring.Color = Colors.Ring
		Ring.Transparency = 1
		Ring.Parent = Circle
		-- (one side of the ring a little brighter than the other: turned slowly, a light seems to run round it)
		Sheen.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(0.5, 0.25),
			NumberSequenceKeypoint.new(1, 0),
		})
		Sheen.Parent = Ring
		Give.Scale = 0.8
		Give.Parent = Circle
		Circle.Parent = Host

		-- Whole screen pixels: the disc's side (even, so its middle is a pixel corner), where it starts and its ring's width are
		-- worked out against the menus' scale, so its edge, ring and words are drawn sharp instead of between pixels.
		const function Snap()
			const Box = Host.AbsoluteSize

			if not Circle.Parent or Box.X < 1 or Box.Y < 1 then
				return
			end

			const Factor = math.max(Scale.Current(), 0.05)
			const Side = 2 * math.max(30, math.round(CircleSide / 2 * Factor))
			const Middle = Host.AbsolutePosition + Box / 2
			const Left, Top = Middle.X - Side / 2, Middle.Y - Side / 2
			-- (as shares of the holder: an offset is a whole layout pixel, which the menus' scale makes a fraction of a screen one)
			const Size = UDim2.fromScale(Side / Box.X, Side / Box.Y)
			const Position = UDim2.fromScale(0.5 + (math.round(Left) - Left) / Box.X, 0.5 + (math.round(Top) - Top) / Box.Y)

			Circle.Size = Size
			Circle.Position = Position
			Ripple.Size = Size
			Ripple.Position = Position
			Ring.Thickness = math.max(2, math.round(2.5 * Factor)) / Factor
			RippleRing.Thickness = math.max(1, math.round(1.6 * Factor)) / Factor
			-- (bigger under the mouse and smaller while held by an even number of pixels too, so it stays sharp at those sizes)
			const Step = 2 * math.max(2, math.round(Side * 0.025))

			GrowTo = (Side + Step) / Side
			ShrinkTo = (Side - Step) / Side
		end

		Snap()
		Host:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			task.defer(Snap)
		end)
		Host:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
			task.defer(Snap)
		end)

		local Hovered, Held, Shown = false, false, false
		-- (the screen was freed: nothing may start again, and the endless light round the ring is stopped)
		local Gone = false
		local SheenTween: Tween? = nil
		const Rippling: { Tween } = {}
		const Quick = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		-- To the look for the mouse: a touch bigger and the cover's full colour under it, a touch smaller while held.
		const function Paint()
			if not Shown or Gone then
				return
			end

			TweenService:Create(Give, Quick, { Scale = if Held then ShrinkTo elseif Hovered then GrowTo else 1 }):Play()
			TweenService:Create(Ring, Quick, { Color = if Hovered then Colors.Hover else Colors.Ring }):Play()
			TweenService:Create(Circle, Quick, {
				BackgroundColor3 = if Hovered then Colors.HoverFill else Colors.Fill,
				BackgroundTransparency = if Hovered then CircleHoverTransparency else CircleRestTransparency,
			}):Play()
		end

		const function StopRipple()
			for _, Playing in Rippling do
				Playing:Cancel()
			end

			table.clear(Rippling)
			RippleRing.Transparency = 1
			RippleGrow.Scale = 1
		end

		-- (a ring that spreads and fades, again and again while the mouse is on it: run by the engine, not a script each frame)
		const function StartRipple()
			StopRipple()

			if Gone then
				return
			end

			const Loop = TweenInfo.new(RippleSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1)

			RippleRing.Transparency = 0.2
			table.insert(Rippling, TweenService:Create(RippleRing, Loop, { Transparency = 1 }))
			table.insert(Rippling, TweenService:Create(RippleGrow, Loop, { Scale = 1.3 }))

			for _, Playing in Rippling do
				Playing:Play()
			end
		end

		-- (a button is hit as its square, so only the disc counts: the empty corners beside it neither light it nor play. The
		-- mouse is read from the window's corner, the disc from below the top bar)
		const function Inside(): boolean
			const Mouse = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
			const Middle = Circle.AbsolutePosition + Circle.AbsoluteSize / 2

			return (Mouse - Middle).Magnitude <= Circle.AbsoluteSize.X / 2
		end

		const function Track()
			const Over = not Gone and Inside()

			if Over == Hovered then
				return
			end

			Hovered = Over

			if not Over then
				Held = false
			end

			Paint()

			if Over and Shown then
				StartRipple()
			elseif not Over then
				StopRipple()
			end
		end

		Circle.MouseEnter:Connect(Track)
		Circle.MouseMoved:Connect(Track)
		Circle.MouseLeave:Connect(function()
			if Hovered or Held then
				Hovered, Held = false, false
				Paint()
				StopRipple()
			end
		end)
		Circle.MouseButton1Down:Connect(function()
			if not Gone and Inside() then
				Held = true
				Paint()
			end
		end)
		Circle.MouseButton1Up:Connect(function()
			if Held then
				Held = false
				Paint()
			end
		end)
		Circle.Activated:Connect(function()
			if not Gone and Inside() then
				Replay(Attempt)
			end
		end)

		const function Place()
			if not Nodes.IsInstanceValid(Button) then
				return
			end

			const Middle = Nodes.GetViewportRect(Item).y >= MiddleMinHeight

			Nodes.Set(Button, "visible", Middle)
			Nodes.Set(PlayButton, "visible", not Middle)
			-- (anchor_left first: it pushes anchor_right along)
			Nodes.Set(ReplayButton, "anchor_left", if Middle then 1 else 0.925)
			Nodes.Set(ReplayButton, "anchor_right", if Middle then 1 else 0.925)
			Nodes.Set(ReplayButton, "offset_right", if Middle then -8 else -32)
		end

		Place()
		-- (the window or Menu Scale changed; deferred, so the anchors aren't set inside the layout pass that told us)
		Nodes.Connect(Holder, "resized", function()
			task.defer(Place)
		end)

		-- Springs in once the screen is on (the scene's Load runs as it is added; before that it would play unseen): the disc and
		-- ring fade in as it grows past its size and settles, the words a moment after, and the light starts round the ring.
		-- Plain instances: the screen's own fades don't reach them, so these are theirs.
		Context.Scene.Load = function()
			if Gone then
				return
			end

			const Spring = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, 0.1)
			const Fade = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.1)

			TweenService:Create(Give, Spring, { Scale = 1 }):Play()
			TweenService:Create(Circle, Fade, { BackgroundTransparency = CircleRestTransparency }):Play()
			TweenService:Create(Ring, Fade, { Transparency = 0 }):Play()
			TweenService:Create(Circle, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.28), { TextTransparency = 0 }):Play()
			const Sheening = TweenService:Create(Sheen, TweenInfo.new(SheenSeconds, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), { Rotation = 360 })

			SheenTween = Sheening
			Sheening:Play()
			task.delay(0.62, function()
				if Gone then
					return
				end

				Shown = true

				if Hovered then
					Paint()
					StartRipple()
				end
			end)
		end

		-- (freed with the screen: the loops that never end on their own are stopped, and nothing starts again)
		table.insert(Connections, function()
			Gone = true
			StopRipple()

			if SheenTween then
				SheenTween:Cancel()
			end
		end)
	end

	Nodes.Connect(ReplayButton, "pressed", function()
		const Path = if Attempt.IsReplay then `{Constants.UserFolder}/replays/{Attempt.Replays[1].ID}.phxr` else Attempt.ReplayPath

		if FileSystem.Exists(Path) then
			PlayReplay(Path, if Attempt.IsReplay then Attempt.Replays[1] else nil)
		end
	end)

	Nodes.OnProcess(Item, function()
		Follow(Item, Holder)
	end)

	const function OnDestroy()
		StopBackdrop()

		-- (a moment later, once the screen has faded and its labels are gone)
		if CoverKey then
			task.delay(2, Images.Unregister, CoverKey)
		end

		for _, Disconnect in Connections do
			Disconnect()
		end
	end

	Context.Scene.Destroy = OnDestroy
end

return New
