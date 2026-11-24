--!strict
--!optimize 2

--[[
	PlayerInputController.cs as pure logic: the game's keyboard and mouse input, turned into the controller's events (pause,
	restart, the replay viewer and camera toggles, pause-or-skip, fade, pushback, the mouse and the left button). The scene
	feeds it: each input event calls HandleKey, HandleMouseMotion or HandleMouseButton, which replace the node's _Input.

	Representation
		Events are Util/Signal values. OnMouseMove fires (Relative, Absolute) as vectors with Z = 0. Keys are the Godot key names
		that UI/Input emits: Key.Escape is "Escape", the backquote key is "Quoteleft".

	Design Notes
		HandleMouseButton takes the left button only: the scene passes the events whose ButtonIndex is MouseButton.Left, as the
		source's switch filters them. A double click and a release fire nothing.
		Echo (key repeat) events fire nothing, the release of Space included. A key the source does not bind fires nothing.
		Each entry point checks IsEnabled first, as _Input does. OnToggleShowOrthonogalCamera keeps the source's spelling.
]]

const Signal = require("../Util/Signal")

export type PlayerInputController = {
	OnMouseMove: Signal.Signal<vector, vector>,
	OnTogglePaused: Signal.Signal<()>,
	OnRestartPressed: Signal.Signal<()>,
	OnToggleReplayViewerVisibility: Signal.Signal<()>,
	OnToggleShowOrthonogalCamera: Signal.Signal<()>,
	OnPauseOrSkipPressed: Signal.Signal<()>,
	OnPauseOrSkipReleased: Signal.Signal<()>,
	OnToggleFade: Signal.Signal<()>,
	OnTogglePushback: Signal.Signal<()>,
	OnLeftMouseButton: Signal.Signal<boolean>,
	IsEnabled: boolean,
}

-- @src scripts/PlayerInputController.cs:handleMouseInput L57-69
const function HandleMouseMotion(Controller: PlayerInputController, Relative: vector, Absolute: vector)
	if not Controller.IsEnabled then
		return
	end

	Signal.Fire(Controller.OnMouseMove, Relative, Absolute)
end

-- @src scripts/PlayerInputController.cs:handleMouseInput L57-69
const function HandleMouseButton(Controller: PlayerInputController, Pressed: boolean, DoubleClick: boolean)
	if not Controller.IsEnabled or not Pressed or DoubleClick then
		return
	end

	Signal.Fire(Controller.OnLeftMouseButton, Pressed)
end

-- @src scripts/PlayerInputController.cs:handleKeyboardInput L71-120
const function HandleKey(Controller: PlayerInputController, Key: string, Pressed: boolean, Echo: boolean)
	if not Controller.IsEnabled or Echo then
		return
	end

	if Key == "Space" then
		if Pressed then
			Signal.Fire(Controller.OnPauseOrSkipPressed)
		else
			Signal.Fire(Controller.OnPauseOrSkipReleased)
		end
	end

	if not Pressed then
		return
	end

	-- (Escape no longer pauses: Roblox's own menu takes that key and opened over the pause menu, and a second press closed
	-- both. The pause menu is R held in a song, Client.Controllers.Handheld. The owner's call, 2026-11-10.)
	if Key == "Quoteleft" then
		Signal.Fire(Controller.OnRestartPressed)
	elseif Key == "F2" then
		Signal.Fire(Controller.OnToggleReplayViewerVisibility)
	elseif Key == "F3" then
		Signal.Fire(Controller.OnToggleShowOrthonogalCamera)
	elseif Key == "F" then
		Signal.Fire(Controller.OnToggleFade)
	elseif Key == "P" then
		Signal.Fire(Controller.OnTogglePushback)
	end
end

-- @src scripts/PlayerInputController.cs:PlayerInputController L6-35
const function New(): PlayerInputController
	return {
		OnMouseMove = Signal.New(),
		OnTogglePaused = Signal.New(),
		OnRestartPressed = Signal.New(),
		OnToggleReplayViewerVisibility = Signal.New(),
		OnToggleShowOrthonogalCamera = Signal.New(),
		OnPauseOrSkipPressed = Signal.New(),
		OnPauseOrSkipReleased = Signal.New(),
		OnToggleFade = Signal.New(),
		OnTogglePushback = Signal.New(),
		OnLeftMouseButton = Signal.New(),
		IsEnabled = true,
	}
end

-- @src scripts/PlayerInputController.cs:ToggleState L122-122
const function ToggleState(Controller: PlayerInputController)
	Controller.IsEnabled = not Controller.IsEnabled
end

return {
	New = New,
	HandleKey = HandleKey,
	HandleMouseMotion = HandleMouseMotion,
	HandleMouseButton = HandleMouseButton,
	ToggleState = ToggleState,
}
