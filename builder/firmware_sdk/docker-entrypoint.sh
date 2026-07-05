#!/bin/dash
set -e

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

# Build firmware and components
make clean all \
	$BUILD_FLAGS \
	SERIAL=$SERIAL \
	KEY=$KEY

EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
	echo "Build failed with exit code $EXIT_CODE"
	exit $EXIT_CODE
fi

echo "Copy files into the mapped release/ tracking path..."
cp firmware/0x00000.bin release/0x00000.bin
cp firmware/0x10000.bin release/0x10000.bin
cp webpages.espfs release/webpages.espfs
cp firmware/esp_init_data_default_112th_byte_0x03.bin release/esp_init_data_default_112th_byte_0x03.bin
cp firmware/blank.bin release/blank.bin

echo "Build completed successfully"
exit 0
