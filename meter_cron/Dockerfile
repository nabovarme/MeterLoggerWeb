# meter_cron

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

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

# =========================================================================
# Version Tracking Setup
# Captures your dynamic deployment version hash safely from .env.version
# =========================================================================
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

ENTRYPOINT ["/bin/bash", "/docker-entrypoint.sh"]
