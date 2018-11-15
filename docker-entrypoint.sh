#/bin/sh

chown -R www-data:www-data /var/www/nabovarme/sms_spool
apachectl -D FOREGROUND
