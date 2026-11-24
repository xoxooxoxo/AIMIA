--!strict
--!optimize 2

--[[
	The jukebox panel of the menu (scripts/ui/menu/JukeboxPanel.cs): the title of the map whose song plays, the pause,
	skip and rewind buttons, and the go-to button that selects that map in the map list.

	Design Notes
		JukeboxPanel.Instance is the source's static instance: SoundManager calls UpdateMap, ClearMap and ShowMenuTheme on it.
		JukeboxPanel.Playback is the jukebox state of SoundManager (the client sets it to SoundManager before the panel is built);
		until it is set, nothing plays (no map, not paused, position 0).
		The pause button's image is set when it changes; the source sets the same image every frame.
		The spectrum's progress and margin are set every frame (_Process); UI/Shaders splits its box at the progress.
		DEVIATION(audio): the song's length is the map's length (the stream is not loaded).
		DEVIATION(platform): media keys have no Roblox KeyCode, so the play, next and previous cases never match.
]]

const Images = require("../Images")
const Input = require("../Input")
const Items = require("../Item")
const Listen = require("./HomeLogic/Listen")
const MapList = require("./Play/MapList")
const MapTypes = require("../../Map/MapTypes")
const Nodes = require("../Nodes")
const Signal = require("../../Util/Signal")
const Color = require("../../Godot/Color")
const SettingsManager = require("../../SettingsManager")
const SettingsProfile = require("../../Database/Settings/SettingsProfile")
const SkinManager = require("../../Skinning/SkinManager")
const SkinProfile = require("../../Skinning/SkinProfile")
const SkinTexture = require("./HomeLogic/SkinTexture")

export type Playback = {
	Map: MapTypes.Map?,
	JukeboxIndex: number,
	JukeboxPlayed: Signal.Signal<MapTypes.Map?>,
	JukeboxEmpty: Signal.Signal<()>,
	IsJukeboxPaused: () -> boolean,
	ToggleJukeboxPause: () -> boolean,
	PlayJukebox: (number?, boolean?) -> (),
	PlayRandom: () -> (),
	PlayPrevious: () -> (),
	PlaybackPosition: () -> number,
	Seek: (number) -> (),
}

export type Jukebox = {
	Map: MapTypes.Map?,
	Playback: Playback,
	Title: Items.Item,
	PauseButton: Items.Item,
	SkipButton: Items.Item,
	RewindButton: Items.Item,
	SelectButton: Items.Item,
	Spectrum: Items.Item,
	PauseShowsPlay: boolean?,
}

-- The jukebox before SoundManager is set as the playback: silence.
const function NotPaused(): boolean
	return false
end

const function NoPosition(): number
	return 0
end

const function Nothing()
	return
end

const function NotToggled(): boolean
	return false
end

const function Silence(): Playback
	return {
		Map = nil,
		JukeboxIndex = 0,
		JukeboxPlayed = Signal.New(),
		JukeboxEmpty = Signal.New(),
		IsJukeboxPaused = NotPaused,
		ToggleJukeboxPause = NotToggled,
		PlayJukebox = Nothing,
		PlayRandom = Nothing,
		PlayPrevious = Nothing,
		PlaybackPosition = NoPosition,
		Seek = Nothing,
	}
end

const JukeboxPanel = {
	Instance = nil :: Jukebox?,
	Playback = Silence(),
}

const Full = Color.Color8(255, 255, 255)
const Dim = Color.Color8(255, 255, 255, 190)
const Opaque = { Color = { Full.R, Full.G, Full.B, Full.A } }
const Faded = { Color = { Dim.R, Dim.G, Dim.B, Dim.A } }

const function AutoplayJukebox(): boolean
	return (SettingsManager.Settings :: SettingsProfile.SettingsProfile).AutoplayJukebox.Value
end

-- The pause button shows the play image while the jukebox is paused, else the pause image.
-- @src scripts/ui/menu/JukeboxPanel.cs:UpdateSkin L141
const function SetPauseImage(State: Jukebox, Skin: SkinProfile.SkinProfile, Play: boolean)
	Nodes.Set(State.PauseButton, "texture_normal", SkinTexture(if Play then Skin.JukeboxPlayImage else Skin.JukeboxPauseImage, Images.Register))

	State.PauseShowsPlay = Play
end

-- @src scripts/ui/menu/JukeboxPanel.cs:UpdateSkin L137-144
const function UpdateSkin(State: Jukebox, Skin: SkinProfile.SkinProfile?)
	const Source = Skin or SkinManager.Skin

	SetPauseImage(State, Source, State.Playback.IsJukeboxPaused())
	Nodes.Set(State.SkipButton, "texture_normal", SkinTexture(Source.JukeboxSkipImage, Images.Register))
	Nodes.Set(State.RewindButton, "texture_normal", SkinTexture(Source.JukeboxSkipImage, Images.Register))
end

