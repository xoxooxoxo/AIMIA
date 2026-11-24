--!strict
--!optimize 2

--[[
	The fade of a settings panel (Godot's modulate tween, without a CanvasGroup, which would blur the text): every visual
	under the root keeps its own base transparency, recorded once when it is tracked, and every step sets each one to its
	base shown at the fade's alpha.

	Paradigm
		One value drives everything: Alpha goes from 0 (hidden) to 1 (shown) along a timed ease (UI/Settings/Motion), stepped
		on PreRender. OnChange(Alpha) runs on each step, for what else follows the fade (the holder's slide). Go starts from
		the alpha reached, so a show during a hide reverses from there; a new Go replaces the running one.

	Design Notes
		Tracked: BackgroundTransparency of GuiObjects, TextTransparency of text controls, ImageTransparency of images and the
		Transparency of strokes. Widgets set colors only; transparency belongs to the fade once an instance is tracked.
		A visual tracked while the fade is at alpha A starts at its base shown at A, so rows and popups created during a
		fade appear in step with the menu.
]]

const RunService = game:GetService("RunService")

const Motion = require("./Motion")

type TextObject = TextLabel | TextButton | TextBox

type FrameVisual = { Base: number, Object: GuiObject }
type TextVisual = { Base: number, Object: TextObject }
type ImageVisual = { Base: number, Object: ImageLabel }
type StrokeVisual = { Base: number, Object: UIStroke }

export type Fade = {
	Alpha: number,
	From: number,
	To: number,
	Elapsed: number,
	Duration: number,
	Ease: number,
	OnDone: (() -> ())?,
	Stepping: RBXScriptConnection?,
	Frames: { FrameVisual },
	Texts: { TextVisual },
	Images: { ImageVisual },
	Strokes: { StrokeVisual },
	Tracked: { [Instance]: boolean },
	OnChange: (Alpha: number) -> (),
}

-- Writes every tracked visual's transparency for Alpha, then reports the alpha to OnChange.
const function Apply(Fade: Fade, Alpha: number)
	Fade.Alpha = Alpha

	for _, Item in Fade.Frames do
		Item.Object.BackgroundTransparency = Motion.Transparency(Item.Base, Alpha)
	end

	for _, Item in Fade.Texts do
		Item.Object.TextTransparency = Motion.Transparency(Item.Base, Alpha)
	end

	for _, Item in Fade.Images do
		Item.Object.ImageTransparency = Motion.Transparency(Item.Base, Alpha)
	end

	for _, Item in Fade.Strokes do
		Item.Object.Transparency = Motion.Transparency(Item.Base, Alpha)
	end

	Fade.OnChange(Alpha)
end

-- Records the base transparencies of one instance (once per instance).
const function TrackOne(Fade: Fade, Object: Instance)
	if Fade.Tracked[Object] then
		return
	end

	Fade.Tracked[Object] = true

	if Object:IsA("GuiObject") then
		const Frame = Object :: GuiObject

		table.insert(Fade.Frames, { Base = Frame.BackgroundTransparency, Object = Frame })
	end

	if Object:IsA("TextLabel") then
		const Label = Object :: TextLabel

		table.insert(Fade.Texts, { Base = Label.TextTransparency, Object = Label })
	elseif Object:IsA("TextButton") then
		const Button = Object :: TextButton

		table.insert(Fade.Texts, { Base = Button.TextTransparency, Object = Button })
	elseif Object:IsA("TextBox") then
		const Box = Object :: TextBox

		table.insert(Fade.Texts, { Base = Box.TextTransparency, Object = Box })
	end

	if Object:IsA("ImageLabel") then
		const Image = Object :: ImageLabel

		table.insert(Fade.Images, { Base = Image.ImageTransparency, Object = Image })
	end

	if Object:IsA("UIStroke") then
		const Stroke = Object :: UIStroke

		table.insert(Fade.Strokes, { Base = Stroke.Transparency, Object = Stroke })
	end
end

-- A fade at alpha 1 that reports every alpha through OnChange.
const function New(OnChange: (Alpha: number) -> ()): Fade
	return {
		Alpha = 1,
		From = 1,
		To = 1,
		Elapsed = 0,
		Duration = 0,
		Ease = Motion.EaseOut,
		OnDone = nil,
		Stepping = nil,
		Frames = {},
		Texts = {},
		Images = {},
		Strokes = {},
		Tracked = {},
		OnChange = OnChange,
	}
end

-- Stops the running fade, keeping the alpha it has reached.
const function Stop(Fade: Fade)
	if Fade.Stepping then
		Fade.Stepping:Disconnect()
		Fade.Stepping = nil
	end

	Fade.OnDone = nil
end

-- Tracks an instance and its descendants, which take the current alpha at once.
const function Track(Fade: Fade, Root: Instance)
	TrackOne(Fade, Root)

	for _, Descendant in Root:GetDescendants() do
		TrackOne(Fade, Descendant)
	end

	Apply(Fade, Fade.Alpha)
end

-- Sets the base transparency of a tracked frame (a control state with its own fill alpha), shown at the fade's alpha now.
const function SetFrameBase(Fade: Fade, Object: GuiObject, Base: number)
	for _, Item in Fade.Frames do
		if Item.Object == Object then
			Item.Base = Base
			Object.BackgroundTransparency = Motion.Transparency(Base, Fade.Alpha)

			return
		end
	end
end

-- Stops tracking the instances under Root (a popup that is closing or being destroyed), so the fade stops writing them.
const function Forget(Fade: Fade, Root: Instance)
	const function Inside(Object: Instance): boolean
		return Object == Root or Object:IsDescendantOf(Root)
	end

	const Frames: { FrameVisual } = {}
	const Texts: { TextVisual } = {}
	const Images: { ImageVisual } = {}
	const Strokes: { StrokeVisual } = {}

	for _, Item in Fade.Frames do
		if not Inside(Item.Object) then
			table.insert(Frames, Item)
		end
	end

	for _, Item in Fade.Texts do
		if not Inside(Item.Object) then
			table.insert(Texts, Item)
		end
	end

	for _, Item in Fade.Images do
		if not Inside(Item.Object) then
			table.insert(Images, Item)
		end
	end

	for _, Item in Fade.Strokes do
		if not Inside(Item.Object) then
			table.insert(Strokes, Item)
		end
	end

	Fade.Frames = Frames
	Fade.Texts = Texts
	Fade.Images = Images
	Fade.Strokes = Strokes

	for Object, _ in Fade.Tracked do
		if Inside(Object) then
			Fade.Tracked[Object] = nil
		end
	end
end

-- Sets the alpha at once, stopping any fade.
const function Set(Fade: Fade, Alpha: number)
	Stop(Fade)
	Apply(Fade, Alpha)
end

-- Fades from the current alpha to Target over Duration seconds with Ease, then runs OnDone. A running fade is replaced.
const function Go(Fade: Fade, Target: number, Duration: number, Ease: number, OnDone: (() -> ())?)
	Stop(Fade)

	Fade.From = Fade.Alpha
	Fade.To = Target
	Fade.Elapsed = 0
	Fade.Duration = Duration
	Fade.Ease = Ease

	if Duration <= 0 then
		Apply(Fade, Target)

		if OnDone then
			OnDone()
		end

		return
	end

	Fade.OnDone = OnDone
	Fade.Stepping = RunService.PreRender:Connect(function(DeltaTime: number)
		Fade.Elapsed += DeltaTime

		const Progress = Motion.Progress(Fade.Elapsed, Fade.Duration)

		Apply(Fade, Motion.Blend(Fade.From, Fade.To, Motion.Quad(Progress, Fade.Ease)))

		if Progress >= 1 then
			const Done = Fade.OnDone

			Stop(Fade)

			if Done then
				Done()
			end
		end
	end)
end

return {
	New = New,
	Track = Track,
	Set = Set,
	SetFrameBase = SetFrameBase,
	Forget = Forget,
	Go = Go,
	Stop = Stop,
}
