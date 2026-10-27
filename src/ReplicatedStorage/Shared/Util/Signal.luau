--!strict
-- Typed, immediate-fire signal. Each handler runs in its own thread (task.spawn), so one failing handler never
-- stops the others and handlers may yield. Firing order is connection order.
--
-- Waiting. Wait(timeout?) parks the calling thread until the next Fire and returns its arguments; with a timeout it
-- returns no values once `timeout` seconds pass first. TryWait(timeout) is the typed form of the same wait:
-- (true, ...) when the signal fired, (false) on timeout. Each wait owns one waiter record, so a wait is resolved
-- exactly once: Fire skips waiters that already timed out, a timed-out waiter leaves the queue, and a waiting thread
-- that something else resumed (or cancelled) is dropped instead of being woken again by a later Fire. Fire only
-- resumes threads that are still suspended, so one dead waiter never stops the others. Do not resume a waiting
-- thread from outside: the wait then ends with whatever that resume passed.

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	-- Next Fire's arguments; no values when `timeout` (seconds) passes first.
	Wait: (self: Signal<T...>, timeout: number?) -> T...,
	-- (true, next Fire's arguments), or (false) when `timeout` seconds pass first.
	TryWait: (self: Signal<T...>, timeout: number) -> (boolean, T...),
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	HasConnections: (self: Signal<T...>) -> boolean,
}

type Slot<T...> = {
	handler: (T...) -> (),
	once: boolean,
	connection: Connection,
}

-- One pending wait. `done` flips exactly once (fired, timed out, or the thread was resumed by someone else).
type Waiter = {
	thread: thread,
	done: boolean,
	fired: boolean,
	timer: thread?,
}

local Signal = {}

function Signal.new<T...>(): Signal<T...>
	local slots: { Slot<T...> } = {}
	local waiting: { Waiter } = {}

	local function remove(slot: Slot<T...>)
		local index = table.find(slots, slot)
		if index then
			table.remove(slots, index)
		end
	end

	local function unqueue(waiter: Waiter)
		local index = table.find(waiting, waiter)
		if index then
			table.remove(waiting, index)
		end
	end

	local function cancelTimer(waiter: Waiter)
		local timer = waiter.timer
		waiter.timer = nil
		if timer and timer ~= coroutine.running() and coroutine.status(timer) == "suspended" then
			task.cancel(timer)
		end
	end

	-- Resumes `waiter` once, and only while its thread is still parked (a dead thread is skipped).
	local function settle(waiter: Waiter, fired: boolean, ...: any)
		if waiter.done then
			return
		end
		waiter.done = true
		waiter.fired = fired
		cancelTimer(waiter)
		if coroutine.status(waiter.thread) == "suspended" then
			task.spawn(waiter.thread, ...)
		end
	end

	-- Parks the running thread until Fire (true, args...) or the timeout (false). Always leaves the queue clean.
	local function waitFor(timeout: number?): (boolean, { n: number, [number]: any })
		local waiter: Waiter = { thread = coroutine.running(), done = false, fired = false, timer = nil }
		table.insert(waiting, waiter)
		if timeout ~= nil then
			local seconds = if timeout == timeout then math.max(0, timeout) else 0
			waiter.timer = task.delay(seconds, function()
				waiter.timer = nil
				if not waiter.done then
					unqueue(waiter)
					settle(waiter, false)
				end
			end)
		end
		local results = table.pack(coroutine.yield())
		if not waiter.done then
			-- Resumed by something other than Fire or the timeout: this wait is over, never wake it again.
			waiter.done = true
			unqueue(waiter)
			cancelTimer(waiter)
		end
		return waiter.fired, results
	end

	local function connect(handler: (T...) -> (), once: boolean): Connection
		local slot: Slot<T...>
		local connection: Connection = {
			Connected = true,
			Disconnect = function(self: Connection)
				if self.Connected then
					self.Connected = false
					remove(slot)
				end
			end,
		}
		slot = { handler = handler, once = once, connection = connection }
		table.insert(slots, slot)
		return connection
	end

	local signal: Signal<T...> = {
		Connect = function(_self: Signal<T...>, handler: (T...) -> ()): Connection
			return connect(handler, false)
		end,
		Once = function(_self: Signal<T...>, handler: (T...) -> ()): Connection
			return connect(handler, true)
		end,
		Wait = function(_self: Signal<T...>, timeout: number?): T...
			local _, results = waitFor(timeout)
			-- A timed-out wait was resumed with no arguments, so this returns nothing.
			return table.unpack(results, 1, results.n)
		end,
		TryWait = function(_self: Signal<T...>, timeout: number): (boolean, T...)
			local fired, results = waitFor(timeout)
			return fired, table.unpack(results, 1, results.n)
		end,
		Fire = function(_self: Signal<T...>, ...: T...)
			local snapshot = table.clone(slots)
			for _, slot in snapshot do
				if slot.connection.Connected then
					if slot.once then
						slot.connection:Disconnect()
					end
					task.spawn(slot.handler, ...)
				end
			end
			if #waiting > 0 then
				local waiters = waiting
				waiting = {}
				for _, waiter in waiters do
					settle(waiter, true, ...)
				end
			end
		end,
		DisconnectAll = function(_self: Signal<T...>)
			for _, slot in table.clone(slots) do
				slot.connection.Connected = false
			end
			table.clear(slots)
		end,
		HasConnections = function(_self: Signal<T...>): boolean
			return #slots > 0
		end,
	}
	return signal
end

return table.freeze(Signal)
