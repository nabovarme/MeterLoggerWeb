#!/bin/bash
set -e

# --- 1. Version Registration Core ---
if [ -d "/run/git-versions" ] && [ -n "$GIT_COMMIT" ]; then
	echo "$GIT_COMMIT" > "/run/git-versions/$(hostname)"
	
	# Register the base layer version if it exists
	if [ -f "/etc/base-commit" ]; then
		cat /etc/base-commit > "/run/git-versions/perl_base_image"
	fi
fi

# --- 2. Environment Variable Setup for Cron ---
# Export relevant environment variables for cron jobs (Using >> to append cleanly)
echo "export METERLOGGER_DB_HOST=${METERLOGGER_DB_HOST}" >> /etc/cron_env
echo "export METERLOGGER_DB_USER=${METERLOGGER_DB_USER}" >> /etc/cron_env
echo "export METERLOGGER_DB_PASSWORD=${METERLOGGER_DB_PASSWORD}" >> /etc/cron_env
echo "export TZ=${TZ}" >> /etc/cron_env
echo "export PERL5LIB=/etc/apache2/perl" >> /etc/cron_env
echo "export ENABLE_DEBUG=${ENABLE_DEBUG}" >> /etc/cron_env

# --- 3. Process Execution Loop ---
# Start cron in the background
cron -f &
cron_pid=$!

# Tail the cron log
tail -f /var/log/cron.log &
tail_cron_pid=$!

# Run scripts manually in the background
/usr/local/bin/update_meters.pl &
update_meters_pid=$!

/usr/local/bin/clean_samples_cache.pl &
clean_samples_cache_pid=$!

# Kill remaining background jobs and let docker restart the container if one fails
wait -n
kill $(jobs -p)