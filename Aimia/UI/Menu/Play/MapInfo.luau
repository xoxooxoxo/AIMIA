--!strict
--!optimize 2

--[[
	MapInfo.cs (scripts/ui/menu/play/MapInfo.cs) on the MapInfo node of the Play menu: shows the selected map's info container
	(instantiated from its prefab, and reused from a cache of removed containers) and swaps it when another map is selected.
	The holder grows to the panel's height, at most 850.

	Representation
		One module state, as the source's static Instance: the map shown, its container, the cached containers, and a selection
		made while the node was off the tree (pendingSelection).

	Design Notes
		_Draw sets the holder's minimum size. It runs at the first draw, when the selection changes (QueueRedraw) and on a resize
		of this node (Godot redraws a control that is resized), so UpdateHolderSize runs on those.
		The map list reaches the selection through MapManager.Selected and MapManager.MapDeleted; the source's MapList reference
		is not used by MapInfo.
		DEVIATION: MapDeleted's deferred call runs at once (Callable.From(...).CallDeferred, as MapManager does).
]]

const BaseScene = require("../../Scenes/BaseScene")
const MapInfoContainer = require("./MapInfoContainer")
const MapManager = require("../../../Map/MapManager")
const MapTypes = require("../../../Map/MapTypes")
const Nodes = require("../../Nodes")
const SceneBuilder = require("../../SceneBuilder")
const Signal = require("../../../Util/Signal")
const Tween = require("../../Tween")

const MaxHolderSide = 850

type State = {
	Item: SceneBuilder.Item,
	Context: BaseScene.Context,
	Holder: SceneBuilder.Item,
	Map: MapTypes.Map?,
	InfoContainer: SceneBuilder.Item?,
	Cache: { SceneBuilder.Item },
	Pending: MapTypes.Map?,
}

local Current: State? = nil

-- _Draw: the holder is as tall as this panel's rect (its parent's height in its anchors, less its offsets), at most 850.
-- @src scripts/ui/menu/play/MapInfo.cs:_Draw L43-48
const function UpdateHolderSize(State: State)
	const Parent = Nodes.GetParent(State.Item)

	if Parent == nil then
		return
	end

	const ParentHeight = (Nodes.Get(Parent, "size") :: vector).y
	const AnchorTop = Nodes.Get(State.Item, "anchor_top") :: number
	const AnchorBottom = Nodes.Get(State.Item, "anchor_bottom") :: number
	const OffsetTop = Nodes.Get(State.Item, "offset_top") :: number
	const OffsetBottom = Nodes.Get(State.Item, "offset_bottom") :: number
	const Height = (AnchorBottom - AnchorTop) * ParentHeight - OffsetTop + OffsetBottom
	const Side = math.min(MaxHolderSide, Height)

	Nodes.Set(State.Holder, "custom_minimum_size", vector.create(Side, Side, 0))
end

-- Select(map): the map's container replaces the shown one (the old one slides out, then is cached).
-- @src scripts/ui/menu/play/MapInfo.cs:Select L64-103
const function Select(State: State, Map: MapTypes.Map?)
	if Map == nil then
		return
	end

	if not Nodes.IsInsideTree(State.Item) then
		State.Pending = Map

		return
	end

	const Shown = State.Map

	if Shown ~= nil and Map.Name == Shown.Name then
		return
	end

	State.Map = Map
	State.Pending = nil

	const OldContainer = State.InfoContainer

	if OldContainer then
		const Running = MapInfoContainer.Transition(OldContainer, false)

		Tween.TweenCallback(Running, function()
			Nodes.RemoveChild(State.Holder, OldContainer)
			table.insert(State.Cache, OldContainer)
		end)
	end

	const Reused = table.remove(State.Cache)
	local Container: SceneBuilder.Item

	if Reused then
		Container = Reused
	else
		Container = Nodes.Instantiate(State.Item.Scene, "res://prefabs/map_info_container.tscn")
		MapInfoContainer.New(Container, State.Context)
	end

	Nodes.AddChild(State.Holder, Container)
	State.InfoContainer = Container

	MapInfoContainer.Setup(Container, Map)
	MapInfoContainer.Transition(Container, true)
	UpdateHolderSize(State)
