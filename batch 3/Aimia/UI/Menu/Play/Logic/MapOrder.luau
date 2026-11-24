--!strict
--!optimize 2

--[[
	The map order of MapList (scripts/ui/menu/play/MapList.cs): the search filter, the sort by title, difficulty or mappers, the
	descending order, favorites first, the shuffle, and the sort type names SortMenuButton parses. Roblox-free.

	Design Notes
		LINQ OrderBy is stable: the sort is Numbers.StableSort, so equal keys keep their order. Descending reverses the whole
		sorted list (MapList.Sort calls Reverse), so equal keys come out reversed too.
		DEVIATION(culture): titles and mappers are compared ordinally (the bytes of the UTF-8 text), as MapCache does, and the
		search ignores case for ASCII letters only: Roblox has no culture-aware comparison.
		Shuffle takes the random source Random(Min, Max), answering an integer in [Min, Max]; the source's order is not
		reproducible either way.
]]

const Numbers = require("../../../../Numbers")
const DotnetString = require("../../../../Dotnet/String")
const MapTypes = require("../../../../Map/MapTypes")

export type Map = MapTypes.Map

-- MapList.SortType: by title, by difficulty, or by the first mapper.
const SortType = {
	Alphabetical = 0,
	Difficulty = 1,
	Mappers = 2,
}

-- Enum.TryParse<SortType>(name, ignoreCase): the sort type named by a button, or nil.
-- @src scripts/ui/menu/play/SortMenuButton.cs:selectSort L62-72
const function ParseSortType(Name: string): number?
	const Wanted = string.lower(Name)

	if Wanted == "alphabetical" then
		return SortType.Alphabetical
	elseif Wanted == "difficulty" then
		return SortType.Difficulty
	elseif Wanted == "mappers" then
		return SortType.Mappers
	end

	return nil
end

-- String.Contains(Part, CurrentCultureIgnoreCase): an empty part is always contained.
-- @src scripts/ui/menu/play/MapList.cs:UpdateMaps L498-523
-- DEVIATION(culture): ASCII letters only (string.lower).
const function Contains(Text: string, Part: string): boolean
	return string.find(string.lower(Text), string.lower(Part), 1, true) ~= nil
end

-- The maps with the favorites first, each group in its order (MapList.UpdateMaps and MapList.Sort).
-- @src scripts/ui/menu/play/MapList.cs:Sort L453-488
const function FavoritesFirst(Maps: { Map }): { Map }
	const Result: { Map } = {}

	for _, Map in Maps do
		if Map.Favorite then
			table.insert(Result, Map)
		end
	end

	for _, Map in Maps do
		if not Map.Favorite then
			table.insert(Result, Map)
		end
	end

	return Result
end

-- The maps whose title contains SearchQuery and whose mappers contain AuthorQuery, favorites first.
-- @src scripts/ui/menu/play/MapList.cs:UpdateMaps L498-523
const function Filter(All: { Map }, SearchQuery: string, AuthorQuery: string): { Map }
	const Queried: { Map } = {}

	for _, Map in All do
		if Contains(Map.PrettyTitle, SearchQuery) and Contains(Map.PrettyMappers, AuthorQuery) then
			table.insert(Queried, Map)
		end
	end

	return FavoritesFirst(Queried)
end

-- The mapper that orders a map: the least of its mappers. A map without mappers takes its PrettyMappers split at ", ".
-- @src scripts/ui/menu/play/MapList.cs:Sort L453-488
const function FirstMapper(Map: Map): string
	const Mappers = if #Map.Mappers == 0 then DotnetString.Split(Map.PrettyMappers, ", ") else Map.Mappers
	local First = Mappers[1]

	for _, Mapper in Mappers do
		if Mapper < First then
			First = Mapper
		end
	end

	return First
end

-- @src scripts/ui/menu/play/MapList.cs:Sort L453-488
const function TitleOf(Map: Map): string
	return Map.PrettyTitle
end

-- @src scripts/ui/menu/play/MapList.cs:Sort L453-488
const function DifficultyOf(Map: Map): number
	return Map.Difficulty
end

-- Orders the maps by key (stable), reversed when descending (List.Reverse after OrderBy).
-- @src scripts/ui/menu/play/MapList.cs:Sort L453-488
const function OrderBy<K>(Maps: { Map }, KeyOf: (Map) -> K, Less: (K, K) -> boolean, Ascending: boolean): { Map }
	const Keyed: { { Key: K, Map: Map } } = {}

	for _, Map in Maps do
		table.insert(Keyed, { Key = KeyOf(Map), Map = Map })
	end

	Numbers.StableSort(Keyed, function(First: { Key: K, Map: Map }, Second: { Key: K, Map: Map }): boolean
		return Less(First.Key, Second.Key)
	end)

	const Result: { Map } = {}
	const Count = #Keyed

	for Index, Entry in Keyed do
		if Ascending then
			Result[Index] = Entry.Map
		else
			Result[Count - Index + 1] = Entry.Map
		end
	end

	return Result
