# meter_alarm

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

COPY ./perl /usr/local/lib/perl

COPY ./meter_alarm/meter_alarm.pl /usr/local/bin/meter_alarm.pl

ENV PERL5LIB=/usr/local/lib/perl

CMD ["perl", "/usr/local/bin/meter_alarm.pl"]
