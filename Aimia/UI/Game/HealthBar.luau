--!strict
--!optimize 2

--[[
	scripts/game/ui/HealthBar.cs: the health panel (Runner/HUD/Health, a quad with the HealthViewport's background and bar). The
	bar's width eases toward the target width each physics step, at the HPLerpValue speed; a dead attempt's bar and background
	are faded to half opacity.

	Design Notes
		The eased width keeps its value across attempts, as the source's field does. The physics steps run at 60 a second
		(HudManager), so the ease is the source's per-step lerp.
]]

const AttemptModule = require("../../Game/Attempt")
const HudLogic = require("./HudLogic")
const Nodes = require("../Nodes")
const Numbers = require("../../Numbers")
const Signal = require("../../Util/Signal")
const SkinManager = require("../../Skinning/SkinManager")
const UIComponent = require("./UIComponent")

type Attempt = AttemptModule.Attempt

-- The bar's node and its viewport, and the bar's full width and height (targetSize = 1088 x 80 at the start).
const PanelPath = "Runner/HUD/Health"
const ViewportPath = "Runner/HUD/Health/HealthViewport"
const FullWidth = 1088
const BarHeight = 80

-- The dead attempt's tint: 0xffffff80 (white at half opacity).
const DeadColour = { Color = { 1, 1, 1, Numbers.F32(128 / 255) } }

-- @src scripts/game/ui/HealthBar.cs:Init L14-24
const function New(Context: UIComponent.Context): UIComponent.Component
	const Panel = UIComponent.NewPanel(Context.World.Hud, PanelPath, ViewportPath)
	const Main = UIComponent.Control(Panel, "Main")
	const Background = UIComponent.Control(Panel, "Background")

	local TargetWidth = FullWidth
	local CurrentWidth = FullWidth

	-- @src scripts/game/ui/HealthBar.cs:OnStatsUpdated L27-36
	const function OnStatsUpdated(AttemptValue: Attempt)
		TargetWidth = HudLogic.HealthTargetWidth(AttemptValue.Health)

		if not AttemptValue.IsReplay and AttemptValue.Health <= 0 then
			-- (near black on a light map skin, as the bar is)
			const Light = UIComponent.Ink.LightBottom
			const Ink = if Light then UIComponent.DarkInk else Color3.new(1, 1, 1)

			Nodes.Set(Main, "modulate", { Color = { Ink.R, Ink.G, Ink.B, DeadColour.Color[4] } })
			Nodes.Set(Background, "modulate", { Color = { 1, 1, 1, DeadColour.Color[4] * (if Light then 0.2 else 1) } })
		end
	end

	-- @src scripts/game/ui/HealthBar.cs:Init L14-24
	const function Init()
		const Skin = SkinManager.Skin
		const Key = UIComponent.TextureKey(Skin.HealthImage)
		const BackgroundKey = UIComponent.TextureKey(Skin.HealthBackgroundImage)
		const AttemptValue = Context.Runner.Attempt :: Attempt
		const Visible = not AttemptValue.Settings.SuperSimpleHUD.Value

		if Key then
			Nodes.Set(Main, "texture", { Path = Key })
		end

		if BackgroundKey then
			Nodes.Set(Background, "texture", { Path = BackgroundKey })
		end

		-- (not in the source: near black on a light map skin, where the white bar can't be seen: UIComponent.Ink. The bar is the
		-- HUD's bottom row, so a light picture with a dark bottom keeps it as it is)
		const Light = UIComponent.Ink.LightBottom
		const Ink = if Light then UIComponent.DarkInk else Color3.new(1, 1, 1)

		Nodes.Set(Main, "modulate", { Color = { Ink.R, Ink.G, Ink.B, 1 } })
		-- (its dark track goes mostly see-through on a light skin, so the filled part stands out from it)
		Nodes.Set(Background, "modulate", { Color = { 1, 1, 1, if Light then 0.2 else 1 } })
		Nodes.Set(Main, "visible", Visible)
		Nodes.Set(Background, "visible", Visible)

		Signal.Connect(Context.Runner.AttemptStatsUpdated, OnStatsUpdated)
	end

	-- @src scripts/game/ui/HealthBar.cs:Exit L8-13
	const function Exit()
		Signal.Disconnect(Context.Runner.AttemptStatsUpdated, OnStatsUpdated)
	end

	-- The width the bar was last given (none yet). Setting the size lays the bar out again even when it is unchanged (size is
	-- always laid out), and it was set every physics step. Now it is set when the bar's end crosses a half pixel, as finer moves
	-- don't show on whole pixels, and exactly once the ease comes to rest: at a steady health, most of a song (the default HP
	-- Lerp reaches its target within a step or two), the bar isn't laid out at all.
	local DrawnWidth = -1

	-- @src scripts/game/ui/HealthBar.cs:_PhysicsProcess L17-19
	const function PhysicsProcess(Delta: number)
		const AttemptValue = Context.Runner.Attempt :: Attempt
		-- (the lerp's 60 Hz step weight raised to this frame's share of a step, so it eases as fast at any frame rate; a step
		-- weight of one or more, as the default HP Lerp of 60 gives, still lands at once)
		const StepWeight = HudLogic.HealthLerpWeight(1 / 60, AttemptValue.Settings.HPLerpValue.Value)
		const Weight = 1 - math.max(0, 1 - StepWeight) ^ (Delta * 60)
		const Previous = CurrentWidth

		CurrentWidth = HudLogic.Lerp(CurrentWidth, TargetWidth, Weight)

		if CurrentWidth ~= DrawnWidth and (CurrentWidth == Previous or CurrentWidth * 2 // 1 ~= DrawnWidth * 2 // 1) then
			DrawnWidth = CurrentWidth
			Nodes.Set(Main, "size", vector.create(CurrentWidth, BarHeight, 0))
		end
	end

	return {
		Init = Init,
		Exit = Exit,
		PhysicsProcess = PhysicsProcess,
	}
end

return New
