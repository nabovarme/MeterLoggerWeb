#!/bin/sh
set -e

#tail -f /dev/null

mkdir -p /var/www/.texmf-var
chown www-data:www-data /var/www/.texmf-var

mkdir -p /var/www/.texlive2018
chown www-data:www-data /var/www/.texlive2018

sudo -u www-data mktexpk --mfmode / --bdpi 600 --mag 1+0/600 --dpi 600 ecsx3583
sudo -u www-data mktexpk --mfmode / --bdpi 600 --mag 1+0/600 --dpi 600 ectt1095
sudo -u www-data mktexpk --mfmode / --bdpi 600 --mag 1+0/600 --dpi 600 ecss1095

chown -R www-data:www-data /var/www/nabovarme/sms_spool

# --- Create .my.cnf for DB access from environment ---
cat <<EOF >/etc/mysql/my.cnf
[client]
user=${METERLOGGER_DB_USER}
password=${METERLOGGER_DB_PASSWORD}
host=${METERLOGGER_DB_HOST}
database=${METERLOGGER_DB_NAME}
port=${METERLOGGER_DB_PORT}
EOF

# Make sure only www-data can read it
chown www-data:www-data /etc/mysql/my.cnf
chmod 600 /etc/mysql/my.cnf

# Start Apache in foreground
apachectl -D FOREGROUND
