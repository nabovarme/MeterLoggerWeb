#!/bin/bash

/usr/local/bin/mqtt_to_redis.pl &
mqtt_to_redis_pid=$!

/usr/local/bin/meter_grapher.pl &
meter_grapher_pid=$!

wait -n
kill $(jobs -p)
