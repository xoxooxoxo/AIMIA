--!strict
--!optimize 2

--[[
	MapSet.cs: the maps of one folder. Artist and Title are the first map's (Maps.First()).

	Design Notes
		An empty set errors as LINQ First() does ("Sequence contains no elements"). The Mappers property is commented out
		upstream and is not ported.
]]

const Map = require("./Map")

export type MapSet = {
	Directory: string?,
	Maps: { Map.Map }?,
}

-- @src scripts/map/MapSet.cs:MapSet L7-17
const function New(Directory: string?, Maps: { Map.Map }?): MapSet
	return {
		Directory = Directory,
		Maps = Maps,
	}
end

const function FirstMap(Set: MapSet): Map.Map
	const Maps = Set.Maps :: { Map.Map }

	if #Maps == 0 then
		error("Sequence contains no elements", 0)
	end

	return Maps[1]
end

-- @src scripts/map/MapSet.cs:Artist L13-13
const function GetArtist(Set: MapSet): string
	return FirstMap(Set).Artist
end

-- @src scripts/map/MapSet.cs:Title L15-15
const function GetTitle(Set: MapSet): string
	return FirstMap(Set).Title
end

return {
	New = New,
	GetArtist = GetArtist,
	GetTitle = GetTitle,
}
