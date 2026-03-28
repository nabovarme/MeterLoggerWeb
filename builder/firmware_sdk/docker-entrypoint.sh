#!/bin/sh
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

# Go to repo (adjust if needed)
cd /meterlogger/MeterLogger

# Build command
# We pass everything as Make variables
make clean all release \
  $BUILD_FLAGS \
  SERIAL=$SERIAL \
  KEY=$KEY

EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
  echo "Build failed with exit code $EXIT_CODE"
  exit $EXIT_CODE
fi

# Move firmware to shared release directory
if [ -f /meterlogger/MeterLogger/release/firmware.bin ]; then
  OUTPUT="/meterlogger/MeterLogger/release/${SERIAL}.bin"

  mv /meterlogger/MeterLogger/release/firmware.bin "$OUTPUT"

  echo "Firmware written to $OUTPUT"
else
  echo "ERROR: firmware.bin not found"
  exit 1
fi

echo "Build completed successfully"
exit 0
