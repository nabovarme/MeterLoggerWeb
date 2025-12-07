#!/bin/bash

set -e

# Start SMTP server
/smtp_server.pl &
smtp_server_pid=$!

# Wait for any process to exit
wait -n

# Kill remaining background jobs
kill $(jobs -p)
