--!optimize 2

--[[
	The Spectate section of the main menu (fourth, after Leaderboards): the players in this server who are in a song right
	now, and watching one of them from here, however far away they are. The players on the right as Play lists songs; the
	picked player and their song on the left, with a WATCH button.

	Paradigm
		The section's panel (Menus/Spectate) comes from the scene data, so the top bar, the Home button and the tab fade are
		MainMenu's own. Its contents are plain Instances in layout pixels, made once by Mount and laid out and faded as
		LeaderboardsMenu's (its card numbers, curve, stick-out of the picked card, outline and turning square). A card shows
		what the player's attributes say, which the server keeps through their song (Server.Services.Players.AimiaSpectate:
		AimiaSong, AimiaSongMods, AimiaSongSpeed, AimiaSongClock, AimiaSongHeld, AimiaSongRestarting, AimiaSongWatchers).
		Watching is the Handheld's: it sets the Hooks and MaxWatchers, and calls Show, Notice and Reset.

	Design Notes
		Nothing is written while the page is still. An attribute change only sets a flag, and the list is read again on the
		next frame the page shows (and every 2 s while it shows, as the player filter tells nobody when it changes). The song
		times and bars are worked out 4 times a second and written only when the second shown or the bar's step changes.
		Every frame and input handler checks Nodes.HiddenInTree(Section): the cached menu keeps running behind a song, where
		its panel is still Visible.
		Yourself and anyone hidden with the player filter are never listed. A card stays a second after its song ends, so a
		restart (the server clears the attributes and sets them again) doesn't make it blink.
		Show requires SceneManager and Scenes/MainMenu. Neither of them loads this module (AimiaApp and the Handheld do, once
		the menu is up), so there is no require cycle; keep it so (nothing ScriptRegistry loads may require this one).
		No local is named Font or Content: either hides Roblox's own (Font.new, Content.none, Content.fromObject).
]]

