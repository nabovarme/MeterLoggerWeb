#/bin/sh

mkdir -p /var/spool/sms/checked &&
mkdir -p /var/spool/sms/failed &&
mkdir -p /var/spool/sms/incoming &&
mkdir -p /var/spool/sms/outgoing &&
mkdir -p /var/spool/sms/sent &&

#daemon -r -n socat 
socat -d -d pty,link=/var/run/ttyV0,raw,echo=0,wait-slave,b19200 tcp:$SMSD_HOST:$SMSD_PORT &
while [ ! -L /var/run/ttyV0 ]
	do sleep 1
done
ls -al /var/run/ttyV0 &&
smsd -c/etc/smsd.conf && tail -f /var/log/smstools/smsd.log &
while [ -L /tmp/ttyV0 ]
	do sleep 10
done
exit 1
