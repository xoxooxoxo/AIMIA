--!optimize 2

--[[
	The song lists from the host game's server: the top runs of each song by points. The host sets Hooks.Fetch (asks the
	server for every list) and passes pushed changes to Receive. Rows are keyed by MapID (Map.Name).

	Row: { UserId, Name (username), DisplayName, Points, Score, Misses, Hits, Accuracy, Speed, Mods ("_" joined), At (os.time) }
]]

local Signal = require("../Util/Signal")

local OnlineBoard = {
	Hooks = {
		Fetch = nil :: (() -> { [string]: { any } }?)?,
		-- a listed run's replay file, compressed (MapID, UserId, At): the bytes (and its player's look when it was saved with
		-- one), or nil and why
		FetchReplay = nil :: ((string, number, number) -> (buffer?, string?, { [string]: unknown }?))?,
	},
	-- the last few runs that could be listed, by their token (Game/LiveSpectate): { Path (the run's replay file), Look
	-- (LiveSpectate.SharedOf) }. A run's replay goes up while its song plays; when that wasn't all of it the server asks for
	-- the whole file by the run's token (the host answers: Client.Controllers.Handheld), so one run's file never stands in
	-- for another's.
	Runs = {} :: { [string]: { Path: string, Look: { [string]: unknown }? } },
	RunOrder = {} :: { string },
	Rows = {} :: { [string]: { any } },
	-- whether a list has ever arrived, and whether the last ask failed with nothing to show
	Loaded = false,
	Failed = false,
	-- fired with the MapID that changed, or nil for all of them
	Changed = Signal.New(),
}

local Asking = false

-- Keeps a run that could be listed in mind: the last KeptRuns of them (their files are small, and the server asks at once).
local KeptRuns = 4

function OnlineBoard.KeepRun(Token: string, Path: string, Look: { [string]: unknown }?)
	if not OnlineBoard.Runs[Token] then
		table.insert(OnlineBoard.RunOrder, Token)

		if #OnlineBoard.RunOrder > KeptRuns then
			OnlineBoard.Runs[table.remove(OnlineBoard.RunOrder, 1) :: string] = nil
		end
	end

	OnlineBoard.Runs[Token] = { Path = Path, Look = Look }
end

-- Asks for every list. Yields; a failed answer keeps what was there.
function OnlineBoard.Refresh()
	local Fetch = OnlineBoard.Hooks.Fetch

	if not Fetch or Asking then
		return
	end

	Asking = true

	local Answered, Value = pcall(Fetch)

	Asking = false

	if Answered and type(Value) == "table" then
		for Id, Rows in Value do
			if type(Id) == "string" and type(Rows) == "table" then
				OnlineBoard.Rows[Id] = Rows
			end
		end

		OnlineBoard.Loaded = true
		OnlineBoard.Failed = false
	elseif not OnlineBoard.Loaded then
		OnlineBoard.Failed = true
	end

	Signal.Fire(OnlineBoard.Changed, nil)
end

function OnlineBoard.Receive(Id: unknown, Rows: unknown)
	if type(Id) == "string" and type(Rows) == "table" then
		OnlineBoard.Rows[Id] = Rows :: { any }
		OnlineBoard.Loaded = true
		Signal.Fire(OnlineBoard.Changed, Id)
	end
end

return OnlineBoard
