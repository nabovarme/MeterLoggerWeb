FROM debian:bullseye

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

# Base tools + Perl deps
RUN apt-get update && apt-get install -y \
	aptitude \
	procps \
	bash \
	git \
	make \
	gcc \
	joe \
	sudo \
	screen \
	rsync \
	libwww-perl \
	libjson-perl \
	libdbd-mysql-perl \
	libdbi-perl \
	libconfig-simple-perl \
	libhttp-daemon-perl \
	libemail-mime-perl

# Copy local repository from Docker volume
RUN mkdir -p /opt/local-debs
COPY ./perl_modules/debs/*.deb /opt/local-debs

# Install all local .deb packages
RUN for pkg in /opt/local-debs/*.deb; do \
		echo "Installing $pkg..."; \
		dpkg -i --force-overwrite "$pkg" || true; \
	done

# Fix any missing dependencies from official repos
RUN apt-get update && \
	apt-get -f install -y

RUN groupadd -r exporter && useradd -r -g exporter -m -s /bin/bash exporter

# Perl libs + config
COPY ./perl /etc/apache2/perl
COPY ./Nabovarme.conf /etc/

# Exporter script
COPY ./prometheus_exporter/prometheus_exporter.pl /usr/local/bin/prometheus_exporter.pl
RUN chmod +x /usr/local/bin/prometheus_exporter.pl

ENV PERL5LIB=/etc/apache2/perl:${PERL5LIB}
ENV EXPORTER_PORT=9100

EXPOSE 9100

USER exporter

CMD ["/usr/local/bin/prometheus_exporter.pl"]
