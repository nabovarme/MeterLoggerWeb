local _M = {}
local resolver = require "resty.dns.resolver"
local cache = ngx.shared.dnsbl_cache

local dnsbls = {
	"zen.spamhaus.org",
	"bl.spamcop.net",
	"b.barracudacentral.org",
	"dnsbl.sorbs.net"
}

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
		local answers, err = r:query(query, { qtype = r.TYPE_A })

		if answers and not answers.errcode then
			cache:set(cache_key, true, 3600)
			return true
		end
	end

	cache:set(cache_key, false, 1800)
	return false
end

function _M.run()
	local client_ip = ngx.var.remote_addr
	if is_ip_blacklisted(client_ip) then
		ngx.log(ngx.ERR, "Blocked blacklisted IP: ", client_ip)
		return ngx.exit(ngx.HTTP_FORBIDDEN)
	end
end

return _M
