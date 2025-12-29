#!/bin/bash
set -e

# Optional: default if env not set
: "${INNODB_BUFFER_POOL_SIZE:=32G}"

echo "Applying INNODB_BUFFER_POOL_SIZE=$INNODB_BUFFER_POOL_SIZE"

# Generate the actual my.cnf for MariaDB
sed "s|\${INNODB_BUFFER_POOL_SIZE}|$INNODB_BUFFER_POOL_SIZE|g" \
    /etc/mysql/my.cnf.template > /etc/mysql/my.cnf

# Done — official entrypoint will start MariaDB
