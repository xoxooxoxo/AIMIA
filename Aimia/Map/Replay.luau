--!strict
--!optimize 2

--[[
	Replay.cs: a replay file (user/replays/<AttemptID>.phxr) read into a table: the settings it was played with, the map it
	was played on, the cursor frames, the note results and the skips. A replay is a table from New (the path constructor)
	or FromBuffer (the same over bytes); Hash and Equals are GetHashCode and Equals.

	Representation
		Frames are { Progress, CursorPosition } with CursorPosition a vector (Z = 0). FrameIndex is the source's 0-based index:
		Frames[FrameIndex + 1] is the current frame. Notes is 1-based: Notes[Index + 1] is the result of note Index (-1 for no
		hit). Skips is a list of times. Modifiers and CameraMode are the Game/Modifiers and
		Game/Camera objects the file names. Complete, LastNote, LastFrame, CurrentPosition, FrameIndex and SkipIndex are the
		playback state the constructor sets; the replay manager (phase 3) reads and writes them.

	Design Notes
		The file is the phxr format, version 1 (the only one the source reads): any other version leaves Valid true with no
		frames, modifiers or notes, as the source's constructor does. A check that fails returns the replay with Valid false
		and the fields read so far. A frame count of 0 or 1 is invalid and leaves no frames.
		Upstream quirk kept: a note result is `note / (254 / 55)`, an integer division (254 / 55 is 4), so a byte becomes
		note // 4; 255 is a miss (-1).
		Upstream quirk kept: the map folder of a legacy ".phxm" id loses that extension (Path.ChangeExtension).
		DEVIATION(hash): the hash text writes Speed and StartFrom with %.17g, not .NET's double text, so hash values differ
		from .NET's; equal replays still hash equal.
]]

const CameraLock = require("../Game/Camera/CameraLock")
const CameraSpin = require("../Game/Camera/CameraSpin")
const AutoplayModifier = require("../Game/Modifiers/AutoplayModifier")
const ChaosModifier = require("../Game/Modifiers/ChaosModifier")
const EarthquakeModifier = require("../Game/Modifiers/EarthquakeModifier")
const GhostModifier = require("../Game/Modifiers/GhostModifier")
const HorizontalFlipModifier = require("../Game/Modifiers/HorizontalFlipModifier")
const Modifier = require("../Game/Modifiers/Modifier")
const NoFailModifier = require("../Game/Modifiers/NoFailModifier")
const VerticalFlipModifier = require("../Game/Modifiers/VerticalFlipModifier")
const VortexModifier = require("../Game/Modifiers/VortexModifier")
const StrobeModifier = require("../Game/Modifiers/StrobeModifier")
const Constants = require("../Constants")
const DotnetString = require("../Dotnet/String")
const FileParser = require("../Util/FileParser")
const FileSystem = require("../Util/FileSystem")
const GodotString = require("../Godot/String")
const Logger = require("../Util/Logger")
const Notify = require("../Util/Notify")
const Numbers = require("../Numbers")
const Settings = require("../Database/Settings/SettingsProfile")
const SettingsItem = require("../Database/Settings/SettingsItem")
const ReplayTypes = require("./ReplayTypes")
const Sha256 = require("../Util/Sha256")

export type Frame = ReplayTypes.Frame
export type Replay = ReplayTypes.Replay

const Signature = "phxr"
const DigestSize = 32
const MissNote = -1
const ModifiersTypeName = "System.Collections.Generic.List`1[Modifier]"

-- The replay before its file is read: the defaults of the source's fields, Valid, and the playback state the constructor sets.
-- @src scripts/map/Replay.cs:Replay L56-62
const function Blank(): Replay
	return {
		ID = nil,
		MapID = nil,
		MapNoteCount = 0,
		MapFilePath = nil,
		ReplayNoteCount = 0,
		Player = nil,
		Settings = nil,
		Valid = true,
		Length = 0,
		Status = nil,
		Speed = 0,
		StartFrom = 0,
		FirstNote = 0,
		CameraMode = nil,
		Modifiers = nil,
		ApproachRate = 0,
		ApproachDistance = 0,
		ApproachTime = 0,
		FadeIn = 0,
		FadeOut = false,
		Pushback = false,
		Parallax = 0,
		FoV = 0,
		NoteSize = 0,
		Sensitivity = 0,
		Complete = false,
		LastNote = 0,
		LastFrame = 0,
		CurrentPosition = vector.zero,
		Frames = nil,
		FrameIndex = 0,
		Notes = nil,
		Skips = nil,
		SkipIndex = 0,
	}
