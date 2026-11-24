--!strict
--!optimize 2

--[[
	Waves.cs: the default menu space (MenuSpace "waves"): the noise sky (sky_noise_waves.gdshader) and the water plane
	(water_ripple.gdshader) at y = -2.01, seen through a camera that tilts from level to 15 degrees down in the intro and
	turns with the mouse. The space holds state only; UI/SpaceView draws it.

	Representation
		A Waves space is BaseSpace's table plus SkyRotation (the environment's sky_rotation, Godot's Euler radians), Coverage
		(the sky's fade-in, 0 to 1), the water plane's height and size (Water MeshInstance3D at y = -2.01, PlaneMesh
		4000 x 4000), and WaterMaterial (the water shader's uniforms that change: Echo).

	Design Notes
		DEVIATION(render): the sky draws no cover image yet: the map cover is decoded but not sampled, so UpdateMap and
		UpdateState only update the base space.
		DEVIATION(render): the sky's coverage is applied by the view as the frame's opacity (black behind it), not inside
		the shader: the sky color is the same at full coverage and fades to black.
		Godot's source_color uniforms are sRGB in the scene and linear in the shader: the water colors are converted here.
		The water color is black in waves.tscn and is not kept.
]]

const BaseSpace = require("./BaseSpace")
const Map = require("../Map/Map")
const SettingsProfile = require("../Database/Settings/SettingsProfile")
const WaterRipple = require("./Shaders/WaterRipple")

export type Waves = BaseSpace.BaseSpace & {
	SkyRotation: vector,
	Coverage: number,
	WaterHeight: number,
	WaterSize: number,
	WaterMaterial: WaterRipple.WaterUniforms,
}

-- The intro's end pose: Godot's camera at the scene's 15 degrees down (rotation.x) and fov 70.
const IntroPitch = math.rad(15)
const IntroFov = 70
const IntroStartFov = 90
const IntroTurnDuration = 5
const IntroCoverDuration = 8
const EchoDuration = 12
const EchoLimit = 0.5
const WaterHeight = -2.01
const WaterSize = 4000
const TurnDivisor = 50000
const FresnelStrength = 0.25

-- @src engine/Color.cs:SrgbToLinear L432-439
-- One channel of Color.SrgbToLinear.
const function SrgbToLinearChannel(Channel: number): number
	if Channel < 0.04045 then
		return Channel / 12.92
	end

	return ((Channel + 0.055) / 1.055) ^ 2.4
end

const function SrgbToLinear(Red: number, Green: number, Blue: number): vector
	return vector.create(SrgbToLinearChannel(Red), SrgbToLinearChannel(Green), SrgbToLinearChannel(Blue))
end

-- @src scripts/spaces/Waves.cs:_Ready L13-57
-- The intro (when no game plays): the camera turns from level to 15 degrees down and widens from 90 to 70 degrees over
-- 5 s (Quart Out), the sky fades in over 8 s (Linear). The water's echo ramps over 12 s (Linear) in any case.
const function New(Settings: SettingsProfile.SettingsProfile): Waves
	const Space = BaseSpace.New(Settings) :: Waves

	Space.SkyRotation = vector.zero
	Space.Coverage = 1
	Space.WaterHeight = WaterHeight
	Space.WaterSize = WaterSize
	Space.WaterMaterial = {
		FresnelStrength = FresnelStrength,
		FresnelColor = SrgbToLinear(0.1, 0.05, 0.1),
		EchoColor = SrgbToLinear(1, 0.2, 0.25),
		Echo = 0,
	}

	if not Space.Playing then
		Space.Coverage = 0
		Space.Camera.Rotation = vector.zero
		Space.Camera.Fov = IntroStartFov

		const Intro = BaseSpace.CreateTween(Space)

		BaseSpace.SetTransition(Intro, BaseSpace.QuartOut)
		BaseSpace.SetParallel(Intro, true)
		BaseSpace.TweenMethod(Intro, 0, IntroPitch, IntroTurnDuration, function(Angle: number)
			Space.Camera.Rotation = vector.create(Angle, 0, 0)
		end)
		BaseSpace.TweenMethod(Intro, IntroStartFov, IntroFov, IntroTurnDuration, function(Fov: number)
			Space.Camera.Fov = Fov
		end)
		BaseSpace.SetTransition(Intro, BaseSpace.Linear)
		BaseSpace.TweenMethod(Intro, 0, 1, IntroCoverDuration, function(Coverage: number)
			Space.Coverage = Coverage
		end)
	end

	const EchoTween = BaseSpace.CreateTween(Space)

	BaseSpace.TweenMethod(EchoTween, 0, EchoLimit, EchoDuration, function(Echo: number)
		Space.WaterMaterial.Echo = Echo
	end)

	return Space
end

-- @src scripts/spaces/Waves.cs:_Process L59-70
-- OffsetX is the mouse's horizontal offset from the view's center, in pixels (Godot's centerOffset.X).
const function Process(Space: Waves, Delta: number, OffsetX: number)
	BaseSpace.Process(Space, Delta)

	if not Space.Playing then
		Space.SkyRotation += vector.create(0, Delta * OffsetX / TurnDivisor, 0)
	end
end

-- The camera pose the sky is drawn at: the intro's end pose until a game plays, then the camera as it is.
-- DEVIATION(render): the view draws the frame at this pose and turns the image to the current one.
const function RestCamera(Space: Waves): (vector, number)
	if Space.Playing then
		return Space.Camera.Rotation, Space.Camera.Fov
	end

	return vector.create(IntroPitch, 0, 0), IntroFov
end

-- @src scripts/spaces/Waves.cs:UpdateMap L72-95
-- The cover is not drawn yet (see the header), so nothing changes here.
const function UpdateMap(Space: Waves, Map: Map.Map)
	BaseSpace.UpdateMap(Space)
end

-- @src scripts/spaces/Waves.cs:UpdateState L97-113
-- The cover is not drawn yet (see the header): the state is the base space's.
const function UpdateState(Space: Waves, Playing: boolean)
	BaseSpace.UpdateState(Space, Playing)
end

return {
	New = New,
	Process = Process,
	RestCamera = RestCamera,
	UpdateMap = UpdateMap,
	UpdateState = UpdateState,
	Load = BaseSpace.Load,
}
