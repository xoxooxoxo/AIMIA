--!optimize 2

--[[
	The Leaderboards section of the main menu (third beside Home and Play): the top five finished runs of each song, by points,
	from every server (Map/OnlineBoard). Songs on the right as Play lists them, the chosen song's list on the left.

	Paradigm
		The section's panel (Menus/Leaderboards) comes from the scene data, so the top bar, the Home button and the tab fade are
		MainMenu's own. Its contents are plain Instances: the song list copies Play's list (card sizes, the curve, the stick-out
		of the chosen song, the cover, the outline and the turning square that follows the mouse), and the board is one
		CanvasGroup.

	Design Notes
		Smooth on any machine: nothing is written while the page is still. The list fades with the tab by its own transparencies
		(a CanvasGroup redraws its whole picture whenever anything inside it moves), and every animated value is eased by hand
		and stops writing once it has arrived. The board's CanvasGroup only changes on a song swap, a refresh or a row hover.
		Play's numbers, measured from its list: cards 90 high (+10 hovered, +20 chosen) 10 apart, the first 10 down; each card's
		left edge at 0.1 of the list less cos(pi/2 d)/20 (d its distance from the list's middle) less 0.05 when chosen; the square
		60 left of the card it follows, 40 across, easing at 8 a second and turned by -y/60 radians.
]]

local AssetService = game:GetService("AssetService")
local EncodingService = game:GetService("EncodingService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local BBCode = require("../BBCode")
local Constants = require("../../Constants")
local FileSystem = require("../../Util/FileSystem")
local GameStart = require("./Play/GameStart")
local MapOrder = require("./Play/Logic/MapOrder")
local Images = require("../Images")
local MapCache = require("../../Map/MapCache")
local MapModule = require("../../Map/Map")
local MapParser = require("../../Map/MapParser")
local MapText = require("./Play/Logic/MapText")
local Nodes = require("../Nodes")
local OnlineBoard = require("../../Map/OnlineBoard")
local ReplayFile = require("../../Map/Replay")
local Scale = require("../Scale")
local AimiaInput = require("../Input")
local Signal = require("../../Util/Signal")
local TextureValue = require("./Play/Textures")
local LiveSpectate = require("../../Game/LiveSpectate")
local SettingsProfile = require("../../Database/Settings/SettingsProfile")

-- The values a replay file records itself: they stay as the file has them when the run's player's look is put on.
-- (not Fade Out: the file keeps only whether it was on; not Approach Time: it's worked out from the rate and distance)
local Recorded = { "ApproachRate", "ApproachDistance", "FadeIn", "Pushback", "FoV", "NoteSize", "Sensitivity" }

local Module = {
	Hooks = {
		-- plays a listed run's replay: (MapID, row); answers false and a reason when it can't
		WatchReplay = nil :: ((string, any) -> (boolean, string?))?,
	},
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

local function Tween(Object: Instance, Time: number, Style: Enum.EasingStyle, Goal: { [string]: any })
	TweenService:Create(Object, TweenInfo.new(Time, Style, Enum.EasingDirection.Out), Goal):Play()
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

local function Thousands(Value: number): string
	local Text = tostring(math.floor(Value))
	local Out = Text:reverse():gsub("(%d%d%d)", "%1,"):reverse()

	return (Out:gsub("^,", ""))
end

local function Ago(At: number): string
	local Seconds = math.max(0, os.time() - At)

	for _, Unit in { { 31536000, "year" }, { 2592000, "month" }, { 86400, "day" }, { 3600, "hour" }, { 60, "minute" } } do
		local Count = Seconds // Unit[1]

		if Count >= 1 then
			return `{Count} {Unit[2]}{if Count == 1 then "" else "s"} ago`
		end
	end

	return "just now"
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

-- a panel's modulate alpha, however the scene keeps it
local function AlphaOf(Value: unknown): number
	if type(Value) == "table" then
		local Color = (Value :: any).Color or Value

		if type(Color) == "table" and type(Color[4]) == "number" then
			return Color[4]
		end
	end

	return 1
end

-- The small cover kept with each baked map (the Cover attribute: Zstd RGB, Base64), for a map whose full cover won't decode.
local Thumbs: { [string]: Content | false } = {}

local function ThumbOf(Id: string): Content?
	if Thumbs[Id] ~= nil then
		return Thumbs[Id] or nil
	end

	Thumbs[Id] = false

	-- (not a local named Content: that would hide Roblox's Content, and Content.fromObject below would fail)
	local Stock = game:GetService("ReplicatedStorage"):FindFirstChild("AimiaContent")
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

-- The songs, mixed with artists kept apart (MapOrder.Spread), as Play starts each visit (the user's ask, 2026-11-07).
local function Songs(): { any }
	local Maps = {}

	for _, Map in MapCache.FetchAll() do
		table.insert(Maps, Map)
	end

	return MapOrder.Spread(Maps, math.random)
end

local function DifficultyColor(Map: any): any
	local Colors = Constants.DifficultyColors

	return Colors[math.clamp(tonumber(Map.Difficulty) or 0, 0, #Colors - 1) + 1]
end

-- Play's line under a song's title (length, difficulty in its colour, mappers), as Roblox rich text
local function ExtraOf(Map: any): string
	return (BBCode.ToRichText(MapText.ExtraText(Map.Length, MapText.ColorHtml(DifficultyColor(Map)), Map.DifficultyName, Map.PrettyMappers)))
end

-- Fills the scene's Menus/Leaderboards panel. Once.
function Module.Mount(Section: any)
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

	-- the chosen song's list, on the left (Play's song panel's place)
	local Board = Make("Frame", Host, {
		Name = "Board",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0.05, 8, 0, 128),
		Size = UDim2.new(0.4, -8, 1, -208),
		ZIndex = 2,
	})
	local Header = Box(Board, { Name = "Header", Size = UDim2.new(1, 0, 0, 132) })
	local Cover = Make("ImageLabel", Header, {
		BackgroundColor3 = White,
		BackgroundTransparency = 0.95,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(14, 14),
		Size = UDim2.fromOffset(104, 104),
		ScaleType = Enum.ScaleType.Crop,
	})

	Make("UICorner", Cover, { CornerRadius = UDim.new(0, 4) })

	local Words = Make("Frame", Header, { BackgroundTransparency = 1, Position = UDim2.fromOffset(134, 16), Size = UDim2.new(1, -150, 1, -16) })
	local Title = Label(Words, { FontFace = FontOf("Roboto", Enum.FontWeight.Medium), TextSize = 30, Size = UDim2.new(1, 0, 0, 38) })
	local Sub = Label(Words, { FontFace = FontOf("Roboto", Enum.FontWeight.Medium), TextColor3 = Grey, RichText = true, Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 24) })
	local Note = Label(Words, {
		TextColor3 = Dim,
		TextSize = 16,
		Position = UDim2.fromOffset(0, 72),
		Size = UDim2.new(1, 0, 0, 22),
		Text = "Top 5 by points. Faster speeds and harder modifiers earn more.",
	})
	local Strip = Make("Frame", Header, { BackgroundColor3 = Accent, BorderSizePixel = 0, Size = UDim2.new(0, 4, 1, 0) })
	local List = Box(Board, { Name = "List", Position = UDim2.fromOffset(0, 140), Size = UDim2.new(1, 0, 1, -170) })
	local Status = Label(List, {
		TextColor3 = Grey,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.new(0, 0, 0.5, -30),
		Visible = false,
	})
	local Retry = Make("TextButton", List, {
		Text = "Try again",
		FontFace = FontOf("Ubuntu", Enum.FontWeight.Medium),
		TextSize = 18,
		TextColor3 = White,
		BackgroundColor3 = Black,
		BackgroundTransparency = 0.4,
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 8),
		Size = UDim2.fromOffset(140, 36),
		Visible = false,
	})

	Make("UICorner", Retry, { CornerRadius = UDim.new(0, 4) })

	local Toast = Label(Board, {
		TextColor3 = Grey,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -4),
		Size = UDim2.new(1, 0, 0, 22),
	})

	Fade(Header, "BackgroundTransparency", PanelTransparency)
	Fade(Cover, "ImageTransparency", 0)

	local CoverBack = Fade(Cover, "BackgroundTransparency", 0.95)

	Fade(Title, "TextTransparency", 0)
	Fade(Sub, "TextTransparency", 0)
	Fade(Note, "TextTransparency", 0)
	Fade(Strip, "BackgroundTransparency", 0)
	Fade(List, "BackgroundTransparency", PanelTransparency)
	Fade(Status, "TextTransparency", 0)
	Fade(Retry, "BackgroundTransparency", 0.4)
	Fade(Retry, "TextTransparency", 0)
	Fade(Toast, "TextTransparency", 0)

	local Chosen: string? = nil
	local Rows = {}
	local WatchToken = 0

	for Index = 1, 5 do
		local Resting = if Index % 2 == 0 then 0.97 else 1
		local Row = Make("TextButton", List, {
			Name = "Row" .. Index,
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = White,
			BackgroundTransparency = Resting,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, (Index - 1) / 5, 0),
			Size = UDim2.new(1, 0, 0.2, 0),
			Visible = false,
		})
		local Item = {
			Row = Row,
			Resting = Resting,
			Hovered = false,
			HoverMix = 0,
			Rank = Label(Row, {
				FontFace = FontOf("Ubuntu", Enum.FontWeight.Medium),
				TextSize = 26,
				TextXAlignment = Enum.TextXAlignment.Center,
				Position = UDim2.new(0, 8, 0, 0),
				Size = UDim2.new(0, 48, 1, 0),
				Text = "#" .. Index,
				TextColor3 = if Index == 1 then Accent else White,
			}),
			Avatar = Make("ImageLabel", Row, {
				BackgroundColor3 = White,
				BackgroundTransparency = 0.94,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 62, 0.5, 0),
				Size = UDim2.new(0, 64, 0, 64),
			}),
			Name = Label(Row, {
				FontFace = FontOf("Ubuntu", Enum.FontWeight.Medium),
				TextSize = 24,
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 140, 0.5, 0),
				Size = UDim2.new(0.55, -140, 0, 28),
			}),
			Hint = Label(Row, { TextColor3 = Dim, TextSize = 14, Position = UDim2.new(0, 140, 0.5, 4), Size = UDim2.new(0.55, -140, 0, 18) }),
			Points = Label(Row, {
				FontFace = FontOf("Ubuntu", Enum.FontWeight.Medium),
				TextSize = 26,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -16, 0.5, 0),
				Size = UDim2.new(0.45, 0, 0, 30),
			}),
			Detail = Label(Row, {
				TextColor3 = Grey,
				TextSize = 16,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -16, 0.5, 2),
				Size = UDim2.new(0.62, 0, 0, 20),
			}),
			When = Label(Row, {
				TextColor3 = Dim,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -16, 0.5, 24),
				Size = UDim2.new(0.5, 0, 0, 14),
			}),
			Run = nil :: any,
		}

		Make("UICorner", Item.Avatar, { CornerRadius = UDim.new(0.5, 0) })

		Item.Back = Fade(Row, "BackgroundTransparency", Resting)
		Fade(Item.Rank, "TextTransparency", 0)
		Fade(Item.Avatar, "ImageTransparency", 0)
		Fade(Item.Avatar, "BackgroundTransparency", 0.94)
		Fade(Item.Name, "TextTransparency", 0)
		Fade(Item.Hint, "TextTransparency", 0)
		Fade(Item.Points, "TextTransparency", 0)
		Fade(Item.Detail, "TextTransparency", 0)
		Fade(Item.When, "TextTransparency", 0)

		-- a listed run can be watched: its row lights on hover and plays its replay on a click
		Row.MouseEnter:Connect(function()
			Item.Hovered = true
			Item.Hint.Text = if Item.Run then "Click to watch the replay" else ""
		end)
		Row.MouseLeave:Connect(function()
			Item.Hovered = false
			Item.Hint.Text = ""
		end)
		Row.Activated:Connect(function()
			local Watch = Module.Hooks.WatchReplay
			local Song = Chosen

			if not (Item.Run and Watch and Song) then
				return
			end

			WatchToken += 1

			local Mine = WatchToken

			Toast.Text = "Loading the replay"

			task.spawn(function()
				-- (a slow download that comes back after another click, or after the page was left, starts nothing)
				local Started, Why = Watch(Song, Item.Run, function(): boolean
					return Mine == WatchToken and Host.Visible and Chosen == Song
				end)

				if Mine == WatchToken then
					Toast.Text = if Started or Why == nil then "" else Why
				end
			end)
		end)

		Rows[Index] = Item
	end

	-- the songs, on the right (Play's list's place and look)
	local Picker = Make("Frame", Host, {
		Name = "Songs",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 0, 128),
		Size = UDim2.new(0.5, -8, 1, -208),
		ZIndex = 2,
	})
	-- (the cards scroll inside a mask; the square sits outside it, as Play's does, so it shows left of a song that sticks out)
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

	local Cards = {}
	local LastHovered = nil

	for Order, Map in Songs() do
		local Holder = Make("Frame", Mask, { Name = Map.Name, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2 })
		local Fill = Make("Frame", Holder, { BackgroundColor3 = Black, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) })
		local Art = Make("ImageLabel", Holder, {
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -3, 0.5, 0),
			Size = UDim2.new(0.75, -3, 1, -4),
			ScaleType = Enum.ScaleType.Crop,
			ImageContent = CoverOf(Map) or Content.none,
		})
		local Frame = Make("Frame", Holder, { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 3 })
		local Outline = Make("UIStroke", Frame, { Thickness = 2, Color = White, Transparency = 1 })
		local Name = Label(Holder, {
			FontFace = FontOf("Roboto", Enum.FontWeight.Medium),
			TextSize = 26,
			Position = UDim2.fromOffset(16, 8),
			Size = UDim2.new(1, -60, 0, 37),
			Text = Map.PrettyTitle,
			ZIndex = 3,
		})
		local Line = Make("Frame", Holder, { BackgroundColor3 = White, BorderSizePixel = 0, Position = UDim2.fromOffset(16, 45), Size = UDim2.new(1, -32, 0, 1), ZIndex = 3 })
		local Extra = Label(Holder, {
			FontFace = FontOf("Roboto", Enum.FontWeight.Medium),
			TextSize = 21,
			RichText = true,
			Position = UDim2.fromOffset(16, 45),
			Size = UDim2.new(1, -40, 0, 37),
			Text = ExtraOf(Map),
			ZIndex = 3,
		})
		local Button = Make("TextButton", Holder, { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 4 })

		Make("UICorner", Fill, { CornerRadius = UDim.new(0, 5) })
		Make("UICorner", Frame, { CornerRadius = UDim.new(0, 4) })
		Make("UICorner", Art, { CornerRadius = UDim.new(0, 4) })
		-- (Play's cover fade: clear at its left edge, 20% clear from just past halfway)
		Make("UIGradient", Art, {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.8 / 1.5, 0.2),
				NumberSequenceKeypoint.new(1, 0.2),
			}),
		})
		local NameStroke = Make("UIStroke", Name, { Thickness = 0.5, Color = Black })

		local Card = {
			Map = Map,
			Id = Map.Name,
			Holder = Holder,
			Fill = Fill,
			Art = Art,
			Outline = Outline,
			Name = Name,
			NameStroke = NameStroke,
			Line = Line,
			Extra = Extra,
			Order = Order,
			Hovered = false,
			Height = CardHeight,
			Stick = 0,
			HoverMix = 0,
			OutlineFill = 0,
			Cover = 0.5,
			Drawn = {} :: { [string]: any },
		}

		Button.MouseEnter:Connect(function()
			-- (a modal over the list takes the hover, as on Spectate's cards; under a pointer-only layer, the owner panel, the
			-- card still follows the pointer and shows no hover while that layer has it: Input.PointerTaken)
			if AimiaInput.Blocked(Button) and not AimiaInput.PointerTaken(Button) then
				return
			end

			Card.Hovered = true
			LastHovered = Card
		end)
		Button.MouseLeave:Connect(function()
			Card.Hovered = false
		end)
		Button.Activated:Connect(function()
			if Chosen ~= Card.Id then
				Module.Choose(Card.Id)
			end
		end)

		table.insert(Cards, Card)
	end

	-- Board ------------------------------------------------------------------------------------------------------------------
	local Swap = 1 -- 0 to 1: the board's song swap, eased in
	local Faded = -1

	local function Draw()
		local Map
		for _, Card in Cards do
			if Card.Id == Chosen then
				Map = Card.Map
			end
		end

		if not Map then
			return
		end

		Title.Text = Map.PrettyTitle
		Sub.Text = ExtraOf(Map)

		local Color = DifficultyColor(Map)

		Strip.BackgroundColor3 = Color3.new(Color.R or 1, Color.G or 1, Color.B or 1)

		local Picture = CoverOf(Map)

		Cover.ImageContent = Picture or Content.none
		Rest(CoverBack, if Picture then 1 else 0.95)

		local Listed = OnlineBoard.Rows[Map.Name]
		local Count = if Listed then #Listed else 0

		for Index, Item in Rows do
			local Run = Listed and Listed[Index]

			Item.Run = Run
			Put(Item.Row, "Visible", Run ~= nil)

			if Run then
				local UserId = tonumber(Run.UserId) or 0
				local Misses = tonumber(Run.Misses) or 0
				local Parts = {
					if Misses == 0 then "Full combo" elseif Misses == 1 then "1 miss" else `{Misses} misses`,
					string.format("%.2f%%", tonumber(Run.Accuracy) or 0),
					string.format("%.2fx", tonumber(Run.Speed) or 1),
				}
				local Mods = ModsText(Run.Mods)

				if Mods ~= "" then
					table.insert(Parts, Mods)
				end

				Put(Item.Avatar, "Image", `rbxthumb://type=AvatarHeadShot&id={UserId}&w=150&h=150`)
				Put(Item.Name, "Text", tostring(Run.Name or Run.DisplayName or ""))
				Put(Item.Points, "Text", Thousands(tonumber(Run.Points) or 0))
				Put(Item.Detail, "Text", table.concat(Parts, "  ·  "))
				Put(Item.When, "Text", if type(Run.At) == "number" then Ago(Run.At) else "")
			end
		end

		Put(Retry, "Visible", false)

		if Count > 0 then
			Put(Status, "Visible", false)
		elseif not OnlineBoard.Loaded then
			Put(Status, "Visible", true)
			Put(Status, "Text", if OnlineBoard.Failed then "Couldn't load the scores." else "Loading")
			Put(Retry, "Visible", OnlineBoard.Failed)
		else
			Put(Status, "Visible", true)
			Put(Status, "Text", "No one has finished this song yet.")
		end
	end

	function Module.Choose(Id: string)
		if Chosen == Id then
			return
		end

		local First = Chosen == nil

		Chosen = Id
		Toast.Text = ""
		Draw()

		-- (the swap: the board drops in from a little below, as Play's song panel does)
		if not First then
			Swap = 0
		end
	end

	-- Asking for the lists ---------------------------------------------------------------------------------------------------
	local Token = 0

	local function Ask()
		Token += 1

		local Mine = Token

		Draw()
		task.spawn(OnlineBoard.Refresh)
		task.delay(10, function()
			if Mine == Token and not OnlineBoard.Loaded then
				OnlineBoard.Failed = true
				Draw()
			end
		end)
	end

	Retry.Activated:Connect(function()
		OnlineBoard.Failed = false
		Ask()
	end)

	Signal.Connect(OnlineBoard.Changed, function(Id: string?)
		if Id == nil or Id == Chosen then
			Draw()
		end
	end)

	if Cards[1] then
		Module.Choose(Cards[1].Id)
	end

	-- Every frame the page shows ---------------------------------------------------------------------------------------------
	local ListHovered = false
	local SquareX, SquareY, SquareAlpha = -80, 0, 0
	local SquareShown = false
	local Scroll, TargetScroll = 0, 0
	local LastAlpha = -1
	local WasShown = false

	-- A fresh mixed order each visit (Handheld calls Module.Mix): the cards are drawn in table order, so reordering them is
	-- enough. The list goes back to the top and the first card is chosen, as on the first visit.
	Module.Mix = function()
		local Maps = {}
		local ByName = {}

		for _, Card in Cards do
			table.insert(Maps, Card.Map)
			ByName[Card.Id] = Card
		end

		table.clear(Cards)

		for Index, Map in MapOrder.Spread(Maps, math.random) do
			local Card = ByName[Map.Name]

			if Card then
				Card.Order = Index
				table.insert(Cards, Card)
			end
		end

		TargetScroll = 0

		if Cards[1] then
			Module.Choose(Cards[1].Id)
		end
	end

	Picker.MouseEnter:Connect(function()
		ListHovered = true
	end)
	Picker.MouseLeave:Connect(function()
		ListHovered = false
	end)

	UserInputService.InputChanged:Connect(function(Input: InputObject)
		if ListHovered and Host.Visible and Input.UserInputType == Enum.UserInputType.MouseWheel and not AimiaInput.Blocked(Picker) then
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

	local function Paint(Card, Key: string, Object: Instance, Property: string, Value: any)
		if Card.Drawn[Key] ~= Value then
			Card.Drawn[Key] = Value;
			(Object :: any)[Property] = Value
		end
	end

	Nodes.OnFrame(function(Delta: number)
		local Shown = Host.Visible

		if Shown and not WasShown then
			Ask()
		end

		WasShown = Shown

		-- (the cached menu stays Visible behind a song, a replay started from here included: it rests while it isn't in the tree,
		-- as the Spectate page does)
		if not Shown or Nodes.HiddenInTree(Section) then
			return
		end

		Delta = math.min(Delta, 0.1)

		local Alpha = AlphaOf(Nodes.Get(Section, "modulate"))
		local Factor = Scale.FactorOf(Picker)
		local Width = Picker.AbsoluteSize.X / Factor
		local Height = Picker.AbsoluteSize.Y / Factor
		local AlphaMoved = Alpha ~= LastAlpha

		LastAlpha = Alpha

		-- the board: the tab's fade and the swap together, written only when something moved
		Swap = Ease(Swap, 1, 1 / 0.12, Delta, 0.002)

		for _, Item in Rows do
			Item.HoverMix = Ease(Item.HoverMix, if Item.Hovered then 1 else 0, 1 / 0.15, Delta, 0.01)
			Rest(Item.Back, Item.Resting + (0.9 - Item.Resting) * Item.HoverMix)
		end

		local Shade = Alpha * (1 - (1 - Swap) ^ 3)

		if Shade ~= Faded or FadesDirty then
			Faded = Shade
			FadesDirty = false

			for _, Entry in Fades do
				Put(Entry.Object, Entry.Property, 1 - (1 - Entry.Base) * Shade)
			end
		end

		local Rise = math.floor(24 * (1 - Swap) ^ 3 + 0.5)

		Put(Board, "Position", UDim2.new(0.05, 8, 0, 128 + Rise))

		-- (while a pointer-only layer, the owner panel, has the pointer, the cards under it show no hover: Input.PointerTaken)
		local Taken = AimiaInput.PointerTaken(Picker)

		-- the cards: heights first, then their places (a grown card pushes the others apart evenly, as Play's do)
		local Total = ListTop

		for _, Card in Cards do
			local Selected = Card.Id == Chosen
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

		for _, Card in Cards do
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
			Paint(Card, "Outline", Card.Outline, "Transparency", 1 - (0.12 + 0.5 * Glow) * Alpha)
			Paint(Card, "OutlineColor", Card.Outline, "Color", White:Lerp(Accent, Card.HoverMix * (1 - math.max(0, Glow - 0.5) * 2) + (if Card.Id == Chosen then 0 else 0)))
			Paint(Card, "Name", Card.Name, "TextTransparency", 1 - Alpha)
			Paint(Card, "NameStroke", Card.NameStroke, "Transparency", 1 - Alpha)
			Paint(Card, "Extra", Card.Extra, "TextTransparency", 1 - Alpha)
			Paint(Card, "Line", Card.Line, "BackgroundTransparency", 1 - 0.2 * Alpha)

			Card.Left = Left
			Card.Middle = Middle
			Top += Card.Height + CardGap
		end

		-- the square, as Play's: it shows once the mouse is on a song, starts at that song's height, follows the last song the
		-- mouse was on (the gaps between songs don't move it), and fades out to the list's left edge when the mouse leaves
		local Pointing = ListHovered and not Taken
		local Followed = if Pointing then LastHovered else nil

		local OnSong = false

		for _, Card in Cards do
			OnSong = OnSong or (Card.Hovered and not Taken)
		end

		if Followed and Followed.Middle and OnSong and not SquareShown then
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

		if AlphaMoved then
			Put(Picker, "Visible", Alpha > 0)
		end
	end)
end

-- Plays a listed run's replay: it comes down from the server, is written as a replay file and started as the Play menu
-- starts a local one.
Module.Hooks.WatchReplay = function(MapID: string, Run: any, StillWanted: (() -> boolean)?): (boolean, string?)
	local Fetch = OnlineBoard.Hooks.FetchReplay

	if not Fetch then
		return false, "Replays aren't available here."
	end

	-- (phones and tablets can't start a song here, replays included)
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return false, "Replays play on a computer."
	end

	local Packed, Why, Look = Fetch(MapID, tonumber(Run.UserId) or 0, tonumber(Run.At) or 0)

	if not Packed then
		return false, Why
	end

	local Sized, Size = pcall(EncodingService.GetDecompressedBufferSize, EncodingService, Packed, Enum.CompressionAlgorithm.Zstd)

	if not Sized or type(Size) ~= "number" or Size > 16 * 1024 * 1024 then
		return false, "That replay couldn't be opened."
	end

	local Opened, Bytes = pcall(EncodingService.DecompressBuffer, EncodingService, Packed, Enum.CompressionAlgorithm.Zstd)

	if not Opened then
		return false, "That replay couldn't be opened."
	end

	local Path = `{Constants.UserFolder}/replays/online-{tonumber(Run.UserId) or 0}-{MapID}.phxr`

	FileSystem.WriteAllBytes(Path, Bytes)

	local Read, Watched = pcall(ReplayFile.New, Path)

	-- (it came from another player's game: it must read whole, at a speed and start a song can have)
	local Speed, Start = tonumber(Watched and Watched.Speed), tonumber(Watched and Watched.StartFrom)

	if not Read or not Watched or Watched.Valid == false or not Watched.MapFilePath or not Watched.Frames
		or not Speed or Speed ~= Speed or Speed < 0.25 or Speed > 10 or not Start or Start ~= Start or Start < 0 then
		return false, "That replay couldn't be opened."
	end

	local Decoded, Map = pcall(MapParser.Decode, Watched.MapFilePath)

	if not Decoded or not Map then
		return false, "That song isn't here any more."
	end

	-- (and it must be a replay of this map's notes: a count that doesn't match would leave notes with no result)
	local NoteCount = #MapModule.GetNotes(Map)

	if Watched.MapNoteCount ~= NoteCount or type(Watched.Notes) ~= "table" or #Watched.Notes ~= NoteCount then
		return false, "That replay couldn't be opened."
	end

	if StillWanted and not StillWanted() then
		return false, nil
	end

	-- The run's player's look, as spectating shows it (their space, colors, notes and cursor), from a copy: the watcher's own
	-- settings are never read or changed. A run saved before looks went up with replays plays with the watcher's.
	if type(Look) == "table" then
		local Profile = LiveSpectate.ProfileOf(Look)
		local FromFile = Watched.Settings

		if FromFile then
			for _, Name in Recorded do
				local Item: any = SettingsProfile.ItemNamed(Profile, Name)
				local Kept: any = SettingsProfile.ItemNamed(FromFile, Name)

				if Item and Kept and type(Kept.Value) == type(Item.Value) then
					local Wanted: any = Kept.Value

					-- (a number from the file must be a real one, inside the setting's own range)
					if type(Wanted) == "number" then
						if not math.isfinite(Wanted) then
							continue
						end

						if Item.Slider then
							Wanted = math.clamp(Wanted, Item.Slider.Floor, Item.Slider.Ceiling)
						end
					end

					Item.Value = Wanted
				end
			end

			if Profile.ApproachRate.Value > 0 then
				Profile.ApproachTime.Value = Profile.ApproachDistance.Value / Profile.ApproachRate.Value
			end

			if FromFile.FadeOut.Value == 0 then
				Profile.FadeOut.Value = 0
			end

			Profile.FoV.Value = math.clamp(Profile.FoV.Value, 1, 120)
		end

		-- (the player's note look goes on in Attempt.New, once the start is accepted)
		Watched.Settings = Profile
		Watched.ShowsPlayer = true
		-- (everything that came with it, and whose it is, for Copy Settings)
		;(Watched :: any).Look = Look
		;(Watched :: any).PlayerName = if type(Run.Name) == "string" then Run.Name else nil
	end

	GameStart.Play(Map, Watched.Speed, Watched.StartFrom, Watched.CameraMode, Watched.Modifiers, { Watched })

	return true
end

return Module
