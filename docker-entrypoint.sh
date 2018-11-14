#/bin/sh

#daemon -r -n meter_grapher /etc/apache2/perl/Nabovarme/bin/meter_grapher.pl
daemon -r -n update_meters /etc/apache2/perl/Nabovarme/bin/update_meters.pl
#daemon -r -n mysql_mqtt_command_queue_receive /etc/apache2/perl/Nabovarme/bin/mysql_mqtt_command_queue_receive.pl
#daemon -r -n mysql_mqtt_command_queue_send /etc/apache2/perl/Nabovarme/bin/mysql_mqtt_command_queue_send.pl
daemon -r -n meter_notify /etc/apache2/perl/Nabovarme/bin/meter_notify.pl
daemon -r -n meter_notify_water /etc/apache2/perl/Nabovarme/bin/meter_notify_water.pl
daemon -r -n meter_wifi_config /etc/apache2/perl/Nabovarme/bin/meter_wifi_config.pl
#daemon -r -n meter_alarm /etc/apache2/perl/Nabovarme/bin/meter_alarm.pl
daemon -r -n clean_samples_cache /etc/apache2/perl/Nabovarme/bin/clean_samples_cache.pl
#daemon -r -n sms_code_queue_watcher /etc/apache2/perl/Nabovarme/bin/sms_code_queue_watcher.sh

apachectl -D FOREGROUND
