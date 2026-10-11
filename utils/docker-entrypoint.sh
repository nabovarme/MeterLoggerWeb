#!/bin/bash

# Ensure bash_history exists
HISTFILE=/home/meterlogger/.bash_history
if [ ! -f "$HISTFILE" ]; then
    touch "$HISTFILE"
    chown meterlogger:meterlogger "$HISTFILE"
fi

# Execute passed command if provided, otherwise default to infinite loop
if [ "$#" -gt 0 ]; then
    exec "$@"
else
    while true; do sleep 1; done
fi
