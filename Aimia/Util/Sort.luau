--!strict
--!optimize 2

--[[
	Array.Sort<T>(T[]) for T : IComparable<T>, as .NET 10 runs it: GenericArraySortHelper<T> in reference/engine/ArraySortHelper.cs.
	Introspective sort: median-of-three quicksort, insertion sort for partitions of at most 16, heapsort past the depth limit.

	Design Notes
		Keys is a 1-based Luau array sorted in place. Compare answers <0, 0, >0 like CompareTo, called with the source's
		operand order (the pivot first where the source compares the pivot). The sort is not stable: equal keys end up where
		this algorithm leaves them, and that order is observable (note indexes come from it).
		A partition is (First, Count), absolute 1-based indexes: the source's Span slices are index ranges here.
		The reference-type null checks and the NaN pre-pass (float, double, Half only) do not apply to Luau values.
]]

const IntrosortSizeThreshold = 16

-- @src engine/ArraySortHelper.cs:SwapIfGreater L389-395
const function SwapIfGreater<T>(Keys: { T }, Compare: (T, T) -> number, First: number, Second: number)
	if Compare(Keys[First], Keys[Second]) > 0 then
		Keys[First], Keys[Second] = Keys[Second], Keys[First]
	end
end

-- @src engine/ArraySortHelper.cs:InsertionSort L545-560
const function InsertionSort<T>(Keys: { T }, First: number, Count: number, Compare: (T, T) -> number)
	for Index = 0, Count - 2 do
		const Current = Keys[First + Index + 1]
		local Position = Index

		while Position >= 0 and Compare(Current, Keys[First + Position]) < 0 do
			Keys[First + Position + 1] = Keys[First + Position]
			Position -= 1
		end

		Keys[First + Position + 1] = Current
	end
end

-- @src engine/ArraySortHelper.cs:DownHeap L524-543
const function DownHeap<T>(Keys: { T }, First: number, Root: number, Count: number, Compare: (T, T) -> number)
	const Sifted = Keys[First + Root - 1]
	local Position = Root

	while Position <= Count // 2 do
		local Child = 2 * Position

		if Child < Count and Compare(Keys[First + Child - 1], Keys[First + Child]) < 0 then
			Child += 1
		end

		if not (Compare(Sifted, Keys[First + Child - 1]) < 0) then
			break
		end

		Keys[First + Position - 1] = Keys[First + Child - 1]
		Position = Child
	end

	Keys[First + Position - 1] = Sifted
end

-- @src engine/ArraySortHelper.cs:HeapSort L507-522
const function HeapSort<T>(Keys: { T }, First: number, Count: number, Compare: (T, T) -> number)
	for Root = Count // 2, 1, -1 do
		DownHeap(Keys, First, Root, Count, Compare)
	end

	for Size = Count, 2, -1 do
		Keys[First], Keys[First + Size - 1] = Keys[First + Size - 1], Keys[First]
		DownHeap(Keys, First, 1, Size - 1, Compare)
	end
end

-- Returns the pivot's offset from First: the elements before it are <= pivot, the ones after it are >= pivot.
-- @src engine/ArraySortHelper.cs:PickPivotAndPartition L458-505
const function PickPivotAndPartition<T>(Keys: { T }, First: number, Count: number, Compare: (T, T) -> number): number
	const Last = First + Count - 1
	const NextToLast = Last - 1
	const Middle = First + (Count - 1) // 2

	-- Median of three: the first, middle and last elements end up ordered, and the middle one is the pivot.
	SwapIfGreater(Keys, Compare, First, Middle)
	SwapIfGreater(Keys, Compare, First, Last)
	SwapIfGreater(Keys, Compare, Middle, Last)

	const Pivot = Keys[Middle]

	Keys[Middle], Keys[NextToLast] = Keys[NextToLast], Keys[Middle]

	local Left = First
	local Right = NextToLast

	while Left < Right do
		-- The scans step first and then compare, so the index that stops a scan is the one left in Left or Right.
		while Left < NextToLast do
			Left += 1

			if Compare(Pivot, Keys[Left]) <= 0 then
				break
			end
		end

		while Right > First do
			Right -= 1

			if Compare(Pivot, Keys[Right]) >= 0 then
				break
			end
		end

		if Left >= Right then
			break
		end

		Keys[Left], Keys[Right] = Keys[Right], Keys[Left]
	end

	if Left ~= NextToLast then
		Keys[Left], Keys[NextToLast] = Keys[NextToLast], Keys[Left]
	end

	return Left - First
end

-- @src engine/ArraySortHelper.cs:IntroSort L411-456
const function IntroSort<T>(Keys: { T }, First: number, Count: number, DepthLimit: number, Compare: (T, T) -> number)
	local PartitionSize = Count
	local Depth = DepthLimit

	while PartitionSize > 1 do
		if PartitionSize <= IntrosortSizeThreshold then
			if PartitionSize == 2 then
				SwapIfGreater(Keys, Compare, First, First + 1)

				return
			end

			if PartitionSize == 3 then
				SwapIfGreater(Keys, Compare, First, First + 1)
				SwapIfGreater(Keys, Compare, First, First + 2)
				SwapIfGreater(Keys, Compare, First + 1, First + 2)

				return
			end

			InsertionSort(Keys, First, PartitionSize, Compare)

			return
		end

		if Depth == 0 then
			HeapSort(Keys, First, PartitionSize, Compare)

			return
		end

		Depth -= 1

		const Split = PickPivotAndPartition(Keys, First, PartitionSize, Compare)

		-- The pivot is in place: the right side is sorted by recursion, the left side by the next pass of this loop.
		IntroSort(Keys, First + Split + 1, PartitionSize - Split - 1, Depth, Compare)
		PartitionSize = Split
	end
end

-- @src engine/ArraySortHelper.cs:Sort L283-322
const function Sort<T>(Keys: { T }, Compare: (T, T) -> number)
	const Count = #Keys

	if Count > 1 then
		-- BitOperations.Log2: the number of halvings from Count down to 1.
		local Log = 0
		local Remaining = Count

		while Remaining > 1 do
			Remaining //= 2
			Log += 1
		end

		IntroSort(Keys, 1, Count, 2 * (Log + 1), Compare)
	end
end

return Sort
