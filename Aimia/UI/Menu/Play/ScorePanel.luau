--!strict
--!optimize 2

--[[
	ScorePanel.cs (scripts/ui/menu/play/ScorePanel.cs) on res://prefabs/score_panel.tscn: one row of a map's leaderboard (player,
	score, accuracy, speed, time, modifier icons) whose button shows the replay state on hover and watches the replay on press.

	Representation
		The row's score is kept per Item: MapInfoContainer calls New when it instantiates the row, then Setup with the score.

	Design Notes
		DEVIATION: the score label is dimmed with a theme font color override; the source duplicates its LabelSettings resource,
		which the port does not have.
		The replay is read with Replay.New and its map with MapParser.Decode; the start goes through GameStart.Play (phase 3).
]]

const BaseScene = require("../../Scenes/BaseScene")
const CameraMode = require("../../../Game/Camera/CameraMode")
const FileSystem = require("../../../Util/FileSystem")
const GameStart = require("./GameStart")
const Leaderboard = require("../../../Map/Leaderboard")
const MapParser = require("../../../Map/MapParser")
const MapTypes = require("../../../Map/MapTypes")
const Misc = require("../../../Util/Misc")
const Modifier = require("../../../Game/Modifiers/Modifier")
const Nodes = require("../../Nodes")
const ReplayFile = require("../../../Map/Replay")
const SceneBuilder = require("../../SceneBuilder")
const ScoreLogic = require("./InfoLogic/Scores")
const SkinManager = require("../../../Skinning/SkinManager")
const Tween = require("../../Tween")
const Textures = require("./Textures")

const DimmedGray = 160 / 255

const Scores: { [SceneBuilder.Item]: Leaderboard.Score } = {}

-- Watches the replay of this row's score, when its file exists.
-- @src scripts/ui/menu/play/ScorePanel.cs:Replay L84-95
const function Watch(Item: SceneBuilder.Item)
	const Score = Scores[Item]

	if not Score then
		return
	end

	const Path = ScoreLogic.ReplayPath(Score.AttemptID)

	if not FileSystem.Exists(Path) then
		return
	end

	const Watched = ReplayFile.New(Path)

	-- (a file that didn't read whole, like one left by a run stopped while it loaded, would freeze the replay)
	if not Watched.Valid or not Watched.Frames or not Watched.Notes or not Watched.MapFilePath then
		return
	end

	const Map = MapParser.Decode(Watched.MapFilePath :: string) :: MapTypes.Map

	GameStart.Play(
		Map,
		Watched.Speed,
		Watched.StartFrom,
		Watched.CameraMode :: CameraMode.CameraMode,
		Watched.Modifiers :: { Modifier.Modifier },
		{ Watched }
	)
end

-- The button's hover: the label says VIEW or REPLAY NOT FOUND, and the hover panel fades in or out.
-- @src scripts/ui/menu/play/ScorePanel.cs:_Ready L35-45
const function TweenHover(Item: SceneBuilder.Item, Hover: SceneBuilder.Item, Label: SceneBuilder.Item, Show: boolean)
	const Score = Scores[Item]

	if Score then
		Nodes.Set(Label, "text", ScoreLogic.ReplayLabel(FileSystem.Exists(ScoreLogic.ReplayPath(Score.AttemptID))))
	end

	const Running = Tween.Create(Item)

	Tween.SetEase(Running, Tween.EaseType.Out)
	Tween.SetTrans(Running, Tween.TransitionType.Quart)
	Tween.TweenProperty(Running, Hover, "modulate", { Color = { 1, 1, 1, if Show then 1 else 0 } }, 0.25)
end

-- @src scripts/ui/menu/play/ScorePanel.cs:_Ready L20-50
const function New(Item: SceneBuilder.Item, Context: BaseScene.Context)
	const Button = Nodes.GetNode(Item, "Button")
	const Hover = Nodes.GetNode(Button, "Hover")
	const Label = Nodes.GetNode(Hover, "Label")

	Nodes.Connect(Button, "mouse_entered", function()
		TweenHover(Item, Hover, Label, true)
	end)
	Nodes.Connect(Button, "mouse_exited", function()
		TweenHover(Item, Hover, Label, false)
	end)
	Nodes.Connect(Button, "pressed", function()
		Watch(Item)
	end)

	table.insert(Item.Cleanup, function()
		Scores[Item] = nil
	end)
end

-- Setup(score): the labels, and the modifier icons of the enabled modifiers, from the row's template.
-- @src scripts/ui/menu/play/ScorePanel.cs:Setup L52-82
const function Setup(Item: SceneBuilder.Item, Score: Leaderboard.Score)
	Scores[Item] = Score

	Nodes.Set(Nodes.GetNode(Item, "Player"), "text", Score.Player)
	Nodes.Set(Nodes.GetNode(Item, "Accuracy"), "text", ScoreLogic.AccuracyText(Score.Accuracy))
	Nodes.Set(Nodes.GetNode(Item, "Speed"), "text", ScoreLogic.SpeedText(Score.Speed))
	Nodes.Set(Nodes.GetNode(Item, "Time"), "text", ScoreLogic.TimeText(os.time(), Score.Time))

	const ScoreLabel = Nodes.GetNode(Item, "Score")
	const Text, Dimmed = ScoreLogic.ScoreText(Score)

	Nodes.Set(ScoreLabel, "text", Text)

	if Dimmed then
		Nodes.Set(ScoreLabel, "theme_override_colors/font_color", { Color = { DimmedGray, DimmedGray, DimmedGray, 1 } })
	end

	const Modifiers = Nodes.GetNode(Item, "Modifiers")
	const Template = Nodes.GetNode(Modifiers, "ModifierTemplate")

	for _, Name in ScoreLogic.EnabledModifiers(Score.Modifiers) do
		const Icon = Nodes.Duplicate(Template)

		Nodes.Set(Icon, "texture", Textures(Misc.GetModIcon(Name, SkinManager.Skin)))
		Nodes.Set(Icon, "visible", true)
		Nodes.AddChild(Modifiers, Icon)
	end
end

return {
	New = New,
	Setup = Setup,
}
