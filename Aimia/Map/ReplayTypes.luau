--!strict
--!optimize 2

--[[
	The types of a replay file (Map/Replay) and of the camera modes that replays name (Game/Camera/CameraMode), as one
	types-only module. Map/Replay and Game/Camera/CameraMode re-export them; Game/Attempt names Replay from here.

	Design Notes
		A Replay names its CameraMode, whose Process takes the attempt, whose Replays are Replay. That is a cycle of types, and a
		cycle of requires would not load, so Replay, CameraMode and CameraAttempt are declared together here. This module
		requires only the Modifier and SettingsProfile types, which name nothing above.
		CameraAttempt is the fields the modes read and write, typed as Game/Attempt types them (Settings is the SettingsProfile,
		Replays are Replay), so an Attempt is passed to Process with no cast.
]]

const Modifier = require("../Game/Modifiers/Modifier")
const SettingsProfile = require("../Database/Settings/SettingsProfile")

export type Frame = {
	Progress: number,
	CursorPosition: vector,
}

export type Replay = {
	ID: string?,
	MapID: string?,
	MapNoteCount: number,
	MapFilePath: string?,
	ReplayNoteCount: number,
	Player: string?,
	Settings: SettingsProfile.SettingsProfile?,
	Valid: boolean,
	Length: number,
	Status: string?,
	Speed: number,
	StartFrom: number,
	FirstNote: number,
	CameraMode: CameraMode?,
	Modifiers: { Modifier.Modifier }?,
	ApproachRate: number,
	ApproachDistance: number,
	ApproachTime: number,
	FadeIn: number,
	FadeOut: boolean,
	Pushback: boolean,
	Parallax: number,
	FoV: number,
	NoteSize: number,
	Sensitivity: number,
	Complete: boolean,
	LastNote: number,
	LastFrame: number,
	CurrentPosition: vector,
	Frames: { Frame }?,
	FrameIndex: number,
	Notes: { number }?,
	Skips: { number }?,
	SkipIndex: number,
	Live: boolean?,
	-- a listed run's replay that came with its player's look: Settings holds it, and the attempt reads it instead of the watcher's
	ShowsPlayer: boolean?,
}

-- The attempt fields the camera modes read and write (Game/Camera/CameraMode's Attempt).
export type CameraAttempt = {
	IsReplay: boolean,
	Replays: { Replay },
	CursorPosition: vector,
	RawCursorPosition: vector,
	Settings: SettingsProfile.SettingsProfile,
}

export type ReplayManager = {
	CursorPosition: vector,
}

export type Camera = {
	Position: vector,
	Rotation: vector,
	Fov: number,
}

export type Cursor = {
	Position: vector,
}

export type CameraMode = {
	Name: string,
	Rankable: boolean,
	Process: (CameraAttempt, ReplayManager, Camera, Cursor, vector, number, boolean?) -> (),
}

return {}
