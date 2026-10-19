#!/bin/bash

/usr/local/bin/mqtt_to_redis.pl &
mqtt_to_redis_pid=$!

wait -n
kill $(jobs -p)
