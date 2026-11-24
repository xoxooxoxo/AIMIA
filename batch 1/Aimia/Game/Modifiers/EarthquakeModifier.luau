--!strict
--!optimize 2

--[[
	Earthquake: each note is pushed a random distance in a random direction, unseeded as the upstream System.Random
	(scripts/game/modifiers/EarthquakeModifier.cs).

	Design Notes
		Random angles are whole degrees in [-180, 179]: System.Random.Next(-180, 180) excludes the upper bound.
]]

const Numbers = require("../../Numbers")
const Color = require("../../Godot/Color")
const Math = require("../../Godot/Math")
const Modifier = require("./Modifier")

-- Mathf.Pi / 180 as a float32 value (the C# constant is float).
const DegreeToRadian = Numbers.F32(Math.Pi / 180)

-- @src scripts/game/modifiers/EarthquakeModifier.cs:ModifyRenderObject L16-29
const function ModifyRenderObject(Note: Modifier.Note, Attempt: Modifier.Attempt)
	const Depth = math.max(0, -Note.Transform.Origin.z)

	if Depth > 0 then
		const Radian = Numbers.F32(math.random(-180, 179) * DegreeToRadian)
		const Direction = Math.Rotated(Math.Up, Math.Back, Radian)
		const ApproachDistance = Numbers.F32(Attempt.Settings.ApproachDistance.Value)
		const Ratio = Numbers.F32(Depth / ApproachDistance)
		const Offset = Numbers.F32(Numbers.F32(math.pow(Ratio, 1.5)) / 2)

		Note.Transform.Origin += Direction * Offset
	end
end

-- @src scripts/game/modifiers/EarthquakeModifier.cs:EarthquakeModifier L4-30
const function New(): Modifier.Modifier
	const Mod = Modifier.New("Earthquake", Color.FromRgba(0xff4400ff))

	Mod.Rankable = true
	Mod.ScoreMultiplier = 1.01
	Mod.ModifyRenderObject = ModifyRenderObject

	return Mod
end

return New
