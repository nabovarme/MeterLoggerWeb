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
	daemon \
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
	default-mysql-client

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
RUN PERL_MM_USE_DEFAULT=1 cpan install Crypt::Mode::CBC
# we need a specific version here
RUN cd /tmp && git clone https://github.com/DCIT/perl-CryptX.git && \
	cd perl-CryptX && \
	git checkout 6cef046ba02cfd01d1bfbe9e3f914bb7d1a03489 && \
	perl Makefile.PL && \
	make && \
	make install

COPY ./perl /etc/apache2/perl
COPY ./Nabovarme.conf /etc/

COPY ./mysql_mqtt_command_queue_receive/mysql_mqtt_command_queue_receive.pl /etc/apache2/perl/Nabovarme/bin/mysql_mqtt_command_queue_receive.pl

ENV PERL5LIB=/etc/apache2/perl:${PERL5LIB}

CMD /etc/apache2/perl/Nabovarme/bin/mysql_mqtt_command_queue_receive.pl

