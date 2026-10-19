# mqtt_to_redis

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

COPY ./perl /usr/local/lib/perl

COPY ./mqtt_queue_workers/worker_meters/worker_meters.pl /usr/local/bin/worker_meters.pl
COPY ./mqtt_queue_workers/worker_meters/docker-entrypoint.sh /docker-entrypoint.sh

ENV PERL5LIB=/usr/local/lib/perl

# =========================================================================
# Version Tracking Setup
# Captures your current environment deployment hash safely from .env.version
# =========================================================================
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

ENTRYPOINT ["/docker-entrypoint.sh"]
