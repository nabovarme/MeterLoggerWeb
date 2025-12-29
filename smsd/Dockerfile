FROM debian:bullseye

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

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
	libnet-smtp-server-perl \
	libemail-simple-perl \
	libwww-perl \
	libjson-perl \
	libnet-server-mail-perl \
	libemail-mime-perl

# Ensure root user for setup
USER root

# Install Perl module
RUN PERL_MM_USE_DEFAULT=1 cpan install File::chown

# Add smsd group and user
RUN groupadd -r smsd && useradd -r -g smsd -m -s /bin/bash smsd

# Copy scripts
COPY ./perl /etc/apache2/perl
COPY ./Nabovarme.conf /etc/

COPY ./smsd/smtp_server.pl .
COPY ./smsd/docker-entrypoint.sh /docker-entrypoint.sh

# Create directories and set ownership
RUN mkdir -p /var/spool/sms/{outgoing,failed,incoming,checked,sent}
RUN chown -R smsd:smsd /var/spool/sms

ENV PERL5LIB=/etc/apache2/perl:${PERL5LIB}

CMD ["/bin/bash", "/docker-entrypoint.sh"]
