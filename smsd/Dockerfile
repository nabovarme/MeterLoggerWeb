# smsd

FROM perl-base:1.0

LABEL maintainer="Kristoffer Ek <stoffer@skulp.net>"

USER root

# Add smsd group and user
RUN groupadd -r smsd && useradd -r -g smsd -m -s /bin/bash smsd

# Copy scripts
COPY ./perl /usr/local/lib/perl

COPY ./smsd/smtp_server.pl /usr/local/bin/smtp_server.pl
COPY ./smsd/docker-entrypoint.sh /docker-entrypoint.sh

ENV PERL5LIB=/usr/local/lib/perl

CMD ["/bin/bash", "/docker-entrypoint.sh"]
