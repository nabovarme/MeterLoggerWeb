#!/bin/bash

set -e

# Use SMSD_DEVICE env variable or default if not set
SMSD_DEVICE=${SMSD_DEVICE:-/dev/ttyUSB0}

# Update smsd.conf with the device from environment
if [ -f /etc/smsd.conf ]; then
    sed -i "s|^device = .*|device = $SMSD_DEVICE|g" /etc/smsd.conf
fi

# Start SMTP server
/smtp_server.pl &
smtp_server_pid=$!

# Start smsd
smsd -c /etc/smsd.conf -t &
smsd_pid=$!

# Wait for any process to exit
wait -n

# Kill remaining background jobs
kill $(jobs -p)
