FROM debian:bullseye

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

ENV DEBIAN_FRONTEND="noninteractive"

RUN apt-get update && apt-get install -y \
	perl \
	libjson-perl \
	libredis-perl \
	libtry-tiny-perl

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

COPY ./perl_alarm_condition_sandbox/perl_sandbox.pl /usr/local/bin/perl_sandbox.pl

CMD ["perl", "/usr/local/bin/perl_sandbox.pl"]
