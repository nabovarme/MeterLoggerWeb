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

# --- 2. Signal Trapping & Process Management ---
# Forward signals to the Perl process
_term() {
  echo "Caught SIGTERM, forwarding to Perl..."
  kill -TERM "$perl_pid" 2>/dev/null
}

trap _term SIGTERM SIGINT

# Run Perl server in the background so the shell can catch signals
perl /usr/local/bin/smtp_server.pl &
perl_pid=$!

# Wait on the Perl process to finish or for a signal to trip the trap
wait "$perl_pid"
