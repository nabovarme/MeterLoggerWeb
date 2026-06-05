-- rate_limit.lua
local _M = {}

function _M.run()
	local limit_store = ngx.shared.rate_limit_store

	local ip = ngx.var.remote_addr
	local uri = ngx.var.request_uri
	local key = ip .. ":" .. uri

	local base_delay = 2
	local max_delay = 60
	local window = 30
	local limit = 20

	-- Atomically increment key counter directly to prevent concurrent execution lookup misses
	local reqs, err = limit_store:incr(key, 1, 0, window)
	if not reqs then
		limit_store:set(key, 1, window)
		reqs = 1
	end

	if reqs == 1 then
		ngx.log(ngx.INFO, "Rate limit: first request from ", ip, " to ", uri)
	elseif reqs <= limit then
		ngx.log(ngx.INFO, "Rate limit: ", reqs, " requests from ", ip, " to ", uri)
	else
		local penalty_key = key .. "_penalty"
		local strikes = limit_store:get(penalty_key) or 0
		strikes = strikes + 1

		local delay = math.min(base_delay * (2 ^ (strikes - 1)), max_delay)
		limit_store:set(penalty_key, strikes, delay)

		ngx.header["Retry-After"] = delay
		ngx.status = 429
		ngx.say("Rate limit exceeded. Retry in " .. delay .. " seconds.")

		ngx.log(ngx.WARN, "Rate limit block: IP ", ip, " URL ", uri, " blocked for ", delay, " seconds (strike ", strikes, ")")

		return ngx.exit(429)
	end
end

return _M
