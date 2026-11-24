--!strict
--!optimize 2

--[[
	Hook for ToastNotification.Notify, so logic modules notify without requiring the UI.

	Owned State
		Handler: set by the UI's toast module; until then a notification is logged.
		Severity follows the source: 0 info, 1 warning, 2 error.
]]

const Logger = require("./Logger")

const Notify = {
	Handler = nil :: ((Message: string, Severity: number) -> ())?,
}

-- (not in the source: the same message again within a moment is dropped, so changing several skin settings at once, like
-- picking a whole map skin set, shows "Loaded skin" once instead of a stack of them)
local LastMessage = ""
local LastAt = -math.huge

function Notify.Notify(Message: string, Severity: number?)
	const Handler = Notify.Handler
	const Level = Severity or 0
	const Now = os.clock()

	if Message == LastMessage and Now - LastAt < 1.5 then
		return
	end

	LastMessage, LastAt = Message, Now

	if Handler then
		Handler(Message, Level)
	else
		Logger.Log(`[notify {Level}] {Message}`)
	end
end

return Notify
