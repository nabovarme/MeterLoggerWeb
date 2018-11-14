#
# uIota Dockerfile
#
# The resulting image will contain everything needed to build uIota FW.
#
# Setup: (only needed once per Dockerfile change)
# 1. install docker, add yourself to docker group, enable docker, relogin
# 2. # docker build -t uiota-build .
#
# Usage:
# 3. cd to MeterLoggerWeb root
# 4. # docker run -t -i -p 8080:80 meterloggerweb:latest


FROM debian:jessie

MAINTAINER Kristoffer Ek <stoffer@skulp.net>

RUN "echo" "deb http://http.us.debian.org/debian jessie non-free" >> /etc/apt/sources.list

RUN apt-get update && apt-get install -y \
	aptitude \
	autoconf \
	automake \
	aptitude \
	bash \
	bison \
	flex \
	g++ \
	gawk \
	gcc \
	git \
	inetutils-telnet \
	joe \
	make \
	sed \
	texinfo \
	sudo \
	screen \
	rsync \
	apache2 \
	apache2-bin \
	apache2-doc \
	apache2-utils \
	libapache2-mod-perl2 \
	libapache2-mod-perl2-dev \
	libapache2-mod-perl2-doc \
	libembperl-perl \
	libdbd-mysql-perl \
	libdbi-perl \
	libconfig-simple-perl \
	mysql-client

USER root

RUN PERL_MM_USE_DEFAULT=1 cpan install Math::Random::Secure
RUN PERL_MM_USE_DEFAULT=1 cpan install Net::MQTT::Simple

COPY htdocs /var/www/nabovarme
COPY ./000-default.conf /etc/apache2/sites-available/
COPY ./perl /etc/apache2/perl
COPY ./docker-entrypoint.sh /docker-entrypoint.sh
COPY ./Nabovarme.conf /etc/

COPY ./meter_grapher.pl /etc/apache2/perl/Nabovarme/bin/meter_grapher.pl
COPY ./update_meters.pl /etc/apache2/perl/Nabovarme/bin/update_meters.pl
COPY ./mysql_mqtt_command_queue_receive.pl /etc/apache2/perl/Nabovarme/bin/mysql_mqtt_command_queue_receive.pl
COPY ./mysql_mqtt_command_queue_send.pl /etc/apache2/perl/Nabovarme/bin/mysql_mqtt_command_queue_send.pl
COPY ./meter_notify.pl /etc/apache2/perl/Nabovarme/bin/meter_notify.pl
COPY ./meter_notify_water.pl /etc/apache2/perl/Nabovarme/bin/meter_notify_water.pl
COPY ./meter_wifi_config.pl /etc/apache2/perl/Nabovarme/bin/meter_wifi_config.pl
COPY ./meter_alarm.pl /etc/apache2/perl/Nabovarme/bin/meter_alarm.pl
COPY ./clean_samples_cache.pl /etc/apache2/perl/Nabovarme/bin/clean_samples_cache.pl
COPY ./sms_code_queue_watcher.sh /etc/apache2/perl/Nabovarme/bin/sms_code_queue_watcher.sh

RUN mkdir /var/www/nabovarme/sms_spool
RUN chown www-data:www-data /var/www/nabovarme/sms_spool

CMD /docker-entrypoint.sh

