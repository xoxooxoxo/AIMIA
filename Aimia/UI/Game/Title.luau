--!strict
--!optimize 2

--[[
	scripts/game/ui/Title.cs: the map's pretty title (Runner/HUD/Title/Label, a Label3D that wraps at 2500 px). Hidden by
	SuperSimpleHUD; the text is set once per attempt.
]]

const AttemptModule = require("../../Game/Attempt")
const UIComponent = require("./UIComponent")

type Attempt = AttemptModule.Attempt

-- The label's node in the game scene, and its canvas: the 2500 px wrap width, and room for a few lines of 64 px text.
const LabelPath = "Runner/HUD/Title/Label"
const Canvas = vector.create(2500, 512, 0)

-- @src scripts/game/ui/Title.cs:Init L8-12
const function New(Context: UIComponent.Context): UIComponent.Component
	const Label = UIComponent.NewLabel(Context.World.Hud, "Title", UIComponent.SceneLabel(LabelPath, Canvas, true))

	-- @src scripts/game/ui/Title.cs:Init L8-12
	const function Init()
		const AttemptValue = Context.Runner.Attempt :: Attempt

		UIComponent.SetLabelText(Label, AttemptValue.Map.PrettyTitle)
		UIComponent.InkLabel(Label) -- (not in the source: readable on a light map skin)
		UIComponent.SetLabelVisible(Label, not AttemptValue.Settings.SuperSimpleHUD.Value)
	end

	const function Exit() end

	return {
		Init = Init,
		Exit = Exit,
	}
end

return New
