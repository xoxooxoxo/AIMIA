--!strict
--!optimize 2

--[[
	In-memory tables standing in for the SQLite connection of scripts/database/DatabaseService.cs.

	Design Notes
		A table keeps one stored copy per row: the object's fields except the Ignored ones, as SQLite stores only
		properties without [Ignore]. Insert, Update and InsertOrReplace copy the object in, so a change to the object
		reaches the table only through a later write. Reads materialize a new object, as SQLite does: New() builds it
		with the constructor's defaults (ignored fields keep those), then the stored fields are copied over. A nil field
		is not stored, so it reads back as New() gives it (nil where C# is null).
		AutoIncrement tables take Id = last issued Id + 1 on Insert and set it on the object, whatever Id it had; a
		deleted Id is not reused (SQLite AUTOINCREMENT). Keys keeps the rows in insertion order, which is Id order for
		those tables.
		Find and Get test the stored copies, so a predicate reads columns only, as a SQL WHERE does; only the rows
		returned are materialized.
		DEVIATION(platform): the Node lifecycle (_Ready opens data.db with Batteries.Init, _ExitTree disposes it) has no
		in-memory equivalent. The tables exist once their owner creates them, and the session keeps them; a table is
		not written to disk here (Database/Stats writes its row to a file).
]]

export type Key = number | string

-- A stored row: the fields of the object except the ignored ones.
export type Fields = { [string]: unknown }

export type Table<T> = {
	Name: string,
	New: () -> T,
	Ignored: { [string]: boolean },
	AutoIncrement: boolean,
	LastId: number,
	Keys: { Key },
	Rows: { [Key]: Fields },
}

-- The stored copy of Row: every field except the ignored ones.
const function ToFields<T>(Table: Table<T>, Row: T): Fields
	const Source = Row :: Fields
	const Copy: Fields = {}

	for Field, Value in Source do
		if not Table.Ignored[Field] then
			Copy[Field] = Value
		end
	end

	return Copy
end

-- The object a read answers: New() with the stored fields copied over.
const function FromFields<T>(Table: Table<T>, Stored: Fields): T
	const Row = Table.New()
	const Target = Row :: Fields

	for Field, Value in Stored do
		Target[Field] = Value
	end

	return Row
end

-- Writes Stored under its Id: replaces the row with that Id, or adds it after the others.
const function Put<T>(Table: Table<T>, Stored: Fields)
	const Key = Stored.Id :: Key

	if Table.Rows[Key] == nil then
		table.insert(Table.Keys, Key)
	end

	if Table.AutoIncrement and type(Key) == "number" and Key > Table.LastId then
		Table.LastId = Key
	end

	Table.Rows[Key] = Stored
end

-- CREATE TABLE. New builds an object with the constructor's defaults; Ignored names the fields that are not stored.
const function CreateTable<T>(Name: string, New: () -> T, Ignored: { string }, AutoIncrement: boolean): Table<T>
	const IgnoredFields: { [string]: boolean } = {}

	for _, Field in Ignored do
		IgnoredFields[Field] = true
	end

	return {
		Name = Name,
		New = New,
		Ignored = IgnoredFields,
		AutoIncrement = AutoIncrement,
		LastId = 0,
		Keys = {},
		Rows = {},
	}
end

-- INSERT. An AutoIncrement table assigns the Id (the object's Id is set to it); any other table rejects a duplicate Id.
const function Insert<T>(Table: Table<T>, Row: T)
	const Stored = ToFields(Table, Row)

	if Table.AutoIncrement then
		Table.LastId += 1
		Stored.Id = Table.LastId

		const Target = Row :: Fields

		Target.Id = Table.LastId
	elseif Table.Rows[Stored.Id :: Key] ~= nil then
		error(`UNIQUE constraint failed: {Table.Name}.Id`, 0)
	end

	Put(Table, Stored)
end

-- UPDATE by Id. A row that is not there is left alone (SQLite changes no row).
const function Update<T>(Table: Table<T>, Row: T)
	const Stored = ToFields(Table, Row)

	if Table.Rows[Stored.Id :: Key] ~= nil then
		Put(Table, Stored)
	end
end

-- INSERT OR REPLACE.
const function InsertOrReplace<T>(Table: Table<T>, Row: T)
	Put(Table, ToFields(Table, Row))
end

-- DELETE by Id. A row that is not there is left alone.
const function Delete<T>(Table: Table<T>, Row: T?)
	-- sqlite-net reads the null row's type first: a NullReferenceException.
	if Row == nil then
		error("Object reference not set to an instance of an object.", 2)
	end

	const Key = (Row :: Fields).Id :: Key

	if Table.Rows[Key] == nil then
		return
	end

	Table.Rows[Key] = nil

	for Index, Other in Table.Keys do
		if Other == Key then
			table.remove(Table.Keys, Index)

			return
		end
	end
end

-- Table.Where(Predicate).FirstOrDefault(): the first row in order that matches, or nil.
const function Find<T>(Table: Table<T>, Predicate: (Fields) -> boolean): T?
	for _, Key in Table.Keys do
		const Stored = Table.Rows[Key]

		if Predicate(Stored) then
			return FromFields(Table, Stored)
		end
	end

	return nil
end

-- Table.Where(Predicate).First(): the first matching row; an error when none matches.
const function Get<T>(Table: Table<T>, Predicate: (Fields) -> boolean): T
	const Row = Find(Table, Predicate)

	if Row == nil then
		error("Sequence contains no elements", 0)
	end

	return Row
end

-- Find(Key): the row with that primary key, or nil.
const function FindKey<T>(Table: Table<T>, Key: Key): T?
	const Stored = Table.Rows[Key]

	if Stored == nil then
		return nil
	end

	return FromFields(Table, Stored)
end

-- Table<T>(): every row, in Keys order.
const function All<T>(Table: Table<T>): { T }
	const Rows: { T } = {}

	for _, Key in Table.Keys do
		table.insert(Rows, FromFields(Table, Table.Rows[Key]))
	end

	return Rows
end

return {
	CreateTable = CreateTable,
	Insert = Insert,
	Update = Update,
	InsertOrReplace = InsertOrReplace,
	Delete = Delete,
	Find = Find,
	Get = Get,
	FindKey = FindKey,
	All = All,
	ToFields = ToFields,
	FromFields = FromFields,
}
