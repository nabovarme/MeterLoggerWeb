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
	cron \
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
	default-mysql-client \
	libparallel-forkmanager-perl \
	libproc-pid-file-perl \
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

USER root

COPY ./perl /usr/local/lib/perl
COPY ./meter_cron/crontab /etc/

RUN chmod 0644 /etc/crontab && \
	touch /var/log/cron.log

COPY ./update_meters.pl /usr/local/bin/update_meters.pl
COPY ./clean_samples_cache.pl /usr/local/bin/clean_samples_cache.pl
COPY ./meter_cron/clean_sms_auth.pl /usr/local/bin/clean_sms_auth.pl
COPY ./meter_cron/wifi_get_location.pl /usr/local/bin/wifi_get_location.pl
COPY ./meter_cron/update_samples_hourly_and_daily.pl /usr/local/bin/update_samples_hourly_and_daily.pl
COPY ./meter_cron/remove_spikes.pl /usr/local/bin/remove_spikes.pl
COPY ./meter_cron/sync_alarms_auto.pl /usr/local/bin/sync_alarms_auto.pl
COPY ./meter_cron/update_estimated_energy.pl /usr/local/bin/update_estimated_energy.pl

COPY ./meter_cron/docker-entrypoint.sh /docker-entrypoint.sh

ENV PERL5LIB=/usr/local/lib/perl

CMD ["/bin/bash", "/docker-entrypoint.sh"]
