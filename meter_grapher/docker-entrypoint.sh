#!/bin/bash

/etc/apache2/perl/Nabovarme/bin/mqtt_to_redis.pl &
mqtt_to_redis_pid=$!

/etc/apache2/perl/Nabovarme/bin/meter_grapher.pl &
meter_grapher_pid=$!

wait -n
kill $(jobs -p)
