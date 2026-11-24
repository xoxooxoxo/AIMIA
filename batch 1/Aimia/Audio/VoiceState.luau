--!strict
--!optimize 2

--[[
	The voice logic of Audio/RobloxBackend: which voices play through a Sound and which stay on the simulated clock (Audio/Clock),
	and the state of each sound voice over its Sound handles. Roblox-free: RobloxBackend creates the handles.

	Representation
		A sound voice has a pool of playbacks (Playbacks, up to Capacity = MaxPolyphony), created when first needed. Current is the
		playback of the last Play. Rest is the position when no playback is live: 0 after a load or stop, Length after an end.
		A playback is Live from its Play until a stop, a steal or its end. Pending: its handle is not loaded yet, or the voice was
		paused before the start. Its logical position is Anchor at AnchorTime, advanced at the voice's pitch, as Clock does.

	Design Notes
		A Play takes a free playback (not live, or ended), else a new one below Capacity, else steals the oldest one (Godot's
		AudioStreamPlayer stops the oldest when its polyphony is full).
		A voice with no asset (no stream, no key, or no entry in Hooks.Assets) is on Clock for that load. Pitch, pause and volume
		stay in the voice record across loads and routes, and are given to Clock when it takes the voice.
		The end of the current playback comes from the handle's Ended event, which sets Rest to Length. TimePosition is not read
		to detect it.
		Time is Clock.Hooks.Clock, the same seconds source as the clock voices.
		TimeSinceLastMix is 0: Roblox has no mix clock. Instead SoundPosition extrapolates: Roblox moves TimePosition in steps of one
		audio block (1024 samples, about 21 ms), so between steps the position runs on with the clock (at most BlockCap). A play or
		seek while playing reaches the speakers 50-150 ms after it is asked for; Runner's de-sync corrector now waits for the song
		right after one, rather than raising the pitch to catch it up (audible at normal speed after a start or a Space skip,
		2026-11-07). StartLead can aim a start or seek ahead, but it is 0: a fixed lead overshoots.
]]

const Audio = require("./Audio")
const Clock = require("./Clock")

export type SoundHandle = {
	IsLoaded: () -> boolean,
	IsPlaying: () -> boolean,
	GetTimePosition: () -> number,
	SetTimePosition: (Seconds: number) -> (),
	SetAsset: (Asset: string) -> (),
	SetSpeed: (Scale: number) -> (),
	SetVolume: (Volume: number) -> (),
	Play: () -> (),
	Pause: () -> (),
	Resume: () -> (),
	Stop: () -> (),
	Destroy: () -> (),
	-- (not in the source: where the song ends for its map, the stub length, so a song longer than its map can fade out there)
	SetEnd: ((Seconds: number) -> ())?,
}

export type Playback = {
	Handle: SoundHandle,
	Order: number,
	Live: boolean,
	Pending: boolean,
	Anchor: number,
	AnchorTime: number,
	RawPos: number,
	RawAt: number,
	-- (not in the source: whether the position has moved since the playback was last started, seeked or resumed. Roblox starts
	-- one 50-150 ms after it is asked, and until then its position stands still.)
	Moving: boolean,
	-- where it was last put (seconds): it is moving once it reads a little past this
	MoveFrom: number,
}

export type VoiceRecord = {
	Asset: string,
	Capacity: number,
	Current: Playback?,
	Length: number,
	Order: number,
	Paused: boolean,
	Pitch: number,
	Playbacks: { Playback }?,
	Rest: number,
	Volume: number,
}

-- The default factory: a sound voice needs one (RobloxBackend.Install sets it), so a missing one is an error at its first sound.
const function NoSound(OnLoaded: () -> (), OnEnded: () -> ()): SoundHandle
	error("VoiceState.Hooks.NewSound is not set", 0)
end

const Assets: { [string]: string } = {}

const Hooks = {
	NewSound = NoSound,
	Assets = Assets,
}

const Voices: { [string]: VoiceRecord } = {}

-- (see Design Notes: the extrapolation limit between TimePosition steps, and how far ahead a start or seek is aimed, seconds)
const BlockCap = 0.03
const StartLead = 0 -- (a fixed lead overshot: the delay varies 50-150 ms; Runner waits for the song after a start or seek)

