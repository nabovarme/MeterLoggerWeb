#!/bin/bash

service postfix start &
postfix_pid=$!

/etc/apache2/perl/Nabovarme/bin/meter_notify.pl &
meter_notify_water_pid=$!

/etc/apache2/perl/Nabovarme/bin/meter_notify_water.pl &
meter_notify_water_pid=$!

/etc/apache2/perl/Nabovarme/bin/meter_alarm.pl &
meter_alarm_pid=$!

/etc/apache2/perl/Nabovarme/bin/sms_code_queue_watcher.sh &
sms_code_queue_watcher=$!

wait -n
kill $(jobs -p)
