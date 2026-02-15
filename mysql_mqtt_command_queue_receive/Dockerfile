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

COPY ./mysql_mqtt_command_queue_receive/mysql_mqtt_command_queue_receive.pl /etc/apache2/perl/Nabovarme/bin/mysql_mqtt_command_queue_receive.pl

ENV PERL5LIB=/etc/apache2/perl:${PERL5LIB}

CMD /etc/apache2/perl/Nabovarme/bin/mysql_mqtt_command_queue_receive.pl

