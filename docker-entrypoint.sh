#!/bin/sh
set -e

# Load Apache environment variables explicitly (Required when bypassing apachectl)
. /etc/apache2/envvars

# Execute the binary directly so it catches SIGTERM instantly
exec apache2 -D FOREGROUND