--!strict
--!optimize 2

--[[
	MapInfoContainer.cs (scripts/ui/menu/play/MapInfoContainer.cs) on res://prefabs/map_info_container.tscn: the selected map's
	info panel (cover, labels, favorite, export, delete), its speed and start time, its actions (preview, camera, modifiers,
	speed presets, start) and its leaderboard. The formats are UI/Menu/Play/InfoLogic.

	Representation
		State per container, keyed by its Item: the map, the leaderboard, and the nodes the script reads. The children with
		their own scripts (the flat preview, the speed presets, the camera and modifier lists) are attached by New, and each
		score row by Leaderboard loading; MapInfo instantiates the container and calls New.

	Design Notes
		DEVIATION(link): LinkPopupButton (scripts/ui/LinkPopupButton.cs) is not ported: the artist link's text is set, its
		popup and OS.ShellOpen are not.
		Excluded: OS.ShellShowInFileManager (the export opens its folder).
		The video and copy buttons are commented out in the source and are not connected.
]]

const BaseScene = require("../../Scenes/BaseScene")
const CameraModes = require("./CameraModes")
const Constants = require("../../../Constants")
const Details = require("./InfoLogic/Details")
const Format = require("./InfoLogic/Format")
const FlatPreview = require("../../FlatPreview")
const FileSystem = require("../../../Util/FileSystem")
const GameStart = require("./GameStart")
const Input = require("../../Input")
const Leaderboard = require("../../../Map/Leaderboard")
const Lobby = require("../../../Multiplayer/Lobby")
const MapLogic = require("../../../Map/Map")
const MapManager = require("../../../Map/MapManager")
const MapParser = require("../../../Map/MapParser")
const MapTypes = require("../../../Map/MapTypes")
const Modifiers = require("./Modifiers")
const Nodes = require("../../Nodes")
const Notify = require("../../../Util/Notify")
const Scores = require("./InfoLogic/Scores")
const SceneBuilder = require("../../SceneBuilder")
const ScorePanel = require("./ScorePanel")
const Signal = require("../../../Util/Signal")
const SkinManager = require("../../../Skinning/SkinManager")
const SoundManager = require("../../../Audio/SoundManager")
const SkinProfile = require("../../../Skinning/SkinProfile")
const SpeedLogic = require("./InfoLogic/Speed")
const SpeedPresetButton = require("./SpeedPresetButton")
const StartFromLogic = require("./InfoLogic/StartFrom")
const Tween = require("../../Tween")
const Textures = require("./Textures")

const SpeedPresetNames = { "MinusMinus", "Minus", "Middle", "Plus", "PlusPlus" }
const ScrollAuto = 1
const ScrollShowNever = 3
const LeaderboardOffsetInfo = 64
const LeaderboardOffsetActions = 80
const LeaderboardOffsetBoard = 96
const DimOpaque = 128 / 255

type State = {
	Item: SceneBuilder.Item,
	Context: BaseScene.Context,
	Map: MapTypes.Map?,
	Board: Leaderboard.Leaderboard,
	MainFormat: string,
	ExtraFormat: string,
	ArtistFormat: string,
	Info: SceneBuilder.Item,
	Dim: SceneBuilder.Item,
	CoverBackground: SceneBuilder.Item,
	Cover: SceneBuilder.Item,
	InfoSubholder: SceneBuilder.Item,
	MainLabel: SceneBuilder.Item,
	ExtraLabel: SceneBuilder.Item,
	ArtistLink: SceneBuilder.Item,
	ExportButton: SceneBuilder.Item,
	FavoriteButton: SceneBuilder.Item,
	DeleteButton: SceneBuilder.Item,
	Actions: SceneBuilder.Item,
	Preview: SceneBuilder.Item,
	SpeedPresets: SceneBuilder.Item,
	SpeedSlider: SceneBuilder.Item,
	SpeedEdit: SceneBuilder.Item,
	StartSlider: SceneBuilder.Item,
	StartEdit: SceneBuilder.Item,
	StartButton: SceneBuilder.Item,
	Leaderboard: SceneBuilder.Item,
	LbScroll: SceneBuilder.Item,
	LbContainer: SceneBuilder.Item,
	LbExpand: SceneBuilder.Item,
	LbHide: SceneBuilder.Item,
	LbExpandHover: SceneBuilder.Item,
	Rows: { SceneBuilder.Item },
}

