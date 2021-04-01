#/bin/sh

#PSEUDO_TTY=/var/run/ttyV0

mkdir -p /var/spool/sms/checked &&
mkdir -p /var/spool/sms/failed &&
mkdir -p /var/spool/sms/incoming &&
mkdir -p /var/spool/sms/outgoing &&
mkdir -p /var/spool/sms/sent &&
chown -R smsd:smsd /var/spool/sms &&

/smtp_server.pl &
smsd -c/etc/smsd.conf
touch /var/log/smstools/smsd.log
tail -f /var/log/smstools/smsd.log
