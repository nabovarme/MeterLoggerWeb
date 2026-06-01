# meter_alarm

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

COPY ./perl /usr/local/lib/perl

COPY ./meter_alarm/meter_alarm.pl /usr/local/bin/meter_alarm.pl
COPY ./meter_alarm/docker-entrypoint.sh /docker-entrypoint.sh

ENV PERL5LIB=/usr/local/lib/perl

# =========================================================================
# Version Tracking Setup
# Bakes the commit argument from .env.version securely into this image layer
# =========================================================================
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["perl", "/usr/local/bin/meter_alarm.pl"]
