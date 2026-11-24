--!strict
--!optimize 2

--[[
	Chaos: each note is pushed in a direction and distance taken from Godot's FastNoiseLite 3D noise, sampled at the note
	position and the playback time (scripts/game/modifiers/ChaosModifier.cs).

	Owned State
		Noise is FastNoiseLite with Godot's defaults. Sampling only reads its configuration, so one noise serves every
		Chaos modifier, as each C# instance (its own default noise) computes the same values.
]]

const Numbers = require("../../Numbers")
const Color = require("../../Godot/Color")
const FastNoiseLite = require("../../Godot/FastNoiseLite")
const Math = require("../../Godot/Math")
const Modifier = require("./Modifier")

const Noise = FastNoiseLite.New()

-- @src scripts/game/modifiers/ChaosModifier.cs:ModifyRenderObject L16-29
const function ModifyRenderObject(Note: Modifier.Note, Attempt: Modifier.Attempt)
	const Depth = math.max(0, -Note.Transform.Origin.z)

	if Depth > 0 then
		const NoiseX = Numbers.F32(Note.X * 2)
		const NoiseY = Numbers.F32(Note.Y * 2)
		const Time = Numbers.F32(Attempt.Progress / Attempt.Speed / 400)
		const NoiseZ = Numbers.F32(Numbers.F32(Note.Index) + Time)
		const Value = FastNoiseLite.GetNoise3D(Noise, NoiseX, NoiseY, NoiseZ)
		const Angle = Numbers.F32(Numbers.F32(Value * Math.Pi) * 4)
		const Direction = Math.Rotated(Math.Up, Math.Back, Angle)
		const ApproachDistance = Numbers.F32(Attempt.Settings.ApproachDistance.Value)
		const Ratio = Numbers.F32(Depth / ApproachDistance)
		const Offset = Numbers.F32(math.pow(Ratio, 2))

		Note.Transform.Origin += Direction * Offset
	end
end

-- @src scripts/game/modifiers/ChaosModifier.cs:ChaosModifier L4-30
const function New(): Modifier.Modifier
	const Mod = Modifier.New("Chaos", Color.FromRgba(0xff6198ff))

	Mod.Rankable = true
	Mod.ScoreMultiplier = 1.015
	Mod.ModifyRenderObject = ModifyRenderObject

	return Mod
end

return New
