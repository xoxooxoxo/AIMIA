--!strict
--!optimize 2

--[[
	The UI scale: the menus lay out in Godot's pixels (the project has no stretch mode, so one Godot pixel is one screen
	pixel), while Roblox pixels are DPI-scaled. The scenes are built under one root frame that is scaled by Factor
	(UIScale) and made 1 / Factor larger, so a layout pixel is Factor screen pixels and the menus are the size they are in
	the engine on the same display.

	Design Notes
		Layout code works in layout pixels; Instance geometry (AbsolutePosition, AbsoluteSize), the viewport and the mouse are in
		screen pixels. The functions here convert between them, and only for what is under the root: a SurfaceGui (the HUD) is
		not scaled, so its factor is 1.
		The root sits at the screen's origin, so a screen position is a layout position times 1 / Factor.
]]

const Signal = require("../Util/Signal")

type Root = Frame

local ScaleRoot: Root? = nil
local ScaleScreen: ScreenGui? = nil
local ScaleObject: UIScale? = nil
local ScaleFactor = 1

-- Fired with the new factor after SetFactor changes it (the window or Menu Scale changed). The root's AbsoluteSize stays the
-- screen's size, so the layouts listening to it don't notice: they listen here.
const Changed: Signal.Signal<number> = Signal.New()

-- Makes Root (a frame that fills Screen) the scaled root, scaled by Factor through Scaling.
const function Install(Screen: ScreenGui, Root: Root, Factor: number, Scaling: UIScale?)
	ScaleScreen = Screen
	ScaleRoot = Root
	ScaleObject = Scaling
	ScaleFactor = Factor
end

-- Changes the factor of the installed root. The root stays at the screen's origin (ToLayout relies on it).
const function SetFactor(Factor: number)
	const Root = ScaleRoot
	const Scaling = ScaleObject

	if Factor == ScaleFactor or not (Factor > 0 and Factor < math.huge) or not Root or not Scaling then
		return
	end

	ScaleFactor = Factor
	Root.Size = UDim2.fromScale(1 / Factor, 1 / Factor)
	Scaling.Scale = Factor
	Signal.Fire(Changed, Factor)
end

-- The factor of the root.
const function Current(): number
	return ScaleFactor
end

-- The factor of a viewport or an Instance: the scale under the root, 1 elsewhere.
const function FactorOf(Gui: Instance): number
	const Root = ScaleRoot

	if Root and (Gui == Root or Gui:IsDescendantOf(Root)) then
		return ScaleFactor
	end

	return 1
end

-- A viewport's size in screen pixels (the screen's size for the root).
const function ScreenSizeOf(Viewport: GuiBase2d): Vector2
	return if Viewport == ScaleRoot and ScaleScreen then ScaleScreen.AbsoluteSize else Viewport.AbsoluteSize
end

-- A viewport's size in layout pixels.
const function SizeOfViewport(Viewport: GuiBase2d): vector
	const Size = ScreenSizeOf(Viewport)
	const Factor = FactorOf(Viewport)

	return vector.create(Size.X / Factor, Size.Y / Factor, 0)
end

-- The size of a GUI object in layout pixels.
const function SizeOf(Gui: GuiObject): vector
	const Size = Gui.AbsoluteSize
	const Factor = FactorOf(Gui)

	return vector.create(Size.X / Factor, Size.Y / Factor, 0)
end

-- The position of a GUI object in layout pixels.
const function PositionOf(Gui: GuiObject): vector
	const Position = Gui.AbsolutePosition
	const Factor = FactorOf(Gui)

	return vector.create(Position.X / Factor, Position.Y / Factor, 0)
end

-- A screen position (the mouse) in layout pixels.
const function ToLayout(Screen: vector): vector
	return vector.create(Screen.x / ScaleFactor, Screen.y / ScaleFactor, 0)
end

-- A length in screen pixels in layout pixels.
const function LengthToLayout(Length: number): number
	return Length / ScaleFactor
end

return {
	Changed = Changed,
	Install = Install,
	SetFactor = SetFactor,
	Current = Current,
	FactorOf = FactorOf,
	ScreenSizeOf = ScreenSizeOf,
	SizeOfViewport = SizeOfViewport,
	SizeOf = SizeOf,
	PositionOf = PositionOf,
	ToLayout = ToLayout,
	LengthToLayout = LengthToLayout,
}
