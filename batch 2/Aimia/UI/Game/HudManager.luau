--!strict
--!optimize 2

--[[
	scripts/game/managers/HudManager.cs: the HUD of an attempt. New builds the components in the source's tree order (Grid,
	HealthBar, PanelLeft, PanelRight, ProgressBar, Progress, Title, Combo, Speed, Skip) into the world's HUD folder. Init (the
	runner's Play) starts them for the attempt and clears the modifier icons. Each frame an attempt is running, the physics
	components step (once, by the frame's time) and then every component processes. DisplayModifier adds a modifier icon and spaces the icons.
	Destroy releases the components and removes the HUD from the world.

	Representation
		Hud is a record: its world and runner, its components in tree order, its modifier icons, the template modifier's
		transform and tint (the scene's TemplateModifier, read for those only), the physics time not yet stepped, and the
		function that ends its per-frame subscription.

	Design Notes
		DEVIATION(smoothness): Godot runs _PhysicsProcess at 60 steps a second with a fixed step. Here the physics components
		step once a frame by the frame's time (at most MaxPhysicsSteps steps of it; time beyond that is dropped, as Godot drops
		it), and each eases by its 60 Hz step's weight raised to the frame's share of a step, so it eases as fast as at 60 Hz
		but moves every frame: fixed steps moved the health bar, the combo ring and the count fades every fourth frame at 240 FPS. Nothing runs without an attempt: the source's HudManager returns early, and the physics
		components dereference the attempt.
		New yields while the panels' text is measured (SceneBuilder), so it runs in a task.
]]

const Combo = require("./Combo")
const Grid = require("./Grid")
const HealthBar = require("./HealthBar")
const HudLogic = require("./HudLogic")
const Items = require("../Item")
const Math = require("../../Godot/Math")
const Misc = require("../../Util/Misc")
const Modifier = require("../../Game/Modifiers/Modifier")
const Nodes = require("../Nodes")
const PanelLeft = require("./PanelLeft")
const PanelRight = require("./PanelRight")
const ProgressBar = require("./ProgressBar")
const Progress = require("./Progress")
const Runner = require("../../Game/Runner")
const SettingsManager = require("../../SettingsManager")
const Signal = require("../../Util/Signal")
const SkinManager = require("../../Skinning/SkinManager")
const SkinSets = require("../../Skinning/SkinSets")
const Skip = require("./Skip")
const Speed = require("./Speed")
const Title = require("./Title")
const GameWorld = require("../../Game/View/GameWorld")
const UIComponent = require("./UIComponent")
const WorldTransform = require("../../Game/View/WorldTransform")

export type TemplateModifier = {
	Transform: Math.Transform3D,
	Modulate: { number },
}

export type Hud = {
	World: GameWorld.World,
	Runner: Runner.Runner,
	Components: { UIComponent.Component },
	Icons: { UIComponent.Sprite },
	Template: TemplateModifier,
	Accumulator: number,
	Disconnect: () -> (),
	Placed: { Placement },
	IconExtents: { [UIComponent.Sprite]: vector },
	Scale: number,
	ScaleLinks: { () -> () },
	-- (the Spin camera's slide taken out of the HUD, Follow: each part's place in the unmoved HUD, and the place Follow last
	-- gave it)
	FollowBase: { [BasePart]: CFrame },
	FollowApplied: { [BasePart]: CFrame },
	Followed: boolean,
}

-- A HUD part as it was built, for HUD Scale: its group decides how it moves (see Origin).
type Placement = {
	Part: BasePart,
	Group: string,
	Size: Vector3,
	Rotation: CFrame,
	Base: vector,
}