local AssetService = game:GetService("AssetService")
local EncodingService = game:GetService("EncodingService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
local TextureValue = require("./Play/Textures")

local Module = {
	Hooks = {
		-- starts watching a listed player (the Handheld sets it): answers whether it started, and why not
		Watch = nil :: ((Player) -> (boolean, string?))?,
		-- whether a player is hidden with the player filter (the Handheld sets it): they aren't listed
		IsHidden = nil :: ((Player) -> boolean)?,
		-- who is being watched now, if anyone (the Handheld sets it): WATCH is off while it answers someone
		Watching = nil :: (() -> Player?)?,
	},
	MaxWatchers = 20, -- Config.AimiaSpectate.MaxWatchers (the Handheld sets it)
	Section = nil :: any, -- the Menus/Spectate item, once mounted
	Reset = nil :: (() -> ())?, -- set by Mount: the pick forgotten, the list at the top, no line under WATCH
	Notice = nil :: ((string) -> ())?, -- set by Mount: a line under WATCH (why watching stopped, or didn't start)
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

-- WATCH, in layout pixels: its height, and where its top goes with the skin row above it and without one. How see-through
-- its inside is at rest and under the mouse; how long the light takes round its ring and each ring under the mouse to spread.
local WatchHeight, WatchTopWithSkin, WatchTopAlone = 72, 456, 370
local WatchRestTransparency, WatchHoverTransparency = 0.18, 0.06
local SheenSeconds, RippleSeconds = 4.5, 1.1
local Swatches = 8 -- note colours shown at most

-- the LIVE badge's dot: red while they play, amber while they restart, grey while paused
local LiveRed = Color3.fromRGB(255, 59, 92)
local LiveAmber = Color3.fromRGB(255, 209, 102)
local LiveGrey = Color3.fromRGB(150, 150, 150)

local MenuPath = "res://scenes/main_menu.tscn"
-- the times are worked out every TickGap s; a card stays GoneGrace s after its song; JOINING shows at most JoinWait s; the
-- list is read again every Reread s while it shows
local TickGap, GoneGrace, JoinWait, Reread = 0.25, 1, 15, 2
local Dot = "  ·  "
local AutoplayText = '<font color="#FFD166">Autoplay</font>' -- (AimiaWatch's colour for it: nobody is playing that run by hand)

-- the player attributes a card is read from
local Watched = {
	AimiaSong = true,
	AimiaSongMods = true,
	AimiaSongSpeed = true,
	AimiaSongClock = true,
	AimiaSongHeld = true,
	AimiaSongRestarting = true,
	AimiaSongWatchers = true,
	AimiaSongLook = true,
}

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

-- A player's look as their attribute holds it ("Name;rrggbb,rrggbb": the background they play on and their note colours,
-- Server.Services.Players.AimiaSpectate's checkedLook): the name to show (a built-in background's capitalised) and the
-- colours. No name for a look that doesn't read so.
local function LookOf(Text: any): (string?, { Color3 })
	local Colors = {}

	if type(Text) ~= "string" then
		return nil, Colors
	end

	local Name, Hexes = string.match(Text, "^([^;]*);(.*)$")

	for Hex in string.gmatch(Hexes or "", "%x%x%x%x%x%x") do
		if #Colors < Swatches then
			table.insert(Colors, Color3.fromHex(Hex))
		end
	end

	if not Name or Name == "" then
		return nil, Colors
	end

	return (string.gsub(Name, "^%l", string.upper)), Colors
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

-- What a player's attributes say of their song now, or nil when they aren't listed: not in a song, yourself (never), or
-- hidden with the player filter (then true too, so the empty page can say why nobody shows).
local function Read(Who: Player): (any?, boolean?)
	local Song = Who:GetAttribute("AimiaSong")

	if type(Song) ~= "string" or Song == "" or Who == Players.LocalPlayer then
		return nil
	end

	local IsHidden = Module.Hooks.IsHidden

	if IsHidden then
		local Asked, Hidden = pcall(IsHidden, Who)

		if Asked and Hidden then
			return nil, true
		end
	end

	-- (the map folder's own attributes stand in for a map this client's list doesn't have)
	local Stock = ReplicatedStorage:FindFirstChild("AimiaContent")
	local Folders = Stock and Stock:FindFirstChild("Maps")
	local Folder = Folders and Folders:FindFirstChild(Song)
	local Named = Folder and Folder:GetAttribute("MapID")
	local MapID = if type(Named) == "string" and Named ~= "" then Named else (string.gsub(Song, "%.sspm$", ""))
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
	local Speed = Who:GetAttribute("AimiaSongSpeed")
	local Clock = Who:GetAttribute("AimiaSongClock")
	local Held = Who:GetAttribute("AimiaSongHeld")
	local Watchers = Who:GetAttribute("AimiaSongWatchers")
	local Look = Who:GetAttribute("AimiaSongLook")
	local Skin, SkinColors = LookOf(Look)

	return {
		Song = Song,
		MapID = MapID,
		Map = Map,
		Folder = Folder or (Folders and Folders:FindFirstChild(MapID .. ".sspm")), -- (its small cover gives WATCH a colour)
		Look = if type(Look) == "string" then Look else "",
		Skin = Skin, -- the background they play on, or nil when their game didn't say
		Colors = SkinColors, -- their note colours (at most Swatches)
		Title = if type(Title) == "string" and Title ~= "" then Title else MapID, -- Artist - Title
		Difficulty = if type(Difficulty) == "string" then Difficulty else "",
		Mappers = if type(Mappers) == "string" then Mappers else "",
		Color = Color,
		Length = if Map and Finite(Map.Length) then math.max(Map.Length, 0) else 0, -- ms, 0 when not known
		Mods = ModsText(Who:GetAttribute("AimiaSongMods")),
		Speed = if Finite(Speed) and Speed > 0 then math.clamp(Speed, 0.05, 10) else 1,
		Clock = if Finite(Clock) then Clock else nil, -- the server time at which the song's time was 0 (at this speed)
		Held = if Finite(Held) then Held else nil, -- the song's time while it's paused
		Restarting = Who:GetAttribute("AimiaSongRestarting") == true,
		Watchers = if Finite(Watchers) then math.max(0, math.floor(Watchers)) else 0,
	}
end

-- The time in a player's song now (ms of the map), or nil when it isn't known: a restart, or a server that doesn't say.
local function Elapsed(Entry: any, Now: number): number?
	if Entry.Restarting then
		return nil
	elseif Entry.Held then
		return Entry.Held
	elseif Entry.Clock then
		return (Now - Entry.Clock) * 1000 * Entry.Speed
	end

	return nil
end

-- "1:23 / 3:45", "Paused · 1:23 / 3:45" or "Restarting…"; only the length when the time isn't known, and only the time when
-- the length isn't (a map this client's list doesn't have). Short leaves "Paused" out (the board's TIME caption says it).
local function TimeText(Entry: any, Ms: number?, Short: boolean?): string
	if Entry.Restarting then
		return "Restarting…"
	end

	local Length = Entry.Length
	local Total = if Length > 0 then MapText.LengthText(Length) else ""

	if not Ms then
		return Total
	end

	local At = MapText.LengthText(math.clamp(Ms, 0, if Length > 0 then Length else math.max(Ms, 0)))
	local Text = if Total ~= "" then `{At} / {Total}` else At

	return if Entry.Held and not Short then `Paused · {Text}` else Text
end

-- Writes a time and its bar (a card's, or the board's View): the text only when the second it shows changes (or the
-- pause), the bar in 400 steps. A View is { Time, Bar, Caption?, Second, Held, Fraction }.
local function DrawTime(View: any, Entry: any, Now: number)
	local Ms = Elapsed(Entry, Now)
	local Length = Entry.Length
	local Second = if Entry.Restarting then -3 elseif not Ms then -1 else math.clamp(Ms, 0, if Length > 0 then Length else math.huge) // 1000
	local Held = Entry.Held ~= nil

	if Second ~= View.Second or Held ~= View.Held then
		View.Second = Second
		View.Held = Held
		Put(View.Time, "Text", TimeText(Entry, Ms, View.Caption ~= nil))

		if View.Caption then
			Put(View.Caption, "Text", if Held then "PAUSED" else "TIME")
		end
	end

	local Fraction = if Ms and Length > 0 then math.floor(math.clamp(Ms / Length, 0, 1) * 400 + 0.5) / 400 else 0

	if Fraction ~= View.Fraction then
		View.Fraction = Fraction
		View.Bar.Size = UDim2.fromScale(Fraction, 1)
	end
end

local function WatchingLine(Count: number): string
	return if Count <= 0 then "No one watching yet" elseif Count == 1 then "1 person watching" else `{Count} people watching`
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

-- A card's speed and modifiers
local function DetailOf(Entry: any): string
	local Speed = string.format("%.2fx", Entry.Speed)

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

-- Brings the main menu to this tab at once (the Handheld, back from watching someone). Nothing when the main menu isn't
-- the scene shown, or the tab isn't mounted (or isn't this menu's).
function Module.Show()
	local Section = Module.Section
	local Scene = SceneManager.Scene

	if not Section or not Scene or Scene.Path ~= MenuPath or not Scene.State then
		return
	end

	if Nodes.GetNodeOrNull(Scene.Item, "Menus/Spectate") ~= Section then
		return
	end

	MainMenu.Transition(Scene.State :: any, Section, true)
end

-- Fills the scene's Menus/Spectate panel. Once.
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

	-- the picked player and their song, on the left (Play's song panel's place)
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

	-- (the name ends short of the LIVE badge at the top right)
	local PlayerName = Label(Person, {
		FontFace = FontOf("Ubuntu", Enum.FontWeight.Medium),
		TextSize = 28,
		Position = UDim2.fromOffset(112, 18),
		Size = UDim2.new(1, -290, 0, 34),
	})
	local UserName = Label(Person, { TextColor3 = Grey, Position = UDim2.fromOffset(112, 52), Size = UDim2.new(1, -128, 0, 22) })
	local WatchingText = Label(Person, { TextColor3 = Dim, TextSize = 16, Position = UDim2.fromOffset(112, 78), Size = UDim2.new(1, -128, 0, 20) })

	-- LIVE, PAUSED or RESTARTING at the top right, its dot beating gently while they play
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
		Text = "LIVE",
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

	local SpeedValue = Stat("SPEED", UDim.new(0, 16), UDim.new(0.22, -16))
	local ModsValue = Stat("MODS", UDim.new(0.24, 0), UDim.new(0.34, 0))
	local TimeValue, TimeCaption = Stat("TIME", UDim.new(0.6, 0), UDim.new(0.4, -16))
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

	-- their skin: the background they play on, and their note colours as dots (when their game said, Read)
	local SkinBox = Box(Board, { Name = "Skin", Position = UDim2.fromOffset(0, 370), Size = UDim2.new(1, 0, 0, 78), Visible = false })
	local SkinCaption = Label(SkinBox, { TextColor3 = Dim, TextSize = 14, Text = "SKIN", Position = UDim2.fromOffset(16, 14), Size = UDim2.new(0.45, -16, 0, 18) })
	local SkinName = Label(SkinBox, {
		FontFace = FontOf("Ubuntu", Enum.FontWeight.Medium),
		TextSize = 24,
		Position = UDim2.fromOffset(16, 34),
		Size = UDim2.new(0.45, -16, 0, 30),
	})
	local ColorsCaption = Label(SkinBox, {
		TextColor3 = Dim,
		TextSize = 14,
		Text = "NOTE COLORS",
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 14),
		Size = UDim2.new(0.55, -16, 0, 18),
	})
	local SwatchRow = Make("Frame", SkinBox, {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 38),
		Size = UDim2.new(0.55, -16, 0, 22),
	})
	local SwatchDots = {}

	Make("UIListLayout", SwatchRow, {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})

	for Index = 1, Swatches do
		local Dot = Make("Frame", SwatchRow, {
			BackgroundColor3 = White,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(22, 22),
			LayoutOrder = Index,
			Visible = false,
		})

		Make("UICorner", Dot, { CornerRadius = UDim.new(0.5, 0) })
		SwatchDots[Index] = { Dot = Dot, Edge = Make("UIStroke", Dot, { Thickness = 1, Color = White, Transparency = 1 }) }
	end

	-- WATCH: a pill in the player's colours (their note colours, else the song cover's: CoverTheme), as the round PLAY AGAIN
	-- after a fail is: a deep shade inside a light ring, a slow light running round the ring, and under the mouse the full
	-- colour, a touch bigger and soft rings going out. Its edges, ring and words land on whole screen pixels (SnapWatch).
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
		Text = "WATCH",
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

	-- nobody in a song: a line in the middle of the page instead (the line under WATCH shows under it too)
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
		Text = "No one is playing a song right now",
	})
	local EmptySub = Label(EmptyPage, {
		TextColor3 = Grey,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 52),
		Size = UDim2.new(1, 0, 0, 24),
		Text = "When someone starts a song, they show up here.",
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
	Fade(SkinBox, "BackgroundTransparency", PanelTransparency)
	Fade(SkinCaption, "TextTransparency", 0)
	Fade(SkinName, "TextTransparency", 0)
	Fade(ColorsCaption, "TextTransparency", 0)

	for _, Swatch in SwatchDots do
		Fade(Swatch.Dot, "BackgroundTransparency", 0)
		Fade(Swatch.Edge, "Transparency", 0.7)
	end

	Fade(Toast, "TextTransparency", 0)
	Fade(EmptyTitle, "TextTransparency", 0)
	Fade(EmptySub, "TextTransparency", 0)
	Fade(EmptyNote, "TextTransparency", 0)

	-- the players, on the right (Play's list's place and look)
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
	local Cards: { [Player]: any } = {} -- a card for each player listed so far (kept for their next song until they leave)
	local Order: { any } = {} -- the cards listed now, top to bottom
	local Links: { [Player]: RBXScriptConnection } = {}
	local LeftGame = setmetatable({}, { __mode = "k" }) -- (players who left: GetPlayers can still answer them for a moment)
	local Chosen: any = nil
	local LastHovered: any = nil
	local Dirty, BoardDirty, Waiting = true, true, false
	local Joining, WatchOff, WatchHovered = false, false, false
	local Busy: Player? = nil -- who the Handheld is watching (asked each tick)
	local WatchToken = 0
	local NoticeKept = false -- a Notice came while the page wasn't up: its showing keeps it
	local BoardDrawn: { [string]: any } = {}
	local BoardTime = { Time = TimeValue, Bar = BoardBar, Caption = TimeCaption, Second = -2, Held = false, Fraction = 0, Card = nil :: any, Song = nil :: string? }
	local Swap = 1 -- 0 to 1: the board's player swap, eased in
	local Faded = -1
	local ListHovered = false
	local SquareX, SquareY, SquareAlpha = -80, 0, 0
	local SquareShown = false
	local Scroll, TargetScroll = 0, 0
	local WasShown = false
	local Ticked, Since = 0, 0
	-- WATCH: under the mouse and held down (eased 0 to 1), where its top goes now, its whole-pixel size at rest and the board
	-- size it was worked out against (SnapWatch), the pixels it grows by under the mouse, its colours by look and song, the
	-- picked player's colours and the ones it wears now (eased toward them), its rings going out, and what was last written
	local WatchHeld = false
	local WatchMix, WatchPress = 0, 0
	local WatchTop = WatchTopAlone
	local WatchWide, WatchTall, WatchStep = 0, 0, 4
	local WatchBox = Vector2.zero
	local Themes: { [string]: Color3 | false } = {}
	local Want = CoverTheme.ButtonsOf(nil)
	local Worn = table.clone(Want)
	local Rippling: { Tween } = {}
	local WatchDrawn = { Mix = -1, Press = -1, Shade = -1, Off = false }
	local LiveState, LivePulse = "", -1

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
		local Extra = WatchStep * (WatchMix - WatchPress)

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
	-- The board for the picked player, written only where it changed.
	local function DrawBoard()
		local Card = Chosen
		local Entry = Card and Card.Entry

		if not Entry then
			return
		end

		local Who = Card.Player :: Player
		local Full = Entry.Watchers >= Module.MaxWatchers

		PaintBoard("Avatar", BigAvatar, "Image", `rbxthumb://type=AvatarHeadShot&id={Who.UserId}&w=150&h=150`)
		PaintBoard("PlayerName", PlayerName, "Text", Who.DisplayName)
		PaintBoard("UserName", UserName, "Text", "@" .. Who.Name)
		PaintBoard("Watching", WatchingText, "Text", WatchingLine(Entry.Watchers))
		PaintBoard("Title", Title, "Text", Entry.Title)
		PaintBoard("Sub", Sub, "Text", SubOf(Entry))
		PaintBoard("Strip", Strip, "BackgroundColor3", Entry.Color)
		PaintBoard("Bar", BoardBar, "BackgroundColor3", Entry.Color)
		PaintBoard("Speed", SpeedValue, "Text", string.format("%.2fx", Entry.Speed))
		PaintBoard("Mods", ModsValue, "Text", if Entry.Mods ~= "" then ModsRich(Entry.Mods) else "None")
		PaintBoard("Watch", WatchButton, "Text", if Joining then "JOINING" elseif Full then "FULL" else "WATCH")

		-- LIVE, PAUSED or RESTARTING, in red, grey or amber
		local State = if Entry.Restarting then "RESTARTING" elseif Entry.Held then "PAUSED" else "LIVE"

		if State ~= LiveState then
			local Tint = if State == "RESTARTING" then LiveAmber elseif State == "PAUSED" then LiveGrey else LiveRed

			LiveState = State
			LivePulse = -1
			Live.BackgroundColor3 = Tint
			LiveDot.BackgroundColor3 = Tint
			LiveText.Text = State
			Live.Size = UDim2.fromOffset(if State == "RESTARTING" then 138 elseif State == "PAUSED" then 108 else 84, 30)
		end

		-- their skin: the row shows when their game said, and WATCH sits under it (or in its place)
		local HasSkin = Entry.Skin ~= nil or #Entry.Colors > 0

		PaintBoard("SkinShown", SkinBox, "Visible", HasSkin)
		PaintBoard("Skin", SkinName, "Text", Entry.Skin or "Unknown")
		PaintBoard("ColorsShown", ColorsCaption, "Visible", #Entry.Colors > 0)

		for Index, Swatch in SwatchDots do
			local Color = Entry.Colors[Index]

			PaintBoard("SwatchShown" .. Index, Swatch.Dot, "Visible", Color ~= nil)

			if Color then
				PaintBoard("Swatch" .. Index, Swatch.Dot, "BackgroundColor3", Color)
			end
		end

		local Top = if HasSkin then WatchTopWithSkin else WatchTopAlone

		if Top ~= WatchTop then
			WatchTop = Top
			Toast.Position = UDim2.fromOffset(0, WatchTop + WatchHeight + 12)
			SnapWatch()
		end

		-- WATCH's colour: their note colours' own, else the song cover's (worked out once for each look and song)
		local ThemeKey = Entry.Look .. "|" .. Entry.Song

		if Themes[ThemeKey] == nil then
			local Theme = CoverTheme.OfColors(Entry.Colors)

			if not Theme and Entry.Folder then
				Theme = CoverTheme.OfThumb(Entry.Folder:GetAttribute("Cover"))
			end

			Themes[ThemeKey] = Theme or false
		end

		Want = CoverTheme.ButtonsOf(Themes[ThemeKey] or nil)

		-- (the cover only when the song or its row changes: two players can be in the same song)
		local CoverKey = Entry.Map or Entry.Song

		if BoardDrawn.Cover ~= CoverKey then
			local Picture = (Entry.Map and CoverOf(Entry.Map)) or ThumbOf(Entry.MapID)

			BoardDrawn.Cover = CoverKey
			Cover.ImageContent = Picture or Content.none
			Rest(CoverBack, if Picture then 1 else 0.95)
		end

		-- WATCH is off while joining, when they're full, while you watch someone, or with no Handheld to watch through
		WatchOff = Joining or Full or Busy ~= nil or Module.Hooks.Watch == nil

		if WatchOff then
			StopRipple()
		elseif WatchHovered and #Rippling == 0 then
			StartRipple()
		end

		-- (the time: at once for a new pick or a new song, otherwise worked out again on the next tick)
		BoardTime.Second = -2

		if BoardTime.Card ~= Card or BoardTime.Song ~= Entry.Song then
			BoardTime.Card = Card
			BoardTime.Song = Entry.Song
			DrawTime(BoardTime, Entry, workspace:GetServerTimeNow())
		end
	end

	local function Choose(Card: any, ByHand: boolean?)
		if Chosen == Card then
			return
		end

		local First = Chosen == nil

		Chosen = Card

		-- (a pick by hand clears the line under WATCH; one made for you, when the picked player's card goes, keeps it)
		if ByHand then
			SetToast("")
		end

		DrawBoard()

		-- (the swap: the board drops in from a little below, as Play's song panel does)
		if not First and Card then
			Swap = 0
		end
	end

	-- Asks the Handheld to watch a card's player. A slow or late answer changes nothing once a Notice, a Reset or another
	-- try came after it.
	local function StartWatch(Card: any)
		local Watch = Module.Hooks.Watch

		if not Watch or Joining or not Card or not Card.Entry or Card.Gone or Card.Player.Parent == nil then
			return
		end

		if WatchingNow() then
			SetToast("You're already spectating someone.")

			return
		end

		if Card.Entry.Watchers >= Module.MaxWatchers then
			SetToast("Too many people are watching them already.")

			return
		end

		WatchToken += 1

		local Mine = WatchToken
		local Who = Card.Player

		Joining = true
		SetToast(`Joining {Who.DisplayName}`)
		DrawBoard()

		task.spawn(function()
			local Asked, Started, Why = pcall(Watch, Who)

			if Mine == WatchToken and not (Asked and Started) then
				Joining = false
				SetToast(if Asked and type(Why) == "string" and Why ~= "" then Why else "Couldn't start spectating.")
				BoardDirty = true
			end
		end)

		task.delay(JoinWait, function()
			if Mine == WatchToken and Joining then
				Joining = false
				BoardDirty = true
			end
		end)
	end

	-- Cards ------------------------------------------------------------------------------------------------------------------
	local function NewCard(Who: Player): any
		local Holder = Make("Frame", Mask, { Name = Who.Name, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2, Visible = false })
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
			Image = `rbxthumb://type=AvatarHeadShot&id={Who.UserId}&w=150&h=150`,
			ZIndex = 3,
		})
		-- (the left side ends 320 short of the card's right edge, where the time column is)
		local Name = Label(Holder, {
			FontFace = FontOf("Roboto", Enum.FontWeight.Medium),
			TextSize = 24,
			RichText = true,
			Position = UDim2.fromOffset(86, 8),
			Size = UDim2.new(1, -320, 0, 34),
			Text = `{Escape(Who.DisplayName)} <font size="16" color="#A0A0A0">@{Escape(Who.Name)}</font>`,
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
			Player = Who,
			Sort = string.lower(Who.DisplayName),
			Entry = nil :: any,
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
			Hovered = false,
			Height = CardHeight,
			Stick = 0,
			HoverMix = 0,
			OutlineFill = 0,
			Cover = 0.5,
			CoverKey = nil :: any,
			Gone = nil :: number?, -- os.clock() when their song went (the card stays GoneGrace s more)
			Second = -2, -- what the time text shows (DrawTime)
			Held = false,
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
		-- the first click picks a player; a click on the picked one watches them
		Button.Activated:Connect(function()
			if Nodes.HiddenInTree(Section) or AimiaInput.Blocked(Button) or not Card.Entry then
				return
			end

			if Chosen ~= Card then
				Choose(Card, true)
			else
				StartWatch(Card)
			end
		end)

		return Card
	end

	-- A card shows a player's song as their attributes say it now (Paint skips what hasn't changed).
	local function SetEntry(Card: any, Entry: any)
		local Old = Card.Entry
		local CoverKey = Entry.Map or Entry.Song

		Card.Entry = Entry
		Card.Second = -2 -- (the time text is worked out again)

		if Card.CoverKey ~= CoverKey then
			Card.CoverKey = CoverKey
			Card.Art.ImageContent = (Entry.Map and CoverOf(Entry.Map)) or ThumbOf(Entry.MapID) or Content.none
		end

		Paint(Card, "BarColor", Card.Bar, "BackgroundColor3", Entry.Color)
		Paint(Card, "SongText", Card.Song, "Text", SongLine(Entry))
		Paint(Card, "DetailText", Card.Detail, "Text", DetailOf(Entry))
		Paint(Card, "WatchersText", Card.Watchers, "Text", if Entry.Watchers > 0 then `{Entry.Watchers} watching` else "")

		-- (a new card or a new song shows its time at once; the rest waits for the next tick)
		if Old == nil or Old.Song ~= Entry.Song then
			DrawTime(Card, Entry, workspace:GetServerTimeNow())
		end

		if Card == Chosen then
			BoardDirty = true
		end
	end

	-- Reads every player again: the cards listed, their order and the pick.
	local function Refresh()
		Dirty = false

		local Now = os.clock()
		local Everyone: { any } = Players:GetPlayers()
		local HiddenCount = 0

		for _, Who in Everyone do
			if LeftGame[Who] then
				continue
			end

			local Entry, Hidden = Read(Who)
			local Card = Cards[Who]

			if Hidden then
				HiddenCount += 1
			end

			if Entry then
				if not Card then
					Card = NewCard(Who)
					Cards[Who] = Card
				end

				Card.Gone = nil
				SetEntry(Card, Entry)
			elseif Card and not Card.Gone then
				Card.Gone = Now
			end
		end

		table.clear(Order)

		local Soonest = math.huge

		for _, Card in Cards do
			local Listed = Card.Gone == nil or Now - Card.Gone < GoneGrace

			if Listed then
				table.insert(Order, Card)

				if Card.Gone then
					Soonest = math.min(Soonest, Card.Gone + GoneGrace - Now)
				end
			else
				Card.Hovered = false

				if LastHovered == Card then
					LastHovered = nil
				end
			end

			Paint(Card, "Visible", Card.Holder, "Visible", Listed)
		end

		-- by display name, then user id: a steady order, so the cards don't jump about
		table.sort(Order, function(A, B)
			if A.Sort ~= B.Sort then
				return A.Sort < B.Sort
			end

			return A.Player.UserId < B.Player.UserId
		end)

		-- (a card in its last second is looked at again once it's over)
		if Soonest < math.huge and not Waiting then
			Waiting = true

			task.delay(Soonest + 0.05, function()
				Waiting = false
				Dirty = true
			end)
		end

		-- the pick stays while its card is listed (through a restart too); otherwise the first player in a song is picked
		if Chosen == nil or not table.find(Order, Chosen) then
			local Next = Order[1]

			for _, Card in Order do
				if not Card.Gone then
					Next = Card

					break
				end
			end

			Choose(Next)
		end

		local Empty = #Order == 0

		-- (players hidden with the player filter aren't listed: the page says so when they're all there'd be)
		if Empty then
			Put(EmptyTitle, "Text", if HiddenCount > 0 then "No one to show right now" else "No one is playing a song right now")
			Put(EmptySub, "Text", if HiddenCount > 0 then "Players you've hidden aren't listed here." else "When someone starts a song, they show up here.")
		end

		Put(EmptyPage, "Visible", Empty)
		Put(Board, "Visible", not Empty)
	end

	-- Every TickGap s while the page shows: the song times and bars, and who the Handheld is watching.
	local function Tick()
		local Now = workspace:GetServerTimeNow()

		for _, Card in Order do
			if Card.Entry and not Card.Gone then
				DrawTime(Card, Card.Entry, Now)
			end
		end

		local Entry = Chosen and Chosen.Entry

		if Entry and not Chosen.Gone then
			DrawTime(BoardTime, Entry, Now)
		end

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

	-- Players and input ------------------------------------------------------------------------------------------------------
	-- (an attribute change only sets the flag: it comes while AIMIA is shut or behind a song too)
	local function Follow(Who: Player)
		if Who == Players.LocalPlayer or Links[Who] then
			return
		end

		Links[Who] = Who.AttributeChanged:Connect(function(Name: string)
			if Watched[Name] then
				Dirty = true
			end
		end)
	end

	Players.PlayerAdded:Connect(function(Who: Player)
		Follow(Who)
		Dirty = true
	end)

	for _, Who in Players:GetPlayers() do
		Follow(Who)
	end

	-- a player who leaves takes their card; the pick moves on, and a watch on its way is dropped (StartWatch's token and the
	-- Handheld's own checks)
	Players.PlayerRemoving:Connect(function(Who: Player)
		LeftGame[Who] = true

		local Link = Links[Who]

		if Link then
			Link:Disconnect()
			Links[Who] = nil
		end

		local Card = Cards[Who]

		if Card then
			local Index = table.find(Order, Card)

			Cards[Who] = nil

			if Index then
				table.remove(Order, Index)
			end

			if LastHovered == Card then
				LastHovered = nil
			end

			if Chosen == Card then
				Chosen = nil
			end

			Card.Holder:Destroy()
		end

		Dirty = true
	end)

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

		StartWatch(Chosen)
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

	-- Enter watches the picked player; Up and Down pick the one above or below.
	AimiaInput.OnInput(function(Event: any, Processed: boolean)
		if Processed or Event.Class ~= "InputEventKey" or not Event.Pressed or Nodes.HiddenInTree(Section) then
			return
		end

		local Code = Event.Keycode

		if Code == AimiaInput.Key.Enter or Code == AimiaInput.Key.KpEnter then
			StartWatch(Chosen)
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

			if Joining then
				Joining = false
				BoardDirty = true
			end
		end

		-- (hidden: WATCH lets go of the mouse, and its rings stop)
		if WasShown and not Shown then
			WatchHovered, WatchHeld = false, false
			StopRipple()
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

		if Moved or WatchMix ~= WatchDrawn.Mix or WatchPress ~= WatchDrawn.Press or Shade ~= WatchDrawn.Shade or WatchOff ~= WatchDrawn.Off then
			local Lit = if WatchOff then 0.45 else 1
			local Resting = WatchRestTransparency + (WatchHoverTransparency - WatchRestTransparency) * WatchMix

			WatchDrawn.Mix, WatchDrawn.Press, WatchDrawn.Shade, WatchDrawn.Off = WatchMix, WatchPress, Shade, WatchOff
			WatchButton.BackgroundColor3 = Worn.Fill:Lerp(Worn.HoverFill, WatchMix)
			WatchButton.BackgroundTransparency = 1 - (1 - Resting) * Shade * Lit
			WatchButton.TextTransparency = 1 - Shade * (if WatchOff then 0.55 else 1)
			WatchRing.Color = Worn.Ring:Lerp(Worn.Hover, WatchMix)
			WatchRing.Transparency = 1 - Shade * Lit
			RippleRing.Color = Worn.Hover

			if WatchWide > 0 then
				local Extra = WatchStep * (WatchMix - WatchPress)

				WatchButton.Size = UDim2.fromScale((WatchWide + Extra) / WatchBox.X, (WatchTall + Extra) / WatchBox.Y)
			end
		end

		-- (the sheen and the beat run on the frame clock, UI/Frames, so they step evenly)
		Put(WatchSheen, "Rotation", math.floor(Frames.Time % SheenSeconds / SheenSeconds * 3600) / 10)

		-- the LIVE dot beats gently while they play
		local Beat = if LiveState == "LIVE" then 0.35 + 0.65 * (0.5 + 0.5 * math.cos(Frames.Time * math.pi * 2 / 1.6)) else 1
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

		local Top = ListTop - Scroll
		local Clear = 1 - Alpha

		for _, Card in Order do
			local Middle = Top + Card.Height / 2
			local Distance = math.abs(Middle - Height / 2) / (Height / 2 + CardHeight / 2)
			-- (places round to whole screen pixels, not layout pixels: under Menu Scale a layout pixel isn't one, and the slow end
			-- of each ease moved in uneven steps)
			local Left = math.floor(Width * (0.1 - math.cos(math.pi * math.min(Distance, 1) / 2) / 20 - Card.Stick) * Factor + 0.5) / Factor
			local Glow = Card.OutlineFill

			Paint(Card, "Position", Card.Holder, "Position", UDim2.fromOffset(Left, math.floor(Top * Factor + 0.5) / Factor))
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
	end)

	Module.Reset = function()
		WatchToken += 1
		Joining = false
		Chosen = nil
		Scroll, TargetScroll = 0, 0
		NoticeKept = false
		SetToast("")
		Dirty = true
		BoardDirty = true
	end

	Module.Notice = function(Text: string)
		WatchToken += 1
		Joining = false
		-- (the page isn't up yet, as when the Handheld brings it back: its showing keeps the line)
		NoticeKept = not WasShown
		SetToast(if type(Text) == "string" then Text else "")
		BoardDirty = true
	end

	task.defer(SnapWatch)
	Module.Section = Section
end

return Module
