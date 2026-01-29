#!/bin/bash
set -e

# Forward signals to the Perl process
_term() {
  echo "Caught SIGTERM, forwarding to Perl..."
  kill -TERM "$perl_pid" 2>/dev/null
}

trap _term SIGTERM SIGINT

# Run Perl server in the foreground
exec perl /smtp_server.pl
