--!strict
-- Cleanup bag. Every service keeps a ServiceTrove (process lifetime) and a RunTrove (one run); controllers keep
-- one per character or per screen. Clean() releases everything in reverse insertion order.

export type Destroyable = { Destroy: (self: any) -> () }
export type Disconnectable = { Disconnect: (self: any) -> () }

export type Trove = {
	Add: <T>(self: Trove, item: T) -> T,
	Connect: (self: Trove, signal: RBXScriptSignal, handler: (...any) -> ()) -> RBXScriptConnection,
	Spawn: (self: Trove, fn: (...any) -> (), ...any) -> thread,
	Delay: (self: Trove, seconds: number, fn: (...any) -> (), ...any) -> thread,
	Extend: (self: Trove) -> Trove,
	Remove: (self: Trove, item: any) -> boolean,
	Clean: (self: Trove) -> (),
	Destroy: (self: Trove) -> (),
}

local Trove = {}

local function release(item: any)
	local kind = typeof(item)
	if kind == "RBXScriptConnection" then
		(item :: RBXScriptConnection):Disconnect()
	elseif kind == "Instance" then
		(item :: Instance):Destroy()
	elseif kind == "function" then
		(item :: () -> ())()
	elseif kind == "thread" then
		local thread = item :: thread
		if coroutine.status(thread) ~= "dead" and coroutine.running() ~= thread then
			pcall(task.cancel, thread)
		end
	elseif kind == "table" then
		local tbl = item :: any
		if type(tbl.Destroy) == "function" then
			tbl:Destroy()
		elseif type(tbl.Disconnect) == "function" then
			tbl:Disconnect()
		end
	end
end

function Trove.new(): Trove
	local items: { any } = {}
	local cleaning = false

	local trove: Trove
	trove = {
		Add = function<T>(_self: Trove, item: T): T
			if cleaning then
				-- Adding during Clean(): release immediately so nothing outlives the trove.
				task.defer(release, item)
				return item
			end
			table.insert(items, item)
			return item
		end,
		Connect = function(self: Trove, signal: RBXScriptSignal, handler: (...any) -> ()): RBXScriptConnection
			return self:Add(signal:Connect(handler))
		end,
		Spawn = function(self: Trove, fn: (...any) -> (), ...: any): thread
			return self:Add(task.spawn(fn, ...))
		end,
		Delay = function(self: Trove, seconds: number, fn: (...any) -> (), ...: any): thread
			return self:Add(task.delay(seconds, fn, ...))
		end,
		Extend = function(self: Trove): Trove
			local child = Trove.new()
			self:Add(child)
			return child
		end,
		Remove = function(_self: Trove, item: any): boolean
			local index = table.find(items, item)
			if index then
				table.remove(items, index)
				release(item)
				return true
			end
			return false
		end,
		Clean = function(_self: Trove)
			if cleaning then
				return
			end
			cleaning = true
			while #items > 0 do
				local item = table.remove(items)
				xpcall(release, function(err: any)
					warn("[Trove] cleanup failed: " .. tostring(err))
				end, item)
			end
			cleaning = false
		end,
		Destroy = function(self: Trove)
			self:Clean()
		end,
	}
	return trove
end

return table.freeze(Trove)
