# Use the official OpenResty image based on Debian Bookworm
FROM openresty/openresty:bookworm

# Install only the system packages you actually need for your Lua modules/Certbot
RUN apt-get update && apt-get install -y --no-install-recommends \
	luarocks \
	git \
	build-essential \
	libssl-dev \
	&& rm -rf /var/lib/apt/lists/*

# Install lua-resty-http and luafilesystem
RUN luarocks install lua-resty-http
RUN luarocks install luafilesystem

# Copy nginx and lua files
COPY openresty/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY openresty/lua/access_control.lua /usr/local/openresty/lualib/access_control.lua
COPY openresty/lua/rate_limit.lua /usr/local/openresty/lualib/rate_limit.lua
COPY openresty/lua/dnsbl_check.lua /usr/local/openresty/lualib/dnsbl_check.lua

# Create html directory
RUN mkdir -p /usr/local/openresty/html

# Copy custom 502 and 403 page from Apache htdocs
COPY htdocs/backend_down.html /usr/local/openresty/html/backend_down.html
COPY htdocs/blocked_ip.html /usr/local/openresty/html/blocked_ip.html

RUN mkdir /usr/local/openresty/lualib/dnsbl_whitelist

# Set lua path for development and debugging
ENV LUA_PATH="/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;;"
ENV PATH="/usr/local/openresty/nginx/sbin:/usr/local/openresty/bin:$PATH"

EXPOSE 80 443

CMD ["openresty", "-g", "daemon off;"]