-- The fraction of the jukebox song played (the source's stream position over its length). DEVIATION(audio): the length is
-- the map's, and nothing plays until the audio port sets the position.
const function SongProgress(State: Jukebox): number
	const Map = State.Playback.Map

	if not Map or Map.Length <= 0 then
		return 0
	end

	return math.clamp(State.Playback.PlaybackPosition() / (Map.Length / 1000), 0, 1)
end

-- @src scripts/ui/menu/JukeboxPanel.cs:_Process L76-90
const function Process(State: Jukebox)
	const Paused = State.Playback.IsJukeboxPaused()

	if Paused ~= State.PauseShowsPlay then
		SetPauseImage(State, SkinManager.Skin, Paused)
	end

	const SpectrumWidth = (Nodes.Get(State.Spectrum, "size") :: vector).x
	const ViewportWidth = Nodes.GetViewportRect(State.Title).x

	Nodes.SetShaderParameter(State.Spectrum, "progress", SongProgress(State))
	Nodes.SetShaderParameter(State.Spectrum, "margin", 1 - SpectrumWidth / ViewportWidth)
end

-- @src scripts/ui/menu/JukeboxPanel.cs:pause L146-150
const function Pause(State: Jukebox)
	State.Playback.ToggleJukeboxPause()
	UpdateSkin(State, nil)
end

-- @src scripts/ui/menu/JukeboxPanel.cs:skip L152-161
const function Skip(State: Jukebox)
	if not AutoplayJukebox() then
		return
	end

	State.Playback.PlayRandom()
end

-- @src scripts/ui/menu/JukeboxPanel.cs:rewind L163-179
const function Rewind(State: Jukebox)
	if not AutoplayJukebox() then
		return
	end

	if State.Playback.PlaybackPosition() < 2 then
		State.Playback.PlayPrevious()
	else
		State.Playback.Seek(0)
	end
end

-- @src scripts/ui/menu/JukeboxPanel.cs:select L181-189
const function Select(State: Jukebox)
	const Map = State.Map

	if not Map then
		return
	end

	MapList.Select(MapList.GetInstance(), Map, false)
end

-- @src scripts/ui/menu/JukeboxPanel.cs:_Input L92-109
const function OnKey(State: Jukebox, Event: Input.InputEvent)
	if Event.Class ~= "InputEventKey" or not Event.Pressed then
		return
	end

	if Event.Keycode == "Mediaplay" then
		Pause(State)
	elseif Event.Keycode == "Medianext" then
		Skip(State)
	elseif Event.Keycode == "Mediaprevious" then
		Rewind(State)
	end
end

-- @src scripts/ui/menu/JukeboxPanel.cs:ClearMap L111-116
function JukeboxPanel.ClearMap(State: Jukebox)
	Nodes.Set(State.Title, "text", "")

	State.Map = nil

	Nodes.Set(State.SelectButton, "disabled", true)
end

-- @src scripts/ui/menu/JukeboxPanel.cs:ShowMenuTheme L118-123
function JukeboxPanel.ShowMenuTheme(State: Jukebox)
	Nodes.Set(State.Title, "text", "Menu Theme")

	State.Map = nil

	Nodes.Set(State.SelectButton, "disabled", true)
end

-- @src scripts/ui/menu/JukeboxPanel.cs:UpdateMap L125-135
function JukeboxPanel.UpdateMap(State: Jukebox, Map: MapTypes.Map?)
	State.Map = Map

	if Map then
		Nodes.Set(State.Title, "text", Map.PrettyTitle)
		Nodes.Set(State.SelectButton, "disabled", false)

		SetPauseImage(State, SkinManager.Skin, false)
	end
end

-- @src scripts/ui/menu/JukeboxPanel.cs:_Ready L21-74
function JukeboxPanel.New(Item: Items.Item)
	const Hooks = JukeboxPanel.Playback
	const Title = Nodes.GetNode(Item, "Title")
	const PauseButton = Nodes.GetNode(Item, "Pause")
	const SkipButton = Nodes.GetNode(Item, "Skip")
	const RewindButton = Nodes.GetNode(Item, "Rewind")
	const SelectButton = Nodes.GetNode(Item, "Title/GoTo")
	const State = {
		Map = nil :: MapTypes.Map?,
		Playback = Hooks,
		Title = Title,
		PauseButton = PauseButton,
		SkipButton = SkipButton,
		RewindButton = RewindButton,
		SelectButton = SelectButton,
		Spectrum = Nodes.GetNode(Item, "Spectrum"),
		PauseShowsPlay = nil :: boolean?,
	} :: Jukebox

	JukeboxPanel.Instance = State

	for _, Button in { PauseButton, SkipButton, RewindButton } do
		Nodes.Connect(Button, "mouse_entered", function()
			Nodes.Set(Button, "self_modulate", Opaque)
		end)
		Nodes.Connect(Button, "mouse_exited", function()
			Nodes.Set(Button, "self_modulate", Faded)
		end)
	end

	Nodes.Connect(SelectButton, "mouse_entered", function()
		Nodes.Set(Title, "self_modulate", Opaque)
	end)
	Nodes.Connect(SelectButton, "mouse_exited", function()
		Nodes.Set(Title, "self_modulate", Faded)
	end)

	Nodes.Connect(PauseButton, "pressed", function()
		Pause(State)
	end)
	Nodes.Connect(SkipButton, "pressed", function()
		Skip(State)
	end)
	Nodes.Connect(RewindButton, "pressed", function()
		Rewind(State)
	end)
	Nodes.Connect(SelectButton, "pressed", function()
		Select(State)
	end)

	if AutoplayJukebox() then
		SetPauseImage(State, SkinManager.Skin, false)
	end

	if Hooks.Map then
		JukeboxPanel.UpdateMap(State, Hooks.Map)
	end

	UpdateSkin(State, nil)

	Listen(Item, Hooks.JukeboxPlayed, function(Map: MapTypes.Map?)
		JukeboxPanel.UpdateMap(State, Map)
	end)
	Listen(Item, Hooks.JukeboxEmpty, function()
		JukeboxPanel.ClearMap(State)
	end)
	Listen(Item, SkinManager.Loaded, function(Skin: SkinProfile.SkinProfile)
		UpdateSkin(State, Skin)
	end)

	Nodes.OnProcess(Item, function()
		Process(State)
	end)
	table.insert(Item.Cleanup, Input.OnInput(function(Event: Input.InputEvent)
		OnKey(State, Event)
	end))
end

return JukeboxPanel
