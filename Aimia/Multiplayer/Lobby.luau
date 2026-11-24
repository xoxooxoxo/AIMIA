--!strict
--!optimize 2

--[[
	Lobby.cs: the play selection and the lobby's players, as module state (the static fields of the source). The map info,
	the modifier and camera buttons and the game start read and set it; each change fires the signal the source emits.

	Representation
		Speed is a ratio (1 is 100%). CameraModeChanged passes the mode's name and ModifiersChanged the names of the active
		modifiers, as the source does. The Node Instance is not kept: the signals are module values.

	Design Notes
		Initialize is the node's _Ready: the selected map follows MapManager.Selected, once.
		Networking is not ported: Players holds the players it is given (Enter adds the local one), and PlayerReady counts
		toward AllReady as the source does. Nothing calls them before the multiplayer packet.
		Signals fire synchronously in connection order (Util/Signal), as EmitSignal does.
]]

const CameraLock = require("../Game/Camera/CameraLock")
const CameraMode = require("../Game/Camera/CameraMode")
const MapManager = require("../Map/MapManager")
const MapTypes = require("../Map/MapTypes")
const Modifier = require("../Game/Modifiers/Modifier")
const Player = require("./Player")
const Signal = require("../Util/Signal")

const Lobby = {
	Players = {} :: { Player.Player },
	PlayersReady = 0,
	Map = nil :: MapTypes.Map?,
	Speed = 1,
	StartFrom = 0,
	CameraMode = CameraLock() :: CameraMode.CameraMode,
	Modifiers = {} :: { Modifier.Modifier },
	Initialized = false,
	AllReady = Signal.New() :: Signal.Signal<()>,
	MapChanged = Signal.New() :: Signal.Signal<MapTypes.Map?>,
	SpeedChanged = Signal.New() :: Signal.Signal<number>,
	StartFromChanged = Signal.New() :: Signal.Signal<number>,
	CameraModeChanged = Signal.New() :: Signal.Signal<string>,
	ModifiersChanged = Signal.New() :: Signal.Signal<{ string }>,
}

-- The names of the active modifiers, in the order they were turned on.
const function ModifierNames(): { string }
	const Names: { string } = {}

	for _, Mod in Lobby.Modifiers do
		table.insert(Names, Mod.Name)
	end

	return Names
end

-- Whether a modifier of this name is active.
const function IsActive(Name: string): boolean
	for _, Mod in Lobby.Modifiers do
		if Mod.Name == Name then
			return true
		end
	end

	return false
end

-- The selected map changed in MapManager: the lobby follows it unless it already holds that map.
-- @src scripts/multiplayer/Lobby.cs:_Ready L51-59
const function OnSelectedChanged(Source: unknown, Args: { Value: MapTypes.Map?, OldValue: MapTypes.Map? })
	const Selected = Args.Value

	if Lobby.Map == nil or (Selected :: MapTypes.Map).Name ~= Lobby.Map.Name then
		Lobby.SetMap(Selected)
	end
end

-- The node's _Ready: the lobby follows MapManager.Selected. Once: the connection is made the first time only.
-- @src scripts/multiplayer/Lobby.cs:_Ready L47-60
function Lobby.Initialize()
	if Lobby.Initialized then
		return
	end

	Lobby.Initialized = true

	Signal.Connect(MapManager.Selected.ValueChanged, OnSelectedChanged)
end

-- @src scripts/multiplayer/Lobby.cs:Enter L62-65
function Lobby.Enter()
	Lobby.AddPlayer(Player.New("You"))
end

-- @src scripts/multiplayer/Lobby.cs:Leave L67-70
function Lobby.Leave()
	Lobby.Players = {}
end

-- @src scripts/multiplayer/Lobby.cs:PlayerReady L72-90
function Lobby.PlayerReady(Name: string, Ready: boolean?)
	if Ready == nil or Ready then
		Lobby.PlayersReady += 1
	else
		Lobby.PlayersReady -= 1
	end

	if Lobby.PlayersReady == #Lobby.Players then
		Signal.Fire(Lobby.AllReady)
	end
end

-- @src scripts/multiplayer/Lobby.cs:PlayerUnready L92-95
function Lobby.PlayerUnready(Name: string)
	Lobby.PlayerReady(Name, false)
end

-- @src scripts/multiplayer/Lobby.cs:AddPlayer L97-100
function Lobby.AddPlayer(Value: Player.Player)
	table.insert(Lobby.Players, Value)
end

-- List.Remove: the first entry that is the player, if any.
-- @src scripts/multiplayer/Lobby.cs:RemovePlayer L102-105
function Lobby.RemovePlayer(Value: Player.Player)
	for Index, Entry in Lobby.Players do
		if Entry == Value then
			table.remove(Lobby.Players, Index)

			return
		end
	end
end

-- Selects a map: the start time resets to 0 (firing StartFromChanged first), then MapChanged fires.
-- @src scripts/multiplayer/Lobby.cs:SetMap L107-114
function Lobby.SetMap(Map: MapTypes.Map?)
	Lobby.Map = Map

	Lobby.SetStartFrom(0)

	Signal.Fire(Lobby.MapChanged, Map)
end

-- @src scripts/multiplayer/Lobby.cs:SetSpeed L116-121
function Lobby.SetSpeed(Speed: number)
	Lobby.Speed = Speed

	Signal.Fire(Lobby.SpeedChanged, Speed)
end

-- @src scripts/multiplayer/Lobby.cs:SetStartFrom L123-128
function Lobby.SetStartFrom(StartFrom: number)
	Lobby.StartFrom = StartFrom

	Signal.Fire(Lobby.StartFromChanged, StartFrom)
end

-- Sets the camera mode; the same name changes nothing.
-- @src scripts/multiplayer/Lobby.cs:SetCameraMode L130-138
function Lobby.SetCameraMode(Mode: CameraMode.CameraMode)
	if Lobby.CameraMode.Name == Mode.Name then
		return
	end

	Lobby.CameraMode = Mode

	Signal.Fire(Lobby.CameraModeChanged, Mode.Name)
end

-- Turns a modifier on (appended) or off (removed by name). Nothing changes when it is already in that state.
-- @src scripts/multiplayer/Lobby.cs:SetModifier L140-155
function Lobby.SetModifier(Mod: Modifier.Modifier, Active: boolean)
	if Active == IsActive(Mod.Name) then
		return
	end

	if Active then
		table.insert(Lobby.Modifiers, Mod)
	else
		for Index, Entry in Lobby.Modifiers do
			if Entry.Name == Mod.Name then
				table.remove(Lobby.Modifiers, Index)

				break
			end
		end
	end

	Signal.Fire(Lobby.ModifiersChanged, ModifierNames())
end

return Lobby
