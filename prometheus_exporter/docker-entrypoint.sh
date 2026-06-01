#!/bin/bash
set -e

# Target tracking file path based on the unique container hostname
FILE_PATH="/run/git-versions/$(hostname)"

# --- 1. Version Registration Core ---
if [ -d "/run/git-versions" ] && [ -n "$GIT_COMMIT" ]; then
	echo "$GIT_COMMIT" > "$FILE_PATH"
	
	# Track the underlying base layer hash if present
	if [ -f "/etc/base-commit" ]; then
		cat /etc/base-commit > "/run/git-versions/perl_base_image"
	fi
fi

# --- 2. Automated Cleanup & Forwarding Trap ---
# Deletes the tracking token and passes SIGTERM down to Apache gracefully
_cleanup() {
	echo "Caught shutdown signal! Removing version token and stopping Apache..."
	rm -f "$FILE_PATH"
	kill -TERM "$apache_pid" 2>/dev/null
	exit 0
}
trap _cleanup SIGTERM SIGINT

# --- 3. Start Apache Web Server Engine ---
# Load Apache environment variables explicitly (Required when bypassing apachectl)
. /etc/apache2/envvars

# Run the binary in the background so the shell can catch signals
apache2 -D FOREGROUND &
apache_pid=$!

# Wait on the Apache process
wait "$apache_pid"
