#/bin/bash

# Export relevant environment variables for cron jobs
echo "export METERLOGGER_DB_HOST=${METERLOGGER_DB_HOST}" >> /etc/cron_env
echo "export METERLOGGER_DB_USER=${METERLOGGER_DB_USER}" >> /etc/cron_env
echo "export METERLOGGER_DB_PASSWORD=${METERLOGGER_DB_PASSWORD}" >> /etc/cron_env
echo "export TZ=${TZ}" >> /etc/cron_env
echo "export PERL5LIB=/etc/apache2/perl" >> /etc/cron_env
echo "export ENABLE_DEBUG=${ENABLE_DEBUG}" > /etc/cron_env

# Start cron in the background
cron -f &
cron_pid=$!

# Tail the cron log
tail -f /var/log/cron.log &
tail_cron_pid=$!

# Run scripts manually in the background
/etc/apache2/perl/Nabovarme/bin/update_meters.pl &
update_meters_pid=$!

/etc/apache2/perl/Nabovarme/bin/clean_samples_cache.pl &
clean_samples_cache_pid=$!

# Kill remaining background jobs and let docker restart the container
wait -n
kill $(jobs -p)
