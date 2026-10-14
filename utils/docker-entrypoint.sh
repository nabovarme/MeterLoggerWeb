#!/bin/bash

# Ensure bash_history exists
HISTFILE=/home/meterlogger/.bash_history
if [ ! -f "$HISTFILE" ]; then
	touch "$HISTFILE"
	chown meterlogger:meterlogger "$HISTFILE"
fi

METERLOGGER_GROUPS=$(id -G meterlogger | tr ' ' ',')

if [ -S /var/run/docker.sock ]; then
	DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)

	case ",$METERLOGGER_GROUPS," in
		*,"$DOCKER_GID",*)
			;;
		*)
			METERLOGGER_GROUPS="$METERLOGGER_GROUPS,$DOCKER_GID"
			;;
	esac
fi

if [ "$#" -gt 0 ]; then
	exec setpriv \
		--reuid=meterlogger \
		--regid=meterlogger \
		--groups="$METERLOGGER_GROUPS" \
		-- "$@"
else
	exec setpriv \
		--reuid=meterlogger \
		--regid=meterlogger \
		--groups="$METERLOGGER_GROUPS" \
		-- /bin/bash -c 'while true; do sleep 1; done'
fi
