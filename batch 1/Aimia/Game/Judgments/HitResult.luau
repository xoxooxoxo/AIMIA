--!strict
--!optimize 2

--[[
	HitResult enum of scripts/game/judgments/HitResult.cs as numbers: the source casts it (`(int)LastResult`), so the
	values stay numeric.
]]

export type HitResult = number

-- @src scripts/game/judgments/HitResult.cs:HitResult L3-8
const HitResult = {
	None = 0,
	Hit = 1,
	Miss = 2,
}

return HitResult
