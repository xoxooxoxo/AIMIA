--!strict
--!optimize 2

--[[
	SHA-256 (FIPS 180-4) over a buffer: System.Security.Cryptography.SHA256.HashData for the leaderboard and replay files,
	which end in their own digest. Pure Luau, so it runs under lute.

	Representation
		Input and output are buffers. The digest is 32 bytes, big-endian words as SHA-256 writes them. The eight state
		words are A..H, as FIPS names them.

	Design Notes
		Words are numbers in [0, 2^32): sums are reduced with Numbers.Uint32, rotations and logic use bit32.
		The padded message is one buffer; no table is created per block except the 64-word schedule, reused per call.
]]

const Numbers = require("../Numbers")

-- The round constants: the first 32 bits of the fractional parts of the cube roots of the first 64 primes (FIPS 180-4 4.2.2).
const RoundConstants = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- The initial hash value: the first 32 bits of the fractional parts of the square roots of the first 8 primes.
const InitialHash = {
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

const BlockSize = 64
const DigestSize = 32

-- The padded length: the message, a 0x80 byte, zeros, then the 64-bit bit length, to a whole number of blocks (FIPS 180-4 5.1.1).
const function PaddedLength(Length: number): number
	return ((Length + 9 + BlockSize - 1) // BlockSize) * BlockSize
end

-- Copies the message into a zeroed buffer of the padded length and appends the length in bits, big-endian.
const function Pad(Data: buffer): buffer
	const Length = buffer.len(Data)
	const Padded = buffer.create(PaddedLength(Length))
	const BitLength = Length * 8

	buffer.copy(Padded, 0, Data)
	buffer.writeu8(Padded, Length, 0x80)

	for Index = 0, 7 do
		const Byte = (BitLength // (2 ^ (8 * Index))) % 256

		buffer.writeu8(Padded, buffer.len(Padded) - 1 - Index, Byte)
	end

	return Padded
end

-- The 32-bit big-endian word at Offset.
const function WordAt(Data: buffer, Offset: number): number
	return bit32.byteswap(buffer.readu32(Data, Offset))
end

-- Sigma helpers of FIPS 180-4 4.1.2 (lowercase sigma for the schedule, uppercase for the rounds).
const function SmallSigma0(Value: number): number
	return bit32.bxor(bit32.rrotate(Value, 7), bit32.rrotate(Value, 18), bit32.rshift(Value, 3))
end

const function SmallSigma1(Value: number): number
	return bit32.bxor(bit32.rrotate(Value, 17), bit32.rrotate(Value, 19), bit32.rshift(Value, 10))
end

const function BigSigma0(Value: number): number
	return bit32.bxor(bit32.rrotate(Value, 2), bit32.rrotate(Value, 13), bit32.rrotate(Value, 22))
end

const function BigSigma1(Value: number): number
	return bit32.bxor(bit32.rrotate(Value, 6), bit32.rrotate(Value, 11), bit32.rrotate(Value, 25))
end

const function Choose(Left: number, Middle: number, Right: number): number
	return bit32.bxor(bit32.band(Left, Middle), bit32.band(bit32.bnot(Left), Right))
end

const function Majority(Left: number, Middle: number, Right: number): number
	return bit32.bxor(bit32.band(Left, Middle), bit32.band(Left, Right), bit32.band(Middle, Right))
end

-- Runs the 64 rounds of one block over the schedule Words (1-based) and updates Hash in place.
const function Compress(Hash: { number }, Words: { number })
	local A, B, C, D, E, F, G, H = Hash[1], Hash[2], Hash[3], Hash[4], Hash[5], Hash[6], Hash[7], Hash[8]

	for Round = 1, 64 do
		const Temporary1 = Numbers.Uint32(H + BigSigma1(E) + Choose(E, F, G) + RoundConstants[Round] + Words[Round])
		const Temporary2 = Numbers.Uint32(BigSigma0(A) + Majority(A, B, C))

		H = G
		G = F
		F = E
		E = Numbers.Uint32(D + Temporary1)
		D = C
		C = B
		B = A
		A = Numbers.Uint32(Temporary1 + Temporary2)
	end

	Hash[1] = Numbers.Uint32(Hash[1] + A)
	Hash[2] = Numbers.Uint32(Hash[2] + B)
	Hash[3] = Numbers.Uint32(Hash[3] + C)
	Hash[4] = Numbers.Uint32(Hash[4] + D)
	Hash[5] = Numbers.Uint32(Hash[5] + E)
	Hash[6] = Numbers.Uint32(Hash[6] + F)
	Hash[7] = Numbers.Uint32(Hash[7] + G)
	Hash[8] = Numbers.Uint32(Hash[8] + H)
end

-- The SHA-256 digest of Data, 32 bytes.
const function Hash(Data: buffer): buffer
	const Padded = Pad(Data)
	const State = table.clone(InitialHash)
	const Words: { number } = table.create(64, 0)

	for BlockStart = 0, buffer.len(Padded) - BlockSize, BlockSize do
		for Index = 1, 16 do
			Words[Index] = WordAt(Padded, BlockStart + (Index - 1) * 4)
		end

		for Index = 17, 64 do
			Words[Index] = Numbers.Uint32(SmallSigma1(Words[Index - 2]) + Words[Index - 7] + SmallSigma0(Words[Index - 15]) + Words[Index - 16])
		end

		Compress(State, Words)
	end

	const Digest = buffer.create(DigestSize)

	for Index = 1, 8 do
		buffer.writeu32(Digest, (Index - 1) * 4, bit32.byteswap(State[Index]))
	end

	return Digest
end

-- Whether two digests (or any two buffers) hold the same bytes.
const function Equal(First: buffer, Second: buffer): boolean
	return buffer.len(First) == buffer.len(Second) and buffer.tostring(First) == buffer.tostring(Second)
end

return {
	Hash = Hash,
	Equal = Equal,
	DigestSize = DigestSize,
}
