-- dnsbl_check.lua

local _M = {}

-- Local requires only
local resolver = require("resty.dns.resolver")
local ngx = ngx
local io = io
local string = string
local ipairs = ipairs
local pcall = pcall
local table = table

-- Shared memory cache
local cache = ngx.shared.dnsbl_cache

-- DNSBL providers to check
local dnsbls = {
	"sbl.spamhaus.org",
	"xbl.spamhaus.org",
	"bl.spamcop.net"
}

-- Optional decoding for Spamhaus-style return codes
local spamhaus_codes = {
	["127.0.0.2"] = "Spam source",
	["127.0.0.3"] = "Spam source (snowshoe)",
	["127.0.0.4"] = "Open relay",
	["127.0.0.5"] = "Known spam bot",
	["127.0.0.6"] = "Botnet C&C",
	["127.0.0.7"] = "Spam support service",
}

-- Directory containing .txt files with whitelisted IPs
local whitelist_dir = "/usr/local/openresty/lualib/dnsbl_whitelist"

-- Placeholder for lazy loading
local whitelist = nil
local lfs_lib = nil

-- Load whitelist IPs from .txt files
local function load_whitelist(dir)
	local ips = {}
	
	if not lfs_lib then
		-- Temporarily detach OpenResty's global write guard metatable completely
		local old_mt = getmetatable(_G)
		setmetatable(_G, nil)

		-- Execute the require step while the guard is disabled
		local status, res = pcall(require, "lfs")

		-- Restore the original environment configuration instantly
		setmetatable(_G, old_mt)

		if not status then
			ngx.log(ngx.ERR, "Failed to require lfs: ", res)
			return ips
		end

		lfs_lib = res
		
		-- Safely drop the global leak using rawset to bypass meta hooks
		rawset(_G, "lfs", nil)
	end

	local attr, err = lfs_lib.attributes(dir)
	if not attr then
		ngx.log(ngx.WARN, "Whitelist directory not found: ", err)
		return ips
	end

	for file in lfs_lib.dir(dir) do
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

-- Check if IP is whitelisted (Lazily loaded when the first request flows through)
local function is_ip_whitelisted(ip)
	if not whitelist then
		whitelist = load_whitelist(whitelist_dir)
	end
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

		if answers and #answers > 0 and not answers.errcode then
			local codes = {}
			local decoded = {}

			for _, ans in ipairs(answers) do
				if ans.address then
					table.insert(codes, ans.address)

					-- Decode known Spamhaus-style codes
					if spamhaus_codes[ans.address] then
						table.insert(decoded, spamhaus_codes[ans.address])
					end
				end
			end

			ngx.log(ngx.WARN,
				"DNSBL HIT: ", ip,
				" listed on ", bl,
				" | codes: ", table.concat(codes, ", "),
				" | decoded: ", (#decoded > 0 and table.concat(decoded, ", ") or "n/a")
			)

			-- Try TXT lookup for more info
			local txt_answers = r:query(query, { qtype = r.TYPE_TXT })
			if txt_answers and not txt_answers.errcode then
				for _, txt in ipairs(txt_answers) do
					if txt.txt then
						ngx.log(ngx.WARN,
							"DNSBL TXT info for ", ip,
							" on ", bl, ": ",
							table.concat(txt.txt, " ")
						)
					end
				end
			end

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
