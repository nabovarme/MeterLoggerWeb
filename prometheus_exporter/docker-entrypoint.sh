#!/bin/bash
set -e

# --- 1. Version Registration Core ---
if [ -d "/run/git-versions" ] && [ -n "$GIT_COMMIT" ]; then
	echo "$GIT_COMMIT" > "/run/git-versions/$(hostname)"
	
	# Track the underlying base layer hash if present
	if [ -f "/etc/base-commit" ]; then
		cat /etc/base-commit > "/run/git-versions/perl_base_image"
	fi
fi

# --- 2. Start Apache Web Server Engine ---
# Load Apache environment variables explicitly (Required when bypassing apachectl)
. /etc/apache2/envvars

# Execute the binary directly so it catches SIGTERM instantly
exec apache2 -D FOREGROUND
