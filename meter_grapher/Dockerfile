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

# Install all local .deb packages
RUN for pkg in /opt/local-debs/*.deb; do \
		echo "Installing $pkg..."; \
		dpkg -i --force-overwrite "$pkg" || true; \
	done

# Fix any missing dependencies from official repos
RUN apt-get update && \
	apt-get -f install -y

USER root

COPY ./perl /etc/apache2/perl

COPY ./meter_grapher/mqtt_to_redis.pl /etc/apache2/perl/Nabovarme/bin/mqtt_to_redis.pl
COPY ./meter_grapher/meter_grapher.pl /etc/apache2/perl/Nabovarme/bin/meter_grapher.pl

COPY ./meter_grapher/docker-entrypoint.sh /docker-entrypoint.sh

ENV PERL5LIB=/etc/apache2/perl:${PERL5LIB}

CMD /docker-entrypoint.sh

