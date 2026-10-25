--!strict
-- Typed, immediate-fire signal. Each handler runs in its own thread (task.spawn), so one failing handler never
-- stops the others and handlers may yield. Firing order is connection order.

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	HasConnections: (self: Signal<T...>) -> boolean,
}

type Slot<T...> = {
	handler: (T...) -> (),
	once: boolean,
	connection: Connection,
}

local Signal = {}

function Signal.new<T...>(): Signal<T...>
	local slots: { Slot<T...> } = {}
	local waiting: { thread } = {}

	local function remove(slot: Slot<T...>)
		local index = table.find(slots, slot)
		if index then
			table.remove(slots, index)
		end
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
		Wait = function(_self: Signal<T...>): T...
			table.insert(waiting, coroutine.running())
			return coroutine.yield()
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
				local threads = waiting
				waiting = {}
				for _, thread in threads do
					task.spawn(thread, ...)
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
