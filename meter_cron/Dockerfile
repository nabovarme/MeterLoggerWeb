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


FROM debian:bullseye

MAINTAINER Kristoffer Ek <stoffer@skulp.net>

RUN apt-get update && apt-get install -y \
	aptitude \
	autoconf \
	automake \
	aptitude \
	bash \
	bison \
	cpanplus \
	cron \
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
	libdbd-mysql-perl \
	libdbi-perl \
	libconfig-simple-perl \
	default-mysql-client \
	libparallel-forkmanager-perl \
	libproc-pid-file-perl

USER root

RUN PERL_MM_USE_DEFAULT=1 cpan install Math::Random::Secure

# we need a specific version here
#RUN PERL_MM_USE_DEFAULT=1 cpan install Net::MQTT::Simple
RUN cd /tmp && git clone https://github.com/st0ff3r/Net-MQTT-Simple.git && \
	cd Net-MQTT-Simple && \
	perl Makefile.PL && \
	make && \
	make install

RUN PERL_MM_USE_DEFAULT=1 cpan install Statistics::Basic
RUN PERL_MM_USE_DEFAULT=1 cpan install Time::Format
RUN PERL_MM_USE_DEFAULT=1 cpan install JSON::Create
# we need a specific version here
RUN cd /tmp && git clone https://github.com/DCIT/perl-CryptX.git && \
	cd perl-CryptX && \
	git checkout 6cef046ba02cfd01d1bfbe9e3f914bb7d1a03489 && \
	perl Makefile.PL && \
	make && \
	make install

COPY ./perl /etc/apache2/perl
COPY ./Nabovarme.conf /etc/
COPY ./meter_cron/crontab /etc/

RUN chmod 0644 /etc/crontab && \
	touch /var/log/cron.log

COPY ./meter_cron/update_meters.pl /etc/apache2/perl/Nabovarme/bin/update_meters.pl
COPY ./meter_cron/clean_samples_cache.pl /etc/apache2/perl/Nabovarme/bin/clean_samples_cache.pl
COPY ./meter_cron/clean_sms_auth.pl /etc/apache2/perl/Nabovarme/bin/clean_sms_auth.pl
COPY ./meter_cron/wifi_get_location.pl /etc/apache2/perl/Nabovarme/bin/wifi_get_location.pl
COPY ./meter_cron/update_samples_hourly_and_daily.pl /etc/apache2/perl/Nabovarme/bin/update_samples_hourly_and_daily.pl
COPY ./meter_cron/remove_spikes.pl /etc/apache2/perl/Nabovarme/bin/remove_spikes.pl
COPY ./meter_cron/sync_alarms_auto.pl /etc/apache2/perl/Nabovarme/bin/sync_alarms_auto.pl
COPY ./meter_cron/update_estimated_energy.pl /etc/apache2/perl/Nabovarme/bin/update_estimated_energy.pl

COPY ./meter_cron/docker-entrypoint.sh /docker-entrypoint.sh

CMD ["/bin/bash", "/docker-entrypoint.sh"]
