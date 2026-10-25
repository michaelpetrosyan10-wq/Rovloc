--!strict
-- Tagged, levelled, rate-limited logging. Debug lines only print in Studio. Errors use warn() so logging never
-- throws; callers decide whether a failure is fatal.

local RunService = game:GetService("RunService")

export type Logger = {
	debug: (fmt: string, ...any) -> (),
	info: (fmt: string, ...any) -> (),
	warn: (fmt: string, ...any) -> (),
	error: (fmt: string, ...any) -> (),
	-- Like warn, but prints at most once per `key` every `seconds`.
	warnThrottled: (key: string, seconds: number, fmt: string, ...any) -> (),
}

local Log = {}

local IS_STUDIO = RunService:IsStudio()
local SIDE = if RunService:IsServer() then "S" else "C"
local lastPrinted: { [string]: number } = {}

local function format(fmt: string, ...: any): string
	local ok, message = pcall(string.format, fmt, ...)
	if ok then
		return message
	end
	local parts = { fmt }
	for i = 1, select("#", ...) do
		table.insert(parts, tostring((select(i, ...))))
	end
	return table.concat(parts, " ")
end

function Log.new(tag: string): Logger
	local prefix = string.format("[%s:%s]", SIDE, tag)
	return {
		debug = function(fmt: string, ...: any)
			if IS_STUDIO then
				print(prefix, format(fmt, ...))
			end
		end,
		info = function(fmt: string, ...: any)
			print(prefix, format(fmt, ...))
		end,
		warn = function(fmt: string, ...: any)
			warn(prefix, format(fmt, ...))
		end,
		error = function(fmt: string, ...: any)
			warn(prefix, "ERROR", format(fmt, ...), "\n" .. debug.traceback(nil, 2))
		end,
		warnThrottled = function(key: string, seconds: number, fmt: string, ...: any)
			local now = os.clock()
			local fullKey = tag .. "|" .. key
			local last = lastPrinted[fullKey]
			if last == nil or now - last >= seconds then
				lastPrinted[fullKey] = now
				warn(prefix, format(fmt, ...))
			end
		end,
	}
end

return table.freeze(Log)
