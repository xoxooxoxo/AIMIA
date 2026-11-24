--!strict
--!optimize 2

--[[
	In-memory file system standing in for System.IO (File, Directory, Path) and Godot.FileAccess.

	Design Notes
		Paths are "/"-separated strings (Constants.UserFolder is the root folder, "user"); "\" is read as "/" and
		repeated or trailing separators are dropped, so "user//maps/" and "user/maps" name one folder.
		File contents are buffers. Writing a file needs its folder to exist, and a missing file raises the
		.NET exception text, as System.IO does.
		Changed fires (Path, Data?) after every write (Data is the new buffer) and delete (Data nil), so the host can
		persist the files it wants (session only by default). Mount writes a file, creating its folders, without
		firing Changed: it is for loading baked or persisted files at start.
		LastWriteTime is os.time() of the write; GetFiles and GetDirectories answer full paths sorted ordinally.
]]

const Signal = require("./Signal")

type Entry = {
	Data: buffer,
	Modified: number,
}

const Files: { [string]: Entry } = {}
const Directories: { [string]: boolean } = {}

const FileSystem = {
	Changed = Signal.New() :: Signal.Signal<string, buffer?>,
}

const function Normalize(Path: string): string
	local Clean = string.gsub(Path, "\\", "/")

	Clean = string.gsub(Clean, "/+", "/")

	if #Clean > 1 and string.sub(Clean, -1) == "/" then
		Clean = string.sub(Clean, 1, -2)
	end

	return Clean
end

const function Parent(Path: string): string?
	return string.match(Path, "^(.*)/[^/]*$")
end

const function MissingPart(Path: string): never
	error(`Could not find a part of the path '{Path}'.`, 0)
end

const function CheckParent(Path: string, Original: string)
	const Folder = Parent(Path)

	if Folder and not Directories[Folder] then
		MissingPart(Original)
	end
end

const function CreateDirectory(Path: string)
	local Current = Normalize(Path)

	while Current and #Current > 0 and not Directories[Current] do
		Directories[Current] = true
		Current = Parent(Current) :: string
	end
end

const function DirectoryExists(Path: string): boolean
	return Directories[Normalize(Path)] == true
end

const function Exists(Path: string): boolean
	return Files[Normalize(Path)] ~= nil
end

const function ReadAllBytes(Path: string): buffer
	const Entry = Files[Normalize(Path)]

	if not Entry then
		error(`Could not find file '{Path}'.`, 0)
	end

	const Copy = buffer.create(buffer.len(Entry.Data))

	buffer.copy(Copy, 0, Entry.Data)

	return Copy
end

const function ReadAllText(Path: string): string
	const Text = buffer.tostring(ReadAllBytes(Path))

	-- File.ReadAllText drops a UTF-8 byte order mark.
	if string.sub(Text, 1, 3) == "\u{FEFF}" then
		return string.sub(Text, 4)
	end

	return Text
end

const function Store(Path: string, Data: buffer)
	const Copy = buffer.create(buffer.len(Data))

	buffer.copy(Copy, 0, Data)
	Files[Path] = {
		Data = Copy,
		Modified = os.time(),
	}
end

const function WriteAllBytes(Path: string, Data: buffer)
	const Clean = Normalize(Path)

	CheckParent(Clean, Path)
	Store(Clean, Data)
	Signal.Fire(FileSystem.Changed, Clean, Data)
end

const function WriteAllText(Path: string, Text: string)
	WriteAllBytes(Path, buffer.fromstring(Text))
end

const function Mount(Path: string, Data: buffer)
	const Clean = Normalize(Path)
	const Folder = Parent(Clean)

	if Folder then
		CreateDirectory(Folder)
	end

	Store(Clean, Data)
end

const function Delete(Path: string)
	const Clean = Normalize(Path)

	CheckParent(Clean, Path)

	if Files[Clean] then
		Files[Clean] = nil
		Signal.Fire(FileSystem.Changed, Clean, nil)
	end
end

const function Copy(Source: string, Destination: string, Overwrite: boolean?)
	const Clean = Normalize(Destination)

	if Files[Clean] and not Overwrite then
		error(`The file '{Destination}' already exists.`, 0)
	end

	WriteAllBytes(Destination, ReadAllBytes(Source))
