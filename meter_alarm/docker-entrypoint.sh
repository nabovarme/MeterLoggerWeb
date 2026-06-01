#!/bin/bash
set -e

# --- 1. Version Registration Core ---
if [ -d "/run/git-versions" ] && [ -n "$GIT_COMMIT" ]; then
	echo "$GIT_COMMIT" > "/run/git-versions/$(hostname)"
	
	# Track the base image layer hash if it's there
	if [ -f "/etc/base-commit" ]; then
		cat /etc/base-commit > "/run/git-versions/perl_base_image"
	fi
fi

# --- 2. Handoff to Perl Script ---
exec "$@"
