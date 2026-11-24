--!strict
--!optimize 2

--[[
	Player.cs: a lobby member (the local player, and any networked one once networking is ported).
]]

export type Player = {
	Name: string,
	Ready: boolean,
}

-- @src scripts/multiplayer/Player.cs:Player L1-5
const function New(Name: string?): Player
	return {
		Name = Name or "Player",
		Ready = false,
	}
end

-- @src scripts/multiplayer/Player.cs:ToString L6-6
const function ToString(Value: Player): string
	return Value.Name
end

return {
	New = New,
	ToString = ToString,
}
