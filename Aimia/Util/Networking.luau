--!strict
--!optimize 2

--[[
	Default address and port, and their validation, as scripts/util/Networking.cs.

	Design Notes
		ValidatePort reports a port that does not parse through Util/Notify at severity 1 (warning), then answers DefaultPort.
		Port parsing is Godot's ToInt (int.Parse), so the clamp applies to the parsed int.
]]

const GodotString = require("../Godot/String")
const Notify = require("./Notify")

const DefaultIP = "127.0.0.1"
const DefaultPort = 44220

-- @src scripts/util/Networking.cs:ValidateIP L11-19
const function ValidateIP(Ip: string?): string?
	if Ip ~= "" then
		return Ip
	end

	return DefaultIP
end

-- @src scripts/util/Networking.cs:ValidatePort L21-36
const function ValidatePort(Port: string): number
	if Port ~= "" then
		const Success, Value = pcall(GodotString.ToInt, Port)

		if Success then
			return math.clamp(Value, 0, 65535)
		end

		Notify.Notify(`Could not set port, defaulting to {DefaultPort}`, 1)
	end

	return DefaultPort
end

return {
	DefaultIP = DefaultIP,
	DefaultPort = DefaultPort,
	ValidateIP = ValidateIP,
	ValidatePort = ValidatePort,
}
