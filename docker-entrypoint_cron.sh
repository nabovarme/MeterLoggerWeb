#/bin/bash

cron -f &
cron_pid=$!

/etc/apache2/perl/Nabovarme/bin/update_meters.pl &
update_meters_pid=$!

/etc/apache2/perl/Nabovarme/bin/clean_samples_cache.pl &
clean_samples_cache_pid=$!

wait -n
kill $(jobs -p)