const Containers: { [SceneBuilder.Item]: State } = {}

-- The favorite button's icon and tooltip follow the map's favorite flag.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:favoriteButton.Pressed L140-149
const function FavoriteIcon(Map: MapTypes.Map): SkinProfile.Texture?
	if Map.Favorite then
		return SkinManager.Skin.UnfavoriteButtonImage
	end

	return SkinManager.Skin.FavoriteButtonImage
end

const function UpdateFavorite(State: State)
	const Map = State.Map

	if not Map then
		return
	end

	Nodes.Set(State.FavoriteButton, "tooltip_text", if Map.Favorite then "Unfavorite" else "Favorite")
	Nodes.Set(State.FavoriteButton, "icon", Textures(FavoriteIcon(Map)))
end

-- The speed box and slider show the lobby's speed in percent.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:displaySpeed L191-209
const function DisplaySpeed(State: State, Speed: number)
	if not Nodes.IsInstanceValid(State.SpeedSlider) then
		return
	end

	const Percent = SpeedLogic.DisplayPercent(Speed)

	Nodes.SetValueNoSignal(State.SpeedSlider, Percent)
	Nodes.Set(State.SpeedEdit, "text", SpeedLogic.DisplayText(Percent))
end

-- @src scripts/ui/menu/play/MapInfoContainer.cs:applySpeed L215-231
const function ApplySpeed(State: State)
	Lobby.SetSpeed(SpeedLogic.ParseRatio(Nodes.Get(State.SpeedEdit, "text") :: string))

	const Map = State.Map

	if Map and SoundManager.Map ~= nil and SoundManager.Map.Name == Map.Name and SoundManager.Song.Playing then
		SoundManager.SongSetPitch(Lobby.Speed)
	end
end

-- The start time box, slider and button show the lobby's start.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:displayStartFrom L248-260
const function DisplayStartFrom(State: State, StartFrom: number)
	if not Nodes.IsInstanceValid(State.StartSlider) then
		return
	end

	const Length = if State.Map then State.Map.Length else 1

	Nodes.SetValueNoSignal(State.StartSlider, StartFromLogic.SliderValue(StartFrom, Length))
	Nodes.Set(State.StartEdit, "text", StartFromLogic.TimeText(StartFrom))
	Nodes.Set(State.StartButton, "text", StartFromLogic.ButtonText(StartFrom, Nodes.Get(State.StartEdit, "text") :: string))
end

-- The typed text, or the edit's text (its placeholder when empty) when none was typed.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:applyStartFrom L266
const function InputText(State: State, Typed: string?): string
	if Typed then
		return Typed
	end

	const Edited = Nodes.Get(State.StartEdit, "text") :: string

	return if Edited == "" then Nodes.Get(State.StartEdit, "placeholder_text") :: string else Edited
end

-- applyStartFrom: the typed text becomes the lobby's start.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:applyStartFrom L264-302
const function PreviewMap(Map: MapTypes.Map)
	if SoundManager.Map == nil or SoundManager.Map.Name ~= Map.Name then
		SoundManager.StartMapSelectionPlayback(Map)
	end
end

const function SeekPreview(State: State)
	if SoundManager.Song.Playing then
		FlatPreview.Seek(State.Preview, Lobby.StartFrom / 1000)
		SoundManager.SongSeek(Lobby.StartFrom / 1000)
	end
end

const function ApplyStartFrom(State: State, Typed: string?, Seek: boolean)
	const Map = State.Map :: MapTypes.Map
	const Text = InputText(State, Typed)

	-- Leaving the box without typing anything changes nothing (it shows whole seconds, and the start may not be on one).
	if Text == StartFromLogic.TimeText(Lobby.StartFrom) then
		return
	end

	Lobby.SetStartFrom(StartFromLogic.ParseInput(Text, Map.Length))
	PreviewMap(Map)

	if Seek then
		SeekPreview(State)
	end
