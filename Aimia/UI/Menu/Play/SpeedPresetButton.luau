--!strict
--!optimize 2

--[[
	SpeedPresetButton.cs (scripts/ui/menu/play/SpeedPresetButton.cs) on res://prefabs/speed_preset_button.tscn: a button that sets
	the lobby's speed to its preset and is pressed while the speed is that preset.

	Design Notes
		The preset (the Speed export, 100 when the instance does not set it) is the node's Speed property.
		The button's state follows Lobby.SpeedChanged until the node is freed (Item.Cleanup).
]]

const Format = require("./InfoLogic/Format")
const Lobby = require("../../../Multiplayer/Lobby")
const Nodes = require("../../Nodes")
const BaseScene = require("../../Scenes/BaseScene")
const SceneBuilder = require("../../SceneBuilder")
const Signal = require("../../../Util/Signal")

const DefaultSpeed = 100

-- @src scripts/ui/menu/play/SpeedPresetButton.cs:_Ready L10-19 and updateState L28-36
-- @src scripts/ui/menu/play/SpeedPresetButton.cs:_Pressed L21-26
const function New(Item: SceneBuilder.Item, Context: BaseScene.Context)
	const Preset = if type(Nodes.Get(Item, "Speed")) == "number" then Nodes.Get(Item, "Speed") :: number else DefaultSpeed

	Nodes.Set(Item, "tooltip_text", Format.Shortest(Preset))

	const function UpdateState(Speed: number)
		if not Nodes.IsInstanceValid(Item) then
			return
		end

		Nodes.Set(Item, "button_pressed", Preset / 100 == Speed)
	end

	UpdateState(Lobby.Speed)
	Signal.Connect(Lobby.SpeedChanged, UpdateState)

	Nodes.Connect(Item, "pressed", function()
		Lobby.SetSpeed(Preset / 100)
	end)

	table.insert(Item.Cleanup, function()
		Signal.Disconnect(Lobby.SpeedChanged, UpdateState)
	end)
end

return New
