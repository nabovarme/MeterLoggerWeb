FROM debian:bookworm

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

# Enable contrib + non-free
RUN echo "deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list

# Base dependencies
RUN apt-get update && apt-get install -y \
	docker.io \
	aptitude \
	bash \
	joe \
	libhttp-daemon-perl \
	libjson-perl \
	libdbi-perl \
	libdbd-mysql-perl \
	libparallel-forkmanager-perl \
	sed \
	curl \
	lsb-release \
	&& apt-get clean && rm -rf /var/lib/apt/lists/*

COPY ./builder/firmware_builder/docker-entrypoint.sh /docker-entrypoint.sh
COPY ./builder/firmware_builder/build_server.pl /usr/local/bin
COPY ./perl /usr/local/share/perl

CMD ["/docker-entrypoint.sh"]
