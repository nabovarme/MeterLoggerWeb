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

	local reqs, err = limit_store:get(key)
	if not reqs then
		ngx.log(ngx.INFO, "Rate limit: first request from ", ip, " to ", uri)
		limit_store:set(key, 1, window)
	elseif reqs < limit then
		ngx.log(ngx.INFO, "Rate limit: ", reqs + 1, " requests from ", ip, " to ", uri)
		limit_store:incr(key, 1)
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
