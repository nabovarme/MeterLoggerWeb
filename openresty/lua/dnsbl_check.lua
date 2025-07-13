local _M = {}
local resolver = require "resty.dns.resolver"
local cache = ngx.shared.dnsbl_cache

local dnsbls = {
	"zen.spamhaus.org",
	"bl.spamcop.net",
	"b.barracudacentral.org",
	"dnsbl.sorbs.net"
}

-- Path to whitelist file (one IP per line, supports comments starting with #)
local whitelist_path = "/usr/local/openresty/lualib/dnsbl_whitelist.txt"

-- Load whitelist IPs from file, return set (table with ips as keys)
local function load_whitelist(path)
	local file, err = io.open(path, "r")
	if not file then
		ngx.log(ngx.WARN, "Whitelist file not found, continuing without whitelist: ", err)
		return {}
	end

	local ips = {}
	for line in file:lines() do
		local ip = line:match("^%s*(.-)%s*$")  -- trim whitespace
		if ip ~= "" and not ip:match("^#") then
			ips[ip] = true
		end
	end
	file:close()
	return ips
end

local whitelist = load_whitelist(whitelist_path)

local function is_ip_whitelisted(ip)
	return whitelist[ip] == true
end

local function reverse_ip(ip)
	local o1, o2, o3, o4 = ip:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
	if o1 and o2 and o3 and o4 then
		return string.format("%s.%s.%s.%s", o4, o3, o2, o1)
	end
	return nil
end

local function is_ip_blacklisted(ip)
	local reversed_ip = reverse_ip(ip)
	if not reversed_ip then
		ngx.log(ngx.ERR, "Invalid IP for DNSBL: ", ip)
		return false
	end

	local cache_key = "dnsbl:" .. ip
	local cached = cache:get(cache_key)
	if cached ~= nil then
		ngx.log(ngx.INFO, "DNSBL cache hit for ", ip, ": ", tostring(cached))
		return cached == true
	end

	local r, err = resolver:new{
		nameservers = {"8.8.8.8", "8.8.4.4"},
		retrans = 2,
		timeout = 2000,
	}

	if not r then
		ngx.log(ngx.ERR, "DNS resolver init failed: ", err)
		return false
	end

	for _, bl in ipairs(dnsbls) do
		local query = reversed_ip .. "." .. bl
		ngx.log(ngx.INFO, "DNSBL lookup: querying ", query)

		local answers, err = r:query(query, { qtype = r.TYPE_A })

		if answers and not answers.errcode then
			ngx.log(ngx.WARN, "DNSBL HIT: ", ip, " is blacklisted on ", bl)
			cache:set(cache_key, true, 3600)
			return true
		elseif err then
			ngx.log(ngx.ERR, "DNSBL lookup failed for ", query, ": ", err)
		else
			ngx.log(ngx.INFO, "D
