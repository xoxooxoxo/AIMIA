--!strict
--!native
--!optimize 2

--[[
	water_ripple.gdshader in plain double math: the Fresnel term, the ripple displacement of the screen uv and the
	surface color (linear RGB) from the reflected sky and the echo ring.

	Representation
		Scalars are numbers and colors are vectors (linear RGB). The noise is SkyNoiseWaves.Snoise, the same text as the
		water shader's snoise.

	Design Notes
		The water plane's normal is the world up, so its view-space normal dotted with the view direction is the ray's
		world y: the caller passes the cosine as -WorldY for a ray that hits the water.
		DEVIATION(render): the water color is black in waves.tscn, so the shader's water_color term is dropped (the
		tint is the reflected screen times Fresnel).
		The reflected screen color is the sky at the displaced uv (the renderer computes it); this shader takes it
		already halved, as the shader's texture(screen_texture) / 2.
]]

const SkyNoiseWaves = require("./SkyNoiseWaves")

export type WaterUniforms = {
	FresnelStrength: number,
	FresnelColor: vector,
	EchoColor: vector,
	Echo: number,
}

const FresnelSpan = 500
const RippleBase = 50
const RippleFresnelRange = 100
const EchoWidth = 0.01
const EchoRingScale = 2
const EchoBlendScale = 5

-- pow(1 - clamp(dot(normal, view), 0, 1), 14) by repeated squaring.
-- @src scripts/shaders/water_ripple.gdshader:fresnel_effect L85-87
const function Fresnel(Cosine: number): number
	const Base = 1 - math.clamp(Cosine, 0, 1)
	const Squared = Base * Base
	const Fourth = Squared * Squared
	const Eighth = Fourth * Fourth

	return Eighth * Fourth * Squared
end

-- The ripple added to the screen uv: snoise over the scaled uv and TIME, divided by 500 - 500 * Fresnel.
-- @src scripts/shaders/water_ripple.gdshader:fragment L89-108
const function Ripple(FresnelValue: number, ScreenU: number, ScreenV: number, Time: number): number
	const Scale = RippleBase + FresnelValue * RippleFresnelRange

	return SkyNoiseWaves.Snoise(ScreenU * Scale, ScreenV * Scale, Time) / (FresnelSpan - FresnelValue * FresnelSpan)
end

-- The water's ALBEDO (linear RGB): Screen is the reflected sky already halved; EchoDistance is the distance of the
-- plane uv from its center.
-- @src scripts/shaders/water_ripple.gdshader:fragment L89-108
const function Shade(FresnelValue: number, Screen: vector, EchoDistance: number, Uniforms: WaterUniforms): vector
	const Amount = FresnelValue * Uniforms.FresnelStrength
	local Color = Screen * FresnelValue * (1 - Amount) + Uniforms.FresnelColor * Amount
	const Echo = Uniforms.Echo

	if EchoDistance < Echo * EchoRingScale and EchoDistance > Echo - EchoWidth then
		const EchoMix = math.min(1, Echo * EchoBlendScale)

		Color = Uniforms.EchoColor * (1 - EchoMix) + Color * EchoMix
	end

	return Color
end

return {
	Fresnel = Fresnel,
	Ripple = Ripple,
	Shade = Shade,
}
