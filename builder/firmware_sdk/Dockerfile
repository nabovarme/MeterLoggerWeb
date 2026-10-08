FROM debian:buster

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

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
	libdbd-mysql-perl \
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

# Adduser `meterlogger`
RUN perl -pi -e 's/^#?\%sudo\W+ALL=\(ALL\:ALL\)\W+ALL/\%sudo\tALL=\(ALL\:ALL\) NOPASSWD\: ALL/' /etc/sudoers
RUN adduser --disabled-password --gecos "" meterlogger && usermod -a -G dialout meterlogger
RUN usermod -a -G sudo meterlogger

# Create our main work directory
RUN mkdir /meterlogger
RUN chown -R meterlogger:meterlogger /meterlogger

COPY ./builder/firmware_sdk/docker-entrypoint.sh /docker-entrypoint.sh

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

# Export ENV early so esptool2 and rboot can utilize the xtensa toolchain
ENV PATH=/meterlogger/esp-open-sdk/xtensa-lx106-elf/bin:$PATH
ENV XTENSA_TOOLS_ROOT=/meterlogger/esp-open-sdk/xtensa-lx106-elf/bin
ENV SDK_BASE=/meterlogger/esp-open-sdk/sdk

# compatible esptool for ESP8266 toolchain
RUN pip3 install esptool

# Build esptool2 (Required by rboot for packing OTA roms)
RUN cd /meterlogger && git clone https://github.com/raburton/esptool2.git && \
	cd /meterlogger/esptool2 && make && \
	cp esptool2 /meterlogger/esp-open-sdk/xtensa-lx106-elf/bin/

# Initialize repository and setup remote tracking
RUN mkdir -p /meterlogger/MeterLogger/rboot && \
	cd /meterlogger/MeterLogger && \
	git init && \
	git remote add -t ota origin https://github.com/nabovarme/MeterLogger

# Ensure we always fetch the newest MeterLogger and rboot firmware (disable cache for this step)
ARG CACHEBUST=1

# 3. Fetch and switch directly using standard checkout (Uncached)
RUN cd /meterlogger/MeterLogger && \
	git fetch origin && \
	git checkout -f working_ota

# Build rboot bootloader (Uncached to pull latest fork changes)
RUN cd /meterlogger && git clone https://github.com/nabovarme/rboot && \
	cd /meterlogger/rboot && make

# Populate rboot binaries and headers
RUN cp /meterlogger/rboot/firmware/rboot.bin /meterlogger/MeterLogger/rboot/rboot.bin && \
	cp /meterlogger/rboot/rboot.h /meterlogger/MeterLogger/rboot/rboot.h && \
	cp /meterlogger/rboot/appcode/rboot-api.h /meterlogger/MeterLogger/rboot/rboot-api.h && \
	cp /meterlogger/rboot/appcode/rboot-api.c /meterlogger/MeterLogger/rboot/rboot-api.c

WORKDIR /meterlogger/MeterLogger

COPY ./perl /meterlogger/perl

# We switch temporarily to root context to safely execute high-level permission 
# modifications over the generated compilation layout directories.
USER root
RUN mkdir -p /meterlogger/MeterLogger/release && \
    chown -R meterlogger:meterlogger /meterlogger/MeterLogger/release

# Drop execution privileges safely back to the compilation user
USER meterlogger

CMD ["/docker-entrypoint.sh"]