const function Now(): number
	return Clock.Hooks.Clock()
end

const function RecordOf(Voice: string): VoiceRecord
	const Existing = Voices[Voice]

	if Existing then
		return Existing
	end

	const Created = {
		Asset = "",
		Capacity = 1,
		Current = nil,
		Length = 0,
		Order = 0,
		Paused = false,
		Pitch = 1,
		Playbacks = nil,
		Rest = 0,
		Volume = 1,
	} :: VoiceRecord

	Voices[Voice] = Created

	return Created
end

-- The name an asset is listed under: the key without its folder and extension ("sounds/quiet.mp3" is "quiet").
const function AssetName(Key: string): string
	const File = string.match(Key, "[^/]*$") :: string

	return string.match(File, "^(.+)%.%a+$") or File
end

-- The asset of a stream: its key's entry in Hooks.Assets, listed by AssetName. Nil for no stream, no key, or an empty entry: the clock plays it.
const function AssetOf(Stream: Audio.Stream?): string?
	if Stream == nil then
		return nil
	end

	const Key = Stream.Key

	if Key == nil then
		return nil
	end

	const Asset = Hooks.Assets[AssetName(Key)]

	if Asset == nil or Asset == "" then
		return nil
	end

	return Asset
end

-- Roblox Volume (0 to 10) of a level in dB: 10^(dB/20), clamped. -inf is 0.
const function VolumeFromDb(Db: number): number
	return math.clamp(10 ^ (Db / 20), 0, 10)
end

-- The logical position of a pending playback: frozen while the voice is paused, else advanced at the pitch since AnchorTime.
const function PendingPosition(Item: Playback, Record: VoiceRecord): number
	if Record.Paused then
		return Item.Anchor
	end

	return math.clamp(Item.Anchor + (Now() - Item.AnchorTime) * Record.Pitch, 0, Record.Length)
end

-- Folds the clock time into a pending playback's Anchor, before its voice changes pitch or pause.
const function FoldPending(Item: Playback, Record: VoiceRecord)
	if Item.Pending then
		Item.Anchor = PendingPosition(Item, Record)
		Item.AnchorTime = Now()
	end
end

-- Starts a pending playback once its handle is loaded and the voice is not paused, at its logical position.
const function StartIfReady(Item: Playback, Record: VoiceRecord)
	if not Item.Pending or Record.Paused or not Item.Handle.IsLoaded() then
		return
	end

	const From = math.clamp(PendingPosition(Item, Record) + StartLead * Record.Pitch, 0, Record.Length)

	Item.Handle.SetTimePosition(From)
	Item.Handle.Play()
	Item.Pending = false
	Item.RawPos = -1
	Item.Moving = false
	Item.MoveFrom = From
end

-- The Loaded and Ended events of playback Index of a voice. A playback dropped by a route change has no events left to fire.
const function OnLoaded(Record: VoiceRecord, Index: number)
	const Playbacks = Record.Playbacks

	if Playbacks then
		StartIfReady(Playbacks[Index], Record)
	end
end

const function OnEnded(Record: VoiceRecord, Index: number)
	const Playbacks = Record.Playbacks

	if Playbacks == nil then
		return
	end

	const Item = Playbacks[Index]

	if Record.Current == Item and Item.Live then
		Item.Live = false
		Record.Rest = Record.Length
	end
end

const function NewPlayback(Record: VoiceRecord, Index: number): Playback
	const Handle = Hooks.NewSound(function()
		OnLoaded(Record, Index)
	end, function()
		OnEnded(Record, Index)
	end)

	Handle.SetAsset(Record.Asset)
	Handle.SetSpeed(Record.Pitch)
	Handle.SetVolume(Record.Volume)

	if Handle.SetEnd then
		Handle.SetEnd(Record.Length)
	end

	return {
		Handle = Handle,
		Order = 0,
		Live = false,
		Pending = false,
		Anchor = 0,
		AnchorTime = 0,
		RawPos = -1,
		RawAt = 0,
		Moving = false,
		MoveFrom = 0,
	}
