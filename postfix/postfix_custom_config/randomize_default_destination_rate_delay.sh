#!/bin/bash
# /docker-init.db/randomize_default_destination_rate_delay.sh
# This script randomizes Postfix default_destination_rate_delay periodically

# Constants
MIN_DELAY=10
MAX_DELAY=20

while true; do
	# Generate random number between MIN_DELAY and MAX_DELAY
	DELAY=$(( RANDOM % (MAX_DELAY - MIN_DELAY + 1) + MIN_DELAY ))

	# Apply Postfix setting
	postconf -e "default_destination_rate_delay = ${DELAY}s"

	# Optional: print for debugging
	echo "Set default_destination_rate_delay = ${DELAY}s"

	# Sleep MIN_DELAY seconds before next update
	sleep $MIN_DELAY
done
