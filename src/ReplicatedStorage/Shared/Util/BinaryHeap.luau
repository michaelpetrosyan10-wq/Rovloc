--!strict
-- BinaryHeap: a min-priority queue (array-backed binary heap) for A* and other best-first searches.
--
--   local open = BinaryHeap.new<string>()
--   open:push("a", 3)
--   local item, priority = open:pop() -- lowest priority first
--
-- Stable: items pushed with equal priorities come out in the order they were pushed (each entry carries an insertion
-- counter that breaks ties), so searches built on it are deterministic. Priorities may be any number including
-- +/-math.huge; NaN has no order and is refused. push / pop are O(log n); peek / size are O(1).

export type Heap<T> = {
	push: (self: Heap<T>, item: T, priority: number) -> (),
	pop: (self: Heap<T>) -> (T?, number?),
	peek: (self: Heap<T>) -> (T?, number?),
	size: (self: Heap<T>) -> number,
	clear: (self: Heap<T>) -> (),
}

type Entry<T> = { item: T, priority: number, order: number }

local BinaryHeap = {}

-- Whether entry `a` leaves the heap before entry `b`.
local function before<T>(a: Entry<T>, b: Entry<T>): boolean
	if a.priority ~= b.priority then
		return a.priority < b.priority
	end
	return a.order < b.order
end

function BinaryHeap.new<T>(): Heap<T>
	local entries: { Entry<T> } = {}
	local count = 0
	local pushed = 0 -- insertion counter (tie-breaker)

	local function siftUp(index: number)
		local entry = entries[index]
		while index > 1 do
			local parentIndex = index // 2
			local parent = entries[parentIndex]
			if not before(entry, parent) then
				break
			end
			entries[index] = parent
			index = parentIndex
		end
		entries[index] = entry
	end

	local function siftDown(index: number)
		local entry = entries[index]
		while true do
			local left = index * 2
			if left > count then
				break
			end
			local child = left
			local right = left + 1
			if right <= count and before(entries[right], entries[left]) then
				child = right
			end
			if not before(entries[child], entry) then
				break
			end
			entries[index] = entries[child]
			index = child
		end
		entries[index] = entry
	end

	local heap: Heap<T> = {
		push = function(_self: Heap<T>, item: T, priority: number)
			if priority ~= priority then
				error("BinaryHeap.push: priority is NaN", 2)
			end
			pushed += 1
			count += 1
			entries[count] = { item = item, priority = priority, order = pushed }
			siftUp(count)
		end,
		pop = function(_self: Heap<T>): (T?, number?)
			if count == 0 then
				return nil, nil
			end
			local top = entries[1]
			local last = entries[count]
			entries[count] = nil
			count -= 1
			if count > 0 then
				entries[1] = last
				siftDown(1)
			end
			return top.item, top.priority
		end,
		peek = function(_self: Heap<T>): (T?, number?)
			local top = entries[1]
			if top == nil then
				return nil, nil
			end
			return top.item, top.priority
		end,
		size = function(_self: Heap<T>): number
			return count
		end,
		clear = function(_self: Heap<T>)
			table.clear(entries)
			count = 0
			pushed = 0
		end,
	}
	return heap
end

return table.freeze(BinaryHeap)
