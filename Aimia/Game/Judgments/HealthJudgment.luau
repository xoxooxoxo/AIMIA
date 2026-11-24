--!strict
--!optimize 2

--[[
	Health and fail state of an attempt, as scripts/game/judgments/HealthJudgment.cs. Nothing upstream uses it.

	Owned State
		Health and HealthStep are doubles. IsFailed is set once a fail is applied; Failed is fired with true.

	Design Notes
		Upstream quirks kept: ApplyAttempt's body is commented out, so the modifier lists stay empty and the default rules
		apply. The default fail rule answers Health > 0, so the first hit result fails the attempt while Health is positive.
		Failed is invoked without a null check: Signal.Invoke errors when no listener is connected, as C# throws on a null
		delegate.
]]

const Signal = require("../../Util/Signal")
const Modifier = require("../Modifiers/Modifier")

export type HealthJudgment = {
	IsFailed: boolean,
	Failed: Signal.Signal<boolean>,
	FailModifiers: { Modifier.Modifier },
	HealthModifiers: { Modifier.Modifier },
	Health: number,
	HealthStep: number,
}

-- @src scripts/game/judgments/HealthJudgment.cs:HealthJudgment L6-91
const function New(): HealthJudgment
	return {
		IsFailed = false,
		Failed = Signal.New(),
		FailModifiers = {},
		HealthModifiers = {},
		Health = 1,
		HealthStep = 15,
	}
end

-- @src scripts/game/judgments/HealthJudgment.cs:ApplyAttempt L20-34
const function ApplyAttempt(Attempt: Modifier.Attempt)
	-- Upstream registers the health and fail modifiers of the attempt here, in a commented-out body: nothing is registered.
end

-- @src scripts/game/judgments/HealthJudgment.cs:defaultHealthResult L70-82
const function DefaultHealthResult(Judgment: HealthJudgment, Hit: boolean)
	if Hit then
		Judgment.HealthStep = math.max(Judgment.HealthStep / 1.45, 15)
		Judgment.Health = math.min(100, Judgment.Health + Judgment.HealthStep / 1.75)
	else
		Judgment.Health = math.max(0, Judgment.Health - Judgment.HealthStep)
		Judgment.HealthStep = math.min(Judgment.HealthStep * 1.2, 100)
	end
end

-- @src scripts/game/judgments/HealthJudgment.cs:defaultFailResult L84-84
const function DefaultFailResult(Judgment: HealthJudgment): boolean
	return Judgment.Health > 0
end

-- @src scripts/game/judgments/HealthJudgment.cs:applyFail L86-90
const function ApplyFail(Judgment: HealthJudgment)
	Judgment.IsFailed = true
	Signal.Invoke(Judgment.Failed, true)
end

-- @src scripts/game/judgments/HealthJudgment.cs:ApplyHitObjectResult L36-68
const function ApplyHitObjectResult(Judgment: HealthJudgment, Hit: boolean)
	if #Judgment.HealthModifiers ~= 0 then
		for _, HealthModifier in Judgment.HealthModifiers do
			const ApplyHealthResult = assert(HealthModifier.ApplyHealthResult, "health modifier without ApplyHealthResult")

			Judgment.Health = ApplyHealthResult(Hit, Judgment.Health)
		end
	else
		DefaultHealthResult(Judgment, Hit)
	end

	if #Judgment.FailModifiers ~= 0 then
		for _, FailModifier in Judgment.FailModifiers do
			const CheckFailCondition = assert(FailModifier.CheckFailCondition, "fail modifier without CheckFailCondition")

			if CheckFailCondition(Hit, Judgment.Health) then
				ApplyFail(Judgment)
				break
			end
		end
	elseif DefaultFailResult(Judgment) then
		ApplyFail(Judgment)
	end
end

return {
	New = New,
	ApplyAttempt = ApplyAttempt,
	ApplyHitObjectResult = ApplyHitObjectResult,
}
