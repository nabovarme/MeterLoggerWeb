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

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

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
	libemail-mime-perl \
	default-mysql-client

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
	libjson-create-perl

USER root

COPY ./perl /etc/apache2/perl
COPY ./Nabovarme.conf /etc/

COPY ./mysql_mqtt_command_queue_receive/mysql_mqtt_command_queue_receive.pl /etc/apache2/perl/Nabovarme/bin/mysql_mqtt_command_queue_receive.pl

ENV PERL5LIB=/etc/apache2/perl:${PERL5LIB}

CMD /etc/apache2/perl/Nabovarme/bin/mysql_mqtt_command_queue_receive.pl

