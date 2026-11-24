--!strict
--!optimize 2

--[[
	scripts/game/ui/PanelRight.cs: the accuracy panel (Runner/HUD/PanelRight, a quad with the PanelRightViewport's background,
	accuracy, hit and miss counts with their icons, the sum, and the alpha-gradient line). A hit or a miss sets its count to full
	opacity, which then eases back to 0.62 each physics step.

	Design Notes
		DEVIATION(shader): alpha_gradient.gdshader is a UIGradient on the line's style box: transparent at both ends, opaque at
		the centre (alpha = 1 - 2 |u - 0.5|), as the shader's COLOR.a. The gradient is set once after the tree is built; the line
		is not redrawn by the attempt.
		The simple and super-simple HUDs hide the widgets, and the simple misses label stands in for the misses count.
]]

const AttemptModule = require("../../Game/Attempt")
const HitResult = require("../../Game/Judgments/HitResult")
const HudLogic = require("./HudLogic")
const Items = require("../Item")
const Nodes = require("../Nodes")
const Numbers = require("../../Numbers")
const Signal = require("../../Util/Signal")
const SkinManager = require("../../Skinning/SkinManager")
const TextUtil = require("../../Util/String")
const UIComponent = require("./UIComponent")

type Attempt = AttemptModule.Attempt

-- The panel's node and its viewport.
const PanelPath = "Runner/HUD/PanelRight"
const ViewportPath = "Runner/HUD/PanelRight/PanelRightViewport"

-- The resting opacity of the hit and miss counts, and the fade's rate (1.5 a second).
const RestOpacity = Numbers.F32(0.62)
const FadeRate = 1.5

