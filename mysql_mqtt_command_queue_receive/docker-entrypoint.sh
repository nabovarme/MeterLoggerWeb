#!/bin/bash
set -e

# --- 1. Version Registration Core ---
if [ -d "/run/git-versions" ] && [ -n "$GIT_COMMIT" ]; then
    echo "$GIT_COMMIT" > "/run/git-versions/$(hostname)"
fi

# --- 2. Handoff to OpenResty Engine ---
exec "$@"
