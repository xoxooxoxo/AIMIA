--!strict
--!optimize 2

--[[
	scripts/game/ui/PanelLeft.cs: the score panel (Runner/HUD/PanelLeft, a quad with the PanelLeftViewport's background, score,
	multiplier and alternative combo counter, and the multiplier ring). The ring eases its fill and its colour each physics step.

	Design Notes
		DEVIATION(shader): combo_progress.gdshader is drawn with frames instead of the shader. The ring is a polygon of
		ComboMultiplierIncrement sides (3 to 32) of radius 64 px in the 256 px MultiplierProgress panel, outlined 6 px thick.
		Each side is two frames: the part the sweep has passed (HudLogic.RingFill) in the ring's colour, and the rest in the
		background colour. A side is split at its angular fraction rather than per pixel, so the vertices are exact.
		The ring is rebuilt on Init when the sides change, as the shader's sides parameter is set on Init.
		The counter and the ring are controls of the viewport, so SimpleHUD and SuperSimpleHUD hide them with the others.
]]

const AttemptModule = require("../../Game/Attempt")
const HudLogic = require("./HudLogic")
const Items = require("../Item")
const Nodes = require("../Nodes")
const Numbers = require("../../Numbers")
const Signal = require("../../Util/Signal")
const SkinManager = require("../../Skinning/SkinManager")
const TextUtil = require("../../Util/String")
const UIComponent = require("./UIComponent")

type Attempt = AttemptModule.Attempt

-- The panel's node, its viewport, and the ring's control: a 256 px square, so its centre is (128, 128).
const PanelPath = "Runner/HUD/PanelLeft"
const ViewportPath = "Runner/HUD/PanelLeft/PanelLeftViewport"
const RingName = "MultiplierProgress"
const RingCenter = 128

-- The ring's radius, its line thickness (3 px either side of the line), its side count limits, and the background grey.
const RingRadius = 64
const RingThickness = 6
const MinSides = 3
const MaxSides = 32
const BackgroundGrey = Numbers.F32(0.155)

-- The ring's colour eases at 2 a second (Color.Lerp by delta * 2) and its progress at 16 (Mathf.Lerp by min(1, delta * 16)).
const ColourRate = 2
const ProgressRate = 16

