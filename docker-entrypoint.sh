#/bin/sh

mkdir -p /var/www/.texmf-var
chown www-data:www-data /var/www/.texmf-var

mkdir -p /var/www/.texlive2018
chown www-data:www-data /var/www/.texlive2018

sudo -u www-data mktexpk --mfmode / --bdpi 600 --mag 1+0/600 --dpi 600 ecsx3583
sudo -u www-data mktexpk --mfmode / --bdpi 600 --mag 1+0/600 --dpi 600 ectt1095
sudo -u www-data mktexpk --mfmode / --bdpi 600 --mag 1+0/600 --dpi 600 ecss1095

chown -R www-data:www-data /var/www/nabovarme/sms_spool
apachectl -D FOREGROUND

while true; do sleep 1; done