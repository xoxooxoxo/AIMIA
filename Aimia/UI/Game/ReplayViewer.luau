--!strict
--!optimize 2

--[[
	The replay viewer's view (scripts/game/managers/ReplayManager.cs _Ready and the show, seek and pause parts) on the game scene's
	ReplayViewer node: the seeker and its time label, the pause button, the tip and the background, and the orthogonal camera
	panel. New fills the ReplayManager.View callbacks for the run and connects the controls to the manager; the function it
	returns clears the callbacks and disconnects.

	Design Notes
		The seeker's hover state is the manager's SeekerHovered, set on focus; the drag end seeks to the seeker's value and releases
		its focus, as upstream.
		DEVIATION(phase3): the replay's mouse visibility goes through SetMouseMode (the mouse mode names of UI/Scenes/Game).
		The pause icon is pause.png while the run plays and play.png when it is paused (SetPauseIcon takes the playing state).
]]

const Items = require("../Item")
const Nodes = require("../Nodes")
const ReplayManagerModule = require("../../Game/Managers/ReplayManager")

type Item = Items.Item

const PauseIconPath = "res://textures/ui/pause.png"
const PlayIconPath = "res://textures/ui/play.png"

-- The replay viewer of a run: connects its controls to the replay manager and the manager's View callbacks to the controls.
-- Answers the function that disconnects them and clears the callbacks.
-- @src scripts/game/managers/ReplayManager.cs:_Ready L163-199
const function New(Item: Item, Replay: ReplayManagerModule.Manager, SetMouseMode: (Mode: string) -> ()): () -> ()
	const Pause = Nodes.GetNode(Item, "Pause")
	const Time = Nodes.GetNode(Item, "Time")
	const Seek = Nodes.GetNode(Item, "Seek")
	const Tip = Nodes.GetNode(Item, "Tip")
	const Background = Nodes.GetNode(Item, "Background")
	const OrthogonalPanel = Nodes.GetNode(Item, "OrthogonalPanel")
	const Connections: { () -> () } = {}
	const ViewerItems = { Pause, Time, Seek, Tip, Background }

	const function ShowViewer(Visible: boolean)
		for _, Control in ViewerItems do
			Nodes.Set(Control, "visible", Visible)
		end
	end

	const function SetMouseVisible(Visible: boolean)
		SetMouseMode(if Visible then "Visible" else "Hidden")
	end

	const function ShowOrthogonal(Visible: boolean)
		Nodes.Set(OrthogonalPanel, "visible", Visible)
	end

	const function SetIcon(Playing: boolean)
		Nodes.Set(Pause, "texture_normal", { Path = if Playing then PauseIconPath else PlayIconPath })
	end

	const function SetSeeker(Ratio: number)
		Nodes.Set(Seek, "value", Ratio)
	end

	ReplayManagerModule.View.ShowReplayViewer = ShowViewer
	ReplayManagerModule.View.SetMouseVisible = SetMouseVisible
	ReplayManagerModule.View.ShowOrthogonalCamera = ShowOrthogonal
	ReplayManagerModule.View.SetPauseIcon = SetIcon
	ReplayManagerModule.View.SetSeekerValue = SetSeeker

	table.insert(Connections, Nodes.Connect(Pause, "pressed", function()
		ReplayManagerModule.TogglePause(Replay)
	end))
	table.insert(Connections, Nodes.Connect(Seek, "value_changed", function(Value: unknown)
		Nodes.Set(Time, "text", ReplayManagerModule.TimeText(Replay, Value :: number))
	end))
	table.insert(Connections, Nodes.Connect(Seek, "drag_ended", function()
		ReplayManagerModule.Seek(Replay, Nodes.Get(Seek, "value") :: number)
		Nodes.ReleaseFocus(Seek)
	end))
	table.insert(Connections, Nodes.Connect(Seek, "focus_entered", function()
		Replay.SeekerHovered = true
	end))
	table.insert(Connections, Nodes.Connect(Seek, "focus_exited", function()
		Replay.SeekerHovered = false
	end))

	const function Destroy()
		for _, Disconnect in Connections do
			Disconnect()
		end

		ReplayManagerModule.View.ShowReplayViewer = nil
		ReplayManagerModule.View.SetMouseVisible = nil
		ReplayManagerModule.View.ShowOrthogonalCamera = nil
		ReplayManagerModule.View.SetPauseIcon = nil
		ReplayManagerModule.View.SetSeekerValue = nil
	end

	return Destroy
end

return New
