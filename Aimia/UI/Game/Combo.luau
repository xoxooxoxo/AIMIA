--!strict
--!optimize 2

--[[
	scripts/game/ui/Combo.cs: the combo counter (Runner/HUD/Combo/Label, a Label3D). Shown unless SuperSimpleHUD or the
	alternative counter (which moves it to PanelLeft) is on. Its text follows the attempt's combo.

	Design Notes
		The label's modulate is alpha 0 in game.tscn and nothing changes it, so its fill is invisible and only its outline (a
		white 4 px outline at 39% alpha) shows the number, as the source draws it.
]]

const AttemptModule = require("../../Game/Attempt")
const Signal = require("../../Util/Signal")
const UIComponent = require("./UIComponent")

type Attempt = AttemptModule.Attempt

-- The label's node in the game scene, and its canvas (a 1024 x 128 px text box).
const LabelPath = "Runner/HUD/Combo/Label"
const Canvas = vector.create(1024, 128, 0)

-- @src scripts/game/ui/Combo.cs:Init L13-22
const function New(Context: UIComponent.Context): UIComponent.Component
	const Label = UIComponent.NewLabel(Context.World.Hud, "Combo", UIComponent.SceneLabel(LabelPath, Canvas, false))

	-- @src scripts/game/ui/Combo.cs:OnStatsUpdated L24-27
	const function OnStatsUpdated(AttemptValue: Attempt)
		UIComponent.SetLabelText(Label, `{AttemptValue.Combo}`)
	end

	-- @src scripts/game/ui/Combo.cs:Init L13-22
	const function Init()
		const Settings = (Context.Runner.Attempt :: Attempt).Settings

		UIComponent.SetLabelVisible(Label, not Settings.SuperSimpleHUD.Value and not Settings.AltComboCounter.Value)
		Signal.Connect(Context.Runner.AttemptStatsUpdated, OnStatsUpdated)
	end

	-- @src scripts/game/ui/Combo.cs:OnExitTree L8-13
	const function Exit()
		Signal.Disconnect(Context.Runner.AttemptStatsUpdated, OnStatsUpdated)
	end

	return {
		Init = Init,
		Exit = Exit,
	}
end

return New
