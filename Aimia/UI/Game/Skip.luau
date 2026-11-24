--!strict
--!optimize 2

--[[
	scripts/game/ui/Skip.cs: the skip prompt (Runner/HUD/Skip/Label, a Label3D). When a skip is available it pulses between 25%
	and 75% alpha, a sine ease of 0.75 s each way, forever; it reads "Press Space to complete" once the last note is passed.
	When the skip is no longer available the pulse stops and the prompt is invisible.

	Design Notes
		The pulse is two tweens: a first pass from the prompt's alpha (0) that ends at 75%, then a looping pass from 75% (the
		source's loop restarts each property from its current value, so the loop is 75% to 25% and back). Both use UI/Tween's
		method tweeners on the label's alpha; the label is not an item, so a property tweener cannot drive it.
]]

const AttemptModule = require("../../Game/Attempt")
const HudLogic = require("./HudLogic")
const MapModule = require("../../Map/Map")
const ObjectType = require("../../Map/Objects/ObjectType")
const Signal = require("../../Util/Signal")
const Tween = require("../Tween")
const UIComponent = require("./UIComponent")

type Attempt = AttemptModule.Attempt

-- The label's node in the game scene, and its canvas (a 1024 x 64 px text box).
const LabelPath = "Runner/HUD/Skip/Label"
const Canvas = vector.create(1024, 64, 0)

-- The pulse: 25% to 75% alpha, 0.75 s each way.
const LowAlpha = 0.25
const HighAlpha = 0.75
const PulseDuration = 0.75

-- @src scripts/game/ui/Skip.cs:Init L11-16
const function New(Context: UIComponent.Context): UIComponent.Component
	const Label = UIComponent.NewLabel(Context.World.Hud, "Skip", UIComponent.SceneLabel(LabelPath, Canvas, false))

	local Pulse: Tween.Tween? = nil

	-- The label's alpha, as the tweeners write it.
	const function SetAlpha(Value: number)
		UIComponent.SetLabelAlpha(Label, Value)
	end

	-- The looping pass: from 75% down to 25%, then back up, sine eased, forever.
	-- @src scripts/game/ui/Skip.cs:OnSkipAvailable L47-49
	const function StartLoop(): Tween.Tween
		const Created = Tween.Create(nil)

		Tween.SetTrans(Created, Tween.TransitionType.Sine)
		Tween.SetLoops(Created, 0)
		Tween.TweenMethod(Created, SetAlpha, HighAlpha, LowAlpha, PulseDuration)
		Tween.TweenMethod(Created, SetAlpha, LowAlpha, HighAlpha, PulseDuration)

		return Created
	end

	-- The first pass from the label's alpha to 25% and to 75%, then the loop.
	-- @src scripts/game/ui/Skip.cs:OnSkipAvailable L47-49
	const function StartPulse(): Tween.Tween
		const Created = Tween.Create(nil)

		Tween.SetTrans(Created, Tween.TransitionType.Sine)
		Tween.TweenMethod(Created, SetAlpha, Label.Modulate[4], LowAlpha, PulseDuration)
		Tween.TweenMethod(Created, SetAlpha, LowAlpha, HighAlpha, PulseDuration)
		Tween.TweenCallback(Created, function()
			Pulse = StartLoop()
		end)

		return Created
	end

	-- @src scripts/game/ui/Skip.cs:OnSkipAvailable L40-53
	const function OnSkipAvailable(AttemptValue: Attempt)
		const Text = HudLogic.SkipCompleteText(Context.Runner.ObjectIndicesStart[ObjectType.Note], #MapModule.GetNotes(AttemptValue.Map))

		-- (a VS round's song skips only at its end, Game.PauseOrSkipPressed: no prompt before that)
		if (AttemptValue :: any).Versus and not Text then
			return
		end

		if Text then
			UIComponent.SetLabelText(Label, Text)
		end

		if Pulse ~= nil then
			return
		end

		Pulse = StartPulse()
	end

	-- @src scripts/game/ui/Skip.cs:Process L27-35
	const function Process(_: number, AttemptValue: Attempt)
		const Running = Pulse

		if Running ~= nil and not AttemptValue.CanSkip then
			Tween.Kill(Running)
			Pulse = nil
			UIComponent.SetLabelAlpha(Label, 0)
		end
	end

	-- @src scripts/game/ui/Skip.cs:Init L11-16
	const function Init()
		UIComponent.InkLabel(Label, true) -- (not in the source: readable on a light map skin; it's in the HUD's bottom row)
		UIComponent.SetLabelText(Label, "Press Space to skip")
		Signal.Connect(Context.Runner.SkipAvailable, OnSkipAvailable)
	end

	-- @src scripts/game/ui/Skip.cs:OnExitTree L8-13
	const function Exit()
		Signal.Disconnect(Context.Runner.SkipAvailable, OnSkipAvailable)

		const Running = Pulse

		if Running ~= nil then
			Tween.Kill(Running)
			Pulse = nil
		end
	end

	return {
		Init = Init,
		Exit = Exit,
		Process = Process,
	}
end

return New
