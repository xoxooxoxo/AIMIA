--!strict
--!optimize 2

--[[
	The frames-per-second label (scripts/ui/FPSCounter.cs): counts the frames of each second and shows "{n} FPS" while
	DisplayFPS is on.

	Design Notes
		Time keeps the excess over one second (the source's time--, not a reset), so the count of a late frame carries on.
]]

const Items = require("./Item")
const Listen = require("./Menu/HomeLogic/Listen")
const Nodes = require("./Nodes")
const SettingsManager = require("../SettingsManager")
const SettingsProfile = require("../Database/Settings/SettingsProfile")

-- @src scripts/ui/FPSCounter.cs:_Ready L10-20
-- @src scripts/ui/FPSCounter.cs:_Process L22-34
const function New(Item: Items.Item)
	const Settings = SettingsManager.Settings :: SettingsProfile.SettingsProfile

	local Frames = 0
	local Time = 0

	Nodes.Set(Item, "visible", Settings.DisplayFPS.Value)

	Listen(Item, Settings.DisplayFPS.Updated, function(Value: boolean)
		Nodes.Set(Item, "visible", Value)
	end)

	Nodes.OnProcess(Item, function(Delta: number)
		Frames += 1
		Time += Delta

		if Time >= 1 then
			-- (Not in the source: the count goes straight to the label while it keeps its number of digits, and nothing goes
			-- while it is hidden. A Set laid the whole page out again, which once a second was a hitch at 240 FPS.)
			const Text = `{Frames} FPS`
			const Shown = Item.Context.Properties["text"]
			const Label = Item.Text

			if Settings.DisplayFPS.Value then
				if Label and type(Shown) == "string" and #Shown == #Text then
					Item.Context.Properties["text"] = Text
					Label.Text = Items.DisplayText(Item)
				else
					Nodes.Set(Item, "text", Text)
				end
			end

			Time -= 1
			Frames = 0
		end
	end)
end

return New
