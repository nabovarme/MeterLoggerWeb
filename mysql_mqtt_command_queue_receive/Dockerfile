# mysql_mqtt_command_queue_receive

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

COPY ./perl /usr/local/lib/perl

COPY ./mysql_mqtt_command_queue_receive/mysql_mqtt_command_queue_receive.pl /usr/local/bin/mysql_mqtt_command_queue_receive.pl
COPY ./mysql_mqtt_command_queue_receive/docker-entrypoint.sh /docker-entrypoint.sh

ENV PERL5LIB=/usr/local/lib/perl

# =========================================================================
# Version Tracking Setup
# Captures your current environment deployment hash safely from .env.version
# =========================================================================
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/usr/local/bin/mysql_mqtt_command_queue_receive.pl"]