end

const function GetLastWriteTime(Path: string): number
	const Entry = Files[Normalize(Path)]

	-- File.GetLastWriteTime answers 1601-01-01 for a missing file.
	return if Entry then Entry.Modified else -11644473600
end

const function IsChild(Folder: string, Path: string): boolean
	return Parent(Path) == Folder
end

const function GetFiles(Path: string, Extension: string?): { string }
	const Folder = Normalize(Path)
	const Found: { string } = {}

	if not Directories[Folder] then
		MissingPart(Path)
	end

	for FilePath in Files do
		if IsChild(Folder, FilePath) and (Extension == nil or string.sub(FilePath, -#Extension) == Extension) then
			table.insert(Found, FilePath)
		end
	end

	table.sort(Found)

	return Found
end

const function GetDirectories(Path: string): { string }
	const Folder = Normalize(Path)
	const Found: { string } = {}

	if not Directories[Folder] then
		MissingPart(Path)
	end

	for DirectoryPath in Directories do
		if IsChild(Folder, DirectoryPath) then
			table.insert(Found, DirectoryPath)
		end
	end

	table.sort(Found)

	return Found
end

const function DeleteDirectory(Path: string, Recursive: boolean?)
	const Folder = Normalize(Path)

	if not Directories[Folder] then
		MissingPart(Path)
	end

	const Prefix = `{Folder}/`
	const Inside: { string } = {}

	for FilePath in Files do
		if string.sub(FilePath, 1, #Prefix) == Prefix then
			table.insert(Inside, FilePath)
		end
	end

	local HasFolders = false

	for DirectoryPath in Directories do
		if string.sub(DirectoryPath, 1, #Prefix) == Prefix then
			HasFolders = true
		end
	end

	if not Recursive and (#Inside > 0 or HasFolders) then
		error(`Directory not empty : '{Path}'`, 0)
	end

	table.sort(Inside)

	for _, FilePath in Inside do
		Files[FilePath] = nil
		Signal.Fire(FileSystem.Changed, FilePath, nil)
	end

	for DirectoryPath in table.clone(Directories) do
		if DirectoryPath == Folder or string.sub(DirectoryPath, 1, #Prefix) == Prefix then
			Directories[DirectoryPath] = nil
		end
	end
end

-- Path.Combine: a rooted second part replaces the first.
const function Combine(First: string, Second: string): string
	if #Second == 0 then
		return First
	elseif #First == 0 or string.sub(Second, 1, 1) == "/" then
		return Second
	elseif string.sub(First, -1) == "/" then
		return `{First}{Second}`
	end

	return `{First}/{Second}`
end

const function GetFileName(Path: string): string
	return string.match(Path, "([^/\\]*)$") :: string
end

-- Path.GetExtension: the extension with its dot, or "".
const function GetExtension(Path: string): string
	const Name = GetFileName(Path)

	return string.match(Name, "(%.[^%.]*)$") or ""
end

const function GetFileNameWithoutExtension(Path: string): string
	const Name = GetFileName(Path)
	const Extension = GetExtension(Name)

	return string.sub(Name, 1, #Name - #Extension)
end

const function GetDirectoryName(Path: string): string?
	return Parent(Normalize(Path))
end

FileSystem.Normalize = Normalize
FileSystem.Exists = Exists
FileSystem.ReadAllBytes = ReadAllBytes
FileSystem.ReadAllText = ReadAllText
FileSystem.WriteAllBytes = WriteAllBytes
FileSystem.WriteAllText = WriteAllText
FileSystem.Mount = Mount
FileSystem.Delete = Delete
FileSystem.Copy = Copy
FileSystem.GetLastWriteTime = GetLastWriteTime
FileSystem.DirectoryExists = DirectoryExists
FileSystem.CreateDirectory = CreateDirectory
FileSystem.DeleteDirectory = DeleteDirectory
FileSystem.GetFiles = GetFiles
FileSystem.GetDirectories = GetDirectories
FileSystem.Combine = Combine
FileSystem.GetFileName = GetFileName
FileSystem.GetExtension = GetExtension
FileSystem.GetFileNameWithoutExtension = GetFileNameWithoutExtension
FileSystem.GetDirectoryName = GetDirectoryName

return FileSystem
