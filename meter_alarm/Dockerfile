FROM debian:bullseye

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

ENV DEBIAN_FRONTEND="noninteractive"
RUN apt-get update && apt-get install -y \
	aptitude \
	bash \
	cpanplus \
	git \
	inetutils-telnet \
	joe \
	texinfo \
	sudo \
	screen \
	rsync \
	libdbd-mysql-perl \
	libdbi-perl \
	libconfig-simple-perl \
	libemail-mime-perl \
	libjson-perl \
	default-mysql-client \
	libdatetime-perl

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

USER root

COPY ./perl /usr/local/lib/perl

COPY ./meter_alarm/meter_alarm.pl /usr/local/bin/meter_alarm.pl

ENV PERL5LIB=/usr/local/lib/perl

CMD ["perl", "/usr/local/bin/meter_alarm.pl"]