-- @src scripts/game/ui/PanelRight.cs:Init L14-44
const function New(Context: UIComponent.Context): UIComponent.Component
	const Panel = UIComponent.NewPanel(Context.World.Hud, PanelPath, ViewportPath)
	const Background = UIComponent.Control(Panel, "Background")
	const HitsIcon = UIComponent.Control(Panel, "HitsIcon")
	const MissesIcon = UIComponent.Control(Panel, "MissesIcon")
	const Accuracy = UIComponent.Control(Panel, "Accuracy")
	const Hits = UIComponent.Control(Panel, "Hits")
	const Misses = UIComponent.Control(Panel, "Misses")
	const SimpleMisses = UIComponent.Control(Panel, "SimpleMisses")
	const Sum = UIComponent.Control(Panel, "Sum")
	const Line = UIComponent.Control(Panel, "Line")
	const Widgets = Nodes.GetChildren(Panel.Built.Root :: Items.Item)

	local HitOpacity = RestOpacity
	local MissOpacity = RestOpacity

	-- The modulate tables are reused every step (Nodes.Set keeps the table it is given).
	const HitTint = { Color = { 1, 1, 1, 1 } }
	const MissTint = { Color = { 1, 1, 1, 1 } }
	const FullTint = { Color = { 1, 1, 1, 1 } }

	-- The line's transparency gradient: transparent at both ends, opaque at the centre.
	const LineHost = Line.StyleHost
	const Gradient = Instance.new("UIGradient")

	Gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})

	if LineHost then
		Gradient.Parent = LineHost
	end

	-- @src scripts/game/ui/PanelRight.cs:OnStatsUpdated L60-66
	const function OnStatsUpdated(AttemptValue: Attempt)
		Nodes.Set(Accuracy, "text", HudLogic.AccuracyText(AttemptValue.Hits, AttemptValue.Misses, AttemptValue.Accuracy))
		Nodes.Set(Hits, "text", `{AttemptValue.Hits}`)
		Nodes.Set(Misses, "text", `{AttemptValue.Misses}`)
		Nodes.Set(SimpleMisses, "text", `{AttemptValue.Misses}`)
		Nodes.Set(Sum, "text", TextUtil.PadMagnitude(AttemptValue.Sum))
	end

	-- @src scripts/game/ui/PanelRight.cs:OnHitStateChanged L68-82
	const function OnHitStateChanged(_: number, Result: number)
		if Result == HitResult.Miss then
			MissOpacity = 1
			FullTint.Color[4] = 1
			Nodes.Set(Misses, "modulate", FullTint)
		elseif Result == HitResult.Hit then
			HitOpacity = 1
			FullTint.Color[4] = 1
			Nodes.Set(Hits, "modulate", FullTint)
		end
	end

	-- @src scripts/game/ui/PanelRight.cs:Init L14-44
	const function Init()
		const AttemptValue = Context.Runner.Attempt :: Attempt
		const Visible = not AttemptValue.Settings.SimpleHUD.Value and not AttemptValue.Settings.SuperSimpleHUD.Value
		const BackgroundKey = UIComponent.TextureKey(SkinManager.Skin.PanelRightBackgroundImage)
		const HitsKey = UIComponent.TextureKey(SkinManager.Skin.HitsImage)
		const MissesKey = UIComponent.TextureKey(SkinManager.Skin.MissesImage)

		if BackgroundKey then
			Nodes.Set(Background, "texture", { Path = BackgroundKey })
		end

		if HitsKey then
			Nodes.Set(HitsIcon, "texture", { Path = HitsKey })
		end

		if MissesKey then
			Nodes.Set(MissesIcon, "texture", { Path = MissesKey })
		end

		for _, Widget in Widgets do
			Nodes.Set(Widget, "visible", Visible)
		end

		Nodes.Set(SimpleMisses, "visible", not Visible)

		-- (not in the source: the words read on a light map skin, near black there, and the counts' tints keep that colour)
		const Ink = if UIComponent.Ink.Light then UIComponent.DarkInk else Color3.new(1, 1, 1)

		for _, Tint in { HitTint, MissTint, FullTint } do
			Tint.Color[1], Tint.Color[2], Tint.Color[3] = Ink.R, Ink.G, Ink.B
		end

		UIComponent.InkPanel(Panel, { Accuracy, Hits, Misses, SimpleMisses, Sum })

		-- (the hit and miss icons' pastel green and pink are faint on a light skin: half as bright there, so they keep their colour)
		const IconTint = if UIComponent.Ink.Light then 0.5 else 1

		Nodes.Set(HitsIcon, "modulate", { Color = { IconTint, IconTint, IconTint, 1 } })
		Nodes.Set(MissesIcon, "modulate", { Color = { IconTint, IconTint, IconTint, 1 } })

		Signal.Connect(Context.Runner.AttemptStatsUpdated, OnStatsUpdated)
		Signal.Connect(Context.Runner.HitResultChanged, OnHitStateChanged)
	end

	-- @src scripts/game/ui/PanelRight.cs:_ExitTree L24-29
	const function Exit()
		Signal.Disconnect(Context.Runner.AttemptStatsUpdated, OnStatsUpdated)
		Signal.Disconnect(Context.Runner.HitResultChanged, OnHitStateChanged)
	end

	-- @src scripts/game/ui/PanelRight.cs:_PhysicsProcess L46-60
	const function PhysicsProcess(Delta: number)
		if HitOpacity > RestOpacity then
			HitOpacity = HudLogic.MoveToward(HitOpacity, RestOpacity, Delta * FadeRate)
			HitTint.Color[4] = HitOpacity
			Nodes.Set(Hits, "modulate", HitTint)
		end

		if MissOpacity > RestOpacity then
			MissOpacity = HudLogic.MoveToward(MissOpacity, RestOpacity, Delta * FadeRate)
			MissTint.Color[4] = MissOpacity
			Nodes.Set(Misses, "modulate", MissTint)
		end
	end

	return {
		Init = Init,
		Exit = Exit,
		PhysicsProcess = PhysicsProcess,
	}
end

return New