end

-- The maps in the sort type's order (descending reverses it), favorites first.
-- @src scripts/ui/menu/play/MapList.cs:Sort L453-488
const function Order(Maps: { Map }, Sorting: number, Ascending: boolean): { Map }
	local Ordered: { Map }

	if Sorting == SortType.Difficulty then
		Ordered = OrderBy(Maps, DifficultyOf, function(First: number, Second: number): boolean
			return First < Second
		end, Ascending)
	elseif Sorting == SortType.Mappers then
		Ordered = OrderBy(Maps, FirstMapper, function(First: string, Second: string): boolean
			return First < Second
		end, Ascending)
	else
		Ordered = OrderBy(Maps, TitleOf, function(First: string, Second: string): boolean
			return First < Second
		end, Ascending)
	end

	return FavoritesFirst(Ordered)
end

-- A uniform random order (Fisher-Yates) of a copy of the maps.
-- @src scripts/ui/menu/play/MapList.cs:shuffle L634-639
const function Shuffle(Maps: { Map }, Random: (number, number) -> number): { Map }
	const Result = table.clone(Maps)

	for Index = #Result, 2, -1 do
		const Other = Random(1, Index)
		const Held = Result[Index]

		Result[Index] = Result[Other]
		Result[Other] = Held
	end

	return Result
end

-- The artist part of a title ("Camellia - Flamewall" is "camellia"; a title with no " - " is its own artist).
const function ArtistOf(Map: Map): string
	const Title = tostring(Map.PrettyTitle)
	const Dash = string.find(Title, " - ", 1, true)

	return string.lower(if Dash then string.sub(Title, 1, Dash - 1) else Title)
end

-- A random order that keeps songs by one artist apart where it can (the user's ask, 2026-11-07: Camellia is half the songs,
-- and by title they all sat together, as if there was nothing else). Each step takes an artist other than the last one at
-- random, weighted by the songs it has left, except that an artist with more songs left than all the others together goes
-- now (else two of its songs would have to touch later). Favorites stay first, each group spread on its own.
const function SpreadGroup(Group: { Map }, Random: (number, number) -> number): { Map }
	const Piles: { [string]: { Map } } = {}
	const Names: { string } = {}

	for _, Map in Shuffle(Group, Random) do
		const Name = ArtistOf(Map)

		if Piles[Name] == nil then
			Piles[Name] = {}
			table.insert(Names, Name)
		end

		table.insert(Piles[Name], Map)
	end

	const Result: { Map } = {}
	local Last: string? = nil
	local Left = #Group

	while Left > 0 do
		local Biggest: string? = nil
		local BiggestCount = 0

		for _, Name in Names do
			if #Piles[Name] > BiggestCount then
				Biggest = Name
				BiggestCount = #Piles[Name]
			end
		end

		local Pick: string? = nil

		if Biggest ~= nil and Biggest ~= Last and BiggestCount > Left - BiggestCount then
			Pick = Biggest
		else
			local Total = 0

			for _, Name in Names do
				if Name ~= Last then
					Total += #Piles[Name]
				end
			end

			if Total == 0 then
				Pick = Last
			else
				local Roll = Random(1, Total)

				for _, Name in Names do
					if Name ~= Last then
						Roll -= #Piles[Name]

						if Roll <= 0 then
							Pick = Name

							break
						end
					end
				end
			end
		end

		const Chosen = Pick :: string
		const Pile = Piles[Chosen]

		table.insert(Result, table.remove(Pile) :: Map)

		if #Pile == 0 then
			const At = table.find(Names, Chosen)

			if At then
				table.remove(Names, At)
			end
		end

		Last = Chosen
		Left -= 1
	end

	return Result
end

const function Spread(Maps: { Map }, Random: (number, number) -> number): { Map }
	const Favorites: { Map } = {}
	const Others: { Map } = {}

	for _, Map in Maps do
		table.insert(if Map.Favorite then Favorites else Others, Map)
	end

	const Result = SpreadGroup(Favorites, Random)

	for _, Map in SpreadGroup(Others, Random) do
		table.insert(Result, Map)
	end

	return Result
end

-- The 0-based place of a map (by name) in the list, -1 when it is absent (List.FindIndex).
-- @src scripts/ui/menu/play/MapList.cs:Focus L442-451
const function IndexOf(Maps: { Map }, Name: string): number
	for Index, Map in Maps do
		if Map.Name == Name then
			return Index - 1
		end
	end

	return -1
end

return {
	SortType = SortType,
	ParseSortType = ParseSortType,
	Contains = Contains,
	Filter = Filter,
	Order = Order,
	Shuffle = Shuffle,
	Spread = Spread,
	ArtistOf = ArtistOf,
	IndexOf = IndexOf,
}