end

-- The modifier a name in the file stands for (the switch of the source's constructor), or nil for a name it ignores.
-- @src scripts/map/Replay.cs:Replay L130-161
const function ModifierNamed(Name: string): Modifier.Modifier?
	if Name == "NoFail" then
		return NoFailModifier()
	elseif Name == "Autoplay" then
		return AutoplayModifier()
	elseif Name == "Ghost" then
		return GhostModifier()
	elseif Name == "Chaos" then
		return ChaosModifier()
	elseif Name == "Earthquake" then
		return EarthquakeModifier()
	elseif Name == "Vortex" then
		return VortexModifier()
	elseif Name == "VFlip" then
		return VerticalFlipModifier()
	elseif Name == "HFlip" then
		return HorizontalFlipModifier()
	elseif Name == "Strobe" then
		-- (the menu's Strobe: without it here, replays and live views dropped it)
		return StrobeModifier()
	end

	return nil
end

-- The path without its extension, as Path.ChangeExtension(path, null).
const function WithoutExtension(Path: string): string
	const Extension = FileSystem.GetExtension(Path)

	return string.sub(Path, 1, #Path - #Extension)
end

-- The settings a version-1 replay was played with: a new profile with those values set, in the source's order.
-- @src scripts/map/Replay.cs:Replay L105-114
const function SettingsOf(Replay: Replay): Settings.SettingsProfile
	const Profile = Settings.New()

	SettingsItem.SetValue(Profile.ApproachRate, Replay.ApproachRate)
	SettingsItem.SetValue(Profile.ApproachDistance, Replay.ApproachDistance)
	SettingsItem.SetValue(Profile.ApproachTime, Replay.ApproachTime)
	SettingsItem.SetValue(Profile.FadeIn, Replay.FadeIn)
	SettingsItem.SetValue(Profile.FadeOut, if Replay.FadeOut then 100 else 0)
	SettingsItem.SetValue(Profile.Pushback, Replay.Pushback)
	SettingsItem.SetValue(Profile.FoV, Replay.FoV)
	SettingsItem.SetValue(Profile.NoteSize, Replay.NoteSize)
	SettingsItem.SetValue(Profile.Sensitivity, Replay.Sensitivity)

	return Profile
end

-- The modifier names (split on "_") into the replay's modifiers and camera mode: Spin and Lock are the camera (neither is the
-- default camera), the rest modifiers.
-- @src scripts/map/Replay.cs:Replay L122-162
const function ReadModifiers(Replay: Replay, Names: string)
	const Modifiers: { Modifier.Modifier } = {}

	Replay.Modifiers = Modifiers
	Replay.CameraMode = CameraLock()

	for _, Name in DotnetString.Split(Names, "_") do
		if Name == "Spin" then
			Replay.CameraMode = CameraSpin()
		elseif Name == "Lock" then
			Replay.CameraMode = CameraLock(true)
		else
			const Mod = ModifierNamed(Name)

			if Mod then
				table.insert(Modifiers, Mod)
			end
		end
	end
end

-- The frames: each a progress, then a cursor position (x, then y), read in that order.
-- @src scripts/map/Replay.cs:Replay L204-208
const function ReadFrames(Parser: FileParser.FileParser, Count: number): { Frame }
	const Frames: { Frame } = {}

	for Index = 1, Count do
		const Progress = FileParser.GetFloat(Parser)
		const X = FileParser.GetFloat(Parser)
		const Y = FileParser.GetFloat(Parser)

		Frames[Index] = {
			Progress = Progress,
			CursorPosition = vector.create(X, Y, 0),
		}
	end

	return Frames
end

-- Writes the result of note Index, which must be inside the map's note count (the source's array bounds).
const function SetNote(Notes: { number }, MapNoteCount: number, Index: number, Value: number)
	if Index >= MapNoteCount then
		error("Index was outside the bounds of the array.", 0)
	end

	Notes[Index + 1] = Value
end

-- The note results: the notes before the replay's first are misses, then one byte each, then misses to the map's end.
-- @src scripts/map/Replay.cs:Replay L209-228
const function ReadNotes(Replay: Replay, Parser: FileParser.FileParser)
	const Notes: { number } = table.create(Replay.MapNoteCount, MissNote)

	Replay.Notes = Notes
	Replay.FirstNote = FileParser.GetUInt64(Parser)
	Replay.ReplayNoteCount = FileParser.GetUInt64(Parser)

	for Index = 0, Replay.FirstNote - 1 do
		SetNote(Notes, Replay.MapNoteCount, Index, MissNote)
	end

	for Index = Replay.FirstNote, Replay.FirstNote + Replay.ReplayNoteCount - 1 do
		const Byte = FileParser.GetUInt8(Parser)

		-- Note / (254 / 55) in C#: the divisor is the integer 4.
		SetNote(Notes, Replay.MapNoteCount, Index, if Byte == 255 then MissNote else Byte // 4)
	end

	for Index = Replay.FirstNote + Replay.ReplayNoteCount, Replay.MapNoteCount - 1 do
		SetNote(Notes, Replay.MapNoteCount, Index, MissNote)
	end
end

-- The skip times: a count, then one float each.
-- @src scripts/map/Replay.cs:Replay L230-235
const function ReadSkips(Replay: Replay, Parser: FileParser.FileParser)
	const Count = FileParser.GetUInt64(Parser)
	const Skips: { number } = {}

	Replay.Skips = Skips

	for Index = 1, Count do
		Skips[Index] = FileParser.GetFloat(Parser)
	end
end

-- The map folder a replay names: user/maps/<MapID>, without a legacy .phxm extension.
-- @src scripts/map/Replay.cs:Replay L177-182
const function MapFolderOf(MapID: string): string
	const Folder = `{Constants.UserFolder}/maps/{MapID}`

	if string.lower(FileSystem.GetExtension(Folder)) == ".phxm" then
		Logger.Log(`Legacy Replay detected: {Folder}`)

		return WithoutExtension(Folder)
	end

	return Folder
end

-- The version-1 body after the version byte. Each failed check returns with Valid false.
-- @src scripts/map/Replay.cs:Replay L89-236
const function ReadVersion1(Replay: Replay, Parser: FileParser.FileParser, Path: string)
	Replay.ID = GodotString.GetBaseName(GodotString.GetFile(Path))
	Replay.Speed = FileParser.GetDouble(Parser)
	Replay.StartFrom = FileParser.GetDouble(Parser)
	Replay.ApproachRate = FileParser.GetDouble(Parser)
	Replay.ApproachDistance = FileParser.GetDouble(Parser)
	Replay.ApproachTime = Replay.ApproachDistance / Replay.ApproachRate
	Replay.FadeIn = FileParser.GetDouble(Parser)
	Replay.FadeOut = FileParser.GetBool(Parser)
	Replay.Pushback = FileParser.GetBool(Parser)
	Replay.Parallax = FileParser.GetDouble(Parser)
	Replay.FoV = FileParser.GetDouble(Parser)
	Replay.NoteSize = FileParser.GetDouble(Parser)
	Replay.Sensitivity = FileParser.GetDouble(Parser)
	Replay.Settings = SettingsOf(Replay)

	const StatusCode = FileParser.GetUInt8(Parser)

	Replay.Status = if StatusCode == 0 then "PASSED" elseif StatusCode == 1 then "DISQUALIFIED" else "FAILED"

	ReadModifiers(Replay, FileParser.GetString(Parser, FileParser.GetUInt32(Parser)))

	const MapID = FileParser.GetString(Parser, FileParser.GetUInt32(Parser))
	const MapFolder = MapFolderOf(MapID)

	Replay.MapID = MapID
	Replay.MapNoteCount = FileParser.GetUInt64(Parser)

	-- (a file from another player's game can name any count: one no map has can't be real, and would be a huge table)
	if Replay.MapNoteCount > 1000000 then
		Replay.Valid = false

		return
	end
	Replay.MapFilePath = MapFolder

	if not FileSystem.DirectoryExists(MapFolder) then
		Replay.Valid = false

		Notify.Notify("Replay map not found", 2)
		Logger.Log(`Replay map not found, path: {MapFolder}`)

		return
	end

	Replay.Player = FileParser.GetString(Parser, FileParser.GetUInt32(Parser))

	const FrameCount = FileParser.GetUInt64(Parser)

	Replay.CurrentPosition = vector.zero
	Replay.FrameIndex = 0
	Replay.SkipIndex = 0

	if FrameCount <= 1 then
		Replay.Valid = false

		return
	end

	Replay.Frames = ReadFrames(Parser, FrameCount)
	Replay.Length = (Replay.Frames :: { Frame })[FrameCount].Progress

	ReadNotes(Replay, Parser)
	ReadSkips(Replay, Parser)
end

-- The file's parse: the digest over the bytes before its last 32, the signature, then the version and its body.
-- @src scripts/map/Replay.cs:Replay L56-236
const function FromParser(Parser: FileParser.FileParser, Path: string): Replay
	const Replay = Blank()
	const Bytes = FileParser.Get(Parser, Parser.Length - DigestSize)
	const Digest = FileParser.Get(Parser, DigestSize)

	if not Sha256.Equal(Sha256.Hash(Bytes), Digest) then
		Replay.Valid = false

		Notify.Notify("Replay file corrupted", 2)
		Logger.Error("Replay file corrupted; invalid SHA256 hash")

		return Replay
	end

	FileParser.Seek(Parser, 0)

	const Found = FileParser.GetString(Parser, 4)

	if Found ~= Signature then
		Replay.Valid = false

		Notify.Notify("Replay file corrupted", 2)
		Logger.Error(`Replay file corrupted; invalid file sig {Found}`)

		return Replay
	end

	if FileParser.GetUInt8(Parser) == 1 then
		ReadVersion1(Replay, Parser, Path)
	end

	return Replay
end

-- The path constructor: the file at Path (an empty parser when it is missing, as FileParser.FromPath).
-- @src scripts/map/Replay.cs:Replay L56-58
const function New(Path: string): Replay
	return FromParser(FileParser.FromPath(Path), Path)
end

-- The same over bytes, for a file read elsewhere.
const function FromBuffer(Data: buffer, Path: string): Replay
	return FromParser(FileParser.FromBuffer(Data), Path)
end

-- A replay that grows while someone plays (Game/LiveSpectate): no file, the first frame where the song is now, and every note
-- pending until its result arrives. Profile is a copy of the player's settings, never the watcher's own.
const function Live(MapID: string, MapNoteCount: number, Speed: number, StartFrom: number, Mods: string, Profile: Settings.SettingsProfile, Progress: number, Cursor: vector): Replay
	const Replay = Blank()

	Replay.Live = true
	Replay.ID = MapID
	Replay.MapID = MapID
	Replay.MapFilePath = MapFolderOf(MapID)
	Replay.MapNoteCount = MapNoteCount
	Replay.Speed = Speed
	Replay.StartFrom = StartFrom
	Replay.Settings = Profile
	Replay.Status = "PASSED"
	Replay.Length = 1e12
	Replay.Notes = table.create(MapNoteCount, math.huge)
	Replay.Frames = { { Progress = Progress, CursorPosition = Cursor } }
	Replay.Skips = {}
	ReadModifiers(Replay, Mods)

	return Replay
end

-- The text GetHashCode hashes: the map id, the validity, the speed and start, and the modifiers' list type name (or nothing).
-- @src scripts/map/Replay.cs:GetHashCode L246-250
const function HashText(Replay: Replay): string
	const ModifiersText = if Replay.Modifiers then ModifiersTypeName else ""

	return `{Replay.MapID or ""}{if Replay.Valid then "True" else "False"}{string.format("%.17g", Replay.Speed)}{string.format("%.17g", Replay.StartFrom)}{ModifiersText}`
end

-- UTF-16 code units of the text, little-endian (ToUtf16Buffer).
const function Utf16(Text: string): buffer
	const Units: { number } = {}

	for _, CodePoint in utf8.codes(Text) do
		if CodePoint > 0xFFFF then
			const Offset = CodePoint - 0x10000

			table.insert(Units, 0xD800 + Offset // 1024)
			table.insert(Units, 0xDC00 + Offset % 1024)
		else
			table.insert(Units, CodePoint)
		end
	end

	const Bytes = buffer.create(#Units * 2)

	for Index, Unit in Units do
		buffer.writeu16(Bytes, (Index - 1) * 2, Unit)
	end

	return Bytes
end

-- GetHashCode: the sum of the digest's eight little-endian 32-bit words (wrapping, as C# int arithmetic does).
-- @src scripts/map/Replay.cs:GetHashCode L246-258
const function Hash(Replay: Replay): number
	const Digest = Sha256.Hash(Utf16(HashText(Replay)))
	local Total = 0

	for Offset = 0, DigestSize - 4, 4 do
		Total = Numbers.Int32(Total + buffer.readi32(Digest, Offset))
	end

	return Total
end

-- Equals: two replays are equal when their hash codes are.
-- @src scripts/map/Replay.cs:Equals L241-244
const function Equals(Left: Replay, Right: Replay): boolean
	return Hash(Left) == Hash(Right)
end

return {
	New = New,
	FromBuffer = FromBuffer,
	Live = Live,
	Hash = Hash,
	Equals = Equals,
}
