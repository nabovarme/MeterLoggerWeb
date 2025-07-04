-- Get the shared dictionary for storing rate limit counters
local limit_store = ngx.shared.rate_limit_store

-- Identify client IP and requested URI (including query string)
local ip = ngx.var.remote_addr
local uri = ngx.var.request_uri  -- or ngx.var.uri if you want to exclude query params

-- Create a unique key per IP and URI for tracking requests
local key = ip .. ":" .. uri

-- Rate limit configuration parameters
local base_delay = 2	-- initial penalty delay in seconds
local max_delay = 60	-- max penalty delay in seconds
local window = 30	   -- time window in seconds for counting requests
local limit = 20		-- allowed number of requests per window

-- Retrieve current request count for this IP+URI
local reqs, err = limit_store:get(key)
if not reqs then
	-- No requests recorded yet, set counter to 1 with expiration of 'window' seconds
	limit_store:set(key, 1, window)
elseif reqs < limit then
	-- Under the limit, increment request count atomically
	limit_store:incr(key, 1)
else
	-- Limit exceeded: apply exponential backoff penalty
	local penalty_key = key .. "_penalty"
	local strikes = limit_store:get(penalty_key) or 0
	strikes = strikes + 1

	-- Calculate delay: base_delay * 2^(strikes-1), capped by max_delay
	local delay = math.min(base_delay * (2 ^ (strikes - 1)), max_delay)

	-- Store the number of strikes with expiration equal to the current delay seconds
	limit_store:set(penalty_key, strikes, delay)

	-- Set HTTP Retry-After header to inform client how long to wait
	ngx.header["Retry-After"] = delay
	ngx.status = 429  -- HTTP status code for Too Many Requests
	ngx.say("Rate limit exceeded. Retry in " .. delay .. " seconds.")
	
	-- Log the rate limiting event with details for monitoring
	ngx.log(ngx.WARN, "Rate limit block: IP ", ip, " URL ", uri, " blocked for ", delay, " seconds (strike ", strikes, ")")
	
	return ngx.exit(429)  -- Stop processing and return the error
end
