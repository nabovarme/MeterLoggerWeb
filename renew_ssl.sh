#!/bin/bash

ssh rnanopi 'iptables -t nat -D PREROUTING -d 193.89.248.25/32 -i eth0 -p tcp -m tcp --dport 80 -m comment --comment "Web Server" -j DNAT --to-destination 10.0.1.9:80'
ssh rnanopi 'iptables -t nat -D PREROUTING -d 193.89.248.25/32 -i lan0 -p tcp -m tcp --dport 80 -m comment --comment "Web Server" -j DNAT --to-destination 10.0.1.9:80'

screen -S ssh_forward -dm ssh -R 193.89.248.25:80:localhost:80 -i ~/.ssh/root_nanopi.identity rnanopi ping -i 10 127.0.0.1

docker exec -it web certbot certonly --agree-tos --email $METERLOGGER_LETS_ENCRYPT_EMAIL --webroot -w /var/www/nabovarme/ -d $METERLOGGER_LETS_ENCRYPT_HOST_NAME
docker exec -it web apachectl reload

ssh rnanopi 'iptables -t nat -A PREROUTING -d 193.89.248.25/32 -i eth0 -p tcp -m tcp --dport 80 -m comment --comment "Web Server" -j DNAT --to-destination 10.0.1.9:80'
ssh rnanopi 'iptables -t nat -A PREROUTING -d 193.89.248.25/32 -i lan0 -p tcp -m tcp --dport 80 -m comment --comment "Web Server" -j DNAT --to-destination 10.0.1.9:80'
