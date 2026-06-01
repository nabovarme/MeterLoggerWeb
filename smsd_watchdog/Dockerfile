# smsd_watchdog

FROM perl-base:1.0

# Copy watcher script
COPY ./perl /usr/local/lib/perl
COPY ./smsd_watchdog/watcher.pl /watcher.pl
COPY ./smsd_watchdog/docker-entrypoint.sh /docker-entrypoint.sh

RUN chmod +x /watcher.pl /docker-entrypoint.sh

WORKDIR /

ENV PERL5LIB=/usr/local/lib/perl

# =========================================================================
# Version Tracking Setup
# Captures your dynamic deployment version hash safely from .env.version
# =========================================================================
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/watcher.pl"]
