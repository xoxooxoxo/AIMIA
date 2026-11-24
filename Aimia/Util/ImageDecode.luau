--!strict
--!optimize 2

--[[
	Image decoders for the formats Godot's Image.LoadPngFromBuffer, LoadJpgFromBuffer, LoadBmpFromBuffer and
	LoadWebpFromBuffer read, as RGBA8 pixels (Width, Height, Pixels: buffer, row-major, top row first).

	Design Notes
		Each exported decoder returns nil for data it cannot decode (Godot returns an error code; the caller falls through
		to the next format as scripts/util/Misc.cs does). Corrupt input raises inside the decoder and is caught there.
		Pixels are written straight into one buffer; no table is created per pixel.
		Pixel conversion follows libpng (PNG, 16-bit samples keep the high byte, grayscale is expanded to 8 bits), BMP
		and VP8L (lossless WebP) are exact; JPEG follows libjpeg's islow IDCT and fancy upsampling.
]]

const Zip = require("./Zip")

const BmpFileHeaderSize = 14
const BmpMinimumInfoSize = 40

export type Image = {
	Width: number,
	Height: number,
	Pixels: buffer,
}

type BitReader = {
	Data: buffer,
	Bit: number,
	EndBit: number,
}

type HuffmanCode = {
	Single: number,
	Lookup: { number },
	Counts: { number },
	Symbols: { number },
}

type HuffmanGroup = {
	Green: HuffmanCode,
	Red: HuffmanCode,
	Blue: HuffmanCode,
	Alpha: HuffmanCode,
	Distance: HuffmanCode,
}

type Transform = {
	Kind: number,
	Bits: number,
	Width: number,
	Data: buffer,
	PaletteSize: number,
}

type PngInfo = {
	Width: number,
	Height: number,
	Depth: number,
	ColorType: number,
	Channels: number,
	Palette: buffer,
	PaletteCount: number,
	Alpha: buffer,
	AlphaCount: number,
	Key: { number }?,
}

type JpegHuffman = {
	Lookup: { number },
	MinCode: { number },
	MaxCode: { number },
	ValPtr: { number },
	Values: { number },
}

type JpegBits = {
	Data: buffer,
	Position: number,
	End: number,
	Buffer: number,
	Count: number,
	Marker: boolean,
}

type JpegComponent = {
	Id: number,
	H: number,
	V: number,
	QuantTable: number,
	BlocksPerLine: number,
	BlocksPerColumn: number,
	Coefficients: buffer,
	DcPredictor: number,
	DcTable: number,
	AcTable: number,
}

type JpegFrame = {
	Width: number,
	Height: number,
	MaxH: number,
	MaxV: number,
	McusPerLine: number,
	McusPerColumn: number,
	RestartInterval: number,
	Components: { JpegComponent },
	Quantization: { { number } },
	DcTables: { JpegHuffman },
	AcTables: { JpegHuffman },
}

type JpegScanEntry = {
	Component: JpegComponent,
	DcTable: JpegHuffman,
	AcTable: JpegHuffman,
}

type JpegScanState = {
	EobRun: number,
}

type JpegSource = {
	Plane: buffer,
	Stride: number,
	Width: number,
	Height: number,
	HorizontalFactor: number,
	VerticalFactor: number,
}

