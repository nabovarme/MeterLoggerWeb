# meter_notify

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

COPY ./perl /usr/local/lib/perl

COPY ./meter_notify/meter_notify.pl /usr/local/bin/meter_notify.pl

ENV PERL5LIB=/usr/local/lib/perl

CMD ["perl", "/usr/local/bin/meter_notify.pl"]
