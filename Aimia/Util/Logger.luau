--!strict
--!optimize 2

--[[
	Timestamped log lines, as scripts/util/Logger.cs.

	Design Notes
		GD.PrintRich prints with `print` (BBCode stays raw); GD.PrintErr prints with `warn`, which does not throw.
		Error(Message) logs and returns the message, so `throw Logger.Error(...)` is `error(Logger.Error(...), 0)`.
		C# exception stack traces are replaced by `debug.traceback()` of the logging site.
]]

-- @src scripts/util/Logger.cs:Log L6-18
const function Log(Message: string, IsError: boolean?)
	const Line = `[{os.date("%Y-%m-%dT%H:%M:%S")}] {Message}`

	-- `warn` is a Roblox global; lute (tests) has none and prints instead.
	if IsError and warn ~= nil then
		warn(Line)
	else
		print(Line)
	end
end

-- @src scripts/util/Logger.cs:Error L20-25
const function Error(Message: string): string
	Log(Message, true)

	return Message
end

-- @src scripts/util/Logger.cs:Error L27-30
const function ErrorException(Exception: unknown)
	const Trace = string.gsub(debug.traceback(), "\n", "")

	Log(`{Exception}\n{Trace}`, true)
end

return {
	Log = Log,
	Error = Error,
	ErrorException = ErrorException,
}
