#!/bin/bash

/usr/local/bin/worker_events.pl &
worker_events=$!

wait -n
kill $(jobs -p)
