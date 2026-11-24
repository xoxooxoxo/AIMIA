--!strict
--!optimize 2

--[[
	MD5 (RFC 1321) over buffers, as System.Security.Cryptography.MD5 that the source uses in Misc.HashFiles and
	MapCache.GetMd5Checksum. No @src tag: MD5 replaces the BCL class, there is no C# source for it in reference/Client.

	Design Notes
		Hash digests the parts in order, as several MD5.TransformBlock calls followed by TransformFinalBlock(empty).
		Parts are compressed in place; only a block that straddles two parts is copied (into Pending).
		The digest is 16 bytes: the little-endian words A, B, C, D, as MD5.Hash returns it.
		ToHexLower is Convert.ToHexStringLower.
		DEVIATION(platform): Hooks.Digest replaces the Luau digest when the host has a faster one (Roblox's EncodingService hashes
		megabytes in milliseconds, this loop in hundreds). It takes the parts and answers the 16 byte digest.
]]

const RoundConstants = {
	0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
	0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
	0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
	0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
	0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
	0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
	0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
	0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
}

const RoundShifts = {
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

const BlockSize = 64
const LengthWordBytes = 536870912 -- 2^29: the bit length is 8 * bytes, so its low word is 8 * (bytes % 2^29)

-- Runs the 64 steps over the 16-word block at Offset of Source and returns the new state.
const function Compress(Source: buffer, Offset: number, StateA: number, StateB: number, StateC: number, StateD: number): (number, number, number, number)
	local A = StateA
	local B = StateB
	local C = StateC
	local D = StateD

	for Step = 0, 63 do
		local F: number
		local G: number

		if Step < 16 then
			F = bit32.bor(bit32.band(B, C), bit32.band(bit32.bnot(B), D))
			G = Step
		elseif Step < 32 then
			F = bit32.bor(bit32.band(D, B), bit32.band(bit32.bnot(D), C))
			G = (5 * Step + 1) % 16
		elseif Step < 48 then
			F = bit32.bxor(B, bit32.bxor(C, D))
			G = (3 * Step + 5) % 16
		else
			F = bit32.bxor(C, bit32.bor(B, bit32.bnot(D)))
			G = (7 * Step) % 16
		end

		const Sum = bit32.bor(F + A + RoundConstants[Step + 1] + buffer.readu32(Source, Offset + 4 * G), 0)

		A = D
		D = C
		C = B
		B = bit32.bor(B + bit32.lrotate(Sum, RoundShifts[Step + 1]), 0)
	end

	return bit32.bor(StateA + A, 0), bit32.bor(StateB + B, 0), bit32.bor(StateC + C, 0), bit32.bor(StateD + D, 0)
end

const Hooks = {
	Digest = nil :: ((Parts: { buffer }) -> buffer)?,
}

const function Compute(Parts: { buffer }): buffer
	local StateA = 0x67452301
	local StateB = 0xefcdab89
	local StateC = 0x98badcfe
	local StateD = 0x10325476
	const Pending = buffer.create(BlockSize)
	local PendingLength = 0
	local TotalLength = 0

	for _, Part in Parts do
		const PartLength = buffer.len(Part)
		local Offset = 0

		TotalLength += PartLength

		if PendingLength > 0 then
			const Take = math.min(BlockSize - PendingLength, PartLength)

			buffer.copy(Pending, PendingLength, Part, 0, Take)
			PendingLength += Take
			Offset = Take

			if PendingLength < BlockSize then
				continue
			end

			StateA, StateB, StateC, StateD = Compress(Pending, 0, StateA, StateB, StateC, StateD)
			PendingLength = 0
		end

		while Offset + BlockSize <= PartLength do
			StateA, StateB, StateC, StateD = Compress(Part, Offset, StateA, StateB, StateC, StateD)
			Offset += BlockSize
		end

		if Offset < PartLength then
			buffer.copy(Pending, 0, Part, Offset, PartLength - Offset)
			PendingLength = PartLength - Offset
		end
	end

	-- Padding: a 1 bit, zeros, then the 64-bit message length in bits (little-endian), ending a block.
	const FinalLength = if PendingLength < BlockSize - 8 then BlockSize else 2 * BlockSize
	const Final = buffer.create(FinalLength)

	buffer.copy(Final, 0, Pending, 0, PendingLength)
	buffer.writeu8(Final, PendingLength, 0x80)
	buffer.writeu32(Final, FinalLength - 8, (TotalLength % LengthWordBytes) * 8)
	buffer.writeu32(Final, FinalLength - 4, TotalLength // LengthWordBytes)

	StateA, StateB, StateC, StateD = Compress(Final, 0, StateA, StateB, StateC, StateD)

	if FinalLength > BlockSize then
		StateA, StateB, StateC, StateD = Compress(Final, BlockSize, StateA, StateB, StateC, StateD)
	end

	const Digest = buffer.create(16)

	buffer.writeu32(Digest, 0, StateA)
	buffer.writeu32(Digest, 4, StateB)
	buffer.writeu32(Digest, 8, StateC)
	buffer.writeu32(Digest, 12, StateD)

	return Digest
end

const function Hash(Parts: { buffer }): buffer
	const Digest = Hooks.Digest

	if Digest then
		return Digest(Parts)
	end

	return Compute(Parts)
end

const function ToHexLower(Digest: buffer): string
	const Hex: { string } = {}

	for Index = 0, buffer.len(Digest) - 1 do
		table.insert(Hex, string.format("%02x", buffer.readu8(Digest, Index)))
	end

	return table.concat(Hex)
end

return {
	Hooks = Hooks,
	Hash = Hash,
	ToHexLower = ToHexLower,
}
