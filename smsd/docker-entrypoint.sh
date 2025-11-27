#/bin/bash

/smtp_server.pl &
smtp_server_pid=$!

smsd -c/etc/smsd.conf -t &
smsd_pid=$!

wait -n
kill $(jobs -p)
