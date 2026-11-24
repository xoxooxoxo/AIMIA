--!optimize 2

--[[
	The VS section of the main menu (fifth, after Spectate): AIMIA's VS mode, where up to five players play one song with
	the same speed and modifiers, their scores live against each other (Multiplayer/Versus; the lobbies are the server's,
	Server.Services.Players.AimiaVersus). Out of a lobby, this server's lobbies are listed on the right as Play lists songs,
	and the picked one is on the left, with JOIN. In a lobby, its players are on the right (best first through a round, by
	place after it) and its song on the left, with START for the host (the count on it as the round starts) and WATCH for
	anyone out of a round that's still going. Under it LEAVE LOBBY, and beside that, for the host while the lobby is open,
	CHANGE SONG (Play, where VS gives the lobby the song, speed and modifiers picked). While the lobby is open the host also
	picks where the round starts in the song (START: a time box over it, and the bar under the stats as a slider; a later
	start keeps the round off the Leaderboards, as it does alone), and has KICK on everyone else's card (pressed twice: SURE?).

	Paradigm
		The section's panel (Menus/Versus) comes from the scene data, so the top bar, the Home button and the tab fade are
		MainMenu's own (AimiaApp adds them, and Play's VS button, which hosts a lobby or changes the host's). The page is
		SpectateMenu's, made the same way: plain Instances in layout pixels, made once by Mount and laid out and faded as
		that page's (its board's boxes, its pill and colours, its cards, their curve, the turning square, the scroll bar);
		its WATCH pill is this page's JOIN, START, count and WATCH. The round's songs and watching are the Handheld's: it
		sets the Hooks, and calls Show, Notice and Reset.

	Design Notes
		Nothing is written while the page is still. A change to any lobby or member (Versus.Version) only sets a flag, and
		the page is read again on the next frame it shows (and every 2 s while it shows, as the player filter tells nobody
		when it changes). Times and bars are worked out 4 times a second, the count each frame. Every frame and input
		handler checks Nodes.HiddenInTree(Section): the cached menu keeps running behind a song, where its panel is still
		Visible.
		Your own card is listed in your lobby (it's the scoreboard), and picked at first. A lobby hosted by someone you've
		hidden with the player filter isn't listed; in your own lobby everyone is.
		Show requires SceneManager and Scenes/MainMenu. Neither of them loads this module (AimiaApp and the Handheld do, once
		the menu is up), so there is no require cycle; keep it so (nothing ScriptRegistry loads may require this one).
		No local is named Font or Content: either hides Roblox's own (Font.new, Content.none, Content.fromObject).
]]

local AssetService = game:GetService("AssetService")
local EncodingService = game:GetService("EncodingService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AimiaInput = require("../Input")
local BBCode = require("../BBCode")
local Constants = require("../../Constants")
local CoverTheme = require("../CoverTheme")
local Frames = require("../Frames")
local Images = require("../Images")
local MainMenu = require("../Scenes/MainMenu")
local MapManager = require("../../Map/MapManager")
local MapModule = require("../../Map/Map")
local MapText = require("./Play/Logic/MapText")
local Nodes = require("../Nodes")
local Scale = require("../Scale")
local SceneManager = require("../SceneManager")
local StartFromLogic = require("./Play/InfoLogic/StartFrom")
local TextureValue = require("./Play/Textures")
local Versus = require("../../Multiplayer/Versus")

local Module = {
	Hooks = {
		-- starts watching a player in your lobby's round (the Handheld sets it): answers whether it started, and why not
		Watch = nil :: ((Player) -> (boolean, string?))?,
		-- who is being watched now, if anyone (the Handheld sets it): WATCH is off while it answers someone
		Watching = nil :: (() -> Player?)?,
		-- whether a player is hidden with the player filter (the Handheld sets it): the lobbies they host aren't listed
		IsHidden = nil :: ((Player) -> boolean)?,
		-- whether this device plays songs (the Handheld sets it): phones and tablets only watch, so they don't join
		CanPlay = nil :: (() -> boolean)?,
	},
	Section = nil :: any, -- the Menus/Versus item, once mounted
	Reset = nil :: (() -> ())?, -- set by Mount: the pick forgotten, the list at the top, no line under the pill
	Notice = nil :: ((string) -> ())?, -- set by Mount: a line under the pill (the server's reason for a refusal, and the like)
}

local Accent = Color3.new(0.7921569, 0, 0.27450982)
local White = Color3.new(1, 1, 1)
local Black = Color3.new(0, 0, 0)
local Grey = Color3.new(0.627, 0.627, 0.627)
local Dim = Color3.new(0.42, 0.42, 0.42)
local HoverTint = Color3.fromRGB(26, 6, 13)
local PanelTransparency = 1 - 224 / 255

-- Play's list, in layout pixels
local CardHeight, CardHover, CardChosen, CardGap, ListTop = 90, 10, 20, 10, 10
local SquareSide = 40

-- The pill (JOIN, START, the count, WATCH), in layout pixels: its height, and where its top goes (under the lobby's row;
-- WatchTopAlone places the line under it before the first draw, as on Spectate). How see-through its inside is at rest and
-- under the mouse; how long the light takes round its ring and each ring under the mouse to spread.
local WatchHeight, WatchTopWithSkin, WatchTopAlone = 72, 456, 456
local WatchRestTransparency, WatchHoverTransparency = 0.18, 0.06
local SheenSeconds, RippleSeconds = 4.5, 1.1
local Faces = 5 -- faces shown at most in the lobby's row (a lobby holds 5)
-- LEAVE LOBBY, under the pill: the gap above it, its width and its height
local LeaveGap, LeaveWidth, LeaveHeight = 14, 220, 44
-- CHANGE SONG, beside it for the host while the lobby is open (the same size): the gap between the two
local PairGap = 12
-- KICK on someone else's card (the host's, while the lobby is open): its size, its right edge from the card's (at the edge,
-- or left of the numbers column on a card that shows numbers), how much narrower the name and state lines get when it sits
-- left of the numbers, and how long the first press waits for the second (SURE?)
local KickWidth, KickHeight, KickRight, KickRightNumbers, KickRoom, KickConfirm = 64, 30, 20, 244, 84, 3
-- the host's start box over START (its size and where it goes in the stats box), and the slider's knob (its side and colour)
local StartBoxWidth, StartBoxHeight = 84, 32
local KnobSide = 14
local KnobColor = Color3.fromRGB(255, 229, 238)

