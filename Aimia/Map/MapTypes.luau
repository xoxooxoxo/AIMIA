--!strict
--!optimize 2

--[[
	The Map object's type (scripts/map/Map.cs), shared by Map, MapCache, MapManager and their users. It lives apart from
	Map.luau because Map requires MapManager and MapCache, which need the type too (a require cycle otherwise).
]]

const Note = require("./Objects/Note")

export type Map = {
	Id: number,
	Name: string,
	CacheVersion: number?,
	LastModifiedMetadata: string?,
	LastModifiedNotes: string?,
	MetadataObjectHash: string?,
	Collection: string,
	MapSet: unknown?,
	FolderPath: string,
	Favorite: boolean,
	Ephemeral: boolean,
	Artist: string,
	ArtistLink: string,
	ArtistPlatform: string,
	Title: string,
	PrettyTitle: string,
	Rating: number,
	CachedMappers: string,
	Mappers: { string },
	PrettyMappers: string,
	DifficultyName: string,
	Difficulty: number,
	Length: number,
	AudioBuffer: buffer?,
	AudioExt: string,
	PlayCount: number,
	Cover: unknown?,
	Audio: unknown?,
	CoverBuffer: buffer?,
	VideoBuffer: buffer?,
	Notes: { Note.Note }?,
}

return {}
