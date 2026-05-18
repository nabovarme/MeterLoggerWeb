# meter_grapher

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

COPY ./perl /usr/local/lib/perl

COPY ./meter_grapher/mqtt_to_redis.pl /usr/local/bin/mqtt_to_redis.pl
COPY ./meter_grapher/meter_grapher.pl /usr/local/bin/meter_grapher.pl

COPY ./meter_grapher/docker-entrypoint.sh /docker-entrypoint.sh

ENV PERL5LIB=/usr/local/lib/perl

CMD ["/docker-entrypoint.sh"]