end

-- A playback holds its handle while it is live and pending, paused, or playing.
const function IsBusy(Item: Playback, Record: VoiceRecord): boolean
	if not Item.Live then
		return false
	end

	return Item.Pending or Record.Paused or Item.Handle.IsPlaying()
end

const function StopPlayback(Item: Playback)
	Item.Handle.Stop()

	Item.Live = false
	Item.Pending = false
end

-- The playback for a new Play: the first free one, a new one below Capacity, else the oldest, which is stopped.
const function AcquirePlayback(Record: VoiceRecord, Playbacks: { Playback }): Playback
	for _, Item in Playbacks do
		if not IsBusy(Item, Record) then
			return Item
		end
	end

	if #Playbacks < Record.Capacity then
		const Created = NewPlayback(Record, #Playbacks + 1)

		table.insert(Playbacks, Created)

		return Created
	end

	local Oldest = Playbacks[1]

	for _, Item in Playbacks do
		if Item.Order < Oldest.Order then
			Oldest = Item
		end
	end

	StopPlayback(Oldest)

	return Oldest
end

const function SoundPosition(Record: VoiceRecord): number
	const Current = Record.Current

	if Current == nil or not Current.Live then
		return Record.Rest
	end

	StartIfReady(Current, Record)

	if Current.Pending then
		return PendingPosition(Current, Record)
	end

	const Raw = Current.Handle.GetTimePosition()
	const At = Now()

	if Raw ~= Current.RawPos then
		-- (the sound is moving once it reads a little past where it was put. Just after a start, seek or resume Roblox can
		-- still read the position from before, or 0, for a frame or two: those are not movement.)
		if not Current.Moving and Raw > Current.MoveFrom + 0.004 and Raw < Current.MoveFrom + 0.2 then
			Current.Moving = true
		end

		Current.RawPos = Raw
		Current.RawAt = At
	end

	const Ahead = if Record.Paused or not Current.Handle.IsPlaying() then 0 else math.min(At - Current.RawAt, BlockCap) * Record.Pitch

	return math.clamp(Raw + Ahead, 0, Record.Length)
end

-- Gives up the handles of a sound voice (its route changes to the clock).
const function DropPlaybacks(Record: VoiceRecord)
	const Playbacks = Record.Playbacks

	if Playbacks then
		for _, Item in Playbacks do
			Item.Handle.Destroy()
		end
	end

	Record.Current = nil
	Record.Playbacks = nil
	Record.Rest = 0
end

-- A voice with an asset plays through its handles, else through Clock. Pitch, pause and volume survive the load.
const function Load(Voice: string, Stream: Audio.Stream?, MaxPolyphony: number)
	const Record = RecordOf(Voice)
	const Asset = AssetOf(Stream)

	if Asset == nil then
		DropPlaybacks(Record)
		Clock.Load(Voice, Stream, MaxPolyphony)
		Clock.SetPitch(Voice, Record.Pitch)
		Clock.SetPaused(Voice, Record.Paused)

		return
	end

	const Playbacks: { Playback } = Record.Playbacks or {}
	const Length = if Stream then Stream.Length else 0

	for _, Item in Playbacks do
		StopPlayback(Item)
		Item.Handle.SetAsset(Asset)

		if Item.Handle.SetEnd then
			Item.Handle.SetEnd(Length)
		end
	end

	Record.Asset = Asset
	Record.Capacity = math.max(1, MaxPolyphony)
	Record.Current = nil
	Record.Length = Length
	Record.Playbacks = Playbacks
	Record.Rest = 0
end

const function Play(Voice: string, From: number)
	const Record = RecordOf(Voice)
	const Playbacks = Record.Playbacks

	if Playbacks == nil then
		Clock.Play(Voice, From)

		return
	end

	const Item = AcquirePlayback(Record, Playbacks)

	Record.Order += 1

	Item.Order = Record.Order
	Item.Live = true
	Item.Pending = true
	Item.Anchor = math.clamp(From, 0, Record.Length)
	Item.AnchorTime = Now()
	Record.Current = Item

	StartIfReady(Item, Record)
end

const function Stop(Voice: string)
	const Record = RecordOf(Voice)
	const Playbacks = Record.Playbacks

	if Playbacks == nil then
		Clock.Stop(Voice)

		return
	end

	for _, Item in Playbacks do
		StopPlayback(Item)
	end

	Record.Current = nil
	Record.Rest = 0
end

const function SetPaused(Voice: string, Paused: boolean)
	const Record = RecordOf(Voice)
	const Playbacks = Record.Playbacks

	if Playbacks == nil then
		Record.Paused = Paused

		Clock.SetPaused(Voice, Paused)

		return
	end

	if Paused == Record.Paused then
		return
	end

	if Paused then
		for _, Item in Playbacks do
			FoldPending(Item, Record)
		end

		Record.Paused = true

		for _, Item in Playbacks do
			if Item.Live and not Item.Pending then
				Item.Handle.Pause()
			end
		end

		return
	end

	Record.Paused = false

	for _, Item in Playbacks do
		if Item.Pending then
			Item.AnchorTime = Now()
		elseif Item.Live then
			Item.MoveFrom = Item.Handle.GetTimePosition()
			Item.Handle.Resume()
			-- (not in the source: the position is read afresh instead of running on from before the pause, and the playback
			-- counts as moving again only once Roblox has really resumed it)
			Item.RawPos = -1
			Item.Moving = false
		end
	end

	for _, Item in Playbacks do
		StartIfReady(Item, Record)
	end
end

const function Seek(Voice: string, Seconds: number)
	const Record = RecordOf(Voice)
	const Playbacks = Record.Playbacks

	if Playbacks == nil then
		Clock.Seek(Voice, Seconds)

		return
	end

	const Current = Record.Current

	if Current == nil or not Current.Live then
		return
	end

	const Target = math.clamp(Seconds, 0, Record.Length)

	if Current.Pending then
		Current.Anchor = Target
		Current.AnchorTime = Now()
	else
		const From = math.clamp(Target + (if Record.Paused then 0 else StartLead * Record.Pitch), 0, Record.Length)

		Current.Handle.SetTimePosition(From)
		Current.RawPos = -1
		Current.Moving = false
		Current.MoveFrom = From
	end
end

const function SetPitch(Voice: string, Scale: number)
	const Record = RecordOf(Voice)
	const Playbacks = Record.Playbacks

	if Playbacks == nil then
		Record.Pitch = Scale

		Clock.SetPitch(Voice, Scale)

		return
	end

	for _, Item in Playbacks do
		FoldPending(Item, Record)
	end

	Record.Pitch = Scale

	for _, Item in Playbacks do
		Item.Handle.SetSpeed(Scale)
	end
end

const function SetVolume(Voice: string, Db: number)
	const Record = RecordOf(Voice)
	const Playbacks = Record.Playbacks

	Record.Volume = VolumeFromDb(Db)

	if Playbacks == nil then
		Clock.SetVolume(Voice, Db)

		return
	end

	for _, Item in Playbacks do
		Item.Handle.SetVolume(Record.Volume)
	end
end

const function Position(Voice: string): number
	const Record = RecordOf(Voice)

	if Record.Playbacks == nil then
		return Clock.Position(Voice)
	end

	return SoundPosition(Record)
end

-- (Not in the source: whether a voice's current playback has moved since it was last started, seeked or resumed. A voice on
-- the clock, a paused one, or one with nothing playing counts as moving.)
const function Moving(Voice: string): boolean
	const Record = RecordOf(Voice)
	const Current = Record.Current

	if Record.Playbacks == nil or Current == nil or not Current.Live or Record.Paused then
		return true
	end

	return not Current.Pending and Current.Moving
end

const function TimeSinceLastMix(): number
	return 0
end

return {
	Hooks = Hooks,
	AssetOf = AssetOf,
	VolumeFromDb = VolumeFromDb,
	Load = Load,
	Play = Play,
	Stop = Stop,
	SetPaused = SetPaused,
	Seek = Seek,
	SetPitch = SetPitch,
	SetVolume = SetVolume,
	Position = Position,
	Moving = Moving,
	TimeSinceLastMix = TimeSinceLastMix,
}
