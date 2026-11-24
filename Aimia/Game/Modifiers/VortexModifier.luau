--!strict
--!optimize 2

--[[
	Vortex: notes turn about the view axis by an amount that follows the playback time, and are pulled toward the centre
	as they approach (scripts/game/modifiers/VortexModifier.cs).
]]

const Numbers = require("../../Numbers")
const Color = require("../../Godot/Color")
const Math = require("../../Godot/Math")
const Modifier = require("./Modifier")

-- @src scripts/game/modifiers/VortexModifier.cs:ModifyRenderObject L14-33
const function ModifyRenderObject(Note: Modifier.Note, Attempt: Modifier.Attempt)
	const Depth = math.max(0, -Note.Transform.Origin.z)

	if Depth > 0 then
		const ApproachDistance = Numbers.F32(Attempt.Settings.ApproachDistance.Value)
		const Ratio = Numbers.F32(Depth / ApproachDistance)

		local Rotation = Numbers.F32(Numbers.F32(math.pow(Numbers.F32(Ratio * 15), 1.5)) / 60)
		const Sine = Numbers.F32(math.sin(Attempt.Progress / Attempt.Speed / 1000 * Attempt.Settings.ApproachTime.Value))

		-- Math.Sign throws on NaN in .NET.
		if Sine ~= Sine then
			error("Function does not accept floating point Not-a-Number values.", 0)
		end

		const SineSign = if Sine > 0 then 1 elseif Sine < 0 then -1 else 0

		Rotation = Numbers.F32(Rotation * Numbers.F32(SineSign * math.pow(math.abs(Sine), 0.75)))
		Note.Transform = Math.RotatedTransform(Note.Transform, Math.Back, Rotation)

		const Offset = vector.create(Note.Transform.Origin.x, Note.Transform.Origin.y, 0)
		const Pull = Numbers.F32(Numbers.F32(math.pow(Ratio * 0.85, 3)) * Math.DistanceTo(Offset, vector.zero))

		Note.Transform.Origin -= Offset * Pull
	end
end

-- @src scripts/game/modifiers/VortexModifier.cs:VortexModifier L4-34
const function New(): Modifier.Modifier
	const Mod = Modifier.New("Vortex", Color.FromRgba(0x9661ffff))

	Mod.Rankable = true
	Mod.ScoreMultiplier = 1.02
	Mod.ModifyRenderObject = ModifyRenderObject

	return Mod
end

return New
