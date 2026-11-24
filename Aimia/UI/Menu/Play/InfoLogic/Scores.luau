--!strict
--!optimize 2

--[[
	The leaderboard's text, rows and visibility: a score panel's labels (ScorePanel.Setup), the replay path and label, and
	the map info's row layout (MapInfoContainer.LoadLeaderboard and toggleLeaderboard).

	Design Notes
		A score that did not qualify shows its progress against the map length, dimmed; a qualifying one its value.
		Rows show at most 8 scores; the collapsed list shows 4 rows' height (the expanded list of toggleLeaderboard).
]]

const Constants = require("../../../../Constants")
const Leaderboard = require("../../../../Map/Leaderboard")
const Format = require("./Format")
const UtilString = require("../../../../Util/String")

const MaxRows = 8
const CollapsedRows = 4
const RowHeight = 100

-- The accuracy label: two decimals and a percent sign.
-- @src scripts/ui/menu/play/ScorePanel.cs:Setup L57
const function AccuracyText(Accuracy: number): string
	return `{Format.Fixed(Accuracy, 2)}%`
end

-- The speed label: two decimals and an x.
-- @src scripts/ui/menu/play/ScorePanel.cs:Setup L58
const function SpeedText(Speed: number): string
	return `{Format.Fixed(Speed, 2)}x`
end

-- The score label and whether it is dimmed: the value for a qualifying score, otherwise the progress over the map length.
-- @src scripts/ui/menu/play/ScorePanel.cs:Setup L61-70
const function ScoreText(Score: Leaderboard.Score): (string, boolean)
	if Score.Qualifies then
		return UtilString.PadMagnitude(Score.Value), false
	end

	const Progress = UtilString.FormatTime(math.max(0, Score.Progress) / 1000)
	const Length = UtilString.FormatTime(Score.MapLength / 1000)

	return `{Progress} / {Length}`, true
end

-- The relative time label of a score: its time against now (both Unix seconds).
-- @src scripts/ui/menu/play/ScorePanel.cs:Setup L59
const function TimeText(Now: number, Time: number): string
	return UtilString.FormatUnixTimePretty(Now, Time)
end

-- The names of a score's enabled modifiers, in the order the score holds them (one icon each).
-- @src scripts/ui/menu/play/ScorePanel.cs:Setup L72-81
const function EnabledModifiers(Modifiers: { Leaderboard.ModifierEntry }): { string }
	const Names: { string } = {}

	for _, Entry in Modifiers do
		if Entry.Value then
			table.insert(Names, Entry.Key)
		end
	end

	return Names
end

-- The replay file of an attempt.
-- @src scripts/ui/menu/play/ScorePanel.cs:Replay L86
const function ReplayPath(AttemptID: string): string
	return `{Constants.UserFolder}/replays/{AttemptID}.phxr`
end

-- The button label of a score panel: VIEW when the replay exists, otherwise REPLAY NOT FOUND.
-- @src scripts/ui/menu/play/ScorePanel.cs:tweenHover L39
const function ReplayLabel(Exists: boolean): string
	return if Exists then "VIEW" else "REPLAY NOT FOUND"
end

-- The leaderboard file of a map.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:LoadLeaderboard L486
const function PbsPath(MapName: string): string
	return `{Constants.UserFolder}/pbs/{MapName}`
end

-- Whether the leaderboard list is shown: the file was read and has scores.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:LoadLeaderboard L491
const function ListVisible(Board: Leaderboard.Leaderboard): boolean
	return Board.Valid and Board.ScoreCount > 0
end

-- The rows built: at most 8.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:LoadLeaderboard L499
const function VisibleRows(ScoreCount: number): number
	return math.min(MaxRows, ScoreCount)
end

-- The background alpha byte of row Index (0-based): every other row is 8, the rest 0.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:LoadLeaderboard L505
const function RowAlpha(Index: number): number
	return Index % 2 * 8
end

-- The leaderboard's offset_top: expanded to the rows shown (at most 4), or the collapsed height of one row.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:toggleLeaderboard L557
const function ExpandedOffsetTop(Show: boolean, ScoreCount: number): number
	return -RowHeight * (if Show then math.min(CollapsedRows, ScoreCount) else 1)
end

return {
	AccuracyText = AccuracyText,
	SpeedText = SpeedText,
	ScoreText = ScoreText,
	TimeText = TimeText,
	EnabledModifiers = EnabledModifiers,
	ReplayPath = ReplayPath,
	ReplayLabel = ReplayLabel,
	PbsPath = PbsPath,
	ListVisible = ListVisible,
	VisibleRows = VisibleRows,
	RowAlpha = RowAlpha,
	ExpandedOffsetTop = ExpandedOffsetTop,
}
