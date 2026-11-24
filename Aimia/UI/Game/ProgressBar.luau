--!strict
--!optimize 2

--[[
	scripts/game/ui/ProgressBar.cs: the progress panel (Runner/HUD/ProgressBar, a quad with the ProgressBarViewport's background
	and bar). Each frame the bar's width follows the attempt's progress over its length, and only moves when its whole pixel
	width changes.

	Design Notes
		The last progress is kept as a float, as the source's field is, and compared with IsEqualApprox before anything else.
]]

const AttemptModule = require("../../Game/Attempt")
const HudLogic = require("./HudLogic")
const Nodes = require("../Nodes")
const Numbers = require("../../Numbers")
const SkinManager = require("../../Skinning/SkinManager")
const UIComponent = require("./UIComponent")

type Attempt = AttemptModule.Attempt

-- The panel's node and its viewport, and the bar's height (80 px).
const PanelPath = "Runner/HUD/ProgressBar"
const ViewportPath = "Runner/HUD/ProgressBar/ProgressBarViewport"
const BarHeight = 80

-- @src scripts/game/ui/ProgressBar.cs:Init L11-17
const function New(Context: UIComponent.Context): UIComponent.Component
	const Panel = UIComponent.NewPanel(Context.World.Hud, PanelPath, ViewportPath)
	const Main = UIComponent.Control(Panel, "Main")
	const Background = UIComponent.Control(Panel, "Background")

	local LastProgress = -1
	-- the whole pixels of width last set (kept here: reading the size back through Nodes flushed the layout every frame,
	-- part-way through the frame, before the game had moved)
	local DrawnWidth = -1

	-- @src scripts/game/ui/ProgressBar.cs:Init L11-17
	const function Init()
		DrawnWidth = -1

		const Skin = SkinManager.Skin
		const Key = UIComponent.TextureKey(Skin.ProgressImage)
		const BackgroundKey = UIComponent.TextureKey(Skin.ProgressBackgroundImage)

		if Key then
			Nodes.Set(Main, "texture", { Path = Key })
		end

		if BackgroundKey then
			Nodes.Set(Background, "texture", { Path = BackgroundKey })
		end

		-- (not in the source: near black on a light map skin, where the white bar can't be seen: UIComponent.Ink. Its dark track
		-- goes mostly see-through there, so the light skin behind it tells the filled part from the rest)
		const Light = UIComponent.Ink.Light
		const Ink = if Light then UIComponent.DarkInk else Color3.new(1, 1, 1)

		Nodes.Set(Main, "modulate", { Color = { Ink.R, Ink.G, Ink.B, 1 } })
		Nodes.Set(Background, "modulate", { Color = { 1, 1, 1, if Light then 0.2 else 1 } })
	end

	-- @src scripts/game/ui/ProgressBar.cs:Process L19-31
	const function Process(_: number, AttemptValue: Attempt)
		if HudLogic.IsEqualApprox(LastProgress, AttemptValue.Progress) then
			return
		end

		LastProgress = Numbers.F32(AttemptValue.Progress)

		const Width = HudLogic.ProgressWidth(AttemptValue.Progress, AttemptValue.Length)
		const Whole = Numbers.TruncInt32(Width)

		if Whole ~= DrawnWidth then
			DrawnWidth = Whole
			Nodes.Set(Main, "size", vector.create(Width, BarHeight, 0))
		end
	end

	const function Exit() end

	return {
		Init = Init,
		Exit = Exit,
		Process = Process,
	}
end

return New
