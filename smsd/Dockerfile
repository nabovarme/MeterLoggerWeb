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

# Copy local repository from Docker volume
RUN mkdir -p /opt/local-debs
COPY ./perl_modules/debs/*.deb /opt/local-debs
COPY ./perl_modules/debs/Packages.gz /opt/local-debs

# Add a local APT source list
RUN echo "deb [trusted=yes] file:/opt/local-debs ./" > /etc/apt/sources.list.d/local-debs.list

# Update and install Perl modules
RUN apt-get update && apt-get install -y \
	libfile-chown-perl

USER root

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
