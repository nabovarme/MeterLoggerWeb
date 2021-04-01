#/bin/sh

/smtp_server.pl &
sudo -u smsd smsd -c/etc/smsd.conf
touch /var/log/smstools/smsd.log
tail -f /var/log/smstools/smsd.log
