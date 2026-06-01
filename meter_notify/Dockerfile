# meter_notify

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

COPY ./perl /usr/local/lib/perl

COPY ./meter_notify/meter_notify.pl /usr/local/bin/meter_notify.pl
COPY ./meter_notify/docker-entrypoint.sh /docker-entrypoint.sh

ENV PERL5LIB=/usr/local/lib/perl

# =========================================================================
# Version Tracking Setup
# Captures your current environment deployment hash safely from .env.version
# =========================================================================
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["perl", "/usr/local/bin/meter_notify.pl"]
