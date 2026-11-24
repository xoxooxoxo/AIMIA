--!strict
--!optimize 2

--[[
	The arithmetic of the in-game HUD scripts (scripts/game/ui/*.cs, scripts/game/managers/HudManager.cs) without Roblox: bar
	widths and their lerp steps, the multiplier and accuracy texts, the hit popup's lateness and score, the combo ring's fill
	and vertices, and the modifier icons' spacing.

	Representation
		Times are milliseconds, speeds are multipliers and widths are viewport pixels. The values the source keeps as float are
		float32 (Numbers.F32), computed in the source's order.

	Design Notes
		The combo ring is drawn with frames instead of combo_progress.gdshader: each edge of the polygon is two pieces, the
		part up to the progress filled (RingFill is that fraction). The shader colours by fragment angle, so an edge split at
		its angular fraction matches it along the edge's angle, not exactly along its length.
]]

const Numbers = require("../../Numbers")
const TextUtil = require("../../Util/String")

-- Mathf.Epsilon (float): the tolerance of IsEqualApprox, relative above one and never below it.
const EpsilonF = 0.00001

-- The health and progress bars: 32 px at zero, 10.24 px per health point, 1024 px across the map.
const BarMinimum = 32
const HealthScale = Numbers.F32(10.24)
const ProgressScale = 1024

-- The health lerp's clamp on the speed (HPLerpValue).
const HealthLerpMinimum = 10
const HealthLerpMaximum = 100

-- The modifier icons: 0.75 units apart.
const ModifierSpacing = 0.75

-- The popup score's lateness terms: 25 ms free, then the factor loses 1 per 150 ms.
const FreeLateness = 25
const LatenessSpan = 150

-- The highest uint, the saturation of a (uint) cast of a double (.NET 10).
const UintMax = 4294967295

-- The multiplier step whose ring is orange (Color8(255, 140, 0)).
const MaxMultiplier = 8

-- Mathf.IsEqualApprox (float): exact equality, else a tolerance of Epsilon times the magnitude of Left, at least Epsilon.
-- @src engine/Mathf.cs:IsEqualApprox L952-967
const function IsEqualApprox(Left: number, Right: number): boolean
	if Left == Right then
		return true
	end

	const Tolerance = math.max(EpsilonF * math.abs(Left), EpsilonF)

	return math.abs(Left - Right) < Tolerance
end

-- Mathf.MoveToward (float): steps From toward To by at most Step, landing on To.
-- @src engine/Mathf.cs:MoveToward L1293-1299
const function MoveToward(From: number, To: number, Step: number): number
	if math.abs(To - From) <= Step then
		return To
	end

	return From + (if To > From then Step else -Step)
end

-- Mathf.Lerp (float): From + (To - From) * Weight, the weight unclamped.
const function Lerp(From: number, To: number, Weight: number): number
	return Numbers.F32(From + Numbers.F32(To - From) * Weight)
end

-- The weight of one physics step of the health bar's lerp: the step times the clamped HPLerpValue.
-- @src scripts/game/ui/HealthBar.cs:_PhysicsProcess L17-17
const function HealthLerpWeight(Delta: number, HPLerp: number): number
	return Numbers.F32(Numbers.F32(Delta) * math.clamp(Numbers.F32(HPLerp), HealthLerpMinimum, HealthLerpMaximum))
end

-- The health bar's target width: 32 px plus 10.24 px per health point.
-- @src scripts/game/ui/HealthBar.cs:OnStatsUpdated L30-30
const function HealthTargetWidth(Health: number): number
	return Numbers.F32(BarMinimum + Numbers.F32(Numbers.F32(Health) * HealthScale))
end

-- The progress bar's width: 32 px plus 1024 px scaled by the progress over the map's length.
-- @src scripts/game/ui/ProgressBar.cs:Process L27-27
const function ProgressWidth(Progress: number, Length: number): number
	return Numbers.F32(BarMinimum + Numbers.F32(Numbers.F32(Progress / Length) * ProgressScale))
end

-- The combo multiplier progress as the ring's fraction: the progress over the increment (a float).
-- @src scripts/game/ui/PanelLeft.cs:OnStatsUpdated L50-50
const function MultiplierFraction(Progress: number, Increment: number): number
	return Numbers.F32(Progress / Increment)
end

-- The colour of the ring's fill at a multiplier: orange at the top step, white below (the RGB of a Color8).
-- @src scripts/game/ui/PanelLeft.cs:OnStatsUpdated L52-58
const function MultiplierColour(Multiplier: number): (number, number, number)
	if Multiplier == MaxMultiplier then
		return 1, Numbers.F32(140 / 255), 0
	end

	return 1, 1, 1
end

-- The ring's fraction of the polygon's edge Index (0-based) that is filled at Progress: the part of its angle the sweep
-- has passed, from 0 to 1. The sweep runs clockwise from the top (the shader's frag_angle).
-- @src scripts/shaders/combo_progress.gdshader:fragment L3-47
const function RingFill(Index: number, Sides: number, Progress: number): number
	const SideAngle = 360 / Sides
	const Fraction = (Progress * 360 - Index * SideAngle) / SideAngle

	return math.clamp(Fraction, 0, 1)
end

-- The offset of polygon vertex Index (0-based) from the centre of a ring of Radius, clockwise from the top, in canvas pixels
-- with Y down (the shader's points).
-- @src scripts/shaders/combo_progress.gdshader:fragment L6-16
const function RingVertex(Index: number, Sides: number, Radius: number): (number, number)
	const Angle = Index * 2 * math.pi / Sides

	return Radius * math.sin(Angle), -Radius * math.cos(Angle)
end

-- The accuracy text: "100.00%" until a note is judged, else the accuracy with two decimals.
-- @src scripts/game/ui/PanelRight.cs:OnStatsUpdated L60-60
const function AccuracyText(Hits: number, Misses: number, Accuracy: number): string
	if Hits + Misses == 0 then
		return "100.00%"
	end

	return string.format("%.2f%%", Accuracy)
end

-- The multiplier text, "3x".
-- @src scripts/game/ui/PanelLeft.cs:OnStatsUpdated L49-49
const function MultiplierText(Multiplier: number): string
	return `{Multiplier}x`
end

-- The progress label: the time played over the length, both as m:ss (never negative played time).
-- @src scripts/game/ui/Progress.cs:Process L10-10
const function ProgressText(Progress: number, Length: number): string
	return `{TextUtil.FormatTime(math.max(0, Progress) / 1000)} / {TextUtil.FormatTime(Length / 1000)}`
end

-- The speed label: two decimals and an x, "1.50x".
-- @src scripts/game/ui/Speed.cs:Init L11-11
const function SpeedText(Speed: number): string
	return string.format("%.2fx", Speed)
end

-- The speed label's alpha: invisible at 1x, 100 of 255 otherwise.
-- @src scripts/game/ui/Speed.cs:Init L9-9
const function SpeedAlpha(Speed: number): number
	if Speed == 1 then
		return 0
	end

	return Numbers.F32(100 / 255)
end

-- The skip prompt once the last note is passed; nil keeps the prompt's text.
-- @src scripts/game/ui/Skip.cs:OnSkipAvailable L43-43
const function SkipCompleteText(PassedNotes: number, NoteCount: number): string?
	if PassedNotes >= NoteCount then
		return "Press Space to complete"
	end

	return nil
end

-- The lateness a hit popup uses: a replay's stored lateness, else the whole-millisecond gap from the note over the speed.
-- The progress is the attempt's, not the judgment override the runner uses.
-- @src scripts/game/ui/Grid.cs:onHitResultChanged L86-88
const function PopupLateness(IsReplay: boolean, StoredLateness: number, Progress: number, NoteMillisecond: number, Speed: number): number
	if IsReplay then
		return StoredLateness
	end

	return Numbers.F32((Numbers.TruncInt32(Progress) - NoteMillisecond) / Speed)
end

-- The score a hit popup shows: the hit's score with the popup's factor, a uint (a negative product saturates to 0).
-- @src scripts/game/ui/Grid.cs:onHitResultChanged L89-91
const function PopupScore(Lateness: number, ComboMultiplier: number, ModsMultiplier: number, Speed: number): number
	const Overshoot = Numbers.F32(math.max(0, Numbers.F32(Lateness - FreeLateness)))
	const Factor = Numbers.F32(1 - Numbers.F32(Overshoot / LatenessSpan))

	return math.clamp(Numbers.Trunc(100 * ComboMultiplier * ModsMultiplier * Factor * ((Speed - 1) / 2.5 + 1)), 0, UintMax)
end

-- The x of modifier icon Index (0-based) of Count icons: centred on the template, 0.75 apart.
-- @src scripts/game/managers/HudManager.cs:positionModifiers L40-40
const function ModifierOffset(Index: number, Count: number): number
	return Numbers.F32((Index - (Count - 1) / 2) * ModifierSpacing)
end

return {
	IsEqualApprox = IsEqualApprox,
	MoveToward = MoveToward,
	Lerp = Lerp,
	HealthLerpWeight = HealthLerpWeight,
	HealthTargetWidth = HealthTargetWidth,
	ProgressWidth = ProgressWidth,
	MultiplierFraction = MultiplierFraction,
	MultiplierColour = MultiplierColour,
	RingFill = RingFill,
	RingVertex = RingVertex,
	AccuracyText = AccuracyText,
	MultiplierText = MultiplierText,
	ProgressText = ProgressText,
	SpeedText = SpeedText,
	SpeedAlpha = SpeedAlpha,
	SkipCompleteText = SkipCompleteText,
	PopupLateness = PopupLateness,
	PopupScore = PopupScore,
	ModifierOffset = ModifierOffset,
}
