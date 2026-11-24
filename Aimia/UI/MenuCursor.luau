--!strict
--!optimize 2

--[[
	The menu cursor (scripts/ui/MenuCursor.cs): a texture that follows the mouse, sized by CursorScale, shown while
	UseCursorInMenus is on (the native cursor is hidden then), drawn with the skin's cursor image.

	Design Notes
		MenuCursor.Instance is the source's static instance: the game and pause menus call UpdateVisible on it.
		The subscriptions go with the item (Listen, Input.OnInput into Item.Cleanup).
]]

const UserInputService = game:GetService("UserInputService")

const Images = require("./Images")
const Input = require("./Input")
const Items = require("./Item")
const Listen = require("./Menu/HomeLogic/Listen")
const Nodes = require("./Nodes")
const Numbers = require("../Numbers")
const SettingsManager = require("../SettingsManager")
const SettingsProfile = require("../Database/Settings/SettingsProfile")
const SkinManager = require("../Skinning/SkinManager")
const SkinProfile = require("../Skinning/SkinProfile")
const SkinTexture = require("./Menu/HomeLogic/SkinTexture")

export type CursorState = {
	Item: Items.Item,
	-- whether it shows, and its side in pixels (kept: reading the size back through Nodes flushed the layout)
	Visible: boolean,
	Side: number,
}

const MenuCursor = {
	Instance = nil :: CursorState?,
}

-- @src scripts/ui/MenuCursor.cs:UpdateSize L31-34
const function UpdateSize(State: CursorState, Size: number)
	const Side = Numbers.F32(32 * Size)

	State.Side = Side
	Nodes.Set(State.Item, "size", vector.create(Side, Side, 0))
end

-- @src scripts/ui/MenuCursor.cs:UpdateSkin L46-51
const function UpdateSkin(State: CursorState, Skin: SkinProfile.SkinProfile?)
	const Source = Skin or SkinManager.Skin

	Nodes.Set(State.Item, "texture", SkinTexture(Source.CursorImage, Images.Register))
end

-- @src scripts/ui/MenuCursor.cs:UpdateVisible L36-44
function MenuCursor.UpdateVisible(State: CursorState, Visible: boolean, UpdateNativeCursor: boolean?)
	State.Visible = Visible
	Nodes.Set(State.Item, "visible", Visible)

	if UpdateNativeCursor ~= false then
		Input.SetMouseMode(if Visible then "Hidden" else "Visible")
	end
end

-- @src scripts/ui/MenuCursor.cs:_Ready L8-21
-- @src scripts/ui/MenuCursor.cs:_Input L23-29
function MenuCursor.New(Item: Items.Item)
	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile
	const State = { Item = Item, Visible = false, Side = 32 } :: CursorState

	MenuCursor.Instance = State

	Listen(Item, Settings.CursorScale.Updated, function(Value: number)
		UpdateSize(State, Value)
	end)
	Listen(Item, Settings.UseCursorInMenus.Updated, function(Value: boolean)
		MenuCursor.UpdateVisible(State, Value)
	end)
	Listen(Item, SkinManager.Loaded, function(Skin: SkinProfile.SkinProfile)
		UpdateSkin(State, Skin)
	end)

	UpdateSize(State, Settings.CursorScale.Value)
	MenuCursor.UpdateVisible(State, Settings.UseCursorInMenus.Value)
	UpdateSkin(State, nil)

	-- _Input: the cursor follows every mouse motion, GUI or not, centred on its own size. DEVIATION(frame): a mouse reports many
	-- motions a frame, and each placement lays the scene out, so the last motion is placed once a frame.
	local Motion: vector? = nil

	table.insert(Item.Cleanup, Input.OnInput(function(Event: Input.InputEvent)
		if Event.Class == "InputEventMouseMotion" then
			Motion = Event.Position
		end
	end))
	Nodes.OnProcess(Item, function()
		const Position = Motion

		-- (not while it's hidden or the mouse is locked in a song: each placement lays the scene out part-way through the frame,
		-- before the game has moved; the last motion waits for the cursor to show)
		if Position and State.Visible and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
			Motion = nil
			-- (from the window's mouse position, as the root's space is: the motion's own position is below the top bar's inset,
			-- so the cursor drew 58 px above the real pointer)
			Nodes.Set(Item, "position", Input.GetMousePosition() - vector.create(State.Side, State.Side, 0) / 2)
		end
	end)
end

return MenuCursor
