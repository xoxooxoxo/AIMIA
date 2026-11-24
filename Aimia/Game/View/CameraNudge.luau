--!strict

--[=[
	A nudge on top of the song's camera, for the owner panel's trolls (StarterPlayerScripts Client.Controllers.AimiaTrolls,
	sent by the server's Players.AimiaOwner): GameWorld.Sync multiplies the camera's CFrame by Offset every frame. Only the
	view moves: the cursor, the notes and every hit are worked out in the game's own space, never from the camera. Offset is
	the identity unless an effect is running, and the effects put it back when they end.
]=]

return {
	Offset = CFrame.identity,
	-- the nudge the Workspace camera carries now: the Offset that GameWorld.Sync last multiplied in (it trails Offset until
	-- the next Sync, and GameWorld.Destroy clears it). The HUD's canvas fitting takes this one out: UI/Game/UIComponent
	Applied = CFrame.identity,
}