end

-- MapManager.Selected changed: the selection is shown.
-- @src scripts/ui/menu/play/MapInfo.cs:_Ready L27
const function OnSelected(Source: unknown, Args: { Value: MapTypes.Map?, OldValue: MapTypes.Map? })
	const State = Current

	if State then
		Select(State, Args.Value)
	end
end

-- MapManager.MapDeleted: a deleted map that is shown (or any, when none is) is dropped.
-- @src scripts/ui/menu/play/MapInfo.cs:_Ready L28-40
const function OnMapDeleted(Deleted: MapTypes.Map)
	const State = Current

	if State == nil then
		return
	end

	if State.Map == nil or State.Map.Name == Deleted.Name then
		State.Map = nil

		const Container = State.InfoContainer

		if Container then
			MapInfoContainer.Transition(Container, false)
		end
	end
end

-- ApplyPendingSelection: a selection made while off the tree is applied (forced: the shown map is cleared first).
-- @src scripts/ui/menu/play/MapInfo.cs:ApplyPendingSelection L53-62
const function ApplyPendingSelection(State: State)
	const Pending = State.Pending

	if Pending then
		State.Pending = nil
		State.Map = nil

		Select(State, Pending)
	end
end

-- @src scripts/ui/menu/play/MapInfo.cs:_Ready L20-41
const function New(Item: SceneBuilder.Item, Context: BaseScene.Context)
	const State = {
		Item = Item,
		Context = Context,
		Holder = Nodes.GetNode(Item, "Holder"),
		Map = nil,
		InfoContainer = nil,
		Cache = {},
		Pending = nil,
	} :: State

	Current = State

	-- DEVIATION(start): the baked maps select the first map at start, before this node exists (upstream selects only after the
	-- menu is built), so the selection already made is shown once the menu loads.
	State.Pending = MapManager.Selected.Value

	Signal.Connect(MapManager.Selected.ValueChanged, OnSelected)
	Signal.Connect(MapManager.MapDeleted, OnMapDeleted)

	const Disconnect = Nodes.Connect(Item, "resized", function()
		UpdateHolderSize(State)
	end)

	-- DEVIATION(draw): _Draw runs after the layout of a frame. The resize signal here can come before the parent's size is
	-- written (the holder then stays at zero), so the holder is also set each frame (Nodes.Set ignores an unchanged value).
	Nodes.OnProcess(Item, function()
		if not Nodes.HiddenInTree(Item) then
			UpdateHolderSize(State)
		end
	end)

	table.insert(Item.Cleanup, Disconnect)
	table.insert(Item.Cleanup, function()
		Signal.Disconnect(MapManager.Selected.ValueChanged, OnSelected)
		Signal.Disconnect(MapManager.MapDeleted, OnMapDeleted)
	end)

	ApplyPendingSelection(State)
	UpdateHolderSize(State)
end

-- Select(map) for the map list: the selection the shown container follows.
-- @src scripts/ui/menu/play/MapInfo.cs:Select L64
const function SelectMap(Map: MapTypes.Map)
	const State = Current

	if State then
		Select(State, Map)
	end
end

-- ApplyPendingSelection of the shown instance (MainMenu.Load): a selection made while the menu was off the tree.
-- @src scripts/ui/menu/play/MapInfo.cs:ApplyPendingSelection L53-62
const function ApplyPending()
	const State = Current

	if State then
		ApplyPendingSelection(State)
	end
end

-- InfoContainer?.Refresh() of the shown instance (MainMenu.Load).
-- @src scripts/scenes/MainMenu.cs:Load L95-97
const function RefreshContainer()
	const State = Current

	if State and State.InfoContainer then
		MapInfoContainer.Refresh(State.InfoContainer)
	end
end

return {
	New = New,
	Select = SelectMap,
	ApplyPending = ApplyPending,
	Refresh = RefreshContainer,
}
