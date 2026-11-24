--!strict
--!optimize 2

--[[
	Hit judgment of scripts/game/judgments/HitJudgment.cs. ProcessHitJudgments is not implemented upstream (it throws
	NotImplementedException), and the port keeps that.
]]

const Modifier = require("../Modifiers/Modifier")

export type HitJudgment = {}

-- @src scripts/game/judgments/HitJudgment.cs:HitJudgment L3-12
const function New(): HitJudgment
	return {}
end

-- @src scripts/game/judgments/HitJudgment.cs:ProcessHitJudgments L5-11
const function ProcessHitJudgments(Judgment: HitJudgment, Attempt: Modifier.Attempt): { boolean }
	error("The method or operation is not implemented.", 0)
end

return {
	New = New,
	ProcessHitJudgments = ProcessHitJudgments,
}