end

-- Expands the leaderboard list to its rows, or collapses it to one row; the rows' buttons follow.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:toggleLeaderboard L541-564
const function ToggleLeaderboard(State: State, Show: boolean)
	Nodes.Set(State.LbExpand, "visible", not Show)
	Nodes.Set(State.LbHide, "visible", Show)
	Nodes.Set(State.LbScroll, "vertical_scroll_mode", if Show then ScrollAuto else ScrollShowNever)

	for _, Row in State.Rows do
		Nodes.Set(Nodes.GetNode(Row, "Button"), "visible", Show)
	end

	const Running = Tween.Create(State.Item)

	Tween.SetEase(Running, Tween.EaseType.Out)
	Tween.SetTrans(Running, Tween.TransitionType.Quart)
	Tween.SetParallel(Running, true)
	Tween.TweenProperty(Running, State.Leaderboard, "offset_top", Scores.ExpandedOffsetTop(Show, State.Board.ScoreCount), 0.25)
	Tween.TweenProperty(Running, State.Dim, "color", { Color = { 0, 0, 0, if Show then DimOpaque else 0 } }, 0.25)

	if not Show then
		Tween.TweenProperty(Running, State.LbScroll, "scroll_vertical", 0, 0.15)
	end
end

-- Reads the map's leaderboard and shows its scores: at most 8 rows, each shaded alternately.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:LoadLeaderboard L480-512
const function LoadLeaderboard(State: State, Map: MapTypes.Map)
	State.Board = Leaderboard.Empty()

	const Path = Scores.PbsPath(Map.Name)

	if FileSystem.Exists(Path) then
		State.Board = Leaderboard.New(Map.Name, Path)
	end

	Nodes.Set(State.Leaderboard, "visible", Scores.ListVisible(State.Board))

	for _, Child in State.Rows do
		Nodes.RemoveChild(State.LbContainer, Child)
		Nodes.QueueFree(Child)
	end

	table.clear(State.Rows)

	for Index = 0, Scores.VisibleRows(State.Board.ScoreCount) - 1 do
		const Row = Nodes.Instantiate(State.Item.Scene, "res://prefabs/score_panel.tscn")

		ScorePanel.New(Row, State.Context)
		Nodes.AddChild(State.LbContainer, Row)
		ScorePanel.Setup(Row, State.Board.Scores[Index + 1])
		table.insert(State.Rows, Row)

		const Shade = Scores.RowAlpha(Index) / 255

		Nodes.Set(Nodes.GetNode(Row, "Background"), "color", { Color = { 1, 1, 1, Shade } })
		Nodes.Connect(Nodes.GetNode(Row, "Button"), "pressed", function()
			ToggleLeaderboard(State, false)
		end)
	end
end

