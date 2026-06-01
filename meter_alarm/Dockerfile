# meter_alarm

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

COPY ./perl /usr/local/lib/perl

COPY ./meter_alarm/meter_alarm.pl /usr/local/bin/meter_alarm.pl

ENV PERL5LIB=/usr/local/lib/perl

# =========================================================================
# Version Tracking Setup
# Configures structural labels visible directly to the cAdvisor API
# =========================================================================
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}
LABEL app.git.commit=${GIT_COMMIT}

# Run the meter alarm script natively as PID 1
CMD ["perl", "/usr/local/bin/meter_alarm.pl"]
