#! /bin/sh

while true; do
	chown smsd:smsd /var/www/nabovarme/sms_spool/* 2> /dev/null;
	mv /var/www/nabovarme/sms_spool/* /var/spool/sms/outgoing/ 2> /dev/null; sleep 1;
done
