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

CMD /docker-entrypoint.sh

