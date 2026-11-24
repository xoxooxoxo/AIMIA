--!strict
--!optimize 2

--[[
	LineEdit's max_length rule (Godot line_edit.cpp: an edit that passes the limit is cut to it), Roblox-free.

	Design Notes
		The length counts characters (UTF-8 code points, as Godot counts them). Text that is not valid UTF-8 is not cut.
]]

-- The text cut to MaxLength characters; 0 (or less) means no limit.
const function TextLimit(Text: string, MaxLength: number): string
	if MaxLength <= 0 then
		return Text
	end

	const Length = utf8.len(Text)

	if Length == nil or Length <= MaxLength then
		return Text
	end

	const Cut = utf8.offset(Text, MaxLength + 1)

	return if Cut then string.sub(Text, 1, Cut - 1) else Text
end

return TextLimit
