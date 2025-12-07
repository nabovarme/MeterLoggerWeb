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
	procps \
	bash \
	git \
	make \
	gcc \
	inetutils-telnet \
	joe \
	sudo \
	screen \
	rsync \
	smstools \
	libnet-smtp-server-perl \
	libemail-simple-perl \
	libwww-perl \
	libjson-perl

USER root

RUN PERL_MM_USE_DEFAULT=1 cpan install File::chown

COPY ./smsd.conf /etc/smsd.conf
COPY ./smtp_server.pl .
COPY ./docker-entrypoint.sh /docker-entrypoint.sh

RUN mkdir -p /var/run/smstools
RUN chown smsd:smsd /var/run/smstools
RUN mkdir -p /var/spool/sms/{outgoing,failed,incoming,checked,sent}
RUN chown -R smsd:smsd /var/spool/sms

CMD ["/bin/bash", "/docker-entrypoint.sh"]


