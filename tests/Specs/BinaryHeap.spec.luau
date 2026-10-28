--!strict
-- BinaryHeap: a min-heap that pops in priority order, breaks ties by insertion order (stable), peeks without
-- popping, counts, clears, takes infinite priorities, refuses NaN, and keeps every heap's state its own.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BinaryHeap = require(ReplicatedStorage.Shared.Util.BinaryHeap)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

type Pushed = { label: string, priority: number, order: number }

-- What a stable min-heap must return for `pushed`: priority order, insertion order among equals.
local function expectedOrder(pushed: { Pushed }): { string }
	local sorted = table.clone(pushed)
	table.sort(sorted, function(a: Pushed, b: Pushed): boolean
		if a.priority ~= b.priority then
			return a.priority < b.priority
		end
		return a.order < b.order
	end)
	local labels: { string } = {}
	for _, entry in sorted do
		table.insert(labels, entry.label)
	end
	return labels
end

local function drain(heap: BinaryHeap.Heap<string>): ({ string }, { number })
	local labels: { string } = {}
	local priorities: { number } = {}
	while heap:size() > 0 do
		local item, priority = heap:pop()
		assert(item ~= nil and priority ~= nil, "a non-empty heap pops an item")
		table.insert(labels, item)
		table.insert(priorities, priority)
	end
	return labels, priorities
end

return {
	["pops random priorities in ascending order, matching a stable sort"] = function(t: Expect)
		local random = Random.new(20261028)
		for round = 1, 25 do
			local heap: BinaryHeap.Heap<string> = BinaryHeap.new()
			local pushed: { Pushed } = {}
			local count = random:NextInteger(1, 60)
			for i = 1, count do
				-- few distinct values, so ties are common
				local priority = random:NextInteger(-4, 6) * 0.5
				local label = string.format("r%d_%d", round, i)
				heap:push(label, priority)
				table.insert(pushed, { label = label, priority = priority, order = i })
			end
			t.eq(heap:size(), count, "size counts every push")
			local labels, priorities = drain(heap)
			local expected = expectedOrder(pushed)
			t.eq(table.concat(labels, ","), table.concat(expected, ","), "round " .. round)
			for i = 2, #priorities do
				t.truthy(priorities[i - 1] <= priorities[i], "non-decreasing priorities")
			end
			t.eq(heap:size(), 0)
		end
	end,

	["equal priorities leave in insertion order, also across interleaved pops"] = function(t: Expect)
		local heap: BinaryHeap.Heap<string> = BinaryHeap.new()
		for _, label in { "a", "b", "c", "d" } do
			heap:push(label, 1)
		end
		t.eq((heap:pop()), "a")
		heap:push("e", 1)
		heap:push("z", 0)
		t.eq((heap:pop()), "z", "a lower priority overtakes")
		heap:push("f", 1)
		local labels = drain(heap)
		t.eq(table.concat(labels, ""), "bcdef", "FIFO among equals")
	end,

	["peek shows the minimum without removing it; empty heaps answer nil"] = function(t: Expect)
		local heap: BinaryHeap.Heap<string> = BinaryHeap.new()
		local item, priority = heap:peek()
		t.eq(item, nil)
		t.eq(priority, nil)
		local popped, popPriority = heap:pop()
		t.eq(popped, nil, "pop on empty")
		t.eq(popPriority, nil)
		heap:push("late", 5)
		heap:push("early", 2)
		item, priority = heap:peek()
		t.eq(item, "early")
		t.eq(priority, 2)
		t.eq(heap:size(), 2, "peek leaves it in")
		item, priority = heap:pop()
		t.eq(item, "early")
		t.eq(priority, 2)
		t.eq(heap:size(), 1)
	end,

	["clear empties the heap and restarts tie-breaking"] = function(t: Expect)
		local heap: BinaryHeap.Heap<string> = BinaryHeap.new()
		for i = 1, 10 do
			heap:push("x" .. i, i)
		end
		heap:clear()
		t.eq(heap:size(), 0)
		t.eq((heap:peek()), nil)
		heap:push("first", 3)
		heap:push("second", 3)
		local labels = drain(heap)
		t.eq(table.concat(labels, ","), "first,second")
	end,

	["infinite priorities sort at the ends; NaN is refused"] = function(t: Expect)
		local heap: BinaryHeap.Heap<string> = BinaryHeap.new()
		heap:push("mid", 0)
		heap:push("top", math.huge)
		heap:push("bottom", -math.huge)
		local labels = drain(heap)
		t.eq(table.concat(labels, ","), "bottom,mid,top")
		t.throws(function()
			heap:push("nan", 0 / 0)
		end, "NaN has no order")
		t.eq(heap:size(), 0, "a refused push adds nothing")
	end,

	["heaps are independent and hold any item type"] = function(t: Expect)
		local a: BinaryHeap.Heap<string> = BinaryHeap.new()
		local b: BinaryHeap.Heap<{ id: number }> = BinaryHeap.new()
		a:push("only", 1)
		local record = { id = 7 }
		b:push(record, 4)
		b:push({ id = 8 }, 5)
		t.eq(a:size(), 1)
		t.eq(b:size(), 2)
		local top = b:pop()
		t.eq(top, record, "items come back by identity")
		t.eq(a:size(), 1, "popping one heap leaves the other alone")
	end,

	["a large heap stays ordered"] = function(t: Expect)
		local random = Random.new(99)
		local heap: BinaryHeap.Heap<string> = BinaryHeap.new()
		for i = 1, 2000 do
			heap:push(tostring(i), random:NextNumber(-1000, 1000))
		end
		local _, priorities = drain(heap)
		t.eq(#priorities, 2000)
		for i = 2, #priorities do
			if priorities[i - 1] > priorities[i] then
				t.fail(string.format("out of order at %d: %f > %f", i, priorities[i - 1], priorities[i]))
			end
		end
	end,
}
