--!strict
--!optimize 2

--[[
	Processes score information for the player (combo multiplier, total score, grade rating), as
	scripts/game/judgments/ScoreJudgment.cs. The upstream class has no members yet.
]]

export type ScoreJudgment = {}

-- @src scripts/game/judgments/ScoreJudgment.cs:ScoreJudgment L6-6
const function New(): ScoreJudgment
	return {}
end

return New
