-- access_control.lua

-- Local requires
local dnsbl = require("dnsbl_check")
local rate_limit = require("rate_limit")
local ngx = ngx
local pcall = pcall

-- Run DNSBL check safely
local ok1, err1 = pcall(dnsbl.run)
if not ok1 then
	ngx.log(ngx.ERR, "DNSBL check failed: ", err1)
end

-- Run rate limit check safely
local ok2, err2 = pcall(rate_limit.run)
if not ok2 then
	ngx.log(ngx.ERR, "Rate limit check failed: ", err2)
end
