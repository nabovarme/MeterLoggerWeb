#/bin/bash

# Export relevant environment variables for cron jobs
echo "export REDIS_HOST=${REDIS_HOST}" >> /etc/cron_env
echo "export REDIS_PORT=${REDIS_PORT}" >> /etc/cron_env
echo "export GOOGLE_API_KEY=${GOOGLE_API_KEY}" >> /etc/cron_env
echo "export GOOGLE_GEOLOCATION_API_URL=${GOOGLE_GEOLOCATION_API_URL}" >> /etc/cron_env
echo "export TZ=${TZ}" >> /etc/cron_env
echo "export PERL5LIB=/usr/local/lib/perl" >> /etc/cron_env
echo "export ENABLE_DEBUG=${ENABLE_DEBUG}" >> /etc/cron_env

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

# Kill remaining background jobs and let docker restart the container
wait -n
kill $(jobs -p)
