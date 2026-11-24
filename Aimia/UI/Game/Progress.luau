--!strict
--!optimize 2

--[[
	scripts/game/ui/Progress.cs: the played time over the map's length (Runner/HUD/Progress/Label, a Label3D). Hidden by
	SuperSimpleHUD; its text follows the attempt every frame.
]]

const AttemptModule = require("../../Game/Attempt")
const HudLogic = require("./HudLogic")
const UIComponent = require("./UIComponent")

type Attempt = AttemptModule.Attempt

-- The label's node in the game scene, and its canvas (a 1024 x 128 px text box).
const LabelPath = "Runner/HUD/Progress/Label"
const Canvas = vector.create(1024, 128, 0)

-- @src scripts/game/ui/Progress.cs:Init L9-11
const function New(Context: UIComponent.Context): UIComponent.Component
	const Label = UIComponent.NewLabel(Context.World.Hud, "Progress", UIComponent.SceneLabel(LabelPath, Canvas, false))

	-- @src scripts/game/ui/Progress.cs:Init L9-11
	const function Init()
		UIComponent.InkLabel(Label) -- (not in the source: readable on a light map skin)
		UIComponent.SetLabelVisible(Label, not (Context.Runner.Attempt :: Attempt).Settings.SuperSimpleHUD.Value)
	end

	-- The whole second and the length the text was last made for. The text shows whole seconds, so it is made (two times
	-- formatted, and the label's text read back to compare) only when one of them changes, not every frame.
	local ShownSecond = -1
	local ShownLength = -1

	-- @src scripts/game/ui/Progress.cs:Process L13-16
	const function Process(_: number, AttemptValue: Attempt)
		const Second = (math.max(0, AttemptValue.Progress) / 1000) // 1

		if Second == ShownSecond and AttemptValue.Length == ShownLength then
			return
		end

		ShownSecond = Second
		ShownLength = AttemptValue.Length
		UIComponent.SetLabelText(Label, HudLogic.ProgressText(AttemptValue.Progress, AttemptValue.Length))
	end

	const function Exit() end

	return {
		Init = Init,
		Exit = Exit,
		Process = Process,
	}
end

return New
