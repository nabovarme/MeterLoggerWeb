#!/bin/bash
set -e

# Start Perl server in foreground
/smtp_server.pl &
perl_pid=$!

# Trap signals and forward to Perl
_term() {
  echo "Caught SIGTERM, forwarding to Perl..."
  kill -TERM "$perl_pid" 2>/dev/null
}
trap _term SIGTERM SIGINT

# Wait for Perl to exit
wait "$perl_pid"
