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


FROM debian:buster

MAINTAINER Kristoffer Ek <stoffer@skulp.net>

RUN "echo" "deb http://http.us.debian.org/debian buster non-free" >> /etc/apt/sources.list

RUN apt-get update && apt-get install -y \
	aptitude \
	autoconf \
	automake \
	aptitude \
	bash \
	bison \
	cpanplus \
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
	libtime-duration-perl \
	libjson-xs-perl \
	default-mysql-client\
	software-properties-common \
	texlive \
	texlive-latex-base \
	texlive-latex-extra \
	texlive-fonts-extra \
	qrencode \
	imagemagick

USER root

RUN PERL_MM_USE_DEFAULT=1 cpan install Math::Random::Secure

# we need a specific version here
#RUN PERL_MM_USE_DEFAULT=1 cpan install Net::MQTT::Simple
RUN cd /tmp && git clone https://github.com/st0ff3r/Net-MQTT-Simple.git && \
	cd Net-MQTT-Simple && \
	perl Makefile.PL && \
	make && \
	make install

RUN cd /tmp && git clone https://github.com/DCIT/perl-CryptX.git && \
	cd perl-CryptX && \
	git checkout 6cef046ba02cfd01d1bfbe9e3f914bb7d1a03489 && \
	perl Makefile.PL && \
	make && \
	make install

RUN PERL_MM_USE_DEFAULT=1 cpan install Statistics::Basic
RUN PERL_MM_USE_DEFAULT=1 cpan install Time::Format

RUN mkdir -p /var/www/nabovarme/cache
RUN mkdir -p /var/www/nabovarme/qr
RUN chown www-data:www-data /var/www/nabovarme/cache
RUN chown www-data:www-data /var/www/nabovarme/qr

RUN a2enmod expires
RUN a2enmod remoteip

#COPY ./htdocs /var/www/nabovarme
COPY ./000-default.conf /etc/apache2/sites-available/

#COPY ./perl /etc/apache2/perl
COPY ./docker-entrypoint.sh /docker-entrypoint.sh
COPY ./Nabovarme.conf /etc/
COPY ./template.tex /var/www/nabovarme/qr/

COPY ./update_meters.pl /etc/apache2/perl/Nabovarme/bin/update_meters.pl
COPY ./clean_samples_cache.pl /etc/apache2/perl/Nabovarme/bin/clean_samples_cache.pl

CMD /docker-entrypoint.sh
