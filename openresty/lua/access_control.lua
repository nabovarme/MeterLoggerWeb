local dnsbl = require("dnsbl_check")
local rate_limit = require("rate_limit")

local ok1, err1 = pcall(dnsbl.run)
if not ok1 then
	ngx.log(ngx.ERR, "DNSBL check failed: ", err1)
end

local ok2, err2 = pcall(rate_limit.run)
if not ok2 then
	ngx.log(ngx.ERR, "Rate limit check failed: ", err2)
end
