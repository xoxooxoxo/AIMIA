--!strict
--!optimize 2

--[[
	Util/Audio.cs: the audio stream of a buffer, Ogg Vorbis when the bytes start with "OggS" and MP3 otherwise, with its
	length in seconds from the stream headers.

	Representation
		Stream is what a backend loads: Format ("ogg" or "mp3"), Bytes, Length (seconds) and Key, the asset key the backend
		looks up (AudioAssets). Key is set by the caller for map audio (MD5 of the bytes) and skin sounds (file name).

	Design Notes
		DEVIATION(platform): LoadFromFile is not ported: map audio and skin sounds are bytes in memory, and the stream of a
		missing file (a map without audio) is nil in SoundManager.StartMapSelectionPlayback.
		The quiet stream stands for res://sounds/quiet.mp3, which is not in the repo: no bytes, Length 0, key "sounds/quiet.mp3".
		Ogg length: the last page whose granule position is not -1, over the sample rate of the identification header.
		MP3 length: Layer III frames after an ID3v2 tag, 1152 (MPEG1) or 576 (MPEG2, MPEG2.5) samples each, over the
		frames' sample rate. A Xing or Info frame counts as one frame. Reading stops at the first header that is not a valid
		Layer III header with a bitrate (an ID3v1 tag at the end, free-format frames). No decoder runs here, so the length can
		differ from Godot's by one frame and by the encoder delay.
		WAV is not read: maps and skins are MP3 or Ogg only (Map.AudioExt).
]]

export type Stream = {
	Key: string?,
	Format: string,
	Bytes: buffer?,
	Length: number,
}

const QuietKey = "sounds/quiet.mp3"
const Word = 4294967296

-- Layer III bitrates in kbps by bitrate index 1 to 14 (index 0 is free format, 15 is bad): MPEG1, and MPEG2 and MPEG2.5.
const Mpeg1Bitrates = { 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 }
const Mpeg2Bitrates = { 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 }

-- Sample rates by sample rate index 0 to 2.
const Mpeg1Rates = { 44100, 48000, 32000 }
const Mpeg2Rates = { 22050, 24000, 16000 }
const Mpeg25Rates = { 11025, 12000, 8000 }

-- Frame length in bytes, samples per frame and sample rate of the Layer III header at Position; a frame length of 0 when no
-- valid header is there.
const function FrameHeader(Bytes: buffer, Position: number): (number, number, number)
	if Position + 4 > buffer.len(Bytes) then
		return 0, 0, 0
	end

	const Sync = buffer.readu8(Bytes, Position)
	const Byte1 = buffer.readu8(Bytes, Position + 1)
	const Byte2 = buffer.readu8(Bytes, Position + 2)

	if Sync ~= 0xFF or bit32.band(Byte1, 0xE0) ~= 0xE0 then
		return 0, 0, 0
	end

	const Version = bit32.band(bit32.rshift(Byte1, 3), 3)
	const Layer = bit32.band(bit32.rshift(Byte1, 1), 3)
	const BitrateIndex = bit32.rshift(Byte2, 4)
	const RateIndex = bit32.band(bit32.rshift(Byte2, 2), 3)
	const Padding = bit32.band(bit32.rshift(Byte2, 1), 1)

	if Layer ~= 1 or Version == 1 or RateIndex == 3 or BitrateIndex == 0 or BitrateIndex == 15 then
		return 0, 0, 0
	end

	if Version == 3 then
		const Rate = Mpeg1Rates[RateIndex + 1]

		return 144 * Mpeg1Bitrates[BitrateIndex] * 1000 // Rate + Padding, 1152, Rate
	end

	const Rate = if Version == 2 then Mpeg2Rates[RateIndex + 1] else Mpeg25Rates[RateIndex + 1]

	return 72 * Mpeg2Bitrates[BitrateIndex] * 1000 // Rate + Padding, 576, Rate
end

-- The end of an ID3v2 tag (its size, with the footer when the flags say so), or 0 without a tag.
const function Id3TagEnd(Bytes: buffer): number
	if buffer.len(Bytes) < 10 or buffer.readstring(Bytes, 0, 3) ~= "ID3" then
		return 0
	end

	const Size = ((buffer.readu8(Bytes, 6) * 128 + buffer.readu8(Bytes, 7)) * 128 + buffer.readu8(Bytes, 8)) * 128
		+ buffer.readu8(Bytes, 9)
	const Footer = if bit32.btest(buffer.readu8(Bytes, 5), 0x10) then 10 else 0

	return 10 + Size + Footer
end

const function Mp3Length(Bytes: buffer): number
	local Position = Id3TagEnd(Bytes)
	local Samples = 0
	local Rate = 0

	while true do
		const FrameLength, FrameSamples, FrameRate = FrameHeader(Bytes, Position)

		if FrameLength == 0 then
			break
		end

		Rate = FrameRate
		Samples += FrameSamples
		Position += FrameLength
	end

	if Rate == 0 then
		return 0
	end

	return Samples / Rate
end

const function OggLength(Bytes: buffer): number
	const Size = buffer.len(Bytes)

	local Position = 0
	local Rate = 0
	local Granule = -1

	while Position + 27 <= Size and buffer.readstring(Bytes, Position, 4) == "OggS" do
		const Segments = buffer.readu8(Bytes, Position + 26)

		if Position + 27 + Segments > Size then
			break
		end

		local Body = 0

		for Index = 0, Segments - 1 do
			Body += buffer.readu8(Bytes, Position + 27 + Index)
		end

		-- The first packet of the stream is the Vorbis identification header: its sample rate is at byte 12 of the packet.
		if Position == 0 and Size >= 27 + Segments + 16 and buffer.readstring(Bytes, 27 + Segments, 7) == "\1vorbis" then
			Rate = buffer.readu32(Bytes, 27 + Segments + 12)
		end

		const Low = buffer.readu32(Bytes, Position + 6)
		const High = buffer.readu32(Bytes, Position + 10)

		if Low ~= 0xFFFFFFFF or High ~= 0xFFFFFFFF then
			Granule = High * Word + Low
		end

		Position += 27 + Segments + Body
	end

	if Granule < 0 or Rate == 0 then
		return 0
	end

	return Granule / Rate
end

-- @src scripts/util/Audio.cs:LoadStream L8-32
const function LoadStream(Bytes: buffer?): Stream
	if Bytes == nil or buffer.len(Bytes) < 4 then
		return { Key = QuietKey, Format = "mp3", Bytes = nil, Length = 0 }
	end

	if buffer.readstring(Bytes, 0, 4) == "OggS" then
		return { Key = nil, Format = "ogg", Bytes = Bytes, Length = OggLength(Bytes) }
	end

	-- A map whose song lives only on Roblox: its audio is a stub naming the song's length (tools/aimia/strip_map.ps1).
	if buffer.len(Bytes) < 64 and string.sub(buffer.tostring(Bytes), 1, 10) == "AIMIASTUB:" then
		return { Key = nil, Format = "mp3", Bytes = Bytes, Length = tonumber(string.sub(buffer.tostring(Bytes), 11)) or 0 }
	end

	return { Key = nil, Format = "mp3", Bytes = Bytes, Length = Mp3Length(Bytes) }
end

return LoadStream
