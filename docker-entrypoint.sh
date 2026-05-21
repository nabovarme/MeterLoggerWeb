#!/bin/sh
set -e

# Start Apache in the foreground.
# Using 'exec' ensures Apache runs as PID 1, allowing it to receive graceful termination signals.
exec apachectl -D FOREGROUND
