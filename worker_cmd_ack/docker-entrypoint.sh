#!/bin/bash

/usr/local/bin/worker_cmd_ack.pl &
mqtt_to_redis_pid=$!

wait -n
kill $(jobs -p)
