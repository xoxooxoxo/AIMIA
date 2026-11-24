--!strict
--!optimize 2

--[[
	The toast notifications (scripts/ui/ToastNotification.cs): a severity-colored panel that slides in from the right edge of
	the scene, pushes the older toasts up, stays for 4 seconds and slides out. New installs Util/Notify.Handler, so every
	Notify call shows a toast.

	Design Notes
		Toasts are children of the current scene's parent, the main scene (SceneManager.Main), so they draw above the scene's
		menus: upstream's z_index 10 is above the settings menu (z 1) and the cursor (z 2), and a toast under the scene root
		would sit in the scene's band below them. While there is no scene, nothing is shown, as upstream returns early.
		The tweens of one toast run one after another (TweenQueue), as upstream awaits the previous tween of the same toast.
		DEVIATION(time): the 4 second stay is task.delay (a SceneTreeTimer upstream).
		DEVIATION(scene): a toast is not freed when the scene changes: it stays for its 4 seconds in the main scene.
		DEVIATION(error): upstream's async Notify drops an exception (a first word wider than the toast). The handler logs it;
		the toast stays in the scene with its template text, as upstream leaves it.
]]

const Nodes = require("./Nodes")
const SceneBuilder = require("./SceneBuilder")
const Tween = require("./Tween")
const Controls = require("./SettingsLogic/Controls")
const Toast = require("./SettingsLogic/Toast")
const TweenQueue = require("./SettingsLogic/TweenQueue")
const Logger = require("../Util/Logger")
const Notify = require("../Util/Notify")
const Signal = require("../Util/Signal")

type Item = SceneBuilder.Item

export type ToastNotification = {
	GetScene: () -> Item?,
	Names: { string },
	NextId: number,
	Queue: TweenQueue.TweenQueue,
}

const PrefabPath = "res://prefabs/notification.tscn"

-- maxToastWidth (500 px), the gap between toasts (8 px), and the time a toast stays (4 s).
const MaxToastWidth = 500
const Gap = 8
const StayTime = 4

const Up = vector.create(0, -1, 0)
const Left = vector.create(-1, 0, 0)
const Right = vector.create(1, 0, 0)

-- Queues a tween of Item that moves its position by Distance() over Duration seconds (Quad, Ease) under Key. Callback
-- runs when the move is done; Finished runs when the tween has finished, before the queue moves on.
const function Slide(
	Toasts: ToastNotification,
	Key: string,
	Item: Item?,
	Distance: () -> vector,
	Duration: number,
	Ease: number,
	Callback: (() -> ())?,
	Finished: (() -> ())?
)
	TweenQueue.Enqueue(Toasts.Queue, Key, function(Done: () -> ())
		if not Item or not Nodes.IsInstanceValid(Item) then
			Done()

			return
		end

		const Fade = Tween.Create(Item)
		const Move = Tween.TweenProperty(Fade, Item, "position", (Nodes.Get(Item, "position") :: vector) + Distance(), Duration)

		Tween.SetTweenerTrans(Move, Tween.TransitionType.Quad)
		Tween.SetTweenerEase(Move, Ease)

		if Callback then
			Tween.TweenCallback(Fade, Callback)
		end

		Signal.Connect(Fade.Finished, function()
			if Finished then
				Finished()
			end

			Done()
		end)
	end)
end

-- ToastNotification.Notify: a toast with the message, its severity color, and the older toasts moved up.
-- @src scripts/ui/ToastNotification.cs:Notify L25-119
const function Show(Toasts: ToastNotification, Message: string, Severity: number, MultilineWrap: boolean)
	const Scene = Toasts.GetScene()

	if not Scene then
		return
	end

	const Host = Nodes.GetParent(Scene) or Scene
	const Notification = Nodes.Instantiate(Scene.Scene, PrefabPath)
	const Name = `NotificationToast_{Toasts.NextId}`

	Nodes.AddChild(Host, Notification)
	Nodes.Set(Notification, "visible", true)
	Nodes.Set(Notification, "name", Name)
	table.insert(Toasts.Names, Name)
	Toasts.NextId += 1

	const Label = Nodes.GetNode(Notification, "HBoxContainer/Label")
	const Font = Nodes.GetThemeFont(Label, "font")
	const FontSize = Nodes.GetThemeFontSize(Label, "font_size")

	const function WordWidth(Word: string): number
		return Nodes.GetStringSize(Font, Word, FontSize).x
	end

	Nodes.Set(Label, "text", if MultilineWrap then Toast.WrapText(MaxToastWidth, Message, WordWidth) else Message)
	Nodes.Set(Nodes.GetNode(Notification, "HBoxContainer/Severity"), "color", Controls.ColorValue(Toast.SeverityColor(Severity)))
	Nodes.ResetSize(Notification)

	const Size = Nodes.Get(Notification, "size") :: vector

	Nodes.Set(Notification, "position", (Nodes.Get(Notification, "position") :: vector) + Up * (Size.y + Gap))

	-- the older toasts move up by the height of this one; the distance is read when their tween starts
	const function Lift(): vector
		return Up * ((Nodes.Get(Notification, "size") :: vector).y + Gap)
	end

	for _, Other in Toasts.Names do
		if Other ~= Name then
			Slide(Toasts, Other, Nodes.GetNodeOrNull(Host, Other), Lift, 0.15, Tween.EaseType.InOut, nil, nil)
		end
	end

	const function Enter(): vector
		return Left * ((Nodes.Get(Notification, "size") :: vector).x + Gap)
	end

	Slide(Toasts, Name, Notification, Enter, 0.8, Tween.EaseType.Out, nil, nil)

	task.delay(StayTime, function()
		const function Leave(): vector
			return Right * ((Nodes.Get(Notification, "size") :: vector).x + Gap)
		end

		Slide(Toasts, Name, Notification, Leave, 0.8, Tween.EaseType.In, function()
			const Index = table.find(Toasts.Names, Name)

			if Index then
				table.remove(Toasts.Names, Index)
			end

			if #Toasts.Names == 0 then
				Toasts.NextId = 0
			end
		end, function()
			Nodes.QueueFree(Notification)
		end)
	end)
end

-- ToastNotification._Ready and Util/Notify.Handler: while installed, every Notify call shows a toast. A failure is logged,
-- since upstream's async Notify does not report it.
-- @src scripts/ui/ToastNotification.cs:_Ready L20-23
const function New(GetScene: () -> Item?): ToastNotification
	const Toasts = {
		GetScene = GetScene,
		Names = {},
		NextId = 0,
		Queue = TweenQueue.New(),
	} :: ToastNotification

	const function Handle(Message: string, Severity: number)
		const Success, Failure = pcall(Show, Toasts, Message, Severity, true)

		if not Success then
			Logger.ErrorException(Failure)
		end
	end

	Notify.Handler = Handle

	return Toasts
end

-- Uninstalls the Notify handler: notifications are logged again.
const function Destroy()
	Notify.Handler = nil
end

return {
	New = New,
	Destroy = Destroy,
}
