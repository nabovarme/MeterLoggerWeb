FROM debian:bullseye

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

ENV DEBIAN_FRONTEND="noninteractive"
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
	libemail-mime-perl \
	default-mysql-client \
	postfix

#debconf-set-selections <<< "postfix postfix/mailname string nabovarme"
#debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet with smarthost'"
#debconf-set-selections <<< "postfix postfix/relayhost string smsd"
#apt-get install --assume-yes postfix

# Copy local repository from Docker volume
RUN mkdir -p /opt/local-debs
COPY ./perl_modules/debs/*.deb /opt/local-debs
COPY ./perl_modules/debs/Packages.gz /opt/local-debs

# Add a local APT source list
RUN echo "deb [trusted=yes] file:/opt/local-debs ./" > /etc/apt/sources.list.d/local-debs.list

# Update and install Perl modules
RUN apt-get update && apt-get install -y \
	libmath-random-secure-perl \
	libstatistics-basic-perl \
	libtime-format-perl \
	libcryptx-perl \
	libnet-mqtt-simple-perl \
	libjson-create-perl \
	libredis-perl \
	libfile-chown-perl

USER root

RUN postconf -e 'relayhost=smsd'

RUN mkdir /var/www/nabovarme
RUN chown www-data:www-data /var/www/nabovarme

COPY ./meter_sms/smtp_send_test.pl /

COPY ./perl /etc/apache2/perl
COPY ./Nabovarme.conf /etc/

COPY ./meter_sms/meter_notify.pl /etc/apache2/perl/Nabovarme/bin/meter_notify.pl
COPY ./meter_sms/meter_alarm.pl /etc/apache2/perl/Nabovarme/bin/meter_alarm.pl
COPY ./meter_sms/sms_code_queue_watcher.sh /etc/apache2/perl/Nabovarme/bin/sms_code_queue_watcher.sh
COPY ./meter_sms/smstools_send.pl /etc/apache2/perl/Nabovarme/bin/smstools_send.pl

COPY ./meter_sms/docker-entrypoint.sh /docker-entrypoint.sh

RUN mkdir /var/www/nabovarme/sms_spool
RUN chown -R www-data:www-data /var/www/nabovarme/sms_spool

ENV PERL5LIB=/etc/apache2/perl:${PERL5LIB}

CMD ["/bin/bash", "/docker-entrypoint.sh"]
