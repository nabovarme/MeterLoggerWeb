#/bin/sh

#PSEUDO_TTY=/var/run/ttyV0

mkdir -p /var/spool/sms/checked &&
mkdir -p /var/spool/sms/failed &&
mkdir -p /var/spool/sms/incoming &&
mkdir -p /var/spool/sms/outgoing &&
mkdir -p /var/spool/sms/sent &&

#daemon -r -n socat 
#socat -d -d pty,link=$PSEUDO_TTY,raw,echo=0,wait-slave,b19200 tcp:$SMSD_HOST:$SMSD_PORT &
#while [ ! -L $PSEUDO_TTY ]
#	do sleep 1; echo "waiting for $PSEUDO_TTY to be created"
#done
#smsd -c/etc/smsd.conf && tail -f /var/log/smstools/smsd.log &
/smtp_server.pl &
smsd -c/etc/smsd.conf &
touch /var/log/smstools/smsd.log
tail -f /var/log/smstools/smsd.log
#while [ -L $PSEUDO_TTY ]
#	do sleep 10
#done
#echo "$PSEUDO_TTY went away, restarting"
#exit 1
