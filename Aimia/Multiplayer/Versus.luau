--!optimize 2

--[[
	AIMIA's VS mode on this side: the lobbies the server keeps (Server.Services.Players.AimiaVersus), read from
	ReplicatedStorage.AimiaVsLobbies and the players' attributes; what you ask of it (host, join, leave, start, and the host's start
	time and kicks); a round's song
	started at the round's time; and that song's live numbers, sent while it plays. No UI: the VS tab (UI/Menu/VersusMenu),
	Play's VS button (UI/Menu/Play/GameStart's Hooks.Versus) and the Handheld read and call this.

	Paradigm
		The Handheld sets the Hooks: Send (the remote), RoundStarting (a round you're in is starting: whatever else is on the
		tablet goes and the VS tab shows the count) and Ready (the tablet can start the song now). Version goes up whenever
		anything a lobby shows changes, so a page draws again only then.
		A round's song is Game.Play's, with the lobby's song, speed and modifiers, from the lobby's start (StartFrom: its
		beginning unless the host picked a later time, which keeps the runs off the song lists as it does alone), and Versus = { Lobby, Round }
		on its attempt: Game, Runner and the song's HUD read that (no pause, no restart, no skip but the last, no owner auto).

	Design Notes
		A lobby's folder holds what the server publishes (its Host, Map, Mods, Speed, StartFrom, State, Round, StartAt, Members and
		Results); a member's part in a round is on the member (AimiaVsRound, AimiaVsState, AimiaVsLive), so their numbers
		reach everyone without the lobby being written a few times a second.
		Autoplay is never built for a VS song (Build has no name for it), whatever a lobby says.
		Standings after a round sort as the server's results do: out of the round last, then score, accuracy, fewer misses,
		who came first. Through a round they keep still unless someone really passes someone (Standings' HOLD).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CameraLock = require("../Game/Camera/CameraLock")
local CameraSpin = require("../Game/Camera/CameraSpin")
local ChaosModifier = require("../Game/Modifiers/ChaosModifier")
local Constants = require("../Constants")
local EarthquakeModifier = require("../Game/Modifiers/EarthquakeModifier")
local FileSystem = require("../Util/FileSystem")
local Game = require("../Game/Game")
local GhostModifier = require("../Game/Modifiers/GhostModifier")
local HorizontalFlipModifier = require("../Game/Modifiers/HorizontalFlipModifier")
local NoFailModifier = require("../Game/Modifiers/NoFailModifier")
local StrobeModifier = require("../Game/Modifiers/StrobeModifier")
local VerticalFlipModifier = require("../Game/Modifiers/VerticalFlipModifier")
local VortexModifier = require("../Game/Modifiers/VortexModifier")

local Versus = {
	Hooks = {
		-- sends to the server's AimiaVersus (the Handheld sets it)
		Send = nil :: ((...any) -> ())?,
		-- a round you're in is starting (its lobby's info): the tablet gets ready for it, and answers whether it can play
		RoundStarting = nil :: ((any) -> boolean)?,
		-- whether the tablet can start the round's song right now
		Ready = nil :: (() -> boolean)?,
	},
	MaxPlayers = 5,
	Version = 0, -- goes up whenever a lobby, or a member's part in one, changes
}

