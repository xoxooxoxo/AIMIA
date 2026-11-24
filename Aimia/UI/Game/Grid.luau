--!strict
--!optimize 2

--[[
	scripts/game/ui/Grid.cs: the feedback of judged notes over the grid. A hit shows its score (a Label3D from hit_popup.tscn) and
	a miss shows the miss icon (a Sprite3D from miss_icon.tscn), both at the note's x, 1.4 units below the grid. Each rises a
	quarter unit while it fades over 0.25 s, then returns to its pool. At most 64 of each are alive at once.

	Design Notes
		The grid's textures, guides and cursor are the world's (UI/Game/GameWorld, Grid.Init there); this component only does the
		feedback. Popups are pooled: a finished one is hidden and reused, so no Instance is made per judgment after the pool fills.
		The popup's score takes its lateness from the attempt's progress, not the runner's judgment override (as Grid.cs does).
		DEVIATION(render): the hit popup's and the miss icon's transforms and fonts are the prefabs' (no node in game.tscn).
		Not in the source (2026-11-07): a new popup takes the place of any still showing within ReplaceDistance of it, so fast notes
		in one spot never pile their numbers on top of each other.
]]

const AttemptModule = require("../../Game/Attempt")
const HitResult = require("../../Game/Judgments/HitResult")
const HudLogic = require("./HudLogic")
const MapModule = require("../../Map/Map")
const Math = require("../../Godot/Math")
const SkinManager = require("../../Skinning/SkinManager")
const Signal = require("../../Util/Signal")
const Tween = require("../Tween")
const UIComponent = require("./UIComponent")

type Attempt = AttemptModule.Attempt