-- HUD Scale's groups, by the parts' names. Top grows down from the title's top edge, Bottom grows up from the icon row's
-- bottom edge (both at the default field of view of 70), Side spreads out with the bars, and Centre only grows. The hit and miss
-- popups are the grid's and stay as they are.
const Groups = {
	["Runner/HUD/ProgressBar"] = "Top",
	Progress = "Top",
	Title = "Top",
	["Runner/HUD/Health"] = "Bottom",
	Speed = "Bottom",
	Skip = "Bottom",
	["Runner/HUD/PanelLeft"] = "Side",
	["Runner/HUD/PanelRight"] = "Side",
	Combo = "Centre",
}

const TopEdge = 8.57
const BottomEdge = -8.82

-- Not in the source: room the HUD makes for a map skin's border (Skinning/SkinSets). The bars above and below the grid and the
-- side panels move out until their nearest edges clear the frame, at the HUD Scale in use, with an allowance for the camera's
-- slide (Camera Parallax moves the grid's plane further across the screen than the HUD behind it). The bars move no further
-- than keeps the modifier row under them on the screen. Nothing moves without a border.
local NeedGrid = 0
local PushTop = 0
local PushBottom = 0
local PushSide = 0

-- the camera's distance to the grid's plane, to the bars' and to the side panels'; where the bars and panels are built and
-- how big (game.tscn, in Godot units), and the modifier row's height and its icons' half size
const GridDepth = 3.75
const HudDepth = 13.75
const PanelDepth = 12.75
const BarY = 6.3
const BarHalf = 0.4
const PanelX = 7.5
const PanelHalf = 2.17
const IconY = -8.5
const IconHalf = 0.32
const BorderLine = 0.03
const BorderGap = 0.03
const MaxSlide = 0.15
const MaxPushSide = 0.4

const function SetBorderRoom(Settings: any)
	const Picture, Side = SkinSets.BorderOf(Settings.Border.Value)

	if not Picture then
		NeedGrid = 0

		return
	end

	const Parallax = Settings.CameraParallax.Value
	const Slide = math.min((if Parallax == Parallax then math.clamp(Parallax, 0, 1) else 0) * 1.5 * (1 - GridDepth / HudDepth), MaxSlide)

	NeedGrid = Side / 2 + BorderLine + Slide + BorderGap
end

-- The pushes (HUD units) at scale S.
const function SetPushes(S: number)
	if NeedGrid <= 0 then
		PushTop, PushBottom, PushSide = 0, 0, 0

		return
	end

	const BarToGrid = GridDepth / HudDepth
	const TopInner = (TopEdge + (BarY - TopEdge) * S - BarHalf * S) * BarToGrid
	const BottomInner = -(BottomEdge + (-BarY - BottomEdge) * S + BarHalf * S) * BarToGrid
	const SideInner = (PanelX * math.max(S, 1) - PanelHalf * S) * GridDepth / PanelDepth
	-- (the modifier row's lowest edge stays on the screen: the room under it at this field of view)
	const Camera = workspace.CurrentCamera
	const Fov = if Camera then Camera.FieldOfView else 70
	const Screen = HudDepth * math.tan(math.rad(Fov) / 2)
	const IconLow = -(BottomEdge + (IconY - BottomEdge) * S) + IconHalf * S
	const BottomRoom = math.max(0, Screen - IconLow - 0.15)

	PushTop = math.clamp(NeedGrid - TopInner, 0, 1) / BarToGrid
	PushBottom = math.min(math.max(NeedGrid - BottomInner, 0) / BarToGrid, BottomRoom)
	PushSide = math.clamp(NeedGrid - SideInner, 0, MaxPushSide) * PanelDepth / GridDepth
end

-- Where a part of Group built at Base goes at scale S (SetPushes has run for S).
const function Origin(Group: string, Base: vector, S: number): vector
	if Group == "Top" then
		return vector.create(Base.x, TopEdge + (Base.y - TopEdge) * S + PushTop, Base.z)
	elseif Group == "Bottom" then
		return vector.create(Base.x, BottomEdge + (Base.y - BottomEdge) * S - PushBottom, Base.z)
	elseif Group == "Side" then
		const X = Base.x * math.max(S, 1)

		return vector.create(X + (if X < 0 then -PushSide else PushSide), Base.y, Base.z)
	end

	return Base
end

-- The player's own HUD Scale (watchers keep theirs), kept so the side panels stay on a narrow window.
const function EffectiveScale(): number
	const Settings = SettingsManager.Settings
	const Wanted = if Settings then Settings.HudScale.Value else 1
	const S = if Wanted == Wanted then math.clamp(Wanted, 0.5, 1.25) else 1
	const Camera = workspace.CurrentCamera
	const Size = Camera.ViewportSize
	const Aspect = if Size.Y > 0 then Size.X / Size.Y else 16 / 9
	const Room = 0.868 * Aspect * math.tan(math.rad(Camera.FieldOfView / 2)) / math.tan(math.rad(35))

	return math.min(S, math.max(1, Room))
end

-- Not in the source: whether the attempt's map skin is a light one (SkinSets' Light, the background the player plays on,
-- with no Space Color over it), for the HUD's dark words (UIComponent.Ink), and whether its bottom is light too (a picture
-- with a dark bottom, SkinSets' DarkBottom, keeps the HUD's bottom row white). A spectated player's or a replay's look counts.
const function LightSkin(Settings: any): (boolean, boolean)
	local Name = Settings.GameSpace.Value

	if Name == "skin" then
		Name = SkinManager.Skin.Config.GameSpace
	end

	const Set = if type(Name) == "string" then SkinSets.Get(Name) else nil
	const Light = Set ~= nil and Set.Light == true and Settings.SpaceColor.Value == "default"

	return Light, Light and not (Set :: any).DarkBottom
