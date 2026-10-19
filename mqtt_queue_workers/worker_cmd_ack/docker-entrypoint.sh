#!/bin/bash

/usr/local/bin/worker_cmd_ack.pl &
worker_cmd_ack=$!

wait -n
kill $(jobs -p)
