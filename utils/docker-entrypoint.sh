#!/bin/bash
set -e

# --- 1. History File Initialization ---
HISTFILE=/home/meterlogger/.bash_history
if [ ! -f "$HISTFILE" ]; then
	touch "$HISTFILE"
fi

# --- 2. Version Registration Core ---
# Note: meterlogger needs write permissions to the mounted volume space
if [ -d "/run/git-versions" ] && [ -n "$GIT_COMMIT" ]; then
	echo "$GIT_COMMIT" > "/run/git-versions/$(hostname)" 2>/dev/null || true
	
	# Track the underlying base layer hash if present
	if [ -f "/etc/base-commit" ]; then
		cat /etc/base-commit > "/run/git-versions/perl_base_image" 2>/dev/null || true
	fi
fi

# --- 3. Keep Container Alive Natively ---
echo "Utils container ready. Entering idle loop..."

# Trap signals to exit cleanly when docker compose stops
trap "exit 0" SIGTERM SIGINT

while true; do 
	sleep 3600 & 
	wait $!
done
