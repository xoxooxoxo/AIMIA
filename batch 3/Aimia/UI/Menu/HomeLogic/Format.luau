--!strict
--!optimize 2

--[[
	The .NET text the home menu writes: String.Format with "{n}" items ("{{" and "}}" are braces), int.ToString() and
	the "F2" format of a double.

	Design Notes
		Fixed is printf's "%.2f": it rounds the exact binary value and ties to even, as .NET's "F2" does (checked with
		the .NET 10 oracle, external/Oracle/Cases/HomeLogic.cs: 0.125 -> 0.12, 99.995 -> 100.00).
		Integer is "%d", so counts above 1e14 keep every digit (tostring switches to an exponent).
		Only plain "{n}" items are supported; a format specifier ("{0:F2}") raises.
]]

const function Format(Template: string, Arguments: { string }): string
	const Parts: { string } = {}
	local Position = 1

	while true do
		const Start = string.find(Template, "[{}]", Position)

		if not Start then
			table.insert(Parts, string.sub(Template, Position))

			break
		end

		table.insert(Parts, string.sub(Template, Position, Start - 1))

		const Brace = string.sub(Template, Start, Start)

		if string.sub(Template, Start + 1, Start + 1) == Brace then
			table.insert(Parts, Brace)

			Position = Start + 2
		elseif Brace == "}" then
			error("Input string was not in a correct format.", 2)
		else
			const Close = string.find(Template, "}", Start, true)
			const Index = if Close then tonumber(string.sub(Template, Start + 1, Close - 1)) else nil

			if Index == nil or Index < 0 or Index // 1 ~= Index or Index >= #Arguments then
				error("Index (zero based) must be greater than or equal to zero and less than the size of the argument list.", 2)
			end

			table.insert(Parts, Arguments[Index + 1])

			Position = (Close :: number) + 1
		end
	end

	return table.concat(Parts)
end

const function Fixed(Value: number, Digits: number): string
	return string.format(`%.{Digits}f`, Value)
end

const function Integer(Value: number): string
	return string.format("%d", Value)
end

return {
	Format = Format,
	Fixed = Fixed,
	Integer = Integer,
}
