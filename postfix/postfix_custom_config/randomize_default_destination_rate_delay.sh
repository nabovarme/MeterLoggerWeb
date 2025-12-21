#!/bin/bash
# This script randomizes Postfix default_destination_rate_delay in the background

# Constants
MIN_DELAY=10
MAX_DELAY=20

# Run in background
(
	while true; do
		# Generate random delay between MIN_DELAY and MAX_DELAY
		DELAY=$(( RANDOM % (MAX_DELAY - MIN_DELAY + 1) + MIN_DELAY ))

		# Apply Postfix setting
		postconf -e "default_destination_rate_delay = ${DELAY}s"

		# Optional: print for debugging
		echo "Set default_destination_rate_delay = ${DELAY}s"

		# Sleep MIN_DELAY seconds before next update
		sleep $MIN_DELAY
	done
) &