-- @src scripts/game/ui/PanelLeft.cs:OnStatsUpdated L38-58
const function New(Context: UIComponent.Context): UIComponent.Component
	const Panel = UIComponent.NewPanel(Context.World.Hud, PanelPath, ViewportPath)
	const Background = UIComponent.Control(Panel, "Background")
	const Score = UIComponent.Control(Panel, "Score")
	const Multiplier = UIComponent.Control(Panel, "Multiplier")
	const AltCombo = UIComponent.Control(Panel, "ComboCount")
	const Holder = UIComponent.Control(Panel, RingName).Instance :: Frame
	const Widgets = Nodes.GetChildren(Panel.Built.Root :: Items.Item)

	const Edges: { Frame } = {}
	local Sides = 0
	local TargetProgress = 0
	local CurrentProgress = 0
	local TargetRed = 1
	local TargetGreen = 1
	local TargetBlue = 1
	local CurrentRed = 1
	local CurrentGreen = 1
	local CurrentBlue = 1
	-- (not in the source: on a light map skin the ring reads the other way round, its sweep near black and the rest light grey,
	-- or the white sweep vanished and the dark rest looked like the filled part: UIComponent.Ink)
	local EmptyGrey = BackgroundGrey
	local LightRing = false

	-- Places a piece of a side from one point to another in the ring's canvas, in a colour.
	-- @src scripts/shaders/combo_progress.gdshader:fragment L3-47
	const function SetPiece(Piece: Frame, FromX: number, FromY: number, ToX: number, ToY: number, Red: number, Green: number, Blue: number)
		const DeltaX = ToX - FromX
		const DeltaY = ToY - FromY
		const Length = vector.magnitude(vector.create(DeltaX, DeltaY, 0))

		Piece.Position = UDim2.fromOffset(RingCenter + (FromX + ToX) / 2, RingCenter + (FromY + ToY) / 2)
		Piece.Size = UDim2.fromOffset(Length, RingThickness)
		Piece.Rotation = math.deg(math.atan2(DeltaY, DeltaX))
		Piece.BackgroundColor3 = Color3.new(Red, Green, Blue)
	end

	-- Builds the ring's frames for a number of sides: a filled piece and an empty piece for each side.
	-- @src scripts/game/ui/PanelLeft.cs:Init L35-35
	const function RebuildRing(NewSides: number)
		for _, Edge in Edges do
			Edge:Destroy()
		end

		table.clear(Edges)

		Sides = NewSides

		for _ = 1, 2 * NewSides do
			const Edge = Instance.new("Frame")

			Edge.AnchorPoint = Vector2.new(0.5, 0.5)
			Edge.BorderSizePixel = 0
			Edge.Parent = Holder

			table.insert(Edges, Edge)
		end
	end

	-- What the ring was last drawn with: the pieces it was drawn on (RebuildRing makes new ones), each side's fill, and the
	-- filled pieces' colour.
	local DrawnOn: Frame? = nil
	const DrawnFills: { number } = {}
	local DrawnRed = -1
	local DrawnGreen = -1
	local DrawnBlue = -1

	-- Draws the ring at the eased progress and colour. Only what changed is written: the sides whose fill moved (the one the
	-- sweep is in) and, while the colour eases, the filled pieces' colour. It runs every physics step and used to rewrite 4
	-- properties of each of the ring's 6 to 64 pieces; at 8x every side is full, so once the colour settles it writes nothing.
	-- @src scripts/shaders/combo_progress.gdshader:fragment L3-47
	const function Redraw()
		if DrawnOn ~= Edges[1] then
			DrawnOn = Edges[1]
			table.clear(DrawnFills)
		end

		const Recolour = CurrentRed ~= DrawnRed or CurrentGreen ~= DrawnGreen or CurrentBlue ~= DrawnBlue
		const Colour = Color3.new(CurrentRed, CurrentGreen, CurrentBlue)

		DrawnRed, DrawnGreen, DrawnBlue = CurrentRed, CurrentGreen, CurrentBlue

		for Index = 0, Sides - 1 do
			const Fill = HudLogic.RingFill(Index, Sides, CurrentProgress)

			-- (a side whose fill hasn't moved keeps its pieces: only its filled piece takes a new colour)
			if Fill == DrawnFills[Index + 1] then
				if Recolour then
					Edges[2 * Index + 1].BackgroundColor3 = Colour
				end

				continue
			end

			DrawnFills[Index + 1] = Fill

			const StartX, StartY = HudLogic.RingVertex(Index, Sides, RingRadius)
			const EndX, EndY = HudLogic.RingVertex((Index + 1) % Sides, Sides, RingRadius)
			const SplitX = StartX + (EndX - StartX) * Fill
			const SplitY = StartY + (EndY - StartY) * Fill

			SetPiece(Edges[2 * Index + 1], StartX, StartY, SplitX, SplitY, CurrentRed, CurrentGreen, CurrentBlue)
			SetPiece(Edges[2 * Index + 2], SplitX, SplitY, EndX, EndY, EmptyGrey, EmptyGrey, EmptyGrey)
		end
	end

	-- @src scripts/game/ui/PanelLeft.cs:OnStatsUpdated L38-58
	const function OnStatsUpdated(AttemptValue: Attempt)
		Nodes.Set(Score, "text", TextUtil.PadMagnitude(AttemptValue.Score))
		Nodes.Set(Multiplier, "text", HudLogic.MultiplierText(AttemptValue.ComboMultiplier))
		Nodes.Set(AltCombo, "text", `{AttemptValue.Combo}`)

		TargetProgress = HudLogic.MultiplierFraction(AttemptValue.ComboMultiplierProgress, AttemptValue.ComboMultiplierIncrement)
		TargetRed, TargetGreen, TargetBlue = HudLogic.MultiplierColour(AttemptValue.ComboMultiplier)

		-- (a white sweep is near black on a light skin; the full multiplier's orange stays)
		if LightRing and TargetRed > 0.8 and TargetGreen > 0.8 and TargetBlue > 0.8 then
			TargetRed, TargetGreen, TargetBlue = UIComponent.DarkInk.R, UIComponent.DarkInk.G, UIComponent.DarkInk.B
		end
	end

	-- @src scripts/game/ui/PanelLeft.cs:Init L24-54
	const function Init()
		const AttemptValue = Context.Runner.Attempt :: Attempt
		const Key = UIComponent.TextureKey(SkinManager.Skin.PanelLeftBackgroundImage)
		const Visible = not AttemptValue.Settings.SimpleHUD.Value and not AttemptValue.Settings.SuperSimpleHUD.Value

		if Key then
			Nodes.Set(Background, "texture", { Path = Key })
		end

		RebuildRing(math.clamp(AttemptValue.ComboMultiplierIncrement, MinSides, MaxSides))

		for _, Widget in Widgets do
			Nodes.Set(Widget, "visible", Visible)
		end

		Nodes.Set(AltCombo, "visible", Visible and AttemptValue.Settings.AltComboCounter.Value)
		-- (not in the source: the score, multiplier and combo read on a light map skin)
		UIComponent.InkPanel(Panel, { Score, Multiplier, AltCombo })

		LightRing = UIComponent.Ink.Light
		EmptyGrey = if LightRing then 0.78 else BackgroundGrey

		if LightRing then
			CurrentRed, CurrentGreen, CurrentBlue = UIComponent.DarkInk.R, UIComponent.DarkInk.G, UIComponent.DarkInk.B
			TargetRed, TargetGreen, TargetBlue = CurrentRed, CurrentGreen, CurrentBlue
		end

		Redraw()
		Signal.Connect(Context.Runner.AttemptStatsUpdated, OnStatsUpdated)
	end

	-- @src scripts/game/ui/PanelLeft.cs:_ExitTree L17-22
	const function Exit()
		Signal.Disconnect(Context.Runner.AttemptStatsUpdated, OnStatsUpdated)
	end

	-- @src scripts/game/ui/PanelLeft.cs:_PhysicsProcess L32-37
	const function PhysicsProcess(Delta: number)
		-- (each lerp's 60 Hz step weight raised to this frame's share of a step: they ease as fast at any frame rate, and the
		-- HUD steps every frame, see HudManager)
		const Share = Delta * 60
		const ProgressWeight = 1 - (1 - math.min(1, ProgressRate / 60)) ^ Share
		const ColourWeight = 1 - (1 - ColourRate / 60) ^ Share

		CurrentProgress = HudLogic.Lerp(CurrentProgress, TargetProgress, ProgressWeight)
		CurrentRed = HudLogic.Lerp(CurrentRed, TargetRed, ColourWeight)
		CurrentGreen = HudLogic.Lerp(CurrentGreen, TargetGreen, ColourWeight)
		CurrentBlue = HudLogic.Lerp(CurrentBlue, TargetBlue, ColourWeight)

		-- (an F32 ease creeps on for seconds after it stops showing: it lands once within a thousandth of the ring, or half a
		-- level of 255 in every channel, so the ring isn't redrawn every frame for nothing)
		if math.abs(TargetProgress - CurrentProgress) < 0.001 then
			CurrentProgress = TargetProgress
		end

		if math.abs(TargetRed - CurrentRed) < 0.5 / 255 and math.abs(TargetGreen - CurrentGreen) < 0.5 / 255 and math.abs(TargetBlue - CurrentBlue) < 0.5 / 255 then
			CurrentRed, CurrentGreen, CurrentBlue = TargetRed, TargetGreen, TargetBlue
		end

		Redraw()
	end

	return {
		Init = Init,
		Exit = Exit,
		PhysicsProcess = PhysicsProcess,
	}
end

return New
