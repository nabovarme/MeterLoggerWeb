#!/bin/bash

/usr/local/bin/worker_telemetry.pl &
mqtt_to_redis_pid=$!

wait -n
kill $(jobs -p)