-- the badge's colours: green while a lobby is open, amber as a round starts, red through one, grey when it's full (and
-- the green of a pass, the amber of a win)
local LiveRed = Color3.fromRGB(255, 59, 92)
local LiveAmber = Color3.fromRGB(255, 209, 102)
local LiveGrey = Color3.fromRGB(150, 150, 150)
local LiveGreen = Color3.fromRGB(110, 231, 155)
-- (each badge's width, made again from its words once they can be measured, and the beat of its dot in s: 0 is still)
local Badges = {
	OPEN = { Color = LiveGreen, Width = 90, Beat = 0 },
	STARTING = { Color = LiveAmber, Width = 122, Beat = 0.6 },
	["IN A ROUND"] = { Color = LiveRed, Width = 134, Beat = 1.6 },
	FULL = { Color = LiveGrey, Width = 84, Beat = 0 },
}

local MenuPath = "res://scenes/main_menu.tscn"
-- the times are worked out every TickGap s; JOINING (and STARTING, LEAVING, a watch on its way) shows at most JoinWait s;
-- the list is read again every Reread s while it shows
local TickGap, JoinWait, Reread = 0.25, 10, 2
local Dot = "  \u{B7}  "
local AutoplayText = '<font color="#FFD166">Autoplay</font>' -- (AimiaWatch's colour for it: nobody is playing that run by hand)
local TouchLine = "VS is played on a computer. On a phone or iPad you can watch players from Spectate."

local Entities = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&apos;" }

local function FontOf(Family: string, Weight: Enum.FontWeight?): Font
	return Font.new(`rbxasset://fonts/families/{Family}.json`, Weight or Enum.FontWeight.Regular)
end

local function Make(Class: string, Parent: Instance?, Props: { [string]: any }): any
	local Object = Instance.new(Class)

	for Key, Value in Props do
		(Object :: any)[Key] = Value
	end

	Object.Parent = Parent

	return Object
end

local function Label(Parent: Instance, Props: { [string]: any }): TextLabel
	local Text = Make("TextLabel", Parent, {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		TextColor3 = White,
		FontFace = FontOf("Ubuntu"),
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
	})

	for Key, Value in Props do
		(Text :: any)[Key] = Value
	end

	return Text
end

local function Box(Parent: Instance, Props: { [string]: any }): Frame
	local Frame = Make("Frame", Parent, { BackgroundColor3 = Black, BackgroundTransparency = PanelTransparency, BorderSizePixel = 0 })

	Make("UICorner", Frame, { CornerRadius = UDim.new(0, 4) })

	for Key, Value in Props do
		(Frame :: any)[Key] = Value
	end

	return Frame
end

-- eases Value toward Target at Rate a second, landing on it once it's within Snap
local function Ease(Value: number, Target: number, Rate: number, Delta: number, Snap: number): number
	local Next = Value + (Target - Value) * math.min(1, Rate * Delta)

	return if math.abs(Target - Next) < Snap then Target else Next
end

-- sets a property only when it changes (an unchanged write still costs a redraw)
local function Put(Object: Instance, Property: string, Value: any)
	if (Object :: any)[Property] ~= Value then
		(Object :: any)[Property] = Value
	end
end

local function ModsText(Mods: string?): string
	if type(Mods) ~= "string" or Mods == "" then
		return ""
	end

	local Names = {}

	for Name in Mods:gmatch("[^_]+") do
		table.insert(Names, if Name == "NoFail" then "No Fail" elseif Name == "HFlip" then "H Flip" elseif Name == "VFlip" then "V Flip" else Name)
	end

	return table.concat(Names, ", ")
end

-- The small cover kept with each baked map (the Cover attribute: Zstd RGB, Base64), for a map whose full cover won't decode.
-- (LeaderboardsMenu's, except that the folder isn't held in a local named Content: there it hides Roblox's Content, so
-- Content.fromObject fails inside the pcall and the small cover never shows)
local Thumbs: { [string]: Content | false } = {}

local function ThumbOf(Id: string): Content?
	if Thumbs[Id] ~= nil then
		return Thumbs[Id] or nil
	end

	Thumbs[Id] = false

	local Stock = ReplicatedStorage:FindFirstChild("AimiaContent")
	local Maps = Stock and Stock:FindFirstChild("Maps")
	local Folder = Maps and (Maps:FindFirstChild(Id .. ".sspm") or Maps:FindFirstChild(Id))
	local Text = Folder and Folder:GetAttribute("Cover")

	if type(Text) ~= "string" then
		return nil
	end

	local Made, Picture = pcall(function()
		local Side = 96
		local Rgb = EncodingService:DecompressBuffer(EncodingService:Base64Decode(buffer.fromstring(Text)), Enum.CompressionAlgorithm.Zstd)
		local Rgba = buffer.create(Side * Side * 4)

		for Index = 0, Side * Side - 1 do
			buffer.writeu8(Rgba, Index * 4, buffer.readu8(Rgb, Index * 3))
			buffer.writeu8(Rgba, Index * 4 + 1, buffer.readu8(Rgb, Index * 3 + 1))
			buffer.writeu8(Rgba, Index * 4 + 2, buffer.readu8(Rgb, Index * 3 + 2))
			buffer.writeu8(Rgba, Index * 4 + 3, 255)
		end

		local Image = AssetService:CreateEditableImage({ Size = Vector2.new(Side, Side) })

		Image:WritePixelsBuffer(Vector2.zero, Vector2.new(Side, Side), Rgba)

		return Content.fromObject(Image)
	end)

	Thumbs[Id] = if Made and Picture then Picture else false

	return Thumbs[Id] or nil
end

-- A map's cover as Play shows it, or the small one.
local function CoverOf(Map: any): Content?
	local Got, Picture = pcall(function()
		local Value = TextureValue(MapModule.GetCover(Map))

		return if Value then Images.GetContent(Value.Path) else nil
	end)

	return if Got and Picture then Picture else ThumbOf(Map.Name)
end

local function DifficultyColor(Map: any): any
	local Colors = Constants.DifficultyColors

	return Colors[math.clamp(tonumber(Map.Difficulty) or 0, 0, #Colors - 1) + 1]
end

-- Play's line under a song's title (length, difficulty in its colour, mappers), as Roblox rich text
local function ExtraOf(Map: any): string
	return (BBCode.ToRichText(MapText.ExtraText(Map.Length, MapText.ColorHtml(DifficultyColor(Map)), Map.DifficultyName, Map.PrettyMappers)))
end

-- Text that goes into rich text as it is (names and titles can hold < & and quotes)
local function Escape(Text: string): string
	return (string.gsub(Text, "[&<>\"']", Entities))
end

-- Readable modifiers (ModsText's) for a rich-text label, Autoplay in gold
local function ModsRich(Mods: string): string
	return (string.gsub(Escape(Mods), "Autoplay", AutoplayText))
end

local function Finite(Value: any): boolean
	return type(Value) == "number" and Value == Value and math.abs(Value) ~= math.huge
end

-- The menu's map row by name (MapManager.Maps: its covers are decoded already). The index is made again when the list is
-- replaced or changes length.
local Indexed: { any }? = nil
local IndexedCount = 0
local ByName: { [string]: any } = {}

local function MapOf(MapID: string): any?
	local Maps = MapManager.Maps

	if Indexed ~= Maps or #Maps ~= IndexedCount then
		Indexed = Maps
		IndexedCount = #Maps
		table.clear(ByName)

		for _, Map in Maps do
			ByName[Map.Name] = Map
		end
	end

	return ByName[MapID]
end

-- A lobby's song as the cards and the board show it: the map (this client's list's, else the map folder's own
-- attributes), its colour and length, and the round's modifiers and speed
local function SongOf(Lobby: any): any
	local Stock = ReplicatedStorage:FindFirstChild("AimiaContent")
	local Folders = Stock and Stock:FindFirstChild("Maps")
	local Song = Lobby.Map
	local MapID = if Lobby.MapID ~= "" then Lobby.MapID else (string.gsub(Song, "%.sspm$", ""))
	local Folder = Folders and ((Song ~= "" and Folders:FindFirstChild(Song)) or Folders:FindFirstChild(MapID .. ".sspm"))
	local Map = MapOf(MapID)
	local Color = White

	if Map then
		local Tint = DifficultyColor(Map)

		Color = Color3.new(Tint.R or 1, Tint.G or 1, Tint.B or 1)
	else
		local Baked = Folder and Folder:GetAttribute("DifficultyColor")

		if typeof(Baked) == "Color3" then
			Color = Baked
		end
	end

	local Title = if Map then Map.PrettyTitle else Folder and Folder:GetAttribute("Title")
	local Difficulty = if Map then Map.DifficultyName else Folder and Folder:GetAttribute("DifficultyName")
	local Mappers = if Map then Map.PrettyMappers else Folder and Folder:GetAttribute("Mappers")

	return {
		Song = Song,
		MapID = MapID,
		Map = Map,
		Folder = Folder, -- (its small cover gives the pill a colour)
		Title = if type(Title) == "string" and Title ~= "" then Title else MapID, -- Artist - Title
		Difficulty = if type(Difficulty) == "string" then Difficulty else "",
		Mappers = if type(Mappers) == "string" then Mappers else "",
		Color = Color,
		Length = if Map and Finite(Map.Length) then math.max(Map.Length, 0) else 0, -- ms, 0 when not known
		Mods = ModsText(Lobby.Mods),
		Speed = Lobby.Speed,
		StartFrom = Lobby.StartFrom or 0, -- where the round starts in the song (ms)
	}
end

-- How far the lobby's round's song is (ms of the map), or nil while none is on or it hasn't started (the count)
local function RoundMs(Lobby: any): number?
	if Lobby.State == "Open" or Lobby.StartAt <= 0 or workspace:GetServerTimeNow() < Lobby.StartAt then
		return nil
	end

	return Versus.Elapsed(Lobby)
end

-- "1:23 / 3:45" (only the time when the length isn't known: a map this client's list doesn't have)
local function RoundText(Ms: number, Length: number): string
	local At = MapText.LengthText(math.clamp(Ms, 0, if Length > 0 then Length else math.max(Ms, 0)))

	return if Length > 0 then `{At} / {MapText.LengthText(Length)}` else At
end

-- 1234567 as "1,234,567"
local function Commas(Value: number): string
	local Whole = if Finite(Value) then math.floor(math.max(0, Value)) else 0
	local Text = string.reverse((string.gsub(string.reverse(string.format("%d", Whole)), "(%d%d%d)", "%1,")))

	return (string.gsub(Text, "^,", ""))
end

local function Plural(Number: number, One: string, Many: string): string
	return `{Number} {if Number == 1 then One else Many}`
end

-- Text in a colour, for a rich-text label
local function Tinted(Text: string, Color: Color3): string
	return `<font color="#{Color:ToHex()}">{Text}</font>`
end

-- A player's card's second line in your lobby: how their round goes, or how the last one went (rich text)
local function StateLine(Row: any, Lobby: any): string
	local Result, Member = Row.Result, Row.Member

	if Result then
		local Status = Result.Status

		if Status == "PASSED" then
			return Tinted("Passed", LiveGreen)
		elseif Status == "FAILED" then
			return Tinted("Failed", Grey)
		elseif Status == "LEFT" then
			return Tinted("Left the round", Dim)
		elseif Status == "DISQUALIFIED" then
			return Tinted("Disqualified", Dim)
		end

		return Tinted("Out of the round", Dim)
	end

	if not Member then
		return ""
	end

	if Lobby.State ~= "Open" then
		if not Member.InRound then
			return Tinted("Plays in the next round", Grey)
		end

		local State = Member.State

		if State == "Loading" then
			return Tinted("Getting ready", LiveAmber)
		elseif State == "Playing" then
			return Tinted("Playing", LiveRed)
		elseif State == "Passed" then
			return Tinted("Passed", LiveGreen)
		elseif State == "Failed" then
			return Tinted("Failed", Grey)
		end

		return Tinted("Out of the round", Dim)
	end

	return Tinted(if Lobby.Results then "Joined after the last round" else "Ready", Color3.fromRGB(200, 200, 200))
end

-- A player's score, accuracy (%) and misses on their card: the last round's after it, the live ones through it, none
-- before their first
local function NumbersOf(Row: any, Lobby: any): (number?, number?, number?)
	local Result, Member = Row.Result, Row.Member

	if Result then
		local Score, Misses = tonumber(Result.Score) or 0, tonumber(Result.Misses) or 0

		-- (none for someone who never got to a note: their song never started, or they left before the first one)
		if Score == 0 and Misses == 0 then
			return nil, nil, nil
		end

		return Score, tonumber(Result.Acc) or 100, Misses
	elseif Member and Member.InRound and Lobby.State ~= "Open" then
		return Member.Score, Member.Accuracy, Member.Misses
	end

	return nil, nil, nil
end

-- The board's line under the title: Play's (length, difficulty in its colour, mappers), or the map folder's when this
-- client's list doesn't have the map
local function SubOf(Entry: any): string
	if Entry.Map then
		return ExtraOf(Entry.Map)
	end

	local Text = `<font color="#{Entry.Color:ToHex()}">{Escape(Entry.Difficulty)}</font>`

	return if Entry.Mappers ~= "" then `{Text} <font color="#808080">by</font> <font color="#B0B0B0">{Escape(Entry.Mappers)}</font>` else Text
end

-- A card's song line: the title, then the difficulty in its colour
local function SongLine(Entry: any): string
	local Title = Escape(Entry.Title)

	if Entry.Difficulty == "" then
		return Title
	end

	return `{Title}<font color="#808080">{Dot}</font><font color="#{Entry.Color:ToHex()}">{Escape(Entry.Difficulty)}</font>`
end

-- A card's speed, its start when the round starts later, and modifiers
local function DetailOf(Entry: any): string
	local Speed = string.format("%.2fx", Entry.Speed)

	if (Entry.StartFrom or 0) > 0 then
		Speed ..= Dot .. "from " .. StartFromLogic.TimeText(Entry.StartFrom)
	end

	return if Entry.Mods ~= "" then Speed .. Dot .. ModsRich(Entry.Mods) else Speed
end

-- Who the Handheld is watching now, if anyone
local function WatchingNow(): Player?
	local Watching = Module.Hooks.Watching

	if not Watching then
		return nil
	end

	local Asked, Who = pcall(Watching)

	return if Asked and typeof(Who) == "Instance" then Who else nil
end

-- Brings the main menu to this tab at once (the Handheld: on hosting from Play's VS, and back from a round's song or from
-- watching someone in it). Nothing when the main menu isn't the scene shown, or the tab isn't mounted (or isn't this menu's).
function Module.Show()
	local Section = Module.Section
	local Scene = SceneManager.Scene

	if not Section or not Scene or Scene.Path ~= MenuPath or not Scene.State then
		return
	end

	if Nodes.GetNodeOrNull(Scene.Item, "Menus/Versus") ~= Section then
		return
	end

	MainMenu.Transition(Scene.State :: any, Section, true)
end

-- Whether this tab is on screen now: the main menu is up, on it (not behind a song, nor on another tab)
function Module.IsShown(): boolean
	return Module.Section ~= nil and not Nodes.HiddenInTree(Module.Section)
end

-- Fills the scene's Menus/Versus panel. Once.
function Module.Mount(Section: any)
	if Module.Section then
		return
	end

	local Host = Section.Instance :: GuiObject

	-- Everything on the page fades with the tab by its own transparencies: no CanvasGroup (one redraws its whole picture when
	-- anything inside moves, and Roblox drops its resolution when busy, which blurs it). Each faded property keeps its own
	-- resting value (Base), and the page's alpha scales it.
	local Fades = {}
	local FadesDirty = true

	local function Fade(Object: Instance, Property: string, Base: number)
		local Entry = { Object = Object, Property = Property, Base = Base }

		table.insert(Fades, Entry)

		return Entry
	end

	local function Rest(Entry, Base: number)
		if Entry.Base ~= Base then
			Entry.Base = Base
			FadesDirty = true
		end
	end

	-- the picked lobby (or yours) and its song, on the left (Play's song panel's place)
	local Board = Make("Frame", Host, {
		Name = "Board",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0.05, 8, 0, 128),
		Size = UDim2.new(0.4, -8, 1, -208),
		ZIndex = 2,
		Visible = false,
	})
	local Person = Box(Board, { Name = "Player", Size = UDim2.new(1, 0, 0, 112) })
	local BigAvatar = Make("ImageLabel", Person, {
		BackgroundColor3 = White,
		BackgroundTransparency = 0.94,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(16, 16),
		Size = UDim2.fromOffset(80, 80),
	})

	Make("UICorner", BigAvatar, { CornerRadius = UDim.new(0.5, 0) })

	-- (the name ends short of the badge at the top right)
	local PlayerName = Label(Person, {
		FontFace = FontOf("Ubuntu", Enum.FontWeight.Medium),
		TextSize = 28,
		Position = UDim2.fromOffset(112, 18),
		Size = UDim2.new(1, -290, 0, 34),
	})
	local UserName = Label(Person, { TextColor3 = Grey, Position = UDim2.fromOffset(112, 52), Size = UDim2.new(1, -128, 0, 22) })
	local WatchingText = Label(Person, { TextColor3 = Dim, TextSize = 16, Position = UDim2.fromOffset(112, 78), Size = UDim2.new(1, -128, 0, 20) })

	-- the lobby's badge at the top right (OPEN, STARTING, IN A ROUND or FULL), its dot beating as a round starts and on
	local Live = Make("Frame", Person, {
		Name = "Live",
		BackgroundColor3 = LiveRed,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 18),
		Size = UDim2.fromOffset(92, 30),
	})
	local LiveDot = Make("Frame", Live, {
		BackgroundColor3 = LiveRed,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(10, 10),
	})
	local LiveText = Label(Live, {
		FontFace = FontOf("Roboto", Enum.FontWeight.Bold),
		TextSize = 15,
		Position = UDim2.fromOffset(30, 0),
		Size = UDim2.new(1, -38, 1, 0),
		Text = "OPEN",
	})

	Make("UICorner", Live, { CornerRadius = UDim.new(0.5, 0) })
	Make("UICorner", LiveDot, { CornerRadius = UDim.new(0.5, 0) })
	local Header = Box(Board, { Name = "Song", Position = UDim2.fromOffset(0, 120), Size = UDim2.new(1, 0, 0, 132) })
	local Cover = Make("ImageLabel", Header, {
		BackgroundColor3 = White,
		BackgroundTransparency = 0.95,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(14, 14),
		Size = UDim2.fromOffset(104, 104),
		ScaleType = Enum.ScaleType.Crop,
	})

	Make("UICorner", Cover, { CornerRadius = UDim.new(0, 4) })

	-- (two lines, centred on the cover)
	local Words = Make("Frame", Header, { BackgroundTransparency = 1, Position = UDim2.fromOffset(134, 32), Size = UDim2.new(1, -150, 1, -32) })
	local Title = Label(Words, { FontFace = FontOf("Roboto", Enum.FontWeight.Medium), TextSize = 30, Size = UDim2.new(1, 0, 0, 38) })
	local Sub = Label(Words, { FontFace = FontOf("Roboto", Enum.FontWeight.Medium), TextColor3 = Grey, RichText = true, Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 24) })
	local Strip = Make("Frame", Header, { BackgroundColor3 = Accent, BorderSizePixel = 0, Size = UDim2.new(0, 4, 1, 0) })
	local Stats = Box(Board, { Name = "Stats", Position = UDim2.fromOffset(0, 260), Size = UDim2.new(1, 0, 0, 102) })

	-- a column of the stats: its value and its caption
	local function Stat(Caption: string, X: UDim, Width: UDim): (TextLabel, TextLabel)
		local Heading = Label(Stats, {
			TextColor3 = Dim,
			TextSize = 14,
			Text = Caption,
			Position = UDim2.new(X, UDim.new(0, 16)),
			Size = UDim2.new(Width, UDim.new(0, 18)),
		})
		local Value = Label(Stats, {
			FontFace = FontOf("Ubuntu", Enum.FontWeight.Medium),
			TextSize = 24,
			RichText = true,
			Position = UDim2.new(X, UDim.new(0, 36)),
			Size = UDim2.new(Width, UDim.new(0, 30)),
		})

		Fade(Heading, "TextTransparency", 0)
		Fade(Value, "TextTransparency", 0)

		return Value, Heading
	end

	local SpeedValue = Stat("SPEED", UDim.new(0, 16), UDim.new(0.18, -16))
	local ModsValue = Stat("MODS", UDim.new(0.2, 0), UDim.new(0.28, 0))
	-- (where the round starts in the song; the host sets it between rounds in the box over it, or on the bar under the stats)
	local StartValue = Stat("START", UDim.new(0.5, 0), UDim.new(0.18, 0))
	local TimeValue, TimeCaption = Stat("TIME", UDim.new(0.7, 0), UDim.new(0.3, -16))
	local StartBox = Make("TextBox", Stats, {
		Name = "StartBox",
		FontFace = FontOf("Ubuntu", Enum.FontWeight.Medium),
		TextSize = 24,
		TextColor3 = White,
		TextTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		PlaceholderText = "0:00",
		PlaceholderColor3 = Grey,
		ClearTextOnFocus = false,
		Text = "",
		BackgroundColor3 = Black,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, -8, 0, 35),
		Size = UDim2.fromOffset(StartBoxWidth, StartBoxHeight),
		Visible = false,
		ZIndex = 3,
	})
	local StartBoxEdge = Make("UIStroke", StartBox, { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Thickness = 2, Color = Accent, Transparency = 1 })

	Make("UICorner", StartBox, { CornerRadius = UDim.new(0, 4) })
	Make("UIPadding", StartBox, { PaddingLeft = UDim.new(0, 8) })
	local BoardTrack = Make("Frame", Stats, {
		BackgroundColor3 = White,
		BackgroundTransparency = 0.88,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(16, 80),
		Size = UDim2.new(1, -32, 0, 6),
		ClipsDescendants = true,
	})
	local BoardBar = Make("Frame", BoardTrack, { BackgroundColor3 = White, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1) })

	Make("UICorner", BoardTrack, { CornerRadius = UDim.new(0, 3) })
	Make("UICorner", BoardBar, { CornerRadius = UDim.new(0, 3) })

	-- the host's slider on the bar (between rounds): a press anywhere along it, then a drag; the knob shows where the start is
	local StartGrab = Make("TextButton", Stats, {
		Name = "StartGrab",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(8, 68),
		Size = UDim2.new(1, -16, 0, 30),
		Visible = false,
		ZIndex = 3,
	})
	local StartKnob = Make("Frame", Stats, {
		Name = "StartKnob",
		BackgroundColor3 = KnobColor,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(16, 83),
		Size = UDim2.fromOffset(KnobSide, KnobSide),
		Visible = false,
		ZIndex = 4,
	})

	Make("UICorner", StartKnob, { CornerRadius = UDim.new(0.5, 0) })
	Fade(StartKnob, "BackgroundTransparency", 0)

	-- the row under the stats: out of a lobby who's in the picked one (their names, and their faces at the right); in one,
	-- how it goes (STATUS)
	local LobbyRow = Box(Board, { Name = "Lobby", Position = UDim2.fromOffset(0, 370), Size = UDim2.new(1, 0, 0, 78) })
	local RowCaption = Label(LobbyRow, { TextColor3 = Dim, TextSize = 14, Text = "IN THIS LOBBY", Position = UDim2.fromOffset(16, 14), Size = UDim2.new(1, -32, 0, 18) })
	local RowText = Label(LobbyRow, {
		FontFace = FontOf("Ubuntu", Enum.FontWeight.Medium),
		TextSize = 22,
		RichText = true,
		Position = UDim2.fromOffset(16, 35),
		Size = UDim2.new(1, -32, 0, 30),
	})
	local FaceRow = Make("Frame", LobbyRow, {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, 0),
		Size = UDim2.fromOffset(Faces * 40, 40),
	})
	local FaceDots = {}

	Make("UIListLayout", FaceRow, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})

	for Index = 1, Faces do
		local Face = Make("ImageLabel", FaceRow, {
			BackgroundColor3 = White,
			BackgroundTransparency = 0.94,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(34, 34),
			LayoutOrder = Index,
			Visible = false,
		})

		Make("UICorner", Face, { CornerRadius = UDim.new(0.5, 0) })
		FaceDots[Index] = { Face = Face, Edge = Make("UIStroke", Face, { Thickness = 1, Color = White, Transparency = 1 }) }
	end

	-- The pill (JOIN, START, the count, WATCH): in the song cover's colours (CoverTheme), as the round PLAY AGAIN after a
	-- fail is: a deep shade inside a light ring, a slow light running round the ring, and under the mouse the full colour, a
	-- touch bigger and soft rings going out. Its edges, ring and words land on whole screen pixels (SnapWatch).
	local WatchRipple = Make("Frame", Board, {
		Name = "WatchRipple",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 2,
	})
	local RippleRing = Make("UIStroke", WatchRipple, { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Transparency = 1 })
	local WatchButton = Make("TextButton", Board, {
		Name = "Watch",
		Text = "JOIN",
		FontFace = FontOf("Roboto", Enum.FontWeight.Bold),
		TextSize = 28,
		TextColor3 = White,
		TextTransparency = 1,
		BackgroundColor3 = Black,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 3,
	})
	local WatchRing = Make("UIStroke", WatchButton, { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = White, Transparency = 1 })
	-- (one side of the ring a little brighter than the other: turned slowly, a light seems to run round it)
	local WatchSheen = Make("UIGradient", WatchRing, {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(0.5, 0.25),
			NumberSequenceKeypoint.new(1, 0),
		}),
	})

	Make("UICorner", WatchRipple, { CornerRadius = UDim.new(0.5, 0) })
	Make("UICorner", WatchButton, { CornerRadius = UDim.new(0.5, 0) })

	-- (two lines: the Handheld's reasons can be long)
	local Toast = Label(Board, {
		TextColor3 = Grey,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Position = UDim2.fromOffset(0, WatchTopAlone + WatchHeight + 12),
		Size = UDim2.new(1, 0, 0, 40),
	})

	-- LEAVE LOBBY, under the pill while you're in one: a small box of the page's own, lit under the mouse as a card is
	local LeaveButton = Make("TextButton", Board, {
		Name = "Leave",
		Text = "LEAVE LOBBY",
		FontFace = FontOf("Roboto", Enum.FontWeight.Bold),
		TextSize = 18,
		TextColor3 = White,
		TextTransparency = 1,
		BackgroundColor3 = Black,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, WatchTopWithSkin + WatchHeight + LeaveGap),
		Size = UDim2.fromOffset(LeaveWidth, LeaveHeight),
		Visible = false,
		ZIndex = 3,
	})
	local LeaveOutline = Make("UIStroke", LeaveButton, { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Thickness = 2, Color = White, Transparency = 1 })

	Make("UICorner", LeaveButton, { CornerRadius = UDim.new(0, 4) })

	-- CHANGE SONG, the host's, left of LEAVE LOBBY while the lobby is open: the same box
	local ChangeButton = Make("TextButton", Board, {
		Name = "ChangeSong",
		Text = "CHANGE SONG",
		FontFace = FontOf("Roboto", Enum.FontWeight.Bold),
		TextSize = 18,
		TextColor3 = White,
		TextTransparency = 1,
		BackgroundColor3 = Black,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, -(LeaveWidth + PairGap) / 2, 0, WatchTopWithSkin + WatchHeight + LeaveGap),
		Size = UDim2.fromOffset(LeaveWidth, LeaveHeight),
		Visible = false,
		ZIndex = 3,
	})
	local ChangeOutline = Make("UIStroke", ChangeButton, { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Thickness = 2, Color = White, Transparency = 1 })

	Make("UICorner", ChangeButton, { CornerRadius = UDim.new(0, 4) })

	-- no lobbies (or yours not read yet): a line in the middle of the page instead (the line under the pill shows under it too)
	local EmptyPage = Make("Frame", Host, {
		Name = "Empty",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(1000, 128),
		Visible = false,
		ZIndex = 2,
	})
	local EmptyTitle = Label(EmptyPage, {
		FontFace = FontOf("Roboto", Enum.FontWeight.Medium),
		TextSize = 32,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 44),
		Text = "No VS lobbies right now",
	})
	local EmptySub = Label(EmptyPage, {
		TextColor3 = Grey,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 52),
		Size = UDim2.new(1, 0, 0, 24),
		Text = "Pick a song in Play, then press VS next to START to host one.",
	})
	local EmptyNote = Label(EmptyPage, {
		TextColor3 = Grey,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Position = UDim2.fromOffset(0, 88),
		Size = UDim2.new(1, 0, 0, 40),
	})

	Fade(Person, "BackgroundTransparency", PanelTransparency)
	Fade(BigAvatar, "ImageTransparency", 0)
	Fade(BigAvatar, "BackgroundTransparency", 0.94)
	Fade(PlayerName, "TextTransparency", 0)
	Fade(UserName, "TextTransparency", 0)
	Fade(WatchingText, "TextTransparency", 0)
	Fade(Header, "BackgroundTransparency", PanelTransparency)
	Fade(Cover, "ImageTransparency", 0)

	local CoverBack = Fade(Cover, "BackgroundTransparency", 0.95)

	Fade(Title, "TextTransparency", 0)
	Fade(Sub, "TextTransparency", 0)
	Fade(Strip, "BackgroundTransparency", 0)
	Fade(Stats, "BackgroundTransparency", PanelTransparency)
	Fade(BoardTrack, "BackgroundTransparency", 0.88)
	Fade(BoardBar, "BackgroundTransparency", 0)
	Fade(Live, "BackgroundTransparency", 0.84)
	Fade(LiveText, "TextTransparency", 0)
	Fade(LobbyRow, "BackgroundTransparency", PanelTransparency)
	Fade(RowCaption, "TextTransparency", 0)
	Fade(RowText, "TextTransparency", 0)

	for _, Face in FaceDots do
		Fade(Face.Face, "ImageTransparency", 0)
		Fade(Face.Face, "BackgroundTransparency", 0.94)
		Fade(Face.Edge, "Transparency", 0.7)
	end

	Fade(Toast, "TextTransparency", 0)
	Fade(EmptyTitle, "TextTransparency", 0)
	Fade(EmptySub, "TextTransparency", 0)
	Fade(EmptyNote, "TextTransparency", 0)

	-- the lobbies, or your lobby's players, on the right (Play's list's place and look)
	local Picker = Make("Frame", Host, {
		Name = "Players",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 0, 128),
		Size = UDim2.new(0.5, -8, 1, -208),
		ZIndex = 2,
	})
	-- (the cards scroll inside a mask; the square sits outside it, as Play's does, so it shows left of a card that sticks out)
	local Mask = Make("Frame", Picker, { Name = "Mask", BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ClipsDescendants = true })
	local Square = Make("ImageLabel", Picker, {
		Name = "SelectionCursor",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(SquareSide, SquareSide),
		ImageColor3 = Accent,
		ImageTransparency = 1,
		ZIndex = 5,
	})

	pcall(function()
		Square.ImageContent = Images.GetContent("res://user/skins/default/ui/play/maplist_selection_cursor.png")
	end)

	-- the scroll bar, as Play's list draws its own: 12 layout pixels wide at the list's right edge, where the cards stop
	-- short, a track and a thumb of the skin's scroll bar pictures (round ends, a stretched middle). It shows only while the
	-- list is longer than its room; the thumb's length is the seen share of the list and it follows the scroll.
	local BarCap = 12
	local Bar = Make("TextButton", Picker, {
		Name = "ScrollBar",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 12, 1, 0),
		Visible = false,
		ZIndex = 4,
	})
	local BarThumb = Make("Frame", Bar, { Name = "Main", BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true, Size = UDim2.new(1, 0, 0, 0), ZIndex = 5 })
	local BarPieces: { ImageLabel } = {}

	local function BarPicture(Parent: Instance, Name: string, Picture: string, Position: UDim2, Size: UDim2, ZIndex: number)
		local Piece = Make("ImageLabel", Parent, {
			Name = Name,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = Position,
			Size = Size,
			ImageTransparency = 1,
			ZIndex = ZIndex,
		})

		pcall(function()
			Piece.ImageContent = Images.GetContent(`res://user/skins/default/ui/play/{Picture}.png`)
		end)

		table.insert(BarPieces, Piece)
	end

	BarPicture(Bar, "Top", "scrollbar_background_top", UDim2.new(), UDim2.new(1, 0, 0, BarCap), 4)
	BarPicture(Bar, "Middle", "scrollbar_background_middle", UDim2.fromOffset(0, BarCap), UDim2.new(1, 0, 1, -2 * BarCap), 4)
	BarPicture(Bar, "Bottom", "scrollbar_background_bottom", UDim2.new(0, 0, 1, -BarCap), UDim2.new(1, 0, 0, BarCap), 4)
	BarPicture(BarThumb, "Top", "scrollbar_top", UDim2.new(), UDim2.new(1, 0, 0, BarCap), 5)
	BarPicture(BarThumb, "Middle", "scrollbar_middle", UDim2.fromOffset(0, BarCap), UDim2.new(1, 0, 1, -2 * BarCap), 5)
	BarPicture(BarThumb, "Bottom", "scrollbar_bottom", UDim2.new(0, 0, 1, -BarCap), UDim2.new(1, 0, 0, BarCap), 5)

	-- (the thumb's top and length, the room the list scrolls and the bar's height, in layout pixels, for the drag)
	local BarTop, BarLength, BarRoom, BarHeight = 0, 0, 0, 0
	-- (the press dragging the thumb, where it started and the scroll it started from)
	local BarDrag: InputObject? = nil
	local BarFrom, BarScrollFrom = 0, 0

	-- State --------------------------------------------------------------------------------------------------------------
	local Cards: { [string]: any } = {} -- a card for each lobby ("L" and its id) or player in yours ("M" and their UserId)
	local Order: { any } = {} -- the cards listed now, top to bottom
	local Chosen: any = nil
	local LastHovered: any = nil
	local Dirty, BoardDirty = true, true
	local SeenVersion = -1 -- the Versus.Version last read (a change to any lobby or member since sets Dirty)
	local Mode = "" -- "Browse" out of a lobby, "Lobby" in one
	local Lobby: any = nil -- the board's lobby: the picked one, or yours (as Versus.Read last read it)
	local LobbySong: any = nil -- its song (SongOf)
	local Rows: { any } = {} -- your lobby's rows as listed (RowsOf)
	local Joining: string? = nil -- the lobby a JOIN is on its way to
	local StartAsked, LeaveAsked, WatchAsked = false, false, false -- a START, LEAVE LOBBY or WATCH on its way
	local KickAsked: number? = nil -- the UserId a KICK is on its way for (and their name, for the line once they're gone)
	local KickName = ""
	local KickArmed: number? = nil -- the card pressed once (it says SURE?), and when
	local KickArmedAt = 0
	-- the start: the bar's drag (the press, and the start it shows meanwhile), a start sent and not back yet (and when), the
	-- box under the mouse and its light, and whether the box's next focus loss changes nothing (the page went)
	local StartDrag: InputObject? = nil
	local StartDragMs: number? = nil
	local StartSent: number? = nil
	local StartSentAt = 0
	local StartBoxHovered, StartBoxMix = false, 0
	local StartBoxDrawn = { Mix = -1, Shade = -1, Focus = false }
	local StartCancel = false
	local AskToken = 0 -- (an ask's late answer changes nothing once a Notice, a Reset or another ask came after it)
	local WatchOff, WatchHovered = false, false
	local PillAction: string? = nil -- what the pill does now: "Join", "Start", "Watch", or nothing (PillOf)
	local Count = "" -- the count on the pill as your round starts: READY, 3, 2, 1 and GO, or ""
	local Busy: Player? = nil -- who the Handheld is watching (asked each tick)
	local NoticeKept = false -- a Notice came while the page wasn't up: its showing keeps it
	local BoardDrawn: { [string]: any } = {}
	local Swap = 1 -- 0 to 1: the board's lobby swap, eased in
	local Faded = -1
	local ListHovered = false
	local SquareX, SquareY, SquareAlpha = -80, 0, 0
	local SquareShown = false
	local Scroll, TargetScroll = 0, 0
	local WasShown = false
	local Ticked, Since = 0, 0
	-- the pill: under the mouse and held down (eased 0 to 1), the count's pop (1 as each number shows, eased to 0), where its
	-- top goes, its whole-pixel size at rest and the board size it was worked out against (SnapWatch), the pixels it grows
	-- by under the mouse, its colours by song and the ones it wears now (eased toward them), its rings going out, and what
	-- was last written
	local WatchHeld = false
	local WatchMix, WatchPress, Pop = 0, 0, 0
	local WatchTop = WatchTopWithSkin
	local WatchWide, WatchTall, WatchStep = 0, 0, 4
	local WatchBox = Vector2.zero
	local Themes: { [string]: Color3 | false } = {}
	local Want = CoverTheme.ButtonsOf(nil)
	local Worn = table.clone(Want)
	local Rippling: { Tween } = {}
	local WatchDrawn = { Mix = -1, Press = -1, Pop = -1, Shade = -1, Lit = -1 }
	local LiveState, LivePulse = "", -1
	-- LEAVE LOBBY: under the mouse, its light (eased 0 to 1), and what was last written
	local LeaveHovered, LeaveMix = false, 0
	local LeaveDrawn = { Mix = -1, Shade = -1 }
	-- CHANGE SONG: the same
	local ChangeHovered, ChangeMix = false, 0
	local ChangeDrawn = { Mix = -1, Shade = -1 }

	local function Paint(Card, Key: string, Object: Instance, Property: string, Value: any)
		if Card.Drawn[Key] ~= Value then
			Card.Drawn[Key] = Value;
			(Object :: any)[Property] = Value
		end
	end

	local function PaintBoard(Key: string, Object: Instance, Property: string, Value: any)
		if BoardDrawn[Key] ~= Value then
			BoardDrawn[Key] = Value;
			(Object :: any)[Property] = Value
		end
	end

	local function SetToast(Text: string)
		Put(Toast, "Text", Text)
		Put(EmptyNote, "Text", Text)
	end

	-- WATCH ------------------------------------------------------------------------------------------------------------------
	-- On whole screen pixels: an even width and height (so its middle is a pixel corner), its top where the board puts it and
	-- its ring a whole number of pixels, worked out against the menus' scale. As shares of the board: an offset is a whole
	-- layout pixel, which the scale makes a fraction of a screen one.
	local function SnapWatch()
		local Box = Board.AbsoluteSize

		if Box.X < 1 or Box.Y < 1 then
			return
		end

		local Factor = math.max(Scale.Current(), 0.05)
		local At = Board.AbsolutePosition
		local Wide = 2 * math.floor(Box.X / 2)
		local Tall = 2 * math.max(12, math.round(WatchHeight / 2 * Factor))
		local Left = math.round(At.X + (Box.X - Wide) / 2)
		local Top = math.round(At.Y + WatchTop * Factor)
		local Position = UDim2.fromScale((Left + Wide / 2 - At.X) / Box.X, (Top + Tall / 2 - At.Y) / Box.Y)
		local Extra = WatchStep * (WatchMix - WatchPress + 2 * Pop)

		WatchBox = Box
		WatchWide, WatchTall = Wide, Tall
		WatchStep = 2 * math.max(1, math.round(Tall * 0.04))
		WatchButton.Position = Position
		WatchButton.Size = UDim2.fromScale((Wide + Extra) / Box.X, (Tall + Extra) / Box.Y)
		WatchRipple.Position = Position

		if #Rippling == 0 then
			WatchRipple.Size = UDim2.fromScale(Wide / Box.X, Tall / Box.Y)
		end

		WatchRing.Thickness = math.max(2, math.round(2.5 * Factor)) / Factor
		RippleRing.Thickness = math.max(1, math.round(1.6 * Factor)) / Factor
	end

	local function StopRipple()
		for _, Playing in Rippling do
			Playing:Cancel()
		end

		table.clear(Rippling)
		RippleRing.Transparency = 1

		if WatchWide > 0 then
			WatchRipple.Size = UDim2.fromScale(WatchWide / WatchBox.X, WatchTall / WatchBox.Y)
		end
	end

	-- (a ring that spreads out from the edge and fades, again and again while the mouse is on it: run by the engine)
	local function StartRipple()
		StopRipple()

		if WatchWide <= 0 then
			return
		end

		local Loop = TweenInfo.new(RippleSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1)
		local Spread = 2 * math.max(6, math.round(WatchTall * 0.25))

		RippleRing.Transparency = 0.2
		table.insert(Rippling, TweenService:Create(RippleRing, Loop, { Transparency = 1 }))
		table.insert(Rippling, TweenService:Create(WatchRipple, Loop, {
			Size = UDim2.fromScale((WatchWide + Spread) / WatchBox.X, (WatchTall + Spread) / WatchBox.Y),
		}))

		for _, Playing in Rippling do
			Playing:Play()
		end
	end

	-- (a button is hit as its rectangle: only the pill counts, so the empty corners beside its ends neither light it nor
	-- watch. The mouse is read from the window's corner, the pill from below the top bar)
	local function OverWatch(): boolean
		local Mouse = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
		local At, Size = WatchButton.AbsolutePosition, WatchButton.AbsoluteSize
		local Radius = Size.Y / 2
		local Nearest = Vector2.new(math.clamp(Mouse.X, At.X + Radius, At.X + Size.X - Radius), At.Y + Radius)

		return (Mouse - Nearest).Magnitude <= Radius
	end

	local function TrackWatch()
		local Over = not Nodes.HiddenInTree(Section) and not AimiaInput.Blocked(WatchButton) and OverWatch()

		if Over == WatchHovered then
			return
		end

		WatchHovered = Over

		if not Over then
			WatchHeld = false
		end

		if Over and not WatchOff then
			StartRipple()
		else
			StopRipple()
		end
	end

	-- Board ------------------------------------------------------------------------------------------------------------------
	-- The lobby's badge: OPEN, STARTING, IN A ROUND or FULL, in its colour
	local function SetBadge(State: string)
		if State == LiveState then
			return
		end

		local Badge = Badges[State]

		LiveState = State
		LivePulse = -1
		Live.BackgroundColor3 = Badge.Color
		LiveDot.BackgroundColor3 = Badge.Color
		LiveText.Text = State
		Live.Size = UDim2.fromOffset(Badge.Width, 30)
	end

	-- (the badge's widths from its words', once they can be measured: the words and 50 more, as LIVE's 84 on Spectate)
	task.spawn(function()
		for State, Badge in Badges do
			local Measured, Size = pcall(function()
				local Params = Instance.new("GetTextBoundsParams")

				Params.Text = State
				Params.Font = FontOf("Roboto", Enum.FontWeight.Bold)
				Params.Size = 15
				Params.Width = 1000

				return TextService:GetTextBoundsAsync(Params)
			end)

			if Measured and typeof(Size) == "Vector2" and Size.X > 0 then
				Badge.Width = math.ceil(Size.X) + 50
			end
		end

		LiveState = ""
		BoardDirty = true
	end)

	-- whether this device plays songs (phones and tablets only watch)
	local function CanPlay(): boolean
		local Hook = Module.Hooks.CanPlay

		if not Hook then
			return true
		end

		local Asked, Can = pcall(Hook)

		return not Asked or Can ~= false
	end

	-- your row in your lobby, or nil
	local function MyRow(): any?
		for _, Row in Rows do
			if Row.Member and Row.Member.Me then
				return Row
			end
		end

		return nil
	end

	-- Who WATCH watches in your lobby's round: the picked player when they can be watched, else the best placed one still
	-- playing (never you)
	local function WatchTarget(): Player?
		local Member = Chosen and Chosen.Row and Chosen.Row.Member

		if Member and Member.Watchable and not Member.Me then
			return Member.Player
		end

		return Versus.Leader()
	end

	-- what the pill says, and what it does when pressed (nil: nothing, and it's dimmed)
	local function PillOf(): (string, string?)
		if Mode == "Browse" then
			if not Lobby then
				return "JOIN", nil
			elseif Joining then
				return "JOINING", nil
			elseif Lobby.Count >= Versus.MaxPlayers then
				return "FULL", nil
			end

			return "JOIN", if CanPlay() then "Join" else nil
		end

		if LeaveAsked then
			return "LEAVING", nil
		end

		local Mine = MyRow()
		local Member = Mine and Mine.Member
		local InRound = Member ~= nil and Member.InRound

		if Lobby.State == "Starting" then
			return if InRound and Count ~= "" then Count else "STARTING", nil
		elseif Lobby.State == "Playing" then
			if InRound and (Member.State == "Loading" or Member.State == "Playing") then
				return "PLAYING", nil
			elseif WatchAsked then
				return "JOINING", nil
			elseif WatchTarget() then
				return "WATCH", if Busy then nil else "Watch"
			end

			return "IN A ROUND", nil
		elseif not Versus.IsHost(Lobby) then
			return "WAITING", nil
		elseif StartAsked then
			return "STARTING", nil
		elseif Lobby.Count < 2 then
			return "NEED 2 PLAYERS", nil
		end

		-- (Play's START: the start time in brackets when the round starts later)
		return StartFromLogic.ButtonText(Lobby.StartFrom, StartFromLogic.TimeText(Lobby.StartFrom)), "Start"
	end

	-- the lobby's row, in a lobby: how it goes now (rich text)
	local function StatusOf(): string
		local Mine = MyRow()
		local Member = Mine and Mine.Member
		local InRound = Member ~= nil and Member.InRound
		local Hosting = Versus.IsHost(Lobby)

		if Lobby.State == "Starting" then
			return if InRound then "Get ready: the song starts after the count." else "A round is starting. You'll play in the next one."
		elseif Lobby.State == "Playing" then
			if not InRound then
				return "A round is on. You'll play in the next one."
			elseif Member.State == "Passed" then
				return `{Tinted("You passed!", LiveGreen)} Waiting for everyone to finish.`
			elseif Member.State == "Failed" then
				return "You failed this one. Watch the others finish."
			elseif Member.State == "Out" then
				return "You're out of this round."
			end

			return "You're playing."
		end

		-- (between rounds: who won the last one, then who starts the next)
		local Next = if not Hosting then `Waiting for {Escape(Lobby.HostDisplay)} to start the round.`
			elseif Lobby.Count < 2 then "Waiting for someone to join (VS is 2 to 5 players)."
			else "Press START when everyone's in."

		-- (a round that starts later says so: like a later start alone, it won't count for the Leaderboards)
		if Lobby.StartFrom > 0 then
			Next = `Starts at {StartFromLogic.TimeText(Lobby.StartFrom)}: won't count for Leaderboards.`
		end
		local Top = Lobby.Results and Lobby.Results[1]

		if type(Top) == "table" and (Top.Status == "PASSED" or Top.Status == "FAILED") then
			local Who = if Top.Id == Players.LocalPlayer.UserId then "You win" else `{Escape(tostring(Top.Display))} wins`

			-- (the winner alone, so a long name still fits on the line at any Menu Scale: the pill under it says what's next)
			return `{Tinted(Who, LiveAmber)} with {Commas(tonumber(Top.Score) or 0)}!`
		end

		return Next
	end

	-- whether you set the start now: the host, in your lobby while it's open, its song's length known
	local function SetsStart(): boolean
		return Mode == "Lobby" and Lobby ~= nil and LobbySong ~= nil and Versus.IsHost(Lobby) and Lobby.State == "Open"
			and LobbySong.Length > 0 and not StartAsked and not LeaveAsked
	end

	-- the start the board shows: the bar's while it's dragged, one sent until the server has it (2 s at most), else the lobby's
	local function StartShown(): number
		if StartDragMs then
			return StartDragMs
		elseif StartSent and Lobby and Lobby.StartFrom ~= StartSent and os.clock() - StartSentAt < 2 then
			return StartSent
		end

		return if Lobby then Lobby.StartFrom else 0
	end

	-- the third stat: PLAYERS between rounds, the round's TIME (and its bar) through one; START, the box over it and the knob
	-- for the host between rounds, and the bar at the start until the round's song begins (each tick, and as the bar is dragged)
	local function DrawRoundTime()
		if not Lobby or not LobbySong then
			return
		end

		local Ms = RoundMs(Lobby)
		local Length = LobbySong.Length
		local Start = StartShown()
		local At = if Ms then Ms elseif Lobby.State ~= "Playing" then Start else nil
		local Fraction = if At and Length > 0 then math.floor(math.clamp(At / Length, 0, 1) * 400 + 0.5) / 400 else 0
		local Setting = SetsStart()
		local StartText = StartFromLogic.TimeText(Start)

		PaintBoard("TimeCaption", TimeCaption, "Text", if Ms then "TIME" else "PLAYERS")
		PaintBoard("TimeValue", TimeValue, "Text", if Ms then RoundText(Ms, Length) else `{Lobby.Count} / {Versus.MaxPlayers}`)
		PaintBoard("Fraction", BoardBar, "Size", UDim2.fromScale(Fraction, 1))
		PaintBoard("StartValue", StartValue, "Text", StartText)
		PaintBoard("StartValueShown", StartValue, "Visible", not Setting)
		PaintBoard("StartBoxShown", StartBox, "Visible", Setting)
		PaintBoard("StartGrabShown", StartGrab, "Visible", Setting)
		PaintBoard("StartKnobShown", StartKnob, "Visible", Setting)
		PaintBoard("StartKnob", StartKnob, "Position", UDim2.new(Fraction, 16 - 32 * Fraction, 0, 83))

		-- (what the host is typing stays as it is)
		if not StartBox:IsFocused() then
			PaintBoard("StartBoxText", StartBox, "Text", StartText)
		end
	end

	-- The board for the picked lobby, or yours, written only where it changed.
	local function DrawBoard()
		if not Lobby or not LobbySong then
			return
		end

		local Entry = LobbySong
		local InLobby = Mode == "Lobby"

		PaintBoard("Avatar", BigAvatar, "Image", `rbxthumb://type=AvatarHeadShot&id={Lobby.Host}&w=150&h=150`)
		PaintBoard("PlayerName", PlayerName, "Text", Lobby.HostDisplay)
		PaintBoard("UserName", UserName, "Text", "@" .. Lobby.HostName)
		PaintBoard("Watching", WatchingText, "Text", `Host{Dot}{Lobby.Count} of {Versus.MaxPlayers} players`)
		PaintBoard("Title", Title, "Text", Entry.Title)
		PaintBoard("Sub", Sub, "Text", SubOf(Entry))
		PaintBoard("Strip", Strip, "BackgroundColor3", Entry.Color)
		PaintBoard("Bar", BoardBar, "BackgroundColor3", Entry.Color)
		PaintBoard("Speed", SpeedValue, "Text", string.format("%.2fx", Entry.Speed))
		PaintBoard("Mods", ModsValue, "Text", if Entry.Mods ~= "" then ModsRich(Entry.Mods) else "None")
		SetBadge(if Lobby.State == "Starting" then "STARTING" elseif Lobby.State == "Playing" then "IN A ROUND"
			elseif Lobby.Count >= Versus.MaxPlayers and not InLobby then "FULL" else "OPEN")
		DrawRoundTime()

		-- the row under the stats: who's in the picked lobby (their names, and their faces), or how yours goes
		local FaceCount = 0

		if InLobby then
			PaintBoard("RowCaption", RowCaption, "Text", "STATUS")
			PaintBoard("RowSize", RowText, "TextSize", 20)
			PaintBoard("RowText", RowText, "Text", StatusOf())
		else
			local Names = {}

			for _, Id in Lobby.Members do
				local Who = Players:GetPlayerByUserId(Id)

				if Who then
					table.insert(Names, Escape(Who.DisplayName))
				end
			end

			FaceCount = math.min(#Lobby.Members, #FaceDots)
			PaintBoard("RowCaption", RowCaption, "Text", "IN THIS LOBBY")
			PaintBoard("RowSize", RowText, "TextSize", 22)
			PaintBoard("RowText", RowText, "Text", table.concat(Names, ", "))
		end

		for Index, Face in FaceDots do
			local Id = Lobby.Members[Index]
			local Shown = Index <= FaceCount and Id ~= nil

			PaintBoard("FaceShown" .. Index, Face.Face, "Visible", Shown)

			if Shown then
				PaintBoard("Face" .. Index, Face.Face, "Image", `rbxthumb://type=AvatarHeadShot&id={Id}&w=150&h=150`)
			end
		end

		-- (the names stop short of the faces)
		local Room = if FaceCount > 0 then FaceCount * 34 + (FaceCount - 1) * 6 + 16 else 0

		PaintBoard("RowWidth", RowText, "Size", UDim2.new(1, -32 - Room, 0, 30))

		-- the pill, and LEAVE LOBBY under it in a lobby (the line under them goes under both)
		local Text, Action = PillOf()

		PillAction = Action
		PaintBoard("Watch", WatchButton, "Text", Text)
		PaintBoard("WatchSize", WatchButton, "TextSize", if tonumber(Text) or Text == "GO" then 36 else 28)
		-- (the host's CHANGE SONG while the lobby is open: it and LEAVE LOBBY side by side)
		local CanChange = InLobby and Versus.IsHost(Lobby) and Lobby.State == "Open"

		PaintBoard("Leave", LeaveButton, "Visible", InLobby)
		PaintBoard("Change", ChangeButton, "Visible", CanChange)
		PaintBoard("LeaveSide", LeaveButton, "Position", UDim2.new(0.5, if CanChange then (LeaveWidth + PairGap) / 2 else 0, 0, WatchTopWithSkin + WatchHeight + LeaveGap))
		PaintBoard("Toast", Toast, "Position", UDim2.fromOffset(0, WatchTop + WatchHeight + (if InLobby then LeaveGap + LeaveHeight + 12 else 12)))

		-- the pill's colours: the song cover's (worked out once for each song)
		local ThemeKey = Entry.Song

		if Themes[ThemeKey] == nil then
			Themes[ThemeKey] = (Entry.Folder and CoverTheme.OfThumb(Entry.Folder:GetAttribute("Cover"))) or false
		end

		Want = CoverTheme.ButtonsOf(Themes[ThemeKey] or nil)

		-- (the cover only when the song or its row changes)
		local CoverKey = Entry.Map or Entry.Song

		if BoardDrawn.Cover ~= CoverKey then
			local Picture = (Entry.Map and CoverOf(Entry.Map)) or ThumbOf(Entry.MapID)

			BoardDrawn.Cover = CoverKey
			Cover.ImageContent = Picture or Content.none
			Rest(CoverBack, if Picture then 1 else 0.95)
		end

		-- the pill is off while it has nothing to do (or no Handheld to watch through)
		WatchOff = Action == nil or (Action == "Watch" and Module.Hooks.Watch == nil)

		if WatchOff then
			StopRipple()
		elseif WatchHovered and #Rippling == 0 then
			StartRipple()
		end
	end

	local function Choose(Card: any, ByHand: boolean?)
		if Chosen == Card then
			return
		end

		local First = Chosen == nil

		Chosen = Card

		-- (a pick by hand clears the line under the pill; one made for you keeps it)
		if ByHand then
			SetToast("")
		end

		-- out of a lobby the board is the picked one's (it drops in from a little below, as Play's song panel does); in one
		-- it's yours, and the pick is who WATCH watches
		if Mode == "Browse" then
			Lobby = Card and Card.Lobby
			LobbySong = Card and Card.Entry

			if not First and Card then
				Swap = 0
			end
		end

		DrawBoard()
	end

	-- JOIN: the picked lobby. JOINING shows until you're in it, the server says why not (a Notice), or JoinWait s pass.
	local function JoinPicked()
		local Picked = Chosen and Chosen.Lobby

		if Mode ~= "Browse" or not Picked or Joining then
			return
		end

		if not CanPlay() then
			SetToast(TouchLine)

			return
		end

		if Picked.Count >= Versus.MaxPlayers then
			SetToast("That lobby is full.")

			return
		end

		AskToken += 1

		local Mine = AskToken

		Joining = Picked.Id
		SetToast(`Joining {Picked.HostDisplay}'s lobby`)
		Versus.Join(Picked.Id)
		BoardDirty = true

		task.delay(JoinWait, function()
			if Mine == AskToken and Joining then
				Joining = nil
				SetToast("Couldn't join that lobby. Try again.")
				BoardDirty = true
			end
		end)
	end

	-- START (the host's): the round starts on everyone's games after the count
	local function StartRound()
		if Mode ~= "Lobby" or not Lobby or not Versus.IsHost(Lobby) or Lobby.State ~= "Open" or StartAsked then
			return
		end

		if Lobby.Count < 2 then
			SetToast("VS needs at least 2 players. Wait for someone to join.")

			return
		end

		AskToken += 1

		local Mine = AskToken

		StartAsked = true
		SetToast("")
		Versus.StartRound()
		BoardDirty = true

		task.delay(JoinWait, function()
			if Mine == AskToken and StartAsked then
				StartAsked = false
				BoardDirty = true
			end
		end)
	end

	-- WATCH: someone still playing your lobby's round (WatchTarget), through the Handheld. A slow or late answer changes
	-- nothing once a Notice, a Reset or another ask came after it.
	local function WatchSomeone()
		local Watch = Module.Hooks.Watch
		local Target = WatchTarget()

		if Mode ~= "Lobby" or not Watch or not Target or WatchAsked then
			return
		end

		if WatchingNow() then
			SetToast("You're already spectating someone.")

			return
		end

		AskToken += 1

		local Mine = AskToken

		WatchAsked = true
		SetToast(`Joining {Target.DisplayName}`)
		BoardDirty = true

		task.spawn(function()
			local Asked, Started, Why = pcall(Watch, Target)

			if Mine == AskToken and not (Asked and Started) then
				WatchAsked = false
				SetToast(if Asked and type(Why) == "string" and Why ~= "" then Why else "Couldn't start spectating.")
				BoardDirty = true
			end
		end)

		task.delay(JoinWait, function()
			if Mine == AskToken and WatchAsked then
				WatchAsked = false
				BoardDirty = true
			end
		end)
	end

	-- LEAVE LOBBY: back to the lobbies (anyone still in a round who leaves is counted out of it, by the server)
	local function LeaveLobby()
		if Mode ~= "Lobby" or LeaveAsked then
			return
		end

		AskToken += 1

		local Mine = AskToken

		LeaveAsked = true
		SetToast("")
		Versus.Leave()
		BoardDirty = true

		task.delay(JoinWait, function()
			if Mine == AskToken and LeaveAsked then
				LeaveAsked = false
				BoardDirty = true
			end
		end)
	end

	-- KICK (the host's, on someone else's card while the lobby is open): pressed once it says SURE? for KickConfirm s, pressed
	-- again it asks the server. Their card goes once they're out of the lobby, and the line under the pill says so.
	local function KickPlayer(Card: any)
		local Member = Card.Row and Card.Row.Member

		if Mode ~= "Lobby" or not Lobby or not Versus.IsHost(Lobby) or Lobby.State ~= "Open" or StartAsked or LeaveAsked or KickAsked
			or not Member or Member.Me then
			return
		end

		if KickArmed ~= Member.UserId or os.clock() - KickArmedAt > KickConfirm then
			KickArmed, KickArmedAt = Member.UserId, os.clock()

			return
		end

		-- (a double-click only arms it: SURE? has to be seen to be pressed)
		if os.clock() - KickArmedAt < 0.35 then
			return
		end

		AskToken += 1

		local Mine = AskToken

		KickArmed = nil
		KickAsked, KickName = Member.UserId, Member.Display
		SetToast("")
		Versus.Kick(Member.UserId)

		task.delay(JoinWait, function()
			if Mine == AskToken and KickAsked then
				KickAsked = nil
				SetToast("Couldn't kick that player. Try again.")
			end
		end)
	end

	-- A start from the box or the bar, sent when it changes the lobby's (the server keeps it within the song)
	local function SendStart(Ms: number)
		if not SetsStart() then
			return
		end

		local Start = math.max(0, math.floor(Ms + 0.5))
		-- (compared with what the server will hold: a start still on its way, else the lobby's)
		local Holding = if StartSent and os.clock() - StartSentAt < 2 then StartSent else Lobby.StartFrom

		if Start == Holding then
			if Start == Lobby.StartFrom then
				StartSent = nil
			end

			return
		end

		StartSent, StartSentAt = Start, os.clock()
		Versus.SetStart(Start)
	end

	-- CHANGE SONG: on to Play, where the host picks a song (and its speed and modifiers) and VS makes it this lobby's
	local function ChangeSong()
		local Scene = SceneManager.Scene

		if Mode ~= "Lobby" or not Scene or Scene.Path ~= MenuPath or not Scene.State then
			return
		end

		local Play = Nodes.GetNodeOrNull(Scene.Item, "Menus/Play")

		if Play then
			MainMenu.Transition(Scene.State :: any, Play)
		end
	end

	-- The pill pressed (or Enter): what it says. Dimmed, it does nothing (on a phone or iPad, JOIN says why).
	local function PillPressed()
		if PillAction == "Join" then
			JoinPicked()
		elseif PillAction == "Start" then
			StartRound()
		elseif PillAction == "Watch" and not WatchOff then
			WatchSomeone()
		elseif Mode == "Browse" and Lobby and not CanPlay() then
			SetToast(TouchLine)
		end
	end

	-- Cards ------------------------------------------------------------------------------------------------------------------
	local function NewCard(Key: string, UserId: number): any
		local Holder = Make("Frame", Mask, { Name = Key, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2, Visible = false })
		local Fill = Make("Frame", Holder, { BackgroundColor3 = Black, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) })
		local Art = Make("ImageLabel", Holder, {
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -3, 0.5, 0),
			Size = UDim2.new(0.75, -3, 1, -4),
			ScaleType = Enum.ScaleType.Crop,
		})
		-- (a shade under the time column, so it reads over the brightest part of the cover)
		local Shade = Make("Frame", Holder, {
			BackgroundColor3 = Black,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -3, 0.5, 0),
			Size = UDim2.new(0, 340, 1, -4),
			ZIndex = 2,
		})
		local Frame = Make("Frame", Holder, { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 3 })

		Make("UICorner", Shade, { CornerRadius = UDim.new(0, 4) })
		Make("UIGradient", Shade, {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 0.35),
				NumberSequenceKeypoint.new(1, 0.15),
			}),
		})
		local Outline = Make("UIStroke", Frame, { Thickness = 2, Color = White, Transparency = 1 })
		local Avatar = Make("ImageLabel", Holder, {
			BackgroundColor3 = White,
			BackgroundTransparency = 0.94,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 14, 0.5, -2),
			Size = UDim2.fromOffset(58, 58),
			Image = `rbxthumb://type=AvatarHeadShot&id={UserId}&w=150&h=150`,
			ZIndex = 3,
		})
		-- (the left side ends 320 short of the card's right edge, where the time column is)
		local Name = Label(Holder, {
			FontFace = FontOf("Roboto", Enum.FontWeight.Medium),
			TextSize = 24,
			RichText = true,
			Position = UDim2.fromOffset(86, 8),
			Size = UDim2.new(1, -320, 0, 34),
			Text = "",
			ZIndex = 3,
		})
		local Line = Make("Frame", Holder, { BackgroundColor3 = White, BorderSizePixel = 0, Position = UDim2.fromOffset(86, 45), Size = UDim2.new(1, -320, 0, 1), ZIndex = 3 })
		local Song = Label(Holder, {
			FontFace = FontOf("Roboto", Enum.FontWeight.Medium),
			TextSize = 19,
			RichText = true,
			Position = UDim2.fromOffset(86, 48),
			Size = UDim2.new(1, -320, 0, 28),
			ZIndex = 3,
		})
		local Time = Label(Holder, {
			FontFace = FontOf("Ubuntu", Enum.FontWeight.Medium),
			TextSize = 17,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -16, 0, 10),
			Size = UDim2.fromOffset(220, 22),
			ZIndex = 3,
		})
		local Detail = Label(Holder, {
			TextColor3 = Color3.fromRGB(205, 205, 205),
			TextSize = 15,
			RichText = true,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -16, 0, 34),
			Size = UDim2.fromOffset(220, 20),
			ZIndex = 3,
		})
		local Watchers = Label(Holder, {
			TextColor3 = Grey,
			TextSize = 14,
			RichText = true,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -16, 0, 56),
			Size = UDim2.fromOffset(220, 18),
			ZIndex = 3,
		})
		-- (the song's progress along the card's bottom, in its difficulty colour)
		local Track = Make("Frame", Holder, {
			BackgroundColor3 = White,
			BackgroundTransparency = 0.85,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 8, 1, -5),
			Size = UDim2.new(1, -16, 0, 3),
			ClipsDescendants = true,
			ZIndex = 3,
		})
		local Bar = Make("Frame", Track, { BackgroundColor3 = White, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = 3 })
		local Button = Make("TextButton", Holder, { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 4 })
		-- (KICK, the host's on someone else's card: LEAVE LOBBY's box, small, over the card's own button so a press on it doesn't
		-- pick the card)
		local Kick = Make("TextButton", Holder, {
			Name = "Kick",
			Text = "KICK",
			FontFace = FontOf("Roboto", Enum.FontWeight.Bold),
			TextSize = 15,
			TextColor3 = White,
			TextTransparency = 1,
			BackgroundColor3 = Black,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -KickRight, 0.5, -2),
			Size = UDim2.fromOffset(KickWidth, KickHeight),
			Visible = false,
			ZIndex = 5,
		})
		local KickEdge = Make("UIStroke", Kick, { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Thickness = 2, Color = White, Transparency = 1 })

		Make("UICorner", Kick, { CornerRadius = UDim.new(0, 4) })

		Make("UICorner", Fill, { CornerRadius = UDim.new(0, 5) })
		Make("UICorner", Frame, { CornerRadius = UDim.new(0, 4) })
		Make("UICorner", Art, { CornerRadius = UDim.new(0, 4) })
		Make("UICorner", Avatar, { CornerRadius = UDim.new(0.5, 0) })
		-- (Play's cover fade: clear at its left edge, 20% clear from just past halfway)
		Make("UIGradient", Art, {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.8 / 1.5, 0.2),
				NumberSequenceKeypoint.new(1, 0.2),
			}),
		})

		local Card = {
			Key = Key,
			UserId = UserId,
			Lobby = nil :: any, -- (a lobby's card) the lobby, as last read
			Entry = nil :: any, -- the song: the lobby's, or your lobby's (SongOf)
			Row = nil :: any, -- (a player's card) their row in your lobby: Member, Result, Place
			Y = nil :: number?, -- its top in the list, eased to its place (through a round the order changes with the scores)
			Holder = Holder,
			Fill = Fill,
			Art = Art,
			Shade = Shade,
			Outline = Outline,
			Avatar = Avatar,
			Name = Name,
			NameStroke = Make("UIStroke", Name, { Thickness = 0.5, Color = Black }),
			Line = Line,
			Song = Song,
			SongStroke = Make("UIStroke", Song, { Thickness = 0.5, Color = Black }),
			Time = Time,
			TimeStroke = Make("UIStroke", Time, { Thickness = 0.5, Color = Black }),
			Detail = Detail,
			DetailStroke = Make("UIStroke", Detail, { Thickness = 0.5, Color = Black }),
			Watchers = Watchers,
			WatchersStroke = Make("UIStroke", Watchers, { Thickness = 0.5, Color = Black }),
			Track = Track,
			Bar = Bar,
			Kick = Kick,
			KickEdge = KickEdge,
			KickHovered = false,
			KickMix = 0,
			Hovered = false,
			Height = CardHeight,
			Stick = 0,
			HoverMix = 0,
			OutlineFill = 0,
			Cover = 0.5,
			CoverKey = nil :: any,
			Fraction = 0, -- what the bar shows
			Left = nil :: number?,
			Middle = nil :: number?,
			Drawn = {} :: { [string]: any },
		}

		Button.MouseEnter:Connect(function()
			-- (under a pointer-only layer, the owner panel, the card still follows the pointer and shows no hover while that
			-- layer has it: Input.PointerTaken)
			if Nodes.HiddenInTree(Section) or (AimiaInput.Blocked(Button) and not AimiaInput.PointerTaken(Button)) then
				return
			end

			Card.Hovered = true
			LastHovered = Card
		end)
		Button.MouseLeave:Connect(function()
			Card.Hovered = false
		end)
		-- the first click picks a lobby or a player; a click on the picked one joins the lobby, or watches the player
		Button.Activated:Connect(function()
			if Nodes.HiddenInTree(Section) or AimiaInput.Blocked(Button) then
				return
			end

			if Chosen ~= Card then
				Choose(Card, true)
			elseif Card.Lobby then
				JoinPicked()
			elseif Card.Row and Card.Row.Member and Card.Row.Member.Watchable and not Card.Row.Member.Me then
				WatchSomeone()
			end
		end)

		Kick.MouseEnter:Connect(function()
			Card.KickHovered = not Nodes.HiddenInTree(Section) and not AimiaInput.Blocked(Kick)
		end)
		Kick.MouseLeave:Connect(function()
			Card.KickHovered = false
		end)
		Kick.Activated:Connect(function()
			if Nodes.HiddenInTree(Section) or AimiaInput.Blocked(Kick) or not Kick.Visible then
				return
			end

			KickPlayer(Card)
		end)

		return Card
	end

	-- A lobby's card: its state line and bar (the round's time while one is on), written when what they show changes
	local function DrawLobbyTime(Card: any)
		local Info, Entry = Card.Lobby, Card.Entry
		local Ms = RoundMs(Info)
		local Text

		if Info.State == "Starting" then
			Text = Tinted("Starting", LiveAmber)
		elseif Info.State == "Playing" then
			Text = Tinted("In a round", LiveRed) .. (if Ms then Dot .. RoundText(Ms, Entry.Length) else "")
		elseif Info.Count >= Versus.MaxPlayers then
			Text = Tinted("Full", Grey)
		else
			Text = Tinted("Open", LiveGreen)
		end

		local Fraction = if Ms and Entry.Length > 0 then math.floor(math.clamp(Ms / Entry.Length, 0, 1) * 400 + 0.5) / 400 else 0

		Paint(Card, "WatchersText", Card.Watchers, "Text", Text)
		Paint(Card, "Fraction", Card.Bar, "Size", UDim2.fromScale(Fraction, 1))
	end

	-- A player's bar along their card: the round's time while they play, full once they've passed, where it stopped for
	-- anyone who failed or went out
	local function DrawMemberBar(Card: any)
		local Row = Card.Row
		local Member, Result = Row.Member, Row.Result
		local Fraction = Card.Fraction

		if Result then
			Fraction = if Result.Status == "PASSED" then 1 else Fraction
		elseif Member and Member.InRound and Lobby and Lobby.State ~= "Open" then
			if Member.State == "Playing" then
				local Ms = RoundMs(Lobby)
				local Length = Card.Entry.Length

				Fraction = if Ms and Length > 0 then math.floor(math.clamp(Ms / Length, 0, 1) * 400 + 0.5) / 400 else 0
			elseif Member.State == "Passed" then
				Fraction = 1
			elseif Member.State == "Loading" then
				Fraction = 0
			end
		else
			Fraction = 0
		end

		Card.Fraction = Fraction
		Paint(Card, "Fraction", Card.Bar, "Size", UDim2.fromScale(Fraction, 1))
	end

	-- A lobby's card: its host, song, players and state (Paint skips what hasn't changed)
	local function SetLobbyCard(Card: any, Info: any)
		local Entry = SongOf(Info)
		local CoverKey = Entry.Map or Entry.Song

		Card.Lobby = Info
		Card.Entry = Entry
		Card.Row = nil

		if Card.CoverKey ~= CoverKey then
			Card.CoverKey = CoverKey
			Card.Art.ImageContent = (Entry.Map and CoverOf(Entry.Map)) or ThumbOf(Entry.MapID) or Content.none
		end

		Paint(Card, "NameText", Card.Name, "Text", `{Escape(Info.HostDisplay)}'s lobby <font size="16" color="#A0A0A0">@{Escape(Info.HostName)}</font>`)
		Paint(Card, "BarColor", Card.Bar, "BackgroundColor3", Entry.Color)
		Paint(Card, "SongText", Card.Song, "Text", SongLine(Entry))
		Paint(Card, "TimeText", Card.Time, "Text", `{Info.Count} / {Versus.MaxPlayers} players`)
		Paint(Card, "DetailText", Card.Detail, "Text", DetailOf(Entry))
		DrawLobbyTime(Card)
	end

	-- A player's card in your lobby: who they are, how their round goes, their numbers and their place (Paint skips what
	-- hasn't changed)
	local function SetMemberCard(Card: any, Row: any, Info: any, Entry: any)
		local Member, Result = Row.Member, Row.Result
		local Display = if Member then Member.Display elseif Result then tostring(Result.Display or "") else ""
		local Name = if Member then Member.Name elseif Result then tostring(Result.Name or "") else ""
		local CoverKey = Entry.Map or Entry.Song
		local Tags = ""

		if Row.UserId == Info.Host then
			Tags ..= `  <font size="14" color="#{Accent:ToHex()}"><b>HOST</b></font>`
		end

		if Row.UserId == Players.LocalPlayer.UserId then
			Tags ..= '  <font size="14" color="#A0A0A0"><b>YOU</b></font>'
		end

		Card.Lobby = nil
		Card.Entry = Entry
		Card.Row = Row

		-- (the round's song cover behind every player, as behind a lobby)
		if Card.CoverKey ~= CoverKey then
			Card.CoverKey = CoverKey
			Card.Art.ImageContent = (Entry.Map and CoverOf(Entry.Map)) or ThumbOf(Entry.MapID) or Content.none
		end

		local Score, Accuracy, Misses = NumbersOf(Row, Info)
		local Numbers = if Score then `{string.format("%.2f", Accuracy)}%{Dot}{Plural(Misses, "miss", "misses")}` else ""
		local Place = ""

		-- (their place: through the round as it stands, after it the last round's, its best the WINNER, in gold)
		if Row.Place then
			Place = if Result and Row.Place == 1 then Tinted("WINNER", LiveAmber) else `#{Row.Place}`
		end

		Paint(Card, "NameText", Card.Name, "Text", `{Escape(Display)} <font size="16" color="#A0A0A0">@{Escape(Name)}</font>{Tags}`)
		Paint(Card, "BarColor", Card.Bar, "BackgroundColor3", Entry.Color)
		Paint(Card, "SongText", Card.Song, "Text", StateLine(Row, Info))
		Paint(Card, "TimeText", Card.Time, "Text", if Score then Commas(Score) else "")
		Paint(Card, "DetailText", Card.Detail, "Text", Numbers)
		Paint(Card, "WatchersText", Card.Watchers, "Text", Place)
		DrawMemberBar(Card)
	end

	-- Your lobby's players as listed: through a round best first (Versus.Standings), after one by the last round's places
	-- (anyone gone since among them, anyone who came after below), else in the order they came
	local function RowsOf(Info: any): { any }
		local List = {}
		local Members = Versus.Members(Info)

		if Info.State ~= "Open" then
			local Place = 0

			for _, Member in Versus.Standings(Info) do
				local Counted = Member.InRound and Member.State ~= "Out"

				if Counted then
					Place += 1
				end

				table.insert(List, { Key = "M" .. Member.UserId, UserId = Member.UserId, Member = Member, Place = if Counted then Place else nil })
			end
		elseif Info.Results then
			local ById, Listed = {}, {}

			for _, Member in Members do
				ById[Member.UserId] = Member
			end

			for Index, Result in Info.Results do
				if type(Result) == "table" and type(Result.Id) == "number" and not Listed[Result.Id] then
					local Placed = Result.Status == "PASSED" or Result.Status == "FAILED"

					Listed[Result.Id] = true
					table.insert(List, { Key = "M" .. Result.Id, UserId = Result.Id, Member = ById[Result.Id], Result = Result, Place = if Placed then Index else nil })
				end
			end

			for _, Member in Members do
				if not Listed[Member.UserId] then
					table.insert(List, { Key = "M" .. Member.UserId, UserId = Member.UserId, Member = Member })
				end
			end
		else
			for _, Member in Members do
				table.insert(List, { Key = "M" .. Member.UserId, UserId = Member.UserId, Member = Member })
			end
		end

		return List
	end

	-- Reads the lobbies again: the page's mode (out of a lobby, or in one), the cards listed, their order and the pick.
	local function Refresh()
		Dirty = false

		local MyId = Versus.MyId()
		local Mine = if MyId then Versus.Get(MyId) else nil
		local Next = if MyId then "Lobby" else "Browse"

		-- (an ask on its way is over once its answer shows)
		if Joining and (MyId == Joining or not Versus.Get(Joining)) then
			if MyId ~= Joining then
				SetToast("That lobby is gone.")
			end

			Joining = nil
		end

		if LeaveAsked and not MyId then
			LeaveAsked = false
		end

		if StartAsked and not (Mine and Mine.State == "Open" and Versus.IsHost(Mine)) then
			StartAsked = false
		end

		-- (a KICK is over once its player is out of your lobby)
		if KickAsked and not (Mine and table.find(Mine.Members, KickAsked)) then
			if Mine then
				SetToast(`{KickName} was kicked from the lobby.`)
			end

			KickAsked = nil
		end

		if StartSent and Mine and Mine.StartFrom == StartSent then
			StartSent = nil
		end

		-- a new mode starts at the top, with nothing picked and no line from before (the board drops in)
		if Next ~= Mode then
			Mode = Next
			Chosen = nil
			LastHovered = nil
			Scroll, TargetScroll = 0, 0
			Swap = 0
			SetToast("")
		end

		-- (on a phone or iPad, the line under JOIN says why it's dimmed)
		if Mode == "Browse" and not CanPlay() then
			SetToast(TouchLine)
		end

		local Listed: { any } = {}
		local Hidden = 0

		if Mode == "Browse" then
			local IsHidden = Module.Hooks.IsHidden

			Rows = {}

			for _, Info in Versus.Lobbies() do
				local Hoster = Players:GetPlayerByUserId(Info.Host)
				local Hides = false

				if Hoster and IsHidden then
					local Asked, Answer = pcall(IsHidden, Hoster)

					Hides = Asked and Answer == true
				end

				if Hides then
					Hidden += 1
				else
					table.insert(Listed, { Key = "L" .. Info.Id, UserId = Info.Host, Lobby = Info })
				end
			end
		else
			Rows = if Mine then RowsOf(Mine) else {}
			Listed = Rows
			Lobby = Mine
			LobbySong = if Mine then SongOf(Mine) else nil
		end

		-- the cards: one for each row (made as it first shows), the rest gone
		local Wanted = {}

		for _, Row in Listed do
			Wanted[Row.Key] = true
		end

		for Key, Card in Cards do
			if not Wanted[Key] then
				Cards[Key] = nil

				if Chosen == Card then
					Chosen = nil
				end

				if LastHovered == Card then
					LastHovered = nil
				end

				Card.Holder:Destroy()
			end
		end

		table.clear(Order)

		for _, Row in Listed do
			local Card = Cards[Row.Key]

			if not Card then
				Card = NewCard(Row.Key, Row.UserId)
				Cards[Row.Key] = Card
			end

			if Row.Lobby then
				SetLobbyCard(Card, Row.Lobby)
			else
				SetMemberCard(Card, Row, Mine, LobbySong)
			end

			Paint(Card, "Visible", Card.Holder, "Visible", true)
			table.insert(Order, Card)
		end

		-- the pick stays while its card is listed; otherwise the first lobby (out of one), or your own card (in one)
		if Chosen == nil or not table.find(Order, Chosen) then
			local First = Order[1]

			for _, Card in Order do
				if Mode == "Lobby" and Card.UserId == Players.LocalPlayer.UserId then
					First = Card

					break
				end
			end

			Choose(First)
		end

		-- out of a lobby the board is the picked one's (as last read)
		if Mode == "Browse" then
			Lobby = Chosen and Chosen.Lobby
			LobbySong = Chosen and Chosen.Entry
		end

		local Empty = Lobby == nil

		if Empty then
			if Mode == "Lobby" then
				Put(EmptyTitle, "Text", "Joining the lobby\u{2026}")
				Put(EmptySub, "Text", "")
			elseif Hidden > 0 then
				Put(EmptyTitle, "Text", "No lobbies to show right now")
				Put(EmptySub, "Text", "Lobbies hosted by players you've hidden aren't listed here.")
			else
				Put(EmptyTitle, "Text", "No VS lobbies right now")
				Put(EmptySub, "Text", "Pick a song in Play, then press VS next to START to host one.")
			end
		end

		Put(EmptyPage, "Visible", Empty)
		Put(Board, "Visible", not Empty)
		BoardDirty = true
	end

	-- Every TickGap s while the page shows: the round's times and bars, and who the Handheld is watching.
	local function Tick()
		for _, Card in Order do
			if Card.Lobby then
				DrawLobbyTime(Card)
			elseif Card.Row then
				DrawMemberBar(Card)
			end
		end

		DrawRoundTime()

		local Watching = WatchingNow()

		if Watching ~= Busy then
			Busy = Watching
			BoardDirty = true
		end
	end

	-- Scrolls the list so a card is in view (a pick with the keys).
	local function Reveal(Card: any)
		local Top = ListTop

		for _, Other in Order do
			if Other == Card then
				break
			end

			Top += Other.Height + CardGap
		end

		local View = Picker.AbsoluteSize.Y / Scale.Current()
		local Bottom = Top + CardHeight + CardHover + CardChosen

		if Top - ListTop < TargetScroll then
			TargetScroll = Top - ListTop
		elseif Bottom + CardGap > TargetScroll + View then
			TargetScroll = Bottom + CardGap - View
		end
	end

	-- Input ------------------------------------------------------------------------------------------------------------------

	WatchButton.MouseEnter:Connect(TrackWatch)
	WatchButton.MouseMoved:Connect(TrackWatch)
	WatchButton.MouseLeave:Connect(function()
		WatchHovered, WatchHeld = false, false
		StopRipple()
	end)
	WatchButton.MouseButton1Down:Connect(function()
		if WatchHovered then
			WatchHeld = true
		end
	end)
	WatchButton.MouseButton1Up:Connect(function()
		WatchHeld = false
	end)
	WatchButton.Activated:Connect(function()
		if Nodes.HiddenInTree(Section) or AimiaInput.Blocked(WatchButton) or not OverWatch() then
			return
		end

		PillPressed()
	end)

	LeaveButton.MouseEnter:Connect(function()
		LeaveHovered = not Nodes.HiddenInTree(Section) and not AimiaInput.Blocked(LeaveButton)
	end)
	LeaveButton.MouseLeave:Connect(function()
		LeaveHovered = false
	end)
	LeaveButton.Activated:Connect(function()
		if Nodes.HiddenInTree(Section) or AimiaInput.Blocked(LeaveButton) then
			return
		end

		LeaveLobby()
	end)

	ChangeButton.MouseEnter:Connect(function()
		ChangeHovered = not Nodes.HiddenInTree(Section) and not AimiaInput.Blocked(ChangeButton)
	end)
	ChangeButton.MouseLeave:Connect(function()
		ChangeHovered = false
	end)
	ChangeButton.Activated:Connect(function()
		if Nodes.HiddenInTree(Section) or AimiaInput.Blocked(ChangeButton) or not ChangeButton.Visible then
			return
		end

		ChangeSong()
	end)

	-- The host's start box: everything picked when it's clicked, read on Enter or a click away (Play's start box: "m:ss",
	-- seconds, or a fraction under 1; leaving it as it was changes nothing), Escape puts it back.
	StartBox.MouseEnter:Connect(function()
		StartBoxHovered = not Nodes.HiddenInTree(Section) and not AimiaInput.Blocked(StartBox)
	end)
	StartBox.MouseLeave:Connect(function()
		StartBoxHovered = false
	end)
	StartBox.Focused:Connect(function()
		if Nodes.HiddenInTree(Section) or not SetsStart() then
			StartBox:ReleaseFocus()

			return
		end

		-- (typing replaces what is there: everything picked, again once the click that focused it has placed the caret)
		local function PickAll()
			if StartBox:IsFocused() then
				StartBox.SelectionStart = 1
				StartBox.CursorPosition = #StartBox.Text + 1
			end
		end

		PickAll()
		task.defer(PickAll)

		-- (and once the click that focused it is let go, if nothing was typed yet: the click places the caret after the focus)
		local Was = StartBox.Text
		local Let: RBXScriptConnection? = nil

		Let = StartBox.InputEnded:Connect(function(Input: InputObject)
			if Input.UserInputType == Enum.UserInputType.MouseButton1 then
				if StartBox.Text == Was then
					PickAll()
				end

				if Let then
					Let:Disconnect()
				end
			end
		end)

		task.delay(1, function()
			if Let then
				Let:Disconnect()
			end
		end)
	end)
	StartBox.FocusLost:Connect(function(_: boolean, Cause: InputObject?)
		local Typed = StartBox.Text

		-- (Escape lets go of the box changing nothing, as does the page going)
		if StartCancel or (Cause ~= nil and Cause.KeyCode == Enum.KeyCode.Escape) then
			StartCancel = false
		elseif SetsStart() and Typed ~= StartFromLogic.TimeText(StartShown()) then
			SendStart(StartFromLogic.ParseInput(Typed, LobbySong.Length))
		end

		BoardDirty = true
		StartBox.Text = StartFromLogic.TimeText(StartShown())
	end)
	UserInputService.InputBegan:Connect(function(Input: InputObject)
		if Input.KeyCode == Enum.KeyCode.Escape and StartBox:IsFocused() then
			StartCancel = true
			StartBox:ReleaseFocus()
		end
	end)

	-- The host's slider on the bar: the start under the pointer while it's held, sent when it's let go
	local function StartUnderPointer(): number
		local Width = math.max(1, Scale.SizeOf(BoardTrack).x)
		local Along = AimiaInput.GetGuiMousePosition().x - Scale.PositionOf(BoardTrack).x

		return math.clamp(Along / Width, 0, 1) * LobbySong.Length
	end

	StartGrab.InputBegan:Connect(function(Input: InputObject)
		if Input.UserInputType ~= Enum.UserInputType.MouseButton1 or not SetsStart() or Nodes.HiddenInTree(Section) or AimiaInput.Blocked(StartGrab) then
			return
		end

		StartDrag = Input
		StartDragMs = StartUnderPointer()
		DrawRoundTime()
	end)
	UserInputService.InputChanged:Connect(function(Input: InputObject)
		if StartDrag and Input.UserInputType == Enum.UserInputType.MouseMovement and SetsStart() then
			StartDragMs = StartUnderPointer()
			DrawRoundTime()
		end
	end)
	UserInputService.InputEnded:Connect(function(Input: InputObject)
		if StartDrag and (Input == StartDrag or Input.UserInputType == Enum.UserInputType.MouseButton1) then
			local Ms = StartDragMs

			StartDrag, StartDragMs = nil, nil

			if Ms then
				SendStart(Ms)
			end

			DrawRoundTime()
		end
	end)

	Board:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		task.defer(SnapWatch)
	end)
	Board:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
		task.defer(SnapWatch)
	end)

	Picker.MouseEnter:Connect(function()
		if not Nodes.HiddenInTree(Section) then
			ListHovered = true
		end
	end)
	Picker.MouseLeave:Connect(function()
		ListHovered = false
	end)

	UserInputService.InputChanged:Connect(function(Input: InputObject)
		if ListHovered and Input.UserInputType == Enum.UserInputType.MouseWheel and not Nodes.HiddenInTree(Section)
			and not AimiaInput.Blocked(Picker) then
			TargetScroll -= Input.Position.Z * 100
		end
	end)

	-- Dragging the scroll bar: with the mouse, a press on the thumb holds it where it was pressed and a press on the track
	-- brings the thumb's middle to the pointer first; with a finger, the thumb moves as far as the finger does.
	local function BarTravel(): number
		return math.max(1, BarHeight - BarLength)
	end

	Bar.InputBegan:Connect(function(Input: InputObject)
		if not Bar.Visible or BarRoom <= 0 or AimiaInput.Blocked(Bar) then
			return
		end

		if Input.UserInputType == Enum.UserInputType.MouseButton1 then
			local Pointer = AimiaInput.GetGuiMousePosition().y - Scale.PositionOf(Bar).y
			local Grab = if Pointer >= BarTop and Pointer <= BarTop + BarLength then Pointer - BarTop else BarLength / 2

			BarDrag = Input
			BarFrom = Pointer
			BarScrollFrom = math.clamp((Pointer - Grab) / BarTravel(), 0, 1) * BarRoom
			TargetScroll = BarScrollFrom
		elseif Input.UserInputType == Enum.UserInputType.Touch then
			BarDrag = Input
			BarFrom = Input.Position.Y / Scale.FactorOf(Bar)
			BarScrollFrom = TargetScroll
		end
	end)
	UserInputService.InputChanged:Connect(function(Input: InputObject)
		local Drag = BarDrag

		if not Drag then
			return
		end

		local Moved

		if Drag.UserInputType == Enum.UserInputType.MouseButton1 and Input.UserInputType == Enum.UserInputType.MouseMovement then
			Moved = AimiaInput.GetGuiMousePosition().y - Scale.PositionOf(Bar).y - BarFrom
		elseif Drag.UserInputType == Enum.UserInputType.Touch and Input == Drag then
			Moved = Input.Position.Y / Scale.FactorOf(Bar) - BarFrom
		else
			return
		end

		TargetScroll = math.clamp(BarScrollFrom + Moved / BarTravel() * BarRoom, 0, BarRoom)
	end)
	UserInputService.InputEnded:Connect(function(Input: InputObject)
		if BarDrag and (Input == BarDrag or Input.UserInputType == Enum.UserInputType.MouseButton1) then
			BarDrag = nil
		end
	end)

	-- Enter presses the pill (JOIN, START or WATCH); Up and Down pick the card above or below.
	AimiaInput.OnInput(function(Event: any, Processed: boolean)
		if Processed or Event.Class ~= "InputEventKey" or not Event.Pressed or Nodes.HiddenInTree(Section) then
			return
		end

		local Code = Event.Keycode

		if Code == AimiaInput.Key.Enter or Code == AimiaInput.Key.KpEnter then
			PillPressed()
		elseif (Code == AimiaInput.Key.Up or Code == AimiaInput.Key.Down) and #Order > 0 then
			local Index = table.find(Order, Chosen) or 0
			local Next = Order[math.clamp(Index + (if Code == AimiaInput.Key.Up then -1 else 1), 1, #Order)]

			if Next ~= Chosen then
				Choose(Next, true)
				Reveal(Next)
			end
		end
	end)

	-- Every frame the page shows ---------------------------------------------------------------------------------------------
	Nodes.OnFrame(function(Delta: number)
		local Shown = not Nodes.HiddenInTree(Section)

		-- each showing reads everyone again; the line under WATCH from before goes, unless a Notice came while it was away
		if Shown and not WasShown then
			Dirty = true
			Since = 0
			Ticked = TickGap

			if NoticeKept then
				NoticeKept = false
			else
				SetToast("")
			end

			if WatchAsked then
				WatchAsked = false
				BoardDirty = true
			end
		end

		-- (hidden: WATCH lets go of the mouse, and its rings stop)
		if WasShown and not Shown then
			WatchHovered, WatchHeld, LeaveHovered, ChangeHovered = false, false, false, false
			StopRipple()
			-- (and the start box lets go of the keys, changing nothing; a drag on the bar ends; no KICK stays armed)
			StartBoxHovered = false
			StartDrag, StartDragMs = nil, nil
			KickArmed = nil

			if StartBox:IsFocused() then
				StartCancel = true
				StartBox:ReleaseFocus()
			end

			for _, Card in Cards do
				Card.KickHovered = false
			end
		end

		WasShown = Shown

		if not Shown then
			return
		end

		Delta = math.min(Delta, 0.1)

		-- (and every few seconds while it shows: hiding someone with the player filter tells nobody)
		Since += Delta

		if Since >= Reread then
			Since = 0
			Dirty = true
		end

		-- (any lobby or member change: Versus.Version)
		if Versus.Version ~= SeenVersion then
			SeenVersion = Versus.Version
			Dirty = true
		end

		-- the count on the pill as your round starts: READY, then 3, 2, 1 and GO, each with a little pop
		local Counting = ""

		if Mode == "Lobby" and Lobby and Lobby.State == "Starting" then
			local Left = Lobby.StartAt - workspace:GetServerTimeNow()

			Counting = if Left > 3 then "READY" elseif Left > 0 then tostring(math.ceil(Left)) else "GO"
		end

		if Counting ~= Count then
			Count = Counting
			Pop = if Counting ~= "" and Counting ~= "READY" then 1 else Pop
			BoardDirty = true
		end

		if Dirty then
			Refresh()
		end

		if BoardDirty then
			BoardDirty = false
			DrawBoard()
		end

		Ticked += Delta

		if Ticked >= TickGap then
			Ticked = 0
			Tick()
		end

		local Alpha = Section.Modulate[4]
		local Factor = Scale.Current()
		local Width = Picker.AbsoluteSize.X / Factor
		local Height = Picker.AbsoluteSize.Y / Factor

		-- the board: the tab's fade and the swap together, written only when something moved
		Swap = Ease(Swap, 1, 1 / 0.12, Delta, 0.002)

		local Shade = Alpha * (1 - (1 - Swap) ^ 3)

		if Shade ~= Faded or FadesDirty then
			Faded = Shade
			FadesDirty = false

			for _, Entry in Fades do
				Put(Entry.Object, Entry.Property, 1 - (1 - Entry.Base) * Shade)
			end
		end

		-- WATCH: its colours eased toward the picked player's, the mouse (the full colour and a touch bigger under it, a touch
		-- smaller while held, by whole pixels), dimmed while it can't be pressed, the light round its ring
		local Moved = false

		for Key, To in Want do
			local From = (Worn :: any)[Key]

			if From ~= To then
				local Next = From:Lerp(To, math.min(1, Delta * 10))

				if math.abs(Next.R - To.R) + math.abs(Next.G - To.G) + math.abs(Next.B - To.B) < 0.004 then
					Next = To
				end

				(Worn :: any)[Key] = Next
				Moved = true
			end
		end

		WatchMix = Ease(WatchMix, if WatchHovered and not WatchOff then 1 else 0, 1 / 0.15, Delta, 0.01)
		WatchPress = Ease(WatchPress, if WatchHeld and WatchHovered and not WatchOff then 1 else 0, 1 / 0.08, Delta, 0.01)
		Pop = Ease(Pop, 0, 1 / 0.25, Delta, 0.01)

		-- (dimmed while it can't be pressed; the count can't be either, but it shows lit)
		local Lit = if WatchOff and Count == "" then 0.45 else 1

		if Moved or WatchMix ~= WatchDrawn.Mix or WatchPress ~= WatchDrawn.Press or Pop ~= WatchDrawn.Pop or Shade ~= WatchDrawn.Shade
			or Lit ~= WatchDrawn.Lit then
			local Resting = WatchRestTransparency + (WatchHoverTransparency - WatchRestTransparency) * WatchMix

			WatchDrawn.Mix, WatchDrawn.Press, WatchDrawn.Pop, WatchDrawn.Shade, WatchDrawn.Lit = WatchMix, WatchPress, Pop, Shade, Lit
			WatchButton.BackgroundColor3 = Worn.Fill:Lerp(Worn.HoverFill, WatchMix)
			WatchButton.BackgroundTransparency = 1 - (1 - Resting) * Shade * Lit
			WatchButton.TextTransparency = 1 - Shade * (if Lit < 1 then 0.55 else 1)
			WatchRing.Color = Worn.Ring:Lerp(Worn.Hover, WatchMix)
			WatchRing.Transparency = 1 - Shade * Lit
			RippleRing.Color = Worn.Hover

			if WatchWide > 0 then
				local Extra = WatchStep * (WatchMix - WatchPress + 2 * Pop)

				WatchButton.Size = UDim2.fromScale((WatchWide + Extra) / WatchBox.X, (WatchTall + Extra) / WatchBox.Y)
			end
		end

		-- (the sheen and the beat run on the frame clock, UI/Frames, so they step evenly)
		Put(WatchSheen, "Rotation", math.floor(Frames.Time % SheenSeconds / SheenSeconds * 3600) / 10)

		-- the badge's dot beats while a round starts (quickly) and while one is on (as LIVE's does on Spectate)
		local Period = if Badges[LiveState] then Badges[LiveState].Beat else 0
		local Beat = if Period > 0 then 0.35 + 0.65 * (0.5 + 0.5 * math.cos(Frames.Time * math.pi * 2 / Period)) else 1
		local DotShown = math.floor(Beat * Shade * 50 + 0.5) / 50

		if DotShown ~= LivePulse then
			LivePulse = DotShown
			LiveDot.BackgroundTransparency = 1 - DotShown
		end

		local Rise = math.floor(24 * (1 - Swap) ^ 3 + 0.5)

		Put(Board, "Position", UDim2.new(0.05, 8, 0, 128 + Rise))

		-- (while a pointer-only layer, the owner panel, has the pointer, the cards under it show no hover: Input.PointerTaken)
		local Taken = AimiaInput.PointerTaken(Picker)

		-- the cards: heights first, then their places (a grown card pushes the others apart evenly, as Play's do)
		local Total = ListTop

		for _, Card in Order do
			local Selected = Card == Chosen
			local Lit = Card.Hovered and not Taken

			Card.Height = Ease(Card.Height, CardHeight + (if Lit then CardHover else 0) + (if Selected then CardChosen else 0), 16, Delta, 0.05)
			Card.Stick = Ease(Card.Stick, if Selected then 0.05 else 0, 16, Delta, 0.0005)
			Card.HoverMix = Ease(Card.HoverMix, if Lit then 1 else 0, 1 / 0.15, Delta, 0.01)
			Card.OutlineFill = Ease(Card.OutlineFill, if Selected then 1 elseif Lit then 0.5 else 0, 10, Delta, 0.01)
			Card.Cover = Ease(Card.Cover, if Selected then 1 else 128 / 255, 1 / 0.1, Delta, 0.01)
			Total += Card.Height + CardGap
		end

		TargetScroll = math.clamp(TargetScroll, 0, math.max(0, Total - Height))
		Scroll = Ease(Scroll, TargetScroll, 12, Delta, 0.5)

		local Top = ListTop
		local Clear = 1 - Alpha
		-- (KICK on everyone else's card: the host's, while the lobby is open and nothing else is on its way)
		local Kicking = Mode == "Lobby" and Lobby ~= nil and Versus.IsHost(Lobby) and Lobby.State == "Open" and not StartAsked and not LeaveAsked

		if KickArmed and os.clock() - KickArmedAt > KickConfirm then
			KickArmed = nil
		end

		for _, Card in Order do
			-- (its place eased: through a round the order changes with the scores, and the cards slide past each other)
			Card.Y = if Card.Y then Ease(Card.Y, Top, 14, Delta, 0.2) else Top

			local At = Card.Y - Scroll
			local Middle = At + Card.Height / 2
			local Distance = math.abs(Middle - Height / 2) / (Height / 2 + CardHeight / 2)
			-- (places round to whole screen pixels, not layout pixels: under Menu Scale a layout pixel isn't one, and the slow end
			-- of each ease moved in uneven steps)
			local Left = math.floor(Width * (0.1 - math.cos(math.pi * math.min(Distance, 1) / 2) / 20 - Card.Stick) * Factor + 0.5) / Factor
			local Glow = Card.OutlineFill

			Paint(Card, "Position", Card.Holder, "Position", UDim2.fromOffset(Left, math.floor(At * Factor + 0.5) / Factor))
			Paint(Card, "Size", Card.Holder, "Size", UDim2.fromOffset(Width - 13 - Left, math.floor(Card.Height * Factor + 0.5) / Factor))
			Paint(Card, "Tint", Card.Fill, "BackgroundColor3", Black:Lerp(HoverTint, Card.HoverMix))
			Paint(Card, "Fill", Card.Fill, "BackgroundTransparency", 1 - (1 - PanelTransparency) * Alpha)
			Paint(Card, "Art", Card.Art, "ImageTransparency", 1 - Card.Cover * Alpha)
			Paint(Card, "Shade", Card.Shade, "BackgroundTransparency", 1 - 0.7 * Alpha)
			Paint(Card, "Outline", Card.Outline, "Transparency", 1 - (0.12 + 0.5 * Glow) * Alpha)
			Paint(Card, "OutlineColor", Card.Outline, "Color", White:Lerp(Accent, Card.HoverMix * (1 - math.max(0, Glow - 0.5) * 2)))
			Paint(Card, "Avatar", Card.Avatar, "ImageTransparency", Clear)
			Paint(Card, "AvatarBack", Card.Avatar, "BackgroundTransparency", 1 - 0.06 * Alpha)
			Paint(Card, "Name", Card.Name, "TextTransparency", Clear)
			Paint(Card, "NameStroke", Card.NameStroke, "Transparency", Clear)
			Paint(Card, "Line", Card.Line, "BackgroundTransparency", 1 - 0.2 * Alpha)
			Paint(Card, "Song", Card.Song, "TextTransparency", Clear)
			Paint(Card, "SongStroke", Card.SongStroke, "Transparency", Clear)
			Paint(Card, "Time", Card.Time, "TextTransparency", Clear)
			Paint(Card, "TimeStroke", Card.TimeStroke, "Transparency", Clear)
			Paint(Card, "Detail", Card.Detail, "TextTransparency", Clear)
			Paint(Card, "DetailStroke", Card.DetailStroke, "Transparency", Clear)
			Paint(Card, "Watchers", Card.Watchers, "TextTransparency", Clear)
			Paint(Card, "WatchersStroke", Card.WatchersStroke, "Transparency", Clear)
			Paint(Card, "Track", Card.Track, "BackgroundTransparency", 1 - 0.15 * Alpha)
			Paint(Card, "Bar", Card.Bar, "BackgroundTransparency", Clear)

			-- KICK: at the card's right edge, or left of its numbers when it shows some (the name and state lines then stop short of
			-- it); SURE? once pressed, dimmed while a kick is on its way
			local Member = Card.Row and Card.Row.Member
			local Kickable = Kicking and Member ~= nil and not Member.Me
			local Numbered = Kickable and Card.Time.Text ~= ""
			local TextRoom = if Numbered then -320 - KickRoom else -320

			Paint(Card, "KickShown", Card.Kick, "Visible", Kickable)
			Paint(Card, "NameSize", Card.Name, "Size", UDim2.new(1, TextRoom, 0, 34))
			Paint(Card, "LineSize", Card.Line, "Size", UDim2.new(1, TextRoom, 0, 1))
			Paint(Card, "SongSize", Card.Song, "Size", UDim2.new(1, TextRoom, 0, 28))

			if Kickable then
				local Armed = KickArmed == Card.UserId

				Card.KickMix = Ease(Card.KickMix, if Card.KickHovered and not KickAsked then 1 else 0, 1 / 0.15, Delta, 0.01)
				Paint(Card, "KickAt", Card.Kick, "Position", UDim2.new(1, -(if Numbered then KickRightNumbers else KickRight), 0.5, -2))
				Paint(Card, "KickWord", Card.Kick, "Text", if Armed then "SURE?" else "KICK")
				Paint(Card, "KickTint", Card.Kick, "BackgroundColor3", Black:Lerp(HoverTint, if Armed then 1 else Card.KickMix))
				Paint(Card, "KickFill", Card.Kick, "BackgroundTransparency", 1 - (1 - PanelTransparency) * Alpha)
				Paint(Card, "KickText", Card.Kick, "TextTransparency", 1 - Alpha * (if KickAsked then 0.55 else 1))
				Paint(Card, "KickEdgeColor", Card.KickEdge, "Color", White:Lerp(Accent, if Armed then 1 else Card.KickMix))
				Paint(Card, "KickEdge", Card.KickEdge, "Transparency", 1 - (if Armed then 0.62 else 0.12 + 0.5 * Card.KickMix) * Alpha)
			end

			Card.Left = Left
			Card.Middle = Middle
			Top += Card.Height + CardGap
		end

		-- the square, as Play's: it shows once the mouse is on a card, starts at that card's height, follows the last card the
		-- mouse was on (the gaps between cards don't move it), and fades out to the list's left edge when the mouse leaves
		local Pointing = ListHovered and not Taken
		local Followed = if Pointing then LastHovered else nil
		local OnCard = false

		for _, Card in Order do
			OnCard = OnCard or (Card.Hovered and not Taken)
		end

		if Followed and Followed.Middle and OnCard and not SquareShown then
			SquareShown = true
			SquareY = Followed.Middle - SquareSide / 2
		elseif not Pointing and SquareShown then
			SquareShown = false
		end

		local TargetX = if SquareShown and Followed and Followed.Left then Followed.Left - 60 else -80
		local TargetY = if Followed and Followed.Middle then Followed.Middle - SquareSide / 2 else SquareY

		SquareX = Ease(SquareX, TargetX, 8, Delta, 0.2)
		SquareY = Ease(SquareY, math.clamp(TargetY, 0, Height), 8, Delta, 0.2)
		SquareAlpha = Ease(SquareAlpha, if SquareShown then 1 else 0, 1 / 0.1, Delta, 0.01)

		Put(Square, "Position", UDim2.fromOffset(math.floor(SquareX * Factor + 0.5) / Factor, math.floor(SquareY * Factor + 0.5) / Factor))
		Put(Square, "Rotation", math.floor(math.deg(-SquareY / 60) * 10 + 0.5) / 10)
		Put(Square, "ImageTransparency", 1 - SquareAlpha * Alpha)

		-- the scroll bar: only while the list is longer than its room; the thumb's length is the seen share of the list and
		-- its top follows the scroll (the pointer's, while it is dragged), in whole screen pixels
		BarRoom = math.max(0, Total - Height)
		BarHeight = Height

		local Scrolls = BarRoom >= 1

		Put(Bar, "Visible", Scrolls and Alpha > 0)

		if Scrolls then
			local Seen = if BarDrag then TargetScroll else Scroll

			BarLength = math.min(Height, math.max(2 * BarCap, Height * Height / Total))
			BarTop = math.clamp(Seen / BarRoom, 0, 1) * (Height - BarLength)
			Put(BarThumb, "Position", UDim2.fromOffset(0, math.floor(BarTop * Factor + 0.5) / Factor))
			Put(BarThumb, "Size", UDim2.new(1, 0, 0, math.floor(BarLength * Factor + 0.5) / Factor))

			for _, Piece in BarPieces do
				Put(Piece, "ImageTransparency", 1 - Alpha)
			end
		else
			BarDrag = nil
		end
		PaintBoard("Picker", Picker, "Visible", Alpha > 0 and #Order > 0)

		-- LEAVE LOBBY: a box of the page's, the hover tint and an accent edge under the mouse
		LeaveMix = Ease(LeaveMix, if LeaveHovered and LeaveButton.Visible and not LeaveAsked then 1 else 0, 1 / 0.15, Delta, 0.01)

		if LeaveMix ~= LeaveDrawn.Mix or Shade ~= LeaveDrawn.Shade then
			LeaveDrawn.Mix, LeaveDrawn.Shade = LeaveMix, Shade
			LeaveButton.BackgroundColor3 = Black:Lerp(HoverTint, LeaveMix)
			LeaveButton.BackgroundTransparency = 1 - (1 - PanelTransparency) * Shade
			LeaveButton.TextTransparency = 1 - Shade
			LeaveOutline.Color = White:Lerp(Accent, LeaveMix)
			LeaveOutline.Transparency = 1 - (0.12 + 0.5 * LeaveMix) * Shade
		end

		-- CHANGE SONG: the same
		ChangeMix = Ease(ChangeMix, if ChangeHovered and ChangeButton.Visible then 1 else 0, 1 / 0.15, Delta, 0.01)

		if ChangeMix ~= ChangeDrawn.Mix or Shade ~= ChangeDrawn.Shade then
			ChangeDrawn.Mix, ChangeDrawn.Shade = ChangeMix, Shade
			ChangeButton.BackgroundColor3 = Black:Lerp(HoverTint, ChangeMix)
			ChangeButton.BackgroundTransparency = 1 - (1 - PanelTransparency) * Shade
			ChangeButton.TextTransparency = 1 - Shade
			ChangeOutline.Color = White:Lerp(Accent, ChangeMix)
			ChangeOutline.Transparency = 1 - (0.12 + 0.5 * ChangeMix) * Shade
		end

		-- the host's start box: the page's box, its accent edge brighter under the mouse and while typing
		local Focus = StartBox:IsFocused()

		StartBoxMix = Ease(StartBoxMix, if (StartBoxHovered or Focus) and StartBox.Visible then 1 else 0, 1 / 0.15, Delta, 0.01)

		if StartBoxMix ~= StartBoxDrawn.Mix or Shade ~= StartBoxDrawn.Shade or Focus ~= StartBoxDrawn.Focus then
			StartBoxDrawn.Mix, StartBoxDrawn.Shade, StartBoxDrawn.Focus = StartBoxMix, Shade, Focus
			StartBox.BackgroundColor3 = Black:Lerp(HoverTint, StartBoxMix)
			StartBox.BackgroundTransparency = 1 - (1 - PanelTransparency) * Shade
			StartBox.TextTransparency = 1 - Shade
			StartBoxEdge.Transparency = 1 - (0.45 + 0.45 * StartBoxMix) * Shade
		end
	end)

	Module.Reset = function()
		AskToken += 1
		Joining = nil
		StartAsked, LeaveAsked, WatchAsked = false, false, false
		KickAsked, KickArmed = nil, nil
		Chosen = nil
		Scroll, TargetScroll = 0, 0
		NoticeKept = false
		SetToast("")
		Dirty = true
		BoardDirty = true
	end

	Module.Notice = function(Text: string)
		AskToken += 1
		Joining = nil
		StartAsked, LeaveAsked, WatchAsked = false, false, false
		KickAsked, KickArmed = nil, nil
		-- (the page isn't up yet, as when the Handheld brings it back: its showing keeps the line)
		NoticeKept = not WasShown
		SetToast(if type(Text) == "string" then Text else "")
		BoardDirty = true
	end

	task.defer(SnapWatch)
	Module.Section = Section
end

return Module
