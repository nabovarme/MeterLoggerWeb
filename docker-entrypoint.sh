#/bin/sh

daemon -r -n update_meters /etc/apache2/perl/Nabovarme/bin/update_meters.pl
daemon -r -n clean_samples_cache /etc/apache2/perl/Nabovarme/bin/clean_samples_cache.pl

apachectl -D FOREGROUND
