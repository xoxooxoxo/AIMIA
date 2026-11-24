--!strict
--!optimize 2

--[[
	The alpha gradients of the menus as a UIGradient on a ColorRect's host: linear_alpha_gradient.gdshader (COLOR.a *= 1 - UV.x)
	and alpha_gradient.gdshader (COLOR.a = (0.5 - abs(UV.x - 0.5)) * 3 / 1.5, a tent that is 0 at both edges and 1 in the middle).

	Design Notes
		A UIGradient transparency multiplies the host's own transparency, so the linear gradient is exact. The tent shader sets
		the alpha instead of scaling it: the two agree when the color is opaque (the host's alpha is then replaced too late by the
		multiplication only for a translucent color, which the menus' ColorRects using it do not have).
]]

const MaterialModule = require("./Material")

const LinearPath = "res://scripts/shaders/linear_alpha_gradient.gdshader"
const TentPath = "res://scripts/shaders/alpha_gradient.gdshader"
const GradientName = "ShaderGradient"

-- Transparency is 1 - alpha: 0 at the left edge to 1 at the right edge.
const Linear = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(1, 1),
})

-- Transparent at both edges, opaque in the middle.
const Tent = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(1, 1),
})

-- Whether a material's shader is one of the gradients.
const function Is(Material: MaterialModule.Material?): boolean
	return Material ~= nil and (Material.Path == LinearPath or Material.Path == TentPath)
end

-- Puts the gradient of the material's shader on Host (a ColorRect's frame, or a texture's label, where UV spans the drawn texture),
-- or removes the one it has when the shader is not a gradient.
const function Apply(Host: GuiObject, Material: MaterialModule.Material?)
	const Path = if Material then Material.Path else nil
	const Existing = Host:FindFirstChild(GradientName)

	if Path ~= LinearPath and Path ~= TentPath then
		if Existing then
			Existing:Destroy()
		end

		return
	end

	const Gradient = if Existing and Existing:IsA("UIGradient") then Existing else Instance.new("UIGradient")

	Gradient.Name = GradientName
	Gradient.Transparency = if Path == LinearPath then Linear else Tent
	Gradient.Parent = Host
end

return {
	Apply = Apply,
	Is = Is,
}
