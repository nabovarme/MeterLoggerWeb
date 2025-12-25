-- dnsbl_check.lua

local _M = {}

-- Local requires only
local resolver = require("resty.dns.resolver")
local lfs = require("lfs")  -- LuaFileSystem
local ngx = ngx
local io = io
local string = string
local ipairs = ipairs
local pcall = pcall

-- Shared memory cache
local cache = ngx.shared.dnsbl_cache

-- DNSBL providers to check
local dnsbls = {
	"sbl.spamhaus.org",
	"xbl.spamhaus.org",
	"bl.spamcop.net"
}

-- Directory containing .txt files with whitelisted IPs
local whitelist_dir = "/usr/local/openresty/lualib/dnsbl_whitelist"

-- Load whitelist IPs from .txt files
local function load_whitelist(dir)
	local ips = {}
	local attr, err = lfs.attributes(dir)
	if not attr then
		ngx.log(ngx.WARN, "Whitelist directory not found: ", err)
		return ips
	end

	for file in lfs.dir(dir) do
		if file:match("%.txt$") then
			local path = dir .. "/" .. file
			local f, ferr = io.open(path, "r")
			if f then
				for line in f:lines() do
					local ip = line:match("^%s*(.-)%s*$")
					if ip ~= "" and not ip:match("^#") then
						ips[ip] = true
					end
				end
				f:close()
				ngx.log(ngx.INFO, "Loaded whitelist file: ", path)
			else
				ngx.log(ngx.WARN, "Could not open whitelist file ", path, ": ", ferr)
			end
		end
	end
	return ips
end

-- Local whitelist cache
local whitelist = load_whitelist(whitelist_dir)

-- Check if IP is whitelisted
local function is_ip_whitelisted(ip)
	return whitelist[ip] == true
end

-- Reverse IPv4 octets
local function reverse_ip(ip)
	local o1, o2, o3, o4 = ip:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
	if o1 and o2 and o3 and o4 then
		return string.format("%s.%s.%s.%s", o4, o3, o2, o1)
	end
	return nil
end

-- Perform DNSBL check
local function is_ip_blacklisted(ip)
	if is_ip_whitelisted(ip) then
		ngx.log(ngx.INFO, "IP ", ip, " is whitelisted — skipping DNSBL check.")
		return false
	end

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

		local answers, qerr = r:query(query, { qtype = r.TYPE_A })

		if answers and not answers.errcode then
			ngx.log(ngx.WARN, "DNSBL HIT: ", ip, " is blacklisted on ", bl)
			cache:set(cache_key, true, 3600)
			return true
		elseif qerr then
			ngx.log(ngx.ERR, "DNSBL lookup failed for ", query, ": ", qerr)
		else
			ngx.log(ngx.INFO, "DNSBL miss: ", ip, " not listed on ", bl)
		end
	end

	cache:set(cache_key, false, 1800)
	return false
end

-- Module entry point
function _M.run()
	local client_ip = ngx.var.remote_addr
	if is_ip_blacklisted(client_ip) then
		ngx.log(ngx.ERR, "Blocked blacklisted IP: ", client_ip)
		return ngx.exit(ngx.HTTP_FORBIDDEN)
	end
end

return _M
