FROM debian:buster

MAINTAINER Kristoffer Ek <stoffer@skulp.net>

# unrar is non-free
RUN echo "deb http://deb.debian.org/debian buster non-free" >> /etc/apt/sources.list

RUN sed -i 's|deb.debian.org|archive.debian.org|g' /etc/apt/sources.list && \
	sed -i 's|security.debian.org|archive.debian.org|g' /etc/apt/sources.list && \
	echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

RUN apt-get update && apt-get install -y \
	aptitude \
	autoconf \
	automake \
	bash \
	bison \
	bzip2 \
	flex \
	g++ \
	gawk \
	gcc \
	git \
	gnupg \
	gperf \
	help2man \
	joe \
	libexpat-dev \
	libtool \
	libtool-bin \
	make \
	ncurses-dev \
	nano \
	python3 \
	python3-pip \
	python3-dev \
	python \
	python2.7-dev \
	libmojolicious-perl \
	libjson-perl \
	libdbi-perl \
	sed \
	texinfo \
	unrar \
	unzip \
	vim \
	wget \
	splint \
	sudo \
	screen \
	software-properties-common

# REQUIRED: compatible esptool for ESP8266 toolchain
RUN pip3 install esptool==2.8

# Adduser `meterlogger`
RUN perl -pi -e 's/^#?\%sudo\W+ALL=\(ALL\:ALL\)\W+ALL/\%sudo\tALL=\(ALL\:ALL\) NOPASSWD\: ALL/' /etc/sudoers
RUN adduser --disabled-password --gecos "" meterlogger && usermod -a -G dialout meterlogger
RUN usermod -a -G sudo meterlogger

# Create our main work directory
RUN mkdir /meterlogger
RUN chown -R meterlogger:meterlogger /meterlogger

COPY ./builder/firmware_builder/build_server.pl /usr/local/bin
COPY ./perl /meterlogger/perl

# Crosstool demands non-root user for compilation
USER meterlogger

# esp-open-sdk
RUN cd /meterlogger && git clone --recursive https://github.com/nabovarme/esp-open-sdk.git && \
	cd /meterlogger/esp-open-sdk && git checkout sdk-v3.1.0-dev

RUN rm -fr /meterlogger/esp-open-sdk/esp-open-lwip

RUN cd /meterlogger/esp-open-sdk && git clone https://github.com/nabovarme/esp-open-lwip.git && \
	cd /meterlogger/esp-open-sdk/esp-open-lwip && git checkout no_igmp_mdns

RUN cd /meterlogger/esp-open-sdk && \
	make STANDALONE=y

# meterlogger
RUN cd /meterlogger && git clone https://github.com/nabovarme/MeterLogger && \
	cd /meterlogger/MeterLogger && git checkout dev_build_server

# Export ENV
ENV PATH=/meterlogger/esp-open-sdk/xtensa-lx106-elf/bin:$PATH
ENV XTENSA_TOOLS_ROOT=/meterlogger/esp-open-sdk/xtensa-lx106-elf/bin
ENV SDK_BASE=/meterlogger/esp-open-sdk/sdk

WORKDIR /meterlogger/MeterLogger

RUN mkdir -p release

CMD /usr/local/bin/build_server.pl daemon -l http://*:5000 &

CMD cat /dev/zero > /dev/null