--!strict
--!optimize 2

--[[
	scripts/game/ui/Speed.cs: the speed label (Runner/HUD/Speed/Label, a Label3D under the Speed node's transform). It is
	invisible at 1x and shows the speed to two decimals otherwise. Set once per attempt. Not in the source: near solid with a dark
	edge, readable on light map skins.
]]

const HudLogic = require("./HudLogic")
const UIComponent = require("./UIComponent")

-- The label's node in the game scene, and its canvas (a 512 x 64 px text box).
const LabelPath = "Runner/HUD/Speed/Label"
const Canvas = vector.create(512, 64, 0)

-- @src scripts/game/ui/Speed.cs:Init L7-11
const function New(Context: UIComponent.Context): UIComponent.Component
	const Label = UIComponent.NewLabel(Context.World.Hud, "Speed", UIComponent.SceneLabel(LabelPath, Canvas, false))

	-- @src scripts/game/ui/Speed.cs:Init L7-11
	const function Init()
		const Speed = Context.Runner.Speed
		const Alpha = HudLogic.SpeedAlpha(Speed)

		-- (not in the source: the scene draws it white at a faint alpha, unreadable on a light map skin; when it shows it's near
		-- solid with a thin edge, and near black on a light skin: UIComponent.InkLabel)
		UIComponent.InkLabel(Label, true) -- (the HUD's bottom row)
		UIComponent.SetLabelAlpha(Label, if Alpha > 0 then math.max(Alpha, 0.9) else 0)
		UIComponent.SetLabelText(Label, HudLogic.SpeedText(Speed))
	end

	const function Exit() end

	return {
		Init = Init,
		Exit = Exit,
	}
end

return New
