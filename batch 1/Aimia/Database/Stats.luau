--!strict
--!optimize 2

--[[
	Lifetime stats of the player, as scripts/database/Stats.cs: one row in a DatabaseService table, saved to a file.

	Design Notes
		The row has the id "_STATS". StatsUpdated is an event, not a column, so the table ignores it.
		DEVIATION(platform): the SQLite row is saved to user/stats.json (FileSystem; the file name is a port decision).
		Initialize reads that file when the table has no row yet, so stats carry over a restart once the host persists
		the file (FileSystem.Changed). A missing or unparsable file starts new stats.
		Counters are ulong upstream; they stay below 2^53 here and are plain numbers.
]]

const Constants = require("../Constants")
const DatabaseService = require("./DatabaseService")
const FileSystem = require("../Util/FileSystem")
const Json = require("../Godot/Json")
const Logger = require("../Util/Logger")
const Signal = require("../Util/Signal")

export type Stats = {
	Id: string,
	GamePlaytime: number,
	TotalPlaytime: number,
	GamesOpened: number,
	TotalDistance: number,
	NotesHit: number,
	NotesMissed: number,
	HighestCombo: number,
	Attempts: number,
	Passes: number,
	FullCombos: number,
	HighestScore: number,
	TotalScore: number,
	RageQuits: number,
	AverageAccuracy: number,
	StatsUpdated: Signal.Signal<Stats>,
}

const StatsRowId = "_STATS"
const StatsPath = FileSystem.Combine(Constants.UserFolder, "stats.json")

-- @src scripts/database/Stats.cs:Id L32-33
-- @src scripts/database/Stats.cs:GamePlaytime L35-47
-- @src scripts/database/Stats.cs:AverageAccuracy L48-48
-- @src scripts/database/Stats.cs:StatsUpdated L50-50
const function New(): Stats
	return {
		Id = StatsRowId,
		GamePlaytime = 0,
		TotalPlaytime = 0,
		GamesOpened = 0,
		TotalDistance = 0,
		NotesHit = 0,
		NotesMissed = 0,
		HighestCombo = 0,
		Attempts = 0,
		Passes = 0,
		FullCombos = 0,
		HighestScore = 0,
		TotalScore = 0,
		RageQuits = 0,
		AverageAccuracy = 0,
		StatsUpdated = Signal.New(),
	}
end

const StatsTable = DatabaseService.CreateTable("Stats", New, { "StatsUpdated" }, false)

const Stats = {
	Instance = New(),
}

-- The row saved in StatsPath, or nil when there is no file or its text is not a JSON object.
const function ReadSaved(): Stats?
	if not FileSystem.Exists(StatsPath) then
		return nil
	end

	const Parsed = Json.Parse(FileSystem.ReadAllText(StatsPath))

	if type(Parsed) ~= "table" then
		return nil
	end

	return DatabaseService.FromFields(StatsTable, Parsed :: DatabaseService.Fields)
end

-- @src scripts/database/Stats.cs:Initialize L16-30
function Stats.Initialize()
	const Found = DatabaseService.FindKey(StatsTable, StatsRowId)

	if Found then
		Stats.Instance = Found
	else
		const Created = ReadSaved() or New()

		DatabaseService.Insert(StatsTable, Created)

		Stats.Instance = Created
	end
end

-- @src scripts/database/Stats.cs:ForceUpdate L55-55
function Stats.ForceUpdate(Self: Stats)
	Signal.Fire(Self.StatsUpdated, Self)
end

-- @src scripts/database/Stats.cs:Save L57-62
function Stats.Save()
	-- The user folder is created with the first save, as the SQLite file was created in it.
	FileSystem.CreateDirectory(Constants.UserFolder)
	DatabaseService.InsertOrReplace(StatsTable, Stats.Instance)
	FileSystem.WriteAllText(StatsPath, Json.Stringify(DatabaseService.ToFields(StatsTable, Stats.Instance), "\t"))
	Logger.Log("Saved stats")
end

return Stats