-- (Map/Replay's names for them; Autoplay has none here, so a VS song never plays itself)
local Made: { [string]: () -> any } = {
	NoFail = NoFailModifier,
	Ghost = GhostModifier,
	Chaos = ChaosModifier,
	Earthquake = EarthquakeModifier,
	Vortex = VortexModifier,
	VFlip = VerticalFlipModifier,
	HFlip = HorizontalFlipModifier,
	Strobe = StrobeModifier,
}

-- the attributes of a player that their part in a lobby is read from (AimiaSong: whether they can be watched)
local Watched = { AimiaVs = true, AimiaVsRound = true, AimiaVsState = true, AimiaVsLive = true, AimiaSong = true }

local function Finite(Value: any, Default: number): number
	return if type(Value) == "number" and Value == Value and math.abs(Value) ~= math.huge then Value else Default
end

local function Decode(Text: any): any
	if type(Text) ~= "string" or Text == "" then
		return nil
	end

	local Ok, Value = pcall(HttpService.JSONDecode, HttpService, Text)

	return if Ok then Value else nil
end

local function Send(...: any)
	local Hook = Versus.Hooks.Send

	if Hook then
		Hook(...)
	end
end

local function Holder(): Instance?
	return ReplicatedStorage:FindFirstChild("AimiaVsLobbies")
end

-- Reading ----------------------------------------------------------------------------------------------------------------

-- What a lobby's folder says now, or nil when it doesn't read
function Versus.Read(Folder: Instance): any?
	local Host = Folder:GetAttribute("Host")

	if type(Host) ~= "number" then
		return nil
	end

	local Ids = Decode(Folder:GetAttribute("Members"))
	local Members = {}

	if type(Ids) == "table" then
		for _, Id in Ids do
			if type(Id) == "number" then
				table.insert(Members, Id)
			end
		end
	end

	local Results = Decode(Folder:GetAttribute("Results"))
	local function Text(Name: string): string
		local Value = Folder:GetAttribute(Name)

		return if type(Value) == "string" then Value else ""
	end

	return {
		Id = Folder.Name,
		Folder = Folder,
		Host = Host, -- the host's UserId
		HostName = Text("HostName"),
		HostDisplay = Text("HostDisplay"),
		Map = Text("Map"), -- the song's folder in AimiaContent.Maps
		MapID = Text("MapID"), -- the song's id, as this game names its map
		Mods = Text("Mods"), -- "Ghost_NoFail_Spin"
		Speed = math.clamp(Finite(Folder:GetAttribute("Speed"), 1), 0.25, 10),
		StartFrom = math.max(0, Finite(Folder:GetAttribute("StartFrom"), 0)), -- where in the song a round starts, in ms (0: its beginning)
		State = if Text("State") ~= "" then Text("State") else "Open", -- Open, Starting (the count) or Playing
		Round = Finite(Folder:GetAttribute("Round"), 0),
		StartAt = Finite(Folder:GetAttribute("StartAt"), 0), -- the server time the round's songs start at
		Members = Members, -- UserIds, in the order they came
		Count = #Members,
		Results = if type(Results) == "table" then Results else nil, -- the last round's places, best first
	}
end

-- Every lobby now, those with room first, then by host name
function Versus.Lobbies(): { any }
	local List = {}
	local Folder = Holder()

	if Folder then
		for _, Child in Folder:GetChildren() do
			local Info = Versus.Read(Child)

			if Info and Info.Count > 0 then
				table.insert(List, Info)
			end
		end
	end

	table.sort(List, function(A, B)
		local AFull, BFull = A.Count >= Versus.MaxPlayers, B.Count >= Versus.MaxPlayers

		if AFull ~= BFull then
			return BFull
		end

		local AName, BName = string.lower(A.HostDisplay), string.lower(B.HostDisplay)

		if AName ~= BName then
			return AName < BName
		end

		return A.Id < B.Id
	end)

	return List
end

-- The id of the lobby you're in, or nil
function Versus.MyId(): string?
	local Id = Players.LocalPlayer:GetAttribute("AimiaVs")

	return if type(Id) == "string" and Id ~= "" then Id else nil
end

function Versus.Get(Id: string?): any?
	local Folder = Holder()
	local Child = if Id and Folder then Folder:FindFirstChild(Id) else nil

	return if Child then Versus.Read(Child) else nil
end

-- The lobby you're in, or nil
function Versus.Mine(): any?
	return Versus.Get(Versus.MyId())
end

-- Whether you host the lobby
function Versus.IsHost(Info: any?): boolean
	return Info ~= nil and Info.Host == Players.LocalPlayer.UserId
end

-- A lobby's members as they are now, in the order they came: who they are, and their part in the lobby's last round
-- (InRound, State: Loading, Playing, Passed, Failed or Out, and their numbers), from their own attributes
function Versus.Members(Info: any): { any }
	local List = {}

	for Order, Id in Info.Members do
		local Who = Players:GetPlayerByUserId(Id)

		if not Who then
			continue
		end

		local InRound = Info.Round > 0 and Who:GetAttribute("AimiaVs") == Info.Id and Who:GetAttribute("AimiaVsRound") == Info.Round
		local Score, Hits, Misses, Combo = 0, 0, 0, 0
		local Live = Who:GetAttribute("AimiaVsLive")

		if InRound and type(Live) == "string" then
			local A, B, C, D = string.match(Live, "^(%d+),(%d+),(%d+),(%d+)$")

			Score, Hits, Misses, Combo = tonumber(A) or 0, tonumber(B) or 0, tonumber(C) or 0, tonumber(D) or 0
		end

		local State = Who:GetAttribute("AimiaVsState")

		table.insert(List, {
			Player = Who,
			UserId = Id,
			Name = Who.Name,
			Display = Who.DisplayName,
			Host = Id == Info.Host,
			Me = Who == Players.LocalPlayer,
			Order = Order,
			InRound = InRound,
			State = if InRound and type(State) == "string" then State else nil,
			Score = Score,
			Hits = Hits,
			Misses = Misses,
			Combo = Combo,
			Accuracy = if Hits + Misses > 0 then math.floor(Hits / (Hits + Misses) * 10000) / 100 else 100,
			Watchable = InRound and State == "Playing" and Who:GetAttribute("AimiaSong") ~= nil,
		})
	end

	return List
end

-- best first: in the round before out of it, then score, accuracy, fewer misses, who came first (the server's results)
local function Better(A: any, B: any): boolean
	local AOut, BOut = not A.InRound or A.State == "Out", not B.InRound or B.State == "Out"

	if AOut ~= BOut then
		return BOut
	end

	if A.Score ~= B.Score then
		return A.Score > B.Score
	end

	if A.Accuracy ~= B.Accuracy then
		return A.Accuracy > B.Accuracy
	end

	if A.Misses ~= B.Misses then
		return A.Misses < B.Misses
	end

	return A.Order < B.Order
end

local function IsOut(Entry: any): boolean
	return not Entry.InRound or Entry.State == "Out"
end

-- While a round plays, its board keeps still unless someone really passes someone: a tie keeps the order shown, and a player
-- goes above one shown over them only once they have had more points than that one for HOLD seconds without a break (two
-- players on the same notes send their numbers a moment apart, so each would look ahead in turn). Each pair is timed on its
-- own, so two players trading places never hold back a third who has really passed someone. Anyone new on the board takes
-- their place at once, and anyone out of the round goes under everyone still in it at once; everyone else keeps their place.
local HOLD = 1
-- per lobby: its round, the order shown (UserIds), and since when each pair has been the other way round from it ("A>B": A
-- has had more points than B, who shows above A, since then)
local Shown: { [string]: any } = {}

-- A lobby's members, best first: through a round as its board shows them (above), after it as the server's results
function Versus.Standings(Info: any): { any }
	local List = Versus.Members(Info)

	if Info.State == "Open" or Info.Round <= 0 then
		Shown[Info.Id] = nil
		table.sort(List, Better)

		return List
	end

	local Memory = Shown[Info.Id]

	if not Memory or Memory.Round ~= Info.Round then
		Memory = { Round = Info.Round, Order = {}, Ahead = {} }
		Shown[Info.Id] = Memory
	end

	local Place: { [number]: number } = {}

	for Index, Id in Memory.Order do
		Place[Id] = Index
	end

	-- (as shown last time, anyone new under that in the server's order)
	table.sort(List, function(A: any, B: any): boolean
		local APlace, BPlace = Place[A.UserId], Place[B.UserId]

		if APlace and BPlace then
			return APlace < BPlace
		elseif APlace or BPlace then
			return APlace ~= nil
		end

		return Better(A, B)
	end)

	-- each pair the other way round from how it shows, and since when (a pair that ties or agrees again starts over)
	local Clock = os.clock()
	local Ahead, Still = Memory.Ahead, {}

	for Upper = 1, #List do
		for Lower = Upper + 1, #List do
			local Above, Below = List[Upper], List[Lower]

			if Place[Above.UserId] and Place[Below.UserId] and IsOut(Above) == IsOut(Below) and Below.Score > Above.Score then
				local Key = `{Below.UserId}>{Above.UserId}`

				Still[Key] = true

				if not Ahead[Key] then
					local Started = Clock

					Ahead[Key] = Started

					-- (the board looks again once it has lasted, even if nobody's numbers change by then)
					task.delay(HOLD + 0.05, function()
						if Ahead[Key] == Started then
							Versus.Version += 1
						end
					end)
				end
			end
		end
	end

	for Key in Ahead do
		if not Still[Key] then
			Ahead[Key] = nil
		end
	end

	-- whether Below, just under Above, goes over them now: out of the round under everyone in it, someone new where the
	-- server would put them, otherwise more points for HOLD
	local function Passes(Below: any, Above: any): boolean
		local AboveOut, BelowOut = IsOut(Above), IsOut(Below)

		if AboveOut ~= BelowOut then
			return AboveOut
		end

		if not (Place[Above.UserId] and Place[Below.UserId]) then
			return Better(Below, Above)
		end

		local Since = Ahead[`{Below.UserId}>{Above.UserId}`]

		return Since ~= nil and Clock - Since >= HOLD
	end

	for Index = 2, #List do
		local At = Index

		while At > 1 and Passes(List[At], List[At - 1]) do
			List[At], List[At - 1] = List[At - 1], List[At]
			At -= 1
		end
	end

	table.clear(Memory.Order)

	for Index, Entry in List do
		Memory.Order[Index] = Entry.UserId
	end

	return List
end

-- Who to watch in a lobby's round (yours, or the one named Id): the best placed member still playing (not you, not
-- Except), or nil
function Versus.Leader(Except: Player?, Id: string?): Player?
	local Info = if Id then Versus.Get(Id) else Versus.Mine()

	if not Info or Info.Round <= 0 then
		return nil
	end

	for _, Entry in Versus.Standings(Info) do
		if Entry.Watchable and not Entry.Me and Entry.Player ~= Except then
			return Entry.Player
		end
	end

	return nil
end

-- The time in a lobby's round's song now, in ms of the map (0 before it starts; the round's start time until its song begins)
function Versus.Elapsed(Info: any): number
	if Info.State == "Open" or Info.StartAt <= 0 then
		return 0
	end

	return Info.StartFrom + math.max(0, (workspace:GetServerTimeNow() - Info.StartAt) * 1000 * Info.Speed)
end

-- Modifiers ---------------------------------------------------------------------------------------------------------------

-- A selection's modifiers as their names joined with "_", the camera's Spin or Lock last (ReplayManager.ModifierNames'
-- text, which the song's own start sends the server)
function Versus.ModsText(Mods: { any }, Camera: any?): string
	local Names = {}

	for _, Mod in Mods do
		table.insert(Names, Mod.Name)
	end

	if Camera and (Camera.Name == "Spin" or Camera.Name == "Lock") then
		table.insert(Names, Camera.Name)
	end

	return table.concat(Names, "_")
end

-- A lobby's modifiers back as the game's own (Map/Replay's ReadModifiers, less Autoplay): the modifiers and the camera
function Versus.Build(Text: string): ({ any }, any)
	local Mods, Camera = {}, CameraLock()
	local Seen = {}

	for Name in string.gmatch(Text, "[^_]+") do
		if Name == "Spin" then
			Camera = CameraSpin()
		elseif Name == "Lock" then
			Camera = CameraLock(true)
		elseif Made[Name] and not Seen[Name] then
			Seen[Name] = true
			table.insert(Mods, Made[Name]())
		end
	end

	return Mods, Camera
end

-- Asking ------------------------------------------------------------------------------------------------------------------

-- Play's VS button: a lobby of your own with this song, speed, camera, modifiers and start (Play's, in ms), or yours changed
-- to them. Answers whether it was asked for, and why not.
function Versus.Host(Map: any, Speed: number, Camera: any, Mods: { any }, StartFrom: number?): (boolean, string?)
	if not Map or type(Map.FolderPath) ~= "string" then
		return false, "Pick a song first."
	end

	for _, Mod in Mods do
		if Mod.Name == "Autoplay" then
			return false, "Autoplay can't be used in VS. Turn it off, then press VS."
		end
	end

	local Mine = Versus.Mine()

	if Mine and not Versus.IsHost(Mine) then
		return false, `You're in {Mine.HostDisplay}'s lobby. Leave it to host your own.`
	end

	if Mine and Mine.State ~= "Open" then
		return false, "Wait for this round to end."
	end

	Send("Host", FileSystem.GetFileName(Map.FolderPath), Versus.ModsText(Mods, Camera), Finite(Speed, 1), math.max(0, math.floor(Finite(StartFrom, 0))))

	return true, nil
end

function Versus.Join(Id: string)
	Send("Join", Id)
end

function Versus.Leave()
	Send("Leave")
end

-- The host's start time on the VS tab, in ms into the song (the server keeps it between 0 and the song's last note)
function Versus.SetStart(Ms: number)
	Send("StartFrom", math.max(0, math.floor(Finite(Ms, 0))))
end

-- The host's KICK: that player out of your lobby (the server checks you host it, it's open and they're in it)
function Versus.Kick(UserId: number)
	Send("Kick", UserId)
end

function Versus.StartRound()
	Send("Start")
end

-- Rounds -----------------------------------------------------------------------------------------------------------------

local Scheduled: string? = nil -- the round this game has started its song for, or is waiting to: "lobby:round"

-- the folder of a song this game has, or nil
local function MapPath(MapID: string): string?
	if MapID == "" or string.find(MapID, "[/\\]") then
		return nil
	end

	local Path = `{Constants.UserFolder}/maps/{MapID}`

	return if FileSystem.DirectoryExists(Path) then Path else nil
end

-- your lobby, while its round is starting or playing and your song in it hasn't begun
local function RoundToStart(): any?
	local Info = Versus.Mine()
	local Me = Players.LocalPlayer

	if not Info or Info.State == "Open" or Info.Round <= 0 or Info.StartAt <= 0 then
		return nil
	end

	if Me:GetAttribute("AimiaVsRound") ~= Info.Round or Me:GetAttribute("AimiaVsState") ~= "Loading" then
		return nil
	end

	return Info
end

-- Starts a round's song: the lobby's song at its speed with its modifiers, from the lobby's start. Answers whether it started.
function Versus.PlayRound(Info: any): boolean
	local Path = MapPath(Info.MapID)

	if not Path then
		warn("[AIMIA VS] this game doesn't have the round's song: " .. tostring(Info.MapID))

		return false
	end

	local Mods, Camera = Versus.Build(Info.Mods)
	-- (an older start still on its way holds Game.Play: it gets a moment to land, as in LiveSpectate)
	local Asked = os.clock()

	while Game.StartQueued and os.clock() - Asked < 3 do
		task.wait()
	end

	Game.StartQueued = false
	Game.Play({ FolderPath = Path } :: any, Info.Speed, Info.StartFrom, Camera, Mods, nil, { Lobby = Info.Id, Round = Info.Round })

	return true
end

-- A round you're in is starting: the tablet gets ready at once, and the song starts at the round's time
local function Check()
	local Info = RoundToStart()

	if not Info then
		return
	end

	local Key = Info.Id .. ":" .. Info.Round

	if Scheduled == Key then
		return
	end

	Scheduled = Key

	local Starting = Versus.Hooks.RoundStarting

	if Starting then
		local Asked, Can = pcall(Starting, Info)

		if not Asked then
			warn("[AIMIA VS] getting ready for the round: " .. tostring(Can))
		elseif Can == false then
			return
		end
	end

	task.spawn(function()
		while workspace:GetServerTimeNow() < Info.StartAt do
			task.wait()
		end

		-- (the tablet may still be putting something away: a few seconds at most, as the server waits for the song)
		local Waited = os.clock()

		while os.clock() - Waited < 8 do
			local Now = RoundToStart()

			if not Now or Now.Id .. ":" .. Now.Round ~= Key then
				return
			end

			local Ready = Versus.Hooks.Ready
			local Asked, Can = true, true

			if Ready then
				Asked, Can = pcall(Ready)
			end

			if Asked and Can then
				local Played, Why = pcall(Versus.PlayRound, Now)

				if not Played then
					warn("[AIMIA VS] starting the round's song: " .. tostring(Why))
				end

				return
			end

			task.wait(0.1)
		end
	end)
end

local CheckQueued = false

local function Changed()
	Versus.Version += 1

	if not CheckQueued then
		CheckQueued = true

		task.defer(function()
			CheckQueued = false

			local Ok, Why = pcall(Check)

			if not Ok then
				warn("[AIMIA VS] " .. tostring(Why))
			end
		end)
	end
end

-- Following ---------------------------------------------------------------------------------------------------------------

local Links: { [Instance]: RBXScriptConnection } = {}

local function Unfollow(Object: Instance)
	local Link = Links[Object]

	if Link then
		Link:Disconnect()
		Links[Object] = nil
	end
end

local function FollowLobby(Folder: Instance)
	if not Links[Folder] then
		Links[Folder] = Folder.AttributeChanged:Connect(Changed)
	end
end

local function FollowPlayer(Who: Player)
	if not Links[Who] then
		Links[Who] = Who.AttributeChanged:Connect(function(Name: string)
			if Watched[Name] then
				Changed()
			end
		end)
	end
end

for _, Who in Players:GetPlayers() do
	FollowPlayer(Who)
end

Players.PlayerAdded:Connect(function(Who: Player)
	FollowPlayer(Who)
	Changed()
end)

Players.PlayerRemoving:Connect(function(Who: Player)
	Unfollow(Who)
	Changed()
end)

task.spawn(function()
	local Folder = ReplicatedStorage:WaitForChild("AimiaVsLobbies", math.huge)

	for _, Child in Folder:GetChildren() do
		FollowLobby(Child)
	end

	Folder.ChildAdded:Connect(function(Child: Instance)
		FollowLobby(Child)
		Changed()
	end)
	Folder.ChildRemoved:Connect(function(Child: Instance)
		Unfollow(Child)
		Shown[Child.Name] = nil
		Changed()
	end)
	Changed()
end)

-- A round's song sends its numbers while it plays, four times a second at most and only when they changed (the server
-- checks each against the song).
local SentFor: any = nil
local SentAt, Sent = 0, ""

RunService.Heartbeat:Connect(function()
	local Attempt: any = Game.Attempt

	if not Attempt or not Attempt.Versus or Attempt.IsReplay or Attempt.Stopped then
		return
	end

	if SentFor ~= Attempt then
		SentFor, Sent, SentAt = Attempt, "", 0
	end

	local Now = os.clock()

	if Now - SentAt < 0.25 then
		return
	end

	local Score = math.max(0, math.floor(Finite(Attempt.Score, 0)))
	local Hits = math.max(0, math.floor(Finite(Attempt.Hits, 0)))
	local Misses = math.max(0, math.floor(Finite(Attempt.Misses, 0)))
	local Combo = math.max(0, math.floor(Finite(Attempt.Combo, 0)))
	local Text = `{Score},{Hits},{Misses},{Combo}`

	if Text ~= Sent then
		SentAt, Sent = Now, Text
		Send("Score", Score, Hits, Misses, Combo)
	end
end)

return Versus
