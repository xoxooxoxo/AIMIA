--!strict
--!optimize 2

--[[
	Godot node paths as segment lists, Roblox-free: "A/B", "./C" and "D/" split on "/", "." and empty segments are
	dropped, ".." is kept (the parent). UI/Nodes walks the segments over the item tree.

	Design Notes
		Join is the scene-data path join (SceneBuilder): "." is the root and joins to the other side unchanged.
]]

const function Segments(Path: string): { string }
	const Result: { string } = {}

	for Part in string.gmatch(Path, "[^/]+") do
		if Part ~= "." then
			table.insert(Result, Part)
		end
	end

	return Result
end

const function Join(Prefix: string, Local: string): string
	if Local == "." then
		return Prefix
	elseif Prefix == "." then
		return Local
	end

	return `{Prefix}/{Local}`
end

return {
	Segments = Segments,
	Join = Join,
}