-- Decodes a BMP (BITMAPINFOHEADER and later): 24-bit and 32-bit, BI_RGB, bottom-up or top-down. Alpha of 32-bit
-- pixels is kept as stored.
const function DecodeBmpUnchecked(Input: buffer): Image
	const Length = buffer.len(Input)

	if Length < BmpFileHeaderSize + 4 then
		error("BMP too short.", 0)
	end

	const PixelOffset = buffer.readu32(Input, 10)
	const InfoSize = buffer.readu32(Input, 14)

	if InfoSize < BmpMinimumInfoSize or BmpFileHeaderSize + InfoSize > Length then
		error("BMP info header invalid.", 0)
	end

	const Width = buffer.readi32(Input, 18)
	const RawHeight = buffer.readi32(Input, 22)
	const Planes = buffer.readu16(Input, 26)
	const BitCount = buffer.readu16(Input, 28)
	const Compression = buffer.readu32(Input, 30)

	if Width <= 0 or RawHeight == 0 or Planes ~= 1 then
		error("BMP dimensions invalid.", 0)
	end

	if Compression ~= 0 or (BitCount ~= 24 and BitCount ~= 32) then
		error("BMP format not supported.", 0)
	end

	const TopDown = RawHeight < 0
	const Height = if TopDown then -RawHeight else RawHeight
	const BytesPerPixel = BitCount // 8
	const Stride = ((Width * BitCount + 31) // 32) * 4

	if PixelOffset + Stride * Height > Length then
		error("BMP pixel data truncated.", 0)
	end

	const Pixels = buffer.create(Width * Height * 4)

	for Row = 0, Height - 1 do
		const SourceRow = if TopDown then Row else Height - 1 - Row
		const SourceBase = PixelOffset + SourceRow * Stride
		const TargetBase = Row * Width * 4

		for Column = 0, Width - 1 do
			const Source = SourceBase + Column * BytesPerPixel
			const Target = TargetBase + Column * 4

			buffer.writeu8(Pixels, Target, buffer.readu8(Input, Source + 2))
			buffer.writeu8(Pixels, Target + 1, buffer.readu8(Input, Source + 1))
			buffer.writeu8(Pixels, Target + 2, buffer.readu8(Input, Source))

			if BytesPerPixel == 4 then
				buffer.writeu8(Pixels, Target + 3, buffer.readu8(Input, Source + 3))
			else
				buffer.writeu8(Pixels, Target + 3, 255)
			end
		end
	end

	return { Width = Width, Height = Height, Pixels = Pixels }
end

-- Godot's Image.LoadBmpFromBuffer: nil when the data is not a BMP this decoder reads.
const function DecodeBmp(Input: buffer): Image?
	const Success, Result = pcall(DecodeBmpUnchecked, Input)

	if Success then
		return Result
	end

	return nil
end

-- DEVIATION(webp lossy): lossy VP8 ('VP8 ' chunks, including VP8X files with an ALPH chunk) is not decoded; the
-- decoder answers nil for it, so such covers are reported as unloadable. Only lossless VP8L is decoded.
-- The RIFF/WebP container: the payload of the first VP8L chunk.
const function FindWebpLossless(Input: buffer): buffer
	const Length = buffer.len(Input)
	local Position = 12

	while Position + 8 <= Length do
		const ChunkType = buffer.readu32(Input, Position)
		const ChunkSize = buffer.readu32(Input, Position + 4)
		const ChunkStart = Position + 8

		if ChunkStart + ChunkSize > Length then
			error("WebP chunk truncated.", 0)
		end

		if ChunkType == 0x4C385056 then
			const Payload = buffer.create(ChunkSize)

			buffer.copy(Payload, 0, Input, ChunkStart, ChunkSize)

			return Payload
		end

		if ChunkType == 0x20385056 then
			error("Lossy WebP is not supported.", 0)
		end

		Position = ChunkStart + ChunkSize + (ChunkSize % 2)
	end

	error("WebP has no VP8L chunk.", 0)
end

-- VP8L bit reader: LSB-first bits of a payload padded with 4 zero bytes, so PeekBits never reads past the buffer.
-- Canonical prefix code. Single is the symbol of a one-symbol code (zero bits), or -1. Lookup has 256 entries for the
-- codes up to 8 bits: symbol * 16 + length, 0 when the next 8 bits do not start a short code.
const CodeLengthCodeOrder = { 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }
const RootBits = 8

-- The next Count bits, first bit in the least significant position, without consuming them.
const function PeekBits(Reader: BitReader, Count: number): number
	const Offset = Reader.Bit // 8
	const Data = Reader.Data
	const Window = buffer.readu8(Data, Offset)
		+ buffer.readu8(Data, Offset + 1) * 256
		+ buffer.readu8(Data, Offset + 2) * 65536
		+ buffer.readu8(Data, Offset + 3) * 16777216

	return bit32.band(bit32.rshift(Window, Reader.Bit % 8), (2 ^ Count) - 1)
end

const function Consume(Reader: BitReader, Count: number)
	Reader.Bit += Count

	if Reader.Bit > Reader.EndBit then
		error("VP8L: unexpected end of data.", 0)
	end
end

const function ReadBits(Reader: BitReader, Count: number): number
	const Value = PeekBits(Reader, Count)

	Consume(Reader, Count)

	return Value
end

const function ReverseBits(Value: number, Count: number): number
	local Reversed = 0
	local Rest = Value

	for _ = 1, Count do
		Reversed = bit32.bor(bit32.lshift(Reversed, 1), bit32.band(Rest, 1))
		Rest = bit32.rshift(Rest, 1)
	end

	return Reversed
end

-- Canonical code from code lengths (1-based: Lengths[Symbol + 1]). Codes are complete, except one-symbol codes.
const function BuildHuffmanCode(Lengths: { number }, AlphabetSize: number): HuffmanCode
	const Counts = table.create(16, 0)
	local NonZero = 0
	local Single = -1

	for Symbol = 0, AlphabetSize - 1 do
		const Length = Lengths[Symbol + 1]

		if Length > 0 then
			NonZero += 1
			Single = Symbol
			Counts[Length] += 1
		end
	end

	if NonZero == 0 then
		error("VP8L: empty Huffman code.", 0)
	end

	if NonZero == 1 then
		return { Single = Single, Lookup = table.create(256, 0), Counts = Counts, Symbols = { Single } }
	end

	local Left = 1

	for Length = 1, 15 do
		Left = Left * 2 - Counts[Length]

		if Left < 0 then
			error("VP8L: over-subscribed Huffman code.", 0)
		end
	end

	if Left ~= 0 then
		error("VP8L: incomplete Huffman code.", 0)
	end

	const Position = table.create(16, 0)
	local Start = 0

	for Length = 1, 15 do
		Position[Length] = Start
		Start += Counts[Length]
	end

	const Symbols = table.create(NonZero, 0)

	for Symbol = 0, AlphabetSize - 1 do
		const Length = Lengths[Symbol + 1]

		if Length > 0 then
			Symbols[Position[Length] + 1] = Symbol
			Position[Length] += 1
		end
	end

	const NextCode = table.create(16, 0)
	local Value = 0

	for Length = 1, 15 do
		NextCode[Length] = Value
		Value = (Value + Counts[Length]) * 2
	end

	const Lookup = table.create(256, 0)

	for Index = 1, NonZero do
		const Symbol = Symbols[Index]
		const Length = Lengths[Symbol + 1]
		const Code = NextCode[Length]

		NextCode[Length] += 1

		if Length <= RootBits then
			local Slot = ReverseBits(Code, Length)

			while Slot < 256 do
				Lookup[Slot + 1] = Symbol * 16 + Length
				Slot += 2 ^ Length
			end
		end
	end

	return { Single = -1, Lookup = Lookup, Counts = Counts, Symbols = Symbols }
end

const function ReadSymbol(Reader: BitReader, Code: HuffmanCode): number
	if Code.Single >= 0 then
		return Code.Single
	end

	const Entry = Code.Lookup[PeekBits(Reader, RootBits) + 1]

	if Entry ~= 0 then
		const Length = Entry % 16

		Consume(Reader, Length)

		return (Entry - Length) // 16
	end

	-- Longer codes: canonical decoding one bit at a time, most significant code bit first.
	local CodeValue = 0
	local First = 0
	local Index = 0

	for Length = 1, 15 do
		CodeValue = CodeValue * 2 + PeekBits(Reader, 1)

		Consume(Reader, 1)

		const Count = Code.Counts[Length]

		if CodeValue - First < Count then
			return Code.Symbols[Index + CodeValue - First + 1]
		end

		Index += Count
		First = (First + Count) * 2
	end

	error("VP8L: invalid Huffman code.", 0)
end

-- Simple code (1 or 2 symbols) or normal code (code lengths read through the code-length code).
const function ReadHuffmanCode(Reader: BitReader, AlphabetSize: number): HuffmanCode
	const Lengths = table.create(AlphabetSize, 0)

	if ReadBits(Reader, 1) == 1 then
		const SymbolCount = ReadBits(Reader, 1) + 1
		const FirstSymbol = ReadBits(Reader, if ReadBits(Reader, 1) == 1 then 8 else 1)

		if FirstSymbol >= AlphabetSize then
			error("VP8L: symbol out of range.", 0)
		end

		Lengths[FirstSymbol + 1] = 1

		if SymbolCount == 2 then
			const SecondSymbol = ReadBits(Reader, 8)

			if SecondSymbol >= AlphabetSize then
				error("VP8L: symbol out of range.", 0)
			end

			Lengths[SecondSymbol + 1] = 1
		end

		return BuildHuffmanCode(Lengths, AlphabetSize)
	end

	const CodeLengthCount = ReadBits(Reader, 4) + 4
	const CodeLengthLengths = table.create(19, 0)

	for Index = 1, CodeLengthCount do
		CodeLengthLengths[CodeLengthCodeOrder[Index] + 1] = ReadBits(Reader, 3)
	end

	const LengthCode = BuildHuffmanCode(CodeLengthLengths, 19)

	local MaxSymbol = AlphabetSize

	if ReadBits(Reader, 1) == 1 then
		const LengthBits = 2 + 2 * ReadBits(Reader, 3)

		MaxSymbol = 2 + ReadBits(Reader, LengthBits)

		if MaxSymbol > AlphabetSize then
			error("VP8L: code length count too large.", 0)
		end
	end

	local Symbol = 0
	local PreviousLength = 8

	while Symbol < AlphabetSize and MaxSymbol > 0 do
		MaxSymbol -= 1

		const CodeLength = ReadSymbol(Reader, LengthCode)

		if CodeLength < 16 then
			Lengths[Symbol + 1] = CodeLength
			Symbol += 1

			if CodeLength ~= 0 then
				PreviousLength = CodeLength
			end
		else
			local RepeatCount: number
			local RepeatLength: number

			if CodeLength == 16 then
				RepeatCount = 3 + ReadBits(Reader, 2)
				RepeatLength = PreviousLength
			elseif CodeLength == 17 then
				RepeatCount = 3 + ReadBits(Reader, 3)
				RepeatLength = 0
			else
				RepeatCount = 11 + ReadBits(Reader, 7)
				RepeatLength = 0
			end

			if Symbol + RepeatCount > AlphabetSize then
				error("VP8L: code length repeat overflows the alphabet.", 0)
			end

			for _ = 1, RepeatCount do
				Lengths[Symbol + 1] = RepeatLength
				Symbol += 1
			end
		end
	end

	return BuildHuffmanCode(Lengths, AlphabetSize)
end

-- Distance codes 1..120 of the spec (libwebp kCodeToPlane): (yoffset << 4) | (8 - xoffset) for a 2D neighbour.
const CodeToPlane = {
	0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1A,
	0x26, 0x2A, 0x38, 0x05, 0x37, 0x39, 0x15, 0x1B, 0x36, 0x3A,
	0x25, 0x2B, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1C, 0x35, 0x3B,
	0x46, 0x4A, 0x24, 0x2C, 0x58, 0x45, 0x4B, 0x34, 0x3C, 0x03,
	0x57, 0x59, 0x13, 0x1D, 0x56, 0x5A, 0x23, 0x2D, 0x44, 0x4C,
	0x55, 0x5B, 0x33, 0x3D, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1E,
	0x66, 0x6A, 0x22, 0x2E, 0x54, 0x5C, 0x43, 0x4D, 0x65, 0x6B,
	0x32, 0x3E, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5D, 0x11, 0x1F,
	0x64, 0x6C, 0x42, 0x4E, 0x76, 0x7A, 0x21, 0x2F, 0x75, 0x7B,
	0x31, 0x3F, 0x63, 0x6D, 0x52, 0x5E, 0x00, 0x74, 0x7C, 0x41,
	0x4F, 0x10, 0x20, 0x62, 0x6E, 0x30, 0x73, 0x7D, 0x51, 0x5F,
	0x40, 0x72, 0x7E, 0x61, 0x6F, 0x50, 0x71, 0x7F, 0x60, 0x70,
}

-- Subsampled size of one dimension for a transform or meta block size of 2^Bits.
const function SubSampleSize(Size: number, Bits: number): number
	return (Size + 2 ^ Bits - 1) // 2 ^ Bits
end

-- Color cache slot of an ARGB value: (0x1e35a7bd * argb) >> (32 - bits), computed without exceeding 2^53.
const function CacheSlot(Argb: number, CacheBits: number): number
	const Low = Argb % 65536
	const High = Argb // 65536
	const Product = (0x1E35A7BD * Low + (0x1E35A7BD * High % 65536) * 65536) % 4294967296

	return bit32.rshift(Product, 32 - CacheBits)
end

const function ReadCopyDistance(Reader: BitReader, Symbol: number): number
	if Symbol < 4 then
		return Symbol + 1
	end

	const ExtraBits = (Symbol - 2) // 2
	const Offset = (2 + Symbol % 2) * 2 ^ ExtraBits

	return Offset + ReadBits(Reader, ExtraBits) + 1
end

const function PlaneCodeToDistance(Width: number, PlaneCode: number): number
	if PlaneCode > 120 then
		return PlaneCode - 120
	end

	const PlaneByte = CodeToPlane[PlaneCode]
	const Distance = (PlaneByte // 16) * Width + 8 - PlaneByte % 16

	if Distance < 1 then
		return 1
	end

	return Distance
end

const function ReadCacheBits(Reader: BitReader): number
	if ReadBits(Reader, 1) == 0 then
		return 0
	end

	const CacheBits = ReadBits(Reader, 4)

	if CacheBits < 1 or CacheBits > 11 then
		error("VP8L: color cache size out of range.", 0)
	end

	return CacheBits
end

-- Pixels of one image (ARGB u32 per pixel, little-endian in a buffer). Pixel i is at byte 4 * i.
const function DecodePixels(
	Reader: BitReader,
	Pixels: buffer,
	Width: number,
	Height: number,
	CacheBits: number,
	MetaBits: number,
	MetaWidth: number,
	MetaImage: buffer,
	Groups: { HuffmanGroup }
)
	const Total = Width * Height
	const Cache = buffer.create(if CacheBits > 0 then 4 * 2 ^ CacheBits else 0)

	local Position = 0
	local Group = Groups[1]

	while Position < Total do
		if MetaBits > 0 then
			const MetaIndex = (Position // Width) // 2 ^ MetaBits * MetaWidth + (Position % Width) // 2 ^ MetaBits

			Group = Groups[(buffer.readu32(MetaImage, MetaIndex * 4) // 256) % 65536 + 1]
		end

		const GreenSymbol = ReadSymbol(Reader, Group.Green)

		if GreenSymbol < 256 then
			const RedValue = ReadSymbol(Reader, Group.Red)
			const BlueValue = ReadSymbol(Reader, Group.Blue)
			const AlphaValue = ReadSymbol(Reader, Group.Alpha)
			const Argb = AlphaValue * 16777216 + RedValue * 65536 + GreenSymbol * 256 + BlueValue

			buffer.writeu32(Pixels, Position * 4, Argb)

			if CacheBits > 0 then
				buffer.writeu32(Cache, CacheSlot(Argb, CacheBits) * 4, Argb)
			end

			Position += 1
		elseif GreenSymbol < 280 then
			const Length = ReadCopyDistance(Reader, GreenSymbol - 256)
			const Distance = PlaneCodeToDistance(Width, ReadCopyDistance(Reader, ReadSymbol(Reader, Group.Distance)))

			if Distance > Position or Position + Length > Total then
				error("VP8L: copy outside the image.", 0)
			end

			for Offset = 0, Length - 1 do
				const Argb = buffer.readu32(Pixels, (Position - Distance + Offset) * 4)

				buffer.writeu32(Pixels, (Position + Offset) * 4, Argb)

				if CacheBits > 0 then
					buffer.writeu32(Cache, CacheSlot(Argb, CacheBits) * 4, Argb)
				end
			end

			Position += Length
		else
			buffer.writeu32(Pixels, Position * 4, buffer.readu32(Cache, (GreenSymbol - 280) * 4))

			Position += 1
		end
	end
end

-- An entropy-coded image: color cache info, then (level 0 only) the meta prefix image, the prefix code groups and
-- the pixels. Level-0 images have the meta image; transform and meta images do not.
const function DecodeEntropyImage(Reader: BitReader, Width: number, Height: number, IsLevel0: boolean): buffer
	const CacheBits = ReadCacheBits(Reader)
	const CacheSize = if CacheBits > 0 then 2 ^ CacheBits else 0
	local MetaBits = 0
	local MetaWidth = 0
	local MetaImage = buffer.create(0)
	local GroupCount = 1

	if IsLevel0 and ReadBits(Reader, 1) == 1 then
		MetaBits = ReadBits(Reader, 3) + 2
		MetaWidth = SubSampleSize(Width, MetaBits)
		MetaImage = DecodeEntropyImage(Reader, MetaWidth, SubSampleSize(Height, MetaBits), false)

		for Index = 0, buffer.len(MetaImage) // 4 - 1 do
			const Group = (buffer.readu32(MetaImage, Index * 4) // 256) % 65536 + 1

			if Group > GroupCount then
				GroupCount = Group
			end
		end
	end

	const Groups: { HuffmanGroup } = {}

	for _ = 1, GroupCount do
		table.insert(Groups, {
			Green = ReadHuffmanCode(Reader, 280 + CacheSize),
			Red = ReadHuffmanCode(Reader, 256),
			Blue = ReadHuffmanCode(Reader, 256),
			Alpha = ReadHuffmanCode(Reader, 256),
			Distance = ReadHuffmanCode(Reader, 40),
		})
	end

	const Pixels = buffer.create(Width * Height * 4)

	DecodePixels(Reader, Pixels, Width, Height, CacheBits, MetaBits, MetaWidth, MetaImage, Groups)

	return Pixels
end

const PredictorTransform = 0
const CrossColorTransform = 1
const SubtractGreenTransform = 2
const ColorIndexingTransform = 3

const function Channel(Argb: number, Shift: number): number
	return bit32.band(bit32.rshift(Argb, Shift), 255)
end

-- Per-channel floor((A + B) / 2).
const function Average2(A: number, B: number): number
	return bit32.rshift(bit32.band(bit32.bxor(A, B), 0xFEFEFEFE), 1) + bit32.band(A, B)
end

const function Clamp255(Value: number): number
	if Value < 0 then
		return 0
	end

	if Value > 255 then
		return 255
	end

	return Value
end

-- The predictor Select: Left when the sum of |Top - TopLeft| is below the sum of |Left - TopLeft|, else Top.
const function Select(Top: number, Left: number, TopLeft: number): number
	local DistanceToLeft = 0
	local DistanceToTop = 0

	for Shift = 0, 24, 8 do
		const TopValue = Channel(Top, Shift)
		const LeftValue = Channel(Left, Shift)
		const TopLeftValue = Channel(TopLeft, Shift)

		DistanceToLeft += math.abs(TopValue - TopLeftValue)
		DistanceToTop += math.abs(LeftValue - TopLeftValue)
	end

	if DistanceToLeft < DistanceToTop then
		return Left
	end

	return Top
end

const function ClampAddSubtractFull(Left: number, Top: number, TopLeft: number): number
	local Result = 0

	for Shift = 0, 24, 8 do
		Result = bit32.bor(Result, bit32.lshift(Clamp255(Channel(Left, Shift) + Channel(Top, Shift) - Channel(TopLeft, Shift)), Shift))
	end

	return Result
end

-- Average of Left and Top, then Average plus half of its difference to TopLeft, truncated toward zero as in C.
const function ClampAddSubtractHalf(Average: number, TopLeft: number): number
	local Result = 0

	for Shift = 0, 24, 8 do
		const Difference = Channel(Average, Shift) - Channel(TopLeft, Shift)
		const Half = if Difference < 0 then -((-Difference) // 2) else Difference // 2

		Result = bit32.bor(Result, bit32.lshift(Clamp255(Channel(Average, Shift) + Half), Shift))
	end

	return Result
end

const function PredictPixel(Mode: number, Left: number, Top: number, TopLeft: number, TopRight: number): number
	if Mode == 1 then
		return Left
	elseif Mode == 2 then
		return Top
	elseif Mode == 3 then
		return TopRight
	elseif Mode == 4 then
		return TopLeft
	elseif Mode == 5 then
		return Average2(Average2(Left, TopRight), Top)
	elseif Mode == 6 then
		return Average2(Left, TopLeft)
	elseif Mode == 7 then
		return Average2(Left, Top)
	elseif Mode == 8 then
		return Average2(TopLeft, Top)
	elseif Mode == 9 then
		return Average2(Top, TopRight)
	elseif Mode == 10 then
		return Average2(Average2(Left, TopLeft), Average2(Top, TopRight))
	elseif Mode == 11 then
		return Select(Top, Left, TopLeft)
	elseif Mode == 12 then
		return ClampAddSubtractFull(Left, Top, TopLeft)
	elseif Mode == 13 then
		return ClampAddSubtractHalf(Average2(Left, Top), TopLeft)
	end

	-- Mode 0, and modes 14 and 15 (libwebp treats them as black).
	return 0xFF000000
end

-- Adds two ARGB pixels channel by channel modulo 256.
const function AddPixels(First: number, Second: number): number
	local Result = 0

	for Shift = 0, 24, 8 do
		Result = bit32.bor(Result, bit32.lshift(bit32.band(Channel(First, Shift) + Channel(Second, Shift), 255), Shift))
	end

	return Result
end

const function InversePredictor(Image: buffer, Width: number, Height: number, Bits: number, Data: buffer)
	const DataWidth = SubSampleSize(Width, Bits)

	for Row = 0, Height - 1 do
		for Column = 0, Width - 1 do
			const Position = Row * Width + Column
			local Predicted: number

			if Position == 0 then
				Predicted = 0xFF000000
			elseif Row == 0 then
				Predicted = buffer.readu32(Image, (Position - 1) * 4)
			elseif Column == 0 then
				Predicted = buffer.readu32(Image, (Position - Width) * 4)
			else
				const Mode = (buffer.readu32(Data, ((Row // 2 ^ Bits) * DataWidth + Column // 2 ^ Bits) * 4) // 256) % 16

				Predicted = PredictPixel(
					Mode,
					buffer.readu32(Image, (Position - 1) * 4),
					buffer.readu32(Image, (Position - Width) * 4),
					buffer.readu32(Image, (Position - Width - 1) * 4),
					buffer.readu32(Image, (Position - Width + 1) * 4)
				)
			end

			buffer.writeu32(Image, Position * 4, AddPixels(buffer.readu32(Image, Position * 4), Predicted))
		end
	end
end

-- Signed 8-bit reading of a byte.
const function Signed8(Value: number): number
	if Value >= 128 then
		return Value - 256
	end

	return Value
end

-- ColorTransformDelta: (int8 multiplier * int8 channel) >> 5, arithmetic shift.
const function ColorDelta(Multiplier: number, Value: number): number
	return (Signed8(Multiplier) * Signed8(Value)) // 32
end

const function InverseCrossColor(Image: buffer, Width: number, Height: number, Bits: number, Data: buffer)
	const DataWidth = SubSampleSize(Width, Bits)

	for Row = 0, Height - 1 do
		for Column = 0, Width - 1 do
			const Position = Row * Width + Column
			const Multipliers = buffer.readu32(Data, ((Row // 2 ^ Bits) * DataWidth + Column // 2 ^ Bits) * 4)
			const GreenToRed = Multipliers % 256
			const GreenToBlue = (Multipliers // 256) % 256
			const RedToBlue = (Multipliers // 65536) % 256
			const Argb = buffer.readu32(Image, Position * 4)
			const Alpha = Argb // 16777216
			const Red = (Argb // 65536) % 256
			const Green = (Argb // 256) % 256
			const Blue = Argb % 256
			const NewRed = (Red + ColorDelta(GreenToRed, Green)) % 256
			const NewBlue = (Blue + ColorDelta(GreenToBlue, Green) + ColorDelta(RedToBlue, NewRed)) % 256

			buffer.writeu32(Image, Position * 4, Alpha * 16777216 + NewRed * 65536 + Green * 256 + NewBlue)
		end
	end
end

-- Red and blue gain the green value (modulo 256).
const function InverseSubtractGreen(Image: buffer, Count: number)
	for Position = 0, Count - 1 do
		const Argb = buffer.readu32(Image, Position * 4)
		const Green = (Argb // 256) % 256

		buffer.writeu32(Image, Position * 4, AddPixels(Argb, Green * 65536 + Green))
	end
end

-- Palette indices are packed 2^Bits to a byte in the green channel; an index past the palette is transparent black.
const function InverseColorIndexing(Packed: buffer, Width: number, Height: number, Bits: number, Palette: buffer, PaletteSize: number): buffer
	const Output = buffer.create(Width * Height * 4)
	const PixelsPerByte = 2 ^ Bits
	const BitsPerPixel = 8 // PixelsPerByte
	const Mask = 2 ^ BitsPerPixel - 1
	const PackedWidth = SubSampleSize(Width, Bits)

	for Row = 0, Height - 1 do
		for Column = 0, Width - 1 do
			const PackedValue = buffer.readu32(Packed, (Row * PackedWidth + Column // PixelsPerByte) * 4)
			const Byte = (PackedValue // 256) % 256
			const Index = bit32.band(bit32.rshift(Byte, (Column % PixelsPerByte) * BitsPerPixel), Mask)
			const Value = if Index < PaletteSize then buffer.readu32(Palette, Index * 4) else 0

			buffer.writeu32(Output, (Row * Width + Column) * 4, Value)
		end
	end

	return Output
end

-- The palette is delta-coded: each entry is the channel-wise sum (modulo 256) of the decoded value and the expanded
-- previous entry (libwebp ExpandColorMap).
const function ExpandPalette(Palette: buffer, PaletteSize: number)
	for Index = 1, PaletteSize - 1 do
		buffer.writeu32(Palette, Index * 4, AddPixels(buffer.readu32(Palette, Index * 4), buffer.readu32(Palette, (Index - 1) * 4)))
	end
end

-- Lossless (VP8L) payload: header, transforms, the image and the inverse transforms in reverse order. The result is
-- ARGB pixels.
const function DecodeLossless(Payload: buffer): Image
	const PayloadLength = buffer.len(Payload)
	const Padded = buffer.create(PayloadLength + 8)

	buffer.copy(Padded, 0, Payload, 0, PayloadLength)

	if buffer.readu8(Padded, 0) ~= 0x2F then
		error("VP8L: bad signature.", 0)
	end

	const Reader = { Data = Padded, Bit = 8, EndBit = PayloadLength * 8 }
	const Width = ReadBits(Reader, 14) + 1
	const Height = ReadBits(Reader, 14) + 1
	const AlphaUsed = ReadBits(Reader, 1)

	if ReadBits(Reader, 3) ~= 0 then
		error("VP8L: unsupported version.", 0)
	end

	const Transforms: { Transform } = {}
	const Seen: { [number]: boolean } = {}

	local XSize = Width

	while ReadBits(Reader, 1) == 1 do
		const Kind = ReadBits(Reader, 2)

		if Seen[Kind + 1] then
			error("VP8L: transform repeated.", 0)
		end

		Seen[Kind + 1] = true

		const Transform = { Kind = Kind, Bits = 0, Width = XSize, Data = buffer.create(0), PaletteSize = 0 }

		if Kind == PredictorTransform or Kind == CrossColorTransform then
			Transform.Bits = ReadBits(Reader, 3) + 2
			Transform.Data = DecodeEntropyImage(Reader, SubSampleSize(XSize, Transform.Bits), SubSampleSize(Height, Transform.Bits), false)
		elseif Kind == ColorIndexingTransform then
			Transform.PaletteSize = ReadBits(Reader, 8) + 1
			Transform.Data = DecodeEntropyImage(Reader, Transform.PaletteSize, 1, false)

			ExpandPalette(Transform.Data, Transform.PaletteSize)

			if Transform.PaletteSize > 16 then
				Transform.Bits = 0
			elseif Transform.PaletteSize > 4 then
				Transform.Bits = 1
			elseif Transform.PaletteSize > 2 then
				Transform.Bits = 2
			else
				Transform.Bits = 3
			end

			XSize = SubSampleSize(XSize, Transform.Bits)
		end

		table.insert(Transforms, Transform)
	end

	local Image = DecodeEntropyImage(Reader, XSize, Height, true)

	for Index = #Transforms, 1, -1 do
		const Transform = Transforms[Index]

		if Transform.Kind == PredictorTransform then
			InversePredictor(Image, Transform.Width, Height, Transform.Bits, Transform.Data)
		elseif Transform.Kind == CrossColorTransform then
			InverseCrossColor(Image, Transform.Width, Height, Transform.Bits, Transform.Data)
		elseif Transform.Kind == SubtractGreenTransform then
			InverseSubtractGreen(Image, Transform.Width * Height)
		else
			Image = InverseColorIndexing(Image, Transform.Width, Height, Transform.Bits, Transform.Data, Transform.PaletteSize)
		end
	end

	const Pixels = buffer.create(Width * Height * 4)

	for Position = 0, Width * Height - 1 do
		const Argb = buffer.readu32(Image, Position * 4)
		const Alpha = if AlphaUsed == 1 then Argb // 16777216 else 255

		buffer.writeu8(Pixels, Position * 4, (Argb // 65536) % 256)
		buffer.writeu8(Pixels, Position * 4 + 1, (Argb // 256) % 256)
		buffer.writeu8(Pixels, Position * 4 + 2, Argb % 256)
		buffer.writeu8(Pixels, Position * 4 + 3, Alpha)
	end

	return { Width = Width, Height = Height, Pixels = Pixels }
end

const function DecodeWebpUnchecked(Input: buffer): Image
	if buffer.len(Input) < 12 or buffer.readu32(Input, 0) ~= 0x46464952 or buffer.readu32(Input, 8) ~= 0x50424557 then
		error("WebP header invalid.", 0)
	end

	return DecodeLossless(FindWebpLossless(Input))
end

-- Godot's Image.LoadWebpFromBuffer: nil when the data is not a lossless WebP this decoder reads.
const function DecodeWebp(Input: buffer): Image?
	const Success, Result = pcall(DecodeWebpUnchecked, Input)

	if Success then
		return Result
	end

	return nil
end

-- Inflates a zlib stream (RFC 1950) into exactly Length bytes: the header is checked here and the DEFLATE data is
-- Util/Zip's inflate. The Adler-32 trailer is not verified (DEVIATION, as the header says).
const function Inflate(Input: buffer, Length: number): buffer
	const InputLength = buffer.len(Input)

	if InputLength < 2 then
		error("Invalid data: zlib header.", 0)
	end

	const CompressionMethod = buffer.readu8(Input, 0)
	const Flags = buffer.readu8(Input, 1)

	if CompressionMethod % 16 ~= 8 or (CompressionMethod * 256 + Flags) % 31 ~= 0 or bit32.btest(Flags, 0x20) then
		error("Invalid data: zlib header.", 0)
	end

	return Zip.Inflate(Input, 2, InputLength, Length)
end

-- Adam7 passes: start X, start Y, step X, step Y.
const AdamPasses = {
	{ 0, 0, 8, 8 },
	{ 4, 0, 8, 8 },
	{ 0, 4, 4, 8 },
	{ 2, 0, 4, 4 },
	{ 0, 2, 2, 4 },
	{ 1, 0, 2, 2 },
	{ 0, 1, 1, 2 },
}

const function PassSize(Size: number, Start: number, Step: number): number
	if Size <= Start then
		return 0
	end

	return (Size - Start + Step - 1) // Step
end

const function RowBytesOf(PassWidth: number, Channels: number, Depth: number): number
	return (PassWidth * Channels * Depth + 7) // 8
end

-- Sample Index of a row (channel-interleaved), at Depth bits; 16-bit samples are returned in full.
const function SampleOf(Data: buffer, RowBase: number, Index: number, Depth: number): number
	if Depth == 16 then
		return buffer.readu8(Data, RowBase + Index * 2) * 256 + buffer.readu8(Data, RowBase + Index * 2 + 1)
	elseif Depth == 8 then
		return buffer.readu8(Data, RowBase + Index)
	end

	const BitOffset = Index * Depth
	const Byte = buffer.readu8(Data, RowBase + BitOffset // 8)

	return bit32.band(bit32.rshift(Byte, 8 - Depth - BitOffset % 8), 2 ^ Depth - 1)
end

-- An 8-bit value of a sample: 16-bit keeps the high byte (libpng strip_16), sub-byte depths scale to 0..255 (libpng
-- expands grayscale 1/2/4-bit to 8-bit by multiplying).
const function EightBit(Value: number, Depth: number): number
	if Depth == 16 then
		return Value // 256
	elseif Depth < 8 then
		return Value * (255 // (2 ^ Depth - 1))
	end

	return Value
end

-- Unfilters the rows of one pass (or the whole image) starting at Offset; returns the unfiltered rows and the offset of
-- the next pass.
const function UnfilterPass(Raw: buffer, Offset: number, PassWidth: number, PassHeight: number, Channels: number, Depth: number): (buffer, number)
	const BitsPerPixel = Channels * Depth
	const RowBytes = RowBytesOf(PassWidth, Channels, Depth)
	const BytesPerPixel = (BitsPerPixel + 7) // 8
	const Output = buffer.create(RowBytes * PassHeight)
	local Position = Offset

	for Row = 0, PassHeight - 1 do
		const Filter = buffer.readu8(Raw, Position)
		const Source = Position + 1
		const Base = Row * RowBytes

		Position = Source + RowBytes

		if Filter > 4 then
			error("Invalid data: PNG filter type.", 0)
		end

		for Index = 0, RowBytes - 1 do
			const Value = buffer.readu8(Raw, Source + Index)
			const Left = if Index >= BytesPerPixel then buffer.readu8(Output, Base + Index - BytesPerPixel) else 0
			const Up = if Row > 0 then buffer.readu8(Output, Base - RowBytes + Index) else 0
			local Predictor = 0

			if Filter == 1 then
				Predictor = Left
			elseif Filter == 2 then
				Predictor = Up
			elseif Filter == 3 then
				Predictor = (Left + Up) // 2
			elseif Filter == 4 then
				const UpLeft = if Row > 0 and Index >= BytesPerPixel then buffer.readu8(Output, Base - RowBytes + Index - BytesPerPixel) else 0
				const Estimate = Left + Up - UpLeft
				const DistanceLeft = math.abs(Estimate - Left)
				const DistanceUp = math.abs(Estimate - Up)
				const DistanceUpLeft = math.abs(Estimate - UpLeft)

				if DistanceLeft <= DistanceUp and DistanceLeft <= DistanceUpLeft then
					Predictor = Left
				elseif DistanceUp <= DistanceUpLeft then
					Predictor = Up
				else
					Predictor = UpLeft
				end
			end

			buffer.writeu8(Output, Base + Index, (Value + Predictor) % 256)
		end
	end

	return Output, Position
end

-- Writes the pixels of one pass into the image at (X0 + Column * DX, Y0 + Row * DY) as RGBA8.
const function WritePassPixels(Png: PngInfo, Rows: buffer, PassWidth: number, PassHeight: number, Pixels: buffer, X0: number, Y0: number, DX: number, DY: number)
	const RowBytes = RowBytesOf(PassWidth, Png.Channels, Png.Depth)
	const Depth = Png.Depth

	for Row = 0, PassHeight - 1 do
		const RowBase = Row * RowBytes

		for Column = 0, PassWidth - 1 do
			const Target = ((Y0 + Row * DY) * Png.Width + X0 + Column * DX) * 4
			local Red: number
			local Green: number
			local Blue: number
			local Alpha = 255

			if Png.ColorType == 0 then
				const Gray = SampleOf(Rows, RowBase, Column, Depth)

				Red = EightBit(Gray, Depth)
				Green = Red
				Blue = Red

				if Png.Key and Gray == Png.Key[1] then
					Alpha = 0
				end
			elseif Png.ColorType == 2 then
				const RedSample = SampleOf(Rows, RowBase, Column * 3, Depth)
				const GreenSample = SampleOf(Rows, RowBase, Column * 3 + 1, Depth)
				const BlueSample = SampleOf(Rows, RowBase, Column * 3 + 2, Depth)

				Red = EightBit(RedSample, Depth)
				Green = EightBit(GreenSample, Depth)
				Blue = EightBit(BlueSample, Depth)

				if Png.Key and RedSample == Png.Key[1] and GreenSample == Png.Key[2] and BlueSample == Png.Key[3] then
					Alpha = 0
				end
			elseif Png.ColorType == 3 then
				const Index = SampleOf(Rows, RowBase, Column, Depth)

				if Index >= Png.PaletteCount then
					error("Invalid data: PNG palette index.", 0)
				end

				Red = buffer.readu8(Png.Palette, Index * 3)
				Green = buffer.readu8(Png.Palette, Index * 3 + 1)
				Blue = buffer.readu8(Png.Palette, Index * 3 + 2)

				if Index < Png.AlphaCount then
					Alpha = buffer.readu8(Png.Alpha, Index)
				end
			elseif Png.ColorType == 4 then
				Red = EightBit(SampleOf(Rows, RowBase, Column * 2, Depth), Depth)
				Green = Red
				Blue = Red
				Alpha = EightBit(SampleOf(Rows, RowBase, Column * 2 + 1, Depth), Depth)
			else
				Red = EightBit(SampleOf(Rows, RowBase, Column * 4, Depth), Depth)
				Green = EightBit(SampleOf(Rows, RowBase, Column * 4 + 1, Depth), Depth)
				Blue = EightBit(SampleOf(Rows, RowBase, Column * 4 + 2, Depth), Depth)
				Alpha = EightBit(SampleOf(Rows, RowBase, Column * 4 + 3, Depth), Depth)
			end

			buffer.writeu8(Pixels, Target, Red)
			buffer.writeu8(Pixels, Target + 1, Green)
			buffer.writeu8(Pixels, Target + 2, Blue)
			buffer.writeu8(Pixels, Target + 3, Alpha)
		end
	end
end

-- DEVIATION(png checksums): chunk CRC-32 and the zlib Adler-32 are not verified (libpng rejects corrupt files; the
-- decoder reads them as valid), so a damaged file that still inflates decodes.
const function DecodePngUnchecked(Input: buffer): Image
	const Length = buffer.len(Input)

	if Length < 8 or buffer.readu32(Input, 0) ~= 0x474E5089 or buffer.readu32(Input, 4) ~= 0x0A1A0A0D then
		error("PNG signature invalid.", 0)
	end

	local Png: PngInfo? = nil
	local PaletteBytes = buffer.create(0)
	local AlphaBytes = buffer.create(0)
	local KeyValues: { number }? = nil
	const IdatStarts: { number } = {}
	const IdatLengths: { number } = {}
	local IsInterlaced = false
	local Position = 8

	while Position + 12 <= Length do
		const ChunkLength = buffer.readu8(Input, Position) * 16777216
			+ buffer.readu8(Input, Position + 1) * 65536
			+ buffer.readu8(Input, Position + 2) * 256
			+ buffer.readu8(Input, Position + 3)
		const ChunkType = buffer.readstring(Input, Position + 4, 4)
		const Data = Position + 8

		if Data + ChunkLength + 4 > Length then
			error("PNG chunk truncated.", 0)
		end

		if ChunkType == "IHDR" then
			const Width = buffer.readu8(Input, Data) * 16777216 + buffer.readu8(Input, Data + 1) * 65536 + buffer.readu8(Input, Data + 2) * 256 + buffer.readu8(Input, Data + 3)
			const Height = buffer.readu8(Input, Data + 4) * 16777216 + buffer.readu8(Input, Data + 5) * 65536 + buffer.readu8(Input, Data + 6) * 256 + buffer.readu8(Input, Data + 7)
			const Depth = buffer.readu8(Input, Data + 8)
			const ColorType = buffer.readu8(Input, Data + 9)
			const InterlaceByte = buffer.readu8(Input, Data + 12)
			const Channels = if ColorType == 0 or ColorType == 3 then 1 elseif ColorType == 4 then 2 elseif ColorType == 2 then 3 else 4
			const DepthValid = if ColorType == 0 then Depth == 1 or Depth == 2 or Depth == 4 or Depth == 8 or Depth == 16
				elseif ColorType == 3 then Depth == 1 or Depth == 2 or Depth == 4 or Depth == 8
				else Depth == 8 or Depth == 16

			if Width == 0 or Height == 0 or not DepthValid or ColorType == 1 or ColorType == 5 or ColorType > 6 then
				error("PNG header invalid.", 0)
			end

			if buffer.readu8(Input, Data + 10) ~= 0 or buffer.readu8(Input, Data + 11) ~= 0 or InterlaceByte > 1 then
				error("PNG header unsupported.", 0)
			end

			Png = {
				Width = Width,
				Height = Height,
				Depth = Depth,
				ColorType = ColorType,
				Channels = Channels,
				Palette = PaletteBytes,
				PaletteCount = 0,
				Alpha = AlphaBytes,
				AlphaCount = 0,
				Key = KeyValues,
			}

			IsInterlaced = InterlaceByte == 1
		elseif ChunkType == "PLTE" then
			if ChunkLength % 3 ~= 0 or ChunkLength > 768 then
				error("PNG palette invalid.", 0)
			end

			PaletteBytes = buffer.create(ChunkLength)
			buffer.copy(PaletteBytes, 0, Input, Data, ChunkLength)
		elseif ChunkType == "tRNS" then
			const ColorType = if Png then Png.ColorType else -1

			if ColorType == 3 then
				AlphaBytes = buffer.create(ChunkLength)
				buffer.copy(AlphaBytes, 0, Input, Data, ChunkLength)
			elseif ColorType == 0 then
				KeyValues = { buffer.readu8(Input, Data) * 256 + buffer.readu8(Input, Data + 1) }
			elseif ColorType == 2 then
				KeyValues = {
					buffer.readu8(Input, Data) * 256 + buffer.readu8(Input, Data + 1),
					buffer.readu8(Input, Data + 2) * 256 + buffer.readu8(Input, Data + 3),
					buffer.readu8(Input, Data + 4) * 256 + buffer.readu8(Input, Data + 5),
				}
			end
		elseif ChunkType == "IDAT" then
			table.insert(IdatStarts, Data)
			table.insert(IdatLengths, ChunkLength)
		elseif ChunkType == "IEND" then
			break
		end

		Position = Data + ChunkLength + 4
	end

	if Png == nil then
		error("PNG has no IHDR.", 0)
	end

	const Info: PngInfo = Png
	-- Samples of an 8- or 16-bit key are compared at full precision; sub-byte keys as stored.
	Info.Palette = PaletteBytes
	Info.PaletteCount = buffer.len(PaletteBytes) // 3
	Info.Alpha = AlphaBytes
	Info.AlphaCount = buffer.len(AlphaBytes)
	Info.Key = KeyValues

	if Info.ColorType == 3 and Info.PaletteCount == 0 then
		error("PNG palette missing.", 0)
	end

	local CompressedLength = 0

	for Index = 1, #IdatLengths do
		CompressedLength += IdatLengths[Index]
	end

	const Compressed = buffer.create(CompressedLength)
	local Fill = 0

	for Index = 1, #IdatLengths do
		buffer.copy(Compressed, Fill, Input, IdatStarts[Index], IdatLengths[Index])
		Fill += IdatLengths[Index]
	end

	const Width = Info.Width
	const Height = Info.Height
	const Passes = if IsInterlaced then AdamPasses else { { 0, 0, 1, 1 } }
	local RawLength = 0

	for _, Pass in Passes do
		const PassWidth = PassSize(Width, Pass[1], Pass[3])
		const PassHeight = PassSize(Height, Pass[2], Pass[4])

		if PassWidth > 0 and PassHeight > 0 then
			RawLength += PassHeight * (1 + RowBytesOf(PassWidth, Info.Channels, Info.Depth))
		end
	end

	const Raw = Inflate(Compressed, RawLength)
	const Pixels = buffer.create(Width * Height * 4)
	local Offset = 0

	for _, Pass in Passes do
		const PassWidth = PassSize(Width, Pass[1], Pass[3])
		const PassHeight = PassSize(Height, Pass[2], Pass[4])

		if PassWidth > 0 and PassHeight > 0 then
			const Rows, NextOffset = UnfilterPass(Raw, Offset, PassWidth, PassHeight, Info.Channels, Info.Depth)

			Offset = NextOffset

			WritePassPixels(Info, Rows, PassWidth, PassHeight, Pixels, Pass[1], Pass[2], Pass[3], Pass[4])
		end
	end

	return { Width = Width, Height = Height, Pixels = Pixels }
end

-- Godot's Image.LoadPngFromBuffer: nil for data this decoder cannot read (see DecodePngUnchecked).
const function DecodePng(Input: buffer): Image?
	const Success, Result = pcall(DecodePngUnchecked, Input)

	if Success then
		return Result
	end

	return nil
end

-- JPEG (ITU-T T.81). Baseline and progressive Huffman, 8-bit, 1 or 3 components. Coefficients are stored in natural
-- order; the IDCT is libjpeg's islow (jidctint.c, integer, CONST_BITS 13, PASS1_BITS 2) and chroma upsampling is
-- libjpeg's fancy (triangle) filter for 2:1 factors.

const JpegZigZag = {
	0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
}

const JpegLookupBits = 9

-- Counts[Length] (1..16) codes of each length, Values in order of increasing length (T.81 Annex C).
const function BuildJpegHuffman(Counts: { number }, Values: { number }): JpegHuffman
	const MinCode = table.create(17, 0)
	const MaxCode = table.create(17, -1)
	const ValPtr = table.create(17, 0)
	const Lookup = table.create(2 ^ JpegLookupBits, 0)
	local Code = 0
	local Index = 0

	for Length = 1, 16 do
		ValPtr[Length] = Index
		MinCode[Length] = Code

		for Offset = 0, Counts[Length] - 1 do
			if Length <= JpegLookupBits then
				const Prefix = (Code + Offset) * 2 ^ (JpegLookupBits - Length)

				for Fill = 0, 2 ^ (JpegLookupBits - Length) - 1 do
					Lookup[Prefix + Fill + 1] = Values[Index + Offset + 1] * 16 + Length
				end
			end
		end

		Code += Counts[Length]
		Index += Counts[Length]

		if Counts[Length] > 0 then
			MaxCode[Length] = Code - 1
		end

		Code *= 2
	end

	return { Lookup = Lookup, MinCode = MinCode, MaxCode = MaxCode, ValPtr = ValPtr, Values = Values }
end

-- Entropy-coded segment reader: MSB-first bits with 0xFF00 unstuffing. A marker ends the data: zero bits follow it.
const function JpegNextByte(Reader: JpegBits): number
	if Reader.Marker then
		return 0
	end

	while Reader.Position < Reader.End do
		const Byte = buffer.readu8(Reader.Data, Reader.Position)

		if Byte ~= 0xFF then
			Reader.Position += 1

			return Byte
		end

		const Next = if Reader.Position + 1 < Reader.End then buffer.readu8(Reader.Data, Reader.Position + 1) else 0xD9

		if Next == 0x00 then
			Reader.Position += 2

			return 0xFF
		elseif Next == 0xFF then
			Reader.Position += 1
		else
			break
		end
	end

	Reader.Marker = true

	return 0
end

const function JpegPeek(Reader: JpegBits, Count: number): number
	while Reader.Count < 25 do
		Reader.Buffer = Reader.Buffer * 256 + JpegNextByte(Reader)
		Reader.Count += 8
	end

	return Reader.Buffer // 2 ^ (Reader.Count - Count)
end

const function JpegConsume(Reader: JpegBits, Count: number)
	Reader.Count -= Count
	Reader.Buffer %= 2 ^ Reader.Count
end

const function JpegReceive(Reader: JpegBits, Count: number): number
	if Count == 0 then
		return 0
	end

	const Value = JpegPeek(Reader, Count)

	JpegConsume(Reader, Count)

	return Value
end

const function JpegSymbol(Reader: JpegBits, Table: JpegHuffman): number
	const Entry = Table.Lookup[JpegPeek(Reader, JpegLookupBits) + 1]

	if Entry ~= 0 then
		const Length = Entry % 16

		JpegConsume(Reader, Length)

		return (Entry - Length) // 16
	end

	for Length = JpegLookupBits + 1, 16 do
		const Code = JpegPeek(Reader, Length)

		if Table.MaxCode[Length] >= 0 and Code <= Table.MaxCode[Length] then
			JpegConsume(Reader, Length)

			return Table.Values[Table.ValPtr[Length] + Code - Table.MinCode[Length] + 1]
		end
	end

	error("Invalid data: JPEG Huffman code.", 0)
end

-- Sign extension of a Size-bit magnitude (T.81 F.2.2.1).
const function JpegExtend(Value: number, Size: number): number
	if Size == 0 then
		return 0
	end

	if Value < 2 ^ (Size - 1) then
		return Value - 2 ^ Size + 1
	end

	return Value
end

-- Coefficient storage: 64 int32 per block, natural order, block (Row, Column) at (Row * BlocksPerLine + Column) * 256.
const BlockBytes = 256

const function BlockBase(Component: JpegComponent, Row: number, Column: number): number
	return (Row * Component.BlocksPerLine + Column) * BlockBytes
end

-- Coefficient bit p of a value, two's complement (the bit test of libjpeg's AC refinement).
const function BitSet(Value: number, Bit: number): boolean
	return (Value // 2 ^ Bit) % 2 == 1
end

-- DC of a block at the first scan of a band (T.81 G.1.2.1, libjpeg decode_mcu_DC_first).
const function DecodeDcFirst(Reader: JpegBits, Component: JpegComponent, Base: number, Table: JpegHuffman, Al: number)
	const Size = JpegSymbol(Reader, Table)

	Component.DcPredictor += JpegExtend(JpegReceive(Reader, Size), Size)

	buffer.writei32(Component.Coefficients, Base, Component.DcPredictor * 2 ^ Al)
end

-- DC refinement bit (libjpeg decode_mcu_DC_refine: OR of the bit Al).
const function DecodeDcRefine(Reader: JpegBits, Component: JpegComponent, Base: number, Al: number)
	if JpegReceive(Reader, 1) == 1 then
		const Value = buffer.readi32(Component.Coefficients, Base)

		if not BitSet(Value, Al) then
			buffer.writei32(Component.Coefficients, Base, Value + 2 ^ Al)
		end
	end
end

-- AC first pass over Ss..Se (libjpeg decode_mcu_AC_first), with end-of-band runs.
const function DecodeAcFirst(Reader: JpegBits, Component: JpegComponent, Base: number, Table: JpegHuffman, Ss: number, Se: number, Al: number, State: JpegScanState)
	if State.EobRun > 0 then
		State.EobRun -= 1

		return
	end

	local K = Ss

	while K <= Se do
		const Symbol = JpegSymbol(Reader, Table)
		const Run = Symbol // 16
		const Size = Symbol % 16

		if Size ~= 0 then
			K += Run

			if K > Se then
				error("Invalid data: JPEG coefficient index.", 0)
			end

			const Value = JpegExtend(JpegReceive(Reader, Size), Size)

			buffer.writei32(Component.Coefficients, Base + JpegZigZag[K + 1] * 4, Value * 2 ^ Al)
			K += 1
		elseif Run == 15 then
			K += 16
		else
			State.EobRun = 2 ^ Run + JpegReceive(Reader, Run) - 1

			break
		end
	end
end

-- AC refinement pass (libjpeg decode_mcu_AC_refine): appends correction bits to nonzero coefficients and places
-- new +/-1 coefficients among the zero ones.
const function DecodeAcRefine(Reader: JpegBits, Component: JpegComponent, Base: number, Table: JpegHuffman, Ss: number, Se: number, Al: number, State: JpegScanState)
	const Positive = 2 ^ Al
	const Negative = -Positive
	local K = Ss

	if State.EobRun == 0 then
		while K <= Se do
			const Symbol = JpegSymbol(Reader, Table)
			local Run = Symbol // 16
			local NewValue = 0

			if Symbol % 16 ~= 0 then
				NewValue = if JpegReceive(Reader, 1) == 1 then Positive else Negative
			elseif Run ~= 15 then
				State.EobRun = 2 ^ Run + JpegReceive(Reader, Run)

				break
			end

			repeat
				const Natural = JpegZigZag[K + 1] * 4
				const Coefficient = buffer.readi32(Component.Coefficients, Base + Natural)

				if Coefficient ~= 0 then
					if JpegReceive(Reader, 1) == 1 and not BitSet(Coefficient, Al) then
						buffer.writei32(Component.Coefficients, Base + Natural, Coefficient + (if Coefficient >= 0 then Positive else Negative))
					end
				else
					if Run == 0 then
						break
					end

					Run -= 1
				end

				K += 1
			until K > Se

			if NewValue ~= 0 then
				if K > Se then
					error("Invalid data: JPEG refinement index.", 0)
				end

				buffer.writei32(Component.Coefficients, Base + JpegZigZag[K + 1] * 4, NewValue)
			end

			K += 1
		end
	end

	if State.EobRun > 0 then
		while K <= Se do
			const Natural = JpegZigZag[K + 1] * 4
			const Coefficient = buffer.readi32(Component.Coefficients, Base + Natural)

			if Coefficient ~= 0 and JpegReceive(Reader, 1) == 1 and not BitSet(Coefficient, Al) then
				buffer.writei32(Component.Coefficients, Base + Natural, Coefficient + (if Coefficient >= 0 then Positive else Negative))
			end

			K += 1
		end

		State.EobRun -= 1
	end
end

-- Baseline blocks are DC first plus AC first over 1..63 with Al = 0.
const function DecodeBlock(Reader: JpegBits, Entry: JpegScanEntry, Base: number, Progressive: boolean, Ss: number, Se: number, Ah: number, Al: number, State: JpegScanState)
	const Component = Entry.Component

	if not Progressive then
		DecodeDcFirst(Reader, Component, Base, Entry.DcTable, 0)
		DecodeAcFirst(Reader, Component, Base, Entry.AcTable, 1, 63, 0, State)
	elseif Ss == 0 then
		if Ah == 0 then
			DecodeDcFirst(Reader, Component, Base, Entry.DcTable, Al)
		else
			DecodeDcRefine(Reader, Component, Base, Al)
		end
	elseif Ah == 0 then
		DecodeAcFirst(Reader, Component, Base, Entry.AcTable, Ss, Se, Al, State)
	else
		DecodeAcRefine(Reader, Component, Base, Entry.AcTable, Ss, Se, Al, State)
	end
end

-- Moves past a restart marker (RSTn) and clears the bit reader and the predictors (T.81 F.2.2.5).
const function RestartScan(Reader: JpegBits, Entries: { JpegScanEntry }, State: JpegScanState)
	for _, Entry in Entries do
		Entry.Component.DcPredictor = 0
	end

	State.EobRun = 0
	Reader.Buffer = 0
	Reader.Count = 0
	Reader.Marker = false

	while Reader.Position + 1 < Reader.End do
		if buffer.readu8(Reader.Data, Reader.Position) == 0xFF then
			const Marker = buffer.readu8(Reader.Data, Reader.Position + 1)

			if Marker >= 0xD0 and Marker <= 0xD7 then
				Reader.Position += 2

				return
			end
		end

		Reader.Position += 1
	end

	error("Invalid data: JPEG restart marker missing.", 0)
end

-- Decodes one scan's entropy-coded data. Restart interval counts MCUs (one block for a single-component scan).
const function DecodeScan(Reader: JpegBits, Entries: { JpegScanEntry }, Frame: JpegFrame, Progressive: boolean, Ss: number, Se: number, Ah: number, Al: number)
	const State = { EobRun = 0 }

	if #Entries == 1 then
		const Component = Entries[1].Component
		const ComponentWidth = (Frame.Width * Component.H + Frame.MaxH - 1) // Frame.MaxH
		const ComponentHeight = (Frame.Height * Component.V + Frame.MaxV - 1) // Frame.MaxV
		const BlocksWide = (ComponentWidth + 7) // 8
		const BlocksHigh = (ComponentHeight + 7) // 8

		for Unit = 0, BlocksWide * BlocksHigh - 1 do
			if Frame.RestartInterval > 0 and Unit > 0 and Unit % Frame.RestartInterval == 0 then
				RestartScan(Reader, Entries, State)
			end

			DecodeBlock(Reader, Entries[1], BlockBase(Component, Unit // BlocksWide, Unit % BlocksWide), Progressive, Ss, Se, Ah, Al, State)
		end

		return
	end

	for Mcu = 0, Frame.McusPerLine * Frame.McusPerColumn - 1 do
		if Frame.RestartInterval > 0 and Mcu > 0 and Mcu % Frame.RestartInterval == 0 then
			RestartScan(Reader, Entries, State)
		end

		const McuRow = Mcu // Frame.McusPerLine
		const McuColumn = Mcu % Frame.McusPerLine

		for _, Entry in Entries do
			const Component = Entry.Component

			for V = 0, Component.V - 1 do
				for H = 0, Component.H - 1 do
					DecodeBlock(Reader, Entry, BlockBase(Component, McuRow * Component.V + V, McuColumn * Component.H + H), Progressive, Ss, Se, Ah, Al, State)
				end
			end
		end
	end
end

-- One 8-point inverse DCT (libjpeg jidctint.c jpeg_idct_islow, from T.81 Annex A): Shift is the descale amount.
const function IdctCore(
	I0: number,
	I1: number,
	I2: number,
	I3: number,
	I4: number,
	I5: number,
	I6: number,
	I7: number,
	Shift: number
): (number, number, number, number, number, number, number, number)
	const Half = 2 ^ (Shift - 1)
	const Scale = 2 ^ Shift

	const EvenZ = (I2 + I6) * 4433
	const EvenA = EvenZ - I6 * 15137
	const EvenB = EvenZ + I2 * 6270
	const Sum04 = (I0 + I4) * 8192
	const Diff04 = (I0 - I4) * 8192
	const Ev0 = Sum04 + EvenB
	const Ev3 = Sum04 - EvenB
	const Ev1 = Diff04 + EvenA
	const Ev2 = Diff04 - EvenA

	const OddZ3 = I7 + I3
	const OddZ4 = I5 + I1
	const OddZ5 = (OddZ3 + OddZ4) * 9633
	const Q1 = (I7 + I1) * -7373
	const Q2 = (I5 + I3) * -20995
	const Q3 = OddZ3 * -16069 + OddZ5
	const Q4 = OddZ4 * -3196 + OddZ5
	const O0 = I7 * 2446 + Q1 + Q3
	const O1 = I5 * 16819 + Q2 + Q4
	const O2 = I3 * 25172 + Q2 + Q3
	const O3 = I1 * 12299 + Q1 + Q4

	return (Ev0 + O3 + Half) // Scale,
		(Ev1 + O2 + Half) // Scale,
		(Ev2 + O1 + Half) // Scale,
		(Ev3 + O0 + Half) // Scale,
		(Ev3 - O0 + Half) // Scale,
		(Ev2 - O1 + Half) // Scale,
		(Ev1 - O2 + Half) // Scale,
		(Ev0 - O3 + Half) // Scale
end

-- Dequantized coefficient at natural index Index of a block.
const function Dequantized(Coefficients: buffer, Base: number, Quant: { number }, Index: number): number
	return buffer.readi32(Coefficients, Base + Index * 4) * Quant[Index + 1]
end

-- Inverse DCT of one block into Plane (8-bit samples, +128 level shift). Work is a 64-entry int32 scratch buffer.
-- Columns first, then rows; all-zero AC terms take the exact DC shortcuts of libjpeg.
const function IdctBlock(Coefficients: buffer, Base: number, Quant: { number }, Work: buffer, Plane: buffer, PlaneBase: number, Stride: number)
	for Column = 0, 7 do
		const I0 = Dequantized(Coefficients, Base, Quant, Column)
		const I1 = Dequantized(Coefficients, Base, Quant, 8 + Column)
		const I2 = Dequantized(Coefficients, Base, Quant, 16 + Column)
		const I3 = Dequantized(Coefficients, Base, Quant, 24 + Column)
		const I4 = Dequantized(Coefficients, Base, Quant, 32 + Column)
		const I5 = Dequantized(Coefficients, Base, Quant, 40 + Column)
		const I6 = Dequantized(Coefficients, Base, Quant, 48 + Column)
		const I7 = Dequantized(Coefficients, Base, Quant, 56 + Column)

		if I1 == 0 and I2 == 0 and I3 == 0 and I4 == 0 and I5 == 0 and I6 == 0 and I7 == 0 then
			for Row = 0, 7 do
				buffer.writei32(Work, (Row * 8 + Column) * 4, I0 * 4)
			end
		else
			const O0, O1, O2, O3, O4, O5, O6, O7 = IdctCore(I0, I1, I2, I3, I4, I5, I6, I7, 11)

			buffer.writei32(Work, Column * 4, O0)
			buffer.writei32(Work, (8 + Column) * 4, O1)
			buffer.writei32(Work, (16 + Column) * 4, O2)
			buffer.writei32(Work, (24 + Column) * 4, O3)
			buffer.writei32(Work, (32 + Column) * 4, O4)
			buffer.writei32(Work, (40 + Column) * 4, O5)
			buffer.writei32(Work, (48 + Column) * 4, O6)
			buffer.writei32(Work, (56 + Column) * 4, O7)
		end
	end

	for Row = 0, 7 do
		const RowBase = Row * 8 * 4
		const W0 = buffer.readi32(Work, RowBase)
		const W1 = buffer.readi32(Work, RowBase + 4)
		const W2 = buffer.readi32(Work, RowBase + 8)
		const W3 = buffer.readi32(Work, RowBase + 12)
		const W4 = buffer.readi32(Work, RowBase + 16)
		const W5 = buffer.readi32(Work, RowBase + 20)
		const W6 = buffer.readi32(Work, RowBase + 24)
		const W7 = buffer.readi32(Work, RowBase + 28)
		const OutputBase = PlaneBase + Row * Stride

		if W1 == 0 and W2 == 0 and W3 == 0 and W4 == 0 and W5 == 0 and W6 == 0 and W7 == 0 then
			const Value = Clamp255((W0 + 16) // 32 + 128)

			for Column = 0, 7 do
				buffer.writeu8(Plane, OutputBase + Column, Value)
			end
		else
			const O0, O1, O2, O3, O4, O5, O6, O7 = IdctCore(W0, W1, W2, W3, W4, W5, W6, W7, 18)

			buffer.writeu8(Plane, OutputBase, Clamp255(O0 + 128))
			buffer.writeu8(Plane, OutputBase + 1, Clamp255(O1 + 128))
			buffer.writeu8(Plane, OutputBase + 2, Clamp255(O2 + 128))
			buffer.writeu8(Plane, OutputBase + 3, Clamp255(O3 + 128))
			buffer.writeu8(Plane, OutputBase + 4, Clamp255(O4 + 128))
			buffer.writeu8(Plane, OutputBase + 5, Clamp255(O5 + 128))
			buffer.writeu8(Plane, OutputBase + 6, Clamp255(O6 + 128))
			buffer.writeu8(Plane, OutputBase + 7, Clamp255(O7 + 128))
		end
	end
end

-- A component plane at its own resolution: ComponentWidth x ComponentHeight samples used, rows Stride bytes apart.
const function SourceAt(Source: JpegSource, Column: number, Row: number): number
	const Clamped = if Column < 0 then 0 elseif Column >= Source.Width then Source.Width - 1 else Column
	const ClampedRow = if Row < 0 then 0 elseif Row >= Source.Height then Source.Height - 1 else Row

	return buffer.readu8(Source.Plane, ClampedRow * Source.Stride + Clamped)
end

-- Full-resolution sample at (X, Y). 2:1 factors use libjpeg's fancy (triangle) upsampling when the component is wider
-- than 2 samples (h2v1, h2v2), and always for h1v2; other factors replicate the nearest sample.
const function ComponentSample(Source: JpegSource, X: number, Y: number): number
	const Horizontal = Source.HorizontalFactor
	const Vertical = Source.VerticalFactor

	if Horizontal == 1 and Vertical == 1 then
		return buffer.readu8(Source.Plane, Y * Source.Stride + X)
	end

	if Horizontal == 1 and Vertical == 2 then
		const Row = Y // 2
		const Neighbor = if Y % 2 == 0 then Row - 1 else Row + 1
		const Bias = if Y % 2 == 0 then 1 else 2

		return (3 * SourceAt(Source, X, Row) + SourceAt(Source, X, Neighbor) + Bias) // 4
	end

	if Horizontal ~= 2 or Vertical > 2 or Source.Width <= 2 then
		return SourceAt(Source, X // Horizontal, Y // Vertical)
	end

	const Column = X // 2

	if Vertical == 1 then
		if X % 2 == 0 then
			return (3 * SourceAt(Source, Column, Y) + SourceAt(Source, Column - 1, Y) + 1) // 4
		end

		return (3 * SourceAt(Source, Column, Y) + SourceAt(Source, Column + 1, Y) + 2) // 4
	end

	const Row = Y // 2
	const Neighbor = if Y % 2 == 0 then Row - 1 else Row + 1
	const Here = 3 * SourceAt(Source, Column, Row) + SourceAt(Source, Column, Neighbor)

	if X % 2 == 0 then
		const Before = 3 * SourceAt(Source, Column - 1, Row) + SourceAt(Source, Column - 1, Neighbor)

		return (3 * Here + Before + 8) // 16
	end

	const After = 3 * SourceAt(Source, Column + 1, Row) + SourceAt(Source, Column + 1, Neighbor)

	return (3 * Here + After + 7) // 16
end

-- libjpeg jdcolor.c YCbCr to RGB tables (SCALEBITS 16), indexed by chroma value + 1.
const FixedCrRed = (1.40200 * 65536 + 0.5) // 1
const FixedCbBlue = (1.77200 * 65536 + 0.5) // 1
const FixedCrGreen = (0.71414 * 65536 + 0.5) // 1
const FixedCbGreen = (0.34414 * 65536 + 0.5) // 1
const HalfFix = 32768

const function ChromaTables(): ({ number }, { number }, { number }, { number })
	const CrRed = table.create(256, 0)
	const CbBlue = table.create(256, 0)
	const CrGreen = table.create(256, 0)
	const CbGreen = table.create(256, 0)

	for Value = 0, 255 do
		const Offset = Value - 128

		CrRed[Value + 1] = (FixedCrRed * Offset + HalfFix) // 65536
		CbBlue[Value + 1] = (FixedCbBlue * Offset + HalfFix) // 65536
		CrGreen[Value + 1] = -FixedCrGreen * Offset
		CbGreen[Value + 1] = -FixedCbGreen * Offset + HalfFix
	end

	return CrRed, CbBlue, CrGreen, CbGreen
end

-- Segment helpers (big-endian).
const function ReadBe16(Data: buffer, Offset: number): number
	return buffer.readu8(Data, Offset) * 256 + buffer.readu8(Data, Offset + 1)
end

-- DEVIATION(jpeg exif): EXIF orientation is not applied (Godot's JPEG loader does not rotate either).
-- DEVIATION(jpeg colorspace): CMYK and YCCK (4 components) and 12-bit or arithmetic/lossless JPEG are refused (nil).
const function DecodeJpegUnchecked(Input: buffer): Image
	const Length = buffer.len(Input)

	if Length < 4 or buffer.readu8(Input, 0) ~= 0xFF or buffer.readu8(Input, 1) ~= 0xD8 then
		error("JPEG signature invalid.", 0)
	end

	const Quantization: { { number } } = {}
	const DcTables: { JpegHuffman } = {}
	const AcTables: { JpegHuffman } = {}
	local Frame: JpegFrame? = nil
	local Progressive = false
	local RestartInterval = 0
	local Adobe = -1
	local Jfif = false
	local Position = 2

	while Position < Length do
		if buffer.readu8(Input, Position) ~= 0xFF then
			Position += 1
		else
			local Marker = buffer.readu8(Input, Position + 1)

			Position += 2

			while Marker == 0xFF and Position < Length do
				Marker = buffer.readu8(Input, Position)
				Position += 1
			end

			if Marker == 0xD9 then
				break
			end

			if Marker ~= 0 and Marker ~= 0x01 and Marker ~= 0xD8 and not (Marker >= 0xD0 and Marker <= 0xD7) then
				const Segment = Position + 2
				const Next = Position + ReadBe16(Input, Position)

				if Next > Length then
					error("JPEG segment truncated.", 0)
				end

				if Marker == 0xC0 or Marker == 0xC1 or Marker == 0xC2 then
					if Frame ~= nil then
						error("JPEG has more than one frame.", 0)
					end

					Progressive = Marker == 0xC2

					if buffer.readu8(Input, Segment) ~= 8 then
						error("JPEG precision not supported.", 0)
					end

					const Height = ReadBe16(Input, Segment + 1)
					const Width = ReadBe16(Input, Segment + 3)
					const ComponentCount = buffer.readu8(Input, Segment + 5)

					if ComponentCount ~= 1 and ComponentCount ~= 3 or Width == 0 or Height == 0 then
						error("JPEG frame not supported.", 0)
					end

					const Components: { JpegComponent } = {}
					local MaxH = 1
					local MaxV = 1

					for Index = 0, ComponentCount - 1 do
						const Sampling = buffer.readu8(Input, Segment + 7 + Index * 3)
						const Horizontal = Sampling // 16
						const Vertical = Sampling % 16

						if Horizontal < 1 or Horizontal > 4 or Vertical < 1 or Vertical > 4 or buffer.readu8(Input, Segment + 8 + Index * 3) > 3 then
							error("JPEG sampling not supported.", 0)
						end

						table.insert(Components, {
							Id = buffer.readu8(Input, Segment + 6 + Index * 3),
							H = Horizontal,
							V = Vertical,
							QuantTable = buffer.readu8(Input, Segment + 8 + Index * 3),
							BlocksPerLine = 0,
							BlocksPerColumn = 0,
							Coefficients = buffer.create(0),
							DcPredictor = 0,
							DcTable = 0,
							AcTable = 0,
						})

						MaxH = math.max(MaxH, Horizontal)
						MaxV = math.max(MaxV, Vertical)
					end

					const McusPerLine = (Width + 8 * MaxH - 1) // (8 * MaxH)
					const McusPerColumn = (Height + 8 * MaxV - 1) // (8 * MaxV)

					for _, Component in Components do
						if MaxH % Component.H ~= 0 or MaxV % Component.V ~= 0 then
							error("JPEG fractional sampling not supported.", 0)
						end

						Component.BlocksPerLine = McusPerLine * Component.H
						Component.BlocksPerColumn = McusPerColumn * Component.V
						Component.Coefficients = buffer.create(Component.BlocksPerLine * Component.BlocksPerColumn * BlockBytes)
					end

					Frame = {
						Width = Width,
						Height = Height,
						MaxH = MaxH,
						MaxV = MaxV,
						McusPerLine = McusPerLine,
						McusPerColumn = McusPerColumn,
						RestartInterval = 0,
						Components = Components,
						Quantization = Quantization,
						DcTables = DcTables,
						AcTables = AcTables,
					}
				elseif Marker == 0xC3 or (Marker >= 0xC5 and Marker <= 0xC7) or (Marker >= 0xC9 and Marker <= 0xCB) or (Marker >= 0xCD and Marker <= 0xCF) then
					error("JPEG process not supported.", 0)
				elseif Marker == 0xC4 then
					local Table = Segment

					while Table < Next do
						const Class = buffer.readu8(Input, Table) // 16
						const Destination = buffer.readu8(Input, Table) % 16
						const Counts = table.create(16, 0)
						local Total = 0

						for CodeLength = 1, 16 do
							Counts[CodeLength] = buffer.readu8(Input, Table + CodeLength)
							Total += Counts[CodeLength]
						end

						const Values = table.create(Total, 0)

						for Index = 1, Total do
							Values[Index] = buffer.readu8(Input, Table + 16 + Index)
						end

						if Destination > 3 then
							error("JPEG table index.", 0)
						end

						if Class == 0 then
							DcTables[Destination + 1] = BuildJpegHuffman(Counts, Values)
						else
							AcTables[Destination + 1] = BuildJpegHuffman(Counts, Values)
						end

						Table += 17 + Total
					end
				elseif Marker == 0xDB then
					local Table = Segment

					while Table < Next do
						const Precision = buffer.readu8(Input, Table) // 16
						const Destination = buffer.readu8(Input, Table) % 16
						const Quant = table.create(64, 0)

						if Destination > 3 then
							error("JPEG quantization table index.", 0)
						end

						for Index = 0, 63 do
							Quant[JpegZigZag[Index + 1] + 1] = if Precision == 0 then buffer.readu8(Input, Table + 1 + Index) else ReadBe16(Input, Table + 1 + Index * 2)
						end

						Quantization[Destination + 1] = Quant
						Table += if Precision == 0 then 65 else 129
					end
				elseif Marker == 0xDD then
					RestartInterval = ReadBe16(Input, Segment)
				elseif Marker == 0xDA then
					if Frame == nil then
						error("JPEG scan before frame.", 0)
					end

					const Current: JpegFrame = Frame
					const ScanCount = buffer.readu8(Input, Segment)
					const SpectralStart = buffer.readu8(Input, Segment + 1 + ScanCount * 2)
					const SpectralEnd = buffer.readu8(Input, Segment + 2 + ScanCount * 2)
					const Approximation = buffer.readu8(Input, Segment + 3 + ScanCount * 2)
					const Entries: { JpegScanEntry } = {}

					for Index = 0, ScanCount - 1 do
						const Selector = buffer.readu8(Input, Segment + 1 + Index * 2)
						const Tables = buffer.readu8(Input, Segment + 2 + Index * 2)
						local Component: JpegComponent? = nil

						for _, Candidate in Current.Components do
							if Candidate.Id == Selector then
								Component = Candidate
							end
						end

						if Component == nil then
							error("JPEG scan component.", 0)
						end

						const Found: JpegComponent = Component
						const DcIndex = Tables // 16
						const AcIndex = Tables % 16

						if DcIndex > 3 or AcIndex > 3 then
							error("JPEG Huffman table index.", 0)
						end

						if (SpectralStart == 0 and Current.DcTables[DcIndex + 1] == nil) or (SpectralEnd > 0 and Current.AcTables[AcIndex + 1] == nil) then
							error("JPEG Huffman table missing.", 0)
						end

						Found.DcTable = DcIndex
						Found.AcTable = AcIndex

						table.insert(Entries, {
							Component = Found,
							DcTable = Current.DcTables[DcIndex + 1],
							AcTable = Current.AcTables[AcIndex + 1],
						})
					end

					Current.RestartInterval = RestartInterval

					const Reader = { Data = Input, Position = Next, End = Length, Buffer = 0, Count = 0, Marker = false }

					DecodeScan(Reader, Entries, Current, Progressive, SpectralStart, SpectralEnd, Approximation // 16, Approximation % 16)

					Position = Reader.Position

					continue
				elseif Marker >= 0xE0 and Marker <= 0xEF then
					if Marker == 0xE0 and buffer.readstring(Input, Segment, 5) == "JFIF\0" then
						Jfif = true
					elseif Marker == 0xEE and buffer.readstring(Input, Segment, 5) == "Adobe" then
						Adobe = buffer.readu8(Input, Segment + 11)
					end
				end

				Position = Next
			end
		end
	end

	if Frame == nil then
		error("JPEG has no frame.", 0)
	end

	const Output: JpegFrame = Frame
	const ComponentCount = #Output.Components
	const Sources: { JpegSource } = {}
	const Work = buffer.create(BlockBytes)

	for Index, Component in Output.Components do
		const Stride = Component.BlocksPerLine * 8
		const Plane = buffer.create(Stride * Component.BlocksPerColumn * 8)
		const Quant = Output.Quantization[Component.QuantTable + 1]

		if Quant == nil then
			error("JPEG quantization table missing.", 0)
		end

		for Row = 0, Component.BlocksPerColumn - 1 do
			for Column = 0, Component.BlocksPerLine - 1 do
				IdctBlock(Component.Coefficients, BlockBase(Component, Row, Column), Quant, Work, Plane, Row * 8 * Stride + Column * 8, Stride)
			end
		end

		Sources[Index] = {
			Plane = Plane,
			Stride = Stride,
			Width = (Output.Width * Component.H + Output.MaxH - 1) // Output.MaxH,
			Height = (Output.Height * Component.V + Output.MaxV - 1) // Output.MaxV,
			HorizontalFactor = Output.MaxH // Component.H,
			VerticalFactor = Output.MaxV // Component.V,
		}
	end

	-- Color space as libjpeg's default: JFIF means YCbCr, an Adobe marker decides, else R/G/B ids mean RGB.
	local Rgb = false

	if ComponentCount == 3 then
		if not Jfif and Adobe >= 0 then
			Rgb = Adobe == 0
		elseif not Jfif then
			Rgb = Output.Components[1].Id == 82 and Output.Components[2].Id == 71 and Output.Components[3].Id == 66
		end
	end

	const Pixels = buffer.create(Output.Width * Output.Height * 4)
	const CrRed, CbBlue, CrGreen, CbGreen = ChromaTables()

	for Row = 0, Output.Height - 1 do
		for Column = 0, Output.Width - 1 do
			const Target = (Row * Output.Width + Column) * 4
			local Red: number
			local Green: number
			local Blue: number

			if ComponentCount == 1 then
				Red = ComponentSample(Sources[1], Column, Row)
				Green = Red
				Blue = Red
			else
				const First = ComponentSample(Sources[1], Column, Row)
				const Second = ComponentSample(Sources[2], Column, Row)
				const Third = ComponentSample(Sources[3], Column, Row)

				if Rgb then
					Red = First
					Green = Second
					Blue = Third
				else
					Red = Clamp255(First + CrRed[Third + 1])
					Green = Clamp255(First + (CbGreen[Second + 1] + CrGreen[Third + 1]) // 65536)
					Blue = Clamp255(First + CbBlue[Second + 1])
				end
			end

			buffer.writeu8(Pixels, Target, Red)
			buffer.writeu8(Pixels, Target + 1, Green)
			buffer.writeu8(Pixels, Target + 2, Blue)
			buffer.writeu8(Pixels, Target + 3, 255)
		end
	end

	return { Width = Output.Width, Height = Output.Height, Pixels = Pixels }
end

-- Godot's Image.LoadJpgFromBuffer: nil for data this decoder cannot read (see DecodeJpegUnchecked).
const function DecodeJpeg(Input: buffer): Image?
	const Success, Result = pcall(DecodeJpegUnchecked, Input)

	if Success then
		return Result
	end

	return nil
end

-- Dispatch by file signature in the order of scripts/util/Misc.cs LoadImageFromBuffer (PNG, JPEG, BMP, WebP). Answers
-- nil when no decoder reads the data; nothing is logged here.
const function Decode(Buffer: buffer): Image?
	const Length = buffer.len(Buffer)

	if Length >= 4 and buffer.readu8(Buffer, 0) == 137 and buffer.readu8(Buffer, 1) == 80 and buffer.readu8(Buffer, 2) == 78 and buffer.readu8(Buffer, 3) == 71 then
		const Png = DecodePng(Buffer)

		if Png ~= nil then
			return Png
		end
	end

	if Length >= 3 and buffer.readu8(Buffer, 0) == 0xFF and buffer.readu8(Buffer, 1) == 0xD8 and buffer.readu8(Buffer, 2) == 0xFF then
		const Jpeg = DecodeJpeg(Buffer)

		if Jpeg ~= nil then
			return Jpeg
		end
	end

	if Length >= 2 and buffer.readu8(Buffer, 0) == 0x42 and buffer.readu8(Buffer, 1) == 0x4D then
		const Bmp = DecodeBmp(Buffer)

		if Bmp ~= nil then
			return Bmp
		end
	end

	if Length >= 12 and buffer.readstring(Buffer, 0, 4) == "RIFF" and buffer.readstring(Buffer, 8, 4) == "WEBP" then
		const Webp = DecodeWebp(Buffer)

		if Webp ~= nil then
			return Webp
		end
	end

	return nil
end

return {
	DecodeBmp = DecodeBmp,
	DecodeWebp = DecodeWebp,
	DecodePng = DecodePng,
	DecodeJpeg = DecodeJpeg,
	Decode = Decode,
}