-- The map info's labels, cover, favorite and speed and start fields for a map, and its leaderboard.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:Setup L398-472
const function FillMap(State: State, Map: MapTypes.Map)
	const Difficulty = Details.DifficultyColor(Map.Difficulty)

	Nodes.Set(State.MainLabel, "text", Details.MainText(Map, State.MainFormat))
	Nodes.Set(State.ExtraLabel, "text", Details.ExtraText(Map, State.ExtraFormat, #MapLogic.GetNotes(Map)))
	Nodes.Set(State.CoverBackground, "self_modulate", { Color = { Difficulty.R, Difficulty.G, Difficulty.B, Difficulty.A } })
	Nodes.Set(State.Cover, "texture", Textures(MapLogic.GetCover(Map)))
	UpdateFavorite(State)

	Nodes.Set(State.ArtistLink, "visible", Map.ArtistLink ~= "")
	Nodes.Set(State.ArtistLink, "text", Details.ArtistText(State.ArtistFormat, Map.ArtistPlatform))

	Lobby.SetStartFrom(0)
	LoadLeaderboard(State, Map)
	FlatPreview.Setup(State.Preview, Map, true)
end

-- Setup(map): the container shows the map; a container already showing its name changes nothing.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:Setup L398-472
const function Setup(Item: SceneBuilder.Item, Map: MapTypes.Map)
	const State = Containers[Item]

	if Nodes.Get(Item, "name") == Map.Name then
		return
	end

	State.Map = Map
	Nodes.Set(Item, "name", Map.Name)
	Nodes.Set(Item, "position", vector.zero)
	Nodes.Set(Item, "scale", vector.one)

	const Left = Nodes.Get(State.Info, "offset_left") :: number
	const Right = Nodes.Get(State.Info, "offset_right") :: number
	const ActionsLeft = Nodes.Get(State.Actions, "offset_left") :: number
	const ActionsRight = Nodes.Get(State.Actions, "offset_right") :: number
	const BoardLeft = Nodes.Get(State.Leaderboard, "offset_left") :: number
	const BoardRight = Nodes.Get(State.Leaderboard, "offset_right") :: number

	Nodes.Set(State.Info, "offset_left", Left - LeaderboardOffsetInfo)
	Nodes.Set(State.Info, "offset_right", Right - LeaderboardOffsetInfo)
	Nodes.Set(State.Actions, "offset_left", ActionsLeft - LeaderboardOffsetActions)
	Nodes.Set(State.Actions, "offset_right", ActionsRight - LeaderboardOffsetActions)
	Nodes.Set(State.Leaderboard, "offset_left", BoardLeft - LeaderboardOffsetBoard)
	Nodes.Set(State.Leaderboard, "offset_right", BoardRight - LeaderboardOffsetBoard)

	const InTween = Tween.Create(Item)

	Tween.SetEase(InTween, Tween.EaseType.Out)
	Tween.SetParallel(InTween, true)
	Tween.SetTrans(InTween, Tween.TransitionType.Quint)
	Tween.TweenProperty(InTween, State.Info, "offset_left", 0, 0.5)
	Tween.TweenProperty(InTween, State.Info, "offset_right", 0, 0.5)
	Tween.SetTrans(InTween, Tween.TransitionType.Quart)
	Tween.TweenProperty(InTween, State.Actions, "offset_left", 0, 0.6)
	Tween.TweenProperty(InTween, State.Actions, "offset_right", 0, 0.6)
	Tween.SetTrans(InTween, Tween.TransitionType.Cubic)
	Tween.TweenProperty(InTween, State.Leaderboard, "offset_left", 0, 0.7)
	Tween.TweenProperty(InTween, State.Leaderboard, "offset_right", 0, 0.7)

	Nodes.Set(Item, "offset_right", 0)

	const Position = Nodes.Get(Item, "position") :: vector

	Nodes.Set(Item, "position", Position + vector.create(-LeaderboardOffsetInfo, 0, 0))

	FillMap(State, Map)
end

-- Refresh(): the current map is shown again, with its leaderboard reloaded.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:Refresh L474-478
const function Refresh(Item: SceneBuilder.Item)
	const State = Containers[Item]
	const Map = State.Map

	if Map then
		Setup(Item, Map)
		LoadLeaderboard(State, Map)
	end
end

-- Transition(show): the panel fades and slides in or out; the tween it answers finishes the transition.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:Transition L514-527
const function Transition(Item: SceneBuilder.Item, Show: boolean): Tween.Tween
	const Running = Tween.Create(Item)
	const Time = if Show then 0.4 else 0.3

	Tween.SetEase(Running, Tween.EaseType.Out)
	Tween.SetTrans(Running, Tween.TransitionType.Cubic)
	Tween.SetParallel(Running, true)

	const Size = Nodes.Get(Item, "size") :: vector

	Nodes.Set(Item, "pivot_offset", vector.create(Size.x / 2, Size.y / 2, 0))

	Tween.TweenProperty(Running, Item, "modulate", { Color = { 1, 1, 1, if Show then 1 else 0 } }, Time)
	Tween.TweenProperty(Running, Item, "position", if Show then vector.zero else vector.create(0, 24, 0), Time)
	Tween.TweenProperty(Running, Item, "scale", if Show then vector.one else vector.create(0.9, 0.9, 0), Time)
	Tween.Chain(Running)

	return Running
end

-- UpdateSkin: the cover background and the speed preset icons of the skin.
-- @src scripts/ui/menu/play/MapInfoContainer.cs:UpdateSkin L529-539
const function UpdateSkin(Item: SceneBuilder.Item, Skin: SkinProfile.SkinProfile)
	const State = Containers[Item]

	Nodes.Set(State.CoverBackground, "texture", Textures(Skin.MapInfoCoverBackgroundImage))
	Nodes.Set(Nodes.GetNode(State.SpeedPresets, "MinusMinus/SpeedPresetButton"), "icon", Textures(Skin.SpeedPresetMinusMinusButtonImage))
	Nodes.Set(Nodes.GetNode(State.SpeedPresets, "Minus/SpeedPresetButton"), "icon", Textures(Skin.SpeedPresetMinusButtonImage))
	Nodes.Set(Nodes.GetNode(State.SpeedPresets, "Middle/SpeedPresetButton"), "icon", Textures(Skin.SpeedPresetMiddleButtonImage))
	Nodes.Set(Nodes.GetNode(State.SpeedPresets, "Plus/SpeedPresetButton"), "icon", Textures(Skin.SpeedPresetPlusButtonImage))
	Nodes.Set(Nodes.GetNode(State.SpeedPresets, "PlusPlus/SpeedPresetButton"), "icon", Textures(Skin.SpeedPresetPlusPlusButtonImage))
end

-- @src scripts/ui/menu/play/MapInfoContainer.cs:_Ready L120-365
const function New(Item: SceneBuilder.Item, Context: BaseScene.Context)
	const Info = Nodes.GetNode(Item, "Info")
	const HBox = Nodes.GetNode(Info, "ScrollContainer/HBoxContainer")
	const SpeedHolder = Nodes.GetNode(Item, "Actions/ScrollContainer/Holder/Speed")
	const PlayHolder = Nodes.GetNode(Item, "Actions/ScrollContainer/Holder/Play")
	const Board = Nodes.GetNode(Item, "Leaderboard")
	const State = {
		Item = Item,
		Context = Context,
		Map = nil,
		Board = Leaderboard.Empty(),
		MainFormat = Nodes.Get(Nodes.GetNode(HBox, "Subholder/Main"), "text") :: string,
		ExtraFormat = Nodes.Get(Nodes.GetNode(HBox, "Subholder/Extra"), "text") :: string,
		ArtistFormat = Nodes.Get(Nodes.GetNode(HBox, "Background/ArtistLink"), "text") :: string,
		Info = Info,
		Dim = Nodes.GetNode(Item, "Dim"),
		CoverBackground = Nodes.GetNode(HBox, "Background"),
		Cover = Nodes.GetNode(HBox, "Background/Cover"),
		InfoSubholder = HBox,
		MainLabel = Nodes.GetNode(HBox, "Subholder/Main"),
		ExtraLabel = Nodes.GetNode(HBox, "Subholder/Extra"),
		ArtistLink = Nodes.GetNode(HBox, "Background/ArtistLink"),
		ExportButton = Nodes.GetNode(HBox, "Subholder/Buttons/Export"),
		FavoriteButton = Nodes.GetNode(HBox, "Subholder/Buttons/Favorite"),
		DeleteButton = Nodes.GetNode(HBox, "Subholder/Buttons/Delete"),
		Actions = Nodes.GetNode(Item, "Actions"),
		Preview = Nodes.GetNode(Item, "Actions/ScrollContainer/Holder/Preview/AspectRatioContainer/FlatPreview"),
		SpeedPresets = Nodes.GetNode(Item, "Actions/ScrollContainer/Holder/Speed/ScrollContainer/Presets"),
		SpeedSlider = Nodes.GetNode(SpeedHolder, "HSlider"),
		SpeedEdit = Nodes.GetNode(SpeedHolder, "LineEdit"),
		StartSlider = Nodes.GetNode(PlayHolder, "HSlider"),
		StartEdit = Nodes.GetNode(PlayHolder, "LineEdit"),
		StartButton = Nodes.GetNode(PlayHolder, "Button"),
		Leaderboard = Board,
		LbScroll = Nodes.GetNode(Board, "ScrollContainer"),
		LbContainer = Nodes.GetNode(Board, "ScrollContainer/VBoxContainer"),
		LbExpand = Nodes.GetNode(Board, "Expand"),
		LbHide = Nodes.GetNode(Item, "LeaderboardHide"),
		LbExpandHover = Nodes.GetNode(Nodes.GetNode(Board, "Expand"), "Hover"),
		Rows = {},
	} :: State

	Containers[Item] = State

	Nodes.Set(Item, "modulate", { Color = { 1, 1, 1, 0 } })

	-- The info panel's outline follows the cursor every frame (_Process). The other outlines keep their defaults, as in the source.
	const InfoOutline = Nodes.GetNode(Info, "Outline")

	Nodes.OnProcess(Item, function()
		Nodes.SetShaderParameter(InfoOutline, "cursor_position", Nodes.GetMousePosition(Item))
	end)

	-- The children with their own scripts: attached here, since MapInfo instantiates this container at runtime.
	FlatPreview.New(State.Preview, Context)
	CameraModes(Nodes.GetNode(Item, "Actions/ScrollContainer/Holder/Modes"), Context)
	Modifiers(Nodes.GetNode(Item, "Actions/ScrollContainer/Holder/Modifiers"), Context)

	for _, Name in SpeedPresetNames do
		SpeedPresetButton(Nodes.GetNode(State.SpeedPresets, `{Name}/SpeedPresetButton`), Context)
	end

	-- Speed: the slider and the edit, the lobby's speed in percent.
	DisplaySpeed(State, Lobby.Speed)

	const function OnSpeedChanged(Speed: number)
		DisplaySpeed(State, Speed)
	end

	Signal.Connect(Lobby.SpeedChanged, OnSpeedChanged)
	table.insert(Item.Cleanup, function()
		Signal.Disconnect(Lobby.SpeedChanged, OnSpeedChanged)
	end)

	Nodes.Connect(State.SpeedEdit, "focus_exited", function()
		ApplySpeed(State)
	end)
	Nodes.Connect(State.SpeedEdit, "text_submitted", function()
		ApplySpeed(State)
	end)
	Nodes.Connect(State.SpeedSlider, "value_changed", function(Value: unknown)
		Nodes.Set(State.SpeedEdit, "text", Format.Shortest(Value :: number))
		ApplySpeed(State)
	end)

	-- Start time: the slider and the edit, the lobby's start.
	const function OnStartFromChanged(StartFrom: number)
		DisplayStartFrom(State, StartFrom)
	end

	Signal.Connect(Lobby.StartFromChanged, OnStartFromChanged)
	table.insert(Item.Cleanup, function()
		Signal.Disconnect(Lobby.StartFromChanged, OnStartFromChanged)
	end)

	Nodes.Connect(State.StartEdit, "focus_exited", function()
		ApplyStartFrom(State, nil, true)
	end)
	Nodes.Connect(State.StartEdit, "text_submitted", function()
		ApplyStartFrom(State, nil, true)
	end)
	-- done typing: Enter gives the keyboard back to the game, instead of keeping it in the box
	;(State.StartEdit :: any).ReleaseOnSubmit = true
	Nodes.Connect(State.StartSlider, "value_changed", function(Value: unknown)
		const Map = State.Map :: MapTypes.Map

		Lobby.SetStartFrom(math.clamp((Value :: number) * Map.Length // 1, 0, Map.Length))
		PreviewMap(Map)
	end)
	Nodes.Connect(State.StartSlider, "drag_ended", function(Changed: unknown)
		if Changed == true then
			SeekPreview(State)
		end
	end)

	Nodes.Connect(State.StartButton, "pressed", function()
		GameStart.Play(State.Map :: MapTypes.Map, Lobby.Speed, Lobby.StartFrom, Lobby.CameraMode, Lobby.Modifiers, nil)
	end)

	-- VS, right of START (AimiaApp adds it to the prefab): a VS lobby with this song, speed, camera and modifiers
	const VersusButton = Nodes.GetNodeOrNull(PlayHolder, "Versus")

	if VersusButton then
		Nodes.Connect(VersusButton, "pressed", function()
			const Host = GameStart.Hooks.Versus
			const Map = State.Map

			if not Host or not Map then
				return
			end

			const Asked, Started, Why = pcall(Host, Map, Lobby.Speed, Lobby.CameraMode, Lobby.Modifiers, Lobby.StartFrom)

			if not Asked then
				warn("[AIMIA] VS: " .. tostring(Started))
			elseif not Started and type(Why) == "string" then
				Notify.Notify(Why, 1)
			end
		end)
	end

	-- Actions on the map.
	Nodes.Connect(State.ExportButton, "pressed", function()
		const Map = State.Map :: MapTypes.Map

		Notify.Notify(`Exporting to {Constants.UserFolder}/export/{Map.Name}.phxm`, 1)
		MapParser.ExportEncode(Map)
		Notify.Notify("Done! Opening export...", 0)
	end)
	Nodes.Connect(State.FavoriteButton, "pressed", function()
		const Map = State.Map :: MapTypes.Map

		Map.Favorite = not Map.Favorite
		MapManager.Update(Map)
		UpdateFavorite(State)
	end)
	Nodes.Connect(State.DeleteButton, "pressed", function()
		MapManager.Delete(State.Map :: MapTypes.Map)
	end)

	-- The leaderboard's expand and hide buttons, and its hover.
	Nodes.Connect(State.LbExpand, "mouse_entered", function()
		const Running = Tween.Create(Item)

		Tween.SetEase(Running, Tween.EaseType.Out)
		Tween.SetTrans(Running, Tween.TransitionType.Quart)
		Tween.TweenProperty(Running, State.LbExpandHover, "modulate", { Color = { 1, 1, 1, 1 } }, 0.25)
	end)
	Nodes.Connect(State.LbExpand, "mouse_exited", function()
		const Running = Tween.Create(Item)

		Tween.SetEase(Running, Tween.EaseType.Out)
		Tween.SetTrans(Running, Tween.TransitionType.Quart)
		Tween.TweenProperty(Running, State.LbExpandHover, "modulate", { Color = { 1, 1, 1, 0 } }, 0.25)
	end)
	Nodes.Connect(State.LbExpand, "pressed", function()
		ToggleLeaderboard(State, true)
	end)
	Nodes.Connect(State.LbHide, "pressed", function()
		ToggleLeaderboard(State, false)
	end)

	-- Input: a right press hides the leaderboard (_Input), a left press that nothing else took does too (_UnhandledInput).
	const Disconnect = Input.OnInput(function(Event: Input.InputEvent, Processed: boolean)
		if not Event.Pressed then
			return
		end

		if Event.ButtonIndex == Input.MouseButton.Right then
			ToggleLeaderboard(State, false)
		elseif not Processed and Event.ButtonIndex == Input.MouseButton.Left then
			ToggleLeaderboard(State, false)
		end
	end)

	table.insert(Item.Cleanup, Disconnect)

	-- Skin: the cover background and the speed presets (SkinManager.Loaded).
	UpdateSkin(Item, SkinManager.Skin)

	const function OnSkinLoaded(Skin: SkinProfile.SkinProfile)
		UpdateSkin(Item, Skin)
	end

	Signal.Connect(SkinManager.Loaded, OnSkinLoaded)
	table.insert(Item.Cleanup, function()
		Signal.Disconnect(SkinManager.Loaded, OnSkinLoaded)
	end)
end

return {
	New = New,
	Setup = Setup,
	Refresh = Refresh,
	Transition = Transition,
}
