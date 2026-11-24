--!strict
--!optimize 2

--[[
	CameraModes.cs (scripts/ui/menu/play/CameraModes.cs) on the Modes panel of the map info: one toggle button per camera mode,
	pressed while the lobby holds that mode. Pressing the held mode again turns it off: the lobby goes back to the default
	camera (CameraLock(), "Normal"), which has no button, so none is lit.

	Design Notes
		The modes are Lock (CameraLock(true): the camera stays still and only the cursor moves) and Spin. In the source's list
		(RegisterCameraModes: CameraLock, CameraSpin) its Lock, today's default camera, was always held; it is the unlit
		default here (2026-11-08). Aimia.CameraModes is not ported, so the list is here.
		Buttons are named after their mode and the pressed state reads the name, as the source does.
]]

const BaseScene = require("../../Scenes/BaseScene")
const CameraLock = require("../../../Game/Camera/CameraLock")
const CameraSpin = require("../../../Game/Camera/CameraSpin")
const Lobby = require("../../../Multiplayer/Lobby")
const Nodes = require("../../Nodes")
const SceneBuilder = require("../../SceneBuilder")
const Signal = require("../../../Util/Signal")

type Entry = {
	Name: string,
	Button: SceneBuilder.Item,
}

-- @src scripts/ui/menu/play/CameraModes.cs:updateButtons L63-69
const function UpdateButtons(Entries: { Entry }, Mode: string)
	for _, Entry in Entries do
		Nodes.Set(Entry.Button, "button_pressed", Entry.Name == Mode)
	end
end

-- @src scripts/ui/menu/play/CameraModes.cs:_Ready L14-21 and updateModes L28-61
const function New(Item: SceneBuilder.Item, Context: BaseScene.Context)
	const Container = Nodes.GetNode(Item, "ScrollContainer/VBoxContainer")
	const Template = Nodes.GetNode(Item, "ScrollContainer/VBoxContainer/CameraButton")
	const Modes = { CameraLock(true), CameraSpin() }
	const Entries: { Entry } = {}

	Nodes.RemoveChild(Container, Template)

	for _, Child in Nodes.GetChildren(Container) do
		Nodes.QueueFree(Child)
	end

	for _, Mode in Modes do
		const Button = Nodes.Duplicate(Template)

		Nodes.Set(Button, "name", Mode.Name)
		Nodes.Set(Button, "text", Mode.Name)

		Nodes.Connect(Button, "pressed", function()
			if Lobby.CameraMode.Name ~= Mode.Name then
				Lobby.SetCameraMode(Mode)
			else
				-- (the held mode again: off, back to the default camera; the change lights no button)
				Lobby.SetCameraMode(CameraLock())
			end
		end)

		Nodes.AddChild(Container, Button)
		table.insert(Entries, {
			Name = Mode.Name,
			Button = Button,
		})
	end

	const function OnChanged(Name: string)
		UpdateButtons(Entries, Name)
	end

	UpdateButtons(Entries, Lobby.CameraMode.Name)
	Signal.Connect(Lobby.CameraModeChanged, OnChanged)

	table.insert(Item.Cleanup, function()
		Signal.Disconnect(Lobby.CameraModeChanged, OnChanged)
	end)
end

return New
