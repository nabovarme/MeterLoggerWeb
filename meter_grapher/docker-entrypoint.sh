#!/bin/bash
set -e

# --- 1. Version Registration Core ---
if [ -d "/run/git-versions" ] && [ -n "$GIT_COMMIT" ]; then
	echo "$GIT_COMMIT" > "/run/git-versions/$(hostname)"
	
	# Register the structural base layer version if it exists
	if [ -f "/etc/base-commit" ]; then
		cat /etc/base-commit > "/run/git-versions/perl_base_image"
	fi
fi

# --- 2. Process Execution Loop ---
/usr/local/bin/mqtt_to_redis.pl &
mqtt_to_redis_pid=$!

/usr/local/bin/meter_grapher.pl &
meter_grapher_pid=$!

# Kill remaining background jobs and let docker restart the container if one dies
wait -n
kill $(jobs -p)
