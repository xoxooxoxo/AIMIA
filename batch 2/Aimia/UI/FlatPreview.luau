--!strict
--!optimize 2

--[[
	FlatPreview.cs (scripts/ui/FlatPreview.cs): a 3 x 3 grid of tiles that light as the map's notes pass the playhead and fade
	back each frame. The logic is UI/Menu/Play/InfoLogic/Preview.

	Representation
		State is kept per Item (the preview's parent calls Setup and Seek): the map, the playhead, the last note passed, and
		the tile colors and their value tables (set through Nodes, reused each frame).

	Design Notes
		DEVIATION(api): Nodes has no create function, so the tiles are built by SceneBuilder.BuildTree from ColorRect entries.
		The stream playhead (UseSoundManagerStreamPlayer) reads the song through Hooks.Playback. Audio is deferred, so the hook
		is unset and that preview answers no playhead: the source returns early when no song of its map plays.
		Each tile's color is a Godot Color lerped toward transparent by the frame's fade (Godot/Color Lerp).
]]

const Color = require("../Godot/Color")
const MapLogic = require("../Map/Map")
const MapTypes = require("../Map/MapTypes")
const BaseScene = require("./Scenes/BaseScene")
const Note = require("../Map/Objects/Note")
const Nodes = require("./Nodes")
const Numbers = require("../Numbers")
const Preview = require("./Menu/Play/InfoLogic/Preview")
const SceneBuilder = require("./SceneBuilder")

const TileCount = 9
const Transparent = Color.New(1, 1, 1, 0)
const BrightAlpha = 0.2

export type Playhead = (MapName: string) -> (boolean?, number?)

-- The song playback of a map: whether it is playing and its position in seconds, or nil when no song of it is loaded.
-- Unset until audio is ported (SoundManager).
const Hooks: { Playback: Playhead? } = {}

type State = {
	Item: SceneBuilder.Item,
	Map: MapTypes.Map?,
	UseStream: boolean,
	Playing: boolean,
	Time: number,
	Speed: number,
	LastPassed: number,
	Timestamps: { number },
	Notes: { Note.Note },
	Tiles: { SceneBuilder.Item },
	Colors: { Color.Color },
	Values: { { Color: { number } } },
}

const Instances: { [SceneBuilder.Item]: State } = {}

-- Copies a Godot color into a tile's value table.
const function WriteValue(Value: { Color: { number } }, Color: Color.Color)
	const Components = Value.Color

	Components[1] = Color.R
	Components[2] = Color.G
	Components[3] = Color.B
	Components[4] = Color.A
end

-- Writes one tile's color to the node.
const function SetTileColor(State: State, Index: number)
	WriteValue(State.Values[Index], State.Colors[Index])
	Nodes.Set(State.Tiles[Index], "color", State.Values[Index])
end

-- Builds one tile: a ColorRect in its third of the grid (anchors 0, 1/3, 2/3, 1).
-- @src scripts/ui/FlatPreview.cs:_Ready L21-36
const function BuildTile(Item: SceneBuilder.Item, Index: number, Value: { Color: { number } }): SceneBuilder.Item
	const Column = Index % 3
	const Row = Index // 3
	const Left = Column / 3
	const Top = Row / 3
	const Name = tostring(Index)
	const Entry = {
		Path = Name,
		Name = Name,
		ParentPath = nil,
		Class = "ColorRect",
		File = Item.Context.File,
		Files = {},
		Properties = {
			["layout_mode"] = 1,
			["anchor_left"] = Left,
			["anchor_top"] = Top,
			["anchor_right"] = Left + 1 / 3,
			["anchor_bottom"] = Top + 1 / 3,
			["color"] = Value,
		},
	} :: SceneBuilder.Entry
	const Built = SceneBuilder.BuildTree({ Entry }, Item.Scene.Viewport, nil)

	return Built.Root :: SceneBuilder.Item
end

-- Lights the tile of a note.
-- @src scripts/ui/FlatPreview.cs:_Process L80-84
const function Light(State: State, Entry: Note.Note)
	const Index = Preview.TileOf(Entry) + 1

	State.Colors[Index] = Color.New(1, 1, 1, Numbers.F32(BrightAlpha))
	SetTileColor(State, Index)
end

-- The per-frame update: the fade, the playhead, and the notes it reached.
-- @src scripts/ui/FlatPreview.cs:_Process L40-90
const function Process(State: State, Delta: number)
	const Map = State.Map

	if Map == nil then
		return
	end

	const Alpha = Preview.FadeAmount(Delta)

	for Index = 1, TileCount do
		const Current = State.Colors[Index]

		-- (Not in the source: a tile that has faded out is left alone. Every write redraws the tile, and the fade never quite
		-- lands, so all 9 redrew every frame for as long as the Play tab showed.)
		if Current.A > 0 then
			const Next = Color.Lerp(Current, Transparent, Alpha)

			State.Colors[Index] = if Next.A < 0.002 then Transparent else Next
			SetTileColor(State, Index)
		end
	end

	const OldTime = State.Time

	if State.UseStream then
		const Playhead = Hooks.Playback

		if not Playhead then
			return
		end

		const Playing, Seconds = Playhead(Map.Name)

		if Seconds == nil then
			return
		end

		State.Playing = Playing == true
		State.Time = Seconds * 1000
	elseif State.Playing then
		State.Time += Delta * State.Speed * 1000
	end

	if State.Time < OldTime then
		State.LastPassed = Preview.Rewind(State.Timestamps, State.Time)
	end

	const First, Lit, NewLastPassed = Preview.Passed(State.Notes, State.Time, State.LastPassed)

	for Index = First, Lit do
		Light(State, State.Notes[Index + 1])
	end

	State.LastPassed = NewLastPassed
end

-- @src scripts/ui/FlatPreview.cs:_Ready L19-38
-- The preview on its node: its tiles are built now, and the frame update runs until the node is freed.
const function New(Item: SceneBuilder.Item, Context: BaseScene.Context)
	const Values: { { Color: { number } } } = {}
	const Colors: { Color.Color } = {}
	const Tiles: { SceneBuilder.Item } = {}

	for Index = 1, TileCount do
		Values[Index] = { Color = { 1, 1, 1, 0 } }
		Colors[Index] = Color.New(1, 1, 1, 0)
	end

	const State: State = {
		Item = Item,
		Map = nil,
		UseStream = false,
		Playing = false,
		Time = 0,
		Speed = 1,
		LastPassed = -1,
		Timestamps = {},
		Notes = {},
		Tiles = Tiles,
		Colors = Colors,
		Values = Values,
	} :: State

	for Index = 1, TileCount do
		const Tile = BuildTile(Item, Index - 1, Values[Index])

		Nodes.AddChild(Item, Tile)
		Tiles[Index] = Tile
	end

	Instances[Item] = State

	Nodes.OnProcess(Item, function(Delta: number)
		if not Nodes.HiddenInTree(Item) then
			Process(State, Delta)
		end
	end)

	table.insert(Item.Cleanup, function()
		Instances[Item] = nil
	end)
end

-- Setup(map, useSoundManagerStreamPlayer): the map and its note timestamps; the same map changes nothing.
-- @src scripts/ui/FlatPreview.cs:Setup L93-102
const function Setup(Item: SceneBuilder.Item, Map: MapTypes.Map, UseStream: boolean?)
	const State = Instances[Item]

	if State.Map ~= nil and State.Map.Name == Map.Name then
		return
	end

	const Notes = MapLogic.GetNotes(Map)

	State.Map = Map
	State.UseStream = UseStream == true
	State.LastPassed = -1
	State.Notes = Notes
	State.Timestamps = Preview.Timestamps(Notes)
end

-- Seek(seek): the playhead moves to a time and the last note passed is the one it reached.
-- @src scripts/ui/FlatPreview.cs:Seek L104-112
const function Seek(Item: SceneBuilder.Item, Seconds: number)
	const State = Instances[Item]

	if State.Map == nil then
		return
	end

	State.Time = Seconds
	State.LastPassed = Preview.Rewind(State.Timestamps, Seconds)
end

return {
	Hooks = Hooks,
	New = New,
	Setup = Setup,
	Seek = Seek,
}
