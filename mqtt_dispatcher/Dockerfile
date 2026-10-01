# mqtt_dispatcher

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

COPY ./perl /usr/local/lib/perl

COPY ./mqtt_dispatcher/mqtt_dispatcher.pl /usr/local/bin/mqtt_dispatcher.pl

ENV PERL5LIB=/usr/local/lib/perl

# =========================================================================
# Version Tracking Setup
# Captures your current environment deployment hash safely from .env.version
# =========================================================================
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

CMD ["/usr/local/bin/mqtt_dispatcher.pl"]
