--!strict
--!optimize 2

--[[
	Modifiers.cs (scripts/ui/menu/play/Modifiers.cs) on the Modifiers panel of the map info: one toggle button per modifier in
	Aimia.Modifiers, pressed while the lobby holds it. The panel's template button is cloned for each modifier.

	Design Notes
		The clones are named after the modifier by Nodes.Set("name") and keep the modifier name in the list, which is what the
		pressed state reads (the source reads Button.Name).
		DEVIATION: the modifier color override (icon_pressed_color and icon_hover_pressed_color) is set on the clone as a theme
		override.
		Not in the source (2026-11-10, the owner's ask): pointing at a modifier shows a small card over it with its name and what
		it does, in the settings menu's dark rounded look with an edge in the modifier's own colour (upstream's tooltip_text
		is never drawn here). One card serves every button. The leaderboard bonuses it names are the server's
		(Progression.AimiaBoards.Rules MOD_BONUS; a run with No Fail or Autoplay isn't listed): change both together.
]]

const GuiService = game:GetService("GuiService")
const Players = game:GetService("Players")
const RunService = game:GetService("RunService")
const UserInputService = game:GetService("UserInputService")

const BaseScene = require("../../Scenes/BaseScene")
const Lobby = require("../../../Multiplayer/Lobby")
const Misc = require("../../../Util/Misc")
const Nodes = require("../../Nodes")
const Aimia = require("../../../Aimia")
const SceneBuilder = require("../../SceneBuilder")
const SkinManager = require("../../../Skinning/SkinManager")
const Signal = require("../../../Util/Signal")
const Textures = require("./Textures")
const Draw = require("../../Settings/Draw")
const Look = require("../../Settings/Look")
const Scale = require("../../Scale")
const Items = require("../../Item")
const Input = require("../../Input")

-- What each modifier is called on its card, and what the card says.
const Titles: { [string]: string } = {
	NoFail = "No Fail",
	HFlip = "Horizontal Flip",
	VFlip = "Vertical Flip",
}
const About: { [string]: string } = {
	NoFail = "You can't fail: the song plays to the end even with no health left. Runs with it don't go on the leaderboards.",
	Autoplay = "The song plays itself, so you can sit back and watch. Runs with it don't count.",
	Ghost = "Notes fade away as they come in and are gone before they reach the grid. +15% leaderboard points.",
	Strobe = "Notes blink: they're hidden half of the time. +12% leaderboard points.",
	Chaos = "Notes drift off course on their way in and only line up at the grid. +8% leaderboard points.",
	Vortex = "Notes swirl around the middle on their way in. +10% leaderboard points.",
	Earthquake = "Notes shake on their way in, more the further away they are. +6% leaderboard points.",
	HFlip = "Mirrors the map left to right. +3% leaderboard points.",
	VFlip = "Mirrors the map top to bottom. +3% leaderboard points.",
}

-- The card: its width, the room round its text, its title's height, the gap to the button, and how long the pointer rests
-- on a button before it shows.
const CardWidth = 300
const CardMarginX = 10
const CardMarginY = 8
const CardTitleHeight = 22
const CardGap = 8
const CardDelay = 0.3
const Zero = { X = 0, Y = 0, Width = 0, Height = 0 }

type Entry = {
	Name: string,
	Button: SceneBuilder.Item,
}

-- Whether the lobby holds a modifier of this name.
const function LobbyHas(Name: string): boolean
	for _, Mod in Lobby.Modifiers do
		if Mod.Name == Name then
			return true
		end
	end

	return false
end

-- @src scripts/ui/menu/play/Modifiers.cs:updateButtons L61-67
const function UpdateButtons(Entries: { Entry }, Names: { string })
	for _, Item in Entries do
		local Pressed = false

		for _, Name in Names do
			if Name == Item.Name then
				Pressed = true
			end
		end

		Nodes.Set(Item.Button, "button_pressed", Pressed)
	end
end

-- @src scripts/ui/menu/play/Modifiers.cs:_Ready L16-23 and updateModifiers L30-59
const function New(Item: SceneBuilder.Item, Context: BaseScene.Context)
	const Container = Nodes.GetNode(Item, "ScrollContainer/HBoxContainer")
	const Template = Nodes.GetNode(Item, "ScrollContainer/HBoxContainer/ModifierButton")
	const Entries: { Entry } = {}

	Nodes.RemoveChild(Container, Template)

	for _, Child in Nodes.GetChildren(Container) do
		Nodes.QueueFree(Child)
	end

	-- The card, hidden until a button is pointed at. It is moved under the screen's own frame when it shows, so nothing clips
	-- it (the panel isn't in the screen yet while this runs).
	local Top = Item.Instance :: Instance
	const Card = Draw.Frame(Top, "ModifierCard", Zero, 60, false)

	Card.Visible = false
	Draw.Fill(Card, Look.PopupPanelFill)
	Draw.Corner(Card, Look.Corner)

	const CardEdge = Draw.Stroke(Card, Look.Pink, 1)
	const CardTitle = Draw.Label(Card, "Title", Zero, 61, "", Look.Fonts.UbuntuMedium, Look.Sizes.Body, Look.FontWhite, Enum.TextXAlignment.Left)
	const CardText = Draw.Label(Card, "Text", Zero, 61, "", Look.Fonts.Default, Look.Sizes.Body, Look.FontNormal, Enum.TextXAlignment.Left)

	CardText.TextWrapped = true
	CardText.TextTruncate = Enum.TextTruncate.None
	CardText.TextYAlignment = Enum.TextYAlignment.Top

	local CardToken = 0
	local CardWatch: RBXScriptConnection? = nil
	-- the button the pointer is on (leaving another button doesn't put this one's card away)
	local Hovered: GuiObject? = nil

	const function HideCard()
		CardToken += 1
		Card.Visible = false

		if CardWatch then
			CardWatch:Disconnect()
			CardWatch = nil
		end
	end

	-- Whether the pointer is on a button that can be pointed at now (the Play tab showing, nothing over it).
	const function PointedAt(Target: GuiObject): boolean
		if Nodes.HiddenInTree(Item) or not Target:IsDescendantOf(game) or Input.Blocked(Target) then
			return false
		end

		const Mouse = Input.GetGuiMousePosition()
		const At = Scale.PositionOf(Target)
		const Box = Scale.SizeOf(Target)

		if not (Mouse.x >= At.x and Mouse.y >= At.y and Mouse.x < At.x + Box.x and Mouse.y < At.y + Box.y) then
			return false
		end

		-- (not while another button of this screen lies over it there: the expanded leaderboard and its dim cover the panel)
		const Layer = Target:FindFirstAncestorWhichIsA("LayerCollector")
		const Player = Players.LocalPlayer
		const Gui = if Player then Player:FindFirstChildOfClass("PlayerGui") else nil

		if Layer and Gui then
			const Pointer = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()

			for _, Hit in Gui:GetGuiObjectsAtPosition(Pointer.X, Pointer.Y) do
				if Hit == Target or Hit:IsDescendantOf(Target) then
					return true
				end

				if Hit:IsA("GuiButton") and Hit:IsDescendantOf(Layer) and not Hit:IsDescendantOf(Card) then
					return false
				end
			end
		end

		return true
	end

	-- Shows the card for a modifier over its button (under it when there's no room above), inside the screen. It goes when
	-- the pointer leaves, the button is pressed, or the menu under it changes.
	const function ShowCard(Mod: { Name: string, Color: { R: number, G: number, B: number } }, Target: GuiObject)
		const Text = About[Mod.Name]

		if not Text or not PointedAt(Target) then
			return
		end

		-- (under this menu's own scene, the third frame down from the screen: it leaves with the scene, and the menu cursor
		-- and the scene change's fade, which belong to the frames above it, stay over it)
		const Chain: { Instance } = {}
		local Node: Instance? = Target

		while Node and Node:IsA("GuiObject") do
			table.insert(Chain, Node)
			Node = Node.Parent
		end

		Top = Chain[math.max(#Chain - 2, 1)]

		if not Top:IsA("GuiObject") then
			return
		end

		if Card.Parent ~= Top then
			Card.Parent = Top
		end

		const Tint = Color3.new(Mod.Color.R, Mod.Color.G, Mod.Color.B)
		const Inner = CardWidth - 2 * CardMarginX
		-- (measured a little narrower than it is drawn, as the settings tooltips are: small text comes out a touch wider than
		-- its share, and a line that wrapped early would push the last one out of the card)
		const Size = Items.Measure(Text, Look.Fonts.Default, Look.Sizes.Body, math.floor(Inner / 1.1))
		const Height = CardMarginY + CardTitleHeight + math.ceil(Size.y) + 4 + CardMarginY
		const Origin = Scale.PositionOf(Top)
		const Bounds = Scale.SizeOf(Top)
		const At = Scale.PositionOf(Target) - Origin
		const Box = Scale.SizeOf(Target)
		const Left = math.clamp(math.round(At.x + Box.x / 2 - CardWidth / 2), 4, math.max(4, Bounds.x - CardWidth - 4))
		local Above = math.round(At.y - Height - CardGap)

		if Above < 4 then
			Above = math.round(At.y + Box.y + CardGap)
		end

		CardEdge.Color = Tint
		CardTitle.TextColor3 = Tint
		CardTitle.Text = Titles[Mod.Name] or Mod.Name
		CardText.Text = Text
		Draw.Place(Card, { X = Left, Y = Above, Width = CardWidth, Height = Height })
		Draw.Place(CardTitle, { X = CardMarginX, Y = CardMarginY, Width = Inner, Height = CardTitleHeight })
		Draw.Place(CardText, { X = CardMarginX, Y = CardMarginY + CardTitleHeight, Width = Inner, Height = Height - CardTitleHeight - 2 * CardMarginY })
		Card.Visible = true

		if CardWatch then
			CardWatch:Disconnect()
		end

		CardWatch = RunService.Heartbeat:Connect(function()
			if not PointedAt(Target) then
				HideCard()
			end
		end)
	end

	table.insert(Item.Cleanup, function()
		HideCard()
		Card:Destroy()
	end)
	-- (any key puts the card away: Space starts the song and F2 changes the map with the pointer still on a button)
	table.insert(Item.Cleanup, Input.OnInput(function(Event: Input.InputEvent)
		if Event.Class == "InputEventKey" and Event.Pressed then
			HideCard()
		end
	end))

	for _, Mod in Aimia.Modifiers do
		const Button = Nodes.Duplicate(Template)

		Nodes.Set(Button, "name", Mod.Name)
		Nodes.Set(Button, "tooltip_text", Mod.Name)
		Nodes.Set(Button, "icon", Textures(Misc.GetModIcon(Mod.Name, SkinManager.Skin)))
		Nodes.Set(Button, "theme_override_colors/icon_pressed_color", { Color = { Mod.Color.R, Mod.Color.G, Mod.Color.B, Mod.Color.A } })
		Nodes.Set(Button, "theme_override_colors/icon_hover_pressed_color", { Color = { Mod.Color.R, Mod.Color.G, Mod.Color.B, Mod.Color.A } })

		Nodes.Connect(Button, "pressed", function()
			Lobby.SetModifier(Mod, not LobbyHas(Mod.Name))
		end)

		Nodes.AddChild(Container, Button)

		-- (its card, after the pointer has rested on it a moment)
		const Target = (Button :: any).Instance

		if typeof(Target) == "Instance" and Target:IsA("GuiObject") then
			Target.MouseEnter:Connect(function()
				HideCard()
				Hovered = Target

				const Token = CardToken

				task.delay(CardDelay, function()
					if Token == CardToken then
						ShowCard(Mod :: any, Target)
					end
				end)
			end)
			Target.MouseLeave:Connect(function()
				if Hovered == Target then
					Hovered = nil
					HideCard()
				end
			end)
			Target.InputBegan:Connect(function(Event: InputObject)
				if Event.UserInputType == Enum.UserInputType.MouseButton1 then
					HideCard()
				end
			end)
		end

		table.insert(Entries, {
			Name = Mod.Name,
			Button = Button,
		})
	end

	const function OnChanged(Names: { string })
		UpdateButtons(Entries, Names)
	end

	const Names: { string } = {}

	for _, Mod in Lobby.Modifiers do
		table.insert(Names, Mod.Name)
	end

	UpdateButtons(Entries, Names)
	Signal.Connect(Lobby.ModifiersChanged, OnChanged)

	table.insert(Item.Cleanup, function()
		Signal.Disconnect(Lobby.ModifiersChanged, OnChanged)
	end)
end

return New
