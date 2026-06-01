#!/bin/bash
set -e

# Define the target tracking file path based on the unique container hostname
FILE_PATH="/run/git-versions/$(hostname)"

# --- 1. Version Registration ---
if [ -d "/run/git-versions" ] && [ -n "$GIT_COMMIT" ]; then
	echo "$GIT_COMMIT" > "$FILE_PATH"
	
	if [ -f "/etc/base-commit" ]; then
		cat /etc/base-commit > "/run/git-versions/perl_base_image"
	fi
fi

# --- 2. Automated Cleanup Trap ---
# When Docker sends SIGTERM/SIGINT, delete the tracking file before exiting
_cleanup() {
	echo "Container shutting down. Removing version tracking token..."
	rm -f "$FILE_PATH"
	exit 0
}
trap _cleanup SIGTERM SIGINT

# --- 3. Handoff to Perl Script ---
# Run the script in the background and wait on it so the shell can catch signals
"$@" &
child_pid=$!

wait "$child_pid"
