--!strict
--!optimize 2

--[[
	The link button (scripts/ui/LinkPopupButton.cs): a Button that asks before opening its link. Roblox cannot open a URL,
	so "Open" shows the link in a popup with a text field the player can select and copy.

	Paradigm
		New(Item, Context) is attached by ScriptRegistry to each link button of a scene, and is the base of the scripts that
		extend it (ReleaseNotesButton). The state of a button is kept by its item; UpdateLink, Press and Destroy take the item.

	Design Notes
		The two popups are created with the button (upstream: _EnterTree) under the scene's root, and Destroy frees them
		(upstream: _ExitTree). The button node itself is freed with its scene.
		The copy field is a read-only text field of the copy popup (OptionPopup.AddField), between its info and its buttons,
		as upstream's CopyPopup container holds it.
		The "Open" option's tooltip is the link, read when shown (a getter), as upstream sets it in UpdateLink.
		DEVIATION(platform): OS.ShellOpen has no Roblox equivalent: "Open" shows the link for copying instead.
		DEVIATION(unverified): whether a read-only Roblox TextBox (TextEditable off) lets the player select and copy its text
		is not checked in Studio.
]]

const Nodes = require("./Nodes")
const OptionPopup = require("./OptionPopup")
const SceneBuilder = require("./SceneBuilder")
const Text = require("./SettingsLogic/Text")
const TextField = require("./Settings/TextField")
const BaseScene = require("./Scenes/BaseScene")

type Item = SceneBuilder.Item

export type LinkButton = {
	Link: string,
	Popup: OptionPopup.OptionPopup,
	CopyPopup: OptionPopup.OptionPopup,
	Field: TextField.TextField,
	Connections: { () -> () },
}

-- The state of each link button, by its item.
const Buttons: { [Item]: LinkButton } = {}

-- The state of a link button; an item that is not one is an error.
const function StateOf(Item: Item): LinkButton
	return Buttons[Item] or error(`Aimia UI: {Item.Name} is not a link button`, 3)
end

-- Press: the confirmation popup of the link.
-- @src scripts/ui/LinkPopupButton.cs:Press L47-50
const function Press(Item: Item)
	OptionPopup.Show(StateOf(Item).Popup)
end

-- UpdateLink: the link, the confirmation text and the copy field (the "Open" tooltip reads the link when shown).
-- @src scripts/ui/LinkPopupButton.cs:UpdateLink L52-65
const function UpdateLink(Item: Item, Link: string)
	const Button = StateOf(Item)

	Button.Link = Link

	OptionPopup.UpdateInfo(Button.Popup, Text.LinkInfo(Link))
	TextField.SetText(Button.Field, Link)
end

-- The link button of a scene: builds its popups, sets its link from the node's Link property, and wires its press.
-- @src scripts/ui/LinkPopupButton.cs:_EnterTree L14-31
-- @src scripts/ui/LinkPopupButton.cs:_Ready L40-45
const function New(Item: Item, _: BaseScene.Context)
	const Built = Item.Scene
	const Stored = Nodes.Get(Item, "Link")
	const Popup = OptionPopup.Create(Built, "Open Link", "")
	const CopyPopup = OptionPopup.Create(Built, "Copy Link", "")
	const Field = OptionPopup.AddField(CopyPopup, "")

	Buttons[Item] = {
		Link = "",
		Popup = Popup,
		CopyPopup = CopyPopup,
		Field = Field,
		Connections = {},
	}

	UpdateLink(Item, if type(Stored) == "string" then Stored else "")

	-- DEVIATION(platform): OS.ShellOpen has no Roblox equivalent; "Open" shows the copy popup instead.
	OptionPopup.AddOption(Popup, "Open", function()
		OptionPopup.Show(CopyPopup)
	end, function(): string
		return StateOf(Item).Link
	end)
	OptionPopup.AddOption(Popup, "Cancel", function()
		OptionPopup.Hide(Popup)
	end)

	table.insert(StateOf(Item).Connections, Nodes.Connect(Item, "pressed", function()
		Press(Item)
	end))
end

-- _ExitTree: disconnects the button and frees its popups.
const function Destroy(Item: Item)
	const Button = StateOf(Item)

	for _, Disconnect in Button.Connections do
		Disconnect()
	end

	table.clear(Button.Connections)
	OptionPopup.Destroy(Button.Popup)
	OptionPopup.Destroy(Button.CopyPopup)
	Buttons[Item] = nil
end

return {
	New = New,
	Press = Press,
	UpdateLink = UpdateLink,
	Destroy = Destroy,
	InfoTemplate = Text.LinkInfoTemplate,
}
