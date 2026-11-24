--!strict
--!optimize 2

--[[
	Godot RichTextLabel BBCode to Roblox rich text markup, Roblox-free.

	Design Notes
		Tags: [b] [i] [u] [s] [color=...] [font_size=N] [code] [url] [br] [lb] [rb] [p] [center] [right] [left]
		[fill] [img] [font] [outline_*] [bgcolor] [fgcolor] [indent] [ul] [ol] [table] [cell] [wave] [shake] and
		the other effect tags. Roblox rich text has no per-paragraph alignment: the first alignment tag sets the
		whole label's alignment (answered as the second value). [font_size] and [color] that Godot leaves open to
		the end of the text are closed at the end, as Godot does implicitly. Images, effects, lists and tables
		keep their text without the effect. Text outside tags is escaped for Roblox (& < > " ').
]]

const Escapes = {
	["&"] = "&amp;",
	["<"] = "&lt;",
	[">"] = "&gt;",
	["\""] = "&quot;",
	["'"] = "&apos;",
}

const NamedColors = {
	["white"] = "#ffffff",
	["black"] = "#000000",
	["red"] = "#ff0000",
	["green"] = "#00ff00",
	["blue"] = "#0000ff",
	["yellow"] = "#ffff00",
	["gray"] = "#bebebe",
	["grey"] = "#bebebe",
	["aqua"] = "#00ffff",
	["cyan"] = "#00ffff",
	["magenta"] = "#ff00ff",
	["orange"] = "#ffa500",
	["purple"] = "#a020f0",
	["pink"] = "#ffc0cb",
	["lime"] = "#00ff00",
	["transparent"] = "#000000",
}

const Simple = {
	["b"] = "b",
	["i"] = "i",
	["u"] = "u",
	["s"] = "s",
	["url"] = "u",
}

const function Escape(Text: string): string
	return (string.gsub(Text, "[&<>\"']", Escapes))
end

-- Godot color arguments: a name, "#rgb", "#rgba", "#rrggbb", "#rrggbbaa", or the same without "#". Answers the
-- Roblox font attributes: color, plus transparency when the alpha is below 1.
const function ColorArgument(Value: string): string
	const Lower = string.lower(Value)
	const Named = (NamedColors :: { [string]: string })[Lower]

	if Named then
		return `color="{Named}"`
	end

	local Hex = if string.sub(Lower, 1, 1) == "#" then string.sub(Lower, 2) else Lower

	if #Hex == 3 or #Hex == 4 then
		Hex = string.gsub(Hex, ".", "%0%0")
	end

	const Alpha = if #Hex == 8 then tonumber(string.sub(Hex, 7, 8), 16) else nil
	const Color = `color="#{string.sub(Hex, 1, 6)}"`

	if Alpha and Alpha < 255 then
		return `{Color} transparency="{string.format("%.3f", 1 - Alpha / 255)}"`
	end

	return Color
end

-- SizeFactor is the Roblox TextSize of a font size of 1 (Style.TextSizeOf): [font_size] is Godot's, in ems. Roblox takes a whole size.
const function ToRichText(Source: string, SizeFactorOrNil: number?): (string, string?)
	const SizeFactor = SizeFactorOrNil or 1
	const Parts: { string } = {}
	const Open: { string } = {}
	local Alignment: string? = nil
	local Position = 1

	while Position <= #Source do
		const Start, Finish, Tag = string.find(Source, "%[([^%[%]]*)%]", Position)

		if not Start then
			table.insert(Parts, Escape(string.sub(Source, Position)))
			break
		end

		table.insert(Parts, Escape(string.sub(Source, Position, (Start :: number) - 1)))
		Position = (Finish :: number) + 1

		const Body = Tag :: string
		const Closing = string.sub(Body, 1, 1) == "/"
		const Name = string.lower(string.match(Body, "^/?([%w_]+)") or "")
		const Argument = string.match(Body, "^[%w_]+=(.*)$")

		if Name == "lb" then
			table.insert(Parts, "[")
		elseif Name == "rb" then
			table.insert(Parts, "]")
		elseif Name == "br" then
			table.insert(Parts, "\n")
		elseif Name == "center" or Name == "right" or Name == "left" or Name == "fill" then
			if not Closing and not Alignment then
				Alignment = Name
			end
		elseif Name == "img" and not Closing then
			-- The image path is the tag's content up to [/img]; it is dropped.
			const Close = string.find(Source, "[/img]", Position, true)

			Position = if Close then Close + 6 else #Source + 1
		elseif (Simple :: { [string]: string })[Name] or Name == "color" or Name == "font_size" or Name == "code" then
			const Roblox = (Simple :: { [string]: string })[Name] or "font"

			if Closing then
				for Index = #Open, 1, -1 do
					if Open[Index] == Name then
						for Inner = #Open, Index, -1 do
							const Kind = Open[Inner]

							table.insert(Parts, `</{(Simple :: { [string]: string })[Kind] or "font"}>`)
							table.remove(Open, Inner)
						end

						break
					end
				end
			else
				if Name == "color" and Argument then
					table.insert(Parts, `<font {ColorArgument(Argument)}>`)
				elseif Name == "font_size" and Argument then
					table.insert(Parts, `<font size="{math.round((tonumber(Argument) or 16) * SizeFactor)}">`)
				elseif Name == "code" then
					table.insert(Parts, `<font family="rbxasset://fonts/families/RobotoMono.json">`)
				else
					table.insert(Parts, `<{Roblox}>`)
				end

				table.insert(Open, Name)
			end
		elseif Name == "p" and Closing then
			table.insert(Parts, "\n")
		elseif Name == "" or not string.match(Name, "^[%w_]+$") then
			-- Not a tag: Godot shows it as text.
			table.insert(Parts, Escape(`[{Body}]`))
		end
	end

	for Index = #Open, 1, -1 do
		table.insert(Parts, `</{(Simple :: { [string]: string })[Open[Index]] or "font"}>`)
	end

	return table.concat(Parts), Alignment
end

-- The text without markup (Godot's get_parsed_text), for measuring and plain labels.
const function StripTags(Source: string): string
	const Text = string.gsub(Source, "%[img[^%]]*%].-%[/img%]", "")
	const Stripped = string.gsub(Text, "%[(/?[%w_]+)[^%[%]]*%]", function(Tag: string): string
		const Name = string.lower(Tag)

		if Name == "lb" then
			return "["
		elseif Name == "rb" then
			return "]"
		elseif Name == "br" then
			return "\n"
		end

		return ""
	end)

	return Stripped
end

return {
	ToRichText = ToRichText,
	StripTags = StripTags,
}
