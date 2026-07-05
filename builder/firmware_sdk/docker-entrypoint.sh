#!/bin/dash
set -e

# Ensure the mounted release directory is owned by the compilation user
mkdir -p /meterlogger/MeterLogger/release
chown -R meterlogger:meterlogger /meterlogger/MeterLogger/release

# Bypass Git's dubious ownership validation rules globally for root context
git config --global --add safe.directory /meterlogger/MeterLogger

# Validate required env vars
if [ -z "$SERIAL" ]; then
	echo "ERROR: SERIAL not set"
	exit 1
fi

if [ -z "$KEY" ]; then
	echo "ERROR: KEY not set"
	exit 1
fi

echo "Starting build"
echo "SERIAL=$SERIAL"
echo "KEY=***"
echo "BUILD_FLAGS=$BUILD_FLAGS"

# Go to repo
cd /meterlogger/MeterLogger

# FIXED: Leverage the newly refactored release rule to build and copy all segments atomically
make clean release \
	$BUILD_FLAGS \
	SERIAL=$SERIAL \
	KEY=$KEY

EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
	echo "Build failed with exit code $EXIT_CODE"
	exit $EXIT_CODE
fi

echo "Build completed successfully"
exit 0
