--!strict
--!optimize 2

--[[
	Recursive folder copy of scripts/util/FileOperations.cs over Util/FileSystem.

	Design Notes
		A missing source folder is logged as an error (Logger.Error does not throw) and nothing is copied, as the source does.
]]

const FileSystem = require("./FileSystem")
const Logger = require("./Logger")

-- @src scripts/util/FileOperations.cs:CopyDir L7-37
const function CopyDir(Source: string, Destination: string, Overwrite: boolean?)
	if not FileSystem.DirectoryExists(Source) then
		Logger.Error(`Path {Source} does not exist.`)

		return
	end

	if not FileSystem.DirectoryExists(Destination) then
		FileSystem.CreateDirectory(Destination)
	end

	for _, File in FileSystem.GetFiles(Source) do
		const DestinationFile = FileSystem.Combine(Destination, FileSystem.GetFileName(File))

		FileSystem.Copy(File, DestinationFile, Overwrite)
	end

	for _, Directory in FileSystem.GetDirectories(Source) do
		CopyDir(Directory, FileSystem.Combine(Destination, FileSystem.GetFileName(Directory)), Overwrite)
	end
end

return CopyDir
