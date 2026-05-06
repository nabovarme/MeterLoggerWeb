#!/bin/bash
set -e

# Start services
service postfix start

# Start background scripts
/etc/apache2/perl/Nabovarme/bin/meter_notify.pl &
meter_notify_pid=$!

/etc/apache2/perl/Nabovarme/bin/meter_alarm.pl &
meter_alarm_pid=$!

/etc/apache2/perl/Nabovarme/bin/sms_code_queue_watcher.sh &
sms_code_queue_watcher_pid=$!

# Trap signals and forward to children
_term() {
	echo "Caught SIGTERM or SIGINT, forwarding to children..."
	kill -TERM "$meter_notify_pid" 2>/dev/null
	kill -TERM "$meter_alarm_pid" 2>/dev/null
	kill -TERM "$sms_code_queue_watcher_pid" 2>/dev/null
}
trap _term SIGTERM SIGINT

# Wait for any child to exit
wait -n

# Cleanup remaining background jobs when any child exits
kill "$meter_notify_pid" 2>/dev/null
kill "$meter_alarm_pid" 2>/dev/null
kill "$sms_code_queue_watcher_pid" 2>/dev/null
wait