end

-- The physics step (1 / 60 s) and the most steps one frame runs (Godot's max_physics_steps_per_frame).
const PhysicsStep = 1 / 60
const MaxPhysicsSteps = 8

-- The template the modifier icons copy: the scene's TemplateModifier node.
const TemplatePath = "Runner/HUD/TemplateModifier"

-- One frame of the HUD: the physics steps the frame's time allows, then every component's process. Nothing runs without an
-- attempt.
-- @src scripts/game/managers/HudManager.cs:_Process L58-65
const function Frame(Hud: Hud, Delta: number)
	const AttemptValue = Hud.Runner.Attempt

	if AttemptValue == nil then
		Hud.Accumulator = 0

		return
	end

	-- (one physics step a frame, by the frame's time: see the header)
	const Step = math.min(Delta, MaxPhysicsSteps * PhysicsStep)

	Hud.Accumulator = 0

	for _, Component in Hud.Components do
		if Component.PhysicsProcess then
			Component.PhysicsProcess(Step)
		end
	end

	for _, Component in Hud.Components do
		if Component.Process then
			Component.Process(Delta, AttemptValue)
		end
	end
end

-- Spaces the modifier icons 0.75 apart, centred on the template's x, at the template's height and depth.
-- @src scripts/game/managers/HudManager.cs:positionModifiers L40-46
const function PositionModifiers(Hud: Hud)
	const Count = #Hud.Icons
	const At = Hud.Template.Transform.Origin
	const S = Hud.Scale

	for Index, Icon in Hud.Icons do
		const Extents = Hud.IconExtents[Icon] or Icon.Extents

		Hud.IconExtents[Icon] = Extents
		Icon.Extents = vector.create(Extents.x * S, Extents.y * S, Extents.z)
		UIComponent.MoveSprite(Icon, Origin("Bottom", vector.create(HudLogic.ModifierOffset(Index - 1, Count) * S, At.y, At.z), S))
	end
end

-- Not in the source. With the Spin camera the HUD stays on the grid (2026-11-17, a player's report the owner passed on: "its
-- moving with the cursor as if its on lock rather than staying attached to the grid"; the 2026-11-13 version turned the HUD
-- with the camera, so it held still on the screen as with the Lock camera while the grid swung under it). The HUD keeps its
-- place in the world, as in the source, so the camera's turn carries it across the screen exactly as it carries the grid. The
-- camera's slide (Camera Parallax and the orbit's pivot, CameraSpin) would move the grid's plane further across the screen than
-- the HUD behind it, so that slide is taken out of the HUD: each part moves by the slide times (1 - its depth / the grid's
-- depth), which keeps it on the lines of sight through a picture of itself lying on the grid's plane. On the screen the grid,
-- the notes and the HUD turn as one piece. Sizes and turns are untouched, and the troll nudge (CameraNudge) still moves the
-- whole view. The grid's own hit and miss popups are on the grid already. A part's place in the unmoved HUD is the last one the
-- HUD's own code gave it: a placement by HUD Scale or the modifier row shows up as a change and becomes the new base. With the
-- camera unturned (every other camera mode) nothing is done. Runs each frame after the camera is placed (Scenes/Game), and
-- again after HUD Scale moves the parts (a window or field-of-view change can come after that frame's Follow).
const StaysOnGrid = { HitPopup = true, MissIcon = true }

-- where the eye rests (the Spin camera unturned, the cursor in the middle: GridDepth in front of the grid's plane), in the
-- Workspace
const GridDepthStuds = GridDepth * WorldTransform.StudsPerUnit
const RestEye = WorldTransform.Origin + vector.create(0, 0, GridDepthStuds)

const function Follow(Hud: Hud)
	const Camera = Hud.World.Camera
	const Rotation, Position = Camera.Rotation, Camera.Position

	-- (a camera that isn't finite moves nothing: a NaN written into a part never equals itself again, so the next frame would
	-- take it as the part's base and the HUD would stay gone. A Spin replay's cursor is NaN at its last frame's exact progress,
	-- ReplayManager's kept upstream quirk, and CameraSpin turns the camera by it)
	if not (math.isfinite(Rotation.x) and math.isfinite(Rotation.y) and math.isfinite(Rotation.z)) then
		return
	end

	if not (math.isfinite(Position.x) and math.isfinite(Position.y) and math.isfinite(Position.z)) then
		return
	end

	const Turned = Rotation.x ~= 0 or Rotation.y ~= 0 or Rotation.z ~= 0

	if not Turned and not Hud.Followed then
		return
	end

	const Folder = Hud.World.Hud

	if not Folder or not Folder.Parent then
		return
	end

	Hud.Followed = Turned

	-- (how far the eye has slid from where it rests; the turn itself needs nothing, the HUD is in the world)
	local Slide = Vector3.zero

	if Turned then
		Slide = (Position * WorldTransform.StudsPerUnit + WorldTransform.Origin) - RestEye
	end

	for _, Part in Folder:GetChildren() do
		if not Part:IsA("BasePart") or StaysOnGrid[Part.Name] then
			continue
		end

		const Now = Part.CFrame

		if Hud.FollowApplied[Part] ~= Now then
			Hud.FollowBase[Part] = Now
		end

		const Base = Hud.FollowBase[Part]
		const Depth = RestEye.Z - Base.Position.Z
		const Wanted = if Turned and Depth > 0 then Base + Slide * (1 - Depth / GridDepthStuds) else Base

		if Wanted ~= Now then
			Part.CFrame = Wanted
		end

		Hud.FollowApplied[Part] = Part.CFrame
	end
end

-- Sizes and places the HUD's parts for HUD Scale. Only the parts move: the bars and panels draw on their own canvases.
const function ApplyScale(Hud: Hud)
	const S = EffectiveScale()

	Hud.Scale = S
	SetPushes(S)

	for _, Entry in Hud.Placed do
		if Entry.Part.Parent then
			Entry.Part.Size = Vector3.new(Entry.Size.X * S, Entry.Size.Y * S, Entry.Size.Z)
			Entry.Part.CFrame = Entry.Rotation + (WorldTransform.Origin + Origin(Entry.Group, Entry.Base, S) * WorldTransform.StudsPerUnit)

			-- (the title wraps at its unscaled width: a long title at a big scale would run off the screen)
			if Entry.Group == "Top" and Entry.Part.Name == "Title" then
				const Gui = Entry.Part:FindFirstChildOfClass("SurfaceGui")
				const Text = Gui and Gui:FindFirstChild("Text")

				if Text and Text:IsA("TextLabel") then
					-- (a sharpened title is laid out at its full canvas, in pixels, under a UIScale (UIComponent.SharpenLabel): its
					-- width is given in those pixels, or the UIScale would shrink it a second time and it would wrap at half width)
					const Fit = Text:FindFirstChildOfClass("UIScale")
					const Share = math.min(1, 1 / S)

					Text.AnchorPoint = Vector2.new(0.5, 0.5)
					Text.Position = UDim2.fromScale(0.5, 0.5)

					if Fit and Fit.Scale > 0 then
						const Canvas = (Gui :: SurfaceGui).CanvasSize

						Text.Size = UDim2.fromOffset(Canvas.X / Fit.Scale * Share, Canvas.Y / Fit.Scale)
					else
						Text.Size = UDim2.fromScale(Share, 1)
					end
				end
			end
		end
	end

	PositionModifiers(Hud)
	-- (the Spin camera's slide taken out again at once: this can run from a window or field-of-view signal after the frame's own
	-- Follow)
	Follow(Hud)
end

-- Builds the HUD's components into the world's HUD folder. Yields while the panels' text is measured.
-- @src scripts/game/managers/HudManager.cs:Init L14-32
const function New(World: GameWorld.World, RunnerValue: Runner.Runner): Hud
	const Context = {
		World = World,
		Runner = RunnerValue,
	}

	const Components = {
		Grid(Context),
		HealthBar(Context),
		PanelLeft(Context),
		PanelRight(Context),
		ProgressBar(Context),
		Progress(Context),
		Title(Context),
		Combo(Context),
		Speed(Context),
		Skip(Context),
	}

	const Template = {
		Transform = UIComponent.GlobalTransform(TemplatePath),
		Modulate = table.clone(Items.ColorComponents(UIComponent.NodeOf(TemplatePath)["modulate"])),
	}

	local Hud: Hud

	Hud = {
		World = World,
		Runner = RunnerValue,
		Components = Components,
		Icons = {},
		Template = Template,
		Accumulator = 0,
		Disconnect = Nodes.OnFrame(function(Delta: number)
			Frame(Hud, Delta)
		end),
		Placed = {},
		IconExtents = {},
		Scale = 1,
		ScaleLinks = {},
		FollowBase = setmetatable({}, { __mode = "k" }) :: any,
		FollowApplied = setmetatable({}, { __mode = "k" }) :: any,
		Followed = false,
	}

	for _, Part in World.Hud:GetChildren() do
		const Group = Groups[Part.Name]

		if Group and Part:IsA("BasePart") then
			table.insert(Hud.Placed, {
				Part = Part,
				Group = Group,
				Size = Part.Size,
				Rotation = Part.CFrame.Rotation,
				Base = (Part.Position - WorldTransform.Origin) / WorldTransform.StudsPerUnit,
			})
		end
	end

	const function Rescale()
		ApplyScale(Hud)
	end

	const Settings = SettingsManager.Settings

	if Settings then
		Signal.Connect(Settings.HudScale.Updated, Rescale)
		table.insert(Hud.ScaleLinks, function()
			Signal.Disconnect(Settings.HudScale.Updated, Rescale)
		end)
	end

	const Resized = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(Rescale)
	const Zoomed = workspace.CurrentCamera:GetPropertyChangedSignal("FieldOfView"):Connect(Rescale)

	table.insert(Hud.ScaleLinks, function()
		Resized:Disconnect()
		Zoomed:Disconnect()
	end)

	ApplyScale(Hud)

	return Hud
end

-- Starts the HUD for the attempt: the modifier icons of the last attempt are removed, then every component initialises.
-- @src scripts/game/managers/HudManager.cs:Init L14-32
const function Init(Hud: Hud)
	for _, Icon in Hud.Icons do
		Icon.Part:Destroy()
	end

	table.clear(Hud.Icons)
	table.clear(Hud.IconExtents)

	const AttemptValue = Hud.Runner.Attempt

	-- (before the components start: their words take the skin's ink)
	if AttemptValue then
		UIComponent.Ink.Light, UIComponent.Ink.LightBottom = LightSkin(AttemptValue.Settings)
	else
		UIComponent.Ink.Light, UIComponent.Ink.LightBottom = false, false
	end

	for _, Component in Hud.Components do
		Component.Init()
	end

	-- (the attempt's own border: a replay or a spectated player's look makes its own room)

	if AttemptValue then
		SetBorderRoom(AttemptValue.Settings)
	end

	ApplyScale(Hud)
end

-- Adds an icon for a modifier (its skin texture, or none) on the template's transform, and spaces the icons.
-- @src scripts/game/managers/HudManager.cs:DisplayModifier L23-28
const function DisplayModifier(Hud: Hud, Mod: Modifier.Modifier)
	const Texture = Misc.GetModIcon(Mod.Name, SkinManager.Skin)
	const Icon = UIComponent.NewSprite(Hud.World.Hud, "Modifier", {
		Transform = Hud.Template.Transform,
		PixelSize = UIComponent.SpritePixelSize,
		Key = UIComponent.TextureKey(Texture),
		Modulate = table.clone(Hud.Template.Modulate),
		-- (not in the source's no-depth sprite: a surface drawn always on top never showed under AIMIA's screen, so the icons were
		-- invisible; nothing in the world passes in front of the icon row)
		AlwaysOnTop = false,
	})

	-- (not in the source: the icons were white at the template's faint alpha and vanished on light map skins. They're near solid
	-- now with a thin dark edge, as the HUD's speed is, so they read on any background and still look like the HUD's own text;
	-- on a light skin they're near black with a light edge, as its words are: UIComponent.Ink)
	const Light = UIComponent.Ink.LightBottom -- (the icon row is the HUD's bottom)

	Icon.Modulate[4] = math.max(Icon.Modulate[4], 0.92)

	if Light then
		Icon.Modulate[1], Icon.Modulate[2], Icon.Modulate[3] = UIComponent.DarkInk.R, UIComponent.DarkInk.G, UIComponent.DarkInk.B
	end

	Icon.Image.ZIndex = 2

	for _, Step in { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		const Edge = Icon.Image:Clone()

		Edge.Name = "Edge"
		Edge.ZIndex = 1
		Edge.ImageColor3 = if Light then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
		Edge.ImageTransparency = if Light then 0.6 else 0.45
		Edge.Position = UDim2.fromOffset(Step[1], Step[2])
		Edge.Parent = Icon.Gui
	end

	UIComponent.SetSpriteTransparency(Icon, Icon.Transparency)

	table.insert(Hud.Icons, Icon)
	PositionModifiers(Hud)
end

-- Releases the components and removes the HUD from the world.
const function Destroy(Hud: Hud)
	Hud.Disconnect()

	for _, Unlink in Hud.ScaleLinks do
		Unlink()
	end

	table.clear(Hud.ScaleLinks)
	table.clear(Hud.Placed)
	table.clear(Hud.IconExtents)

	for _, Component in Hud.Components do
		Component.Exit()
	end

	Hud.World.Hud:ClearAllChildren()
	table.clear(Hud.Icons)
end

return {
	New = New,
	Init = Init,
	DisplayModifier = DisplayModifier,
	Follow = Follow,
	Destroy = Destroy,
}
