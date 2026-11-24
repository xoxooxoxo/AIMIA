--!strict
--!optimize 2

--[[
	The shader material of a node (its ShaderMaterial's shader and parameters) and the values a parameter reads, Roblox-free.

	Design Notes
		A parameter is the node's override (Godot's "material:shader_parameter/<Name>" property, set by Nodes.SetShaderParameter)
		when it has one, else the material's own "shader_parameter/<Name>", else nil (the caller's default).
		Keys are cached per name, so a per-frame read or write builds no string.
		Colors are { Color = {...} } or a Vector3/Vector4 constructor; Vector2s are { Vector2 = {...} }, a vector, or a
		Vector2 constructor. The Write functions fill a destination table and answer false for a value of another form.
]]

export type Material = {
	Path: string?,
	Code: string?,
	Parameters: { [string]: unknown },
	Overrides: { [string]: unknown },
}

const OverridePrefix = "material:shader_parameter/"
const ParameterPrefix = "shader_parameter/"

const OverrideKeys: { [string]: string } = {}
const ParameterKeys: { [string]: string } = {}

-- The node property that overrides a shader parameter.
const function OverrideKey(Name: string): string
	local Key = OverrideKeys[Name]

	if not Key then
		Key = `{OverridePrefix}{Name}`
		OverrideKeys[Name] = Key
	end

	return Key
end

-- The material's own key of a shader parameter.
const function ParameterKey(Name: string): string
	local Key = ParameterKeys[Name]

	if not Key then
		Key = `{ParameterPrefix}{Name}`
		ParameterKeys[Name] = Key
	end

	return Key
end

-- The override of a parameter when the node sets one, else the material's value, else nil.
const function Parameter(Material: Material, Name: string): unknown
	const Override = Material.Overrides[OverrideKey(Name)]

	if Override ~= nil then
		return Override
	end

	return Material.Parameters[ParameterKey(Name)]
end

-- A number value, or Default.
const function NumberOf(Value: unknown, Default: number): number
	return if type(Value) == "number" then Value else Default
end

-- Writes an RGBA color (four components; alpha 1 when the value has none) into Destination; false when Value is no color.
const function WriteColor(Value: unknown, Destination: { number }): boolean
	if type(Value) == "table" then
		const Color = (Value :: { Color: { number }? }).Color

		if Color then
			Destination[1] = Color[1]
			Destination[2] = Color[2]
			Destination[3] = Color[3]
			Destination[4] = Color[4] or 1

			return true
		end

		const Constructor = Value :: { Constructor: string?, Arguments: { number }? }

		if Constructor.Arguments and (Constructor.Constructor == "Vector3" or Constructor.Constructor == "Vector4") then
			const Arguments = Constructor.Arguments

			Destination[1] = Arguments[1]
			Destination[2] = Arguments[2]
			Destination[3] = Arguments[3]
			Destination[4] = Arguments[4] or 1

			return true
		end
	end

	return false
end

-- Writes an x, y pair into Destination; false when Value is no Vector2.
const function WriteVector2(Value: unknown, Destination: { number }): boolean
	if type(Value) == "vector" then
		Destination[1] = (Value :: vector).x
		Destination[2] = (Value :: vector).y

		return true
	end

	if type(Value) == "table" then
		const Pair = (Value :: { Vector2: { number }? }).Vector2

		if Pair then
			Destination[1] = Pair[1]
			Destination[2] = Pair[2]

			return true
		end

		const Constructor = Value :: { Constructor: string?, Arguments: { number }? }

		if Constructor.Arguments and Constructor.Constructor == "Vector2" then
			Destination[1] = Constructor.Arguments[1]
			Destination[2] = Constructor.Arguments[2]

			return true
		end
	end

	return false
end

-- An RGBA color of a value (a new table), or Default.
const function ColorOf(Value: unknown, Default: { number }): { number }
	const Color = { 0, 0, 0, 1 }

	if WriteColor(Value, Color) then
		return Color
	end

	return Default
end

return {
	OverrideKey = OverrideKey,
	ParameterKey = ParameterKey,
	Parameter = Parameter,
	NumberOf = NumberOf,
	WriteColor = WriteColor,
	WriteVector2 = WriteVector2,
	ColorOf = ColorOf,
}
