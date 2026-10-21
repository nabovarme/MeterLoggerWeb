#!/bin/bash
set -e

# Fix history file ownership if Docker mounted it as root
HISTFILE=/home/meterlogger/.bash_history
if [ ! -f "$HISTFILE" ]; then
	touch "$HISTFILE"
fi
sudo chown meterlogger:meterlogger "$HISTFILE"

# Dynamically append Docker socket GID to supplementary groups
if [ -S /var/run/docker.sock ]; then
	DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
	
	# If no group exists with this GID, create one
	if ! getent group "$DOCKER_GID" >/dev/null; then
		sudo groupadd -g "$DOCKER_GID" docker_host
	fi
	
	# Add meterlogger to this group so it persists for future 'docker exec' sessions
	sudo usermod -aG "$DOCKER_GID" meterlogger
	
	# Exec the CMD using sudo to initialize the newly added group for the current session
	exec sudo -E -u meterlogger -- "$@"
fi

# Fallback if no docker socket is mounted
exec "$@"
