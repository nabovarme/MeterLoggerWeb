#!/bin/bash

/usr/local/bin/worker_meters.pl &
worker_meters=$!

wait -n
kill $(jobs -p)
