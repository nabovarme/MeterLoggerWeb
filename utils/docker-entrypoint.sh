#!/bin/bash
# Ensure bash_history exists
HISTFILE=/home/meterlogger/.bash_history
if [ ! -f "$HISTFILE" ]; then
    touch "$HISTFILE"
    chown meterlogger:meterlogger "$HISTFILE"
fi

# Execute original command
exec "$@"


while true; do sleep 1; done