-- At most this many popups of each kind are alive (the source's hitPopups and missPopups limit).
const PopupLimit = 64

-- The popups' height below the grid, and how far they rise over their 0.25 s.
const PopupY = -1.4
const PopupDuration = 0.25
const RiseDistance = 0.25

-- How near (along x, in Godot units) a showing popup is taken over by a new one: under the 1 unit between note columns.
const ReplaceDistance = 0.6

-- hit_popup.tscn: a Label3D of Roboto Medium, 47% opaque white (its font size and pixel size are the defaults), a
-- 256 x 128 px text box.
const HitFontPath = "res://fonts/Roboto/Roboto-Medium.ttf"
const HitFontSize = 32
const HitPixelSize = 0.005
const HitAlpha = 120 / 255
const HitCanvas = vector.create(256, 128, 0)

-- miss_icon.tscn: a Sprite3D scaled 0.025 at the origin.
const MissScale = 0.025

-- A pooled popup: its label (a hit) or its sprite (a miss), and the tween that is playing it while it is alive.
type Popup = {
	Label: UIComponent.Label?,
	Sprite: UIComponent.Sprite?,
	Created: Tween.Tween?,
	X: number,
	Release: (() -> ())?,
}

-- @src scripts/game/ui/Grid.cs:_ExitTree L17-24
const function New(Context: UIComponent.Context): UIComponent.Component
	const Parent = Context.World.Hud
	const HitFont = UIComponent.FontAt(HitFontPath)
	const MissKey = UIComponent.TextureKey(SkinManager.Skin.MissFeedbackImage)
	const MissBasis = {
		vector.create(MissScale, 0, 0),
		vector.create(0, MissScale, 0),
		vector.create(0, 0, MissScale),
	}

	const HitPool: { Popup } = {}
	const MissPool: { Popup } = {}
	const Popups: { Popup } = {}

	local HitCount = 0
	local MissCount = 0

	-- A pool record for a label or a sprite, with no tween playing.
	const function PopupOf(Label: UIComponent.Label?, Sprite: UIComponent.Sprite?): Popup
		return { Label = Label, Sprite = Sprite, Created = nil, X = 0, Release = nil }
	end

	-- A new hit popup: a label on the grid's layer, hidden until it is used.
	-- @src scripts/game/ui/Grid.cs:spawnHitIcon L62-65
	const function NewHitPopup(): Popup
		const Label = UIComponent.NewLabel(Parent, "HitPopup", {
			Transform = Math.IdentityTransform(),
			PixelSize = HitPixelSize,
			Canvas = HitCanvas,
			Modulate = { 1, 1, 1, HitAlpha },
			OutlineModulate = { 0, 0, 0, 0 },
			OutlineSize = 12,
			Font = HitFont,
			FontSize = HitFontSize,
			Text = "",
			Wrap = false,
		})
		const Popup = PopupOf(Label, nil)

		UIComponent.SetLabelVisible(Label, false)
		table.insert(Popups, Popup)

		return Popup
	end

	-- A new miss icon: a sprite of the miss feedback texture at the miss icon's scale, hidden until it is used.
	-- @src scripts/game/ui/Grid.cs:spawnMissIcon L95-97
	const function NewMissPopup(): Popup
		const Sprite = UIComponent.NewSprite(Parent, "MissIcon", {
			Transform = { Basis = MissBasis, Origin = vector.zero },
			PixelSize = UIComponent.SpritePixelSize,
			Key = MissKey,
			Modulate = { 1, 1, 1, 1 },
			AlwaysOnTop = false,
		})
		const Popup = PopupOf(nil, Sprite)

		UIComponent.SetSpriteVisible(Sprite, false)
		table.insert(Popups, Popup)

		return Popup
	end

	-- Rises and fades a popup over its duration, then calls Release (its tween is tracked until it finishes).
	-- @src scripts/game/ui/Grid.cs:spawnHitIcon L77-86
	const function Rise(Popup: Popup, Fade: (number) -> (), Move: (number) -> (), Release: () -> ())
		const Created = Tween.Create(nil)

		Popup.Created = Created
		Popup.Release = Release

		Tween.TweenMethod(Created, Fade, 0, 1, PopupDuration)
		Tween.Parallel(Created)

		const Rising = Tween.TweenMethod(Created, Move, 0, 1, PopupDuration)

		Tween.SetTweenerTrans(Rising, Tween.TransitionType.Quint)
		Tween.SetTweenerEase(Rising, Tween.EaseType.Out)
		Tween.TweenCallback(Created, function()
			Popup.Created = nil

			const Done = Popup.Release

			Popup.Release = nil

			if Done then
				Done()
			end
		end)
	end

	-- Ends at once every popup still showing within ReplaceDistance of X (a hit's or a miss's), back to its pool.
	const function ClearNear(X: number)
		for _, Popup in Popups do
			const Running = Popup.Created

			if Running ~= nil and math.abs(Popup.X - X) < ReplaceDistance then
				Tween.Kill(Running)
				Popup.Created = nil

				const Done = Popup.Release

				Popup.Release = nil

				if Done then
					Done()
				end
			end
		end
	end

	-- @src scripts/game/ui/Grid.cs:spawnHitIcon L56-86
	const function SpawnHit(NoteIndex: number)
		const AttemptValue = Context.Runner.Attempt :: Attempt

		if not AttemptValue.Settings.HitPopups.Value or HitCount >= PopupLimit then
			return
		end

		const Speed = Context.Runner.Speed
		const Note = MapModule.GetNotes(AttemptValue.Map)[NoteIndex + 1]
		const Lateness = HudLogic.PopupLateness(AttemptValue.IsReplay, AttemptValue.HitsInfo[NoteIndex + 1], AttemptValue.Progress, Note.Millisecond, Speed)
		const Score = HudLogic.PopupScore(Lateness, AttemptValue.ComboMultiplier, AttemptValue.ModsMultiplier, Speed)

		ClearNear(Note.X)
		HitCount += 1

		const Popup = if #HitPool > 0 then table.remove(HitPool) :: Popup else NewHitPopup()

		Popup.X = Note.X

		const Label = Popup.Label :: UIComponent.Label
		const Origin = vector.create(Note.X, PopupY, 0)

		UIComponent.SetLabelText(Label, `{Score}`)
		UIComponent.SetLabelVisible(Label, true)
		UIComponent.SetLabelTransparency(Label, 0)
		UIComponent.MoveLabel(Label, Origin)

		-- @src scripts/game/ui/Grid.cs:spawnHitIcon L80-80
		const function Fade(Value: number)
			UIComponent.SetLabelTransparency(Label, Value)
		end

		-- @src scripts/game/ui/Grid.cs:spawnHitIcon L82-82
		const function Move(Value: number)
			UIComponent.MoveLabel(Label, Origin + vector.create(0, RiseDistance * Value, 0))
		end

		Rise(Popup, Fade, Move, function()
			HitCount -= 1
			UIComponent.SetLabelVisible(Label, false)
			table.insert(HitPool, Popup)
		end)
	end

	-- @src scripts/game/ui/Grid.cs:spawnMissIcon L92-112
	const function SpawnMiss(NoteIndex: number)
		const AttemptValue = Context.Runner.Attempt :: Attempt

		if MissKey == nil or not AttemptValue.Settings.MissPopups.Value or MissCount >= PopupLimit then
			return
		end

		const Note = MapModule.GetNotes(AttemptValue.Map)[NoteIndex + 1]

		ClearNear(Note.X)
		MissCount += 1

		const Popup = if #MissPool > 0 then table.remove(MissPool) :: Popup else NewMissPopup()

		Popup.X = Note.X

		const Sprite = Popup.Sprite :: UIComponent.Sprite
		const Origin = vector.create(Note.X, PopupY, 0)

		UIComponent.SetSpriteVisible(Sprite, true)
		UIComponent.SetSpriteTransparency(Sprite, 0)
		UIComponent.MoveSprite(Sprite, Origin)

		-- @src scripts/game/ui/Grid.cs:spawnMissIcon L101-101
		const function Fade(Value: number)
			UIComponent.SetSpriteTransparency(Sprite, Value)
		end

		-- @src scripts/game/ui/Grid.cs:spawnMissIcon L103-103
		const function Move(Value: number)
			UIComponent.MoveSprite(Sprite, Origin + vector.create(0, RiseDistance * Value, 0))
		end

		Rise(Popup, Fade, Move, function()
			MissCount -= 1
			UIComponent.SetSpriteVisible(Sprite, false)
			table.insert(MissPool, Popup)
		end)
	end

	-- @src scripts/game/ui/Grid.cs:onHitResultChanged L54-60
	const function OnHitResultChanged(NoteIndex: number, Result: number)
		if Result == HitResult.Hit then
			SpawnHit(NoteIndex)
		elseif Result == HitResult.Miss then
			SpawnMiss(NoteIndex)
		end
	end

	-- @src scripts/game/ui/Grid.cs:Init L27-59
	const function Init()
		Signal.Connect(Context.Runner.HitResultChanged, OnHitResultChanged)
	end

	-- @src scripts/game/ui/Grid.cs:_ExitTree L17-24
	const function Exit()
		Signal.Disconnect(Context.Runner.HitResultChanged, OnHitResultChanged)

		for _, Popup in Popups do
			const Running = Popup.Created

			if Running ~= nil then
				Tween.Kill(Running)
				Popup.Created = nil
			end
		end
	end

	return {
		Init = Init,
		Exit = Exit,
	}
end

return New
